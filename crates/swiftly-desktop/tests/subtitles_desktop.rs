//! Subtitles on the desktop player (Windows + Linux),  through the real path:
//! libmpv plays a generated file inside the live `PlayerScreen`, the picture libmpv rendered (with libass' subtitles in
//! it) is read back and measured. Formats (embedded/external SRT, ASS with styles, VTT, PGS, a header-less MKV), the
//! file-style switch, the look against the Apple overlay's reference PNGs, the look following the saved setting, the
//! subtitle delay, full screen, and the transcode reload with the real engine. Skips without libmpv, ffmpeg or python3.
//! `SWIFTLY_TEST_PNG_DIR` keeps the readbacks. Files made once per run in the temp dir.
#![cfg(feature = "mpv")]
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::arc_with_non_send_sync,
    clippy::cast_precision_loss
)]

use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};
use swiftly_desktop::frame_surface::app_cx;
use swiftly_desktop::login_screen::Pending;
use swiftly_desktop::player_host::{PlanAsk, Planner, Switched};
use swiftly_desktop::player_screen::{LiveEngine, PlayerScreen};
use swiftly_jellyfin::{PlayMethod, ReportPlan};
use swiftly_layout::Size;
use swiftly_model::MediaStream;
use swiftly_playback::engine::{EngineEvent, PlaybackEngine};
use swiftly_playback::player_state::EngineRequest;
use swiftly_playback::track_mapping::SubtitleFile;
use swiftly_player_surface::mpv::MpvEngine;
use swiftly_player_surface::{FrameBuffer, FrameStatus, SurfaceEngine, VideoSurface};
use swiftly_render::RgbaImage;
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_rules::delay::Delay;
use swiftly_settings::{JsonFileStore, KeyValueStore, Value};
use swiftly_support::subtitle::{Colour, Outline, Position, Size as SubSize, SubtitleLook};
use swiftly_ui::{Env, Idiom};
use swiftly_vm::{PlayerIntent, PlayerSpec, Quality};

const BG: u8 = 96; // the flat grey of the test picture (0x606060)

// ---- fixtures ------------------------------------------------------------------------------------------------------

struct Fx {
    dir: PathBuf,
}

fn ffmpeg(args: &[&str]) -> bool {
    Command::new("ffmpeg")
        .args(["-v", "quiet", "-y"])
        .args(args)
        .status()
        .is_ok_and(|s| s.success())
}

fn video_args(secs: &str, colour: &str) -> Vec<String> {
    [
        "-f",
        "lavfi",
        "-i",
        &format!("color=c={colour}:s=1920x1080:r=25:d={secs}"),
        "-f",
        "lavfi",
        "-i",
        &format!("sine=frequency=440:duration={secs}"),
    ]
    .map(str::to_owned)
    .to_vec()
}

const ASS: &str = "[Script Info]\nPlayResY: 1080\nPlayResX: 1920\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,Inter 18pt SemiBold,60,&H000000FF,&H000000FF,&H00FF0000,&H00000000,0,0,0,0,100,100,0,0,1,4,0,2,10,10,40,1\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:00.00,0:00:05.50,Default,,0,0,0,,Hallo Welt, Ägypten gjpq\n";
const SRT: &str = "1\n00:00:00,000 --> 00:00:05,500\nHallo Welt, Ägypten gjpq\n";
const VTT: &str = "WEBVTT\n\n00:00:00.000 --> 00:00:05.500\nHallo Welt, Ägypten gjpq\n";

/// Cue texts of the script and stem tests: the same letter repeated (a missing glyph draws the same box for two different
/// letters, real glyphs differ), a Hebrew line with a Latin word (right-to-left order) and the Latin word alone.
const SCRIPT_CUES: [(&str, &str); 11] = [
    ("ill", "Illinois"),
    ("rtl", "שלום ABC"),
    ("abc", "ABC"),
    ("ar_a", "بببببب"),
    ("ar_b", "كككككك"),
    ("he_a", "אאאאאא"),
    ("he_b", "בבבבבב"),
    ("hi_a", "कककककक"),
    ("hi_b", "मममममम"),
    ("th_a", "กกกกกก"),
    ("th_b", "ขขขขขข"),
];

