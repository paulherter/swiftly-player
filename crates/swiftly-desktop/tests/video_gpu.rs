//! The live player draws video on the GPU at full resolution. A real H.264 test pattern (hard edges, 1080p and 4K) goes
//! through the app's own path (libmpv -> `MpvFeed` -> `PlayerScreen::live` -> `GpuVideoHost` -> wgpu bottom layer) and
//! is read back: it must be lit, the edges must be sharp, and the delivered frame must be the source (or window)
//! size, not the 1280x720 of the CPU path. The CPU path stays as the fallback and is measured next to it.
//! Skips without libmpv, ffmpeg or a GPU. `SWIFTLY_TEST_CLIP_DIR` names a folder with `edge1080.mkv` and `edge4k.mkv`
//! (the Windows VM has no encoder). `bench_live_video` (ignored) prints the before/after numbers.
#![cfg(feature = "mpv")]
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::arc_with_non_send_sync
)]

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use swiftly_desktop::frame_surface::{GpuVideoHost, app_cx};
use swiftly_desktop::hub::ImageHub;
use swiftly_desktop::live_play::MpvFeed;
use swiftly_desktop::player_screen::{LiveEngine, PlayerScreen};
use swiftly_images::fixture::FixtureImages;
use swiftly_images::{Device, ImageLoader};
use swiftly_jellyfin::{PlayMethod, ReportPlan};
use swiftly_layout::Size;
use swiftly_model::MediaStream;
use swiftly_playback::engine::PlaybackEngine;
use swiftly_playback::player_state::EngineRequest;
use swiftly_player_surface::SurfaceEngine;
use swiftly_player_surface::mpv::MpvEngine;
use swiftly_render::{Color, GpuContext, RgbaImage, Sources, WgpuRenderer};
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_ui::{Cx, Env, Idiom};
use swiftly_vm::{PlayerSpec, ReportMessage, Reporter};

struct Quiet;
impl Reporter for Quiet {
    fn report(&self, _message: ReportMessage) {}
}

/// A test pattern: dark ground and a white box with hard vertical edges at 25 % and 75 % of the width.
fn clip(name: &str, w: u32, h: u32) -> Option<PathBuf> {
    clip_with(name, w, h, &["-pix_fmt", "yuv420p"])
}

/// The same pattern with the encoder's pixel format and colour tags (10-bit HDR10: `yuv420p10le`, BT.2020, PQ).
fn clip_with(name: &str, w: u32, h: u32, format: &[&str]) -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("SWIFTLY_TEST_CLIP_DIR").map(PathBuf::from) {
        return Some(dir.join(name));
    }
    let dir = std::env::temp_dir().join(format!("swiftly-gpu-clips-{}", std::process::id()));
    std::fs::create_dir_all(&dir).ok()?;
    let out = dir.join(name);
    let graph = format!(
        "color=c=0x202020:s={w}x{h}:r=25:d=8,drawbox=x={}:y=0:w={}:h={h}:color=white:t=fill",
        w / 4,
        w / 2
    );
    let ok = std::process::Command::new("ffmpeg")
        .args([
            "-v",
            "quiet",
            "-y",
            "-f",
            "lavfi",
            "-i",
            &graph,
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-crf",
            "14",
            "-g",
            "25",
        ])
        .args(format)
        .arg(&out)
        .status()
        .is_ok_and(|s| s.success());
    ok.then_some(out)
}

fn busy_cx() -> Cx {
    let cx = app_cx();
    let loader = ImageLoader::new(Arc::new(FixtureImages), None, Device::Mac);
    let hub = ImageHub::new(Box::new(loader), &cx, 1.0, Device::Mac);
    std::mem::forget(hub);
    cx
}

fn spec(file: &Path) -> PlayerSpec {
    PlayerSpec {
        item_id: "edge".into(),
        title: "Edge".into(),
        plan: ReportPlan {
            play_session_id: None,
            media_source_id: None,
            method: PlayMethod::DirectPlay,
        },
        request: EngineRequest {
            item_id: "edge".into(),
            streams: vec![MediaStream {
                index: Some(0),
                type_: Some("Video".into()),
                codec: Some("h264".into()),
                ..MediaStream::default()
            }],
            runtime: 8.0,
            subtitle_files: Vec::new(),
            url: file.to_string_lossy().into_owned(),
            headers: Vec::new(),
            software_decode: false,
            buffer_level: BufferLevel::Normal,
            frame_rate_match: false,
            external_track_id_base: 1000,
        },
        start_at: 0.0,
        audio_index: None,
        subtitle_index: -1,
        next: None,
        series_id: None,
        track_title: None,
        downloaded: false,
    }
}

