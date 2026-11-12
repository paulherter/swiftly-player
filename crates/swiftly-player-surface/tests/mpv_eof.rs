//! With `keep-open=yes` libmpv sends no end-file at the end of a file. The engine must still report
//! `EngineState::Ended` exactly once per file (the next-episode card, the outro skip and the "played to the end"
//! report hang on it), keep the last frame, leave Ended on a seek back and start clean on a new file.
//! Skips when libmpv is not installed.
#![cfg(feature = "mpv")]
use std::time::{Duration, Instant};
use swiftly_playback::engine::{EngineEvent, EngineLoad, EngineState, PlaybackEngine};
use swiftly_player_surface::mpv::MpvEngine;
use swiftly_player_surface::{FrameBuffer, FrameStatus, SurfaceEngine, VideoSurface};
use swiftly_rules::buffer_level::BufferLevel;

const LAVFI: &str = "av://lavfi:testsrc=size=320x180:rate=25:duration=2";

/// A seekable 2 s clip on disk (the lavfi source cannot seek back); None without ffmpeg.
fn seekable_clip() -> Option<String> {
    let path = std::env::temp_dir().join(format!("swiftly-eof-{}.mkv", std::process::id()));
    let ok = std::process::Command::new("ffmpeg")
        .args([
            "-v",
            "quiet",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "testsrc=size=320x180:rate=25:duration=2",
            "-c:v",
            "mpeg4",
            "-g",
            "5",
        ])
        .arg(&path)
        .status()
        .is_ok_and(|s| s.success());
    ok.then(|| path.to_string_lossy().into_owned())
}

fn load(e: &MpvEngine, url: &str) {
    let url = url.to_owned();
    e.load(EngineLoad {
        url,
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

/// Polls and draws like the UI tick; collects the states seen until `stop` is true or `limit` passes.
fn run(
    e: &MpvEngine,
    buf: &mut FrameBuffer,
    limit: Duration,
    seen: &mut Vec<EngineState>,
    mut stop: impl FnMut(&[EngineState]) -> bool,
) {
    let t0 = Instant::now();
    while t0.elapsed() < limit {
        for ev in e.poll_events() {
            if let EngineEvent::State(s) = ev {
                seen.push(s);
            }
        }
        let _ = e.acquire_frame(320, 180, buf);
        if stop(seen) {
            return;
        }
        std::thread::sleep(Duration::from_millis(8));
    }
}

fn ended(seen: &[EngineState]) -> usize {
    seen.iter()
        .filter(|s| matches!(s, EngineState::Ended))
        .count()
}

#[test]
fn ended_once_per_file_and_keep_open_holds_the_last_frame() {
    let Ok(e) = MpvEngine::new() else {
        eprintln!("skipped: no libmpv");
        return;
    };
    let mut buf = FrameBuffer::default();
    let mut seen = Vec::new();
    let clip = seekable_clip();
    load(&e, clip.as_deref().unwrap_or(LAVFI));
    run(&e, &mut buf, Duration::from_secs(20), &mut seen, |s| {
        ended(s) > 0
    });
    assert_eq!(
        ended(&seen),
        1,
        "Ended must arrive at the end of the file: {seen:?}"
    );
    // Nothing after Ended: no Paused from mpv's own keep-open pause, no second Ended; the last frame stays.
    let mark = seen.len();
    run(&e, &mut buf, Duration::from_millis(1200), &mut seen, |_| {
        false
    });
    assert_eq!(
        &seen[mark..],
        &[],
        "events after Ended: {:?}",
        &seen[mark..]
    );
    assert!(!buf.rgba.is_empty(), "the last frame must still be there");
    assert!(matches!(
        e.acquire_frame(320, 180, &mut buf),
        FrameStatus::Unchanged | FrameStatus::New
    ));

    // A seek back leaves Ended: playback restarts and ends once more.
    if clip.is_some() {
        e.seek(0.2);
        let mut again = Vec::new();
        run(&e, &mut buf, Duration::from_millis(700), &mut again, |_| {
            false
        });
        e.play();
        run(&e, &mut buf, Duration::from_secs(20), &mut again, |s| {
            ended(s) > 0
        });
        assert!(
            again.iter().any(|s| matches!(s, EngineState::Seeking)),
            "the seek was not seen: {again:?}"
        );
        assert!(
            again.iter().any(|s| matches!(s, EngineState::Playing)),
            "no Playing after the seek back: {again:?}"
        );
        assert_eq!(ended(&again), 1, "second end of the same file: {again:?}");
    }

    // A new file starts clean and ends once.
    load(&e, clip.as_deref().unwrap_or(LAVFI));
    let mut next = Vec::new();
    run(&e, &mut buf, Duration::from_secs(20), &mut next, |s| {
        ended(s) > 0
    });
    assert!(
        matches!(next.first(), Some(EngineState::Loading)),
        "a new file starts with Loading: {next:?}"
    );
    assert_eq!(ended(&next), 1, "the new file must end once: {next:?}");
    drop(e);
}