/// Every file the tests need; `None` (skip) without libmpv, ffmpeg or python3.
fn fx() -> Option<&'static Fx> {
    static FX: OnceLock<Option<Fx>> = OnceLock::new();
    FX.get_or_init(|| {
        MpvEngine::new().ok()?;
        // A machine without ffmpeg (the Windows VM) gets the made files: `SWIFTLY_SUBS_FIXTURES` names that folder.
        if let Some(dir) = std::env::var_os("SWIFTLY_SUBS_FIXTURES").map(PathBuf::from) {
            return Some(Fx { dir });
        }
        let dir = std::env::temp_dir().join(format!("swiftly-subs-{}", std::process::id()));
        std::fs::create_dir_all(&dir).ok()?;
        let p = |n: &str| dir.join(n);
        for (n, t) in [("s.srt", SRT), ("s.ass", ASS), ("s.vtt", VTT)] {
            std::fs::write(p(n), t).ok()?;
        }
        let v = video_args("6", "0x606060");
        let v: Vec<&str> = v.iter().map(String::as_str).collect();
        let enc = ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac"];
        let mux = |out: &str, subs: &[(&str, &str)]| {
            let mut a: Vec<String> = v.iter().map(|s| (*s).to_owned()).collect();
            for (f, _) in subs {
                a.extend(["-i".to_owned(), p(f).to_string_lossy().into_owned()]);
            }
            a.extend(["-map", "0:v", "-map", "1:a"].map(str::to_owned));
            for i in 0..subs.len() {
                a.extend(["-map".to_owned(), format!("{}:s", i + 2)]);
            }
            a.extend(enc.map(str::to_owned));
            for (i, (_, codec)) in subs.iter().enumerate() {
                a.extend([format!("-c:s:{i}"), (*codec).to_owned()]);
            }
            a.push(p(out).to_string_lossy().into_owned());
            let refs: Vec<&str> = a.iter().map(String::as_str).collect();
            ffmpeg(&refs)
        };
        let ok = mux("emb_srt.mkv", &[("s.srt", "srt")]) && mux("emb_ass.mkv", &[("s.ass", "ass")]) && mux("plain.mkv", &[]);
        if !ok {
            return None;
        }
        // A 2.39:1 picture (1920x804) with the same cue: letterboxed in a 16:9 window (line 8a).
        let mut a: Vec<String> = ["-f", "lavfi", "-i", "color=c=0x606060:s=1920x804:r=25:d=6", "-f", "lavfi", "-i", "sine=frequency=440:duration=6", "-i"].map(str::to_owned).to_vec();
        a.push(p("s.srt").to_string_lossy().into_owned());
        a.extend(["-map", "0:v", "-map", "1:a", "-map", "2:s"].map(str::to_owned));
        a.extend(enc.map(str::to_owned));
        a.extend(["-c:s".to_owned(), "srt".to_owned(), p("wide.mkv").to_string_lossy().into_owned()]);
        let refs: Vec<&str> = a.iter().map(String::as_str).collect();
        ffmpeg(&refs).then_some(())?;
        // Three cues (1-2 s, 4-5 s, 8-9 s) in a 12 s picture: timing after seek, pause and speed (line 14).
        std::fs::write(p("timing.srt"), "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n2\n00:00:04,000 --> 00:00:05,000\nTwo\n\n3\n00:00:08,000 --> 00:00:09,000\nThree\n").ok()?;
        let v12 = video_args("12", "0x606060");
        let mut a: Vec<String> = v12.clone();
        a.extend(["-i".to_owned(), p("timing.srt").to_string_lossy().into_owned()]);
        a.extend(["-map", "0:v", "-map", "1:a", "-map", "2:s"].map(str::to_owned));
        a.extend(enc.map(str::to_owned));
        a.extend(["-c:s".to_owned(), "srt".to_owned(), p("timing.mkv").to_string_lossy().into_owned()]);
        let refs: Vec<&str> = a.iter().map(String::as_str).collect();
        ffmpeg(&refs).then_some(())?;
        // One-line cues for the look and script tests (lines 8-10).
        for (name, text) in SCRIPT_CUES {
            std::fs::write(p(&format!("c_{name}.srt")), format!("1\n00:00:00,000 --> 00:00:05,500\n{text}\n")).ok()?;
            mux(&format!("c_{name}.mkv"), &[(&format!("c_{name}.srt"), "srt")]).then_some(())?;
        }
        // The server's remux of a download: written to a pipe, so the header has no duration, cues or seek head.
        let piped = Command::new("ffmpeg").args(["-v", "quiet", "-y", "-i"]).arg(p("emb_srt.mkv")).args(["-map", "0", "-c", "copy", "-f", "matroska", "pipe:1"]).output().ok()?;
        std::fs::write(p("headerless.mkv"), piped.stdout).ok()?;
        // PGS: written by hand (ffmpeg cannot encode it), muxed as a copy.
        let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/make_pgs.py");
        Command::new("python3").arg("-I").arg(&script).arg(p("pgs.sup")).status().ok().filter(|s| s.success())?;
        // `-copyts`: the file starts at 1 s, ffmpeg must not shift it to 0.
        let mut a: Vec<String> = vec!["-copyts".to_owned()];
        a.extend(v.iter().map(|s| (*s).to_owned()));
        a.extend(["-i".to_owned(), p("pgs.sup").to_string_lossy().into_owned()]);
        a.extend(["-map", "0:v", "-map", "1:a", "-map", "2:s", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-c:s", "copy"].map(str::to_owned));
        a.push(p("pgs.mkv").to_string_lossy().into_owned());
        let refs: Vec<&str> = a.iter().map(String::as_str).collect();
        ffmpeg(&refs).then_some(())?;
        // The "burned in" picture a transcode would deliver: another colour.
        let b = video_args("6", "0x204060");
        let mut a: Vec<&str> = b.iter().map(String::as_str).collect();
        a.extend(["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac"]);
        let burned = p("burned.mkv");
        a.push(burned.to_str()?);
        ffmpeg(&a).then_some(())?;
        Some(Fx { dir })
    })
    .as_ref()
}

// ---- measuring ------------------------------------------------------------------------------------------------------

#[derive(Clone, Default)]
struct Frame {
    w: usize,
    h: usize,
    rgba: Vec<u8>,
}

impl Frame {
    fn px(&self, x: usize, y: usize) -> [u8; 3] {
        let o = (y * self.w + x) * 4;
        [self.rgba[o], self.rgba[o + 1], self.rgba[o + 2]]
    }
    fn image(&self) -> RgbaImage {
        RgbaImage {
            width: self.w,
            height: self.h,
            pixels: self.rgba.clone(),
        }
    }
}

/// What the subtitle is made of, found by colour in the lower third of a picture.
#[derive(Debug, Default, Clone, Copy)]
struct Ink {
    white: usize,
    yellow: usize,
    red: usize,
    blue: usize,
    dark: usize,
    /// Bounding box of everything that differs from the flat background: x0, x1, y0, y1.
    bbox: Option<(usize, usize, usize, usize)>,
}

impl Ink {
    fn any(&self) -> bool {
        self.bbox.is_some() && self.white + self.yellow + self.red + self.blue > 150
    }
    fn width(&self) -> f64 {
        self.bbox.map_or(0.0, |b| (b.1 - b.0 + 1) as f64)
    }
    fn height(&self) -> f64 {
        self.bbox.map_or(0.0, |b| (b.3 - b.2 + 1) as f64)
    }
}

/// Classifies pixels of `rows` (a band of the picture); `bg` gives the background grey of a column.
fn measure(
    at: impl Fn(usize, usize) -> [u8; 3],
    bg: impl Fn(usize) -> u8,
    w: usize,
    rows: std::ops::Range<usize>,
) -> Ink {
    let mut ink = Ink::default();
    let (mut x0, mut x1, mut y0, mut y1) = (usize::MAX, 0, usize::MAX, 0);
    for y in rows {
        for x in 0..w {
            let [r, g, b] = at(x, y);
            let (hi, lo) = (r.max(g).max(b), r.min(g).min(b));
            let base = i32::from(bg(x));
            let lit = i32::from(hi) > base + 60;
            let dark = i32::from(hi) < base - 45;
            if lit {
                if lo > 190 {
                    ink.white += 1;
                } else if r > 190 && g > 170 && b < 130 {
                    ink.yellow += 1;
                } else if r > 190 && g < 90 && b < 90 {
                    ink.red += 1;
                } else if b > 190 && r < 90 && g < 90 {
                    ink.blue += 1;
                }
            }
            if dark {
                ink.dark += 1;
            }
            if lit || dark {
                (x0, x1, y0, y1) = (x0.min(x), x1.max(x), y0.min(y), y1.max(y));
            }
        }
    }
    if x0 != usize::MAX {
        ink.bbox = Some((x0, x1, y0, y1));
    }
    ink
}

fn ink_of(f: &Frame) -> Ink {
    // The lower 30 % of the picture, thinned out for speed (every second pixel is enough for areas, bbox stays close).
    measure(|x, y| f.px(x, y), |_| BG, f.w, (f.h * 7 / 10)..f.h)
}

/// The same measure on one of the Apple reference PNGs (a gradient background: the column's top pixel is the base).
fn ink_of_reference(name: &str) -> (Ink, f64) {
    // On a machine that only has the made files, the reference PNGs sit in `<fixtures>/reference`.
    let dir = std::env::var_os("SWIFTLY_SUBS_FIXTURES").map_or_else(
        || Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Tests/SubtitleRender/reference"),
        |d| PathBuf::from(d).join("reference"),
    );
    let img = RgbaImage::read_png(&dir.join(name)).expect("reference png");
    let ink = measure(
        |x, y| {
            let p = img.pixel(x, y);
            [p[0], p[1], p[2]]
        },
        |x| img.pixel(x, 10)[0],
        img.width,
        40..img.height,
    );
    // The crop ends 6 px above the bottom of the 1080 px picture.
    let gap = (img.height - 1 - ink.bbox.unwrap().3 + 6) as f64;
    (ink, gap)
}

// ---- the real player -----------------------------------------------------------------------------------------------

struct Tee {
    engine: Arc<MpvEngine>,
    buf: Mutex<FrameBuffer>,
    last: Mutex<Frame>,
    tracks: Mutex<usize>,
    /// (number of frames handed over, the engine's clock read in the same call as the last frame): the media time of
    /// the picture, not the polled position of the screen (which is about half a second older).
    stamp: Mutex<(u64, f64)>,
}

impl LiveEngine for Tee {
    fn events(&self) -> Vec<EngineEvent> {
        let events = self.engine.poll_events();
        for ev in &events {
            if let EngineEvent::Tracks { subtitles, .. } = ev {
                *self.tracks.lock().unwrap() = subtitles.len();
            }
        }
        events
    }
    fn source_size(&self) -> Option<(u32, u32)> {
        use swiftly_player_surface::VideoSurface;
        self.engine.display_hints().size
    }
    fn frame(&self, max_w: u32, max_h: u32, sink: &mut dyn FnMut(u32, u32, &[u8])) {
        let mut buf = self.buf.lock().unwrap();
        if self.engine.acquire_frame(max_w, max_h, &mut buf) == FrameStatus::New {
            *self.last.lock().unwrap() = Frame {
                w: buf.width as usize,
                h: buf.height as usize,
                rgba: buf.rgba.clone(),
            };
            let mut stamp = self.stamp.lock().unwrap();
            *stamp = (stamp.0 + 1, self.engine.clock_now().unwrap_or(-1.0));
            drop(stamp);
            sink(buf.width, buf.height, &buf.rgba);
        }
    }
}

struct Quiet;
impl swiftly_vm::Reporter for Quiet {
    fn report(&self, _message: swiftly_vm::ReportMessage) {}
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

/// One title: `emb` is the embedded subtitle codec (track 2), `ext` an external file (track 5: path, codec, attribute).
struct Title<'a> {
    file: PathBuf,
    emb: Option<&'a str>,
    ext: Option<(PathBuf, &'a str, &'a str)>,
    select: i64,
    transcode: Option<String>,
}

fn title<'a>(
    file: PathBuf,
    emb: Option<&'a str>,
    ext: Option<(PathBuf, &'a str, &'a str)>,
    select: i64,
) -> Title<'a> {
    Title {
        file,
        emb,
        ext,
        select,
        transcode: None,
    }
}

