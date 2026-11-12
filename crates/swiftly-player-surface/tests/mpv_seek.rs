//! A seek must be answered with `SeekLanded { target }` once mpv restarted playback there; without it the player state keeps
//! showing the seek target for good (the time label stands still). Skips when libmpv is not installed.
#![cfg(feature = "mpv")]
use std::time::{Duration, Instant};
use swiftly_playback::engine::{EngineEvent, EngineLoad, PlaybackEngine};
use swiftly_player_surface::mpv::MpvEngine;
use swiftly_player_surface::{FrameBuffer, SurfaceEngine, VideoSurface};
use swiftly_rules::buffer_level::BufferLevel;

#[test]
fn a_seek_is_answered_with_seek_landed() {
    let e = match MpvEngine::new() {
        Ok(e) => e,
        Err(m) => {
            eprintln!("skipped: {m}");
            return;
        }
    };
    e.load(EngineLoad {
        url: "av://lavfi:testsrc=size=320x180:rate=25:duration=20".into(),
        headers: vec![],
        start: None,
        audio_server_index: None,
        subtitle_server_index: -1,
        external_subtitles: vec![],
        software_decode: false,
        buffer_level: BufferLevel::Normal,
        frame_rate_match: false,
    });
    let mut buf = FrameBuffer::default();
    let mut frames = false;
    let t0 = Instant::now();
    while t0.elapsed() < Duration::from_secs(20) && !frames {
        frames = e
            .poll_events()
            .iter()
            .any(|v| matches!(v, EngineEvent::FirstFrame));
        let _ = e.acquire_frame(320, 180, &mut buf);
        std::thread::sleep(Duration::from_millis(8));
    }
    assert!(frames, "no first picture");
    e.seek(7.5);
    let mut landed = None;
    let t1 = Instant::now();
    while t1.elapsed() < Duration::from_secs(10) && landed.is_none() {
        for v in e.poll_events() {
            if let EngineEvent::SeekLanded { target } = v {
                landed = Some(target);
            }
        }
        let _ = e.acquire_frame(320, 180, &mut buf);
        std::thread::sleep(Duration::from_millis(8));
    }
    assert_eq!(landed, Some(7.5), "no SeekLanded after the seek");
}