/// CPU seconds this process has used: /proc on Linux, PowerShell's process object on Windows (a slow call, so it
/// is only used at the start and the end of a run); `None` elsewhere.
fn cpu_seconds() -> Option<f64> {
    if cfg!(windows) {
        let out = std::process::Command::new("powershell")
            .args([
                "-NoProfile",
                "-Command",
                &format!(
                    "(Get-Process -Id {}).TotalProcessorTime.TotalSeconds",
                    std::process::id()
                ),
            ])
            .output()
            .ok()?;
        return String::from_utf8_lossy(&out.stdout)
            .trim()
            .replace(',', ".")
            .parse()
            .ok();
    }
    let stat = std::fs::read_to_string("/proc/self/stat").ok()?;
    let rest = stat.rsplit_once(')')?.1;
    let f: Vec<&str> = rest.split_whitespace().collect();
    let (u, s): (f64, f64) = (f.get(11)?.parse().ok()?, f.get(12)?.parse().ok()?);
    Some((u + s) / 100.0)
}

fn pct(v: &mut [f64], p: f64) -> f64 {
    v.sort_by(f64::total_cmp);
    v.get(((v.len() as f64 - 1.0) * p) as usize)
        .copied()
        .unwrap_or(0.0)
}

struct Run {
    shot: RgbaImage,
    /// Size of the last frame the engine delivered.
    delivered: (u32, u32),
    frames: u64,
    secs: f64,
    ticks: u32,
    late: u32,
    work: Vec<f64>,
    cpu: Option<f64>,
    drops: (u64, u64),
}