fn spec_of(t: &Title<'_>) -> PlayerSpec {
    let mut streams = vec![
        stream(0, "Video", "h264", false),
        stream(1, "Audio", "aac", false),
    ];
    if let Some(c) = t.emb {
        streams.push(stream(2, "Subtitle", c, false));
    }
    if let Some((_, c, _)) = &t.ext {
        streams.push(stream(5, "Subtitle", c, true));
    }
    PlayerSpec {
        item_id: "sub".into(),
        title: "Sub".into(),
        plan: ReportPlan {
            play_session_id: None,
            media_source_id: None,
            method: if t.transcode.is_some() {
                PlayMethod::Transcode
            } else {
                PlayMethod::DirectPlay
            },
        },
        request: EngineRequest {
            item_id: "sub".into(),
            streams,
            runtime: 6.0,
            subtitle_files: t
                .ext
                .iter()
                .map(|(p, _, a)| SubtitleFile {
                    index: 5,
                    address: p.to_string_lossy().into_owned(),
                    attribute: Some((*a).into()),
                })
                .collect(),
            url: t
                .transcode
                .clone()
                .unwrap_or_else(|| t.file.to_string_lossy().into_owned()),
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
    }
}

struct Run {
    screen: PlayerScreen,
    tee: Arc<Tee>,
    engine: Arc<MpvEngine>,
    t0: Instant,
    picked: bool,
    select: i64,
    store: Arc<JsonFileStore>,
}

static STORE_N: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

fn save_look(store: &JsonFileStore, look: &SubtitleLook) {
    store
        .set("utAussehen", Value::Data(look.encoded()))
        .unwrap();
}

/// Starts the live player screen on `t` at the window size `size` with the saved look `look` (none = never touched).
fn start(t: &Title<'_>, look: Option<SubtitleLook>, size: (f64, f64)) -> Run {
    start_spec(spec_of(t), t.select, look, size)
}

fn start_spec(spec: PlayerSpec, select: i64, look: Option<SubtitleLook>, size: (f64, f64)) -> Run {
    start_scaled(spec, select, look, size, 1.0)
}

/// `size` is the window in physical pixels; the UI sees it in points at `scale` pixels per point.
fn start_scaled(
    spec: PlayerSpec,
    select: i64,
    look: Option<SubtitleLook>,
    size: (f64, f64),
    scale: f64,
) -> Run {
    let fx = fx().unwrap();
    let env = Env::new(
        Size::new((size.0 / scale) as f32, (size.1 / scale) as f32),
        scale as f32,
        Idiom::Desktop,
    );
    let engine = Arc::new(MpvEngine::new().expect("libmpv"));
    let tee = Arc::new(Tee {
        engine: Arc::clone(&engine),
        buf: Mutex::new(FrameBuffer::default()),
        last: Mutex::new(Frame::default()),
        tracks: Mutex::new(0),
        stamp: Mutex::new((0, -1.0)),
    });
    let n = STORE_N.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    // The settings file is this run's own: a shared fixture folder (`SWIFTLY_SUBS_FIXTURES`) keeps files between runs and
    // between parallel processes, and a stale yellow look from an earlier test made a "never touched" player draw yellow.
    let path = fx
        .dir
        .join(format!("settings-{}-{n}.json", std::process::id()));
    let _ = std::fs::remove_file(&path);
    let store = Arc::new(JsonFileStore::open(path).expect("store"));
    if let Some(l) = &look {
        save_look(&store, l);
    }
    let mut screen = PlayerScreen::live(
        env,
        app_cx(),
        0.0,
        spec,
        ("Sub".into(), "test".into()),
        Arc::clone(&engine) as Arc<dyn PlaybackEngine>,
        Arc::clone(&tee) as Arc<dyn LiveEngine>,
        Arc::new(Quiet),
        |_| {},
    );
    screen.set_store(Arc::clone(&store), 0.0);
    Run {
        screen,
        tee,
        engine,
        t0: Instant::now(),
        picked: false,
        select,
        store,
    }
}

impl Run {
    fn now(&self) -> f64 {
        self.t0.elapsed().as_secs_f64() * 1000.0
    }
    /// Drives the screen until `secs` after the start. Picks the subtitle once the tracks are known.
    fn until(&mut self, secs: f64) {
        while self.t0.elapsed().as_secs_f64() < secs {
            let now = self.now();
            let _ = self.screen.frame(now);
            if !self.picked && *self.tee.tracks.lock().unwrap() > 0 {
                self.picked = true;
                if self.select >= 0 {
                    self.screen
                        .send_intent(PlayerIntent::SelectSubtitle(self.select), now);
                }
            }
            std::thread::sleep(Duration::from_millis(8));
        }
    }
    fn frame(&self) -> Frame {
        self.tee.last.lock().unwrap().clone()
    }
    /// (frame count, media time of the last frame).
    fn stamp(&self) -> (u64, f64) {
        *self.tee.stamp.lock().unwrap()
    }
    /// The picture libmpv renders at exactly `w` x `h` (what the host's GPU path asks for in a big or full-screen
    /// window; the software path of these tests is capped at 1280 px).
    fn frame_at(&self, w: u32, h: u32) -> Frame {
        let mut buf = FrameBuffer::default();
        let mut got = Frame::default();
        // A paused picture: the cue stays up while the big frames (slow in a debug build) are rendered.
        self.engine.pause();
        for _ in 0..8 {
            if self.engine.acquire_frame(w, h, &mut buf) == FrameStatus::New {
                got = Frame {
                    w: buf.width as usize,
                    h: buf.height as usize,
                    rgba: buf.rgba.clone(),
                };
            }
            std::thread::sleep(Duration::from_millis(60));
        }
        got
    }
}

fn keep(name: &str, f: &Frame) {
    if let Some(dir) = std::env::var_os("SWIFTLY_TEST_PNG_DIR") {
        let _ = std::fs::create_dir_all(&dir);
        f.image()
            .write_png(&PathBuf::from(dir).join(format!("sub-{name}.png")))
            .unwrap();
    }
}

fn shown(name: &str, t: &Title<'_>, look: Option<SubtitleLook>) -> (Ink, Frame) {
    let mut r = start(t, look, (1920.0, 1080.0));
    r.until(2.4);
    let f = r.frame_at(1920, 1080);
    keep(name, &f);
    assert!(
        f.h == 1080,
        "{name}: the picture is 1080 lines, got {}x{}",
        f.w,
        f.h
    );
    (ink_of(&f), f)
}

macro_rules! need {
    () => {
        match fx() {
            Some(f) => f,
            None => {
                eprintln!("no libmpv, ffmpeg or python3: skipped");
                return;
            }
        }
    };
}

fn off() -> SubtitleLook {
    SubtitleLook {
        keep_file_style: false,
        ..SubtitleLook::STANDARD
    }
}

// ---- lines 1-3: formats and the file-style switch ------------------------------------------------------------------

#[test]
fn a_text_subtitle_draws_only_when_chosen_embedded_and_external() {
    let fx = need!();
    let plain = title(fx.dir.join("emb_srt.mkv"), Some("subrip"), None, -1);
    assert!(
        !shown("srt-off", &plain, None).0.any(),
        "no subtitle chosen: nothing is drawn"
    );
    let (ink, _) = shown(
        "srt-embedded",
        &title(fx.dir.join("emb_srt.mkv"), Some("subrip"), None, 2),
        None,
    );
    assert!(
        ink.any() && ink.white > 1500 && ink.dark > 1500,
        "embedded SRT: white text with an outline {ink:?}"
    );
    for (name, file, codec, attribute) in [
        ("srt", "s.srt", "subrip", "srt"),
        ("vtt", "s.vtt", "webvtt", "vtt"),
    ] {
        let t = title(
            fx.dir.join("plain.mkv"),
            None,
            Some((fx.dir.join(file), codec, attribute)),
            5,
        );
        let (ink, _) = shown(&format!("external-{name}"), &t, None);
        assert!(
            ink.any() && ink.white > 1500,
            "external {name}: white text in the saved look {ink:?}"
        );
    }
}

#[test]
fn ass_uses_the_files_style_when_the_switch_is_on_and_the_look_when_it_is_off() {
    let fx = need!();
    let emb = title(fx.dir.join("emb_ass.mkv"), Some("ass"), None, 2);
    let ext = title(
        fx.dir.join("plain.mkv"),
        None,
        Some((fx.dir.join("s.ass"), "ass", "ass")),
        5,
    );
    for (name, t) in [("embedded", &emb), ("external", &ext)] {
        let (on, _) = shown(&format!("ass-{name}-on"), t, Some(SubtitleLook::STANDARD));
        assert!(
            on.red > 1500 && on.blue > 800 && on.white < 200,
            "{name}, switch on: the file's red fill and blue outline {on:?}"
        );
        let (off, _) = shown(&format!("ass-{name}-off"), t, Some(off()));
        assert!(
            off.white > 1500 && off.red < 100 && off.blue < 100 && off.dark > 1500,
            "{name}, switch off: the saved white look {off:?}"
        );
    }
}

#[test]
fn a_server_converted_srt_is_plain_text_and_takes_the_look_even_with_the_switch_on() {
    let fx = need!();
    let yellow = SubtitleLook {
        colour: Colour::Yellow,
        ..SubtitleLook::STANDARD
    };
    assert!(yellow.keep_file_style);
    let t = title(
        fx.dir.join("plain.mkv"),
        None,
        Some((fx.dir.join("s.srt"), "subrip", "srt")),
        5,
    );
    let (ink, _) = shown("converted-srt-yellow", &t, Some(yellow));
    assert!(
        ink.yellow > 1500 && ink.white < 300,
        "plain text in the look's yellow {ink:?}"
    );
}

#[test]
fn a_header_less_mkv_shows_its_embedded_subtitle() {
    let fx = need!();
    let (ink, _) = shown(
        "headerless",
        &title(fx.dir.join("headerless.mkv"), Some("subrip"), None, 2),
        None,
    );
    assert!(ink.any() && ink.white > 1500, "{ink:?}");
}

#[test]
fn a_pgs_bitmap_subtitle_is_drawn_into_the_picture() {
    let fx = need!();
    let t = title(fx.dir.join("pgs.mkv"), Some("hdmv_pgs_subtitle"), None, 2);
    let mut r = start(&t, None, (1920.0, 1080.0));
    // The set is on from 1 s to 3 s of the film: wait (the machine may be busy) until the bar shows, then until it is gone.
    let wait = |r: &mut Run, up: bool, limit: f64| {
        let end = r.t0.elapsed().as_secs_f64() + limit;
        while r.t0.elapsed().as_secs_f64() < end {
            let at = r.t0.elapsed().as_secs_f64() + 0.1;
            r.until(at);
            let bar = ink_of(&r.frame()).white > 20_000;
            if bar == up && r.frame().w > 0 {
                return true;
            }
        }
        false
    };
    r.until(0.4);
    assert!(ink_of(&r.frame()).white < 20_000, "no bar before its time");
    assert!(wait(&mut r, true, 12.0), "the PGS bar appears");
    let f = r.frame();
    keep("pgs", &f);
    let bar = ink_of(&f);
    // 200x24 of a 320x180 canvas on the picture: 62 % of the width, 13 % of the height.
    let (bw, bh) = (bar.width() / f.w as f64, bar.height() / f.h as f64);
    assert!(
        (bw - 0.625).abs() < 0.03 && (bh - 0.133).abs() < 0.03,
        "the bar is scaled to the picture {bar:?} ({bw:.3} x {bh:.3})"
    );
    assert!(wait(&mut r, false, 10.0), "and is gone again at 3 s");
}

// ---- lines 8-10: the look against the Apple reference --------------------------------------------------------------

fn like_reference(name: &str, reference: &str, look: SubtitleLook) {
    let fx = need_fx();
    let t = title(fx.dir.join("emb_srt.mkv"), Some("subrip"), None, 2);
    let (ink, f) = shown(name, &t, Some(look));
    let (want, want_gap) = ink_of_reference(reference);
    let gap = (f.h - 1 - ink.bbox.expect("ink").3) as f64;
    let close = |a: f64, b: f64, tol: f64, what: &str| {
        assert!(
            (a - b).abs() <= b * tol,
            "{name}: {what} {a:.1} vs the Apple reference {b:.1} (tolerance {:.0} %)",
            tol * 100.0
        )
    };
    close(ink.width(), want.width(), 0.06, "text width");
    close(
        ink.height(),
        want.height(),
        0.08,
        "text height (outline included)",
    );
    // 16 points at scale 1 on a 1080 line picture: the same place as the Apple overlay's ink, to 2 px.
    assert!(
        (gap - want_gap).abs() <= 2.0,
        "{name}: bottom gap {gap} px vs reference {want_gap} px"
    );
}

fn need_fx() -> &'static Fx {
    fx().expect("fixtures (checked by the caller)")
}

