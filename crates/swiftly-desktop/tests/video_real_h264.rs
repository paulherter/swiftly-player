//! Video must always show a picture. A real H.264 file (1080p, embedded SRT) is decoded by libmpv and drawn by the
//! player screen over an image page that is as busy as the app's (the poster hub has taken its region), then read
//! back: the picture must not be black, the embedded and an external subtitle must be drawn on top, and a second
//! and third play must show a picture too. Skips without libmpv or ffmpeg. `SWIFTLY_TEST_PNG_DIR` keeps the readbacks.
#![cfg(feature = "mpv")]
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::arc_with_non_send_sync
)]

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use swiftly_desktop::frame_surface::app_cx;
use swiftly_desktop::hub::ImageHub;
use swiftly_desktop::player_screen::{LiveEngine, PlayerScreen};
use swiftly_images::fixture::FixtureImages;
use swiftly_images::{Device, ImageLoader};
use swiftly_jellyfin::{PlayMethod, ReportPlan};
use swiftly_layout::Size;
use swiftly_model::MediaStream;
use swiftly_playback::engine::{CueBody, EngineEvent, PlaybackEngine};
use swiftly_playback::player_state::EngineRequest;
use swiftly_playback::track_mapping::SubtitleFile;
use swiftly_player_surface::mpv::MpvEngine;
use swiftly_player_surface::{FrameBuffer, FrameStatus, SurfaceEngine, VideoSurface};
use swiftly_render::RgbaImage;
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_ui::{Cx, Env, Idiom};
use swiftly_vm::{PlayerIntent, PlayerSpec};

const SRT: &str = "1\n00:00:00,000 --> 00:00:30,000\nHallo Welt\n";

