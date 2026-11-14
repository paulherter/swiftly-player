// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The bottom layer of the GPU renderer: the newest video frame as one texture, drawn before the UI quads of the same
//! pass. The frame is uploaded with `queue.write_texture` (rung 1 of the G3 ladder: libmpv software render into a CPU
//! buffer, one copy to the GPU). The texture is recreated only when the frame size changes.

use crate::wgpu_renderer::GpuContext;

const SHADER: &str = include_str!("video.wgsl");

/// How the frame sits in the target.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VideoFit {
    /// The whole frame is visible, black bars where the aspect differs.
    Fit,
    /// The frame covers the target, the overflow is cropped.
    Fill,
}

/// Pipeline, texture and bindings of the video layer.
pub(crate) struct VideoLayer {
    pipeline: wgpu::RenderPipeline,
    layout: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    place: wgpu::Buffer,
    texture: Option<(wgpu::Texture, wgpu::TextureView, (u32, u32))>,
    bind_group: Option<wgpu::BindGroup>,
    pub(crate) fit: VideoFit,
}

impl VideoLayer {
    pub(crate) fn new(ctx: &GpuContext, format: wgpu::TextureFormat) -> VideoLayer {
        let device = ctx.device();
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("swiftly-render video"),
            source: wgpu::ShaderSource::Wgsl(SHADER.into()),
        });
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("swiftly-render video bindings"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("swiftly-render video layout"),
            bind_group_layouts: &[Some(&layout)],
            immediate_size: 0,
        });
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("swiftly-render video"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &module,
                entry_point: Some("vs_main"),
                compilation_options: Default::default(),
                buffers: &[],
            },
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: Default::default(),
            fragment: Some(wgpu::FragmentState {
                module: &module,
                entry_point: Some("fs_main"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            multiview_mask: None,
            cache: None,
        });
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("swiftly-render video sampler"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });
        let place = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("swiftly-render video place"),
            size: 32,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        VideoLayer {
            pipeline,
            layout,
            sampler,
            place,
            texture: None,
            bind_group: None,
            fit: VideoFit::Fit,
        }
    }

    /// Copies a `w x h` RGBA frame into the texture (a new texture when the size changed).
    pub(crate) fn upload(&mut self, ctx: &GpuContext, w: u32, h: u32, rgba: &[u8]) {
        if w == 0 || h == 0 || rgba.len() < w as usize * h as usize * 4 {
            return;
        }
        if self.texture.as_ref().is_none_or(|t| t.2 != (w, h)) {
            let texture = ctx.device().create_texture(&wgpu::TextureDescriptor {
                label: Some("swiftly-render video frame"),
                size: wgpu::Extent3d {
                    width: w,
                    height: h,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Rgba8Unorm,
                usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                view_formats: &[],
            });
            let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
            self.bind_group = Some(ctx.device().create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("swiftly-render video bindings"),
                layout: &self.layout,
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: self.place.as_entire_binding(),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: wgpu::BindingResource::TextureView(&view),
                    },
                    wgpu::BindGroupEntry {
                        binding: 2,
                        resource: wgpu::BindingResource::Sampler(&self.sampler),
                    },
                ],
            }));
            self.texture = Some((texture, view, (w, h)));
        }
        if let Some((texture, _, _)) = &self.texture {
            ctx.queue().write_texture(
                texture.as_image_copy(),
                rgba,
                wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(w * 4),
                    rows_per_image: Some(h),
                },
                wgpu::Extent3d {
                    width: w,
                    height: h,
                    depth_or_array_layers: 1,
                },
            );
        }
    }

    /// The frame's rectangle in clip space (left, top, right, bottom) for a target of `target` pixels.
    pub(crate) fn clip_rect(frame: (u32, u32), target: (u32, u32), fit: VideoFit) -> [f32; 4] {
        let (fw, fh) = (frame.0 as f32, frame.1 as f32);
        let (tw, th) = (target.0 as f32, target.1 as f32);
        let k = match fit {
            VideoFit::Fit => (tw / fw).min(th / fh),
            VideoFit::Fill => (tw / fw).max(th / fh),
        };
        // Half extents of the picture as a fraction of the target.
        let (hx, hy) = (fw * k / tw, fh * k / th);
        [-hx, hy, hx, -hy]
    }

    /// Draws the frame into an open pass; nothing before the first upload.
    pub(crate) fn draw(
        &self,
        ctx: &GpuContext,
        pass: &mut wgpu::RenderPass<'_>,
        target: (u32, u32),
        window_corner: f32,
    ) {
        let (Some((_, _, size)), Some(group)) = (&self.texture, &self.bind_group) else {
            return;
        };
        let rect = Self::clip_rect(*size, target, self.fit);
        // Second vec4: the target in pixels and the window's corner radius (the picture is cut to the rounded outline
        // too, or a film that fills the window would paint over the transparent corners).
        let bytes: Vec<u8> = rect
            .iter()
            .chain([target.0 as f32, target.1 as f32, window_corner, 0.0].iter())
            .flat_map(|f| f.to_le_bytes())
            .collect();
        ctx.queue().write_buffer(&self.place, 0, &bytes);
        pass.set_pipeline(&self.pipeline);
        pass.set_bind_group(0, group, &[]);
        pass.draw(0..6, 0..1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fit_letterboxes_and_fill_crops() {
        // 16:9 frame in a square target: full width, bars above and below.
        let r = VideoLayer::clip_rect((1600, 900), (1000, 1000), VideoFit::Fit);
        assert!((r[0] + 1.0).abs() < 1e-6 && (r[2] - 1.0).abs() < 1e-6);
        assert!((r[1] - 0.5625).abs() < 1e-6 && (r[3] + 0.5625).abs() < 1e-6);
        // Fill: full height, overflow left and right.
        let r = VideoLayer::clip_rect((1600, 900), (1000, 1000), VideoFit::Fill);
        assert!((r[1] - 1.0).abs() < 1e-6);
        assert!(r[2] > 1.0);
        // Same aspect: the whole target.
        let r = VideoLayer::clip_rect((1920, 1080), (1280, 720), VideoFit::Fit);
        assert!((r[0] + 1.0).abs() < 1e-6 && (r[1] - 1.0).abs() < 1e-6);
    }
}
