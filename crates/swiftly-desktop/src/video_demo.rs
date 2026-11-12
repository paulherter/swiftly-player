//! `--demo player --video FILE`: the real player screen over a real video (libmpv software render), headless.
//!
//! Default: the wgpu renderer into an offscreen texture; the frame is the renderer's bottom layer (`upload_video`) and the
//! UI over it is transparent. `--software` draws everything with the CPU renderer (the old path, for comparison).
//!
//! Each tick (60 Hz, paced by the wall clock): pull engine events into the view model, take a new frame if there is
//! one and rewrite it into the image page, build the draw list and draw it with the software renderer. Taps toggle the
//! controls so they animate over the picture. At the end it prints what was delivered and dropped.

use crate::cli::Options;
use crate::frame_surface::{FrameSurface, GpuSurface};
use crate::player_screen::{PlayerScenario, PlayerScreen, VideoSurface};
use std::sync::Arc;
use std::time::{Duration, Instant};
use swiftly_layout::Size;
use swiftly_playback::engine::{EngineEvent, EngineLoad, PlaybackEngine};
use swiftly_player_surface::mpv::MpvEngine;
use swiftly_player_surface::{
    FrameBuffer, FrameStatus, SurfaceEngine, VideoSurface as FrameSource,
};
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_ui::{Env, Idiom};

fn percentile(v: &mut [f64], p: f64) -> f64 {
    v.sort_by(f64::total_cmp);
    v.get(((v.len() as f64 - 1.0) * p) as usize)
        .copied()
        .unwrap_or(0.0)
}

/// The wgpu side: device, renderer and an offscreen target of the window's pixel size.
struct Gpu {
    renderer: swiftly_render::WgpuRenderer,
    view: wgpu::TextureView,
    size: (u32, u32),
    adapter: String,
}

