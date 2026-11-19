//! The regression behind the "player lags and freezes" report: the UI thread used to draw every video frame itself
//! (`acquire_frame` rendered with libmpv's software renderer), so a big picture held every UI tick for as long as one
//! frame took to draw. Now the draw happens on the engine's own thread and `acquire_frame` only hands over what is done.
//! This plays a clip, asks for a 4K frame (far slower than a UI tick to draw on the CPU) on every simulated tick and
//! requires that no single call waits. Skips when libmpv or ffmpeg is not installed.
#![cfg(feature = "mpv")]
use std::time::{Duration, Instant};
use swiftly_playback::engine::{EngineLoad, PlaybackEngine};
use swiftly_player_surface::mpv::MpvEngine;
use swiftly_player_surface::{FrameBuffer, FrameStatus, SurfaceEngine, VideoSurface};
use swiftly_rules::buffer_level::BufferLevel;

fn clip() -> Option<String> {
    let path = std::env::temp_dir().join(format!("swiftly-never-waits-{}.mkv", std::process::id()));
    std::process::Command::new("ffmpeg")
        .args([
            "-v",
            "quiet",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=1920x1080:rate=30:duration=12",
        ])
        .args(["-c:v", "mpeg4", "-g", "10"])
        .arg(&path)
        .status()
        .is_ok_and(|s| s.success())
        .then(|| path.to_string_lossy().into_owned())
}

#[test]
fn a_ui_tick_never_waits_for_a_big_frame() {
    let Ok(engine) = MpvEngine::new() else {
        eprintln!("skipped: libmpv is not installed");
        return;
    };
    let Some(url) = clip() else {
        eprintln!("skipped: ffmpeg is not installed");
        return;
    };
    engine.load(EngineLoad {
        url,
        headers: vec![],
        start: None,
        audio_server_index: None,
        subtitle_server_index: -1,
        external_subtitles: vec![],
        software_decode: true,
        buffer_level: BufferLevel::Normal,
        frame_rate_match: false,
    });
    let mut buf = FrameBuffer::default();
    let (mut worst, mut fresh, mut ticks) = (Duration::ZERO, 0_u32, 0_u32);
    let t0 = Instant::now();
    while t0.elapsed() < Duration::from_secs(3) {
        let t = Instant::now();
        let _ = engine.poll_events();
        if engine.acquire_frame(3840, 2160, &mut buf) == FrameStatus::New {
            fresh += 1;
        }
        // The first tick may start libmpv's own work; every later one must be quick.
        if ticks > 3 {
            worst = worst.max(t.elapsed());
        }
        ticks += 1;
        std::thread::sleep(Duration::from_millis(4));
    }
    assert!(fresh > 5, "only {fresh} frames arrived in 3 s");
    assert!(
        worst < Duration::from_millis(30),
        "a UI tick waited {worst:?} (a 4K software frame takes longer than that to draw)"
    );
    let st = engine.stats();
    assert_eq!(st.path, "cpu-sw");
    assert!(
        st.render_size.0 >= 1920,
        "frames were drawn at {:?}",
        st.render_size
    );
}

// ---- the GPU path (libmpv OpenGL on the render thread into shared buffers) ---------------------------------------------

#[cfg(target_os = "linux")]
mod gpu {
    use super::*;
    use swiftly_player_surface::SharedStatus;

    /// Ends the test run with a clear message when a step hangs (a hung step would stall the whole run for good).
    struct Watchdog(std::sync::Arc<std::sync::atomic::AtomicBool>);

    impl Watchdog {
        fn new(step: &'static str, limit: Duration) -> Watchdog {
            let done = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
            let flag = std::sync::Arc::clone(&done);
            std::thread::spawn(move || {
                let t = Instant::now();
                while t.elapsed() < limit {
                    if flag.load(std::sync::atomic::Ordering::Relaxed) {
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(50));
                }
                eprintln!("HANG: step `{step}` did not finish in {limit:?}");
                std::process::abort();
            });
            Watchdog(done)
        }
    }

    impl Drop for Watchdog {
        fn drop(&mut self) {
            self.0.store(true, std::sync::atomic::Ordering::Relaxed);
        }
    }

    fn gpu_engine() -> Option<MpvEngine> {
        let engine = MpvEngine::new_with(true).ok()?;
        if engine.stats().path != "gpu-dmabuf" {
            eprintln!(
                "skipped: no GPU video path here (render node, EGL, GBM or an OpenGL libmpv is missing)"
            );
            return None;
        }
        Some(engine)
    }

    fn load(engine: &MpvEngine, url: &str) {
        engine.load(EngineLoad {
            url: url.to_owned(),
            headers: vec![],
            start: None,
            audio_server_index: None,
            subtitle_server_index: -1,
            external_subtitles: vec![],
            software_decode: false,
            buffer_level: BufferLevel::Normal,
            frame_rate_match: false,
        });
    }

