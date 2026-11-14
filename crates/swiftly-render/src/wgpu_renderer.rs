// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The GPU renderer of a [`DrawList`]: one instanced draw (six vertices per quad, 176-byte instances read as vertex
//! attributes, so it also runs on GL ES 3) with the pipeline of `quad.wgsl`. Premultiplied "over" blending in sRGB code
//! values, like [`crate::SoftwareRenderer`]. The structure follows the Sequence Studio wgpu renderer (instance buffer
//! that only grows, atlas pages mirrored as textures and updated by dirty rectangle); the shader is new.
//!
//! Targets must be non-sRGB formats (`Rgba8Unorm` or `Bgra8Unorm`), since all colour math is on code values.

use crate::atlas::{Atlas, AtlasFormat};
use crate::draw_list::{DrawList, DrawQuad, QuadKind};
use crate::geometry::{Color, Rect};
use crate::image::RgbaImage;
use crate::software::{SoftwareRenderer, Sources};
use std::fmt;
use std::sync::mpsc;

const SHADER: &str = include_str!("quad.wgsl");

/// What can go wrong on the GPU side.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RenderError {
    /// No adapter (no GPU driver, no software fallback).
    NoAdapter(String),
    /// The device request failed.
    Device(String),
    /// Reading the frame back failed.
    Readback(String),
    /// The surface could not provide a frame.
    Surface(String),
    /// The target format is not supported by this call.
    Format(String),
}

impl fmt::Display for RenderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let (what, why) = match self {
            RenderError::NoAdapter(e) => ("no GPU adapter", e),
            RenderError::Device(e) => ("GPU device", e),
            RenderError::Readback(e) => ("readback", e),
            RenderError::Surface(e) => ("surface", e),
            RenderError::Format(e) => ("target format", e),
        };
        write!(f, "{what}: {why}")
    }
}

impl std::error::Error for RenderError {}

/// A device and queue (plus the adapter they came from).
#[derive(Clone)]
pub struct GpuContext {
    device: wgpu::Device,
    queue: wgpu::Queue,
    adapter: wgpu::Adapter,
}

impl GpuContext {
    /// A context without a window, on the best adapter of Vulkan, DX12, Metal or GL. Blocks.
    pub fn headless() -> Result<GpuContext, RenderError> {
        // One context for the whole process (wgpu devices are shared across threads), and the instance is never dropped.
        // Every instance that also carries the GL backend makes an EGL context per adapter and destroys it when it
        // goes; Mesa's EGL does that racily when several threads create and drop instances at once (measured on Linux:
        // "corrupted double-linked list", SIGSEGV/SIGABRT in `destroy_context` of libgallium, and `BadAccess` in
        // wgpu-hal's EGL `make_current`, at the end of parallel gesture-fuzz runs).
        static CONTEXT: std::sync::OnceLock<Result<GpuContext, RenderError>> =
            std::sync::OnceLock::new();
        CONTEXT
            .get_or_init(|| {
                let mut desc = wgpu::InstanceDescriptor::new_without_display_handle();
                desc.backends = wgpu::Backends::VULKAN
                    | wgpu::Backends::DX12
                    | wgpu::Backends::METAL
                    | wgpu::Backends::GL;
                let instance = Box::leak(Box::new(wgpu::Instance::new(desc)));
                pollster::block_on(GpuContext::from_instance(instance, None))
            })
            .clone()
    }