impl Gpu {
    fn new(size: (u32, u32)) -> Result<Gpu, String> {
        let ctx = swiftly_render::GpuContext::headless().map_err(|e| e.to_string())?;
        let info = ctx.adapter_info();
        let format = wgpu::TextureFormat::Rgba8Unorm;
        let renderer =
            swiftly_render::WgpuRenderer::new(&ctx, format).map_err(|e| e.to_string())?;
        let texture = ctx.device().create_texture(&wgpu::TextureDescriptor {
            label: Some("player demo target"),
            size: wgpu::Extent3d {
                width: size.0,
                height: size.1,
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
        Ok(Gpu {
            renderer,
            view,
            size,
            adapter: format!("{} ({:?})", info.name, info.backend),
        })
    }
}

/// Runs the demo for `opts.quit_after` seconds (default 10) and returns the report line.
pub fn run(opts: &Options) -> Result<String, String> {
    let file = opts
        .video
        .clone()
        .ok_or("--demo player needs --video FILE")?;
    let secs = opts.quit_after.unwrap_or(10.0);
    let env = Env::new(
        Size::new(opts.size.0 as f32, opts.size.1 as f32),
        opts.scale,
        Idiom::Desktop,
    );
    let px = (
        (opts.size.0 as f32 * opts.scale) as u32,
        (opts.size.1 as f32 * opts.scale) as u32,
    );
    let cx = crate::frame_surface::app_cx();
    let mut gpu = if opts.software {
        None
    } else {
        Some(Gpu::new(px)?)
    };
    #[allow(clippy::arc_with_non_send_sync)]
    // the UI is single-threaded; the seam only asks for Arc
    let frames = Arc::new(FrameSurface::new(cx.clone()));
    #[allow(clippy::arc_with_non_send_sync)]
    // the UI is single-threaded; the seam only asks for Arc
    let surface: Arc<dyn VideoSurface> = if gpu.is_some() {
        Arc::new(GpuSurface)
    } else {
        Arc::clone(&frames) as Arc<dyn VideoSurface>
    };
    let mut screen = PlayerScreen::with_surface(env, cx, PlayerScenario::Playing, 0.0, surface);
    screen.use_external_clock();
    let engine = MpvEngine::new()?;
    engine.load(EngineLoad {
        url: file.to_string_lossy().into_owned(),
        headers: vec![],
        start: None,
        audio_server_index: None,
        subtitle_server_index: -1,
        external_subtitles: vec![],
        software_decode: false,
        buffer_level: BufferLevel::Normal,
        frame_rate_match: false,
    });
    // The CPU path rewrites into the 2048 px image page, so it stays at 720p; the GPU path takes the window size.
    let (max_w, max_h) = opts.video_px.unwrap_or(if gpu.is_some() {
        px
    } else {
        (px.0.min(1280), px.1.min(720))
    });
    let mut buf = FrameBuffer::default();
    let (mut total, mut acq, mut up, mut ui, mut draw) = (
        Vec::<f64>::new(),
        Vec::<f64>::new(),
        Vec::<f64>::new(),
        Vec::<f64>::new(),
        Vec::<f64>::new(),
    );
    let (mut video_new, mut ticks) = (0_u64, 0_u32);
    let (mut first, mut late) = (None, 0_u32);
    let (t0, tick) = (Instant::now(), Duration::from_micros(16_667));
    while t0.elapsed().as_secs_f64() < secs {
        let target = t0 + tick * ticks;
        let now_ms = t0.elapsed().as_secs_f64() * 1000.0;
        let began = Instant::now();
        for ev in engine.poll_events() {
            if ev == EngineEvent::FirstFrame && first.is_none() {
                first = Some(t0.elapsed());
            }
            screen.engine_event(ev, now_ms);
        }
        let t = Instant::now();
        let got = engine.acquire_frame(max_w, max_h, &mut buf) == FrameStatus::New;
        if got {
            acq.push(t.elapsed().as_secs_f64() * 1000.0);
            let t = Instant::now();
            match gpu.as_mut() {
                Some(g) => g.renderer.upload_video(
                    buf.width,
                    buf.height,
                    &buf.rgba,
                    swiftly_render::VideoFit::Fit,
                ),
                None => frames.push(buf.width, buf.height, &buf.rgba),
            }
            up.push(t.elapsed().as_secs_f64() * 1000.0);
            video_new += 1;
        }
        // A tap every 2 s opens or closes the controls: they fade and slide over the running picture.
        if ticks % 120 == 60 {
            let (x, y) = (opts.size.0 as f32 / 2.0, opts.size.1 as f32 / 2.0);
            screen.touch_down(x, y, now_ms);
            screen.touch_up(x, y, now_ms + 20.0);
        }
        let t = Instant::now();
        let (list, _) = screen.frame(now_ms);
        ui.push(t.elapsed().as_secs_f64() * 1000.0);
        let t = Instant::now();
        match gpu.as_mut() {
            Some(g) => {
                let (cx, size) = (screen.cx().clone(), g.size);
                let (ts, im) = (cx.text.borrow(), cx.images.borrow());
                g.renderer.draw(
                    &list,
                    &g.view,
                    size,
                    swiftly_render::Color::BLACK,
                    &swiftly_render::Sources {
                        glyphs: Some(&ts.atlas),
                        images: Some(&im.page),
                    },
                );
                g.renderer.wait().map_err(|e| e.to_string())?;
            }
            None => {
                let _img = screen.render_software(&list);
            }
        }
        draw.push(t.elapsed().as_secs_f64() * 1000.0);
        total.push(began.elapsed().as_secs_f64() * 1000.0);
        ticks += 1;
        if Instant::now() > target + tick {
            late += 1;
        } else {
            std::thread::sleep(target.saturating_duration_since(Instant::now()));
        }
    }
    let wall = t0.elapsed().as_secs_f64();
    let st = engine.stats();
    let hints = engine.display_hints();
    let p = |v: &[f64], q: f64| percentile(&mut v.to_vec(), q);
    Ok(format!(
        "player+video [{}]: {wall:.1}s, ticks {ticks} ({late} late), tick work p50 {:.2} ms p99 {:.2} ms max {:.2} ms (frame build p50 {:.2}, draw+gpu p50 {:.2} p99 {:.2}); video {}x{} px, delivered {video_new} ({:.1}/s), mpv render+copy p50 {:.2} p99 {:.2} ms, upload p50 {:.2} p99 {:.2} ms, decoder drops {}, output drops {}, mpv avg render {:.2} ms, hwdec {}, first frame {:?}, source {:?} {:?}",
        gpu.as_ref()
            .map_or("software".to_string(), |g| g.adapter.clone()),
        p(&total, 0.5),
        p(&total, 0.99),
        p(&total, 1.0),
        p(&ui, 0.5),
        p(&draw, 0.5),
        p(&draw, 0.99),
        buf.width,
        buf.height,
        video_new as f64 / wall,
        p(&acq, 0.5),
        p(&acq, 0.99),
        p(&up, 0.5),
        p(&up, 0.99),
        st.decoder_drops,
        st.output_drops,
        st.avg_render_ms,
        st.hwdec,
        first,
        hints.size,
        hints.range,
    ))
}