    /// One simulated UI tick: events and the newest shared frame. Returns how long it took and whether a frame was new.
    fn tick(engine: &MpvEngine, size: (u32, u32)) -> (Duration, bool) {
        let t = Instant::now();
        let _ = engine.poll_events();
        let a = t.elapsed();
        let fresh = matches!(engine.acquire_shared(size.0, size.1), SharedStatus::New(_));
        if t.elapsed() > Duration::from_millis(30) {
            eprintln!(
                "slow tick: poll_events {a:?}, then acquire_shared {:?}",
                t.elapsed() - a
            );
        }
        (t.elapsed(), fresh)
    }

    #[test]
    fn the_gpu_path_never_makes_a_ui_tick_wait() {
        let Some(engine) = gpu_engine() else { return };
        let Some(url) = clip() else { return };
        let _w = Watchdog::new("gpu ticks", Duration::from_secs(30));
        load(&engine, &url);
        let (mut worst, mut fresh, mut ticks) = (Duration::ZERO, 0_u32, 0_u32);
        let t0 = Instant::now();
        while t0.elapsed() < Duration::from_secs(3) {
            let (took, new) = tick(&engine, (3840, 2160));
            fresh += u32::from(new);
            if ticks > 3 {
                worst = worst.max(took);
            }
            ticks += 1;
            std::thread::sleep(Duration::from_millis(4));
        }
        assert!(fresh > 5, "only {fresh} GPU frames arrived in 3 s");
        assert!(
            worst < Duration::from_millis(30),
            "a UI tick waited {worst:?} on the GPU path"
        );
    }

    /// A window drag changes the wanted size on every tick: the ring is made again only when the size has settled, and
    /// no tick may wait for that. A close right after a size change must not hang either.
    #[test]
    fn the_gpu_path_survives_a_resize_storm_and_a_close_right_after() {
        let _w = Watchdog::new("resize storm", Duration::from_secs(60));
        let Some(url) = clip() else { return };
        for round in 0..4_u32 {
            let Some(engine) = gpu_engine() else { return };
            load(&engine, &url);
            let t0 = Instant::now();
            let mut worst = Duration::ZERO;
            let mut n = 0_u32;
            while t0.elapsed() < Duration::from_millis(1500) {
                let size = (800 + (n * 37) % 1200, 450 + (n * 23) % 700);
                let (took, _) = tick(&engine, size);
                worst = worst.max(took);
                n += 1;
                std::thread::sleep(Duration::from_millis(8));
            }
            assert!(
                worst < Duration::from_millis(30),
                "round {round}: a tick waited {worst:?} in the resize storm"
            );
            // Settled: frames come again at the final size.
            let mut fresh = 0;
            let t1 = Instant::now();
            while t1.elapsed() < Duration::from_secs(6) && fresh < 3 {
                fresh += u32::from(tick(&engine, (1280, 720)).1);
                std::thread::sleep(Duration::from_millis(8));
            }
            assert!(
                fresh >= 3,
                "round {round}: no frames after the size settled"
            );
            let _ = tick(&engine, (1000 + round * 111, 600));
            let t = Instant::now();
            drop(engine);
            assert!(
                t.elapsed() < Duration::from_secs(3),
                "round {round}: closing took {:?}",
                t.elapsed()
            );
        }
    }

    /// Opening, playing for a short time and closing, again and again (the close lands at every phase of the start);
    /// loading another title into a running engine; stopping before the close.
    #[test]
    fn the_gpu_path_opens_loads_again_and_closes_without_hanging() {
        let _w = Watchdog::new("open/close cycles", Duration::from_secs(90));
        let Some(url) = clip() else { return };
        for round in 0..12_u64 {
            let t0 = Instant::now();
            let Some(engine) = gpu_engine() else { return };
            load(&engine, &url);
            let run = Duration::from_millis(round * round * 9);
            let t = Instant::now();
            while t.elapsed() < run {
                let _ = tick(&engine, (1920, 1080));
                std::thread::sleep(Duration::from_millis(5));
            }
            if round % 3 == 0 {
                load(&engine, &url);
                let t = Instant::now();
                while t.elapsed() < Duration::from_millis(300) {
                    let _ = tick(&engine, (1920, 1080));
                    std::thread::sleep(Duration::from_millis(5));
                }
            }
            if round % 4 == 1 {
                engine.stop(false);
            }
            let closing = Instant::now();
            drop(engine);
            assert!(
                closing.elapsed() < Duration::from_secs(3),
                "round {round}: closing took {:?}",
                closing.elapsed()
            );
            let fds = |dir: &str| std::fs::read_dir(dir).map_or(0, Iterator::count);
            eprintln!(
                "gpu cycle {round}: {:?} fds {} threads {}",
                t0.elapsed(),
                fds("/proc/self/fd"),
                fds("/proc/self/task")
            );
        }
    }
}