    /// The device of `instance`; with `surface` the adapter is one that can present to it.
    pub async fn from_instance(
        instance: &wgpu::Instance,
        surface: Option<&wgpu::Surface<'_>>,
    ) -> Result<GpuContext, RenderError> {
        let request = |fallback: bool| {
            instance.request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                compatible_surface: surface,
                force_fallback_adapter: fallback,
                ..Default::default()
            })
        };
        // No real GPU: the software adapter (WARP, llvmpipe, SwiftShader) keeps the wgpu path usable.
        let adapter = match request(false).await {
            Ok(a) => a,
            Err(first) => request(true)
                .await
                .map_err(|_| RenderError::NoAdapter(first.to_string()))?,
        };
        // Downlevel limits keep GL ES 3 working; only the texture size is raised to what the adapter offers.
        let mut limits = wgpu::Limits::downlevel_defaults();
        limits.max_texture_dimension_2d = adapter.limits().max_texture_dimension_2d;
        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                label: Some("swiftly-render"),
                required_limits: limits,
                ..Default::default()
            })
            .await
            .map_err(|e| RenderError::Device(e.to_string()))?;
        Ok(GpuContext {
            device,
            queue,
            adapter,
        })
    }

    /// The device.
    pub fn device(&self) -> &wgpu::Device {
        &self.device
    }
    /// The queue.
    pub fn queue(&self) -> &wgpu::Queue {
        &self.queue
    }
    /// The adapter.
    pub fn adapter(&self) -> &wgpu::Adapter {
        &self.adapter
    }
    /// Name, backend and driver of the adapter.
    pub fn adapter_info(&self) -> wgpu::AdapterInfo {
        self.adapter.get_info()
    }

    /// A surface configuration with a non-sRGB format (the renderer blends code values), `None` if the adapter cannot
    /// present to `surface`.
    pub fn surface_config(
        &self,
        surface: &wgpu::Surface<'_>,
        width: u32,
        height: u32,
    ) -> Option<wgpu::SurfaceConfiguration> {
        let mut config = surface.get_default_config(&self.adapter, width, height)?;
        let caps = surface.get_capabilities(&self.adapter);
        if let Some(f) = caps.formats.iter().copied().find(|f| {
            matches!(
                f,
                wgpu::TextureFormat::Bgra8Unorm | wgpu::TextureFormat::Rgba8Unorm
            )
        }) {
            config.format = f;
        }
        // Lists with frosted glass are uploaded as a finished software picture.
        if caps.usages.contains(wgpu::TextureUsages::COPY_DST) {
            config.usage |= wgpu::TextureUsages::COPY_DST;
        }
        Some(config)
    }
}

/// A mirrored atlas page.
struct PageTexture {
    texture: wgpu::Texture,
    view: wgpu::TextureView,
    size: (u32, u32),
    format: AtlasFormat,
}

fn texel_format(f: AtlasFormat) -> wgpu::TextureFormat {
    match f {
        AtlasFormat::R8 => wgpu::TextureFormat::R8Unorm,
        AtlasFormat::Rgba8 => wgpu::TextureFormat::Rgba8Unorm,
    }
}

fn make_page(
    device: &wgpu::Device,
    size: (u32, u32),
    format: AtlasFormat,
    label: &str,
) -> PageTexture {
    let texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some(label),
        size: wgpu::Extent3d {
            width: size.0.max(1),
            height: size.1.max(1),
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: texel_format(format),
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });
    let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
    PageTexture {
        texture,
        view,
        size,
        format,
    }
}

/// Draws draw lists with wgpu.
pub struct WgpuRenderer {
    ctx: GpuContext,
    format: wgpu::TextureFormat,
    pipeline: wgpu::RenderPipeline,
    bind_layout: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    globals: wgpu::Buffer,
    /// Corner radius of the window outline in pixels (0 = square), see [`WgpuRenderer::set_window_corner`].
    window_corner: f32,
    glyph_page: Option<PageTexture>,
    color_page: Option<PageTexture>,
    image_page: Option<PageTexture>,
    dummy_glyph: PageTexture,
    dummy_color: PageTexture,
    dummy_image: PageTexture,
    instances: Option<(wgpu::Buffer, u64)>,
    bytes: Vec<u8>,
    video: Option<crate::video_layer::VideoLayer>,
}