/// Plays `file` for `secs` through the live player screen in a window of `window` pixels at 60 Hz, as the app does:
/// the GPU host announces the window, the screen hands frames over, the host uploads and draws into an offscreen target.
fn run(ctx: &GpuContext, cx: &Cx, file: &Path, window: (u32, u32), gpu: bool, secs: f64) -> Run {
    let env = Env::new(
        Size::new(window.0 as f32, window.1 as f32),
        1.0,
        Idiom::Desktop,
    );
    let engine = Arc::new(MpvEngine::new().expect("libmpv"));
    let feed = Arc::new(MpvFeed::new(Arc::clone(&engine)));
    let mut screen = PlayerScreen::live(
        env,
        cx.clone(),
        0.0,
        spec(file),
        ("Edge".into(), "test".into()),
        Arc::clone(&engine) as Arc<dyn PlaybackEngine>,
        Arc::clone(&feed) as Arc<dyn LiveEngine>,
        Arc::new(Quiet),
        |_| {},
    );
    let mut renderer = WgpuRenderer::new(ctx, wgpu::TextureFormat::Rgba8Unorm).expect("renderer");
    let target = ctx.device().create_texture(&wgpu::TextureDescriptor {
        label: Some("video test target"),
        size: wgpu::Extent3d {
            width: window.0,
            height: window.1,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
        view_formats: &[],
    });
    let view = target.create_view(&wgpu::TextureViewDescriptor::default());
    let host = if gpu {
        GpuVideoHost::new(ctx.device().limits().max_texture_dimension_2d)
    } else {
        None
    };
    assert_eq!(host.is_some(), gpu, "the GPU path can start here");
    let (mut work, mut delivered, mut ticks, mut late) = (Vec::new(), (0, 0), 0_u32, 0_u32);
    let (t0, tick) = (Instant::now(), Duration::from_micros(16_667));
    let mut warm_cpu = None;
    while t0.elapsed().as_secs_f64() < secs {
        let target_time = t0 + tick * ticks;
        let began = Instant::now();
        if let Some(h) = &host {
            h.announce(&cx.video, window);
        }
        let now_ms = t0.elapsed().as_secs_f64() * 1000.0;
        let (list, _) = screen.frame(now_ms);
        if let Some(f) = cx.video.borrow().pending.as_ref() {
            delivered = (f.w, f.h);
        }
        if let Some(h) = &host {
            h.sync(&cx.video, &mut renderer);
        }
        {
            let (ts, im) = (cx.text.borrow(), cx.images.borrow());
            renderer.draw(
                &list,
                &view,
                window,
                Color::BLACK,
                &Sources {
                    glyphs: Some(&ts.atlas),
                    images: Some(&im.page),
                },
            );
        }
        renderer.wait().expect("gpu wait");
        if now_ms > 1500.0 {
            work.push(began.elapsed().as_secs_f64() * 1000.0);
            if warm_cpu.is_none() {
                let at = Instant::now();
                warm_cpu = Some((cpu_seconds(), at));
            }
        }
        ticks += 1;
        if Instant::now() > target_time + tick {
            late += 1;
        } else {
            std::thread::sleep(target_time.saturating_duration_since(Instant::now()));
        }
    }
    let wall = t0.elapsed().as_secs_f64();
    let end = Instant::now();
    let cpu = match (warm_cpu, cpu_seconds()) {
        (Some((Some(c1), at)), Some(c2)) => {
            Some((c2 - c1) / end.duration_since(at).as_secs_f64().max(0.001) * 100.0)
        }
        _ => None,
    };
    let (list, _) = screen.frame(wall * 1000.0);
    if let Some(h) = &host {
        h.announce(&cx.video, window);
        h.sync(&cx.video, &mut renderer);
    }
    let shot = {
        let (ts, im) = (cx.text.borrow(), cx.images.borrow());
        renderer
            .render_to_image(
                &list,
                Color::BLACK,
                &Sources {
                    glyphs: Some(&ts.atlas),
                    images: Some(&im.page),
                },
            )
            .expect("readback")
    };
    let st = engine.stats();
    Run {
        shot,
        delivered,
        frames: screen.video_frames(),
        secs: wall,
        ticks,
        late,
        work,
        cpu,
        drops: (st.decoder_drops, st.output_drops),
    }
}

fn luma(img: &RgbaImage, x: usize, y: usize) -> f32 {
    let p = img.pixel(x, y);
    0.2126 * f32::from(p[0]) + 0.7152 * f32::from(p[1]) + 0.0722 * f32::from(p[2])
}

/// How many pixels the white box's hard edge at `x_edge` needs to go from 10 % to 90 % (rows 36 %-40 % of the height,
/// away from the controls); 0 at a perfect 1:1 edge, about the scale factor when the picture is stretched.
fn edge_width(img: &RgbaImage, x_edge: usize) -> f32 {
    let mut total = 0.0;
    let rows: Vec<usize> = (img.height * 36 / 100..img.height * 40 / 100).collect();
    for &y in &rows {
        let mean =
            |a: usize, b: usize| (a..b).map(|x| luma(img, x, y)).sum::<f32>() / (b - a) as f32;
        let (lo, hi) = (
            mean(x_edge - 30, x_edge - 10),
            mean(x_edge + 10, x_edge + 30),
        );
        let d = hi - lo;
        assert!(d > 80.0, "the box edge is not there (step {d:.0})");
        total += (x_edge - 24..x_edge + 24)
            .filter(|&x| (luma(img, x, y) - lo) / d > 0.1 && (luma(img, x, y) - lo) / d < 0.9)
            .count() as f32;
    }
    total / rows.len() as f32
}

fn lit_share(img: &RgbaImage) -> f64 {
    let (x0, x1, y0, y1) = (
        img.width * 3 / 10,
        img.width * 7 / 10,
        img.height * 3 / 10,
        img.height * 7 / 10,
    );
    let (mut lit, mut all) = (0_u32, 0_u32);
    for y in (y0..y1).step_by(3) {
        for x in (x0..x1).step_by(3) {
            let p = img.pixel(x, y);
            lit += u32::from(p[0] > 24 || p[1] > 24 || p[2] > 24);
            all += 1;
        }
    }
    f64::from(lit) / f64::from(all)
}

fn setup() -> Option<(GpuContext, PathBuf, PathBuf)> {
    if MpvEngine::new().is_err() {
        eprintln!("no libmpv: skipped");
        return None;
    }
    let Ok(ctx) = GpuContext::headless() else {
        eprintln!("no GPU adapter: skipped");
        return None;
    };
    let (Some(a), Some(b)) = (
        clip("edge1080.mkv", 1920, 1080),
        clip("edge4k.mkv", 3840, 2160),
    ) else {
        eprintln!("no ffmpeg: skipped");
        return None;
    };
    Some((ctx, a, b))
}

fn keep(name: &str, img: &RgbaImage) {
    if let Some(dir) = std::env::var_os("SWIFTLY_TEST_PNG_DIR") {
        let _ = std::fs::create_dir_all(&dir);
        img.write_png(&PathBuf::from(dir).join(format!("{name}.png")))
            .unwrap();
    }
}

#[test]
fn the_gpu_layer_shows_1080p_at_full_resolution() {
    let Some((ctx, f1080, _)) = setup() else {
        return;
    };
    let cx = busy_cx();
    let gpu = run(&ctx, &cx, &f1080, (1920, 1080), true, 3.5);
    keep("gpu-1080p", &gpu.shot);
    assert_eq!(
        gpu.delivered,
        (1920, 1080),
        "the engine delivers the source resolution"
    );
    assert!(
        lit_share(&gpu.shot) > 0.5,
        "the picture is black (lit {:.2})",
        lit_share(&gpu.shot)
    );
    let sharp = edge_width(&gpu.shot, 480);
    assert!(
        sharp <= 1.6,
        "the 1080p edge is soft: {sharp:.1} px from 10 % to 90 %"
    );
    // The CPU path (the fallback) is capped at 1280x720 and stretched: visibly softer.
    let cpu = run(&ctx, &busy_cx(), &f1080, (1920, 1080), false, 3.5);
    keep("cpu-1080p", &cpu.shot);
    assert_eq!(
        cpu.delivered,
        (0, 0),
        "the CPU path does not use the hand-over"
    );
    assert!(lit_share(&cpu.shot) > 0.5, "the CPU fallback is black");
    let soft = edge_width(&cpu.shot, 480);
    assert!(
        soft > sharp + 0.8,
        "the GPU edge ({sharp:.1}) is not sharper than the CPU one ({soft:.1})"
    );
}

#[test]
fn a_4k_source_is_scaled_once_to_the_window_and_a_small_source_stays_at_source_size() {
    let Some((ctx, f1080, f4k)) = setup() else {
        return;
    };
    let cx = busy_cx();
    let big = run(&ctx, &cx, &f4k, (2560, 1440), true, 4.0);
    keep("gpu-4k-in-1440p", &big.shot);
    assert_eq!(
        big.delivered,
        (2560, 1440),
        "a 4K source in a 1440p window is delivered at window size"
    );
    assert!(lit_share(&big.shot) > 0.5);
    let edge = edge_width(&big.shot, 640);
    assert!(edge <= 3.0, "the downscaled 4K edge is soft: {edge:.1} px");
    // A window bigger than the source: the engine does not upscale, the layer does.
    let small = run(&ctx, &busy_cx(), &f1080, (2560, 1440), true, 3.5);
    assert_eq!(small.delivered, (1920, 1080), "no CPU upscaling");
    assert!(lit_share(&small.shot) > 0.5);
    assert!(small.shot.width == 2560, "the readback is the window size");
}

#[test]
fn a_10_bit_hdr_file_plays_on_the_gpu_path() {
    if MpvEngine::new().is_err() || GpuContext::headless().is_err() {
        eprintln!("no libmpv or GPU: skipped");
        return;
    }
    let ctx = GpuContext::headless().unwrap();
    let hdr = [
        "-pix_fmt",
        "yuv420p10le",
        "-color_primaries",
        "bt2020",
        "-color_trc",
        "smpte2084",
        "-colorspace",
        "bt2020nc",
        "-x264-params",
        "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc",
    ];
    let Some(file) = clip_with("edge1080-hdr.mkv", 1920, 1080, &hdr) else {
        eprintln!("no ffmpeg (or no 10-bit encoder): skipped");
        return;
    };
    if !file.exists() || std::fs::metadata(&file).map_or(true, |m| m.len() < 1000) {
        eprintln!("no 10-bit encoder: skipped");
        return;
    }
    let r = run(&ctx, &busy_cx(), &file, (1920, 1080), true, 3.5);
    keep("gpu-1080p-hdr10", &r.shot);
    assert_eq!(r.delivered, (1920, 1080));
    assert!(lit_share(&r.shot) > 0.5, "the 10-bit picture is black");
    eprintln!(
        "hdr10 box luma {:.0}, ground luma {:.0}",
        luma(&r.shot, 960, 400),
        luma(&r.shot, 100, 400)
    );
}

#[test]
fn the_box_the_screen_asks_for() {
    use swiftly_desktop::player_screen::gpu_frame_box;
    assert_eq!(
        gpu_frame_box((1920, 1080), Some((3840, 2160)), false, 16384),
        (1920, 1080)
    );
    assert_eq!(
        gpu_frame_box((3840, 2160), Some((1920, 1080)), false, 16384),
        (1920, 1080)
    );
    assert_eq!(
        gpu_frame_box((800, 1200), Some((1920, 1080)), false, 16384),
        (800, 1080)
    );
    assert_eq!(
        gpu_frame_box((3000, 1000), Some((1920, 1080)), true, 16384),
        (1920, 640)
    );
    assert_eq!(
        gpu_frame_box((1000, 3000), Some((1920, 1080)), true, 16384),
        (360, 1080)
    );
    assert_eq!(
        gpu_frame_box((1920, 1080), None, false, 16384),
        (1920, 1080)
    );
    // The texture limit wins over everything.
    assert_eq!(
        gpu_frame_box((7680, 4320), Some((7680, 4320)), false, 2048),
        (2048, 1152)
    );
}

#[test]
fn the_gpu_path_can_be_switched_off() {
    // With the switch set in the caller's environment the host refuses to start.
    if std::env::var_os("SWIFTLY_VIDEO_CPU").is_some() {
        assert!(GpuVideoHost::new(8192).is_none());
    }
    assert!(
        GpuVideoHost::new(1024).is_none(),
        "a texture limit below 1280 keeps the CPU path"
    );
}

/// Before/after numbers: `cargo test --release -p swiftly-desktop --features mpv --test video_gpu bench_live_video -- --ignored --nocapture`
#[test]
#[ignore = "benchmark"]
fn bench_live_video() {
    let Some((ctx, f1080, f4k)) = setup() else {
        return;
    };
    let info = ctx.adapter_info();
    eprintln!("adapter: {} ({:?})", info.name, info.backend);
    // `SWIFTLY_BENCH_ONLY=4K:3840` (source label : window width) runs one pair; `SWIFTLY_BENCH_MODE=gpu|cpu` one path.
    let only = std::env::var("SWIFTLY_BENCH_ONLY").unwrap_or_default();
    let mode = std::env::var("SWIFTLY_BENCH_MODE").unwrap_or_default();
    for (label, file) in [("1080p", &f1080), ("4K", &f4k)] {
        for window in [(1920, 1080), (3840, 2160)] {
            for gpu in [false, true] {
                if (!only.is_empty() && only != format!("{label}:{}", window.0))
                    || (!mode.is_empty() && (mode == "gpu") != gpu)
                {
                    continue;
                }
                let mut r = run(&ctx, &busy_cx(), file, window, gpu, 8.0);
                eprintln!(
                    "BENCH src {label} window {}x{} {}: frame {}x{}, {:.1} frames/s, tick work p50 {:.2} p99 {:.2} max {:.2} ms, late ticks {}/{}, cpu {}, drops dec {} out {}",
                    window.0,
                    window.1,
                    if gpu { "GPU" } else { "CPU(before)" },
                    if gpu { r.delivered.0 } else { 1280 },
                    if gpu { r.delivered.1 } else { 720 },
                    r.frames as f64 / r.secs,
                    pct(&mut r.work, 0.5),
                    pct(&mut r.work, 0.99),
                    pct(&mut r.work, 1.0),
                    r.late,
                    r.ticks,
                    r.cpu
                        .map_or("n/a".into(), |c| format!("{c:.0} % of a core")),
                    r.drops.0,
                    r.drops.1,
                );
            }
        }
    }
}