/// A 1080p H.264 clip with an embedded SRT track and its own SRT file; `None` without ffmpeg.
/// `SWIFTLY_TEST_CLIP_DIR` names a folder that already holds `c.mkv` and `s.srt`.
fn clip(tag: &str) -> Option<(PathBuf, PathBuf)> {
    // A machine without an H.264 encoder (the Windows VM) gets the files made elsewhere: `c.mkv` and `s.srt` in this dir.
    if let Some(dir) = std::env::var_os("SWIFTLY_TEST_CLIP_DIR").map(PathBuf::from) {
        return Some((dir.join("c.mkv"), dir.join("s.srt")));
    }
    let dir = std::env::temp_dir().join(format!("swiftly-h264-{tag}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).ok()?;
    let (srt, mkv) = (dir.join("s.srt"), dir.join("c.mkv"));
    std::fs::write(&srt, SRT).ok()?;
    let ok = std::process::Command::new("ffmpeg")
        .args([
            "-v",
            "quiet",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=1920x1080:rate=25:duration=6",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:duration=6",
            "-i",
        ])
        .arg(&srt)
        .args([
            "-map",
            "0:v",
            "-map",
            "1:a",
            "-map",
            "2:s",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-c:s",
            "srt",
        ])
        .arg(&mkv)
        .status()
        .is_ok_and(|s| s.success());
    ok.then_some((mkv, srt))
}

/// The share of pixels in the middle of the picture that are not (nearly) black.
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

/// Grey-white pixels (the subtitle text) in the band where the cue sits; the colour bars behind it are saturated.
fn white_in_bottom(img: &RgbaImage) -> usize {
    let mut n = 0;
    for y in (img.height * 84 / 100)..(img.height * 99 / 100) {
        for x in (img.width * 35 / 100)..(img.width * 60 / 100) {
            let p = img.pixel(x, y);
            let (hi, lo) = (p[0].max(p[1]).max(p[2]), p[0].min(p[1]).min(p[2]));
            n += usize::from(lo > 110 && hi - lo < 16);
        }
    }
    n
}

#[allow(dead_code)]
struct Played {
    shot: RgbaImage,
    cue_seen: bool,
    tracks: usize,
}

/// The real engine behind the screen's feed; remembers the track lists and cues that pass.
struct Tee {
    engine: Arc<MpvEngine>,
    buf: Mutex<FrameBuffer>,
    seen: Mutex<(Vec<i64>, bool)>,
}

impl LiveEngine for Tee {
    fn events(&self) -> Vec<EngineEvent> {
        let events = self.engine.poll_events();
        let mut seen = self.seen.lock().unwrap();
        for ev in &events {
            match ev {
                EngineEvent::Tracks { subtitles, .. } => {
                    seen.0 = subtitles.iter().map(|t| t.id).collect()
                }
                EngineEvent::Cues(c) => {
                    seen.1 |= c
                        .iter()
                        .any(|c| matches!(&c.body, CueBody::Text(t) if t.contains("Hallo Welt")))
                }
                _ => {}
            }
        }
        events
    }
    fn frame(&self, max_w: u32, max_h: u32, sink: &mut dyn FnMut(u32, u32, &[u8])) {
        let mut buf = self.buf.lock().unwrap();
        if self.engine.acquire_frame(max_w, max_h, &mut buf) == FrameStatus::New {
            sink(buf.width, buf.height, &buf.rgba);
        }
    }
}

fn stream(index: i64, kind: &str, codec: &str, external: bool) -> MediaStream {
    MediaStream {
        index: Some(index),
        type_: Some(kind.into()),
        codec: Some(codec.into()),
        is_external: external.then_some(true),
        ..MediaStream::default()
    }
}

/// What the server lists for the clip: video, audio, the embedded SRT, and (optionally) the external SRT file.
fn streams(with_external: bool) -> Vec<MediaStream> {
    let mut v = vec![
        stream(0, "Video", "h264", false),
        stream(1, "Audio", "aac", false),
        stream(2, "Subtitle", "subrip", false),
    ];
    if with_external {
        v.push(stream(5, "Subtitle", "subrip", true));
    }
    v
}

struct Quiet;
impl swiftly_vm::Reporter for Quiet {
    fn report(&self, _message: swiftly_vm::ReportMessage) {}
}

/// Plays `file` through the live player screen (the app's own path) for `secs` and reads the screen back. With
/// `external`, that subtitle file is added and selected instead of the embedded track.
fn play(cx: &Cx, file: &Path, external: Option<&Path>, secs: f64) -> Played {
    let env = Env::new(Size::new(1280.0, 720.0), 1.0, Idiom::Desktop);
    let spec = PlayerSpec {
        item_id: "h264".into(),
        title: "H264".into(),
        plan: ReportPlan {
            play_session_id: None,
            media_source_id: None,
            method: PlayMethod::DirectPlay,
        },
        request: EngineRequest {
            item_id: "h264".into(),
            streams: streams(external.is_some()),
            runtime: 6.0,
            subtitle_files: external
                .map(|p| SubtitleFile {
                    index: 5,
                    address: p.to_string_lossy().into_owned(),
                    attribute: Some("srt".into()),
                })
                .into_iter()
                .collect(),
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
    };
    let engine = Arc::new(MpvEngine::new().expect("libmpv"));
    let tee = Arc::new(Tee {
        engine: Arc::clone(&engine),
        buf: Mutex::new(FrameBuffer::default()),
        seen: Mutex::new((Vec::new(), false)),
    });
    let mut screen = PlayerScreen::live(
        env,
        cx.clone(),
        0.0,
        spec,
        ("H264".into(), "test".into()),
        engine as Arc<dyn PlaybackEngine>,
        Arc::clone(&tee) as Arc<dyn LiveEngine>,
        Arc::new(Quiet),
        |_| {},
    );
    let (mut tracks, mut picked) = (0, false);
    let t0 = Instant::now();
    while t0.elapsed().as_secs_f64() < secs {
        let now_ms = t0.elapsed().as_secs_f64() * 1000.0;
        let _ = screen.frame(now_ms);
        let ids = tee.seen.lock().unwrap().0.clone();
        tracks = ids.len();
        if !ids.is_empty() && !picked {
            picked = true;
            // The server's stream index: 2 is the embedded track, 5 the external file.
            screen.send_intent(
                PlayerIntent::SelectSubtitle(if external.is_some() { 5 } else { 2 }),
                now_ms,
            );
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let now_ms = t0.elapsed().as_secs_f64() * 1000.0;
    let (list, _) = screen.frame(now_ms);
    let cue_seen = tee.seen.lock().unwrap().1;
    Played {
        shot: screen.render_software(&list),
        cue_seen,
        tracks,
    }
}

/// The page the app has when a title starts: the poster hub has taken its region.
fn busy_cx() -> Cx {
    let cx = app_cx();
    let loader = ImageLoader::new(Arc::new(FixtureImages), None, Device::Mac);
    let hub = ImageHub::new(Box::new(loader), &cx, 1.0, Device::Mac);
    std::mem::forget(hub); // the hub must keep its region for the whole test
    cx
}

fn keep(name: &str, img: &RgbaImage) {
    if let Some(dir) = std::env::var_os("SWIFTLY_TEST_PNG_DIR") {
        let _ = std::fs::create_dir_all(&dir);
        img.write_png(&PathBuf::from(dir).join(format!("{name}.png")))
            .unwrap();
    }
}

#[test]
fn a_real_h264_file_shows_a_picture_and_its_subtitles() {
    if MpvEngine::new().is_err() {
        eprintln!("no libmpv: skipped");
        return;
    }
    let Some((mkv, srt)) = clip("a") else {
        eprintln!("no ffmpeg: skipped");
        return;
    };
    let cx = busy_cx();
    // Five plays in a row on the same page: every one must show its picture.
    for round in 1..=5 {
        let p = play(&cx, &mkv, None, 2.5);
        keep(&format!("h264-embedded-{round}"), &p.shot);
        assert!(
            p.tracks >= 1,
            "round {round}: the embedded subtitle track is listed"
        );
        let share = lit_share(&p.shot);
        assert!(
            share > 0.5,
            "round {round}: the picture is black (lit share {share:.2})"
        );
        if round == 1 {
            // libass draws the subtitle into the picture itself (no cue for the UI to draw).
            assert!(
                white_in_bottom(&p.shot) > 150,
                "the embedded subtitle is drawn on top of the picture"
            );
        }
    }
    let p = play(&cx, &mkv, Some(&srt), 2.5);
    keep("h264-external", &p.shot);
    assert!(
        p.tracks >= 2,
        "the external subtitle is listed next to the embedded one"
    );
    assert!(
        lit_share(&p.shot) > 0.5,
        "the picture is black with an external subtitle"
    );
    assert!(
        white_in_bottom(&p.shot) > 150,
        "the external subtitle is drawn on top ({})",
        white_in_bottom(&p.shot)
    );
}
