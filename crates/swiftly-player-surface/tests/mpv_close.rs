//! Closing the libmpv engine must never hang: after the clip ended, during playback, during pause, during a seek,
//! without ever being polled, and over and over (the library stays loaded). Skips when libmpv is not installed.
//! `SWIFTLY_TEST_MEDIA=/path/clip.mkv` plays a real file instead of the generated test picture.
#![cfg(feature = "mpv")]
use std::sync::Arc;
use std::sync::mpsc;
use std::time::{Duration, Instant};
use swiftly_playback::engine::{EngineEvent, EngineLoad, PlaybackEngine};
use swiftly_player_surface::mpv::MpvEngine;
use swiftly_player_surface::{FrameBuffer, SurfaceEngine, VideoSurface};
use swiftly_rules::buffer_level::BufferLevel;

fn media() -> String {
    std::env::var("SWIFTLY_TEST_MEDIA")
        .unwrap_or_else(|_| "av://lavfi:testsrc=size=320x180:rate=25:duration=2".into())
}

fn load(e: &MpvEngine) {
    e.load(EngineLoad {
        url: media(),
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

/// Polls and draws like the UI tick until `until` says stop or `limit` passes. Returns the events seen.
fn pump(
    e: &MpvEngine,
    buf: &mut FrameBuffer,
    limit: Duration,
    mut until: impl FnMut(&[EngineEvent]) -> bool,
) -> bool {
    let t0 = Instant::now();
    while t0.elapsed() < limit {
        let evs = e.poll_events();
        let _ = e.acquire_frame(320, 180, buf);
        if until(&evs) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(8));
    }
    false
}

/// Runs `body` on its own thread; a close that does not return within 20 s fails the test (the thread is left behind).
fn guarded(name: &str, body: impl FnOnce() + Send + 'static) {
    let (tx, rx) = mpsc::channel();
    let name_owned = name.to_owned();
    std::thread::spawn(move || {
        body();
        let _ = tx.send(());
    });
    assert!(
        rx.recv_timeout(Duration::from_secs(20)).is_ok(),
        "HANG in scenario {name_owned}"
    );
}

fn engine() -> Option<Arc<MpvEngine>> {
    match MpvEngine::new() {
        Ok(e) => Some(Arc::new(e)),
        Err(m) => {
            eprintln!("skipped: {m}");
            None
        }
    }
}

/// Plays the clip to its last frame (keep-open: mpv pauses there and sends no end-file until it is stopped).
fn play_to_the_end(e: &MpvEngine, buf: &mut FrameBuffer) {
    let mut pos = 0.0_f64;
    pump(e, buf, Duration::from_secs(20), |evs| {
        for v in evs {
            if let EngineEvent::Clock { position, .. } = v {
                pos = *position;
            }
        }
        pos >= 1.8
    });
    assert!(
        pos >= 1.8,
        "the clip never reached its end (position {pos})"
    );
    pump(e, buf, Duration::from_millis(800), |_| false);
}

#[test]
fn close_after_the_clip_ended() {
    guarded("ended", || {
        let Some(e) = engine() else { return };
        let mut buf = FrameBuffer::default();
        load(&e);
        play_to_the_end(&e, &mut buf);
        // What the X does: stop, then the screen lets go of the engine.
        e.stop(true);
        drop(e);
    });
}

#[test]
fn close_after_the_clip_ended_without_stop() {
    guarded("ended-no-stop", || {
        let Some(e) = engine() else { return };
        let mut buf = FrameBuffer::default();
        load(&e);
        play_to_the_end(&e, &mut buf);
        drop(e);
    });
}

#[test]
fn close_during_playback() {
    guarded("playing", || {
        let Some(e) = engine() else { return };
        let mut buf = FrameBuffer::default();
        load(&e);
        pump(&e, &mut buf, Duration::from_secs(10), |evs| {
            evs.iter().any(|v| matches!(v, EngineEvent::FirstFrame))
        });
        pump(&e, &mut buf, Duration::from_millis(300), |_| false);
        e.stop(true);
        drop(e);
    });
}

#[test]
fn close_during_pause() {
    guarded("paused", || {
        let Some(e) = engine() else { return };
        let mut buf = FrameBuffer::default();
        load(&e);
        pump(&e, &mut buf, Duration::from_secs(10), |evs| {
            evs.iter().any(|v| matches!(v, EngineEvent::FirstFrame))
        });
        e.pause();
        pump(&e, &mut buf, Duration::from_millis(300), |_| false);
        e.stop(true);
        drop(e);
    });
}

#[test]
fn close_during_seek() {
    guarded("seeking", || {
        let Some(e) = engine() else { return };
        let mut buf = FrameBuffer::default();
        load(&e);
        pump(&e, &mut buf, Duration::from_secs(10), |evs| {
            evs.iter().any(|v| matches!(v, EngineEvent::FirstFrame))
        });
        e.seek(1.5);
        e.seek(0.2);
        e.stop(true);
        drop(e);
    });
}

#[test]
fn close_without_ever_polling() {
    guarded("unpolled", || {
        let Some(e) = engine() else { return };
        load(&e);
        std::thread::sleep(Duration::from_millis(400));
        drop(e);
    });
}

#[test]
fn open_and_close_many_times() {
    guarded("repeat", || {
        for _ in 0..5 {
            let Some(e) = engine() else { return };
            let mut buf = FrameBuffer::default();
            load(&e);
            pump(&e, &mut buf, Duration::from_millis(500), |_| false);
            drop(e);
        }
    });
}
