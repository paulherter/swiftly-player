//! The GPU way of the video (Windows, Vulkan): the engine draws each picture with OpenGL into a ring of images that
//! this module makes on the window's own Vulkan device, with memory exported as opaque Win32 handles. The engine
//! imports the handles into GL (`GL_EXT_memory_object_win32`) and draws into them; the renderer samples the very same
//! images. No frame is ever copied through the CPU. The module keeps the same names as the Linux one
//! (`dmabuf_import`): `wanted`, `announce`, `Importer`.
//!
//! The textures are made here, when the engine's render thread asks for a ring, and are looked up by the ring's
//! generation when the host sees a frame of it. Needs `VULKAN_EXTERNAL_MEMORY_WIN32` on the wgpu device. Without it the
//! screen keeps the software renderer.
#![allow(unsafe_code)]

use ash::vk;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use swiftly_player_surface::SharedFrame;
use swiftly_player_surface::mpv_gl::{WinImage, new_image};
use swiftly_player_surface::win_ring::RingBook;

static IMPORT_OK: AtomicBool = AtomicBool::new(false);
/// The textures of the rings the engines asked for, by ring number (unique in the process). The engine tells when it
/// frees a ring; the ring is forgotten then.
static RINGS: Mutex<RingBook<wgpu::Texture>> = Mutex::new(RingBook::new());

fn rings() -> std::sync::MutexGuard<'static, RingBook<wgpu::Texture>> {
    RINGS.lock().unwrap_or_else(|e| e.into_inner())
}

fn tracing() -> bool {
    std::env::var_os("SWIFTLY_TRACE").is_some() || std::env::var_os("SWIFTLY_VIDEO_LOG").is_some()
}

/// Whether a new engine should draw on the GPU into shared images (`SWIFTLY_VIDEO_CPU=1` turns it off).
pub fn wanted() -> bool {
    // Opt-in for now: the way is proven on one AMD GPU only (the engine clears each imported image before libmpv draws
    // into it, or that driver crashes in `glFinish`). It runs with `SWIFTLY_VIDEO_PATH=gpu-wgl` until other vendors
    // have been tried.
    IMPORT_OK.load(Ordering::Relaxed)
        && swiftly_render::gpu_video_requested()
        && !std::env::var_os("SWIFTLY_VIDEO_CPU").is_some_and(|v| v != "0")
}

/// Called once with the window's GPU context: when its device is Vulkan with Win32 memory sharing, hands the engine the
/// way to make ring images on it, and the GPU's name so the decoder runs on the same adapter.
pub fn announce(ctx: &swiftly_render::GpuContext) {
    let info = ctx.adapter_info();
    let ok = info.backend == wgpu::Backend::Vulkan
        && ctx
            .device()
            .features()
            .contains(wgpu::Features::VULKAN_EXTERNAL_MEMORY_WIN32);
    if ok {
        let device = ctx.device().clone();
        swiftly_player_surface::mpv_gl::set_ring_allocator(
            Box::new(move |generation, w, h, count| make_ring(&device, generation, w, h, count)),
            Box::new(|generation| rings().release(generation)),
            &info.name,
        );
    }
    IMPORT_OK.store(ok, Ordering::Relaxed);
    if tracing() {
        eprintln!(
            "swiftly-desktop: GPU {} ({:?}), Win32 video sharing {}",
            info.name,
            info.backend,
            if ok { "available" } else { "not available" }
        );
    }
}

fn make_ring(
    device: &wgpu::Device,
    generation: u64,
    width: u32,
    height: u32,
    count: usize,
) -> Result<Vec<WinImage>, String> {
    let mut textures = Vec::new();
    let mut handles = Vec::new();
    for _ in 0..count {
        // When one image fails, the `?` drops what was made so far: the textures free their Vulkan memory and the
        // images close their Win32 handles (nothing is left holding video memory).
        let (texture, image) = make_image(device, width, height)?;
        textures.push(texture);
        handles.push(image);
    }
    rings().insert(generation, textures);
    Ok(handles)
}

