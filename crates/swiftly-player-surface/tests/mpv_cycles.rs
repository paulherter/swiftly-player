//! Opening and closing the engine many times in one process (a player screen opened and closed for each title) must not
//! leak: no handles, no threads, no audio device held, with or without a working audio output. Skips without libmpv.
#![cfg(all(feature = "mpv", target_os = "linux"))]

use std::time::{Duration, Instant};
use swiftly_playback::engine::{EngineLoad, PlaybackEngine};
use swiftly_player_surface::SurfaceEngine;
use swiftly_player_surface::mpv::MpvEngine;
use swiftly_rules::buffer_level::BufferLevel;

fn silent_wav(path: &std::path::Path) {
    let data_len: u32 = 48000 * 4 * 4;
    let mut b = Vec::new();
    b.extend_from_slice(b"RIFF");
    b.extend_from_slice(&(36 + data_len).to_le_bytes());
    b.extend_from_slice(b"WAVEfmt ");
    b.extend_from_slice(&16u32.to_le_bytes());
    b.extend_from_slice(&1u16.to_le_bytes());
    b.extend_from_slice(&2u16.to_le_bytes());
    b.extend_from_slice(&48000u32.to_le_bytes());
    b.extend_from_slice(&192000u32.to_le_bytes());
    b.extend_from_slice(&4u16.to_le_bytes());
    b.extend_from_slice(&16u16.to_le_bytes());
    b.extend_from_slice(b"data");
    b.extend_from_slice(&data_len.to_le_bytes());
    b.extend(std::iter::repeat_n(0u8, data_len as usize));
    std::fs::write(path, b).expect("write wav");
}

fn count(dir: &str) -> usize {
    std::fs::read_dir(dir).map_or(0, Iterator::count)
}

#[test]
fn closing_the_engine_repeatedly_leaks_no_handles_or_threads() {
    if MpvEngine::new().is_err() {
        eprintln!("skipped: no libmpv");
        return;
    }
    let dir = std::env::temp_dir().join(format!("swiftly-cycles-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("dir");
    let wav = dir.join("silence.wav");
    silent_wav(&wav);
    let cycles: usize = std::env::var("SWIFTLY_TEST_CYCLES")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(12);
    let (fd0, th0) = (count("/proc/self/fd"), count("/proc/self/task"));
    let mut slowest = Duration::ZERO;
    for round in 0..cycles {
        let t0 = Instant::now();
        let e = MpvEngine::new().expect("engine");
        e.load(EngineLoad {
            url: wav.to_string_lossy().into_owned(),
            headers: vec![],
            start: None,
            audio_server_index: None,
            subtitle_server_index: -1,
            external_subtitles: vec![],
            software_decode: false,
            buffer_level: BufferLevel::Normal,
            frame_rate_match: false,
        });
        let t = Instant::now();
        while t.elapsed() < Duration::from_millis(400) {
            let _ = e.poll_events();
            std::thread::sleep(Duration::from_millis(20));
        }
        drop(e);
        slowest = slowest.max(t0.elapsed());
        eprintln!(
            "cycle {round}: {:?} fds {} threads {}",
            t0.elapsed(),
            count("/proc/self/fd"),
            count("/proc/self/task")
        );
    }
    let (fd1, th1) = (count("/proc/self/fd"), count("/proc/self/task"));
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        fd1 <= fd0 + 8 && th1 <= th0 + 4,
        "LEAK after {cycles} cycles: fds {fd0} -> {fd1}, threads {th0} -> {th1}"
    );
    assert!(
        slowest < Duration::from_secs(3),
        "a cycle took {slowest:?}: closing the engine must not wait for a stuck output"
    );
}