impl WgpuRenderer {
    /// A renderer for targets of `format` (`Rgba8Unorm` for readback, `Bgra8Unorm` or `Rgba8Unorm` for windows).
    pub fn new(ctx: &GpuContext, format: wgpu::TextureFormat) -> Result<WgpuRenderer, RenderError> {
        if format.is_srgb() {
            return Err(RenderError::Format(format!(
                "{format:?} is sRGB; the renderer blends code values"
            )));
        }
        let device = ctx.device();
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("swiftly-render quad"),
            source: wgpu::ShaderSource::Wgsl(SHADER.into()),
        });
        let tex_entry = |binding| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Texture {
                sample_type: wgpu::TextureSampleType::Float { filterable: true },
                view_dimension: wgpu::TextureViewDimension::D2,
                multisampled: false,
            },
            count: None,
        };
        let bind_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("swiftly-render bindings"),
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
                tex_entry(1),
                tex_entry(2),
                tex_entry(4),
                wgpu::BindGroupLayoutEntry {
                    binding: 3,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("swiftly-render layout"),
            bind_group_layouts: &[Some(&bind_layout)],
            immediate_size: 0,
        });
        let attributes: Vec<wgpu::VertexAttribute> = (0..11)
            .map(|i| wgpu::VertexAttribute {
                format: wgpu::VertexFormat::Float32x4,
                offset: i * 16,
                shader_location: i as u32,
            })
            .collect();
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("swiftly-render quads"),
            layout: Some(&layout),
            vertex: wgpu::VertexState {
                module: &module,
                entry_point: Some("vs_main"),
                compilation_options: Default::default(),
                buffers: &[Some(wgpu::VertexBufferLayout {
                    array_stride: DrawQuad::SIZE as u64,
                    step_mode: wgpu::VertexStepMode::Instance,
                    attributes: &attributes,
                })],
            },
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: Default::default(),
            fragment: Some(wgpu::FragmentState {
                module: &module,
                entry_point: Some("fs_main"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: Some(wgpu::BlendState::PREMULTIPLIED_ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            multiview_mask: None,
            cache: None,
        });
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("swiftly-render sampler"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            address_mode_w: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });
        let globals = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("swiftly-render globals"),
            size: 16,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        Ok(WgpuRenderer {
            ctx: ctx.clone(),
            format,
            pipeline,
            bind_layout,
            sampler,
            globals,
            window_corner: 0.0,
            glyph_page: None,
            color_page: None,
            image_page: None,
            dummy_glyph: make_page(device, (1, 1), AtlasFormat::R8, "dummy glyph page"),
            dummy_color: make_page(
                device,
                (1, 1),
                AtlasFormat::Rgba8,
                "dummy colour glyph page",
            ),
            dummy_image: make_page(device, (1, 1), AtlasFormat::Rgba8, "dummy image page"),
            instances: None,
            bytes: Vec::new(),
            video: None,
        })
    }

    /// Uploads the newest video frame (`w x h` RGBA) into the bottom layer; every later draw shows it under the UI
    /// until [`WgpuRenderer::clear_video`]. The UI must leave the video area transparent. A list with backdrop blur
    /// takes the software path and does not show the layer.
    pub fn upload_video(&mut self, w: u32, h: u32, rgba: &[u8], fit: crate::video_layer::VideoFit) {
        let (ctx, format) = (&self.ctx, self.format);
        let layer = self
            .video
            .get_or_insert_with(|| crate::video_layer::VideoLayer::new(ctx, format));
        layer.fit = fit;
        layer.upload(ctx, w, h, rgba);
    }

    /// Removes the video layer.
    pub fn clear_video(&mut self) {
        self.video = None;
    }

    /// The target format this renderer was made for.
    pub fn format(&self) -> wgpu::TextureFormat {
        self.format
    }

    /// Brings the GPU copy of `page` up to date: all of it the first time or after a size change, then the dirty
    /// rectangle only.
    fn sync_page(ctx: &GpuContext, slot: &mut Option<PageTexture>, page: &dyn Atlas, label: &str) {
        let (size, format) = (page.size(), page.format());
        let dirty = page.take_dirty();
        let fresh = slot
            .as_ref()
            .is_none_or(|p| p.size != size || p.format != format);
        if fresh {
            *slot = Some(make_page(ctx.device(), size, format, label));
        }
        let Some(tex) = slot.as_ref() else { return };
        let region = if fresh {
            Some(crate::atlas::DirtyRect {
                x: 0,
                y: 0,
                w: size.0,
                h: size.1,
            })
        } else {
            dirty
        };
        let Some(r) =
            region.filter(|r| r.w > 0 && r.h > 0 && r.x + r.w <= size.0 && r.y + r.h <= size.1)
        else {
            return;
        };
        let bpt = format.bytes_per_texel() as u32;
        let offset = (u64::from(r.y) * u64::from(size.0) + u64::from(r.x)) * u64::from(bpt);
        let Some(data) = page.pixels().get(offset as usize..) else {
            return;
        };
        ctx.queue().write_texture(
            wgpu::TexelCopyTextureInfo {
                texture: &tex.texture,
                mip_level: 0,
                origin: wgpu::Origin3d {
                    x: r.x,
                    y: r.y,
                    z: 0,
                },
                aspect: wgpu::TextureAspect::All,
            },
            data,
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(size.0 * bpt),
                rows_per_image: Some(r.h),
            },
            wgpu::Extent3d {
                width: r.w,
                height: r.h,
                depth_or_array_layers: 1,
            },
        );
    }

    /// Records and submits one draw of `list` into `target` (a view of `size` pixels, cleared to `clear`) without
    /// waiting for the GPU.
    pub fn draw(
        &mut self,
        list: &DrawList,
        target: &wgpu::TextureView,
        size: (u32, u32),
        clear: Color,
        src: &Sources,
    ) {
        if let Some(p) = src.glyphs {
            Self::sync_page(&self.ctx, &mut self.glyph_page, p, "glyph page");
            if let Some(c) = p.color_page() {
                Self::sync_page(&self.ctx, &mut self.color_page, c, "colour glyph page");
            }
        }
        if let Some(p) = src.images {
            Self::sync_page(&self.ctx, &mut self.image_page, p, "image page");
        }
        // Behind a video the ground is black: the bars the picture leaves above and below (or left and right) of it are
        // part of the film's frame, not of the app's window colour.
        let clear = if self.video.is_some() {
            Color::new(0.0, 0.0, 0.0, 1.0)
        } else {
            clear
        };
        self.bytes.clear();
        // A rounded window clears to transparent (the corners must stay so), which would leave every pixel the screen
        // does not paint see-through: the letterbox of a video, the app's own bars when the controls are away, the
        // whole player before its first frame. So the ground is the first quad: the clear colour over the whole
        // window, cut to the rounded outline like every other quad. The video and the list draw over it.
        let ground = self.window_corner > 0.0;
        if ground {
            let scale = list.scale();
            let (w, h) = (size.0 as f32 / scale, size.1 as f32 / scale);
            let mut g = DrawList::new(w, h, scale);
            g.fill(
                Rect::new(0.0, 0.0, w, h),
                Color::new(clear.r, clear.g, clear.b, 1.0),
                0.0,
            );
            for q in g.quads() {
                q.write_bytes(&mut self.bytes);
            }
        }
        let first = u32::from(ground);
        for q in list.quads() {
            q.write_bytes(&mut self.bytes);
        }
        let device = self.ctx.device();
        let queue = self.ctx.queue();
        let need = self.bytes.len().max(DrawQuad::SIZE) as u64;
        if self.instances.as_ref().is_none_or(|(_, cap)| *cap < need) {
            let cap = need.next_power_of_two().max(16 * DrawQuad::SIZE as u64);
            let buffer = device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("swiftly-render instances"),
                size: cap,
                usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
            self.instances = Some((buffer, cap));
        }
        if let Some((buffer, _)) = &self.instances {
            queue.write_buffer(buffer, 0, &self.bytes);
        }
        let constants: Vec<u8> = [
            size.0 as f32,
            size.1 as f32,
            list.scale(),
            self.window_corner,
        ]
        .iter()
        .flat_map(|f| f.to_le_bytes())
        .collect();
        queue.write_buffer(&self.globals, 0, &constants);

        let glyph_view = self.glyph_page.as_ref().unwrap_or(&self.dummy_glyph);
        let image_view = self.image_page.as_ref().unwrap_or(&self.dummy_image);
        let color_view = self.color_page.as_ref().unwrap_or(&self.dummy_color);
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("swiftly-render bindings"),
            layout: &self.bind_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: self.globals.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(&glyph_view.view),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::TextureView(&image_view.view),
                },
                wgpu::BindGroupEntry {
                    binding: 3,
                    resource: wgpu::BindingResource::Sampler(&self.sampler),
                },
                wgpu::BindGroupEntry {
                    binding: 4,
                    resource: wgpu::BindingResource::TextureView(&color_view.view),
                },
            ],
        });
        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("swiftly-render"),
        });
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("swiftly-render pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: target,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: if self.window_corner > 0.0 {
                                0.0
                            } else {
                                f64::from(clear.r)
                            },
                            g: if self.window_corner > 0.0 {
                                0.0
                            } else {
                                f64::from(clear.g)
                            },
                            b: if self.window_corner > 0.0 {
                                0.0
                            } else {
                                f64::from(clear.b)
                            },
                            // Premultiplied: a rounded window has transparent corners, so the ground is a quad of the list.
                            a: if self.window_corner > 0.0 { 0.0 } else { 1.0 },
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
            if let (true, Some((buffer, _))) = (ground, &self.instances) {
                pass.set_pipeline(&self.pipeline);
                pass.set_bind_group(0, &bind_group, &[]);
                pass.set_vertex_buffer(0, buffer.slice(..));
                pass.draw(0..6, 0..1);
            }
            if let Some(v) = &self.video {
                v.draw(&self.ctx, &mut pass, size, self.window_corner);
            }
            if let (false, Some((buffer, _))) = (list.quads().is_empty(), &self.instances) {
                pass.set_pipeline(&self.pipeline);
                pass.set_bind_group(0, &bind_group, &[]);
                pass.set_vertex_buffer(0, buffer.slice(..));
                pass.draw(0..6, first..first + list.quads().len() as u32);
            }
        }
        queue.submit(Some(encoder.finish()));
    }

    /// Cuts every following frame to a rounded rectangle of `px` pixels radius (0 = a plain rectangle). The area outside
    /// the corners is transparent, so the surface must be configured with a premultiplied alpha mode and the list must
    /// start with a quad that covers the window (the screens' ground does).
    pub fn set_window_corner(&mut self, px: f32) {
        self.window_corner = px.max(0.0);
    }

    /// True when `list` holds frosted glass (a backdrop blur quad).
    pub fn has_blur(list: &DrawList) -> bool {
        list.quads()
            .iter()
            .any(|q| q.kind == QuadKind::BackdropBlur)
    }

    /// Draws `list` into `texture`. A list with backdrop blur is rendered by the software renderer and uploaded, so the
    /// blur is bit-identical to the software path on every GPU (a GPU box blur would need a render-to-texture detour
    /// per glass quad; decided against it, see NOTES.md). `texture` needs `COPY_DST` for that case.
    fn draw_to_texture(
        &mut self,
        list: &DrawList,
        texture: &wgpu::Texture,
        clear: Color,
        src: &Sources,
    ) {
        let size = (texture.width(), texture.height());
        let can_upload = texture.usage().contains(wgpu::TextureUsages::COPY_DST);
        if Self::has_blur(list) && can_upload && list.pixel_size() == size {
            let mut img = SoftwareRenderer::render(list, clear, src);
            if self.format == wgpu::TextureFormat::Bgra8Unorm {
                for i in (0..img.pixels.len()).step_by(4) {
                    img.pixels.swap(i, i + 2);
                }
            }
            self.ctx.queue().write_texture(
                texture.as_image_copy(),
                &img.pixels,
                wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(size.0 * 4),
                    rows_per_image: Some(size.1),
                },
                wgpu::Extent3d {
                    width: size.0,
                    height: size.1,
                    depth_or_array_layers: 1,
                },
            );
            return;
        }
        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
        self.draw(list, &view, size, clear, src);
    }

    /// Blocks until everything submitted so far has finished.
    pub fn wait(&self) -> Result<(), RenderError> {
        self.ctx
            .device()
            .poll(wgpu::PollType::wait_indefinitely())
            .map(|_| ())
            .map_err(|e| RenderError::Readback(e.to_string()))
    }

    /// Draws `list` into a fresh texture of its pixel size and reads it back as an opaque image (headless tests and
    /// screenshots). Needs a renderer made for `Rgba8Unorm` or `Bgra8Unorm`.
    pub fn render_to_image(
        &mut self,
        list: &DrawList,
        clear: Color,
        src: &Sources,
    ) -> Result<RgbaImage, RenderError> {
        let swap = match self.format {
            wgpu::TextureFormat::Rgba8Unorm => false,
            wgpu::TextureFormat::Bgra8Unorm => true,
            other => return Err(RenderError::Format(format!("cannot read back {other:?}"))),
        };
        let (width, height) = list.pixel_size();
        let texture = self.ctx.device().create_texture(&wgpu::TextureDescriptor {
            label: Some("swiftly-render offscreen"),
            size: wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: self.format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                | wgpu::TextureUsages::COPY_SRC
                | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        self.draw_to_texture(list, &texture, clear, src);

        let row = width as usize * 4;
        let padded = row.next_multiple_of(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT as usize);
        let staging = self.ctx.device().create_buffer(&wgpu::BufferDescriptor {
            label: Some("swiftly-render readback"),
            size: (padded * height as usize) as u64,
            usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let mut encoder =
            self.ctx
                .device()
                .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                    label: Some("readback"),
                });
        encoder.copy_texture_to_buffer(
            texture.as_image_copy(),
            wgpu::TexelCopyBufferInfo {
                buffer: &staging,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(padded as u32),
                    rows_per_image: Some(height),
                },
            },
            wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
        );
        self.ctx.queue().submit(Some(encoder.finish()));
        let (tx, rx) = mpsc::channel();
        staging
            .slice(..)
            .map_async(wgpu::MapMode::Read, move |result| {
                // The receiver waits below; a closed channel only means the caller gave up.
                let _ = tx.send(result);
            });
        self.wait()?;
        rx.recv()
            .map_err(|e| RenderError::Readback(e.to_string()))?
            .map_err(|e| RenderError::Readback(e.to_string()))?;
        let mut pixels = Vec::with_capacity(row * height as usize);
        {
            let mapped = staging
                .slice(..)
                .get_mapped_range()
                .map_err(|e| RenderError::Readback(e.to_string()))?;
            for r in 0..height as usize {
                pixels.extend_from_slice(&mapped[r * padded..r * padded + row]);
            }
        }
        staging.unmap();
        for px in pixels.as_chunks_mut::<4>().0 {
            if swap {
                px.swap(0, 2);
            }
            px[3] = 255;
        }
        Ok(RgbaImage {
            width: width as usize,
            height: height as usize,
            pixels,
        })
    }

    /// Draws `list` onto the next frame of a configured `surface` and presents it. The surface must use the format
    /// this renderer was made for (see [`GpuContext::surface_config`]). Not covered by the headless tests.
    pub fn render_to_surface(
        &mut self,
        surface: &wgpu::Surface<'_>,
        list: &DrawList,
        clear: Color,
        src: &Sources,
    ) -> Result<(), RenderError> {
        let frame = match surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(f)
            | wgpu::CurrentSurfaceTexture::Suboptimal(f) => f,
            other => return Err(RenderError::Surface(format!("{other:?}"))),
        };
        self.draw_to_texture(list, &frame.texture, clear, src);
        self.ctx.queue().present(frame);
        Ok(())
    }
}