#[test]
fn the_default_look_has_the_size_and_outline_of_the_apple_reference() {
    need!();
    like_reference("look-default", "look-default.png", SubtitleLook::STANDARD);
}

#[test]
fn pauls_look_has_the_size_and_outline_of_the_apple_reference() {
    need!();
    let look = SubtitleLook {
        size: SubSize::Large,
        colour: Colour::Yellow,
        outline: Outline::Thin,
        shadow: true,
        background: false,
        position: Position::Bottom,
        keep_file_style: true,
    };
    like_reference("look-custom", "look-custom.png", look);
}

#[test]
fn the_raised_position_lifts_the_text_by_seven_percent_of_the_height() {
    need!();
    like_reference(
        "look-raised",
        "look-raised.png",
        SubtitleLook {
            position: Position::Raised,
            ..SubtitleLook::STANDARD
        },
    );
}

#[test]
fn the_background_box_is_dark_behind_the_text() {
    let fx = need!();
    let look = SubtitleLook {
        size: SubSize::Small,
        colour: Colour::Grey,
        outline: Outline::Off,
        shadow: false,
        background: true,
        position: Position::Bottom,
        keep_file_style: true,
    };
    let (ink, f) = shown(
        "look-box",
        &title(fx.dir.join("emb_srt.mkv"), Some("subrip"), None, 2),
        Some(look),
    );
    let (want, _) = ink_of_reference("look-box.png");
    assert!(ink.dark > 8000, "a dark box behind the text {ink:?}");
    let w = ink.width();
    assert!(
        (w - want.width()).abs() <= want.width() * 0.12,
        "box width {w} vs reference {}",
        want.width()
    );
    assert!(f.h >= 1000);
}

