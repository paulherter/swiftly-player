//! The GPU way of the video (Linux, Vulkan): the engine draws each picture into a ring of DMA-bufs and this module
//! imports those buffers into wgpu as textures, so the renderer samples the picture where the GPU already holds it. No
//! frame is ever copied through the CPU. One import per buffer and ring (a new ring follows a size change); after that a
//! new frame is only the number of the buffer that holds it.
//!
//! Needs `VULKAN_EXTERNAL_MEMORY_DMA_BUF` on the wgpu device (asked for in `swiftly-render` when the driver has it) and
//! the engine's render node to be the GPU wgpu draws on. Without either the screen keeps the software renderer.
#![allow(unsafe_code)]

use std::sync::atomic::{AtomicBool, Ordering};
use swiftly_player_surface::SharedFrame;

static IMPORT_OK: AtomicBool = AtomicBool::new(false);

/// Whether a new engine should draw on the GPU into shared buffers (`SWIFTLY_VIDEO_CPU=1` or `SWIFTLY_VIDEO_PATH=cpu`
/// turn it off).
pub fn wanted() -> bool {
    IMPORT_OK.load(Ordering::Relaxed)
}

/// Called once with the window's GPU context: remembers whether its device can import DMA-bufs and which render node
/// is that GPU's, so the engine draws on the same one.
pub fn announce(ctx: &swiftly_render::GpuContext) {
    let info = ctx.adapter_info();
    let ok = info.backend == wgpu::Backend::Vulkan
        && ctx
            .device()
            .features()
            .contains(wgpu::Features::VULKAN_EXTERNAL_MEMORY_DMA_BUF);
    if let Some(node) = render_node_of(info.vendor, info.device) {
        swiftly_player_surface::mpv_gl::prefer_render_node(node);
    }
    IMPORT_OK.store(ok, Ordering::Relaxed);
    if std::env::var_os("SWIFTLY_TRACE").is_some()
        || std::env::var_os("SWIFTLY_VIDEO_LOG").is_some()
    {
        eprintln!(
            "swiftly-desktop: GPU {} ({:?}), DMA-buf video import {}",
            info.name,
            info.backend,
            if ok { "available" } else { "not available" }
        );
    }
}

/// The `/dev/dri/renderD*` node of the PCI device `vendor:device`.
fn render_node_of(vendor: u32, device: u32) -> Option<std::path::PathBuf> {
    let read = |p: &std::path::Path| {
        std::fs::read_to_string(p)
            .ok()
            .and_then(|t| u32::from_str_radix(t.trim().trim_start_matches("0x"), 16).ok())
    };
    std::fs::read_dir("/sys/class/drm")
        .ok()?
        .filter_map(|e| e.ok())
        .filter(|e| e.file_name().to_string_lossy().starts_with("renderD"))
        .find(|e| {
            let d = e.path().join("device");
            read(&d.join("vendor")) == Some(vendor) && read(&d.join("device")) == Some(device)
        })
        .map(|e| std::path::Path::new("/dev/dri").join(e.file_name()))
}

/// The imported textures of the engine's current ring.
#[derive(Default)]
pub struct Importer {
    generation: Option<u64>,
    textures: Vec<wgpu::Texture>,
    failed: bool,
}

impl Importer {
    /// The texture of the buffer that holds `frame`, importing the ring first when it is a new one. `None` when the
    /// import failed (it is not tried again for the same ring).
    pub fn texture(
        &mut self,
        device: &wgpu::Device,
        frame: &SharedFrame,
    ) -> Option<&wgpu::Texture> {
        if self.generation != Some(frame.generation) {
            self.generation = Some(frame.generation);
            self.failed = false;
            self.textures.clear();
            match import_ring(device, frame) {
                Ok(t) => {
                    self.textures = t;
                    if std::env::var_os("SWIFTLY_TRACE").is_some()
                        || std::env::var_os("SWIFTLY_VIDEO_LOG").is_some()
                    {
                        let i = &frame.images[0];
                        eprintln!(
                            "swiftly-desktop: video ring {} imported: {} x {}x{} (modifier {:#x}, stride {})",
                            frame.generation,
                            frame.images.len(),
                            i.width,
                            i.height,
                            i.modifier,
                            i.stride
                        );
                    }
                }
                Err(e) => {
                    self.failed = true;
                    eprintln!("swiftly-desktop: importing the video buffers failed: {e}");
                }
            }
        }
        if self.failed {
            return None;
        }
        self.textures.get(frame.slot)
    }

    /// Whether the last import failed (the screen should fall back to CPU frames).
    pub fn failed(&self) -> bool {
        self.failed
    }

    /// Forgets the ring (a new play starts, or the layer is removed).
    pub fn clear(&mut self) {
        self.generation = None;
        self.textures.clear();
        self.failed = false;
    }
}

fn import_ring(device: &wgpu::Device, frame: &SharedFrame) -> Result<Vec<wgpu::Texture>, String> {
    let hal = unsafe { device.as_hal::<wgpu::hal::api::Vulkan>() }
        .ok_or("the wgpu device is not a Vulkan one")?;
    let mut out = Vec::new();
    for image in frame.images.iter() {
        let size = wgpu::Extent3d {
            width: image.width,
            height: image.height,
            depth_or_array_layers: 1,
        };
        let fd = image
            .fd
            .try_clone()
            .map_err(|e| format!("dup of the buffer: {e}"))?;
        let hal_desc = wgpu::hal::TextureDescriptor {
            label: Some("video dmabuf"),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUses::RESOURCE,
            memory_flags: wgpu::hal::MemoryFlags::empty(),
            view_formats: Vec::new(),
        };
        // Vulkan owns the duplicate from here on.
        let texture = unsafe {
            hal.texture_from_dmabuf_fd(
                fd,
                &hal_desc,
                image.modifier,
                u64::from(image.stride),
                u64::from(image.offset),
            )
        }
        .map_err(|e| format!("vkImportMemory: {e:?}"))?;
        let texture = unsafe {
            device.create_texture_from_hal::<wgpu::hal::api::Vulkan>(
                texture,
                &wgpu::TextureDescriptor {
                    label: Some("video dmabuf"),
                    size,
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension: wgpu::TextureDimension::D2,
                    format: wgpu::TextureFormat::Rgba8Unorm,
                    usage: wgpu::TextureUsages::TEXTURE_BINDING,
                    view_formats: &[],
                },
                // Not "uninitialized": wgpu must not clear a buffer the engine has already drawn into. A linear
                // buffer has no compression state, so the sampling layout holds whatever the engine wrote last.
                wgpu::TextureUses::RESOURCE,
            )
        };
        out.push(texture);
    }
    Ok(out)
}
