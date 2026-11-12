//! Window-less rendering for smoke tests and CI: runs the shell for N frames at 60 Hz and draws the last one with the
//! software renderer (the oracle of the goldens). No GPU, no window.

use crate::cli::Options;
use crate::shell::Shell;
use std::time::Instant;
use swiftly_ui::Cx;

/// What a headless run found.
#[derive(Clone, Debug, PartialEq)]
pub struct Report {
    /// Frames run.
    pub frames: u32,
    /// Quads in the last frame.
    pub quads: usize,
    /// The last frame asked for another one (something still moves).
    pub still_moving: bool,
    /// Average CPU time of a frame (build and draw list, without rendering) in ms.
    pub avg_frame_ms: f64,
    /// Size of the rendered image in pixels.
    pub size_px: (u32, u32),
    /// Share of pixels that are not the ground colour (0 = blank).
    pub ink: f64,
}

/// Runs the demo for `opts.frames` frames, renders the last and writes `opts.png` if asked.
pub fn run(opts: &Options) -> Result<Report, String> {
    let frames = opts.frames.unwrap_or(1).max(1);
    let size_px = (
        (opts.size.0 as f32 * opts.scale).round() as u32,
        (opts.size.1 as f32 * opts.scale).round() as u32,
    );
    let mut shell = match opts.home {
        _ if opts.app => Shell::new_suite_state(
            size_px,
            opts.scale,
            Cx::deterministic(),
            opts.form,
            opts.app_state.unwrap_or(crate::home_data::Scenario::Ready),
        ),
        Some(scenario) => Shell::new_home(size_px, opts.scale, Cx::deterministic(), scenario),
        None => Shell::new(size_px, opts.scale, Cx::deterministic()),
    };
    if opts.open_detail && opts.home.is_none() && !opts.app {
        shell.demo_mut().open_detail(0, 2, 0.0);
    }
    if opts.autoplay {
        shell.enable_autoplay();
    }
    let started = Instant::now();
    let (mut last, mut more) = (None, false);
    for i in 0..frames {
        let (list, m) = shell.frame(f64::from(i) * 1000.0 / 60.0);
        last = Some(list);
        more = m;
    }
    let avg_frame_ms = started.elapsed().as_secs_f64() * 1000.0 / f64::from(frames);
    let list = last.ok_or("no frame")?;
    let img = shell.render_software(&list);
    if let Some(path) = &opts.png {
        img.write_png(path)?;
    }
    let ground = img.pixel(0, img.height.saturating_sub(1));
    let mut differing = 0_usize;
    for y in (0..img.height).step_by(3) {
        for x in (0..img.width).step_by(3) {
            if img.pixel(x, y) != ground {
                differing += 1;
            }
        }
    }
    let sampled = (img.width.div_ceil(3)) * (img.height.div_ceil(3));
    Ok(Report {
        frames,
        quads: list.quads().len(),
        still_moving: more,
        avg_frame_ms,
        size_px: (img.width as u32, img.height as u32),
        ink: differing as f64 / sampled.max(1) as f64,
    })
}

/// `--gpu-bench`: the real wgpu renderer into an offscreen texture (no window, no present), paced at 120 Hz by a
/// timer, for `opts.quit_after` seconds (default 10). Prints the same statistics lines as `--stats`. It measures what
/// the shell and the GPU cost per frame, not what the window system adds (vsync, compositor).
pub fn gpu_bench(opts: &Options) -> Result<(), String> {
    use crate::stats::FrameStats;
    use std::time::Duration;
    use swiftly_render::{Color, GpuContext, WgpuRenderer};

    let scale = 2.0_f32;
    let size_px = (
        (opts.size.0 as f32 * scale) as u32,
        (opts.size.1 as f32 * scale) as u32,
    );
    let ctx = GpuContext::headless().map_err(|e| e.to_string())?;
    let info = ctx.adapter_info();
    eprintln!(
        "swiftly-desktop gpu-bench: {} ({:?}), {}x{} px at {scale}x, offscreen, paced at 120 Hz",
        info.name, info.backend, size_px.0, size_px.1
    );
    let format = wgpu::TextureFormat::Rgba8Unorm;
    let mut renderer = WgpuRenderer::new(&ctx, format).map_err(|e| e.to_string())?;
    let texture = ctx.device().create_texture(&wgpu::TextureDescriptor {
        label: Some("gpu-bench target"),
        size: wgpu::Extent3d {
            width: size_px.0,
            height: size_px.1,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
        view_formats: &[],
    });
    let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
    let mut shell = Shell::new(size_px, scale, crate::frame_surface::app_cx());
    if opts.autoplay {
        shell.enable_autoplay();
    }
    let period = 1000.0 / 120.0;
    let mut stats = FrameStats::new(period, 0.0);
    let start = Instant::now();
    let limit = opts.quit_after.unwrap_or(10.0) * 1000.0;
    let mut next = 0.0_f64;
    let mut continuous = false;
    loop {
        let now = start.elapsed().as_secs_f64() * 1000.0;
        if now >= limit {
            break;
        }
        if let Some(line) = stats.report(now) {
            eprintln!("{line}");
        }
        if now < next {
            if next - now > 1.5 {
                std::thread::sleep(Duration::from_secs_f64((next - now - 1.0) / 1000.0));
            } else {
                std::hint::spin_loop();
            }
            continue;
        }
        next = now.max(next) + period;
        let began = Instant::now();
        let (list, more) = shell.frame(now);
        shell.with_sources(|src| {
            renderer.draw(&list, &view, size_px, Color::BLACK, src);
        });
        renderer.wait().map_err(|e| e.to_string())?;
        stats.record(now, began.elapsed().as_secs_f64() * 1000.0, continuous);
        continuous = more;
        if !more {
            // Idle: nothing to draw until an input arrives (there is none here).
            let line = stats.report(limit.min(now + 5000.0));
            if let Some(l) = line {
                eprintln!("{l}");
            }
            break;
        }
    }
    eprintln!("{}", stats.totals());
    Ok(())
}