// ---- line 11: the look follows the saved setting ------------------------------------------------------------------

#[test]
fn the_saved_look_is_used_from_the_first_picture_and_a_change_applies_to_the_running_player() {
    let fx = need!();
    let t = title(fx.dir.join("emb_srt.mkv"), Some("subrip"), None, 2);
    let yellow = SubtitleLook {
        colour: Colour::Yellow,
        ..SubtitleLook::STANDARD
    };
    let mut r = start(&t, Some(yellow), (1920.0, 1080.0));
    // The very first frame that carries a subtitle is already yellow (no white flash of the default look).
    let mut first = None;
    while r.t0.elapsed().as_secs_f64() < 4.0 && first.is_none() {
        r.until(r.t0.elapsed().as_secs_f64() + 0.05);
        let ink = ink_of(&r.frame());
        if ink.any() {
            first = Some(ink);
        }
    }
    let first = first.expect("a subtitle appears");
    assert!(
        first.yellow > first.white * 4,
        "the first drawn subtitle is yellow {first:?}"
    );
    // The settings page writes a new look; the running player follows (this is also where a synced change lands).
    save_look(
        &r.store,
        &SubtitleLook {
            colour: Colour::White,
            size: SubSize::Huge,
            ..SubtitleLook::STANDARD
        },
    );
    let before = ink_of(&r.frame()).height();
    let t1 = r.t0.elapsed().as_secs_f64();
    r.until(t1 + 1.2);
    let after = ink_of(&r.frame());
    keep("sync-after", &r.frame());
    assert!(
        after.white > after.yellow * 4,
        "white after the change {after:?}"
    );
    assert!(
        after.height() > before * 1.3,
        "and much bigger ({before} -> {})",
        after.height()
    );
}

// ---- line 14: delay -------------------------------------------------------------------------------------------------

#[test]
fn the_subtitle_delay_moves_the_text_later() {
    let fx = need!();
    let t = title(fx.dir.join("emb_srt.mkv"), Some("subrip"), None, 2);
    let mut r = start(&t, None, (1920.0, 1080.0));
    r.until(1.5);
    assert!(
        ink_of(&r.frame()).any(),
        "the cue (0 to 5.5 s) is up at 1.5 s"
    );
    let now = r.now();
    r.screen.send_intent(
        PlayerIntent::SubtitleDelay(Delay::from_milliseconds(4000)),
        now,
    );
    let t1 = r.t0.elapsed().as_secs_f64();
    r.until(t1 + 0.8);
    assert!(
        !ink_of(&r.frame()).any(),
        "with +4 s the same cue only starts at 4 s"
    );
    let now = r.now();
    r.screen.send_intent(
        PlayerIntent::SubtitleDelay(Delay::from_milliseconds(0)),
        now,
    );
    let t1 = r.t0.elapsed().as_secs_f64();
    r.until(t1 + 0.8);
    assert!(ink_of(&r.frame()).any(), "and it is back with 0");
}

// ---- line 13: choose, switch, off, remembered ---------------------------------------------------------------------

#[test]
fn choosing_switching_and_turning_off_work_during_playback() {
    let fx = need!();
    let t = title(
        fx.dir.join("emb_srt.mkv"),
        Some("subrip"),
        Some((fx.dir.join("s.ass"), "ass", "ass")),
        -1,
    );
    let mut r = start(&t, None, (1280.0, 720.0));
    r.until(1.0);
    assert!(!ink_of(&r.frame()).any(), "nothing chosen: nothing drawn");
    let mut choose = |r: &mut Run, index: i64, secs: f64| {
        let now = r.now();
        r.screen
            .send_intent(PlayerIntent::SelectSubtitle(index), now);
        let to = r.t0.elapsed().as_secs_f64() + secs;
        r.until(to);
        ink_of(&r.frame())
    };
    let srt = choose(&mut r, 2, 0.8);
    assert!(
        srt.white > 500 && srt.red == 0,
        "the embedded SRT: white text {srt:?}"
    );
    let ass = choose(&mut r, 5, 0.8);
    assert!(
        ass.red > 100,
        "switched to the external ASS: its red fill {ass:?}"
    );
    let none = choose(&mut r, -1, 0.8);
    assert!(!none.any(), "off: nothing drawn {none:?}");
    let back = choose(&mut r, 2, 0.8);
    assert!(back.white > 500, "and on again {back:?}");
    // Remembered per title: the memory is wired by the planner path (`live_play.rs`), not by `PlayerScreen::live`, so this
    // harness cannot read it back; `--smoke-play` with `SWIFTLY_SMOKE_REOPEN=1` proves it through the real path.
}

/// Line 6: a title that lies on the device with the subtitle file that was downloaded with it plays offline through the
/// same screen, lists the file and draws it. Only files are read: there is no server in this test at all.
#[test]
fn a_downloaded_title_shows_the_subtitle_file_that_came_with_it() {
    let fx = need!();
    let dir = fx.dir.join("offline-subs");
    let _ = std::fs::remove_dir_all(&dir);
    let item = swiftly_downloads::DownloadItem::new(
        "m1",
        "acc",
        swiftly_downloads::Art::Film,
        "Film",
        10,
        1.0,
    );
    let file = dir.join(item.file_name());
    let folder = dir.join(item.subtitle_folder_name());
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::copy(fx.dir.join("plain.mkv"), &file).unwrap();
    std::fs::write(folder.join("3.srt"), SRT).unwrap();
    let spec = swiftly_desktop::live_offline::offline_spec(&item, &file, 0.0).unwrap();
    assert_eq!(
        spec.request.subtitle_files.len(),
        1,
        "the file that came with the title is handed to the engine"
    );
    let mut r = start_spec(spec, 3, None, (1280.0, 720.0));
    r.until(2.0);
    let lit = ink_of(&r.frame());
    assert!(
        lit.white > 500,
        "the downloaded subtitle file is drawn offline: {lit:?}"
    );
}

// ---- line 14: timing after seek, pause, speed ------------------------------------------------------------------------

