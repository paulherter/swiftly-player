//! Plays a file through the libmpv engine with the software renderer and prints decode, delivery and drop numbers.
//! `cargo run -p swiftly-player-surface --features mpv --example mpv_probe -- FILE [SECONDS] [WxH]`
use std::time::{Duration, Instant};
use swiftly_playback::engine::{EngineEvent, EngineLoad, EngineState, PlaybackEngine};
use swiftly_player_surface::mpv::MpvEngine;
use swiftly_player_surface::{FrameBuffer, FrameStatus, SurfaceEngine, VideoSurface};
use swiftly_rules::buffer_level::BufferLevel;

fn main() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let file = args.next().ok_or("usage: mpv_probe FILE [SECONDS] [WxH]")?;
    let secs: f64 = args.next().and_then(|s| s.parse().ok()).unwrap_or(10.0);
    let (mw, mh) = args
        .next()
        .and_then(|s| {
            s.split_once('x')
                .map(|(a, b)| (a.parse().unwrap_or(1280), b.parse().unwrap_or(720)))
        })
        .unwrap_or((1280, 720));
    let e = MpvEngine::new()?;
    eprintln!("libmpv client API {}", e.api_version());
    e.load(EngineLoad {
        url: file,
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
    let (mut new, mut ticks, mut first, mut last_pos) = (0_u64, 0_u64, None, 0.0);
    let t0 = Instant::now();
    let cpu0 = cpu_seconds();
    while t0.elapsed().as_secs_f64() < secs {
        for ev in e.poll_events() {
            match ev {
                EngineEvent::FirstFrame => first = Some(t0.elapsed()),
                EngineEvent::Clock { position, .. } => last_pos = position,
                EngineEvent::State(EngineState::Error { message, .. }) => return Err(message),
                EngineEvent::Tracks {
                    audio, subtitles, ..
                } => eprintln!(
                    "tracks: {} audio, {} subtitle",
                    audio.len(),
                    subtitles.len()
                ),
                _ => {}
            }
        }
        if e.acquire_frame(mw, mh, &mut buf) == FrameStatus::New {
            new += 1;
        }
        ticks += 1;
        std::thread::sleep(Duration::from_millis(4));
    }
    let wall = t0.elapsed().as_secs_f64();
    let cpu = cpu_seconds().zip(cpu0).map(|(a, b)| a - b);
    let st = e.stats();
    let nonblack = buf
        .rgba
        .as_chunks::<4>()
        .0
        .iter()
        .step_by(7)
        .filter(|p| p[0] > 8 || p[1] > 8 || p[2] > 8)
        .count();
    println!(
        "RESULT wall {wall:.1}s pos {last_pos:.1}s first-frame {:?} loop-ticks {ticks} frames-delivered {new} ({:.1}/s) decoder-drops {} output-drops {} render {:.2} ms/frame hwdec {} hints {:?} frame {}x{} nonblack-samples {nonblack} cpu {}",
        first,
        new as f64 / wall,
        st.decoder_drops,
        st.output_drops,
        st.avg_render_ms,
        st.hwdec,
        e.display_hints(),
        buf.width,
        buf.height,
        cpu.map_or("n/a".into(), |c| format!(
            "{:.0} % of one core",
            c / wall * 100.0
        )),
    );
    Ok(())
}

#[cfg(windows)]
fn cpu_seconds() -> Option<f64> {
    // Process times through PowerShell would cost a spawn per call; read them from the environment of the caller instead.
    None
}

#[cfg(not(windows))]
fn cpu_seconds() -> Option<f64> {
    let out = std::process::Command::new("ps")
        .args(["-o", "cputime=", "-p", &std::process::id().to_string()])
        .output()
        .ok()?;
    let t = String::from_utf8_lossy(&out.stdout).trim().to_owned();
    let mut secs = 0.0;
    for part in t.split(':') {
        secs = secs * 60.0 + part.parse::<f64>().ok()?;
    }
    Some(secs)
}