fn make_image(
    device: &wgpu::Device,
    width: u32,
    height: u32,
) -> Result<(wgpu::Texture, WinImage), String> {
    let hal = unsafe { device.as_hal::<wgpu::hal::api::Vulkan>() }
        .ok_or("the wgpu device is not a Vulkan one")?;
    let raw = hal.raw_device().clone();
    let instance = hal.shared_instance().raw_instance();
    let phys = hal.raw_physical_device();
    let handle_type = vk::ExternalMemoryHandleTypeFlags::OPAQUE_WIN32;
    unsafe {
        let mut external = vk::ExternalMemoryImageCreateInfo::default().handle_types(handle_type);
        let info = vk::ImageCreateInfo::default()
            .image_type(vk::ImageType::TYPE_2D)
            .format(vk::Format::R8G8B8A8_UNORM)
            .extent(vk::Extent3D {
                width,
                height,
                depth: 1,
            })
            .mip_levels(1)
            .array_layers(1)
            .samples(vk::SampleCountFlags::TYPE_1)
            .tiling(vk::ImageTiling::OPTIMAL)
            .usage(
                vk::ImageUsageFlags::SAMPLED
                    | vk::ImageUsageFlags::COLOR_ATTACHMENT
                    | vk::ImageUsageFlags::TRANSFER_SRC
                    | vk::ImageUsageFlags::TRANSFER_DST,
            )
            .sharing_mode(vk::SharingMode::EXCLUSIVE)
            .initial_layout(vk::ImageLayout::UNDEFINED)
            .push_next(&mut external);
        let image = raw
            .create_image(&info, None)
            .map_err(|e| format!("vkCreateImage: {e}"))?;
        let req = raw.get_image_memory_requirements(image);
        let props = instance.get_physical_device_memory_properties(phys);
        let Some(type_index) = (0..props.memory_type_count).find(|i| {
            req.memory_type_bits & (1 << i) != 0
                && props.memory_types[*i as usize]
                    .property_flags
                    .contains(vk::MemoryPropertyFlags::DEVICE_LOCAL)
        }) else {
            raw.destroy_image(image, None);
            return Err("no device-local memory type for the video image".into());
        };
        let mut export = vk::ExportMemoryAllocateInfo::default().handle_types(handle_type);
        let mut dedicated = vk::MemoryDedicatedAllocateInfo::default().image(image);
        let alloc = vk::MemoryAllocateInfo::default()
            .allocation_size(req.size)
            .memory_type_index(type_index)
            .push_next(&mut export)
            .push_next(&mut dedicated);
        let memory = match raw.allocate_memory(&alloc, None) {
            Ok(m) => m,
            Err(e) => {
                raw.destroy_image(image, None);
                return Err(format!("vkAllocateMemory: {e}"));
            }
        };
        if let Err(e) = raw.bind_image_memory(image, memory, 0) {
            raw.free_memory(memory, None);
            raw.destroy_image(image, None);
            return Err(format!("vkBindImageMemory: {e}"));
        }
        let win32 = ash::khr::external_memory_win32::Device::new(instance, &raw);
        let handle = match win32.get_memory_win32_handle(
            &vk::MemoryGetWin32HandleInfoKHR::default()
                .memory(memory)
                .handle_type(handle_type),
        ) {
            Ok(h) => h,
            Err(e) => {
                raw.free_memory(memory, None);
                raw.destroy_image(image, None);
                return Err(format!("vkGetMemoryWin32HandleKHR: {e}"));
            }
        };
        let size = wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        };
        let hal_desc = wgpu::hal::TextureDescriptor {
            label: Some("video wgl"),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUses::RESOURCE,
            memory_flags: wgpu::hal::MemoryFlags::empty(),
            view_formats: Vec::new(),
        };
        let cleanup = raw.clone();
        let texture = hal.texture_from_raw(
            image,
            &hal_desc,
            Some(Box::new(move || {
                cleanup.destroy_image(image, None);
                cleanup.free_memory(memory, None);
            })),
            wgpu::hal::vulkan::TextureMemory::External,
        );
        let texture = device.create_texture_from_hal::<wgpu::hal::api::Vulkan>(
            texture,
            &wgpu::TextureDescriptor {
                label: Some("video wgl"),
                size,
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Rgba8Unorm,
                usage: wgpu::TextureUsages::TEXTURE_BINDING,
                view_formats: &[],
            },
            // Not "uninitialized": wgpu must not clear an image the engine has already drawn into.
            wgpu::TextureUses::RESOURCE,
        );
        Ok((texture, new_image(handle as usize, req.size, true)))
    }
}

/// The textures of the engine's current ring.
#[derive(Default)]
pub struct Importer {
    generation: Option<u64>,
    textures: Vec<wgpu::Texture>,
    failed: bool,
}

impl Importer {
    /// The texture of the image that holds `frame`. `None` when the ring is unknown (it is not looked up again for the
    /// same ring).
    pub fn texture(
        &mut self,
        _device: &wgpu::Device,
        frame: &SharedFrame,
    ) -> Option<&wgpu::Texture> {
        if self.generation != Some(frame.generation) {
            self.generation = Some(frame.generation);
            let r = rings();
            match r.get(frame.generation) {
                Some(t) => {
                    self.textures = t.to_vec();
                    self.failed = false;
                    if tracing() {
                        eprintln!(
                            "swiftly-desktop: video ring {} shared: {} x {}x{}",
                            frame.generation,
                            self.textures.len(),
                            frame.size.0,
                            frame.size.1
                        );
                    }
                }
                None => {
                    self.textures.clear();
                    self.failed = true;
                    eprintln!(
                        "swiftly-desktop: video ring {} is not known to the renderer",
                        frame.generation
                    );
                }
            }
        }
        if self.failed {
            return None;
        }
        self.textures.get(frame.slot)
    }

    /// Whether the last lookup failed (the screen should fall back to CPU frames).
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
