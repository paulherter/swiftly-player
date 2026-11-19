//! Plays a file with one external subtitle through the libmpv engine and prints, for every new frame, the media time
//! and the share of bright (text) pixels in the lower third: shows whether back-to-back cues leave a frame without text.
//! `cargo run -p swiftly-player-surface --features mpv --example chain_probe -- FILE SUBTITLE_URL_OR_PATH [SECONDS]`
//! An http(s) address goes through the chain rule (`chain_text`); a local path is added untouched (the "before" run).
use std::time::{Duration, Instant};
use swiftly_playback::engine::{
    EngineEvent, EngineLoad, EngineState, ExternalSubtitle, PlaybackEngine,
};
use swiftly_player_surface::mpv::MpvEngine;
use swiftly_player_surface::{FrameBuffer, FrameStatus, SurfaceEngine, VideoSurface};
use swiftly_rules::buffer_level::BufferLevel;

fn main() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let file = args
        .next()
        .ok_or("usage: chain_probe FILE SUBTITLE [SECONDS]")?;
    let sub = args
        .next()
        .ok_or("usage: chain_probe FILE SUBTITLE [SECONDS]")?;
    let secs: f64 = args.next().and_then(|s| s.parse().ok()).unwrap_or(10.5);
    let e = MpvEngine::new()?;
    e.load(EngineLoad {
        url: file,
        headers: vec![],
        start: None,
        audio_server_index: None,
        subtitle_server_index: -1,
        external_subtitles: vec![ExternalSubtitle {
            url: sub,
            name: Some("chain".into()),
            language: Some("eng".into()),
            is_forced: false,
            format_hint: Some("srt".into()),
        }],
        software_decode: false,
        buffer_level: BufferLevel::Normal,
        frame_rate_match: false,
    });
    let mut buf = FrameBuffer::default();
    let mut first: Option<Instant> = None;
    let t0 = Instant::now();
    let mut selected = false;
    println!("media_s,text_share");
    while t0.elapsed().as_secs_f64() < secs {
        for ev in e.poll_events() {
            match ev {
                EngineEvent::FirstFrame => first = Some(Instant::now()),
                EngineEvent::State(EngineState::Error { message, .. }) => return Err(message),
                _ => {}
            }
        }
        if !selected && first.is_some_and(|f| f.elapsed().as_secs_f64() > 0.3) {
            // The external file is the first of its kind: the id the core expects (`EXTERNAL_BASE`).
            e.select_subtitle(1000);
            selected = true;
        }
        if e.acquire_frame(640, 360, &mut buf) == FrameStatus::New
            && let Some(f) = first
        {
            let (w, h) = (buf.width as usize, buf.height as usize);
            let (mut bright, mut total) = (0_u64, 0_u64);
            for y in (h * 2 / 3)..h {
                for x in 0..w {
                    let p = &buf.rgba[(y * w + x) * 4..];
                    total += 1;
                    if p[0] > 150 && p[1] > 150 && p[2] > 150 {
                        bright += 1;
                    }
                }
            }
            println!(
                "{:.3},{:.5}",
                f.elapsed().as_secs_f64(),
                bright as f64 / total as f64
            );
        }
        std::thread::sleep(Duration::from_millis(4));
    }
    Ok(())
}