/// Plays for `secs` and checks every NEW frame against the cue windows (1-2, 4-5, 8-9 s of the media clock) by the media
/// time stamped on that frame (the engine's clock read in the same call as the frame, `Run::stamp`): a cue is up well
/// inside its window and gone well outside it. The slack is only the 0.15 s the clock and the drawn subtitle can differ
/// by (one vsync and the decoder's lead); the polled position of the screen is half a second older and is not used.
fn watch(r: &mut Run, secs: f64, what: &str) {
    const CUES: [(f64, f64); 3] = [(1.0, 2.0), (4.0, 5.0), (8.0, 9.0)];
    const SLACK: f64 = 0.15;
    let end = r.t0.elapsed().as_secs_f64() + secs;
    let (mut inside, mut outside, mut seen, mut last) = (0, 0, 0, r.stamp().0);
    while r.t0.elapsed().as_secs_f64() < end {
        r.until(r.t0.elapsed().as_secs_f64() + 0.01);
        let (count, pos) = r.stamp();
        if count == last {
            continue;
        }
        last = count;
        let lit = ink_of(&r.frame()).any();
        seen += 1;
        if std::env::var_os("SWIFTLY_WATCH_TRACE").is_some() {
            eprintln!(
                "{what}: frame at {pos:.2} s {}",
                if lit { "CUE" } else { "-" }
            );
        }
        if CUES
            .iter()
            .any(|(a, b)| pos >= a + SLACK && pos <= b - SLACK)
        {
            inside += 1;
            assert!(
                lit || std::env::var_os("SWIFTLY_WATCH_TRACE").is_some(),
                "{what}: no cue on the frame at {pos:.2} s"
            );
        } else if CUES.iter().all(|(a, b)| pos < a - SLACK || pos > b + SLACK) {
            outside += 1;
            assert!(
                !lit,
                "{what}: a cue on the frame at {pos:.2} s, between the cues"
            );
        }
    }
    assert!(seen > 5, "{what}: too few frames ({seen})");
    eprintln!("{what}: {seen} frames, {inside} inside cues, {outside} between");
}

#[test]
fn the_cue_stays_on_time_after_seek_pause_and_speed() {
    let fx = need!();
    let t = title(fx.dir.join("timing.mkv"), Some("subrip"), None, 2);
    let mut r = start(&t, None, (1280.0, 720.0));
    r.until(0.8);
    let go = |r: &mut Run, intent: PlayerIntent| {
        let now = r.now();
        r.screen.send_intent(intent, now);
    };
    // Seek forward into a cue, back into a gap, back into an earlier cue.
    go(&mut r, PlayerIntent::SeekTo(7.6));
    r.until(r.t0.elapsed().as_secs_f64() + 0.4);
    watch(&mut r, 2.0, "seek forward");
    go(&mut r, PlayerIntent::SeekTo(2.5));
    r.until(r.t0.elapsed().as_secs_f64() + 0.4);
    watch(&mut r, 2.4, "seek back to a gap");
    // Pause inside the second cue: it stays up while paused; resumed, it goes on time.
    go(&mut r, PlayerIntent::SeekTo(4.2));
    r.until(r.t0.elapsed().as_secs_f64() + 0.6);
    go(&mut r, PlayerIntent::TogglePlay);
    r.until(r.t0.elapsed().as_secs_f64() + 0.5);
    let paused_at = r.screen.vm().transport().position;
    assert!(ink_of(&r.frame()).any(), "paused inside a cue: it stays up");
    r.until(r.t0.elapsed().as_secs_f64() + 1.5);
    assert!(
        (r.screen.vm().transport().position - paused_at).abs() < 0.3,
        "paused: the clock stands"
    );
    assert!(ink_of(&r.frame()).any(), "still up after 1.5 s of pause");
    go(&mut r, PlayerIntent::TogglePlay);
    // Right after the resume the frames inside the 4-5 s cue carry it (W44 saw none at 4.64 s by the polled position).
    watch(&mut r, 1.0, "after resume");
    assert!(
        r.screen.vm().transport().position > paused_at + 0.5,
        "resumed: the clock runs"
    );
    // Double speed: the cues follow the media clock, not the wall clock.
    go(&mut r, PlayerIntent::SeekTo(0.2));
    go(&mut r, PlayerIntent::Tempo(2.0));
    r.until(r.t0.elapsed().as_secs_f64() + 0.5); // the frame of the old position is gone
    watch(&mut r, 5.0, "speed 2x");
}

/// A quality change plans the same title again at its position (`PlayerIntent::Quality`) and the new stream loads there.
#[test]
fn a_quality_change_replans_at_the_position_and_the_cue_stays_on_time() {
    let fx = need!();
    let t = title(fx.dir.join("timing.mkv"), Some("subrip"), None, 2);
    // The re-plan names the track that plays now (the real planner reads it from the track memory).
    let mut again = spec_of(&t);
    again.subtitle_index = 2;
    let planner = Arc::new(BurnedPlanner {
        asks: Mutex::new(Vec::new()),
        spec: Mutex::new(Some(again)),
    });
    let mut r = start(&t, None, (1280.0, 720.0));
    r.screen
        .set_planner(Arc::clone(&planner) as Arc<dyn Planner>);
    r.until(0.8);
    let now = r.now();
    r.screen.send_intent(PlayerIntent::SeekTo(2.6), now);
    r.until(r.t0.elapsed().as_secs_f64() + 0.5);
    let now = r.now();
    r.screen
        .send_intent(PlayerIntent::Quality(Some(4_000_000)), now);
    // The reload takes a moment; from then on every frame is judged by its own media time (the 4-5 s cue ahead).
    r.until(r.t0.elapsed().as_secs_f64() + 0.4);
    {
        let asks = planner.asks.lock().unwrap();
        assert_eq!(asks.len(), 1, "one re-plan is asked for");
        assert!(
            asks[0].reload && asks[0].since > 2.0 && asks[0].since < 4.0,
            "the same title at its position: {:?}",
            asks[0]
        );
    }
    watch(&mut r, 3.0, "after the quality change");
}

// ---- line 15: full screen ------------------------------------------------------------------------------------------

#[test]
fn the_text_keeps_its_share_of_the_picture_in_a_big_full_screen_window() {
    let fx = need!();
    let t = title(fx.dir.join("emb_srt.mkv"), Some("subrip"), None, 2);
    let mut r = start(&t, None, (1280.0, 720.0));
    r.until(2.2);
    let mut seen = Vec::new();
    for (w, h) in [(1280, 720), (1920, 1080), (2560, 1440), (1920, 1080)] {
        let f = r.frame_at(w, h);
        keep(&format!("size-{h}"), &f);
        let i = ink_of(&f);
        assert!(i.any() && i.white > 100, "text at {h} lines {i:?}");
        seen.push((
            h as f64,
            i.height() / f64::from(h),
            (f.h - 1 - i.bbox.unwrap().3) as f64 / f64::from(h),
        ));
    }
    for (h, share, gap) in &seen {
        // The window stays 1280x720 points: a bigger frame is a sharper picture of the same window (a Retina
        // screen), so text share and the gap's share of the picture stay the same (16 points = 16 / 720 of it).
        assert!(
            (share - seen[1].1).abs() < 0.006,
            "text share at {h} lines: {share:.4} vs {:.4} at 1080",
            seen[1].1
        );
        assert!(
            (gap - seen[1].2).abs() < 0.003,
            "bottom gap at {h} lines: {gap:.4} of the height, expected {:.4}",
            seen[1].2
        );
    }
    // Back at 1080 after the big size: the same picture as before.
    assert!((seen[3].1 - seen[1].1).abs() < 0.002);
}

// ---- line 5: the transcode reload with the real engine --------------------------------------------------------------

