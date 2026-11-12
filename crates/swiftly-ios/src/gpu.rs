//! wgpu/Metal presentation on the host's `CAMetalLayer` (iOS and tvOS only).
#![allow(unsafe_code)]

use std::ffi::c_void;
use std::sync::Arc;

use swiftly_render::{Color, DrawList, GpuContext, WgpuRenderer};

use crate::host::Host;

const CLEAR: Color = Color {
    r: 0.0627451,
    g: 0.0627451,
    b: 0.0627451,
    a: 1.0,
};

/// The device, surface and renderer of one layer.
pub struct Gpu {
    surface: wgpu::Surface<'static>,
    ctx: GpuContext,
    renderer: WgpuRenderer,
    config: wgpu::SurfaceConfiguration,
    frames: u64,
    /// The picture lies over a video layer: clear to transparent.
    transparent: bool,
}

impl Gpu {
    /// Creates the Metal device and configures the layer at `w`x`h` pixels.
    ///
    /// # Safety
    /// `layer` must be a valid `CAMetalLayer` that outlives the returned value.
    pub unsafe fn new(
        layer: *mut c_void,
        w: u32,
        h: u32,
        transparent: bool,
    ) -> Result<Gpu, String> {
        let mut desc = wgpu::InstanceDescriptor::new_without_display_handle();
        desc.backends = wgpu::Backends::METAL;
        desc.flags = wgpu::InstanceFlags::empty();
        let instance = wgpu::Instance::new(desc);
        let surface = unsafe {
            instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::CoreAnimationLayer(layer))
        }
        .map_err(|e| format!("create_surface: {e}"))?;
        let ctx = pollster::block_on(GpuContext::from_instance(&instance, Some(&surface)))
            .map_err(|e| e.to_string())?;
        let ai = ctx.adapter_info();
        eprintln!(
            "SwiftlyRust: adapter {:?} {:?} {:?}",
            ai.backend, ai.name, ai.device_type
        );
        ctx.device()
            .on_uncaptured_error(Arc::new(|e| eprintln!("SwiftlyRust: wgpu error: {e}")));
        let mut config = ctx
            .surface_config(&surface, w.max(1), h.max(1))
            .ok_or("the adapter cannot present to this layer")?;
        config.present_mode = wgpu::PresentMode::Fifo;
        config.alpha_mode = wgpu::CompositeAlphaMode::Opaque;
        if transparent {
            let caps = surface.get_capabilities(ctx.adapter());
            if let Some(m) = [
                wgpu::CompositeAlphaMode::PreMultiplied,
                wgpu::CompositeAlphaMode::PostMultiplied,
            ]
            .into_iter()
            .find(|m| caps.alpha_modes.contains(m))
            {
                config.alpha_mode = m;
            }
        }
        config.desired_maximum_frame_latency = 2;
        surface.configure(ctx.device(), &config);
        eprintln!(
            "SwiftlyRust: layer configured {:?} {:?} {}x{}",
            config.format, config.present_mode, config.width, config.height
        );
        let renderer = WgpuRenderer::new(&ctx, config.format).map_err(|e| e.to_string())?;
        let transparent = transparent && config.alpha_mode != wgpu::CompositeAlphaMode::Opaque;
        Ok(Gpu {
            surface,
            ctx,
            renderer,
            config,
            frames: 0,
            transparent,
        })
    }

    /// The layer's drawable size changed.
    pub fn resize(&mut self, w: u32, h: u32) {
        self.config.width = w.max(1);
        self.config.height = h.max(1);
        self.surface.configure(self.ctx.device(), &self.config);
    }

    /// Draws `list`; `false` when no frame could be presented (the host asks again).
    pub fn draw(&mut self, host: &Host, list: &DrawList) -> bool {
        use wgpu::CurrentSurfaceTexture as C;
        let frame = match self.surface.get_current_texture() {
            C::Success(f) | C::Suboptimal(f) => f,
            C::Outdated | C::Lost => {
                self.resize(self.config.width, self.config.height);
                return false;
            }
            C::Occluded => return true,
            C::Timeout | C::Validation => return false,
        };
        let size = (frame.texture.width(), frame.texture.height());
        let view = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        let clear = if self.transparent {
            Color {
                r: 0.0,
                g: 0.0,
                b: 0.0,
                a: 0.0,
            }
        } else {
            CLEAR
        };
        host.shell()
            .with_sources(|src| self.renderer.draw(list, &view, size, clear, src));
        self.ctx.queue().present(frame);
        if self.frames == 0 {
            eprintln!(
                "SwiftlyRust: first frame presented, {} quads, {}x{}",
                list.quads().len(),
                size.0,
                size.1
            );
        }
        self.frames += 1;
        true
    }
}
