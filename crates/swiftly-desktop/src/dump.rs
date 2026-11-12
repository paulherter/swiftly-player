//! `--dump-frame`: reads the presented swapchain texture back to a PNG, so the real window path can be checked
//! without an OS screenshot (those are blank for flip-model/DirectComposition windows).

use std::path::Path;
use swiftly_render::{GpuContext, RgbaImage};

/// Copies `texture` (the swapchain image of `format`, needs `COPY_SRC`) into a buffer, maps it and writes a PNG.
/// Prints `dump-frame: WxH px, <format>` to stderr.
pub fn dump_texture(
    ctx: &GpuContext,
    texture: &wgpu::Texture,
    format: wgpu::TextureFormat,
    path: &Path,
) -> Result<(), String> {
    let swap = match format {
        wgpu::TextureFormat::Rgba8Unorm => false,
        wgpu::TextureFormat::Bgra8Unorm => true,
        other => return Err(format!("cannot read back {other:?}")),
    };
    if !texture.usage().contains(wgpu::TextureUsages::COPY_SRC) {
        return Err("the swapchain does not allow COPY_SRC".to_owned());
    }
    let (width, height) = (texture.width(), texture.height());
    let row = width as usize * 4;
    let padded = row.next_multiple_of(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT as usize);
    let device = ctx.device();
    let staging = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("dump-frame readback"),
        size: (padded * height as usize) as u64,
        usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
        label: Some("dump-frame"),
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
    ctx.queue().submit(Some(encoder.finish()));
    let (tx, rx) = std::sync::mpsc::channel();
    staging.slice(..).map_async(wgpu::MapMode::Read, move |r| {
        let _ = tx.send(r);
    });
    device
        .poll(wgpu::PollType::wait_indefinitely())
        .map_err(|e| e.to_string())?;
    rx.recv()
        .map_err(|e| e.to_string())?
        .map_err(|e| e.to_string())?;
    let mut pixels = Vec::with_capacity(row * height as usize);
    {
        let mapped = staging
            .slice(..)
            .get_mapped_range()
            .map_err(|e| e.to_string())?;
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
    let img = RgbaImage {
        width: width as usize,
        height: height as usize,
        pixels,
    };
    img.write_png(path)?;
    eprintln!(
        "dump-frame: {width}x{height} px, {format:?}, {}",
        path.display()
    );
    Ok(())
}