/// A tiny HTTP server for one file with range support (the transcode's stream address).
fn serve(file: PathBuf) -> u16 {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let file = file.clone();
            std::thread::spawn(move || {
                let mut conn = conn;
                let mut req = vec![0_u8; 4096];
                let n = conn.read(&mut req).unwrap_or(0);
                let text = String::from_utf8_lossy(&req[..n]).to_string();
                let mut f = std::fs::File::open(&file).unwrap();
                let len = f.metadata().unwrap().len();
                let start = text
                    .lines()
                    .find_map(|l| {
                        l.to_lowercase().strip_prefix("range: bytes=").map(|r| {
                            r.split('-')
                                .next()
                                .unwrap_or("0")
                                .trim()
                                .parse::<u64>()
                                .unwrap_or(0)
                        })
                    })
                    .unwrap_or(0);
                let ranged = text.to_lowercase().contains("range: bytes=");
                f.seek(SeekFrom::Start(start)).unwrap();
                let mut body = Vec::new();
                f.read_to_end(&mut body).unwrap();
                let head = if ranged {
                    format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Type: video/x-matroska\r\nAccept-Ranges: bytes\r\nContent-Range: bytes {start}-{}/{len}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        len - 1,
                        body.len()
                    )
                } else {
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: video/x-matroska\r\nAccept-Ranges: bytes\r\nContent-Length: {len}\r\nConnection: close\r\n\r\n"
                    )
                };
                let _ = conn.write_all(head.as_bytes());
                let _ = conn.write_all(&body);
            });
        }
    });
    port
}

struct BurnedPlanner {
    asks: Mutex<Vec<PlanAsk>>,
    spec: Mutex<Option<PlayerSpec>>,
}

impl Planner for BurnedPlanner {
    fn plan(&self, ask: PlanAsk) -> Pending<Result<Switched, String>> {
        let (tx, rx) = Pending::channel();
        let mut spec = self.spec.lock().unwrap().clone().unwrap();
        spec.start_at = ask.since;
        // A plain re-plan keeps the track that plays now (the real planner reads it from the track memory).
        spec.subtitle_index = ask.subtitle.unwrap_or(spec.subtitle_index);
        self.asks.lock().unwrap().push(ask);
        let _ = tx.send(Ok(Switched::bare(spec, ("Sub".into(), "burned".into()))));
        rx
    }
    fn quality(&self) -> Quality {
        Quality {
            direct_play: true,
            limit: 0,
        }
    }
    fn save_quality(&self, _quality: Quality) {}
    fn prepare_next(&self, _ask: PlanAsk) {}
    fn forget_prepared(&self) {}
}

#[test]
fn a_bitmap_subtitle_picked_during_a_transcode_reloads_the_stream_at_the_same_position() {
    let fx = need!();
    let port = serve(fx.dir.join("plain.mkv"));
    let mut t = title(fx.dir.join("plain.mkv"), None, None, -1);
    let url = format!(
        "http://127.0.0.1:{port}/videos/sub/stream.mkv?VideoCodec=h264&TranscodeReasons=VideoCodecNotSupported"
    );
    t.transcode = Some(url);
    let mut spec = spec_of(&t);
    spec.request
        .streams
        .push(stream(4, "Subtitle", "hdmv_pgs_subtitle", false));
    // The same title with the picture subtitle burned in: the transcode would deliver a different picture.
    let burned = title(fx.dir.join("burned.mkv"), None, None, 4);
    let planner = Arc::new(BurnedPlanner {
        asks: Mutex::new(Vec::new()),
        spec: Mutex::new(Some(spec_of(&burned))),
    });
    let mut r = start(&t, None, (1280.0, 720.0));
    // `start` built the spec from `t`; add the bitmap track the server lists.
    r.screen.vm().load_title(spec, 0.0);
    r.screen
        .set_planner(Arc::clone(&planner) as Arc<dyn Planner>);
    r.until(2.2);
    let centre = |f: &Frame| f.px(f.w / 2, f.h / 2);
    assert!(
        centre(&r.frame())[0] > 80,
        "the plain picture (grey) plays first: {:?}",
        centre(&r.frame())
    );
    let now = r.now();
    r.screen.send_intent(PlayerIntent::SelectSubtitle(4), now);
    let t1 = r.t0.elapsed().as_secs_f64();
    r.until(t1 + 3.0);
    let asks = planner.asks.lock().unwrap();
    assert_eq!(asks.len(), 1, "one reload is planned");
    assert!(
        asks[0].reload && asks[0].subtitle == Some(4),
        "{:?}",
        asks[0]
    );
    assert!(
        asks[0].since > 1.0 && asks[0].since < 4.0,
        "at the same position, not from the start ({})",
        asks[0].since
    );
    let c = centre(&r.frame());
    assert!(
        c[0] < 60 && c[2] > 80,
        "the new stream (blue) is on screen: {c:?}"
    );
    drop(asks);
    let _ = &r.engine;
}

// ---- line 10: Arabic, Hebrew, Devanagari, Thai ---------------------------------------------------------------------

/// The lit (white fill) pixels of the lower 40 % of a frame: bounding box and a mask over it.
struct Lit {
    x0: usize,
    x1: usize,
    y0: usize,
    y1: usize,
    on: Vec<bool>,
}

impl Lit {
    fn of(f: &Frame) -> Lit {
        let (from, mut b) = (f.h * 6 / 10, (usize::MAX, 0, usize::MAX, 0));
        let on: Vec<bool> = (from..f.h)
            .flat_map(|y| (0..f.w).map(move |x| (x, y)))
            .map(|(x, y)| f.px(x, y).iter().min().is_some_and(|m| *m > 190))
            .collect();
        for (i, v) in on.iter().enumerate() {
            if *v {
                let (x, y) = (i % f.w, from + i / f.w);
                b = (b.0.min(x), b.1.max(x), b.2.min(y), b.3.max(y));
            }
        }
        Lit {
            x0: b.0,
            x1: b.1,
            y0: b.2,
            y1: b.3,
            on,
        }
    }
    fn count(&self) -> usize {
        self.on.iter().filter(|v| **v).count()
    }
    fn width(&self) -> usize {
        if self.count() == 0 {
            0
        } else {
            self.x1 - self.x0 + 1
        }
    }
}

fn cue_frame(name: &str) -> Frame {
    let fx = need_fx();
    let (_, f) = shown(
        name,
        &title(
            fx.dir.join(format!("c_{name}.mkv")),
            Some("subrip"),
            None,
            2,
        ),
        None,
    );
    f
}

#[test]
fn arabic_hebrew_devanagari_and_thai_draw_real_glyphs() {
    need!();
    for (script, a, b) in [
        ("arabic", "ar_a", "ar_b"),
        ("hebrew", "he_a", "he_b"),
        ("devanagari", "hi_a", "hi_b"),
        ("thai", "th_a", "th_b"),
    ] {
        let (fa, fb) = (cue_frame(a), cue_frame(b));
        let (la, lb) = (Lit::of(&fa), Lit::of(&fb));
        assert!(
            la.count() > 400 && lb.count() > 400,
            "{script}: nothing drawn ({} / {} lit pixels)",
            la.count(),
            lb.count()
        );
        assert!(
            la.width() as f64 > fa.w as f64 * 0.04,
            "{script}: the line is far too narrow ({} px)",
            la.width()
        );
        // Two different letters must look different; the same missing-glyph box for both would be identical.
        let differ = fa
            .rgba
            .chunks_exact(4)
            .zip(fb.rgba.chunks_exact(4))
            .skip(fa.w * (fa.h * 6 / 10))
            .filter(|(p, q)| p[..3] != q[..3])
            .count();
        assert!(
            differ > la.count() / 4,
            "{script}: two different letters draw the same picture ({differ} differing pixels): no glyphs, only boxes"
        );
    }
}

