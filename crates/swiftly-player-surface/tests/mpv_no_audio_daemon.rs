//! With no audio daemon reachable (no PipeWire or PulseAudio socket in the runtime folder: a container, a bare
//! session, a test box) libmpv's PipeWire output used to hang forever in `pw_thread_loop_stop` when the engine was
//! closed. Closing must always return and playback must carry on silently. Skips when libmpv is not installed.
#![cfg(all(feature = "mpv", target_os = "linux"))]

use std::process::{Command, Stdio};
use std::time::{Duration, Instant};
use swiftly_playback::engine::{EngineLoad, PlaybackEngine};
use swiftly_player_surface::SurfaceEngine;
use swiftly_player_surface::mpv::MpvEngine;
use swiftly_rules::buffer_level::BufferLevel;

/// Four seconds of 16-bit stereo silence at 48 kHz (what most films carry).
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

/// Child side: plays the clip for a moment, then closes the engine.
#[test]
#[ignore = "run by closing_without_an_audio_daemon_never_hangs"]
fn child_plays_audio_and_closes() {
    let wav = std::env::var("SWIFTLY_TEST_WAV").expect("wav");
    let e = MpvEngine::new().expect("libmpv");
    e.load(EngineLoad {
        url: wav,
        headers: vec![],
        start: None,
        audio_server_index: None,
        subtitle_server_index: -1,
        external_subtitles: vec![],
        software_decode: false,
        buffer_level: BufferLevel::Normal,
        frame_rate_match: false,
    });
    let t0 = Instant::now();
    while t0.elapsed() < Duration::from_millis(1200) {
        let _ = e.poll_events();
        std::thread::sleep(Duration::from_millis(20));
    }
    drop(e);
}

/// The hang is a race inside libpipewire (about one run in thirty), so the test starts many children, several at once.
#[test]
fn closing_without_an_audio_daemon_never_hangs() {
    if MpvEngine::new().is_err() {
        eprintln!("skipped: no libmpv");
        return;
    }
    let dir = std::env::temp_dir().join(format!("swiftly-noaudio-{}", std::process::id()));
    let runtime = dir.join("run");
    std::fs::create_dir_all(&runtime).expect("dirs");
    std::fs::set_permissions(
        &runtime,
        std::os::unix::fs::PermissionsExt::from_mode(0o700),
    )
    .ok();
    let wav = dir.join("silence.wav");
    silent_wav(&wav);
    let exe = std::env::current_exe().expect("test exe");
    let mut hung = 0;
    for _round in 0..10 {
        let mut kids: Vec<_> = (0..8)
            .map(|_| {
                Command::new(&exe)
                    .args([
                        "--ignored",
                        "--exact",
                        "child_plays_audio_and_closes",
                        "--test-threads",
                        "1",
                    ])
                    .env("XDG_RUNTIME_DIR", &runtime)
                    .env("SWIFTLY_TEST_WAV", &wav)
                    .env_remove("SWIFTLY_MPV_OPTS")
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .expect("spawn")
            })
            .collect();
        let t0 = Instant::now();
        while !kids.is_empty() && t0.elapsed() < Duration::from_secs(20) {
            kids.retain_mut(|k| k.try_wait().expect("wait").is_none());
            std::thread::sleep(Duration::from_millis(100));
        }
        for mut k in kids {
            hung += 1;
            let _ = k.kill();
            let _ = k.wait();
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(
        hung, 0,
        "HANG: {hung} of 80 children never finished closing the engine without an audio daemon"
    );
}