#[test]
fn a_hebrew_line_with_a_latin_word_runs_right_to_left() {
    need!();
    let (mixed, word) = (Lit::of(&cue_frame("rtl")), Lit::of(&cue_frame("abc")));
    let (w, h) = (word.x1 - word.x0 + 1, word.y1 - word.y0 + 1);
    // Where does the word "ABC" sit in the mixed line: at its left end (right-to-left paragraph) or at its right end?
    let hits = |x_at: usize| -> usize {
        let (fw, from) = (1920, 1080 * 6 / 10);
        let mut best = 0;
        for dy in -4i64..=4 {
            let mut n = 0;
            for yy in 0..h {
                for xx in 0..w {
                    if !word.on[(word.y0 - from + yy) * fw + word.x0 + xx] {
                        continue;
                    }
                    let y = (mixed.y1 as i64 - (h - 1) as i64 + yy as i64 + dy) as usize - from;
                    n += usize::from(mixed.on.get(y * fw + x_at + xx).copied().unwrap_or(false));
                }
            }
            best = best.max(n);
        }
        best
    };
    let (left, right) = (hits(mixed.x0), hits(mixed.x1 + 1 - w));
    assert!(
        left > right * 2 && left * 2 > word.count(),
        "the Latin word should sit at the left end of a right-to-left line (left {left}, right {right}, of {})",
        word.count()
    );
}

// ---- lines 8/9: the fill is a full stem, the outline is thinner than it ----------------------------------------------

#[test]
fn the_default_look_has_a_full_stem_and_a_thinner_outline() {
    let fx = need!();
    let (_, f) = shown(
        "stem",
        &title(fx.dir.join("c_ill.mkv"), Some("subrip"), None, 2),
        None,
    );
    let lum =
        |x: usize, y: usize| -> u32 { f.px(x, y).iter().map(|v| u32::from(*v)).sum::<u32>() / 3 };
    let lit = |x: usize, y: usize| f.px(x, y).iter().min().is_some_and(|m| *m > 200);
    // The row with the most lit pixels, as the Apple test takes it.
    let row = ((f.h * 7 / 10)..f.h)
        .max_by_key(|y| (0..f.w).filter(|x| lit(*x, *y)).count())
        .unwrap();
    let (mut stems, mut rims, mut first) = (Vec::new(), Vec::new(), None);
    let mut x = 0;
    while x < f.w {
        if lit(x, row) {
            let mut e = x;
            while e < f.w && lit(e, row) {
                e += 1;
            }
            first.get_or_insert(x + (e - x) / 2);
            stems.push(e - x);
            rims.push(
                (x.saturating_sub(8)..x)
                    .filter(|c| lum(*c, row) < 50)
                    .count(),
            );
            x = e;
        } else {
            x += 1;
        }
    }
    assert!(stems.len() >= 3, "no stems found");
    // The em from the height of the first stem's column (Inter's ascender is about 0.74 em).
    let cx = first.unwrap();
    let (mut top, mut bottom) = (row, row);
    while lit(cx, top - 1) {
        top -= 1;
    }
    while lit(cx, bottom + 1) {
        bottom += 1;
    }
    let em = (bottom - top + 1) as f64 / 0.74;
    stems.sort_unstable();
    rims.sort_unstable();
    let (stem, rim) = (stems[stems.len() / 2] as f64, rims[rims.len() / 2] as f64);
    eprintln!(
        "stem {stem} px ({:.3} em), outline {rim} px ({:.3} em), em {em:.0} px",
        stem / em,
        rim / em
    );
    assert!(
        stem / em > 0.09 && stem / em < 0.18,
        "stem {stem} px of an em of {em:.0}: not the font's own weight"
    );
    assert!(
        rim <= stem * 0.6,
        "outline {rim} px against a stem of {stem} px: letters must be clearly heavier than the outline"
    );
    assert!(rim >= 1.0, "no outline beside the stem");
}

// ---- line 8a: the bottom margin is 16 points, measured above the picture's bottom edge --------------------------

/// Gap in frame pixels between the lowest ink and the bottom of the picture the engine rendered, for a window of
/// `window` physical pixels at `scale`, playing `file`; the frame is what the GPU path asks for (the picture fitted into
/// the window).
fn gap_in(file: &str, look: SubtitleLook, window: (u32, u32), scale: f64) -> (f64, usize) {
    let fx = need_fx();
    let t = title(fx.dir.join(file), Some("subrip"), None, 2);
    let mut r = start_scaled(
        spec_of(&t),
        t.select,
        Some(look),
        (f64::from(window.0), f64::from(window.1)),
        scale,
    );
    r.until(2.4);
    let f = r.frame_at(window.0, window.1);
    keep(&format!("gap-{file}-{scale}"), &f);
    let i = ink_of(&f);
    assert!(i.any(), "{file} at scale {scale}: no text {i:?}");
    let gap = (f.h - 1 - i.bbox.unwrap().3) as f64;
    (gap, f.h)
}

#[test]
fn the_bottom_gap_is_sixteen_points_at_every_ui_scale() {
    need!();
    // The picture is 1920x1080 pixels in all three: a 1920x1080 window at scale 1, the same pixels as 1280x720 points
    // at 1.5 and 960x540 points at 2. The ink sits 16 points + the same share of the text's box above the edge.
    let (g1, _) = gap_in("emb_srt.mkv", SubtitleLook::STANDARD, (1920, 1080), 1.0);
    let (g15, _) = gap_in("emb_srt.mkv", SubtitleLook::STANDARD, (1920, 1080), 1.5);
    let (g2, _) = gap_in("emb_srt.mkv", SubtitleLook::STANDARD, (1920, 1080), 2.0);
    assert!(
        (g15 - g1 - 8.0).abs() <= 1.5,
        "scale 1.5: gap {g15} px, scale 1: {g1} px (expected +8)"
    );
    assert!(
        (g2 - g1 - 16.0).abs() <= 1.5,
        "scale 2: gap {g2} px, scale 1: {g1} px (expected +16)"
    );
}

#[test]
fn a_letterboxed_picture_keeps_the_text_sixteen_points_above_the_pictures_bottom_not_the_windows() {
    need!();
    let (g1, _) = gap_in("emb_srt.mkv", SubtitleLook::STANDARD, (1920, 1080), 1.0);
    // 2.39:1 (1920x804) in a 16:9 window: the picture is 804 px tall, the bars are not part of it. The text box below
    // the ink scales with the picture, the 16 points do not.
    let box_share = (g1 - 16.0) / 1080.0;
    for scale in [1.0, 2.0] {
        let (g, h) = gap_in("wide.mkv", SubtitleLook::STANDARD, (1920, 1080), scale);
        assert!(
            (800..=806).contains(&h),
            "the frame is the picture, not the window: {h} lines"
        );
        let want = 16.0 * scale + box_share * h as f64;
        assert!(
            (g - want).abs() <= 1.5,
            "scale {scale}: gap {g} px above the picture's bottom, expected {want:.1}"
        );
        assert!(
            g < 100.0,
            "gap {g} px: measured from the picture, not the 138 px bar"
        );
    }
    // Raised: 16 points plus 7 % of the picture's height.
    let raised = SubtitleLook {
        position: Position::Raised,
        ..SubtitleLook::STANDARD
    };
    let (g, h) = gap_in("wide.mkv", raised, (1920, 1080), 1.0);
    let want = 16.0 + 0.07 * h as f64 + box_share * h as f64;
    assert!(
        (g - want).abs() <= 2.0,
        "raised: gap {g} px, expected {want:.1}"
    );
}
