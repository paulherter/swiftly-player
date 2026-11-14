//! The Player screen of the shared Rust UI for `touch`, `desktop` and `tv`, drawn from `PlayerVm` parts over a
//! [`VideoSurface`] seam (gate G3 puts libmpv / Media3 behind it; until then [`TestPattern`] draws a test picture).
//! Numbers and behaviour come from the iOS `PlayerScreen` / `TimeRow` / `PlayerMetric`, the Mac key shortcuts and the
//! tvOS `TimeBar`; differences are noted in the code.

use crate::detail_screen::{fill_frame, ins, rgba, txt};
use crate::home::Form;
use crate::player_card::{self, CardLook, CardMotion};
use crate::player_glyphs::Glyphs;
use crate::player_host::{
    EpisodeCardData, EpisodeSource, PlanAsk, Planner, PlayerCalls, SeasonRow, SwitchState,
};
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::{Arc, Mutex, PoisonError};
use swiftly_design::tokens::colour;
use swiftly_jellyfin::{PlayMethod, ReportPlan};
use swiftly_layout::{Align, Alignment, Axis};
use swiftly_model::MediaStream;
use swiftly_playback::engine::{
    EngineEvent, EngineLoad, EngineState, PipCmd, PlaybackEngine, Rect, SubtitleRoute,
};
use swiftly_playback::player_state::EngineRequest;
use swiftly_playback::sections::{Art, Segment};
use swiftly_render::{Color, DrawList, LinearGradient, RgbaImage};
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_rules::chapter::Chapter;
use swiftly_rules::delay::Delay;
use swiftly_settings::{JsonFileStore, KeyValueStore, Value};
use swiftly_ui::components::{color, focus_id};
use swiftly_ui::popover::{
    self, Anchor, MenuController, MenuEntry, MenuItem, MenuKey, MenuOutcome,
};
use swiftly_ui::{
    Action, Cx, Env, FocusLook, Motion, NavKey, Node, Paint, ScopeSpec, Ui, UiEvent, VideoFrame,
};
use swiftly_vm::{
    ControlsPart, NextEpisode, Nudge, OfferPart, OfferView, Phase, PlayerIntent, PlayerLayer,
    PlayerPrefs, PlayerSpec, PlayerVm, Quality, ReportMessage, Reporter, TracksPart, TransportPart,
};

/// Seconds a `notify` line stays (`PlayerScreen.swift:1603-1609`).
pub const NOTICE_SECONDS: f64 = 3.0;
/// Seconds a tap waits for its second (`PlayerScreen.doubleTap`).
pub const DOUBLE_TAP: f64 = 0.26;
/// Seconds a running seek chain waits for the next tap (`PlayerScreen.chainTap`).
pub const CHAIN_TAP: f64 = 0.5;
/// How far (points) a press on the bare background must travel before it is a window drag and no tap.
const WINDOW_DRAG_SLOP: f32 = 4.0;
/// Pinch thresholds of the Swift `MagnifyGesture`.
pub const PINCH_IN: f64 = 1.15;
/// See [`PINCH_IN`].
pub const PINCH_OUT: f64 = 0.85;
/// Sleep timer choices in minutes (`SleepTimes.values`, from the core).
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub const SLEEP_CHOICES: [u32; 5] = {
    let s = swiftly_rules::playback_levels::SLEEP_TIMES;
    [
        s[0] as u32,
        s[1] as u32,
        s[2] as u32,
        s[3] as u32,
        s[4] as u32,
    ]
};
/// Speed choices (`SpeedLevels.values`, from the core).
pub const TEMPOS: [f32; 5] = swiftly_rules::playback_levels::SPEED_VALUES;
/// Quality caps in Mbit/s after "Originalqualität".
/// `Bitrate.levels`; 0 is "Unbegrenzt".
pub const QUALITY_CAPS: [i64; 6] = swiftly_rules::playback_selection::BITRATE_LEVELS;

/// The TV the demo screen can hand a film to (`PlayOutputs.targets`); the live player asks the account's devices.
const DEMO_TARGET: &str = "Wohnzimmer";
/// Seconds the error strip of the group stays (`SharedError`).
const ERROR_SECONDS: f64 = 4.0;
/// The demo season (the made-up player): number, title, minutes, watched share, watched.
const DEMO_EPISODES: [(u32, &str, u32, f32, bool); 6] = [
    (1, "Der Hafen", 46, 0.0, true),
    (2, "Die Nachricht", 44, 0.0, true),
    (3, "Nordlicht", 47, 0.3, false),
    (4, "Die Rückkehr", 45, 0.0, false),
    (5, "Schwarzes Eis", 48, 0.0, false),
    (6, "Das Ende der Nacht", 52, 0.0, false),
];

/// The made-up player's episodes: three seasons, the first six episodes in every one, the third running.
struct DemoEpisodes;

impl crate::player_host::EpisodeSource for DemoEpisodes {
    fn seasons(
        &self,
        _series: &str,
        _hint: Option<&str>,
    ) -> crate::login_screen::Pending<Option<(Vec<SeasonRow>, usize)>> {
        let (tx, rx) = crate::login_screen::Pending::channel();
        let rows = (1..=3)
            .map(|n| SeasonRow {
                id: format!("demo-s{n}"),
                name: format!("Staffel {n}"),
            })
            .collect();
        let _ = tx.send(Some((rows, 0)));
        rx
    }

    fn episodes(
        &self,
        _series: &str,
        _season: &str,
    ) -> crate::login_screen::Pending<Option<Vec<EpisodeCardData>>> {
        let (tx, rx) = crate::login_screen::Pending::channel();
        let cards = DEMO_EPISODES
            .iter()
            .map(|(n, title, minutes, share, watched)| EpisodeCardData {
                // The running one has the demo player's own id.
                id: if *n == 3 {
                    "demo-ep".to_owned()
                } else {
                    format!("demo-e{n}")
                },
                title: (*title).to_owned(),
                header: format!("F{n} · {title}"),
                sub: Some(format!("{minutes} Min.")),
                progress: (*share > 0.0).then_some(*share),
                watched: *watched,
                image: None,
            })
            .collect();
        let _ = tx.send(Some(cards));
        rx
    }

    fn still(&self, _id: &str, _address: Option<&str>) -> player_card::StillSource {
        Arc::new(|| None)
    }
}

/// The seasons on their way: the rows and the index to open on.
type SeasonsWait = crate::login_screen::Pending<Option<(Vec<SeasonRow>, usize)>>;

/// An episode list on its way: the season index it was asked for and the answer.
type CardsWait = (
    usize,
    crate::login_screen::Pending<Option<Vec<EpisodeCardData>>>,
);

/// What the made-up player's overlay says about its made-up file.
fn demo_tech() -> crate::player_host::TechFacts {
    let mut video = stream(0, "Video", "", "h264");
    video.width = Some(1920);
    video.height = Some(1080);
    let mut audio = stream(1, "Audio", "ger", "eac3");
    audio.channels = Some(6);
    crate::player_host::TechFacts {
        delivery: "Direct Play".to_owned(),
        good: true,
        video: Some(video),
        audios: vec![audio],
        subtitles: Vec::new(),
        container: Some("mkv".to_owned()),
        size: Some(2_100_000_000),
        reason: None,
    }
}

/// A shared frame surface as the seam type.
struct RcSurface(Rc<crate::frame_surface::FrameSurface>);

impl VideoSurface for RcSurface {
    fn node(&self, w: f32, h: f32, fill: bool, position: f64) -> Node {
        self.0.node(w, h, fill, position)
    }
}

// ---- the seam ----------------------------------------------------------------------------------------------------

/// Where the picture comes from. The real one hands the rect to libmpv / Media3 (`PlaybackEngine::place`) and draws
/// nothing; the placeholder draws a test picture so frames can be compared.
pub trait VideoSurface {
    /// The node that fills the screen under the UI; `fill` crops instead of fitting.
    fn node(&self, w: f32, h: f32, fill: bool, position: f64) -> Node;
}

/// A colour-bar test picture with a slow gradient so a seek is visible.
pub struct TestPattern;

impl VideoSurface for TestPattern {
    fn node(&self, w: f32, h: f32, _fill: bool, position: f64) -> Node {
        let shift = ((position / 600.0).fract() as f32).clamp(0.0, 1.0);
        let a = Color::new(0.10 + 0.2 * shift, 0.18, 0.34, 1.0);
        let b = Color::new(0.04, 0.30 - 0.1 * shift, 0.30, 1.0);
        let base = Node::rect(a, 0.0).paint(Paint::Linear {
            gradient: LinearGradient {
                start: a,
                end: b,
                from: [0.0, 0.0],
                to: [1.0, 1.0],
            },
            radius: 0.0,
        });
        let bars: Vec<Node> = [
            (0.9, 0.9, 0.9),
            (0.9, 0.9, 0.1),
            (0.1, 0.8, 0.8),
            (0.1, 0.8, 0.1),
            (0.8, 0.1, 0.8),
            (0.8, 0.1, 0.1),
            (0.1, 0.1, 0.8),
        ]
        .iter()
        .map(|&(r, g, bl)| {
            Node::rect(Color::new(r, g, bl, 1.0), 0.0).frame(
                Some(w / 7.0),
                Some(h * 0.18),
                Alignment::CENTER,
            )
        })
        .collect();
        let band = Node::hstack(Align::Start, Some(0.0), bars);
        Node::zstack(
            Alignment::TOP_LEADING,
            vec![
                base.frame(Some(w), Some(h), Alignment::CENTER),
                band.padding(ins(h * 0.3, 0.0, 0.0, 0.0)),
            ],
        )
        .frame(Some(w), Some(h), Alignment::TOP_LEADING)
    }
}

// ---- the fake engine ---------------------------------------------------------------------------------------------

#[derive(Default)]
struct Sim {
    playing: bool,
    position: f64,
    rate: f32,
    changed: Option<bool>,
    sought: bool,
    calls: Vec<String>,
}

/// Any engine behind the player view model (the made-up one or libmpv).
pub struct DynEngine(pub Arc<dyn PlaybackEngine>);

impl PlaybackEngine for DynEngine {
    fn load(&self, request: EngineLoad) {
        self.0.load(request);
    }
    fn play(&self) {
        self.0.play();
    }
    fn pause(&self) {
        self.0.pause();
    }
    fn seek(&self, seconds: f64) {
        self.0.seek(seconds);
    }
    fn set_rate(&self, tempo: f32) {
        self.0.set_rate(tempo);
    }
    fn set_volume(&self, percent: u8) {
        self.0.set_volume(percent);
    }
    fn set_audio_delay(&self, milliseconds: i32) {
        self.0.set_audio_delay(milliseconds);
    }
    fn select_audio(&self, server_index: i32) -> bool {
        self.0.select_audio(server_index)
    }
    fn select_subtitle(&self, server_index: i32) -> SubtitleRoute {
        self.0.select_subtitle(server_index)
    }
    fn set_subtitle_delay(&self, milliseconds: i32) {
        self.0.set_subtitle_delay(milliseconds);
    }
    fn set_subtitle_style(&self, style: &swiftly_playback::engine::SubtitleTextStyle) {
        self.0.set_subtitle_style(style);
    }
    fn set_audio_output(&self, mode: &swiftly_playback::decoder_choice::AudioOutputMode) {
        self.0.set_audio_output(mode);
    }
    fn set_fill(&self, on: bool) {
        self.0.set_fill(on);
    }
    fn place(&self, rect: Rect) {
        self.0.place(rect);
    }
    fn stop(&self, reset_display: bool) {
        self.0.stop(reset_display);
    }
    fn pip(&self, command: PipCmd) {
        self.0.pip(command);
    }
}

/// Any reporter behind the player view model.
pub struct DynReporter(pub Arc<dyn Reporter>);

impl Reporter for DynReporter {
    fn report(&self, message: ReportMessage) {
        self.0.report(message);
    }
}

/// What a real engine adds to the screen: events to pull and frames to draw.
pub trait LiveEngine: Send + Sync {
    /// Engine events since the last call.
    fn events(&self) -> Vec<EngineEvent>;
    /// Hands the newest frame (scaled to fit the box) to `sink` when a new one is there.
    fn frame(&self, max_w: u32, max_h: u32, sink: &mut dyn FnMut(u32, u32, &[u8]));
    /// The size of the picture in the file, when the engine knows it (the GPU path never asks for more).
    fn source_size(&self) -> Option<(u32, u32)> {
        None
    }
    /// Like [`LiveEngine::frame`], but swaps the finished frame into `out` (`true` when a new one is there), so a
    /// 4K frame is never copied. The default copies.
    fn frame_swap(&self, max_w: u32, max_h: u32, out: &mut swiftly_ui::VideoFrame) -> bool {
        let mut got = false;
        self.frame(max_w, max_h, &mut |w, h, rgba| {
            out.w = w;
            out.h = h;
            out.rgba.clear();
            out.rgba.extend_from_slice(rgba);
            got = true;
        });
        got
    }
}

/// The biggest frame worth asking the engine for when the host draws the video on the GPU: the source resolution, or
/// the window when that is smaller (the layer scales a frame that is smaller than the window; one that is bigger
/// would be thrown away). Fit asks for a box the picture fits into; fill asks for the part of the source the window
/// shows, at source scale. Never above the GPU's texture limit.
pub fn gpu_frame_box(
    window: (u32, u32),
    source: Option<(u32, u32)>,
    fill: bool,
    max_side: u32,
) -> (u32, u32) {
    let (ww, wh) = (window.0.max(2), window.1.max(2));
    let (bw, bh) = match source {
        None => (ww, wh),
        Some((sw, sh)) if fill => {
            // The window's aspect, as large as the source allows (but not above the window).
            let k = (sw as f32 / ww as f32).min(sh as f32 / wh as f32).min(1.0);
            (
                (ww as f32 * k).round() as u32,
                (wh as f32 * k).round() as u32,
            )
        }
        Some((sw, sh)) => (ww.min(sw), wh.min(sh)),
    };
    let k = (max_side as f32 / bw.max(bh) as f32).min(1.0);
    (
        ((bw as f32 * k) as u32).max(2),
        ((bh as f32 * k) as u32).max(2),
    )
}

/// An engine that plays a made-up file: it keeps a clock and answers commands, so the UI can run without libmpv.
#[derive(Default)]
pub struct SimEngine {
    sim: Mutex<Sim>,
}

impl SimEngine {
    fn with<R>(&self, f: impl FnOnce(&mut Sim) -> R) -> R {
        f(&mut self.sim.lock().unwrap_or_else(PoisonError::into_inner))
    }
    /// The commands the UI sent, as readable lines (tests).
    pub fn calls(&self) -> Vec<String> {
        self.with(|s| s.calls.clone())
    }
}

impl PlaybackEngine for SimEngine {
    fn load(&self, request: EngineLoad) {
        self.with(|s| s.calls.push(format!("load {:?}", request.start)));
    }
    fn play(&self) {
        self.with(|s| {
            s.playing = true;
            s.changed = Some(true);
            s.calls.push("play".into());
        });
    }
    fn pause(&self) {
        self.with(|s| {
            s.playing = false;
            s.changed = Some(false);
            s.calls.push("pause".into());
        });
    }
    fn seek(&self, seconds: f64) {
        self.with(|s| {
            s.position = seconds;
            s.sought = true;
            s.calls.push(format!("seek {seconds:.0}"));
        });
    }
    fn set_rate(&self, tempo: f32) {
        self.with(|s| {
            s.rate = tempo;
            s.calls.push(format!("rate {tempo}"));
        });
    }
    fn set_volume(&self, percent: u8) {
        self.with(|s| s.calls.push(format!("volume {percent}")));
    }
    fn set_audio_delay(&self, milliseconds: i32) {
        self.with(|s| s.calls.push(format!("audio-delay {milliseconds}")));
    }
    fn select_audio(&self, server_index: i32) -> bool {
        self.with(|s| s.calls.push(format!("audio {server_index}")));
        true
    }
    fn select_subtitle(&self, server_index: i32) -> SubtitleRoute {
        self.with(|s| s.calls.push(format!("subtitle {server_index}")));
        SubtitleRoute::Cues
    }
    fn set_fill(&self, on: bool) {
        self.with(|s| s.calls.push(format!("fill {on}")));
    }
    fn place(&self, _rect: Rect) {}
    fn stop(&self, _reset_display: bool) {
        self.with(|s| s.calls.push("stop".into()));
    }
    fn pip(&self, command: PipCmd) {
        self.with(|s| s.calls.push(format!("pip {command:?}")));
    }
}

/// Drops every report (the demo has no server).
pub struct NoReports;
impl Reporter for NoReports {
    fn report(&self, _message: ReportMessage) {}
}

/// The words of the track labels: the core's built-in language table in the interface language (the desktop has
/// no system call for language names; the table holds the ISO 639 names of the app languages).
fn words() -> swiftly_vm::LabelWords {
    swiftly_vm::LabelWords::new(swiftly_l10n::current_locale())
}

fn stream(index: i64, kind: &str, language: &str, codec: &str) -> MediaStream {
    MediaStream {
        index: Some(index),
        type_: Some(kind.into()),
        language: Some(language.into()),
        codec: Some(codec.into()),
        channels: (kind == "Audio").then_some(6),
        ..MediaStream::default()
    }
}

/// What the demo plays.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayerScenario {
    /// A running episode with intro, chapters, trickplay and a next episode.
    Playing,
    /// The start fails (the screen with its two buttons).
    Failed,
}

/// Total length of the made-up episode in seconds.
pub const DURATION: f64 = 2700.0;

fn spec() -> PlayerSpec {
    PlayerSpec {
        item_id: "demo-ep".into(),
        title: "Nordlicht".into(),
        plan: ReportPlan {
            play_session_id: None,
            media_source_id: None,
            method: PlayMethod::DirectPlay,
        },
        request: EngineRequest {
            item_id: "demo-ep".into(),
            streams: vec![
                stream(1, "Audio", "deu", "eac3"),
                stream(2, "Audio", "eng", "ac3"),
                stream(3, "Subtitle", "deu", "subrip"),
                stream(4, "Subtitle", "eng", "subrip"),
            ],
            runtime: DURATION,
            subtitle_files: Vec::new(),
            url: "demo://nordlicht".into(),
            headers: Vec::new(),
            software_decode: false,
            buffer_level: BufferLevel::Normal,
            frame_rate_match: false,
            external_track_id_base: 1000,
        },
        start_at: 0.0,
        audio_index: Some(1),
        subtitle_index: -1,
        next: Some(NextEpisode {
            id: "demo-ep2".into(),
            title: "Die Rückkehr".into(),
        }),
        series_id: Some("demo-series".into()),
        track_title: None,
        downloaded: false,
    }
}

// ---- parts for the view ------------------------------------------------------------------------------------------

#[derive(Clone, PartialEq)]
struct Params {
    preview_img: Option<swiftly_ui::ImageId>,
    t: TransportPart,
    c: ControlsPart,
    tracks: TracksPart,
    offer: OfferPart,
    title: String,
    meta: String,
    /// The episodes layer and its button exist.
    episodes: bool,
    /// The delivery is a transcode: a warning line under the meta.
    transcode: bool,
    chapters: Vec<(f64, String)>,
    marks: Vec<f64>,
    spin: u8,
    /// Turns of the Mac loader (continuous, 0.7 s per turn).
    turn: f32,
    focus: u64,
    fill: bool,
    muted: bool,
    volume: i32,
    tech: bool,
    /// The stored subtitle look for the lines the app draws itself.
    sub_style: Option<swiftly_playback::engine::SubtitleTextStyle>,
    /// The overlay's delivery word (accent when good) and its file lines.
    tech_head: Option<(String, bool)>,
    /// The first transcode reason in words, under the delivery word (`TechBadge`).
    tech_reason: Option<String>,
    tech_rows: Vec<(String, String)>,
    /// The handover menu is open (desktop).
    menu: bool,
    /// The film runs in the small window: the big picture shows the hint (`smallerHint`).
    small: bool,
    /// The season picker list is open, and the chosen season (index in [`SEASONS`]).
    seasons: (bool, usize),
    /// The season names of the picker, the cards of the chosen season, the running one among them and their pictures.
    season_names: Vec<String>,
    cards: Vec<EpisodeCardData>,
    current_card: Option<usize>,
    card_imgs: Vec<Option<(swiftly_ui::ImageId, f32)>>,
    /// Scroll offset of the episode strip (the arrows show from it).
    strip_x: f32,
    /// The window is in real fullscreen (the rail button swaps its glyph).
    fullscreen: bool,
    /// The volume compartment is out (hover, drag or a key press, desktop).
    vol_open: bool,
    /// The pointer rests on the scrubber at this position in seconds (hover preview, desktop).
    hover_pos: Option<f64>,
    /// "Endet um HH:mm" instead of the remaining time (setting), desktop.
    ends: Option<String>,
    /// The open anchored menu (handover, season list); the overlay is drawn from it.
    menu_c: MenuController,
    /// The next-episode card: its look now, and what it says (title, share, seconds left, episode code).
    card: CardLook,
    card_data: Option<(String, f64, i64, String)>,
    /// The episode picture of the card and its opacity (None: the gradient stays).
    card_img: Option<(swiftly_ui::ImageId, f32)>,
    /// Scale of the back and forward glyphs (bounce after a seek).
    bounce: (f32, f32),
    /// Counts the fullscreen changes: the controls fade in again with easeInOut 0.5 after each.
    fs_epoch: u32,
    /// The group the player sits in: its name and "mit A und B" (`SharedModel.group`, `withWhom`).
    group: Option<(String, String)>,
    /// Everyone in the group, as the server names them.
    participants: Vec<String>,
    /// The latest event of the group, shown at the top for a moment.
    event: Option<crate::together::EventLine>,
    /// What went wrong with the group, shown above the scrubber.
    group_error: Option<String>,
    /// The devices the film can be handed to: id and name (`PlayOutputs.targets`).
    targets: Vec<(String, String)>,
}

struct Metrics {
    form: Form,
    edge: f32,
    top: f32,
    bottom: f32,
    title: f32,
    meta: f32,
    time: f32,
    button: f32,
    glyph: f32,
    bar_h: f32,
    slider_top: f32,
    huge: f32,
    large: f32,
    gap: f32,
    left_w: f32,
    right_w: f32,
    pill_h: f32,
    pill_text: f32,
    over_bar: f32,
    preview_w: f32,
    row_h: f32,
    sub: f32,
    /// Top of the rail buttons and of the title block (desktop: 14 and 44).
    rail_top: f32,
    title_top: f32,
    /// Hit boxes of the skip and play buttons (desktop 48 and 60).
    skip_box: f32,
    play_box: f32,
    /// Space between the time labels and the slider.
    bar_gap: f32,
}

fn metrics(env: &Env) -> Metrics {
    let pad = env.idiom == swiftly_ui::Idiom::Pad;
    match Form::of(env.idiom) {
        Form::Tv => Metrics {
            form: Form::Tv,
            edge: 80.0,
            top: 60.0,
            bottom: 90.0,
            title: 56.0,
            meta: 24.0,
            time: 26.0,
            button: 88.0,
            glyph: 44.0,
            bar_h: 32.0,
            slider_top: 0.0,
            huge: 0.0,
            large: 0.0,
            gap: 8.0,
            left_w: 110.0,
            right_w: 130.0,
            pill_h: 76.0,
            pill_text: 28.0,
            over_bar: 28.0,
            preview_w: 360.0,
            row_h: 72.0,
            sub: 40.0,
            rail_top: 60.0,
            title_top: 60.0,
            skip_box: 96.0,
            play_box: 116.0,
            bar_gap: 14.0,
        },
        // `PL:10-52`: page/titleLeft 28, iconTop 35.5 (= titleTop 44 - (44 - 27) / 2), titleTop 44, bottom 20, button 44, glyph 22, over bar 12.
        Form::Desktop => Metrics {
            form: Form::Desktop,
            edge: 28.0,
            top: 35.5,
            bottom: 20.0,
            title: 22.0,
            meta: 13.0,
            time: 13.0,
            button: 44.0,
            glyph: 22.0,
            bar_h: 44.0,
            slider_top: 16.0,
            huge: 52.0,
            large: 44.0,
            gap: 66.0,
            left_w: 56.0,
            right_w: 64.0,
            pill_h: 40.0,
            pill_text: 15.0,
            over_bar: 12.0,
            preview_w: 160.0,
            row_h: 34.0,
            sub: 22.0,
            rail_top: 35.5,
            title_top: 44.0,
            skip_box: 48.0,
            play_box: 60.0,
            bar_gap: 12.0,
        },
        form => {
            let narrow = env.idiom == swiftly_ui::Idiom::Phone;
            let wide = pad || form == Form::Desktop;
            Metrics {
                form,
                edge: if wide { 28.0 } else { 18.0 },
                top: (if wide { 24.0 } else { 16.0 }) + env.safe.top,
                bottom: (if wide { 22.0 } else { 0.0 }) + env.safe.bottom,
                title: 20.0,
                meta: 12.0,
                time: 13.0,
                button: 44.0,
                glyph: if wide { 21.0 } else { 19.0 },
                bar_h: 44.0,
                slider_top: 16.0,
                huge: if narrow { 36.0 } else { 48.0 },
                large: if narrow { 24.0 } else { 30.0 },
                gap: if narrow { 34.0 } else { 52.0 },
                left_w: 48.0,
                right_w: 62.0,
                pill_h: 40.0,
                pill_text: 15.0,
                over_bar: 20.0,
                preview_w: if wide { 200.0 } else { 160.0 },
                row_h: 48.0,
                sub: 17.0,
                rail_top: (if wide { 24.0 } else { 16.0 }) + env.safe.top,
                title_top: (if wide { 24.0 } else { 16.0 }) + env.safe.top,
                skip_box: 52.0,
                play_box: if narrow { 64.0 } else { 76.0 },
                bar_gap: 14.0,
            }
        }
    }
}

/// Left edge and width of the bar in window points.
fn bar_span(env: &Env, ends: bool) -> (f32, f32) {
    let m = metrics(env);
    let x = m.edge + m.left_w + m.bar_gap;
    let right = m.right_w + if ends { 40.0 } else { 0.0 };
    (
        x,
        (env.size.w - 2.0 * m.edge - m.left_w - right - 2.0 * m.bar_gap).max(40.0),
    )
}

/// Top and height of the scrubber hit area in window points.
fn bar_hit(env: &Env) -> (f32, f32) {
    let m = metrics(env);
    let bottom = env.size.h - m.bottom;
    (bottom - m.bar_h - m.slider_top, m.bar_h + m.slider_top)
}

/// "m:ss" or "h:mm:ss" (`PlayTime.text`).
pub fn play_time(seconds: f64) -> String {
    let s = seconds.max(0.0) as i64;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, s % 3600 / 60, s % 60)
    } else {
        format!("{}:{:02}", s / 60, s % 60)
    }
}

// ---- the view ----------------------------------------------------------------------------------------------------

struct Ctx<'a> {
    m: Metrics,
    env: &'a Env,
    cx: &'a Cx,
    g: &'a Glyphs,
    p: &'a Params,
    tv: bool,
    live: bool,
    surface: &'a dyn VideoSurface,
}

fn white() -> Color {
    color(colour::FONT)
}

/// A control: tappable (and focusable on tv) only while the controls are up, so a faded-out button catches nothing.
fn act(c: &Ctx<'_>, n: Node, on: bool, key: &str, action: &str) -> Node {
    let n = n.key(key);
    if !on {
        return n;
    }
    let name = match action {
        "toggle" if matches!(c.p.t.phase, Phase::Playing) => "Pause".to_owned(),
        "toggle" => "Wiedergabe".to_owned(),
        "back" => format!("{} Sekunden zurück", c.p.c.jump_seconds.0),
        "fwd" => format!("{} Sekunden vor", c.p.c.jump_seconds.1),
        "tracks" => "Ton und Untertitel".to_owned(),
        "fullscreen" if c.p.fullscreen => "Vollbild verlassen".to_owned(),
        "fullscreen" => "Vollbild".to_owned(),
        "mute" if c.p.muted || c.p.volume <= 0 => "Ton an".to_owned(),
        "mute" => "Ton aus".to_owned(),
        "episodes" => "Folgen".to_owned(),
        "settings" => "Einstellungen".to_owned(),
        "handover" => "Auf anderem Gerät fortsetzen".to_owned(),
        "close" => "Player schließen".to_owned(),
        "layer-close" | "fail-close" => "Schließen".to_owned(),
        other => other.to_owned(),
    };
    let n = n
        .a11y_label(swiftly_ui::a11y::Role::Button, name)
        .on_tap(Action::from(action));
    if c.tv {
        n.focusable(focus_id(key), Some(FocusLook::tile(12.0)))
    } else {
        n
    }
}

fn label(c: &Ctx<'_>, s: &str, size: f32, w: u16, col: swiftly_design::Colour) -> Node {
    let base = swiftly_design::TextStyle {
        size,
        weight: w,
        ..base()
    };
    txt(c.cx, s, base, col, Some(1))
}

/// The width a one-line label takes at its natural size (what the Mac reads from its layout).
fn label_width(c: &Ctx<'_>, s: &str, size: f32, w: u16) -> f32 {
    let style = swiftly_design::TextStyle {
        size,
        weight: w,
        ..base()
    };
    c.cx.measure_text(
        s,
        &swiftly_text::TextStyle::from(style),
        Some(1),
        swiftly_layout::Proposal::NIL,
    )
    .w
}

/// A time or clock label: tabular figures, so the digits stay put while the time runs.
fn time_label(c: &Ctx<'_>, s: &str, size: f32, w: u16, col: swiftly_design::Colour) -> Node {
    let base = swiftly_design::TextStyle {
        size,
        weight: w,
        ..base()
    };
    crate::home::tabular_text(c.cx, s, base, col, Some(1), swiftly_text::Align::Start)
}

fn icon_button(c: &Ctx<'_>, glyph: &'static str, key: &str, action: &str, on: bool) -> Node {
    let m = &c.m;
    let g = c.g.node(glyph, m.glyph, white());
    let n = g.frame(Some(m.button), Some(m.button), Alignment::CENTER);
    let n = if c.tv {
        n.background(
            Node::rect(Color::new(1.0, 1.0, 1.0, 0.10), m.button / 2.0),
            Alignment::CENTER,
        )
    } else {
        n
    };
    act(c, n, on, key, action)
}

const VOL_COMPARTMENT: f32 = 96.0;
/// Gap between the speaker button and the open compartment.
const VOL_GAP: f32 = 2.0;
const VOL_SLIDER: f32 = 88.0;
const VOL_INSET: f32 = 6.0;

/// Buttons right of the volume control in the desktop rail: Ton und Untertitel, Folgen, Einstellungen, Vollbild,
/// the handover (when there are targets) and close.
fn rail_after_volume(handover: bool) -> f32 {
    (5 + usize::from(handover)) as f32
}

/// Left edge of the volume slider (window points) and the vertical centre of the rail.
fn vol_geometry(env: &Env, handover: bool) -> (f32, f32) {
    let m = metrics(env);
    let right = env.size.w - (m.edge - (m.button - m.glyph) / 2.0);
    let comp_right = right - rail_after_volume(handover) * (m.button + 2.0);
    (
        comp_right - VOL_COMPARTMENT + (VOL_COMPARTMENT - VOL_SLIDER) / 2.0,
        m.rail_top + m.button / 2.0,
    )
}

/// The rectangle (x0, y0, x1, y1) in which the pointer keeps the compartment out: speaker button and compartment.
fn vol_zone(env: &Env, handover: bool) -> (f32, f32, f32, f32) {
    let m = metrics(env);
    let (sx, cy) = vol_geometry(env, handover);
    let comp_left = sx - (VOL_COMPARTMENT - VOL_SLIDER) / 2.0;
    (
        comp_left - 2.0 - m.button,
        cy - m.button / 2.0,
        comp_left + VOL_COMPARTMENT,
        cy + m.button / 2.0,
    )
}

/// A rail button on the desktop: hover fill white 6 %, tooltip after 0.5 s with label and key.
fn rail_button(
    c: &Ctx<'_>,
    glyph: &'static str,
    key: &str,
    action: &str,
    tip: &str,
    on: bool,
) -> Node {
    let m = &c.m;
    let mut n =
        c.g.node(glyph, m.glyph, white())
            .frame(Some(m.button), Some(m.button), Alignment::CENTER);
    if on {
        n = n
            .hover_surface(Color::new(1.0, 1.0, 1.0, 0.06), 12.0)
            .tooltip(tip);
    }
    act(c, n, on, key, action)
}

/// The play/pause glyph swap (`contentTransition(.symbolEffect(.replace))`; the system's timing is private, the catalogue's estimate).
fn symbol_swap() -> Motion {
    swiftly_ui::feel::of(swiftly_motion::catalogue::Id::SymbolReplace)
}

/// Speaker button and the compartment with the 88 pt slider (`VolumeSlider.swift`).
fn volume_control(c: &Ctx<'_>, on: bool) -> Node {
    let p = c.p;
    // One value like the Mac's `volume`: muted is volume 0, the speaker is slashed at 0 (`VolumeSlider.swift:55`).
    let level = p.volume.clamp(0, 100);
    let glyph = if level == 0 {
        "speaker-slash"
    } else {
        "speaker"
    };
    let word = if level == 0 { "Ton an" } else { "Ton aus" };
    let mut kids = vec![rail_button(c, glyph, "mute", "mute", word, on)];
    // The compartment opens with `easeOut(0.18)`: its width goes 0 to 96 and its opacity 0 to 1 while the speaker button moves
    // over (`VolumeSlider.swift:30-64`: `.frame(width: opened ? 96 : 0).clipped().opacity(opened ? 1 : 0)`).
    let open = p.vol_open && on;
    let inner = VOL_SLIDER - 2.0 * VOL_INSET;
    let thumb_x = VOL_INSET + inner * level as f32 / 100.0;
    let track = Node::rect(Color::new(1.0, 1.0, 1.0, 0.18), 2.0).frame(
        Some(VOL_SLIDER),
        Some(4.0),
        Alignment::LEADING,
    );
    let fill = Node::rect(color(colour::MARK_ACCENT), 2.0).frame(
        Some(thumb_x),
        Some(4.0),
        Alignment::LEADING,
    );
    let thumb = Node::rect(white(), 6.0)
        .frame(Some(12.0), Some(12.0), Alignment::CENTER)
        .padding(ins(0.0, thumb_x - 6.0, 0.0, 0.0));
    let pct = label(c, &format!("{level} %"), 11.0, 600, colour::FONT_QUIET)
        .padding(ins(28.0, 0.0, 0.0, 0.0));
    let slider = Node::zstack(
        Alignment::LEADING,
        vec![track, fill, thumb, fill_frame(pct, Alignment::CENTER)],
    )
    .frame(Some(VOL_SLIDER), Some(c.m.button), Alignment::LEADING)
    .key("vol-slider");
    let motion = swiftly_ui::feel::of(swiftly_motion::catalogue::Id::VolumeOpen);
    let pad = (VOL_COMPARTMENT - VOL_SLIDER) / 2.0;
    kids.push(
        slider
            .padding(ins(0.0, pad + VOL_GAP, 0.0, pad))
            .frame(
                Some(VOL_COMPARTMENT + VOL_GAP),
                Some(c.m.button),
                Alignment::LEADING,
            )
            .animated_frame(
                Some(if open { VOL_COMPARTMENT + VOL_GAP } else { 0.0 }),
                Some(c.m.button),
                Alignment::LEADING,
                motion,
            )
            .clipped()
            .opacity(if open { 1.0 } else { 0.0 }, motion),
    );
    // The 2 pt between the speaker and the compartment belong to the compartment so a closed one takes no room.
    Node::hstack(Align::Center, Some(0.0), kids)
}

/// The desktop header (`PlayerScreen.swift:652-829`): title 22 bold at top 44, rail at top 14.
fn header_desktop(c: &Ctx<'_>) -> Node {
    let (m, on) = (&c.m, c.p.c.visible && c.p.c.layer.is_none());
    let scrubbing = c.p.c.scrubbing;
    let mut col = vec![label(c, &c.p.title, m.title, 700, colour::FONT)];
    if let Some((name, with)) = c.p.group.as_ref() {
        let people = c.g.node("users", m.meta + 1.0, color(colour::MARK_ACCENT));
        col.push(Node::hstack(
            Align::Center,
            Some(6.0),
            vec![
                people,
                label(c, name, m.meta, 600, colour::MARK_ACCENT),
                label(c, &format!("· {with}"), m.meta, 400, colour::FONT_QUIET),
            ],
        ));
    } else if !c.p.meta.is_empty() || c.p.transcode {
        let mut line = Vec::new();
        if !c.p.meta.is_empty() {
            line.push(label(c, &c.p.meta, m.meta, 400, colour::FONT_QUIET));
        }
        if c.p.transcode {
            // `Label(plan.method.rawValue, systemImage: "exclamationmark.triangle.fill")` in the warning colour.
            line.push(c.g.node("warning", m.meta, color(colour::ORIGINAL_WARNING)));
            line.push(label(c, "Transcode", m.meta, 400, colour::ORIGINAL_WARNING));
        }
        col.push(Node::hstack(Align::Center, Some(6.0), line));
    }
    let left =
        Node::vstack(Align::Start, Some(3.0), col).padding(ins(m.title_top, m.edge, 0.0, m.edge));
    let ok = on && !scrubbing && !c.p.menu;
    let mut rail = vec![
        volume_control(c, ok),
        rail_button(
            c,
            "captions",
            "tracks",
            "tracks",
            "Ton und Untertitel (T)",
            ok,
        ),
    ];
    if c.p.episodes {
        rail.push(rail_button(
            c, "stack", "episodes", "episodes", "Folgen", ok,
        ));
    }
    rail.push(rail_button(
        c,
        "sliders",
        "settings",
        "settings",
        "Einstellungen",
        ok,
    ));
    let (fs_glyph, fs_tip) = if c.p.fullscreen {
        ("fullscreen-exit", "Vollbild verlassen (F)")
    } else {
        ("fullscreen", "Vollbild (F)")
    };
    rail.push(rail_button(
        c,
        fs_glyph,
        "fullscreen",
        "fullscreen",
        fs_tip,
        ok,
    ));
    if c.p.group.is_none() && !c.p.targets.is_empty() {
        rail.push(rail_button(
            c,
            "television",
            "handover",
            "handover",
            "Übergeben an …",
            ok,
        ));
    }
    rail.push(rail_button(
        c,
        "x",
        "close",
        "close",
        "Player schließen (Esc)",
        ok,
    ));
    let rail = Node::hstack(Align::Center, Some(2.0), rail)
        .opacity(if scrubbing { 0.0 } else { 1.0 }, Motion::Instant);
    let rail = fill_frame(
        rail.padding(ins(
            m.rail_top,
            0.0,
            0.0,
            m.edge - (m.button - m.glyph) / 2.0,
        )),
        Alignment::TOP_TRAILING,
    );
    let mut kids = vec![fill_frame(left, Alignment::TOP_LEADING), rail];
    if let Some(h) = &c.p.t.hint {
        // `PS:817-829`: centred at the bottom of the header row (title line 27, gap 3, one meta line of about 16), the 12 pt line
        // (about 15 high) offset 22 down, 28 pt of side padding.
        let row_bottom = m.title_top
            + 27.0
            + 3.0
            + if c.p.group.is_some() || !c.p.meta.is_empty() {
                16.0
            } else {
                0.0
            };
        let hint = Node::text(
            c.cx,
            h,
            &swiftly_text::TextStyle::from(swiftly_design::TextStyle {
                size: 12.0,
                weight: 400,
                ..base()
            }),
            white(),
            Some(3),
            swiftly_text::Align::Center,
        )
        .padding(ins(row_bottom - 15.0 + 22.0, m.edge, 0.0, m.edge));
        // `notify`: the hint stays 3 s and goes with `withAnimation { hint = nil }`, the SwiftUI default spring (`PlayerScreen.swift:1606`).
        let default = swiftly_ui::feel::default_spring();
        kids.push(fill_frame(
            hint.appear_from(1.0, 0.0)
                .appear_after_first_build()
                .exit_to(1.0, 0.0)
                .opacity(1.0, default),
            Alignment::TOP,
        ));
    }
    fill_frame(
        Node::zstack(Alignment::TOP_LEADING, kids),
        Alignment::TOP_LEADING,
    )
}

fn header(c: &Ctx<'_>) -> Node {
    if c.m.form == Form::Desktop {
        return header_desktop(c);
    }
    let (m, on) = (&c.m, c.p.c.visible && c.p.c.layer.is_none());
    let tv = c.tv;
    let title = label(
        c,
        &c.p.title,
        m.title,
        if tv { 700 } else { 600 },
        colour::FONT,
    );
    let mut col = vec![title];
    if let Some((name, with)) = c.p.group.as_ref() {
        // In a group the group replaces year and runtime (`GroupsRow`): people icon, name semibold, both accent.
        let people = c.g.node("users", m.meta + 1.0, color(colour::MARK_ACCENT));
        col.push(Node::hstack(
            Align::Center,
            Some(6.0),
            vec![
                people,
                label(c, name, m.meta, 600, colour::MARK_ACCENT),
                label(c, &format!("· {with}"), m.meta, 400, colour::FONT_QUIET),
            ],
        ));
    } else if !c.p.meta.is_empty() {
        col.push(label(c, &c.p.meta, m.meta, 400, colour::FONT_QUIET));
    }
    let left = Node::vstack(Align::Start, Some(if tv { 10.0 } else { 3.0 }), col);
    let scrubbing = c.p.c.scrubbing;
    let mut rail = vec![icon_button(
        c,
        "captions",
        "tracks",
        "tracks",
        on && !scrubbing,
    )];
    // Desktop: "Folgen" (rectangle.stack) only for episodes of a series, the handover tv only outside a group
    // (`macOS/PlayerScreen.iconRail`, `handOverMenu`).
    if !tv {
        rail.push(icon_button(
            c,
            "stack",
            "episodes",
            "episodes",
            on && !scrubbing,
        ));
    }
    rail.push(icon_button(
        c,
        "sliders",
        "settings",
        "settings",
        on && !scrubbing,
    ));
    if c.m.form == Form::Desktop && c.p.group.is_none() && !c.p.targets.is_empty() {
        rail.push(icon_button(
            c,
            "television",
            "handover",
            "handover",
            on && !scrubbing,
        ));
    }
    rail.push(icon_button(c, "x", "close", "close", on && !scrubbing));
    let mut rail = Node::hstack(Align::Center, Some(if tv { m.gap } else { 2.0 }), rail);
    if tv {
        rail = rail.focus_scope(ScopeSpec::section(focus_id("rail")));
    }
    let row = Node::hstack(
        Align::Start,
        Some(12.0),
        vec![
            left,
            Node::spacer(),
            rail.opacity(if scrubbing { 0.0 } else { 1.0 }, Motion::Instant),
        ],
    );
    let row = row.padding(ins(
        m.top,
        m.edge,
        0.0,
        m.edge - if tv { 0.0 } else { (m.button - m.glyph) / 2.0 },
    ));
    let mut kids = vec![fill_frame(row, Alignment::TOP_LEADING)];
    if let Some(h) = &c.p.t.hint {
        let hint = label(c, h, 12.0, 400, colour::FONT).padding(ins(0.0, m.edge, 0.0, m.edge));
        kids.push(fill_frame(
            hint.padding(ins(m.top + m.button + 8.0, 0.0, 0.0, 0.0)),
            Alignment::TOP,
        ));
    }
    fill_frame(
        Node::zstack(Alignment::TOP_LEADING, kids),
        Alignment::TOP_LEADING,
    )
}

fn skip_glyph_name(forward: bool) -> &'static str {
    if forward { "goforward" } else { "gobackward" }
}

fn center(c: &Ctx<'_>) -> Node {
    let (m, on) = (&c.m, c.p.c.visible && c.p.c.layer.is_none());
    let (back, fwd) = c.p.c.jump_seconds;
    let skip = |forward: bool, secs: i64, key: &str| {
        let g = c.g.node(skip_glyph_name(forward), m.large, white());
        let num = label(c, &secs.to_string(), m.large * 0.28, 600, colour::FONT);
        let num = if c.m.form == Form::Desktop {
            label(c, &secs.to_string(), 12.0, 700, colour::FONT).padding(ins(2.0, 0.0, 0.0, 0.0))
        } else {
            num
        };
        let bounce = if forward { c.p.bounce.1 } else { c.p.bounce.0 };
        let n = Node::zstack(Alignment::CENTER, vec![g, num])
            .scaled(bounce, Motion::Instant)
            .frame(Some(m.skip_box), Some(m.skip_box), Alignment::CENTER);
        let n = act(c, n, on, key, if forward { "fwd" } else { "back" });
        // The Mac grows the skip button to 1.06 under the pointer (`PlayerScreen.swift:1973`).
        if on && c.m.form == Form::Desktop {
            n.hover_scale(1.06)
        } else {
            n
        }
    };
    let playing = matches!(c.p.t.phase, Phase::Playing);
    let mut mid =
        c.g.node(if playing { "pause" } else { "play" }, m.huge, white());
    if m.form == Form::Desktop {
        // Play and pause replace each other (`SymbolEffect.replace.offUp`): the new glyph grows in.
        mid = mid
            .key(if playing { "glyph-pause" } else { "glyph-play" })
            .scaled(1.0, symbol_swap())
            .appear_from(0.7, 0.0)
            .opacity(1.0, symbol_swap());
    }
    let mid = act(
        c,
        mid.frame(Some(m.play_box), Some(m.play_box), Alignment::CENTER),
        on,
        "toggle-btn",
        "toggle",
    );
    let row = Node::hstack(
        Align::Center,
        Some(m.gap),
        vec![skip(false, back, "back"), mid, skip(true, fwd, "fwd")],
    );
    // Desktop: the row sits 20 above the middle (`PS:868`).
    if m.form == Form::Desktop {
        let row = fill_frame(row.padding(ins(0.0, 0.0, 40.0, 0.0)), Alignment::CENTER);
        return Node::zstack(Alignment::TOP_LEADING, vec![row, key_hints(c)]);
    }
    fill_frame(row, Alignment::CENTER)
}

fn time_slider(c: &Ctx<'_>, bar_w: f32) -> Node {
    let (p, m) = (c.p, &c.m);
    let dur = p.t.duration.max(1.0);
    let share = (p.t.position / dur).clamp(0.0, 1.0) as f32;
    let desk = m.form == Form::Desktop;
    let thick: f32 = if c.tv {
        if p.c.scrubbing { 14.0 } else { 10.0 }
    } else if desk && p.c.scrubbing {
        6.0
    } else {
        4.0
    };
    let track_alpha = if desk { 0.18 } else { 0.25 };
    let segmented = desk && !p.chapters.is_empty();
    let mut kids = if segmented {
        chapter_track(c, bar_w, share)
    } else {
        vec![
            Node::rect(Color::new(1.0, 1.0, 1.0, track_alpha), thick / 2.0).frame(
                Some(bar_w),
                Some(thick),
                Alignment::CENTER,
            ),
            // The Mac's capsule is exactly `width * share` wide (`PS:1996`), also at zero.
            Node::rect(white(), thick / 2.0).frame(
                Some(if desk {
                    bar_w * share
                } else {
                    (bar_w * share).max(thick)
                }),
                Some(thick),
                Alignment::CENTER,
            ),
        ]
    };
    let tick = |at: f64, a: f32, key: String| {
        let x = (at / dur) as f32 * bar_w - 1.0;
        let (col, tall) = if desk {
            (color(colour::REASON), thick)
        } else {
            (Color::new(0.04, 0.04, 0.05, a), thick + 4.0)
        };
        Node::rect(col, 0.0)
            .frame(Some(2.0), Some(tall), Alignment::CENTER)
            .padding(ins(0.0, x.max(0.0), 0.0, 0.0))
            .key(key.as_str())
    };
    // Notches only strictly inside the track (above 1 %, below 99 %) on the Mac.
    let inside = |at: f64| !desk || (at / dur > 0.01 && at / dur < 0.99);
    for (i, (from, _)) in p
        .chapters
        .iter()
        .enumerate()
        .filter(|(_, (f, _))| !segmented && *f > 1.0 && inside(*f))
    {
        kids.push(tick(*from, 0.85, format!("chapter:{i}")));
    }
    for (i, at) in p.marks.iter().enumerate().filter(|(_, a)| inside(**a)) {
        kids.push(tick(*at, 0.55, format!("mark:{i}")));
    }
    let knob = if p.c.scrubbing {
        18.0
    } else if c.tv || desk {
        0.0
    } else {
        12.0
    };
    if knob > 0.0 {
        let fillc = if p.c.scrubbing {
            color(colour::MARK_ACCENT)
        } else {
            white()
        };
        // The Mac's handle is `offset(x: width * share - 9)`, not held inside the track (`PS:2008`).
        let raw = bar_w * share - knob / 2.0;
        let x = if desk {
            raw.max(0.0)
        } else {
            raw.clamp(0.0, bar_w - knob)
        };
        kids.push(
            Node::rect(fillc, knob / 2.0)
                .frame(Some(knob), Some(knob), Alignment::CENTER)
                .padding(ins(0.0, x, 0.0, 0.0))
                .key("knob"),
        );
    }
    let mut s = Node::zstack(Alignment::LEADING, kids)
        .frame(Some(bar_w), Some(m.bar_h), Alignment::LEADING)
        .key("slider");
    if p.c.scrubbing {
        s = s.overlay(
            preview(c, bar_w, share, p.t.position),
            Alignment::BOTTOM_LEADING,
        );
    } else if let (true, Some(at)) = (desk, p.hover_pos) {
        s = s.overlay(
            preview(c, bar_w, (at / dur).clamp(0.0, 1.0) as f32, at),
            Alignment::BOTTOM_LEADING,
        );
    }
    s
}

/// The track cut into one segment per chapter (`ChapterMask.swift:16`): gap 2, at least 8 wide, 4 high; only the
/// segment under the handle rises to 6 while it is dragged.
fn chapter_track(c: &Ctx<'_>, bar_w: f32, share: f32) -> Vec<Node> {
    let p = c.p;
    let dur = p.t.duration.max(1.0);
    let mut cuts: Vec<f32> = vec![0.0];
    cuts.extend(
        p.chapters
            .iter()
            .map(|(f, _)| *f)
            .filter(|f| *f > 0.0 && *f < dur)
            .map(|f| (f / dur) as f32 * bar_w),
    );
    cuts.push(bar_w);
    cuts.dedup_by(|a, b| (*a - *b).abs() < 0.5);
    if cuts.len() < 2 {
        return Vec::new();
    }
    let handle = share * bar_w;
    let last = cuts.len() - 2;
    let mut kids = Vec::new();
    for i in 0..=last {
        let x0 = cuts[i] + if i > 0 { 1.0 } else { 0.0 };
        let x1 = cuts[i + 1] - if i < last { 1.0 } else { 0.0 };
        let w = (x1 - x0).max(8.0);
        let under = p.c.scrubbing && handle >= cuts[i] && (handle < cuts[i + 1] || i == last);
        let h = if under { 6.0 } else { 4.0 };
        let done = (handle - x0).clamp(0.0, w);
        let seg = Node::rect(Color::new(1.0, 1.0, 1.0, 0.18), h / 2.0)
            .frame(Some(w), Some(h), Alignment::CENTER)
            .background(
                Node::rect(white(), h / 2.0).frame(Some(done), Some(h), Alignment::LEADING),
                Alignment::LEADING,
            );
        kids.push(
            fill_frame(seg.padding(ins(0.0, x0, 0.0, 0.0)), Alignment::LEADING)
                .key(format!("segment:{i}").as_str()),
        );
    }
    kids
}

/// The box above the handle: trickplay still (or the placeholder), the chapter name and the time in a capsule.
fn preview(c: &Ctx<'_>, bar_w: f32, share: f32, at: f64) -> Node {
    let (p, m) = (c.p, &c.m);
    let desk = m.form == Form::Desktop;
    let w = m.preview_w;
    let h = w * 9.0 / 16.0;
    let name = p
        .chapters
        .iter()
        .rev()
        .find(|(f, _)| *f <= at)
        .map(|(_, n)| n.clone())
        .unwrap_or_default();
    let mut col = Vec::new();
    // 2 pt white ring on the Mac, 1 pt border on touch.
    let ring = if desk {
        Paint::Stroke {
            color: white(),
            width: 2.0,
            radius: 8.0,
        }
    } else {
        Paint::Stroke {
            color: color(colour::TILE_BORDER),
            width: 1.0,
            radius: 8.0,
        }
    };
    if let (Some(img), true) = (p.preview_img, p.c.scrubbing || desk) {
        col.push(Node::image(img, w, h, 8.0).paint(ring));
    } else if p.c.preview.is_some() && p.c.scrubbing {
        let a = Color::new(0.20, 0.30, 0.45, 1.0);
        let b = Color::new(0.05, 0.12, 0.20, 1.0);
        col.push(
            Node::rect(a, 8.0)
                .paint(Paint::Linear {
                    gradient: LinearGradient {
                        start: a,
                        end: b,
                        from: [0.0, 0.0],
                        to: [1.0, 1.0],
                    },
                    radius: 8.0,
                })
                .paint(if desk {
                    Paint::Stroke {
                        color: white(),
                        width: 2.0,
                        radius: 8.0,
                    }
                } else {
                    Paint::Stroke {
                        color: color(colour::TILE_BORDER),
                        width: 1.0,
                        radius: 8.0,
                    }
                })
                .frame(Some(w), Some(h), Alignment::CENTER),
        );
    }
    let size = if desk { 12.0 } else { m.time };
    let mut cap = Vec::new();
    if !name.is_empty() {
        cap.push(label(c, &name, size, 400, colour::FONT));
    }
    cap.push(time_label(c, &play_time(at), size, 600, colour::FONT));
    let caption = Node::hstack(Align::Center, Some(6.0), cap);
    if desk {
        col.push(caption);
    } else {
        col.push(caption.padding(ins(3.0, 8.0, 3.0, 8.0)).background(
            Node::rect(rgba(colour::REASON, 0.82), 20.0),
            Alignment::CENTER,
        ));
    }
    // Mac (`PS:2075-2145`): without a picture the box is as wide as its caption (at least 80), the centre is held between
    // half a box and the width minus half a box; the stack spacing is 5 and the caption ends 8 into the 44 pt row.
    let shown = col.len() > 1;
    let box_w = if desk && !shown {
        if name.is_empty() { 80.0 } else { w }
    } else {
        w
    };
    let x = (bar_w * share - box_w / 2.0).clamp(0.0, (bar_w - box_w).max(0.0));
    let (gap, bottom) = if desk {
        (5.0, m.bar_h - 8.0)
    } else {
        (6.0, m.bar_h / 2.0 + 10.0)
    };
    let stack = Node::vstack(Align::Center, Some(gap), col);
    let stack = if desk && !shown {
        stack.frame(Some(box_w), None, Alignment::CENTER)
    } else {
        stack
    };
    stack.padding(ins(0.0, x, bottom, 0.0)).key("preview")
}

fn footer(c: &Ctx<'_>) -> Node {
    let (p, m) = (c.p, &c.m);
    let (_, bar_w) = bar_span(c.env, c.p.ends.is_some());
    let rest = (p.t.duration - p.t.position).max(0.0);
    let left = time_label(
        c,
        &play_time(p.t.position),
        m.time,
        if m.form == Form::Desktop { 500 } else { 400 },
        colour::FONT,
    )
    .frame(Some(m.left_w), None, Alignment::LEADING);
    let (right_text, right_w) = match &p.ends {
        Some(at) => (format!("Endet um {at}"), m.right_w + 40.0),
        None => (format!("−{}", play_time(rest)), m.right_w),
    };
    let right = time_label(
        c,
        &right_text,
        m.time,
        if m.form == Form::Desktop { 500 } else { 400 },
        if m.form == Form::Desktop {
            colour::FONT_QUIET
        } else {
            colour::FONT
        },
    )
    .frame(Some(right_w), None, Alignment::TRAILING);
    let mut sl = time_slider(c, bar_w);
    if c.tv && p.c.visible {
        sl = sl.focusable(focus_id("bar"), None);
    }
    let sl = sl.a11y(
        swiftly_ui::a11y::A11yNode::new("scrubber", swiftly_ui::a11y::Role::Slider, "Position")
            .with_range(p.t.position, 0.0, p.t.duration.max(1.0))
            .with_value(format!(
                "{} von {}",
                play_time(p.t.position),
                play_time(p.t.duration)
            )),
    );
    let row = Node::hstack(Align::Center, Some(m.bar_gap), vec![left, sl, right])
        .padding(ins(0.0, m.edge, m.bottom, m.edge));
    fill_frame(row, Alignment::BOTTOM)
}

fn scrim(c: &Ctx<'_>) -> Node {
    let (w, h) = (c.env.size.w, c.env.size.h);
    let veil = Node::rect(Color::new(0.0, 0.0, 0.0, 0.45), 0.0);
    let band = |a: &[(f32, f32)], bh: f32, top: bool| {
        let _ = top;
        let s = Color::new(0.0, 0.0, 0.0, a[0].0);
        let e = Color::new(0.0, 0.0, 0.0, a[a.len() - 1].0);
        // The base fill stays clear: a gradient paint is drawn ON TOP of the fill, so a black base would keep the whole band
        // dark and cut the picture at the band's lower edge.
        Node::rect(Color::CLEAR, 0.0)
            .paint(Paint::Linear {
                gradient: LinearGradient {
                    start: s,
                    end: e,
                    from: [0.0, 0.0],
                    to: [0.0, 1.0],
                },
                radius: 0.0,
            })
            .frame(Some(w), Some(bh), Alignment::CENTER)
    };
    let top_h = if c.tv { 260.0 } else { 200.0 };
    let bot_h = if c.tv { 340.0 } else { 260.0 };
    let tv = c.tv;
    // Desktop: black .72 gradients only, no flat veil (`PS:326-343`).
    let kids = if c.m.form == Form::Desktop {
        vec![
            fill_frame(
                band(&[(0.72, 0.0), (0.0, 1.0)], top_h, true),
                Alignment::TOP,
            ),
            fill_frame(
                band(&[(0.0, 0.0), (0.72, 1.0)], bot_h, false),
                Alignment::BOTTOM,
            ),
        ]
    } else {
        vec![
            veil.frame(Some(w), Some(h), Alignment::CENTER),
            fill_frame(
                band(&[(0.55, 0.0), (0.0, 1.0)], top_h, true),
                Alignment::TOP,
            ),
            fill_frame(
                band(&[(0.0, 0.0), (0.62, 1.0)], bot_h, false),
                Alignment::BOTTOM,
            ),
        ]
    };
    let _ = tv;
    Node::zstack(Alignment::TOP_LEADING, kids)
}

fn pill(c: &Ctx<'_>) -> Node {
    let (p, m) = (c.p, &c.m);
    let dark = color(colour::REASON);
    let (text, sub, share, next, skip_share) = match &p.offer.view {
        OfferView::Hidden => return Node::spacer().key("offer-none"),
        // Auto-skip on: the button carries the running countdown as its fill, like the card.
        OfferView::Button {
            label: l,
            next_episode,
            countdown,
        } => ((*l).to_owned(), None, None, *next_episode, *countdown),
        OfferView::Card { .. } if m.form == Form::Desktop => {
            return Node::spacer().key("offer-none");
        }
        OfferView::Card {
            title,
            share,
            seconds_left,
        } => (
            "Nächste Folge".to_owned(),
            Some(format!("{title} · Startet in {seconds_left} Sekunden")),
            Some(*share),
            true,
            None,
        ),
    };
    let _ = next;
    let size = m.pill_text;
    // The Mac's pill glyph is 16 pt (`PS:2166`).
    let glyph = c.g.node(
        "skip-end",
        if m.form == Form::Desktop { 16.0 } else { size },
        dark,
    );
    let mut head = vec![glyph, label(c, &text, size, 600, colour::REASON)];
    if c.tv {
        head.insert(0, Node::spacer_min(0.0));
        head.remove(0);
    }
    let mut body = vec![Node::hstack(Align::Center, Some(8.0), head)];
    if let Some(s) = sub {
        body.push(label(c, &s, size * 0.8, 400, colour::REASON));
    }
    let col = Node::vstack(Align::Start, Some(2.0), body).padding(ins(
        0.0,
        if c.tv { 36.0 } else { 18.0 },
        0.0,
        if c.tv { 36.0 } else { 18.0 },
    ));
    let h = if share.is_some() {
        m.pill_h + size * 1.2
    } else {
        m.pill_h
    };
    let mut back = vec![Node::rect(
        white(),
        if c.tv {
            18.0
        } else if m.form == Form::Desktop {
            20.0
        } else {
            12.0
        },
    )];
    if let Some(s) = share {
        let w = 340.0_f32 * s as f32;
        back.push(
            Node::rect(Color::new(dark.r, dark.g, dark.b, 0.16), 0.0).frame(
                Some(w),
                Some(h),
                Alignment::LEADING,
            ),
        );
    }
    if let Some(s) = skip_share {
        // The skip button's countdown: the pill is about as wide as glyph + label + padding.
        // Measured like the Mac's `GeometryReader` over the real button: padding, glyph, gap 8 and the set label.
        let pad = if c.tv { 36.0 } else { 18.0 };
        let glyph_w = if m.form == Form::Desktop { 16.0 } else { size };
        let full = pad * 2.0 + glyph_w + 8.0 + label_width(c, &text, size, 600);
        back.push(
            Node::rect(Color::new(dark.r, dark.g, dark.b, 0.16), 0.0).frame(
                Some(full * s as f32),
                Some(h),
                Alignment::LEADING,
            ),
        );
    }
    let n = col
        .frame(None, Some(h), Alignment::LEADING)
        .background(Node::zstack(Alignment::LEADING, back), Alignment::LEADING)
        .clipped();
    let n = n.key("offer").on_tap(Action::from("offer"));
    let n = if c.tv {
        n.focusable(focus_id("offer"), Some(FocusLook::tile(18.0)))
    } else {
        n
    };
    // Desktop: right 28, bottom 76 (`PS:396`).
    let bottom = if m.form == Form::Desktop {
        76.0
    } else {
        m.bottom + m.bar_h + m.over_bar
    };
    fill_frame(
        n.padding(ins(0.0, m.edge, bottom, m.edge)),
        Alignment::BOTTOM_TRAILING,
    )
}

/// The next-episode card (`EpisodeCardsView.swift:22-205`): bottom right, 16:9, at most 30 % of the width, a ring, the
/// close button top right, "F3 · in 7 s" and the name below. Position, scale and fade come from [`CardMotion`].
fn card(c: &Ctx<'_>) -> Option<Node> {
    let (look, data) = (c.p.card, c.p.card_data.as_ref()?);
    if !look.shown || c.m.form != Form::Desktop {
        return None;
    }
    let (title, share, secs, code) = data;
    let r = player_card::card_rect(c.env.size.w, c.env.size.h, c.m.edge, 76.0, &look);
    let back = Node::rect(color(colour::RAISED), 12.0).paint(Paint::Linear {
        gradient: LinearGradient {
            start: color(colour::RAISED),
            end: Color::new(0.06, 0.06, 0.07, 1.0),
            from: [0.0, 0.0],
            to: [1.0, 1.0],
        },
        radius: 12.0,
    });
    let ring = Node::rect(Color::CLEAR, 12.0)
        .paint(Paint::Stroke {
            color: Color::new(1.0, 1.0, 1.0, 0.55),
            width: 2.0,
            radius: 12.0,
        })
        .scaled(look.ring, Motion::Instant)
        .scale_about(0.5, 0.5)
        .opacity(look.details, Motion::Instant);
    let still =
        c.p.card_img
            .map(|(img, a)| Node::image(img, r.w, r.h, 12.0).opacity(a, Motion::Instant));
    let count = format!("{code} · in {secs} s");
    let text = Node::vstack(
        Align::Start,
        Some(2.0),
        vec![
            label(c, &count, 13.0, 400, colour::FONT_QUIET),
            label(c, title, 17.0, 600, colour::FONT),
        ],
    )
    .padding(ins(0.0, 14.0, 12.0, 14.0));
    let share_w = (r.w - 28.0) * (*share as f32).clamp(0.0, 1.0);
    let bar = Node::rect(Color::new(1.0, 1.0, 1.0, 0.18), 1.5)
        .frame(Some(r.w - 28.0), Some(3.0), Alignment::LEADING)
        .background(
            Node::rect(color(colour::MARK_ACCENT), 1.5).frame(
                Some(share_w),
                Some(3.0),
                Alignment::LEADING,
            ),
            Alignment::LEADING,
        );
    let x_disc = Node::zstack(
        Alignment::CENTER,
        vec![
            Node::rect(rgba(colour::AREA, 0.85), player_card::X_SIZE / 2.0).frame(
                Some(player_card::X_SIZE),
                Some(player_card::X_SIZE),
                Alignment::CENTER,
            ),
            c.g.node("x", 12.0, white()),
        ],
    )
    .frame(
        Some(player_card::X_HIT),
        Some(player_card::X_HIT),
        Alignment::CENTER,
    )
    .key("card-x")
    .a11y_label(swiftly_ui::a11y::Role::Button, "Abspann behalten");
    let x_at = player_card::x_rect(swiftly_layout::Rect::new(0.0, 0.0, r.w, r.h));
    let body = Node::zstack(
        Alignment::TOP_LEADING,
        vec![
            back,
            still.unwrap_or_else(|| Node::fixed(0.0, 0.0)),
            fill_frame(
                bar.padding(ins(0.0, 14.0, 0.0, 14.0))
                    .opacity(look.details, Motion::Instant),
                Alignment::BOTTOM_LEADING,
            ),
            fill_frame(
                text.opacity(look.details, Motion::Instant).padding(ins(
                    0.0,
                    0.0,
                    10.0 - player_card::DETAILS_RISE
                        * (1.0 - look.details)
                        * f32::from(!c.env.reduce_motion),
                    0.0,
                )),
                Alignment::BOTTOM_LEADING,
            ),
            x_disc
                .opacity(look.details, Motion::Instant)
                .padding(ins(x_at.y, x_at.x, 0.0, 0.0)),
            ring,
        ],
    )
    .frame(Some(r.w), Some(r.h), Alignment::TOP_LEADING)
    .scaled(look.scale, Motion::Instant)
    .scale_about(0.5, 0.5)
    .opacity(look.opacity, Motion::Instant)
    .key("card");
    Some(fill_frame(
        body.padding(ins(r.y, r.x, 0.0, 0.0)),
        Alignment::TOP_LEADING,
    ))
}

/// The key hints under the centre row (`PS:895-1869`): "←" "10 s", "Leertaste" Pause/Abspielen, "→" "30 s".
fn key_hints(c: &Ctx<'_>) -> Node {
    let cap = |s: &str| {
        label(c, s, 12.0, 400, colour::FONT_QUIET)
            .fixed_size(true, false)
            .padding(ins(1.0, 6.0, 1.0, 6.0))
            .background(
                Node::rect(Color::new(1.0, 1.0, 1.0, 0.12), 5.0),
                Alignment::CENTER,
            )
    };
    let (back, fwd) = c.p.c.jump_seconds;
    let playing = matches!(c.p.t.phase, Phase::Playing);
    let one = |key: &str, words: String| {
        Node::hstack(
            Align::Center,
            Some(6.0),
            vec![
                cap(key),
                label(c, &words, 12.0, 400, colour::FONT_QUIET).fixed_size(true, false),
            ],
        )
    };
    let row = Node::hstack(
        Align::Center,
        Some(16.0),
        vec![
            one("←", format!("{back} s")),
            one(
                "Leertaste",
                (if playing { "Pause" } else { "Abspielen" }).to_owned(),
            ),
            one("→", format!("{fwd} s")),
        ],
    );
    // Every text keeps its natural width (`fixed_size` above): the row was squeezed to the width of the buttons above
    // it and the paused hint read "Leert... Abspielen".
    // Centre of the row sits 50 below the middle of the centre row, which itself is 20 above the window middle.
    fill_frame(row.padding(ins(60.0, 0.0, 0.0, 0.0)), Alignment::CENTER).key("key-hints")
}

/// App-drawn cue (`SubtitleOverlay.swift:112-193`): size = picture height * 0.0625 * 0.78, white semibold, black
/// shadow .63 with no blur, margin 16 (+7 % of the height while the controls are up), no box.
fn subtitle_desktop(c: &Ctx<'_>, s: &str) -> Node {
    let h = c.env.size.h;
    // The stored look (`utAussehen`): size, colour, outline, shadow, box and the raised position; without one the
    // defaults of the engine path (white, 0.0625 x 0.78 of the picture).
    let look = c.p.sub_style.clone();
    let (share, rgb, outline, shadow, boxed, margin_px, raise) = match &look {
        Some(l) => (
            l.text_share,
            l.colour,
            l.outline_em,
            l.shadow,
            l.background,
            l.margin_px as f32,
            l.margin_share as f32,
        ),
        None => (0.0625 * 0.78, 0xFF_FFFF, 0.0, true, false, 16.0, 0.0),
    };
    let picture = look.as_ref().map_or(h, |l| (l.picture_pt as f32).max(1.0));
    let size = (picture * share as f32).round().max(6.0);
    let margin = margin_px + raise * picture + if c.p.c.visible { h * 0.07 } else { 0.0 };
    let style = swiftly_text::TextStyle::from(swiftly_design::TextStyle {
        size,
        weight: 600,
        ..base()
    });
    let ink = Color::new(
        ((rgb >> 16) & 0xFF) as f32 / 255.0,
        ((rgb >> 8) & 0xFF) as f32 / 255.0,
        (rgb & 0xFF) as f32 / 255.0,
        1.0,
    );
    let text = |col: Color| Node::text(c.cx, s, &style, col, Some(3), swiftly_text::Align::Center);
    let mut layers = Vec::new();
    let reach = (outline as f32 * size).round();
    if reach >= 1.0 {
        // The outline: the line in black, eight steps around the text.
        for (dx, dy) in [
            (-1.0, 0.0),
            (1.0, 0.0),
            (0.0, -1.0),
            (0.0, 1.0),
            (-0.7, -0.7),
            (0.7, -0.7),
            (-0.7, 0.7),
            (0.7, 0.7),
        ] {
            layers.push(text(Color::new(0.0, 0.0, 0.0, 1.0)).padding(ins(
                reach * dy + reach,
                reach * dx + reach,
                reach - reach * dy,
                reach - reach * dx,
            )));
        }
    }
    if shadow {
        layers.push(text(Color::new(0.0, 0.0, 0.0, 0.63)).padding(ins(size * 0.04, 0.0, 0.0, 0.0)));
    }
    layers.push(text(ink));
    let mut t = Node::zstack(Alignment::TOP, layers);
    if boxed {
        t = t.padding(ins(4.0, 10.0, 4.0, 10.0)).background(
            Node::rect(Color::new(0.0, 0.0, 0.0, 0.55), 6.0),
            Alignment::CENTER,
        );
    }
    let w = c.env.size.w * 0.9;
    fill_frame(
        t.frame(Some(w), None, Alignment::TOP)
            .padding(ins(0.0, 0.0, margin, 0.0)),
        Alignment::BOTTOM,
    )
    .key("subtitle")
}

fn subtitle(c: &Ctx<'_>) -> Option<Node> {
    let s = c.p.t.subtitle.as_ref()?;
    let m = &c.m;
    if m.form == Form::Desktop {
        return Some(subtitle_desktop(c, s));
    }
    let lift = if c.p.c.visible {
        m.bottom + m.bar_h + m.over_bar + 10.0
    } else {
        m.bottom + 36.0
    };
    let t = Node::text(
        c.cx,
        s,
        &swiftly_text::TextStyle::from(swiftly_design::TextStyle {
            size: m.sub,
            weight: 600,
            ..base()
        }),
        white(),
        Some(3),
        swiftly_text::Align::Center,
    )
    .padding(ins(4.0, 12.0, 4.0, 12.0))
    .background(
        Node::rect(Color::new(0.0, 0.0, 0.0, 0.55), 6.0),
        Alignment::CENTER,
    );
    Some(fill_frame(t.padding(ins(0.0, m.edge, lift, m.edge)), Alignment::BOTTOM).key("subtitle"))
}

fn jump_mark(c: &Ctx<'_>) -> Option<Node> {
    let (bearing, secs) = c.p.c.jump_display?;
    let desk = c.m.form == Form::Desktop;
    let sign = if bearing < 0 { "−" } else { "+" };
    let g = c.g.node(
        skip_glyph_name(bearing > 0),
        if desk { 32.0 } else { 40.0 },
        white(),
    );
    let t = label(
        c,
        &if desk {
            format!("{secs} s")
        } else {
            format!("{sign}{secs} s")
        },
        13.0,
        500,
        colour::FONT,
    );
    let n = Node::vstack(Align::Center, Some(6.0), vec![g, t])
        .frame(Some(108.0), Some(108.0), Alignment::CENTER)
        .background(
            Node::rect(Color::new(0.0, 0.0, 0.0, 0.45), 54.0),
            Alignment::CENTER,
        );
    let side = if bearing < 0 {
        Alignment::LEADING
    } else {
        Alignment::TRAILING
    };
    let w = c.env.size.w;
    let pad = if desk { 44.0 } else { w * 0.12 };
    // The indicator fades in and out with `easeInOut(0.15)` (`PlayerScreen.swift:1018,1024`).
    let motion = swiftly_ui::feel::of(swiftly_motion::catalogue::Id::SkipDisplay);
    Some(
        fill_frame(n.padding(ins(0.0, pad, 0.0, pad)), side)
            .appear_from(1.0, 0.0)
            .appear_after_first_build()
            .exit_to(1.0, 0.0)
            .opacity(1.0, motion)
            .key("jump"),
    )
}

fn row(c: &Ctx<'_>, key: &str, action: &str, text: &str, selected: bool) -> Node {
    let m = &c.m;
    let tv = c.tv;
    let size = if tv { 28.0 } else { 16.0 };
    let mut kids = vec![
        label(
            c,
            text,
            size,
            if selected { 600 } else { 400 },
            colour::FONT,
        ),
        Node::spacer(),
    ];
    if selected {
        kids.push(c.g.node("check", size, white()));
    }
    let n = Node::hstack(Align::Center, Some(10.0), kids)
        .padding(ins(0.0, 10.0, 0.0, 10.0))
        .frame(None, Some(m.row_h), Alignment::LEADING);
    let n = n.key(key).on_tap(Action::from(action));
    if tv {
        n.focusable(focus_id(key), Some(FocusLook::tile(14.0)))
    } else {
        n
    }
}

fn column(c: &Ctx<'_>, title: &str, rows: Vec<Node>, width: Option<f32>) -> Node {
    let mut kids = vec![
        label(c, title, if c.tv { 36.0 } else { 20.0 }, 700, colour::FONT)
            .padding(ins(0.0, 10.0, 8.0, 0.0)),
    ];
    kids.extend(rows);
    Node::vstack(Align::Start, Some(0.0), kids).frame(width, None, Alignment::TOP_LEADING)
}

fn delay_row(c: &Ctx<'_>, tag: &str, ms: i64) -> Node {
    let size = if c.tv { 24.0 } else { 14.0 };
    let step = |sign: &str, symbol: &str| {
        let key = format!("delay:{tag}:{sign}");
        let b = label(c, symbol, size + 6.0, 600, colour::FONT).frame(
            Some(c.m.button),
            Some(c.m.row_h),
            Alignment::CENTER,
        );
        let b = b.key(key.as_str()).on_tap(Action::from(key.as_str()));
        if c.tv {
            b.focusable(focus_id(key.as_str()), Some(FocusLook::tile(14.0)))
        } else {
            b
        }
    };
    Node::hstack(
        Align::Center,
        Some(6.0),
        vec![
            label(c, "Verzögerung", size, 400, colour::FONT_QUIET),
            Node::spacer(),
            step("-", "−"),
            label(c, &format!("{ms} ms"), size, 500, colour::FONT),
            step("+", "+"),
        ],
    )
    .padding(ins(8.0, 10.0, 0.0, 10.0))
}

/// "+0,05 s" with U+2212 for negatives (`PK/Delay.swift`).
fn delay_text(ms: i64) -> String {
    let sign = if ms > 0 {
        "+"
    } else if ms < 0 {
        "−"
    } else {
        ""
    };
    let a = ms.abs();
    format!("{sign}{},{:02} s", a / 1000, a % 1000 / 10)
}

/// A menu row of the Mac layers (`PL:205`): check slot 17 on the left, 15 regular, selected white else #CCC, pad
/// 10x7, hover fill white 6 % radius 12.
/// The body of a layer row (`LayersRow`): the check column and the text, over the whole width of the column. The row takes
/// the width (`frame(maxWidth: .infinity, alignment: .leading)`); a `Spacer` beside the text would hand it half of what
/// is left, and "Unbegrenzt" would read "Unbegre..." in a 200 pt column.
fn row_layout(check: Node, text: Node) -> Node {
    let row = Node::hstack(
        Align::Center,
        Some(4.0),
        vec![check.frame(Some(17.0), None, Alignment::CENTER), text],
    )
    .padding(ins(7.0, 10.0, 7.0, 10.0));
    crate::browse::wide(row, Alignment::LEADING)
}

fn row_desktop(c: &Ctx<'_>, key: &str, action: &str, text: &str, selected: bool) -> Node {
    let check = if selected {
        c.g.node("check", 13.0, white())
    } else {
        Node::fixed(13.0, 13.0)
    };
    let tone = if selected {
        colour::FONT
    } else {
        colour::FONT_QUIET
    };
    row_layout(check, label(c, text, 15.0, 400, tone))
        .hover_surface(Color::new(1.0, 1.0, 1.0, 0.06), 12.0)
        .key(key)
        .on_tap(Action::from(action))
}

/// The base of every layer (`LayersReason`): the picture blurred (`.ultraThinMaterial`) under the ground colour at 0.72.
/// The desktop uses the renderer's backdrop blur; the other forms keep the flat dim.
fn layer_dim(c: &Ctx<'_>, flat: f32) -> Node {
    if c.m.form == Form::Desktop {
        Node::rect(Color::new(0.0, 0.0, 0.0, 0.0), 0.0).paint(Paint::Blur {
            blur: LAYER_BLUR,
            tint: rgba(colour::REASON, 0.72),
            radius: 0.0,
        })
    } else {
        Node::rect(Color::new(0.0, 0.0, 0.0, flat), 0.0)
    }
}

/// Blur radius of the layer base in points (the system's ultra thin material).
const LAYER_BLUR: f32 = 24.0;

/// Where a layer's columns start from the top (`PL` rail line plus the heading gap).
fn layer_columns_top(m: &Metrics) -> f32 {
    m.rail_top + m.button / 2.0 + 50.0 - 0.5
}

/// The width of the Audio and Subtitle columns: 360 pt, narrower when the window cannot hold both between its margins.
fn track_column_width(c: &Ctx<'_>) -> f32 {
    ((c.env.size.w - 2.0 * c.m.edge - 45.0) / 2.0).clamp(160.0, 360.0)
}

/// A column: its heading stays, its rows scroll (`PL:192`: `ScrollView`, 12 at the bottom, no indicator).
fn column_desktop(c: &Ctx<'_>, title: &str, rows: Vec<Node>, width: f32) -> Node {
    let head = label(c, title, 17.0, 600, colour::FONT).padding(ins(0.0, 10.0, 6.0, 10.0));
    let head_h =
        c.cx.measure_text(
            title,
            &swiftly_text::TextStyle::from(swiftly_design::TextStyle {
                size: 17.0,
                weight: 600,
                ..base()
            }),
            Some(1),
            swiftly_layout::Proposal::NIL,
        )
        .h + 6.0;
    let room = (c.env.size.h - layer_columns_top(&c.m) - head_h).max(60.0);
    let list = Node::vstack(Align::Start, Some(2.0), rows).padding(ins(0.0, 0.0, 12.0, 0.0));
    let body = Node::scroll(Axis::Vertical, None, list).frame(
        Some(width),
        Some(room),
        Alignment::TOP_LEADING,
    );
    Node::vstack(Align::Start, Some(0.0), vec![head, body]).frame(
        Some(width),
        None,
        Alignment::TOP_LEADING,
    )
}

/// Minus, value (15 mono), plus and a reset that hides at 0 (`PL:267`).
fn delay_row_desktop(c: &Ctx<'_>, tag: &str, ms: i64) -> Node {
    let step = |key: String, inner: Node| {
        inner
            .frame(Some(30.0), Some(28.0), Alignment::CENTER)
            .hover_surface(Color::new(1.0, 1.0, 1.0, 0.06), 8.0)
            .key(key.as_str())
            .on_tap(Action::from(key.as_str()))
    };
    let mut kids = vec![
        label(c, "Verzögerung", 13.0, 400, colour::FONT_QUIET),
        Node::spacer(),
        step(
            format!("delay:{tag}:-"),
            label(c, "−", 15.0, 600, colour::FONT),
        ),
        label(c, &delay_text(ms), 15.0, 500, colour::FONT),
        step(
            format!("delay:{tag}:+"),
            label(c, "+", 15.0, 600, colour::FONT),
        ),
    ];
    if ms != 0 {
        kids.push(step(
            format!("delay:{tag}:0"),
            c.g.node("gobackward", 14.0, white()),
        ));
    }
    Node::hstack(Align::Center, Some(4.0), kids).padding(ins(8.0, 10.0, 0.0, 10.0))
}

/// The layers on the Mac (`PL:137-259`): darkened picture, columns centred with gap 45 from iconTop + 50, the only
/// header item is the X at the rail position.
fn layer_desktop(c: &Ctx<'_>, which: PlayerLayer) -> Node {
    let (p, m) = (c.p, &c.m);
    let dim = layer_dim(c, 0.72)
        .key("layer-close")
        .on_tap(Action::from("layer-close"));
    let cols: Vec<Node> = if which == PlayerLayer::Tracks {
        let mut audio: Vec<Node> = p
            .tracks
            .audio
            .iter()
            .map(|t| {
                row_desktop(
                    c,
                    &format!("audio:{}", t.index),
                    &format!("audio:{}", t.index),
                    &t.label,
                    t.selected,
                )
            })
            .collect();
        let mut subs = vec![row_desktop(
            c,
            "sub:-1",
            "sub:-1",
            "Aus",
            p.tracks.subtitles_off,
        )];
        subs.extend(p.tracks.subtitles.iter().map(|t| {
            row_desktop(
                c,
                &format!("sub:{}", t.index),
                &format!("sub:{}", t.index),
                &t.label,
                t.selected,
            )
        }));
        audio.push(delay_row_desktop(c, "audio", p.tracks.audio_delay_ms));
        subs.push(delay_row_desktop(c, "sub", p.tracks.subtitle_delay_ms));
        vec![
            column_desktop(c, "Audio", audio, track_column_width(c)),
            column_desktop(c, "Untertitel", subs, track_column_width(c)),
        ]
    } else {
        let picture = vec![
            row_desktop(c, "fill:0", "fill:0", "Original", !p.fill),
            row_desktop(c, "fill:1", "fill:1", "Füllen", p.fill),
        ];
        let mut sleep = vec![row_desktop(
            c,
            "sleep:off",
            "sleep:0",
            "Aus",
            p.c.sleep_minutes.is_none(),
        )];
        for mins in SLEEP_CHOICES {
            sleep.push(row_desktop(
                c,
                &format!("sleep:{mins}"),
                &format!("sleep:{mins}"),
                &format!("{mins} Min."),
                p.c.sleep_minutes == Some(mins),
            ));
        }
        let shield = vec![
            row_desktop(c, "tech:0", "tech:0", "Aus", !p.tech),
            row_desktop(c, "tech:1", "tech:1", "An", p.tech),
        ];
        let mut cols = Vec::new();
        // "Gemeinsam" comes first: who is there, and below it the exit (`PlayerLayers.swift:461-487`).
        if let Some((name, _)) = &p.group {
            cols.push(column_desktop(
                c,
                &format!("Gemeinsam · {name}"),
                group_rows(c, 15.0),
                200.0,
            ));
        }
        cols.extend(vec![
            column_desktop(c, "Bild", picture, 200.0),
            column_desktop(c, "Schlafzeit", sleep, 200.0),
            column_desktop(c, "Technikschild", shield, 200.0),
        ]);
        if let Some(q) = &p.c.quality {
            let mut quality = vec![row_desktop(
                c,
                "q:dp",
                "quality:dp",
                "Direct Play",
                q.direct_play,
            )];
            for cap in QUALITY_CAPS {
                let text = if cap == 0 {
                    "Unbegrenzt".to_owned()
                } else {
                    format!("{cap} Mbit/s")
                };
                quality.push(row_desktop(
                    c,
                    &format!("q:{cap}"),
                    &format!("quality:{cap}"),
                    &text,
                    !q.direct_play && q.limit == cap,
                ));
            }
            cols.push(column_desktop(c, "Qualität", quality, 200.0));
        }
        cols
    };
    let body = fill_frame(
        // The columns keep the Mac's side margin (`m.edge`): a window too narrow for two 360 pt columns narrows them, so
        // the first never touches the window edge (at 125 % the Audio column started 7 px from it).
        Node::hstack(Align::Start, Some(45.0), cols).padding(ins(
            layer_columns_top(m),
            m.edge,
            0.0,
            m.edge,
        )),
        Alignment::TOP,
    );
    let x = rail_button(c, "x", "layer-x", "layer-close", "Schließen (Esc)", true).padding(ins(
        m.rail_top,
        0.0,
        0.0,
        m.edge - (m.button - m.glyph) / 2.0,
    ));
    fill_frame(
        Node::zstack(
            Alignment::TOP_LEADING,
            vec![dim, body, fill_frame(x, Alignment::TOP_TRAILING)],
        )
        .key("layer"),
        Alignment::TOP_LEADING,
    )
}

fn layer_panel(c: &Ctx<'_>, which: PlayerLayer) -> Node {
    if c.m.form == Form::Desktop {
        return layer_desktop(c, which);
    }
    let (p, m) = (c.p, &c.m);
    let w = c.env.size.w;
    let tv = c.tv;
    let dim = Node::rect(Color::new(0.0, 0.0, 0.0, if tv { 0.82 } else { 0.72 }), 0.0)
        .key("layer-close")
        .on_tap(Action::from("layer-close"));
    let col_w = if tv {
        640.0
    } else {
        ((w - 2.0 * m.edge - 24.0) / if w > 700.0 { 2.0 } else { 1.0 }).min(420.0)
    };
    let cols: Vec<Node> = match which {
        PlayerLayer::Tracks => {
            let audio: Vec<Node> = p
                .tracks
                .audio
                .iter()
                .map(|t| {
                    row(
                        c,
                        &format!("audio:{}", t.index),
                        &format!("audio:{}", t.index),
                        &t.label,
                        t.selected,
                    )
                })
                .collect();
            let mut subs = vec![row(c, "sub:-1", "sub:-1", "Aus", p.tracks.subtitles_off)];
            subs.extend(p.tracks.subtitles.iter().map(|t| {
                row(
                    c,
                    &format!("sub:{}", t.index),
                    &format!("sub:{}", t.index),
                    &t.label,
                    t.selected,
                )
            }));
            let mut a = audio;
            a.push(delay_row(c, "audio", p.tracks.audio_delay_ms));
            subs.push(delay_row(c, "sub", p.tracks.subtitle_delay_ms));
            vec![
                column(c, "Audio", a, Some(col_w)),
                column(c, "Untertitel", subs, Some(col_w)),
            ]
        }
        _ => {
            let tempo: Vec<Node> = TEMPOS
                .iter()
                .map(|t| {
                    row(
                        c,
                        &format!("tempo:{t}"),
                        &format!("tempo:{t}"),
                        &if (*t - 1.0).abs() < f32::EPSILON {
                            "Normal".to_owned()
                        } else {
                            format!("{t}×")
                        },
                        (p.t.tempo - t).abs() < 1e-3,
                    )
                })
                .collect();
            // `SettingLayer`: columns Bild, Schlafzeit, Qualität (with Technikschild).
            let picture = vec![
                row(c, "fill:0", "fill:0", "Original", !p.fill),
                row(c, "fill:1", "fill:1", "Füllen", p.fill),
            ];
            let mut sleep = vec![row(
                c,
                "sleep:off",
                "sleep:0",
                "Aus",
                p.c.sleep_minutes.is_none(),
            )];
            for mins in SLEEP_CHOICES {
                sleep.push(row(
                    c,
                    &format!("sleep:{mins}"),
                    &format!("sleep:{mins}"),
                    &format!("{mins} Min."),
                    p.c.sleep_minutes == Some(mins),
                ));
            }
            let shield = vec![
                row(c, "tech:0", "tech:0", "Aus", !p.tech),
                row(c, "tech:1", "tech:1", "An", p.tech),
            ];
            let mut cols = Vec::new();
            if let Some((name, _)) = &p.group {
                cols.push(column(
                    c,
                    &format!("Gemeinsam · {name}"),
                    group_rows(c, if c.tv { 28.0 } else { 16.0 }),
                    Some(col_w),
                ));
            }
            cols.extend(vec![
                column(c, "Tempo", tempo, Some(col_w)),
                column(c, "Bild", picture, Some(col_w)),
                column(c, "Schlafzeit", sleep, Some(col_w)),
                column(c, "Technikschild", shield, Some(col_w)),
            ]);
            if let Some(q) = &p.c.quality {
                let mut quality = vec![row(c, "q:dp", "quality:dp", "Direct Play", q.direct_play)];
                for cap in QUALITY_CAPS {
                    let text = if cap == 0 {
                        "Unbegrenzt".to_owned()
                    } else {
                        format!("{cap} Mbit/s")
                    };
                    quality.push(row(
                        c,
                        &format!("q:{cap}"),
                        &format!("quality:{cap}"),
                        &text,
                        !q.direct_play && q.limit == cap,
                    ));
                }
                cols.push(column(c, "Qualität", quality, Some(col_w)));
            }
            cols
        }
    };
    let title = if which == PlayerLayer::Tracks {
        "Audio & Untertitel"
    } else {
        "Einstellungen"
    };
    let head = Node::hstack(
        Align::Center,
        Some(12.0),
        vec![
            label(c, title, m.title, 600, colour::FONT),
            Node::spacer(),
            icon_button(c, "x", "layer-x", "layer-close", true),
        ],
    );
    let head = head.padding(ins(
        m.top,
        m.edge,
        12.0,
        m.edge - if tv { 0.0 } else { (m.button - m.glyph) / 2.0 },
    ));
    let cols = Node::hstack(Align::Start, Some(if tv { 80.0 } else { 24.0 }), cols).padding(ins(
        if tv { 90.0 } else { 0.0 },
        m.edge,
        0.0,
        m.edge,
    ));
    let panel = Node::vstack(
        Align::Start,
        Some(0.0),
        vec![head, Node::scroll(Axis::Vertical, None, cols)],
    );
    let mut n = Node::zstack(
        Alignment::TOP_LEADING,
        vec![dim, fill_frame(panel, Alignment::TOP_LEADING)],
    )
    .key("layer");
    if tv {
        n = n.focus_scope(ScopeSpec::trap(focus_id("layer")));
    }
    fill_frame(n, Alignment::TOP_LEADING)
}

/// The Technikschild on the picture (`Shared/TechBadge.swift`): delivery word in accent, then name (quiet) and
/// value per line. Information only, it takes no taps. Slides to the top edge with the controls.
fn tech_badge(c: &Ctx<'_>) -> Option<Node> {
    if !c.p.tech {
        return None;
    }
    let m = &c.m;
    let size = if c.tv { 24.0 } else { 12.0 };
    let gap = if c.tv { 7.0 } else { 4.0 };
    let line = |name: &str, value: &str| {
        Node::hstack(
            Align::Start,
            Some(size * 0.3),
            vec![
                label(c, name, size, 400, colour::FONT_QUIET),
                label(c, value, size, 400, colour::FONT),
            ],
        )
    };
    let (word, good) = c.p.tech_head.clone()?;
    let mut rows = vec![label(
        c,
        &word,
        size + 1.0,
        600,
        if good {
            colour::MARK_ACCENT
        } else {
            colour::ORIGINAL_WARNING
        },
    )];
    // The reason sits directly under the word, in warning colour, two lines at most (`TechBadge.swift:105`).
    if let Some(reason) = &c.p.tech_reason {
        let style = swiftly_design::TextStyle {
            size,
            weight: 400,
            ..base()
        };
        rows.push(
            txt(c.cx, reason, style, colour::ORIGINAL_WARNING, Some(2)).frame(
                Some(420.0),
                None,
                Alignment::TOP_LEADING,
            ),
        );
    }
    rows.extend(c.p.tech_rows.iter().map(|(n, v)| line(n, v)));
    let open = c.p.c.visible && c.p.c.layer.is_none();
    let below = if c.m.form == Form::Desktop {
        14.0 + 30.0 + 46.0 + 8.0
    } else {
        m.top + m.button + 8.0
    };
    let top = if open { below } else { 0.0 };
    let col = Node::vstack(Align::Start, Some(gap), rows);
    Some(
        fill_frame(
            col.padding(ins(top, m.edge, 0.0, 0.0)),
            Alignment::TOP_LEADING,
        )
        .key("tech-badge"),
    )
}

/// What the big picture shows while the film plays in the small window (`smallerHint`): symbol, one quiet line.
/// The rows of the "Gemeinsam" column: everyone who is there (the names do nothing), then "Gruppe verlassen" in the
/// accent colour.
fn group_rows(c: &Ctx<'_>, size: f32) -> Vec<Node> {
    let mut rows: Vec<Node> =
        c.p.participants
            .iter()
            .enumerate()
            .map(|(i, who)| {
                Node::hstack(
                    Align::Center,
                    Some(4.0),
                    vec![
                        Node::fixed(17.0, 13.0),
                        label(c, who, size, 400, colour::FONT_QUIET),
                        Node::spacer(),
                    ],
                )
                .padding(ins(7.0, 10.0, 7.0, 10.0))
                .key(format!("participant:{i}").as_str())
            })
            .collect();
    rows.push(
        Node::hstack(
            Align::Center,
            Some(9.0),
            vec![
                c.g.node("x", size + 2.0, color(colour::MARK_ACCENT)),
                label(c, "Gruppe verlassen", size, 400, colour::MARK_ACCENT),
                Node::spacer(),
            ],
        )
        .padding(ins(7.0, 10.0, 7.0, 10.0))
        .hover_surface(Color::new(1.0, 1.0, 1.0, 0.06), 12.0)
        .key("group-leave")
        .on_tap(Action::from("group-leave")),
    );
    rows
}

/// What happens in the group, briefly at the top, so nobody wonders why the film is paused (`GroupsEvent`): a capsule
/// on `raised` with a 1 px margin, accent symbol, one line.
fn group_event(c: &Ctx<'_>) -> Option<Node> {
    let e = c.p.event.as_ref()?;
    let m = &c.m;
    let line = Node::hstack(
        Align::Center,
        Some(10.0),
        vec![
            c.g.node(e.symbol, 17.0, color(colour::MARK_ACCENT)),
            label(c, &e.text, 15.0, 400, colour::FONT),
        ],
    )
    .padding(ins(0.0, 16.0, 0.0, 16.0))
    .frame(None, Some(40.0), Alignment::CENTER)
    .background(
        Node::rect(color(colour::RAISED), 20.0).paint(Paint::Stroke {
            color: color(colour::MARGIN),
            width: 1.0,
            radius: 20.0,
        }),
        Alignment::CENTER,
    )
    .key(format!("group-event:{}", e.id).as_str())
    .appear_from(0.97, 0.0)
    .exit_to(0.97, 0.0);
    Some(fill_frame(
        line.padding(ins(m.top + m.button + 8.0, 0.0, 0.0, 0.0)),
        Alignment::TOP,
    ))
}

/// What went wrong with the group, at the bottom above the scrubber; a tap sends it away (`SharedError`).
fn group_error(c: &Ctx<'_>) -> Option<Node> {
    let text = c.p.group_error.as_ref()?;
    let m = &c.m;
    let strip = label(c, text, 15.0, 400, colour::FONT)
        .padding(ins(0.0, 14.0, 0.0, 14.0))
        .frame(None, Some(34.0), Alignment::CENTER)
        .background(
            Node::rect(color(colour::RAISED), 17.0).paint(Paint::Stroke {
                color: color(colour::MARGIN),
                width: 1.0,
                radius: 17.0,
            }),
            Alignment::CENTER,
        )
        .key("group-error")
        .on_tap(Action::from("group-error"))
        .appear_from(0.97, 0.0)
        .exit_to(0.97, 0.0);
    Some(fill_frame(
        strip.padding(ins(0.0, 0.0, m.bottom + m.bar_h + m.over_bar, 0.0)),
        Alignment::BOTTOM,
    ))
}

fn small_hint(c: &Ctx<'_>) -> Option<Node> {
    if !c.p.small {
        return None;
    }
    let col = Node::vstack(
        Align::Center,
        Some(12.0),
        vec![
            c.g.node("pip", 30.0, white()),
            label(c, "Läuft im kleinen Fenster", 15.0, 400, colour::FONT_QUIET),
        ],
    );
    Some(
        Node::zstack(
            Alignment::CENTER,
            vec![
                Node::rect(Color::new(0.0, 0.0, 0.0, 1.0), 0.0),
                fill_frame(col, Alignment::CENTER),
            ],
        )
        .key("small-hint"),
    )
}

/// Sizes of the episode strip: tv uses the landscape tile 448 x 252 with gap 40 and edge 80 (`Theme.landscapeWidth`,
/// `tileSpacing`, `edgePage`), the Mac strip `clamp((w - 2 edge) / 4 - 16, 240, 360)` with gap 16.
struct StripGeometry {
    tv: bool,
    card: f32,
    img: f32,
    gap: f32,
    edge: f32,
}

fn strip_geometry(env: &Env) -> StripGeometry {
    let m = metrics(env);
    if m.form == Form::Tv {
        return StripGeometry {
            tv: true,
            card: 448.0,
            img: 252.0,
            gap: 40.0,
            edge: m.edge,
        };
    }
    let card = (((env.size.w - 2.0 * m.edge) / 4.0) - 16.0).clamp(240.0, 360.0);
    StripGeometry {
        tv: false,
        card,
        img: (card * 9.0 / 16.0).round(),
        gap: 16.0,
        edge: m.edge,
    }
}

/// The season line in the meta place: on tv the `SeasonPill` (56 high, padding 24, 26/600, white 10 %, capsule), else
/// the plain line; both open the season list.
fn season_pill(c: &Ctx<'_>) -> Node {
    let name =
        c.p.season_names
            .get(c.p.seasons.1)
            .map_or("", String::as_str);
    if c.p.season_names.is_empty() {
        return Node::spacer_min(0.0);
    }
    if !c.tv {
        return label(c, name, c.m.meta + 1.0, 600, colour::FONT)
            .key("season")
            .on_tap(Action::from("season"));
    }
    let t = Node::hstack(
        Align::Center,
        Some(12.0),
        vec![
            label(c, name, 26.0, 600, colour::FONT),
            c.g.node("caret-down", 22.0, white()),
        ],
    );
    let pill = t
        .padding(ins(0.0, 24.0, 0.0, 24.0))
        .frame(None, Some(56.0), Alignment::CENTER)
        .background(
            Node::rect(Color::new(1.0, 1.0, 1.0, 0.10), 28.0),
            Alignment::CENTER,
        );
    pill.key("season")
        .on_tap(Action::from("season"))
        .focusable(focus_id("season"), Some(FocusLook::tile(28.0)))
}

/// The season list (`ActionPanel`, rows 72 high, 30/500, corner 16, the chosen one 600 with a check).
fn season_list(c: &Ctx<'_>) -> Node {
    let rows: Vec<Node> =
        c.p.season_names
            .iter()
            .enumerate()
            .map(|(i, name)| {
                let on = i == c.p.seasons.1;
                let size = if c.tv { 30.0 } else { 15.0 };
                let mut kids = vec![
                    label(
                        c,
                        name,
                        size,
                        if on { 600 } else { 500 },
                        if on { colour::FONT } else { colour::FONT_QUIET },
                    ),
                    Node::spacer(),
                ];
                if on {
                    kids.push(c.g.node("check", size, white()));
                }
                let h = if c.tv { 72.0 } else { 40.0 };
                let key = format!("season:{i}");
                let row = Node::hstack(Align::Center, Some(12.0), kids)
                    .padding(ins(0.0, 20.0, 0.0, 20.0))
                    .frame(
                        Some(if c.tv { 420.0 } else { 220.0 }),
                        Some(h),
                        Alignment::LEADING,
                    )
                    .key(key.as_str())
                    .on_tap(Action::from(key.as_str()));
                if c.tv {
                    row.focusable(focus_id(key.as_str()), Some(FocusLook::tile(16.0)))
                } else {
                    row
                }
            })
            .collect();
    let panel = Node::vstack(Align::Start, Some(4.0), rows)
        .padding(ins(10.0, 10.0, 10.0, 10.0))
        .background(
            Node::rect(Color::new(0.12, 0.12, 0.12, 0.98), 16.0),
            Alignment::CENTER,
        );
    let top = c.m.top
        + if c.tv {
            61.6 + 10.0 + 56.0 + 12.0
        } else {
            40.0
        };
    let n = panel
        .padding(ins(top, c.m.edge, 0.0, 0.0))
        .key("season-list");
    let mut n = fill_frame(n, Alignment::TOP_LEADING);
    if c.tv {
        n = n.focus_scope(ScopeSpec::trap(focus_id("season-list")));
    }
    n
}

/// The episodes layer: the title stays where the player shows it, the season line sits in the meta place and the
/// strip of cards (`PlayerEpisodeStrip`, running episode 1.25 x in the middle) lies below.
fn episodes_layer(c: &Ctx<'_>) -> Node {
    let (m, w) = (&c.m, c.env.size.w);
    let tv = c.tv;
    let dim = layer_dim(c, if tv { 0.82 } else { 0.72 })
        .key("layer-close")
        .on_tap(Action::from("layer-close"));
    let dim = fill_frame(dim, Alignment::CENTER);
    let head = Node::hstack(
        Align::Start,
        Some(12.0),
        vec![
            Node::vstack(
                Align::Start,
                Some(3.0),
                vec![
                    label(c, "Nordlicht", m.title, 600, colour::FONT).opacity(0.0, Motion::Instant),
                    season_pill(c),
                ],
            ),
            Node::spacer(),
            icon_button(c, "x", "layer-x", "layer-close", true),
        ],
    )
    .padding(ins(
        m.top,
        m.edge,
        0.0,
        m.edge - if tv { 0.0 } else { (m.button - m.glyph) / 2.0 },
    ));
    let g = strip_geometry(c.env);
    let (card_w, img_h) = (g.card, g.img);
    let cards: Vec<Node> = c
        .p
        .cards
        .iter()
        .enumerate()
        .map(|(i, d)| {
            let (title, share, watched) = (d.header.as_str(), d.progress.unwrap_or(0.0), d.watched);
            // tv: every card the same landscape tile (`TileContent`), no larger running card; focus marks it.
            let current = Some(i) == c.p.current_card;
            let scale = if current && !tv { 1.25 } else { 1.0 };
            let (cw, ch) = (card_w * scale, img_h * scale);
            let corner = if tv { 16.0 } else { 10.0 };
            let mut pic = vec![Node::rect(color(colour::AREA), corner).frame(
                Some(cw),
                Some(ch),
                Alignment::CENTER,
            )];
            if let Some(Some((img, a))) = c.p.card_imgs.get(i) {
                pic.push(Node::image(*img, cw, ch, corner).opacity(*a, Motion::Instant));
            }
            if watched {
                // The Mac's `colorMultiply(white 0.45)` on the whole picture: black at 55 % over area and still.
                pic.push(Node::rect(Color::new(0.0, 0.0, 0.0, 0.55), 0.0).frame(
                    Some(cw),
                    Some(ch),
                    Alignment::CENTER,
                ));
            }
            // A watched card shows a badge instead of the bar (`progress: episode.isWatched ? nil : ...`).
            if share > 0.0 && !watched {
                // The Mac's `ImageArea` bar: 4 pt, light track and accent bar, inside the card's rounded mask.
                let bar = if tv {
                    Node::rect(Color::new(1.0, 1.0, 1.0, 0.9), 0.0).frame(
                        Some(cw * share),
                        Some(6.0),
                        Alignment::LEADING,
                    )
                } else {
                    crate::home::progress_bar(cw, corner, share)
                };
                pic.push(bar);
            }
            let pic = Node::zstack(Alignment::BOTTOM_LEADING, pic)
                .frame(Some(cw), Some(ch), Alignment::CENTER)
                .clipped_rounded(corner);
            // `TileBadge(.watched)` top right (the Mac's card); a watched card shows no bar.
            let pic = if watched && !tv {
                let tick = Node::hstack(
                    Align::Center,
                    Some(3.0),
                    vec![c.g.node("check", 10.0, color(colour::FONT))],
                )
                .padding(ins(3.0, 5.0, 3.0, 5.0))
                .background(
                    Node::rect(rgba(colour::REASON, 0.78), 9.0).paint(Paint::Stroke {
                        color: color(colour::MARGIN),
                        width: 1.0,
                        radius: 9.0,
                    }),
                    Alignment::CENTER,
                )
                .padding(ins(6.0, 6.0, 6.0, 6.0));
                pic.overlay(tick, Alignment::TOP_TRAILING)
            } else {
                pic
            };
            // The Mac scales the picture with its bar and badge to 1.04 under the pointer (`scaleEffect`).
            let pic = if tv {
                pic
            } else {
                pic.hover_scale(swiftly_ui::feel::HOVER_TILE_SCALE)
            };
            let tint = if current || tv {
                colour::FONT
            } else {
                colour::FONT_QUIET
            };
            let (ts, us) = if tv { (26.0, 24.0) } else { (13.0, 12.0) };
            let text = Node::vstack(
                Align::Start,
                Some(2.0),
                vec![
                    label(c, title, ts, 500, tint),
                    label(
                        c,
                        d.sub.as_deref().unwrap_or(""),
                        us,
                        400,
                        if tv {
                            colour::FONT_QUIET
                        } else {
                            colour::FONT_VERY_QUIET
                        },
                    ),
                ],
            );
            let key = format!("episode:{i}");
            let n = Node::vstack(
                Align::Start,
                Some(if tv { 12.0 } else { 8.0 }),
                vec![pic, text],
            )
            .frame(Some(cw), None, Alignment::TOP_LEADING)
            .key(key.as_str())
            .a11y_label(
                swiftly_ui::a11y::Role::Button,
                [Some(d.header.as_str()), d.sub.as_deref()]
                    .into_iter()
                    .flatten()
                    .collect::<Vec<_>>()
                    .join(", "),
            )
            .on_tap(Action::from(key.as_str()));
            if tv {
                n.focusable(focus_id(key.as_str()), Some(FocusLook::tile(16.0)))
            } else {
                // The Mac's `.tileMenu(episode, inPlayer: true)` on every card (`PlayerEpisodeStrip.swift:56`).
                n.on_secondary(Action::from(format!("epmenu:{i}").as_str()))
            }
        })
        .collect();
    let run_out = if tv {
        (w - m.edge - card_w).max(m.edge)
    } else {
        m.edge
    };
    let strip = Node::hstack(
        if tv { Align::Start } else { Align::End },
        Some(g.gap),
        cards,
    )
    .padding(ins(
        if tv { 20.0 } else { 8.0 },
        m.edge,
        if tv { 20.0 } else { 8.0 },
        run_out,
    ));
    let mut strip = Node::scroll(Axis::Horizontal, None, strip);
    if !tv {
        // Arrows (`PlayerEpisodeStrip.arrow`): 34 x 34 on the area colour, corner 8, at the middle of the pictures,
        // shown only while there is more to the left / right.
        let total =
            2.0 * m.edge + c.p.cards.len() as f32 * (g.card + g.gap) - g.gap + g.card * 0.25;
        let x = c.p.strip_x;
        let has_current = c.p.current_card.is_some();
        let at = 8.0 + if has_current { g.img * 0.25 } else { 0.0 } + g.img / 2.0 - 17.0;
        // Both overlays are always there (an empty one while an arrow is hidden): a node's retained state follows its
        // path, so wrapping the scroll view only while an arrow shows made it lose its offset the moment an arrow
        // appeared, and the strip snapped back at every scroll step.
        let arrow = |asset: &str, key: &str, label: &str, on: bool, trailing: bool| -> Node {
            if on {
                crate::home::paging_arrow_inset(c.g.icons(), asset, label, key, trailing, at, 12.0)
            } else {
                Node::fixed(0.0, 0.0)
            }
        };
        let (left, right) = (x > 4.0, x + w < total - 4.0);
        strip = strip.overlay(
            arrow(
                "caret-left",
                "strip:-1",
                "Zur\u{fc}ckbl\u{e4}ttern",
                left,
                false,
            ),
            Alignment::TOP_LEADING,
        );
        strip = strip.overlay(
            arrow("caret-right", "strip:1", "Weiterbl\u{e4}ttern", right, true),
            Alignment::TOP_TRAILING,
        );
    }
    let mut panel_kids = vec![head, strip];
    if c.p.seasons.0 {
        panel_kids.push(Node::fixed(1.0, 0.0));
    }
    let panel = Node::vstack(Align::Start, Some(24.0), panel_kids);
    let mut layer_kids = vec![dim, fill_frame(panel, Alignment::TOP_LEADING)];
    if c.p.seasons.0 {
        layer_kids.push(season_list(c));
    }
    fill_frame(
        Node::zstack(Alignment::TOP_LEADING, layer_kids).key("layer"),
        Alignment::TOP_LEADING,
    )
}

/// Desktop: the Mac's start-failed page (`PlayerScreen.swift:683`, `EmptyState`): the warning symbol in a 78 pt disc, the
/// core's header and text (`Failure::START`), the main button "Erneut versuchen" and the quiet accent button
/// "Schließen"; the X stays at the rail position.
fn failure_strip(c: &Ctx<'_>, f: &swiftly_vm::Failure) -> Node {
    let m = &c.m;
    let disc =
        c.g.node("warning", 44.0, color(colour::FONT_QUIET))
            .frame(Some(78.0), Some(78.0), Alignment::CENTER)
            .background(Node::rect(color(colour::AREA), 39.0), Alignment::CENTER);
    let text = Node::text(
        c.cx,
        f.text,
        &swiftly_text::TextStyle::from(swiftly_design::TextStyle {
            size: 15.0,
            weight: 400,
            ..base()
        }),
        color(colour::FONT_QUIET),
        Some(6),
        swiftly_text::Align::Center,
    )
    .frame(Some(262.0), None, Alignment::CENTER);
    let primary = Node::hstack(
        Align::Center,
        Some(8.0),
        vec![
            c.g.node("goforward", 15.0, color(colour::REASON)),
            label(c, f.primary, 15.0, 600, colour::REASON),
        ],
    )
    .padding(ins(0.0, 22.0, 0.0, 22.0))
    .frame(None, Some(44.0), Alignment::CENTER)
    .background(Node::rect(white(), 22.0), Alignment::CENTER)
    .key("retry")
    .on_tap(Action::from("retry"));
    let quiet = label(c, f.quiet, 15.0, 500, colour::MARK_ACCENT)
        .padding(ins(0.0, 12.0, 0.0, 12.0))
        .frame(None, Some(44.0), Alignment::CENTER)
        .key("fail-quiet")
        .on_tap(Action::from("fail-quiet"));
    let col = Node::vstack(
        Align::Center,
        Some(0.0),
        vec![
            disc.padding(ins(0.0, 0.0, 22.0, 0.0)),
            label(c, f.header, 22.0, 600, colour::FONT).padding(ins(0.0, 0.0, 7.0, 0.0)),
            text,
            primary.padding(ins(24.0, 0.0, 0.0, 0.0)),
            quiet.padding(ins(16.0, 0.0, 0.0, 0.0)),
        ],
    );
    let x = icon_button(c, "x", "fail-close", "fail-close", true).padding(ins(
        m.rail_top,
        0.0,
        0.0,
        m.edge - (m.button - m.glyph) / 2.0,
    ));
    let n = Node::zstack(
        Alignment::TOP_LEADING,
        vec![
            Node::rect(Color::new(0.0, 0.0, 0.0, 1.0), 0.0),
            fill_frame(col, Alignment::CENTER),
            fill_frame(x, Alignment::TOP_TRAILING),
        ],
    )
    .key("failure");
    fill_frame(n, Alignment::CENTER)
}

fn failure_view(c: &Ctx<'_>) -> Option<Node> {
    let f = c.p.t.failure.as_ref()?;
    if c.m.form == Form::Desktop {
        return Some(failure_strip(c, f));
    }
    let tv = c.tv;
    let big = if tv { 44.0 } else { 20.0 };
    let body = if tv { 28.0 } else { 15.0 };
    let btn = |key: &str, text: &str, primary: bool| {
        let (bg, fg) = if primary {
            (white(), colour::REASON)
        } else {
            (Color::new(1.0, 1.0, 1.0, 0.10), colour::FONT)
        };
        let n = label(c, text, body, 600, fg)
            .padding(ins(0.0, 22.0, 0.0, 22.0))
            .frame(None, Some(if tv { 76.0 } else { 44.0 }), Alignment::CENTER)
            .background(Node::rect(bg, 12.0), Alignment::CENTER)
            .key(key)
            .on_tap(Action::from(key));
        if tv {
            n.focusable(focus_id(key), Some(FocusLook::tile(18.0)))
        } else {
            n
        }
    };
    let text = Node::text(
        c.cx,
        f.text,
        &swiftly_text::TextStyle::from(swiftly_design::TextStyle {
            size: body,
            weight: 400,
            ..base()
        }),
        color(colour::FONT_QUIET),
        Some(4),
        swiftly_text::Align::Center,
    )
    .frame(
        Some(if tv { 760.0 } else { 300.0 }),
        None,
        Alignment::CENTER,
    );
    let col = Node::vstack(
        Align::Center,
        Some(14.0),
        vec![
            label(c, f.header, big, 700, colour::FONT),
            text,
            Node::hstack(
                Align::Center,
                Some(12.0),
                vec![
                    btn("retry", f.primary, true),
                    btn("fail-close", f.quiet, false),
                ],
            ),
        ],
    );
    let mut n = Node::zstack(
        Alignment::CENTER,
        vec![
            Node::rect(Color::new(0.0, 0.0, 0.0, 1.0), 0.0),
            fill_frame(col, Alignment::CENTER),
        ],
    )
    .key("failure");
    if tv {
        n = n.focus_scope(ScopeSpec::trap(focus_id("failure")));
    }
    Some(fill_frame(n, Alignment::CENTER))
}

/// Seconds per turn of the Mac loader (`Components.swift:Loader`, `.linear(duration: 0.7).repeatForever`).
const LOADER_TURN_SECONDS: f64 = 0.7;

/// The Mac loader: a 34 pt circle with a 3 pt stroke, a track ring at 18 % and an arc over 22 % of the circle that starts at
/// 3 o'clock and turns continuously, round caps. Both rings are vector `Paint::Arc`s on one square, so the arc turns around the
/// centre of the circle at every angle (a raster glyph centred on the bounding box of the arc turned around the wrong point).
fn loader(turn: f32) -> Node {
    let (size, stroke) = (34.0_f32, 3.0_f32);
    let accent = color(colour::MARK_ACCENT);
    let track = Color::new(accent.r, accent.g, accent.b, 0.18);
    // `Paint::Arc` counts turns from 12 o'clock; the Mac's trim starts at 3 o'clock.
    let from = (0.25 + turn).rem_euclid(1.0);
    let to = from + 0.22;
    let mut n = Node::rect(Color::CLEAR, 0.0).paint(Paint::Arc {
        color: track,
        width: stroke,
        from: 0.0,
        to: 1.0,
    });
    if to <= 1.0 {
        n = n.paint(Paint::Arc {
            color: accent,
            width: stroke,
            from,
            to,
        });
    } else {
        for (a, b) in [(from, 1.0), (0.0, to - 1.0)] {
            n = n.paint(Paint::Arc {
                color: accent,
                width: stroke,
                from: a,
                to: b,
            });
        }
    }
    // The stroke is centred on the circle's edge on the Mac, `Paint::Arc` draws it inside the square: grow the square by it.
    n.frame(Some(size + stroke), Some(size + stroke), Alignment::CENTER)
}

fn view(p: &Params, env: &Env, cx: &Cx, g: &Glyphs, surface: &dyn VideoSurface) -> Node {
    let m = metrics(env);
    let tv = m.form == Form::Tv;
    let c = Ctx {
        m,
        env,
        cx,
        g,
        p,
        tv,
        live: p.c.visible,
        surface,
    };
    let (w, h) = (env.size.w, env.size.h);
    let mut kids: Vec<Node> = vec![c.surface.node(w, h, p.fill, p.t.position).key("surface")];
    // Taps on the bare picture are classified by the screen (`PlayerScreen::touch_up`): the nodes above would
    // swallow them, and the Swift tap areas only exist to toggle, seek and pause.
    if tv {
        // The invisible home of focus while the controls are away.
        kids.push(
            Node::rect(Color::CLEAR, 0.0)
                .frame(Some(1.0), Some(1.0), Alignment::TOP_LEADING)
                .key("idle")
                .focusable(focus_id("idle"), None),
        );
    }
    if let Some(s) = subtitle(&c) {
        kids.push(s);
    }
    // The Mac: in `easeOut(0.18)`, out `easeInOut(0.34)`, a layer opening or closing `easeInOut(0.2)` (PlayerScreen.swift:341,362,427).
    let fade = if p.c.layer.is_some() {
        swiftly_ui::feel::player_layer()
    } else if p.c.visible {
        swiftly_ui::feel::controls_in()
    } else {
        swiftly_ui::feel::controls_out()
    };
    let mut ui_kids = vec![scrim(&c), header(&c)];
    if !tv {
        ui_kids.push(center(&c));
    }
    ui_kids.push(footer(&c));
    // Entering or leaving fullscreen: the controls settle into the new layout with easeInOut 0.5 (`PS:183-195`).
    let fs_ease = p.fs_epoch > 0 && c.m.form == Form::Desktop;
    let controls_key = if fs_ease {
        format!("controls{}", p.fs_epoch)
    } else {
        "controls".to_owned()
    };
    let controls = Node::zstack(Alignment::TOP_LEADING, ui_kids)
        .frame(Some(w), Some(h), Alignment::TOP_LEADING)
        .opacity(
            if p.c.visible && p.c.layer.is_none() {
                1.0
            } else {
                0.0
            },
            if fs_ease {
                swiftly_ui::feel::of(swiftly_motion::catalogue::Id::Fullscreen)
            } else {
                fade
            },
        )
        .key(controls_key.as_str());
    let controls = if fs_ease {
        controls.appear_from(1.0, 0.0)
    } else {
        controls
    };
    kids.push(controls);
    // Above the scrim (the picture's own dimming does not touch it), below the layers.
    kids.extend(tech_badge(&c));
    kids.push(pill(&c));
    if let Some(j) = jump_mark(&c) {
        kids.push(j);
    }
    if let Some(layer) = p.c.layer {
        kids.push(if layer == PlayerLayer::Episodes {
            episodes_layer(&c)
        } else {
            layer_panel(&c, layer)
        });
    }
    kids.extend(card(&c));
    kids.extend(group_event(&c));
    kids.extend(group_error(&c));
    kids.extend(p.menu_c.overlay(cx, env));
    kids.extend(small_hint(&c));
    if !p.t.picture_shown && p.t.failure.is_none() {
        let spin = if c.m.form == Form::Desktop {
            loader(p.turn)
        } else {
            c.g.spinner(p.spin, if tv { 72.0 } else { 36.0 }, white())
        };
        kids.push(
            Node::zstack(
                Alignment::CENTER,
                vec![
                    Node::rect(Color::new(0.0, 0.0, 0.0, 1.0), 0.0),
                    fill_frame(spin, Alignment::CENTER),
                ],
            )
            .key("loading"),
        );
    }
    if let Some(f) = failure_view(&c) {
        kids.push(f);
    }
    let _ = c.live;
    Node::zstack(Alignment::TOP_LEADING, kids).frame(Some(w), Some(h), Alignment::TOP_LEADING)
}

// ---- the screen --------------------------------------------------------------------------------------------------

/// A key on a keyboard (desktop shortcuts of the Mac player).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayerKey {
    /// Space: play or pause.
    Space,
    /// Left arrow: skip back.
    Left,
    /// Right arrow: skip forward.
    Right,
    /// Up arrow: volume +5 %.
    Up,
    /// Down arrow: volume -5 %.
    Down,
    /// Return: runs the skip button / card.
    Enter,
    /// The media key "next": the next episode, when there is one.
    NextEpisode,
    /// Esc.
    Escape,
    /// A letter (`m` mute, `f` fill, `g`/`h` subtitle delay, `j`/`k` audio delay).
    Char(char),
}

struct ScrubState {
    last: f64,
}

/// The player: view model, simulated engine, surface and the Ui over them.
pub struct PlayerScreen {
    ui: Ui<Params>,
    vm: PlayerVm<DynEngine, DynReporter>,
    engine: Arc<SimEngine>,
    /// The real engine and the subtitle look it was last given (`None` for the made-up one); the look follows the
    /// saved setting, checked a few times a second.
    sub_look: Option<(
        Arc<dyn PlaybackEngine>,
        Option<swiftly_playback::engine::SubtitleTextStyle>,
        f64,
    )>,
    /// A real engine and the frame surface it feeds; `None` for the made-up one.
    live: Option<(Arc<dyn LiveEngine>, Rc<crate::frame_surface::FrameSurface>)>,
    /// Frames the real engine delivered.
    video_frames: u64,
    /// Title and second line of the header.
    head: (String, String),
    env: Env,
    glyphs: Glyphs,
    surface: Arc<dyn VideoSurface>,
    log: Vec<String>,
    t0: f64,
    last_full: f64,
    last_half: f64,
    last_frame: f64,
    last_tap: Option<(f64, i32)>,
    chain: bool,
    scrub: Option<ScrubState>,
    volume: i32,
    /// The value before the last mute (`volumePrior`); 0 when there was none.
    volume_prior: i32,
    fill: bool,
    /// The Technikschild (technical badge) is on.
    tech: bool,
    /// What the file is, and the lines built from it (rebuilt every 2 s while the overlay shows).
    tech_facts: Option<crate::player_host::TechFacts>,
    tech_rows: (f64, Vec<(String, String)>),
    /// The handover menu is open.
    menu: bool,
    /// The film plays in the small window (set by the host).
    small: bool,
    /// The season picker list is open; the chosen season.
    seasons_open: bool,
    season: usize,
    /// Where the layer gets its seasons and episodes, and what it has fetched so far.
    ep_source: Option<Arc<dyn EpisodeSource>>,
    ep_seasons: Vec<SeasonRow>,
    ep_cards: Vec<EpisodeCardData>,
    /// The card a context menu is open on, and the writes its picks sent (`PlayerEpisodeStrip.swift:56`).
    ep_menu: Option<usize>,
    ep_writers: Vec<swiftly_vm::DetailVm<crate::net::AppTransport>>,
    ep_stills: Vec<Option<player_card::CardStill>>,
    ep_asked: bool,
    ep_wait_seasons: Option<SeasonsWait>,
    ep_wait_cards: Option<CardsWait>,
    /// The strip was put on the running episode for this opening of the layer.
    strip_placed: bool,
    closed: bool,
    spin: u8,
    turn: f32,
    sections: Vec<Segment>,
    chapters: Vec<Chapter>,
    trick: Option<crate::trick_preview::TrickPreview>,
    cx: Cx,
    seen_visible: bool,
    down: Option<(f32, f32)>,
    /// A drag of the bare background asks the host to move the window (see `take_window_drag`).
    window_drag: bool,
    moved: bool,
    /// A real engine drives the clock; the made-up one stays still.
    external_clock: bool,
    /// The window is in real fullscreen (set by the host).
    fullscreen: bool,
    /// The host should toggle fullscreen (read once).
    fs_request: bool,
    /// The pointer is on the speaker button or the compartment.
    vol_hover: bool,
    /// The volume slider is dragged.
    vol_drag: bool,
    /// The compartment stays out until then (keys and wheel, seconds).
    vol_until: f64,
    /// A line the shortcuts announce and the time it goes (`PlayerScreen.notify`).
    notice: Option<(String, f64)>,
    /// The compartment is out (computed per frame).
    vol_open: bool,
    /// Last pointer position in window points (desktop).
    pointer: Option<(f32, f32)>,
    /// Position under the pointer on the scrubber, seconds.
    hover_pos: Option<f64>,
    /// Time of the last bare click (seconds): the second within the interval is a double-click.
    click_at: Option<f64>,
    /// "Endet um": local seconds of the day at the moment it was set, and that moment (seconds).
    end_base: Option<(f64, f64)>,
    /// What the core's player reads from settings (skip widths, auto skip, next episode, quality).
    prefs: PlayerPrefs,
    /// The latest frame time in seconds.
    cur_s: f64,
    /// The anchored menu (handover, season list).
    menu_c: MenuController,
    /// The next-episode card: motion, what it showed last (it keeps it while leaving), a pointer going down on it.
    card_motion: CardMotion,
    card_data: Option<(String, f64, i64, String)>,
    card_still: Option<player_card::CardStill>,
    /// The poster for the system's media widgets, and whether a next episode is queued.
    poster: Option<crate::media_keys::Poster>,
    has_next: bool,
    /// A series episode: the episodes layer exists (`hasEpisodes`).
    has_episodes: bool,
    /// The picture is re-encoded: the header says so (`plan.isLossless`).
    transcode: bool,
    card_drag: Option<(f32, f32)>,
    /// When the back and forward buttons were last used (seconds), for the bounce.
    bounce_at: (f64, f64),
    /// Counts the fullscreen changes.
    fs_epoch: u32,
    /// Where the volume is kept between sessions (`playerLautstaerke`, `playerLautstaerkeDavor`).
    store: Option<Arc<JsonFileStore>>,
    /// The host that plans a title for a switch (next episode, quality, subtitle on a transcode); `None`: effects are logged.
    planner: Option<Arc<dyn Planner>>,
    /// The plan of a switch on its way.
    switch: SwitchState,
    /// A rating or Discord prompt the core asked for; the host shows it once the player is closed.
    nudge: Option<Nudge>,
    /// The file plays from the device (`spec.downloaded`).
    downloaded: bool,
    /// The title's item id (for the stream that takes over).
    item_id: String,
    /// The downloaded file did not open: the position the stream takes over at (read once by the host).
    stream_fallback: Option<f64>,
    /// The next episode's code for the card (`episode.episodeCode`).
    next_code: Option<String>,
    /// The Jellyfin account's own next-episode wish.
    account_next: Option<bool>,
    /// The season the running episode is in.
    season_id: Option<String>,
    /// The running episode's code, "S1 · F3".
    episode_code: Option<String>,
    /// Watching together, the other devices and the remote control (the live app only).
    together: Option<Arc<crate::together::Hub>>,
    /// What the hub last said about the group and the devices.
    view: crate::together::View,
    /// This player sits in the group: its buttons are requests to the group.
    shared: bool,
    /// The demo screen offers its one made-up TV.
    demo_targets: bool,
    /// The error of the group that is on the strip: its number and when it came up (seconds).
    error_seen: Option<(u64, f64)>,
    /// The strip was tapped away.
    error_gone: bool,
    /// A hand-over is on its way; whether the film ran when it started.
    handover_ran: Option<bool>,
    /// The title and version that play here, for a hand-over.
    ids: Option<(String, Option<String>)>,
    /// The device that took the title over; the player leaves for it.
    taken_to: Option<String>,
    /// The last picture of the video, grabbed when the title was handed over (the exit card flies with it).
    exit_still: Option<crate::together_ui::ExitStill>,
    /// When the group was last told about this player's buffering (seconds).
    last_group_tick: f64,
}

fn parts(
    vm: &PlayerVm<DynEngine, DynReporter>,
    head: &(String, String),
    chapters: &[Chapter],
    sections: &[Segment],
    st: (u8, u64, bool, bool, i32, bool, bool, bool, f32),
) -> Params {
    Params {
        preview_img: None,
        t: vm.transport(),
        c: vm.controls(),
        tracks: vm.tracks(),
        offer: vm.offer(),
        seasons: (false, 0),
        season_names: Vec::new(),
        cards: Vec::new(),
        current_card: None,
        card_imgs: Vec::new(),
        strip_x: 0.0,
        fullscreen: false,
        vol_open: false,
        hover_pos: None,
        ends: None,
        menu_c: MenuController::new(),
        card: CardLook::default(),
        card_data: None,
        card_img: None,
        bounce: (1.0, 1.0),
        fs_epoch: 0,
        group: None,
        participants: Vec::new(),
        event: None,
        group_error: None,
        targets: Vec::new(),
        title: head.0.clone(),
        meta: head.1.clone(),
        episodes: true,
        transcode: false,
        chapters: chapters.iter().map(|c| (c.from, c.name.clone())).collect(),
        marks: sections.iter().flat_map(|s| [s.from, s.until]).collect(),
        spin: st.0,
        turn: st.8,
        focus: st.1,
        fill: st.2,
        muted: st.3,
        volume: st.4,
        tech: st.5,
        tech_head: None,
        tech_reason: None,
        tech_rows: Vec::new(),
        sub_style: None,
        menu: st.6,
        small: st.7,
    }
}

/// The settings the core's player decides by (`CorePlaybackBackend.prefs`): the skip widths, "skip intro and outro
/// automatically" and "next episode automatically" (own choice, else on). Quality stays as it is.
pub fn prefs_from_store(
    store: &JsonFileStore,
    base: &PlayerPrefs,
    account_next: Option<bool>,
) -> PlayerPrefs {
    let int = |k: &str, d: i64| match store.get(k) {
        Some(Value::Int(n)) if n > 0 => n,
        _ => d,
    };
    let flag = |k: &str| match store.get(k) {
        Some(Value::Bool(b)) => Some(b),
        _ => None,
    };
    PlayerPrefs {
        back_seconds: int("zurueckSek", 10),
        forward_seconds: int("vorSek", 30),
        auto_skip: flag("introAbspannAuto").unwrap_or(false),
        next_automatic: swiftly_playback::offering_layer::Advance::applies(
            flag("naechsteAuto"),
            account_next,
        ),
        ..base.clone()
    }
}

/// Setting `endzeitImPlayer`: "Endet um" instead of the remaining time.
pub fn end_time_from_store(store: &JsonFileStore) -> bool {
    matches!(store.get("endzeitImPlayer"), Some(Value::Bool(true)))
}

impl PlayerScreen {
    /// What a screen reader gets for this screen: the nodes of the current picture.
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.ui.a11y_nodes()
    }

    /// A player over the made-up episode, started at `now` ms.
    pub fn new(env: Env, cx: Cx, scenario: PlayerScenario, now: f64) -> PlayerScreen {
        PlayerScreen::with_surface(env, cx, scenario, now, Arc::new(TestPattern))
    }

    /// Like [`PlayerScreen::new`] with another picture source under the controls (a real video).
    pub fn with_surface(
        env: Env,
        cx: Cx,
        scenario: PlayerScenario,
        now: f64,
        surface: Arc<dyn VideoSurface>,
    ) -> PlayerScreen {
        let engine = Arc::new(SimEngine::default());
        engine.with(|s| s.rate = 1.0);
        let s = now / 1000.0;
        let vm = PlayerVm::new(
            Arc::new(DynEngine(Arc::clone(&engine) as Arc<dyn PlaybackEngine>)),
            Arc::new(DynReporter(Arc::new(NoReports))),
            Arc::new(words()),
            PlayerPrefs::default(),
            spec(),
            s,
        );
        let sections = vec![
            Segment::new(Art::IntroSegment, 20.0, 80.0),
            Segment::new(Art::Credits, DURATION - 60.0, DURATION),
        ];
        let chapters = vec![
            Chapter::new("Anfang", 0.0),
            Chapter::new("Der Hafen", 540.0),
            Chapter::new("Die Nachricht", 1260.0),
            Chapter::new("Nordlicht", 2040.0),
        ];
        vm.set_sections(sections.clone());
        vm.set_chapters(chapters.clone());
        vm.start(s);
        match scenario {
            PlayerScenario::Playing => {
                vm.engine_event(EngineEvent::LoadFinished { attempt: 1 }, s);
                vm.engine_event(EngineEvent::Duration(DURATION), s);
                vm.engine_event(EngineEvent::State(EngineState::Playing), s);
                vm.engine_event(EngineEvent::FirstFrame, s);
                engine.with(|e| e.playing = true);
            }
            PlayerScenario::Failed => {
                vm.engine_event(
                    EngineEvent::LoadFailed {
                        attempt: 1,
                        message: "Zeitüberschreitung".into(),
                        kind: None,
                    },
                    s,
                );
            }
        }
        let glyphs = Glyphs::new(&cx, env.scale);
        let head = ("Nordlicht".to_owned(), "S1 · F3".to_owned());
        let p = parts(
            &vm,
            &head,
            &chapters,
            &sections,
            (0, 0, false, false, 100, false, false, false, 0.0),
        );
        let (g2, s2) = (glyphs.clone(), Arc::clone(&surface));
        let cx_keep = cx.clone();
        let ui = Ui::new(
            move |p: &Params, env: &Env, cx: &Cx| view(p, env, cx, &g2, s2.as_ref()),
            p,
            env,
            cx,
        );
        PlayerScreen {
            ui,
            vm,
            engine,
            live: None,
            video_frames: 0,
            head,
            env,
            glyphs,
            surface,
            log: Vec::new(),
            t0: s,
            last_full: s,
            last_half: s,
            last_frame: s,
            last_tap: None,
            chain: false,
            scrub: None,
            volume: 100,
            volume_prior: 0,
            fill: false,
            tech: false,
            tech_facts: Some(demo_tech()),
            tech_rows: (f64::NEG_INFINITY, Vec::new()),
            menu: false,
            small: false,
            seasons_open: false,
            season: 0,
            ep_source: Some(Arc::new(DemoEpisodes)),
            ep_seasons: Vec::new(),
            ep_cards: Vec::new(),
            ep_menu: None,
            ep_writers: Vec::new(),
            ep_stills: Vec::new(),
            ep_asked: false,
            ep_wait_seasons: None,
            ep_wait_cards: None,
            strip_placed: false,
            closed: false,
            spin: 0,
            turn: 0.0,
            sections,
            chapters,
            trick: None,
            cx: cx_keep,
            seen_visible: false,
            down: None,
            window_drag: false,
            moved: false,
            external_clock: false,
            fullscreen: false,
            fs_request: false,
            vol_hover: false,
            vol_drag: false,
            vol_until: 0.0,
            notice: None,
            vol_open: false,
            pointer: None,
            hover_pos: None,
            click_at: None,
            end_base: None,
            prefs: PlayerPrefs::default(),
            cur_s: s,
            menu_c: MenuController::new(),
            card_motion: CardMotion::default(),
            card_data: None,
            card_still: None,
            poster: None,
            has_next: true,
            has_episodes: true,
            transcode: false,
            card_drag: None,
            bounce_at: (-10.0, -10.0),
            fs_epoch: 0,
            store: None,
            sub_look: None,
            planner: None,
            switch: SwitchState::Idle,
            nudge: None,
            downloaded: false,
            item_id: String::new(),
            stream_fallback: None,
            next_code: None,
            account_next: None,
            season_id: None,
            episode_code: None,
            together: None,
            view: crate::together::View::default(),
            shared: false,
            demo_targets: true,
            error_seen: None,
            error_gone: false,
            handover_ran: None,
            ids: None,
            taken_to: None,
            exit_still: None,
            last_group_tick: 0.0,
        }
    }

    /// A player over a real title: `engine` plays, `reporter` tells the server, `frames` shows the picture. The
    /// header, chapters and skip sections come from the spec and the lists given.
    #[allow(clippy::too_many_arguments)]
    pub fn live(
        env: Env,
        cx: Cx,
        now: f64,
        spec: PlayerSpec,
        head: (String, String),
        engine: Arc<dyn PlaybackEngine>,
        feed: Arc<dyn LiveEngine>,
        reporter: Arc<dyn Reporter>,
        setup: impl FnOnce(&PlayerVm<DynEngine, DynReporter>),
    ) -> PlayerScreen {
        let frames = Rc::new(crate::frame_surface::FrameSurface::new(cx.clone()));
        #[allow(clippy::arc_with_non_send_sync)]
        // the UI is single-threaded; the seam only asks for Arc
        let surface: Arc<dyn VideoSurface> = Arc::new(RcSurface(Rc::clone(&frames)));
        let mut p = PlayerScreen::with_surface(env, cx, PlayerScenario::Playing, now, surface);
        let s = now / 1000.0;
        p.demo_targets = false;
        p.ids = Some((spec.item_id.clone(), spec.plan.media_source_id.clone()));
        p.has_next = spec.next.is_some();
        p.tech_facts = None;
        p.downloaded = spec.downloaded;
        p.item_id = spec.item_id.clone();
        p.set_title_kind(
            spec.series_id.is_some(),
            spec.plan.method == PlayMethod::Transcode,
        );
        p.sub_look = Some((Arc::clone(&engine), None, f64::NEG_INFINITY));
        let vm = PlayerVm::new(
            Arc::new(DynEngine(engine)),
            Arc::new(DynReporter(reporter)),
            Arc::new(words()),
            PlayerPrefs::default(),
            spec,
            s,
        );
        setup(&vm);
        vm.start(s);
        p.vm = vm;
        p.head = head;
        p.live = Some((feed, frames));
        p.cx.video.borrow_mut().begin();
        p.external_clock = true;
        p.sections.clear();
        p.chapters.clear();
        p.sync();
        p
    }

    /// Frames the real engine delivered so far.
    pub fn video_frames(&self) -> u64 {
        self.video_frames
    }

    /// What the newest CPU-path video frame looks like (`None` on the GPU path or before the first frame).
    pub fn picture_stats(&self) -> Option<crate::frame_surface::PictureStats> {
        self.live.as_ref().and_then(|(_, f)| f.last_stats())
    }

    /// How to fetch the picture of the next episode for the card (the client builds the closure, like the trickplay
    /// source): raw image bytes, called once on a worker thread.
    pub fn set_card_still(&mut self, source: player_card::StillSource) {
        self.card_still = Some(player_card::CardStill::new(source));
    }

    /// How to fetch the poster of the playing title for the system's media widgets (raw image bytes; blocks).
    pub fn set_poster(
        &mut self,
        source: player_card::StillSource,
        dir: std::path::PathBuf,
        name: &str,
    ) {
        self.poster = Some(crate::media_keys::Poster::new(source, dir, name));
    }

    /// What the system's media widgets show now: title card, state, position. A film that ended stays open with its
    /// controls, so it shows as paused at the end (like the Mac's now-playing); `None` while nothing plays (before the
    /// first picture, a failed start, closed) so the card goes away and the system reads "Stopped".
    pub fn now_playing(&self) -> Option<crate::media_keys::NowPlaying> {
        if self.closed {
            return None;
        }
        let t = self.vm.transport();
        let playing = crate::media_keys::playing_in(t.phase)?;
        Some(crate::media_keys::NowPlaying {
            meta: crate::media_keys::Metadata {
                item_id: self.vm.spec().item_id.clone(),
                // The Mac's `report`: the title's own name, the series as the album, the episode code as the artist.
                title: self.vm.spec().title.clone(),
                album: (self.has_episodes && !self.head.0.is_empty()).then(|| self.head.0.clone()),
                artist: self
                    .has_episodes
                    .then(|| self.episode_code.clone())
                    .flatten(),
                duration_s: (t.duration > 0.0).then_some(t.duration),
                cover_url: self.poster.as_ref().and_then(|p| p.url()),
            },
            playing,
            position_s: if t.phase == Phase::Ended && t.duration > 0.0 {
                t.duration
            } else {
                t.position.max(0.0)
            },
            rate: f64::from(t.tempo),
            has_next: self.has_next,
        })
    }

    /// The trickplay offer of a real title and how to fetch its sheets (preview images under the handle).
    pub fn set_trickplay(
        &mut self,
        tp: Option<swiftly_playback::trickplay::Trickplay>,
        source: crate::trick_preview::SheetSource,
    ) {
        self.vm.set_trickplay(tp);
        self.trick = tp.map(|t| crate::trick_preview::TrickPreview::new(t, source));
    }

    /// Chapters and skip sections of a real title (the bar marks).
    pub fn set_marks(&mut self, chapters: Vec<Chapter>, sections: Vec<Segment>) {
        self.vm.set_chapters(chapters.clone());
        self.vm.set_sections(sections.clone());
        self.chapters = chapters;
        self.sections = sections;
    }

    /// A real engine delivers the clock: the made-up clock stops advancing. Events go in through [`PlayerScreen::engine_event`].
    pub fn use_external_clock(&mut self) {
        self.external_clock = true;
    }

    /// Forwards an event of a real engine to the view model.
    pub fn engine_event(&mut self, event: EngineEvent, now: f64) {
        self.vm.engine_event(event, now / 1000.0);
    }

    /// The Technikschild on or off (the settings layer's column does the same by tap).
    pub fn set_tech(&mut self, on: bool) {
        self.tech = on;
        self.sync();
    }

    /// The handover menu open or closed (desktop).
    pub fn set_handover(&mut self, on: bool) {
        if on {
            self.open_handover();
        } else {
            self.menu_c.close();
        }
        self.sync();
    }

    /// The film plays in the small window (host report); the big picture shows the hint.
    pub fn set_small_window(&mut self, on: bool) {
        self.small = on;
        self.sync();
    }

    /// The view model (tests).
    pub fn vm(&self) -> &PlayerVm<DynEngine, DynReporter> {
        &self.vm
    }

    /// What the UI asked of the host, as readable lines.
    pub fn log(&self) -> &[String] {
        &self.log
    }

    /// The engine commands (tests).
    pub fn engine_calls(&self) -> Vec<String> {
        self.engine.calls()
    }

    /// The player asked to be closed.
    pub fn is_closed(&self) -> bool {
        self.closed
    }

    /// The services (atlas pages) the renderers read.
    pub fn cx(&self) -> &Cx {
        self.ui.cx()
    }

    /// Which control has focus on tv.
    pub fn focused(&mut self) -> Option<swiftly_ui::FocusId> {
        self.ui.focused()
    }

    /// A new window size or scale.
    pub fn set_env(&mut self, env: Env) {
        self.env = env;
        self.ui.set_env(env);
    }

    /// Renders a list with the software renderer.
    pub fn render_software(&self, list: &DrawList) -> RgbaImage {
        self.ui.render(list, Color::new(0.0, 0.0, 0.0, 1.0))
    }

    /// Moves the made-up clock (tests and the demo).
    pub fn jump_clock(&mut self, seconds: f64, now: f64) {
        self.engine.with(|e| e.position = seconds);
        let s = now / 1000.0;
        self.vm.engine_event(
            EngineEvent::Clock {
                position: seconds,
                source_time: seconds,
            },
            s,
        );
        self.vm.tick(s);
        self.last_full = s;
    }

    fn pump(&mut self, s: f64) {
        let (change, sought, pos) = self
            .engine
            .with(|e| (e.changed.take(), std::mem::take(&mut e.sought), e.position));
        match change {
            Some(true) => self
                .vm
                .engine_event(EngineEvent::State(EngineState::Playing), s),
            Some(false) => self
                .vm
                .engine_event(EngineEvent::State(EngineState::Paused), s),
            None => {}
        }
        if sought {
            self.vm.engine_event(
                EngineEvent::Clock {
                    position: pos,
                    source_time: pos,
                },
                s,
            );
        }
        let calls = PlayerCalls::fold(self.vm.take_effects());
        self.run_calls(calls, s);
    }

    /// Runs what the core asked for. Each effect arrives once (`take_effects` empties the queue) and is run here.
    fn run_calls(&mut self, c: PlayerCalls, s: f64) {
        if c.is_empty() {
            return;
        }
        let planner = self.planner.clone();
        if c.close {
            self.closed = true;
            if let Some(hub) = &self.together {
                hub.player_open(false);
                if self.shared {
                    hub.player_detached();
                    self.shared = false;
                }
            }
        }
        if let Some(n) = c.nudge {
            self.nudge = Some(n);
        }
        if let Some((subtitle, reason)) = c.hand_over {
            // libmpv shows every track itself: there is no second engine to hand over to.
            self.log.push(format!("handover:{subtitle}:{reason}"));
        }
        if let Some((position, paused, reason)) = c.stream_rebuilt {
            self.log
                .push(format!("rebuilt:{position}:{paused}:{reason}"));
        }
        if let Some(q) = c.quality {
            match &planner {
                Some(p) => p.save_quality(q),
                None => self.log.push(format!("effect QualityChosen {q:?}")),
            }
        }
        if c.forget_prepared
            && let Some(p) = &planner
        {
            p.forget_prepared();
        }
        if let Some(id) = c.prepare_next
            && let Some(p) = &planner
        {
            p.prepare_next(self.ask(id, 0.0, false, None, None));
        }
        if let Some(sw) = c.switch_to {
            match planner {
                Some(p) if !self.switch.busy() => {
                    let ask = self.ask(sw.id, sw.since, sw.from_card, c.reload_subtitle, c.quality);
                    let pending = p.plan(ask.clone());
                    self.switch = SwitchState::Planning(ask, pending);
                }
                Some(_) => {}
                None => self.log.push(format!(
                    "effect switch {} from_card={} since={} subtitle={:?}",
                    sw.id, sw.from_card, sw.since, c.reload_subtitle
                )),
            }
        }
        let _ = s;
    }

    /// The plan request for `id` with the settings of this moment; the same id is a reload and keeps the version.
    fn ask(
        &self,
        id: String,
        since: f64,
        from_card: bool,
        subtitle: Option<i64>,
        chosen: Option<Quality>,
    ) -> PlanAsk {
        let spec = self.vm.spec();
        let reload = spec.item_id == id;
        let quality = chosen
            .or_else(|| self.planner.as_ref().map(|p| p.quality()))
            .unwrap_or(Quality {
                direct_play: true,
                limit: 0,
            });
        PlanAsk {
            source_id: reload.then(|| spec.plan.media_source_id.clone()).flatten(),
            id,
            since,
            from_card,
            reload,
            subtitle,
            quality,
        }
    }

    /// The answer of a plan: load the title at the position, or show why it cannot play.
    fn poll_switch(&mut self, s: f64) {
        let Some((ask, answer)) = self.switch.step() else {
            return;
        };
        match answer {
            Ok(sw) => {
                let mut spec = sw.spec;
                spec.start_at = ask.since;
                if let Some(sub) = ask.subtitle {
                    spec.subtitle_index = sub;
                }
                self.has_next = spec.next.is_some();
                if let Some(x) = sw.extra {
                    self.set_title_facts(x.next_code, x.account_next);
                    self.set_tech_facts(x.tech);
                    self.set_season_id(x.season_id);
                    self.episode_code = x.code;
                    self.vm.set_original_language(x.original_language);
                }
                self.ep_cards.clear();
                self.ep_stills.clear();
                self.set_title_kind(
                    spec.series_id.is_some(),
                    spec.plan.method == PlayMethod::Transcode,
                );
                self.head = sw.head;
                self.vm.load_title(spec, s);
                self.set_marks(sw.chapters, sw.sections);
                match sw.trickplay {
                    Some((tp, fetch)) => self.set_trickplay(Some(tp), fetch),
                    None => {
                        self.vm.set_trickplay(None);
                        self.trick = None;
                    }
                }
                self.card_still = sw.still.map(player_card::CardStill::new);
                self.card_data = None;
                if let Some((source, dir, name)) = sw.poster {
                    self.set_poster(source, dir, &name);
                }
            }
            Err(message) => {
                self.log.push(format!("switch failed: {message}"));
                self.vm.engine_event(
                    EngineEvent::LoadFailed {
                        attempt: 1,
                        message,
                        kind: None,
                    },
                    s,
                );
            }
        }
    }

    /// The host that plans a title for a switch. Also takes the quality of the settings into the menu.
    pub fn set_planner(&mut self, planner: Arc<dyn Planner>) {
        let q = planner.quality();
        self.prefs.direct_play = q.direct_play;
        self.prefs.bitrate_limit = q.limit;
        self.vm.set_prefs(self.prefs.clone());
        self.planner = Some(planner);
    }

    /// Whether a plan for a switch is on its way (tests).
    pub fn switching(&self) -> bool {
        self.switch.busy()
    }

    /// The plan request in flight (tests).
    pub fn switch_ask(&self) -> Option<&PlanAsk> {
        self.switch.ask()
    }

    /// The prompt the core asked for, once (the host shows it after the close).
    pub fn take_nudge(&mut self) -> Option<Nudge> {
        self.nudge.take()
    }

    /// Shows a line over the picture for a few seconds (a link that arrived while the player is open).
    pub fn announce(&mut self, text: String, now: f64) {
        self.notice = Some((text, now / 1000.0 + NOTICE_SECONDS));
    }

    /// The line a shortcut announced and that is still showing (G/H/J/K).
    pub fn notice(&self) -> Option<&str> {
        self.notice.as_ref().map(|(t, _)| t.as_str())
    }

    /// Sends an intent as the UI would (tests, host shortcuts).
    pub fn send_intent(&mut self, intent: PlayerIntent, now: f64) {
        self.send(intent, now);
    }

    fn send(&mut self, intent: PlayerIntent, now: f64) {
        let s = now / 1000.0;
        match intent {
            PlayerIntent::Back => self.bounce_at.0 = s,
            PlayerIntent::Forward => self.bounce_at.1 = s,
            _ => {}
        }
        crate::script::trace(&format!("intent {intent:?}"));
        self.vm.send(intent, s);
        crate::script::trace("engine command issued");
        self.pump(s);
    }

    fn advance(&mut self, now: f64) {
        let s = (now / 1000.0).max(self.t0);
        self.cur_s = s;
        self.vol_open = self.desk() && (self.vol_hover || self.vol_drag || s < self.vol_until);
        if let Some((eng, frames)) = &self.live {
            for ev in eng.events() {
                if let EngineEvent::State(state) = &ev {
                    crate::script::trace(&format!("engine report {state:?}"));
                }
                self.vm.engine_event(ev, s);
            }
            let gpu = self.cx.video.borrow().gpu;
            if let Some(g) = gpu {
                // The host draws the picture under the UI: ask for the source resolution, hand the frame over by swap.
                let (bw, bh) = gpu_frame_box(g.window, eng.source_size(), self.fill, g.max_side);
                let mut h = self.cx.video.borrow_mut();
                h.alive = true;
                let mut frame = VideoFrame {
                    w: 0,
                    h: 0,
                    rgba: std::mem::take(&mut h.spare),
                };
                drop(h);
                let got = eng.frame_swap(bw, bh, &mut frame);
                let mut h = self.cx.video.borrow_mut();
                if got {
                    h.spare = std::mem::take(&mut h.pending)
                        .map(|f| f.rgba)
                        .unwrap_or_default();
                    h.pending = Some(frame);
                    h.shown = true;
                    self.video_frames += 1;
                } else {
                    h.spare = frame.rgba;
                }
            } else {
                let counter = &mut self.video_frames;
                eng.frame(1280, 720, &mut |w, h, rgba| {
                    frames.push(w, h, rgba);
                    *counter += 1;
                });
            }
        }
        let dt = (s - self.last_frame).clamp(0.0, 1.0);
        self.last_frame = s;
        let (playing, rate) = self.engine.with(|e| (e.playing, e.rate));
        if playing && !self.external_clock {
            let pos = self.engine.with(|e| {
                e.position = (e.position + dt * f64::from(rate)).min(DURATION);
                e.position
            });
            self.vm.engine_event(
                EngineEvent::Clock {
                    position: pos,
                    source_time: pos,
                },
                s,
            );
        }
        if s - self.last_half >= 0.5 {
            self.last_half = s - (s - self.last_half) % 0.5;
        }
        if s - self.last_full >= 0.5 {
            self.last_full = s;
            self.vm.tick(s);
        } else if s - self.last_full >= 0.25 && s - self.last_half >= 0.25 {
            self.vm.display_tick(s);
            self.last_half = s + 1e9;
        }
        self.spin = ((s * 12.5) as u64 % 12) as u8;
        self.turn = (s / LOADER_TURN_SECONDS).fract() as f32;
        self.poll_switch(s);
        self.together_tick(s);
        self.pump(s);
    }

    fn sync(&mut self) {
        let focus = self.ui.focused().map_or(0, |f| f.0);
        self.menu = self.menu_c.is_open();
        let p = parts(
            &self.vm,
            &self.head,
            &self.chapters,
            &self.sections,
            (
                self.spin,
                focus,
                self.fill,
                self.volume == 0,
                self.volume,
                self.tech,
                self.menu,
                self.small,
                self.turn,
            ),
        );
        let mut p = p;
        crate::script::trace_flag("shown playing", matches!(p.t.phase, Phase::Playing));
        if self
            .notice
            .as_ref()
            .is_some_and(|(_, until)| self.cur_s >= *until)
        {
            self.notice = None;
        }
        if let Some((text, _)) = &self.notice {
            p.t.hint = Some(text.clone());
        }
        p.seasons = (self.seasons_open, self.season);
        if self.tech {
            // Every 2 s from what plays now (`PS:450-458`: the task re-reads the values and the playing tracks).
            if self.cur_s - self.tech_rows.0 >= 2.0 {
                let tracks = self.vm.tracks();
                let playing = |rows: &[swiftly_vm::TrackRow]| {
                    rows.iter().find(|r| r.selected).map(|r| r.index)
                };
                let duration = self.vm.transport().duration;
                if let Some(f) = &self.tech_facts {
                    self.tech_rows = (
                        self.cur_s,
                        f.rows(
                            playing(&tracks.audio),
                            playing(&tracks.subtitles),
                            duration,
                            &words(),
                        ),
                    );
                }
            }
            p.tech_head = self
                .tech_facts
                .as_ref()
                .map(|f| (f.delivery.clone(), f.good));
            p.tech_reason = self.tech_facts.as_ref().and_then(|f| f.reason.clone());
            p.tech_rows = self.tech_rows.1.clone();
        }
        p.sub_style = Some(self.stored_subtitle_style());
        p.season_names = self.ep_seasons.iter().map(|r| r.name.clone()).collect();
        p.cards = self.ep_cards.clone();
        p.current_card = self.current_card();
        let reduce_still = self.env.reduce_motion;
        p.card_imgs = if self.vm.controls().layer == Some(PlayerLayer::Episodes) {
            self.ep_stills
                .iter_mut()
                .map(|st| {
                    st.as_mut()
                        .and_then(|st| st.poll(&self.cx, self.cur_s, reduce_still))
                })
                .collect()
        } else {
            Vec::new()
        };
        p.group = self.view.group.clone().filter(|_| self.shared);
        p.participants = self.view.participants.clone();
        p.event = self.view.event.clone().filter(|_| self.shared);
        p.group_error = self.group_error_text();
        p.targets = self.p_targets();
        if let Some(t) = &mut self.trick {
            // Scrubbing shows the tile of the scrub position, hovering the tile under the pointer.
            let tile = if p.c.scrubbing {
                p.c.preview
            } else {
                self.hover_pos.and_then(|at| t.offer().tile(at))
            };
            p.preview_img = t.image(&self.cx, tile);
        }
        let reduce = self.env.reduce_motion;
        if let OfferView::Card {
            title,
            share,
            seconds_left,
        } = self.vm.offer().view
        {
            let code = self.next_code.clone().unwrap_or_else(|| title.clone());
            self.card_data = Some((title, share, seconds_left, code));
            let desk = self.desk();
            self.card_motion.update(desk, self.cur_s, reduce);
        } else {
            // Zoomed by a click that started the next episode: the card stays over the switch (as on the Mac).
            let hold = self.desk() && self.card_motion.zoomed() && self.switch.busy();
            self.card_motion.update(hold, self.cur_s, reduce);
        }
        p.card = self.card_motion.look(self.cur_s, reduce);
        p.card_data = if p.card.shown {
            self.card_data.clone()
        } else {
            None
        };
        p.card_img = if p.card.shown {
            self.card_still
                .as_mut()
                .and_then(|st| st.poll(&self.cx, self.cur_s, reduce))
        } else {
            None
        };
        p.bounce = (
            player_card::bounce(self.cur_s - self.bounce_at.0),
            player_card::bounce(self.cur_s - self.bounce_at.1),
        );
        p.menu_c = self.menu_c.clone();
        p.fs_epoch = self.fs_epoch;
        p.strip_x = self.ui.scroll_offsets().first().copied().unwrap_or(0.0) as f32;
        p.episodes = self.has_episodes;
        p.transcode = self.transcode;
        p.fullscreen = self.fullscreen;
        p.vol_open = self.vol_open;
        p.hover_pos = self.hover_pos;
        p.ends = self.end_base.map(|(day, at)| {
            let t = self.vm.transport();
            let rest = (t.duration - t.position).max(0.0) / f64::from(t.tempo.max(0.1));
            let secs = (day + (self.cur_s - at) + rest).rem_euclid(86_400.0);
            format!(
                "{:02}:{:02}",
                (secs / 3600.0) as u32,
                (secs % 3600.0 / 60.0) as u32
            )
        });
        self.ui.set_parts(p);
    }

    /// The running episode among the cards.
    fn current_card(&self) -> Option<usize> {
        let id = &self.vm.spec().item_id;
        self.ep_cards.iter().position(|c| &c.id == id)
    }

    /// Asks the source for the episodes of the chosen season; the cards stay until the answer comes.
    fn load_cards(&mut self) {
        let (Some(src), Some(series), Some(season)) = (
            self.ep_source.clone(),
            self.vm.spec().series_id.clone(),
            self.ep_seasons.get(self.season).map(|r| r.id.clone()),
        ) else {
            return;
        };
        self.ep_wait_cards = Some((self.season, src.episodes(&series, &season)));
    }

    /// Opens the layer's data once per opening and takes the answers (`EpisodesLayer.load`, `episodesLoad`).
    fn episodes_tick(&mut self) {
        let open = self.vm.controls().layer == Some(PlayerLayer::Episodes);
        if !open {
            self.ep_asked = false;
            return;
        }
        if !self.ep_asked {
            self.ep_asked = true;
            if let (Some(src), Some(series)) =
                (self.ep_source.clone(), self.vm.spec().series_id.clone())
            {
                self.ep_wait_seasons = Some(src.seasons(&series, self.season_id.as_deref()));
            }
        }
        if let Some(w) = &self.ep_wait_seasons {
            match w.0.try_recv() {
                Ok(found) => {
                    self.ep_wait_seasons = None;
                    if let Some((rows, chosen)) = found {
                        // Keep the season the person picked while this ran; else the one the episode is in.
                        let keep = self.ep_seasons.get(self.season).map(|r| r.id.clone());
                        self.season = keep
                            .and_then(|k| rows.iter().position(|r| r.id == k))
                            .unwrap_or(chosen);
                        self.ep_seasons = rows;
                        self.load_cards();
                    }
                }
                Err(std::sync::mpsc::TryRecvError::Disconnected) => self.ep_wait_seasons = None,
                Err(std::sync::mpsc::TryRecvError::Empty) => {}
            }
        }
        if let Some((season, w)) = &self.ep_wait_cards {
            let season = *season;
            match w.0.try_recv() {
                Ok(found) => {
                    self.ep_wait_cards = None;
                    // Someone who switched season meanwhile gets that season's episodes, not these.
                    if let (Some(cards), true) = (found, season == self.season) {
                        let g = strip_geometry(&self.env);
                        let running = self.vm.spec().item_id.clone();
                        let scale = self.env.scale.max(0.5);
                        // The old stills' regions are free again before the new ones take theirs.
                        self.cx.images.borrow_mut().reset_stills();
                        self.ep_stills = cards
                            .iter()
                            .map(|c| {
                                // The card's device pixels (the running one is 1.25 x): the picture is asked for, and cut
                                // down to, exactly that, so it is drawn 1:1.
                                let k = if c.id == running && !g.tv { 1.25 } else { 1.0 };
                                let (tw, th) = (
                                    (g.card * k * scale).round().max(1.0) as u32,
                                    (g.img * k * scale).round().max(1.0) as u32,
                                );
                                let address = c
                                    .image
                                    .as_deref()
                                    .and_then(|a| swiftly_images::Url::parse(a).ok())
                                    .map(|u| crate::hub::sized_for_device(&u, tw, th).to_string());
                                self.ep_source.as_ref().map(|s| {
                                    player_card::CardStill::new(s.still(&c.id, address.as_deref()))
                                        .fitted(tw, th)
                                })
                            })
                            .collect();
                        self.ep_cards = cards;
                        self.strip_placed = false;
                    }
                }
                Err(std::sync::mpsc::TryRecvError::Disconnected) => self.ep_wait_cards = None,
                Err(std::sync::mpsc::TryRecvError::Empty) => {}
            }
        }
    }

    /// A card was chosen: the running episode just closes the layer, another one is started through the core's switch
    /// (stop report, plan, load), like the Mac's `start(item)`.
    fn start_episode(&mut self, card: &EpisodeCardData, now: f64) {
        self.send(PlayerIntent::Layer(None), now);
        if card.id == self.vm.spec().item_id {
            return;
        }
        self.vm.set_next(Some(swiftly_vm::NextEpisode {
            id: card.id.clone(),
            title: card.title.clone(),
        }));
        self.send(PlayerIntent::NextEpisode, now);
    }

    /// Where the layer gets its data.
    pub fn set_episode_source(&mut self, source: Arc<dyn EpisodeSource>) {
        self.ep_source = Some(source);
    }

    /// Puts the strip on the running episode once per opening (tv: at the front, else in the middle).
    fn place_strip(&mut self) -> bool {
        let open = self.vm.controls().layer == Some(PlayerLayer::Episodes);
        if !open {
            self.strip_placed = false;
            self.seasons_open = false;
            return false;
        }
        if self.strip_placed {
            return false;
        }
        let g = strip_geometry(&self.env);
        let Some(current) = self.current_card() else {
            return false;
        };
        let at = current as f32 * (g.card + g.gap);
        let target = if g.tv {
            at
        } else {
            at + g.card * 1.25 / 2.0 - self.env.size.w / 2.0 + g.edge
        };
        if self
            .ui
            .jump_first_scroll(Axis::Horizontal, f64::from(target.max(0.0)))
        {
            self.strip_placed = true;
            return true;
        }
        false
    }

    /// One frame at `now` ms. Returns the draw list and whether another frame is wanted.
    pub fn frame(&mut self, now: f64) -> (DrawList, bool) {
        self.follow_subtitle_look(now);
        self.episodes_tick();
        self.advance(now);
        // A downloaded file that gives no picture: the stream takes over (`fileFailed`), once.
        if self.downloaded && self.vm.transport().failure.is_some() {
            self.downloaded = false;
            self.stream_fallback = Some(self.vm.transport().position.max(0.0));
        }
        self.sync();
        let visible = self.vm.controls().visible;
        if self.env.idiom == swiftly_ui::Idiom::Tv && visible && !self.seen_visible {
            self.ui.set_focus(focus_id("bar"), now);
        }
        self.seen_visible = visible;
        let mut list = self.ui.frame(now);
        let moved = self.place_strip();
        if moved {
            self.sync();
            list = self.ui.frame(now);
        }
        let _ = self.drain(now);
        let more = self.wants_frame();
        (list, more)
    }

    /// Whether a frame is wanted without a new event: always while the picture runs.
    pub fn wants_frame(&self) -> bool {
        self.ui.needs_frame()
            || self.card_motion.moving(self.cur_s)
            || self
                .card_still
                .as_ref()
                .is_some_and(|s| s.moving(self.cur_s))
            || (self.vm.controls().layer == Some(PlayerLayer::Episodes)
                && (self.ep_wait_cards.is_some()
                    || self.ep_wait_seasons.is_some()
                    || self
                        .ep_stills
                        .iter()
                        .flatten()
                        .any(|s| s.moving(self.cur_s))))
            || self.cur_s - self.bounce_at.0.max(self.bounce_at.1) < 0.5
            || self.live.is_some()
            || self.engine.with(|e| e.playing)
            || !self.vm.transport().picture_shown
    }

    fn desk(&self) -> bool {
        Form::of(self.env.idiom) == Form::Desktop
    }

    /// Whether the episodes layer (the strip of cards) is open.
    pub fn episodes_open(&self) -> bool {
        self.vm.controls().layer == Some(PlayerLayer::Episodes)
    }

    /// How far the strip of episode cards is scrolled sideways (tests, measuring).
    pub fn strip_offset(&self) -> f32 {
        self.ui.scroll_offsets().first().copied().unwrap_or(0.0) as f32
    }

    /// A wheel notch or touchpad delta over the episode strip: it moves sideways whichever way the wheel turns
    /// (`ScrollView(.horizontal)` on the Mac). Returns whether the strip moved.
    pub fn wheel_scroll(&mut self, x: f32, y: f32, dx: f32, dy: f32, now: f64) -> bool {
        let moved = self.ui.wheel_scroll(x, y, dx, dy, now);
        if moved {
            self.sync();
        }
        moved
    }

    /// The host tells whether the window is in real fullscreen.
    pub fn set_fullscreen(&mut self, on: bool) {
        if on != self.fullscreen {
            self.fs_epoch += 1;
        }
        self.fullscreen = on;
    }

    /// Whether the host should toggle fullscreen now (F, the rail button, double-click, Esc in fullscreen). Read once.
    pub fn take_fullscreen_request(&mut self) -> bool {
        std::mem::take(&mut self.fs_request)
    }

    /// The cursor is hidden together with the controls while the film runs (desktop).
    pub fn cursor_hidden(&self) -> bool {
        let c = self.vm.controls();
        self.desk()
            && !c.visible
            && c.layer.is_none()
            && self.vm.transport().picture_shown
            && matches!(self.vm.transport().phase, Phase::Playing)
    }

    /// "Endet um HH:mm" instead of the remaining time; `local_seconds` is the local time of day now.
    pub fn set_end_time(&mut self, on: bool, local_seconds: f64, now: f64) {
        self.end_base = on.then_some((local_seconds, now / 1000.0));
    }

    /// The pointer moved (no button): hover fills, tooltips, volume compartment, scrubber preview, controls wake.
    pub fn pointer_move(&mut self, x: f32, y: f32, now: f64) {
        if !self.desk() {
            return;
        }
        {
            let look = self.card_motion.look(self.cur_s, self.env.reduce_motion);
            let r = player_card::card_rect(
                self.env.size.w,
                self.env.size.h,
                metrics(&self.env).edge,
                76.0,
                &look,
            );
            self.card_motion.set_hover(
                look.shown && look.zoom < 0.01 && player_card::inside(r, x, y),
                now / 1000.0,
                self.env.reduce_motion,
            );
        }
        let moved = self
            .pointer
            .is_none_or(|(px, py)| (x - px).abs() > 2.0 || (y - py).abs() > 2.0);
        self.pointer = Some((x, y));
        let c = self.vm.controls();
        let (x0, y0, x1, y1) = vol_zone(&self.env, self.handover_on());
        self.vol_hover = c.visible && x >= x0 && x <= x1 && y >= y0 && y <= y1;
        let (bx, bw) = bar_span(&self.env, self.end_base.is_some());
        let (top, h) = bar_hit(&self.env);
        self.hover_pos =
            (c.visible && c.layer.is_none() && x >= bx && x <= bx + bw && y >= top && y <= top + h)
                .then(|| self.pos_at(x));
        if moved && c.layer.is_none() && !c.scrubbing {
            self.send(PlayerIntent::WakeControlsBeside, now);
        }
        self.sync();
        self.ui.pointer_move(x, y, now);
    }

    /// The pointer left the window: playing hides the controls at once.
    pub fn pointer_leave(&mut self, now: f64) {
        self.pointer = None;
        self.vol_hover = false;
        self.hover_pos = None;
        self.ui.pointer_leave(now);
        let c = self.vm.controls();
        if self.desk()
            && c.visible
            && c.layer.is_none()
            && matches!(self.vm.transport().phase, Phase::Playing)
        {
            self.send(PlayerIntent::ToggleControls, now);
        }
    }

    /// The wheel over the speaker or compartment sets the volume (`VS`): a touchpad moves by d/24*5 %, a notch by 5 %
    /// (at most three). Returns whether the event was used.
    pub fn volume_wheel(&mut self, x: f32, y: f32, dy: f32, precise: bool, now: f64) -> bool {
        let (x0, y0, x1, y1) = vol_zone(&self.env, self.handover_on());
        if !self.desk()
            || !self.vm.controls().visible
            || x < x0
            || x > x1
            || y < y0
            || y > y1
            || dy == 0.0
        {
            return false;
        }
        let share = if precise {
            dy / 24.0 * 0.05
        } else {
            dy.clamp(-3.0, 3.0) * 0.05
        };
        self.volume = (self.volume + (share * 100.0).round() as i32).clamp(0, 100);
        self.vol_until = now / 1000.0 + 1.2;
        self.send(PlayerIntent::Volume(self.volume), now);
        self.send(PlayerIntent::WakeControls, now);
        self.persist_volume();
        self.sync();
        true
    }

    fn volume_at(&mut self, x: f32, now: f64) {
        let (sx, _) = vol_geometry(&self.env, self.handover_on());
        let f = ((x - sx - VOL_INSET) / (VOL_SLIDER - 2.0 * VOL_INSET)).clamp(0.0, 1.0);
        self.volume = (f * 100.0).round() as i32;
        self.send(PlayerIntent::Volume(self.volume), now);
    }

    fn on_volume_slider(&self, x: f32, y: f32) -> bool {
        let (sx, cy) = vol_geometry(&self.env, self.handover_on());
        self.vol_open && x >= sx - 8.0 && x <= sx + VOL_SLIDER + 8.0 && (y - cy).abs() <= 18.0
    }

    /// Click on the speaker and key M (`volumeMuted`): mute remembers the value, a second time restores it (or 1 %).
    fn toggle_mute(&mut self, now: f64) {
        if self.volume > 0 {
            self.volume_prior = self.volume;
            self.volume = 0;
        } else {
            self.volume = if self.volume_prior > 0 {
                self.volume_prior
            } else {
                1
            };
        }
        self.vol_until = now / 1000.0 + 1.2;
        self.send(PlayerIntent::Volume(self.volume), now);
        self.persist_volume();
    }

    /// Keeps the volume between sessions like the Mac (`playerLautstaerke` 0...1, `playerLautstaerkeDavor` before a mute).
    fn persist_volume(&self) {
        if let Some(store) = &self.store {
            crate::store::set_logged(
                &**store,
                "playerLautstaerke",
                Value::Double(f64::from(self.volume) / 100.0),
            );
            crate::store::set_logged(
                &**store,
                "playerLautstaerkeDavor",
                Value::Double(f64::from(self.volume_prior.max(0)) / 100.0),
            );
        }
    }

    /// The saved subtitle look (`utAussehen`, synced) as the style the engine and the app-drawn route use. The 16 point
    /// margin follows the picture on screen (window size in points, source aspect).
    fn stored_subtitle_style(&self) -> swiftly_playback::engine::SubtitleTextStyle {
        let source = self.live.as_ref().and_then(|(live, _)| live.source_size());
        let picture = crate::subtitle_style::picture_pt((self.env.size.w, self.env.size.h), source);
        let stored = match self.store.as_ref().and_then(|s| s.get("utAussehen")) {
            Some(Value::Data(d)) => Some(d),
            _ => None,
        };
        let look = swiftly_support::subtitle::SubtitleLook::read(stored.as_deref());
        crate::subtitle_style::style_of(&look, picture)
    }

    /// Hands the saved subtitle look (`utAussehen`, synced) to the engine: before the first frame, and again when it
    /// changes, so a running player follows the settings page at once.
    fn follow_subtitle_look(&mut self, now: f64) {
        let style = self.stored_subtitle_style();
        let Some((engine, seen, at)) = self.sub_look.as_mut() else {
            return;
        };
        if now - *at < 200.0 && seen.is_some() {
            return;
        }
        *at = now;
        if seen.as_ref() != Some(&style) {
            engine.set_subtitle_style(&style);
            *seen = Some(style);
        }
    }

    /// Gives the player the settings file: the saved volume (and a saved mute) applies at once and later changes are kept.
    pub fn set_store(&mut self, store: Arc<JsonFileStore>, now: f64) {
        let get = |k: &str| match store.get(k) {
            Some(Value::Double(v)) => Some(v.clamp(0.0, 1.0)),
            _ => None,
        };
        if let Some(v) = get("playerLautstaerke") {
            self.volume_prior =
                (get("playerLautstaerkeDavor").unwrap_or(0.0) * 100.0).round() as i32;
            self.volume = (v * 100.0).round() as i32;
            self.send(PlayerIntent::Volume(self.volume), now);
        }
        self.prefs = prefs_from_store(&store, &self.prefs, self.account_next);
        self.vm.set_prefs(self.prefs.clone());
        self.set_end_time(
            end_time_from_store(&store),
            crate::local_clock::day_seconds(),
            now,
        );
        self.store = Some(store);
        if let Some((_, _, at)) = self.sub_look.as_mut() {
            *at = f64::NEG_INFINITY;
        }
        self.follow_subtitle_look(now);
    }

    /// The next episode's code and the account's own next-episode wish; the prefs follow at once.
    pub fn set_title_facts(&mut self, next_code: Option<String>, account_next: Option<bool>) {
        self.next_code = next_code;
        self.account_next = account_next;
        if let Some(store) = self.store.clone() {
            self.prefs = prefs_from_store(&store, &self.prefs, self.account_next);
            self.vm.set_prefs(self.prefs.clone());
        }
    }

    /// The file plays from the device, so a failed start falls back to the stream.
    pub fn set_downloaded(&mut self, on: bool) {
        self.downloaded = on;
    }

    /// What the technical overlay says about the file.
    pub fn set_tech_facts(&mut self, facts: Option<crate::player_host::TechFacts>) {
        self.tech_facts = facts;
        self.tech_rows.0 = f64::NEG_INFINITY;
    }

    /// The season of the running episode (the episodes layer opens on it).
    pub fn set_season_id(&mut self, id: Option<String>) {
        self.season_id = id;
    }

    /// The running episode's code for the system's now-playing card.
    pub fn set_episode_code(&mut self, code: Option<String>) {
        self.episode_code = code;
    }

    /// A downloaded file that would not open: the second to play the stream from (`fileFailed`), read once.
    pub fn take_stream_fallback(&mut self) -> Option<(String, f64)> {
        self.stream_fallback
            .take()
            .map(|since| (self.item_id.clone(), since))
    }

    /// What the title is: a series episode has the episodes layer and its button; a transcode is named in the header.
    pub fn set_title_kind(&mut self, episode: bool, transcode: bool) {
        self.has_episodes = episode;
        self.transcode = transcode;
    }

    /// The player prefs the screen holds (tests).
    pub fn prefs(&self) -> &PlayerPrefs {
        &self.prefs
    }

    fn pos_at(&self, x: f32) -> f64 {
        let (bx, bw) = bar_span(&self.env, self.end_base.is_some());
        let dur = self.vm.transport().duration;
        f64::from(((x - bx) / bw).clamp(0.0, 1.0)) * dur
    }

    fn on_bar(&self, x: f32, y: f32) -> bool {
        let (bx, bw) = bar_span(&self.env, self.end_base.is_some());
        let (top, h) = bar_hit(&self.env);
        self.vm.controls().visible
            && self.vm.controls().layer.is_none()
            && x >= bx - 14.0
            && x <= bx + bw + 14.0
            && y >= top
            && y <= top + h
    }

    /// A finger or button goes down.
    pub fn touch_down(&mut self, x: f32, y: f32, now: f64) {
        if self.env.idiom == swiftly_ui::Idiom::Tv {
            return;
        }
        if let Some(on_x) = self.card_hit(x, y) {
            let _ = on_x;
            self.card_drag = Some((x, y));
            return;
        }
        if self.on_volume_slider(x, y) {
            self.vol_drag = true;
            self.volume_at(x, now);
            return;
        }
        if self.on_bar(x, y) {
            let at = self.pos_at(x);
            self.send(PlayerIntent::ScrubStart, now);
            self.send(PlayerIntent::ScrubMove(at), now);
            self.scrub = Some(ScrubState { last: at });
            return;
        }
        if self.vm.controls().visible {
            self.send(PlayerIntent::WakeControls, now);
        }
        self.sync();
        self.down = Some((x, y));
        self.moved = false;
        self.ui.touch_down(x, y, now);
        let _ = self.drain(now);
    }

    /// The finger moves.
    pub fn touch_move(&mut self, x: f32, y: f32, now: f64) {
        if let Some((sx, sy)) = self.card_drag {
            self.card_motion.drag_to(x - sx, y - sy);
            self.sync();
            return;
        }
        if self.vol_drag {
            self.volume_at(x, now);
            return;
        }
        if self.scrub.is_some() {
            let at = self.pos_at(x);
            if let Some(s) = &mut self.scrub {
                s.last = at;
            }
            self.send(PlayerIntent::ScrubMove(at), now);
            return;
        }
        if let Some((dx, dy)) = self.down {
            self.moved |= (x - dx).abs() > 10.0 || (y - dy).abs() > 10.0;
            // The window moves by its background, like the Mac's: a drag that started on nothing (no control, no layer
            // card) hands the press to the window manager. It is no tap any more.
            if self.desk() && (x - dx).hypot(y - dy) > WINDOW_DRAG_SLOP && self.ui.touch_is_bare() {
                self.down = None;
                self.ui.touch_cancel(now);
                self.window_drag = true;
                return;
            }
        }
        self.ui.touch_move(x, y, now);
        let _ = self.drain(now);
    }

    /// Whether the last drag asks the host to move the window (read once).
    pub fn take_window_drag(&mut self) -> bool {
        std::mem::take(&mut self.window_drag)
    }

    /// The finger lifts.
    pub fn touch_up(&mut self, x: f32, y: f32, now: f64) {
        if let Some((sx, sy)) = self.card_drag.take() {
            self.card_released(sx, sy, x, y, now);
            return;
        }
        if self.vol_drag {
            self.vol_drag = false;
            self.volume_at(x, now);
            self.persist_volume();
            return;
        }
        if let Some(s) = self.scrub.take() {
            let at = self.pos_at(x);
            let _ = s.last;
            self.send(PlayerIntent::ScrubEnd(at), now);
            return;
        }
        self.ui.touch_up(x, y, now);
        let taken = self.drain(now);
        if taken == 0 && !self.moved && self.down.take().is_some() {
            self.bare_tap(x, y, now);
        }
    }

    /// Whether a pointer at (x, y) is on the next-episode card; says whether it is on the close button.
    fn card_hit(&self, x: f32, y: f32) -> Option<bool> {
        if !self.desk() || !matches!(self.vm.offer().view, OfferView::Card { .. }) {
            return None;
        }
        let look = self.card_motion.look(self.cur_s, self.env.reduce_motion);
        if !look.shown {
            return None;
        }
        let r = player_card::card_rect(
            self.env.size.w,
            self.env.size.h,
            metrics(&self.env).edge,
            76.0,
            &look,
        );
        player_card::inside(r, x, y).then(|| player_card::inside(player_card::x_rect(r), x, y))
    }

    /// The pointer that went down on the card lets go at (x, y): far away dismisses (keep the credits), a click on the
    /// close button too, a click elsewhere zooms, anything between springs back.
    fn card_released(&mut self, sx: f32, sy: f32, x: f32, y: f32, now: f64) {
        let dist = ((x - sx).powi(2) + (y - sy).powi(2)).sqrt();
        let reduce = self.env.reduce_motion;
        if dist > player_card::DRAG_DISMISS {
            self.card_motion.release(now / 1000.0);
            self.send(PlayerIntent::Back2, now);
        } else if dist < player_card::CLICK_SLOP {
            self.card_motion.release(now / 1000.0);
            let look = self.card_motion.look(self.cur_s, reduce);
            let r = player_card::card_rect(
                self.env.size.w,
                self.env.size.h,
                metrics(&self.env).edge,
                76.0,
                &CardLook {
                    drag: (0.0, 0.0),
                    ..look
                },
            );
            if player_card::inside(player_card::x_rect(r), sx, sy) {
                self.send(PlayerIntent::Back2, now);
            } else {
                // The Mac: the click starts the next episode, the card zooms over the switch.
                if !self.card_motion.zoomed() {
                    self.card_motion.toggle_zoom(now / 1000.0, reduce);
                }
                self.send(PlayerIntent::PressCard, now);
            }
        } else {
            self.card_motion.release(now / 1000.0);
        }
        self.sync();
    }

    /// A tap on the bare picture: the middle zone where the pause button sits pauses, the halves toggle and seek.
    fn bare_tap(&mut self, x: f32, y: f32, now: f64) {
        let c = self.vm.controls();
        if c.layer.is_some() || self.vm.transport().failure.is_some() {
            return;
        }
        if self.desk() {
            // The Mac: a click shows the controls, a double-click toggles real fullscreen.
            let s = now / 1000.0;
            if self.click_at.is_some_and(|t| s - t < 0.4) {
                self.click_at = None;
                self.fs_request = true;
            } else {
                self.click_at = Some(s);
                self.send(PlayerIntent::WakeControls, now);
            }
            return;
        }
        let (w, h) = (self.env.size.w, self.env.size.h);
        if (x - w / 2.0).abs() <= 54.0 && (y - h / 2.0).abs() <= 66.0 {
            self.send(PlayerIntent::TogglePlay, now);
        } else {
            self.tap_area(if x < w / 2.0 { -1 } else { 1 }, now);
        }
    }

    /// The touch is cancelled.
    pub fn touch_cancel(&mut self, now: f64) {
        if self.scrub.take().is_some() {
            let pos = self.vm.transport().position;
            self.send(PlayerIntent::ScrubEnd(pos), now);
        }
        self.ui.touch_cancel(now);
    }

    /// A pinch finished with this magnification (the shell's multi-touch seam): out fills, in fits.
    pub fn pinch(&mut self, magnification: f64, now: f64) {
        if self.vm.controls().layer.is_some() {
            return;
        }
        if magnification > PINCH_IN && !self.fill {
            self.set_fill(true, now);
        } else if magnification < PINCH_OUT && self.fill {
            self.set_fill(false, now);
        }
    }

    fn set_fill(&mut self, on: bool, now: f64) {
        self.fill = on;
        self.send(PlayerIntent::Fill(on), now);
    }

    fn tap_area(&mut self, bearing: i32, now: f64) {
        let s = now / 1000.0;
        let window = if self.chain { CHAIN_TAP } else { DOUBLE_TAP };
        if let Some((before, page)) = self.last_tap
            && page == bearing
            && s - before < window
        {
            self.last_tap = Some((s, bearing));
            self.chain = true;
            self.send(
                if bearing < 0 {
                    PlayerIntent::Back
                } else {
                    PlayerIntent::Forward
                },
                now,
            );
            return;
        }
        self.last_tap = Some((s, bearing));
        self.chain = false;
        self.send(PlayerIntent::ToggleControls, now);
    }

    fn drain(&mut self, now: f64) -> usize {
        let events = self.ui.take_events();
        let mut taps = 0;
        for ev in events {
            match ev {
                UiEvent::Tap(a) => {
                    taps += 1;
                    self.action(a, now);
                }
                UiEvent::Secondary { action, x, y } => self.open_episode_menu(&action, x, y),
                _ => {}
            }
        }
        taps
    }

    /// A right click on a card of the episodes layer.
    pub fn secondary_click(&mut self, x: f32, y: f32, now: f64) -> bool {
        let took = self.ui.secondary_click(x, y, now);
        self.drain(now);
        self.sync();
        took
    }

    /// The tile of an episode card for the shared menu: only what its entries read.
    fn card_tile(card: &EpisodeCardData) -> swiftly_vm::Tile {
        swiftly_vm::Tile {
            id: card.id.clone(),
            title: card.title.clone(),
            subtitle: None,
            progress: card.progress,
            image: None,
            badges: if card.watched {
                vec![swiftly_vm::Badge::Watched]
            } else {
                Vec::new()
            },
            remaining: None,
            facts: swiftly_vm::TileFacts {
                kind: Some("Episode".to_owned()),
                ..swiftly_vm::TileFacts::default()
            },
        }
    }

    /// The menu context in the player: the Mac's `inPlayer` leaves only the watched marks.
    fn episode_menu_cx() -> crate::tile_menu::Cx {
        crate::tile_menu::Cx {
            host: swiftly_vm::MenuContext {
                in_player: true,
                ..swiftly_vm::MenuContext::default()
            },
            watchlist_shown: false,
            favourite: false,
        }
    }

    /// Opens the tile menu of card `epmenu:{i}` at the pointer.
    fn open_episode_menu(&mut self, a: &Action, x: f32, y: f32) {
        let Some(i) =
            (0..self.ep_cards.len()).find(|i| *a == Action::from(format!("epmenu:{i}").as_str()))
        else {
            return;
        };
        let tile = Self::card_tile(&self.ep_cards[i]);
        let rows = crate::tile_menu::pop_items(
            crate::home::Form::Desktop,
            &Self::episode_menu_cx(),
            Some(&tile),
        );
        if rows.is_empty() {
            return;
        }
        self.menu_c.open(
            rows,
            Anchor::Pointer(swiftly_layout::Point::new(x, y)),
            0.0,
            false,
        );
        self.log.push(format!("epmenu open {}", tile.id));
        self.ep_menu = Some(i);
    }

    /// A pick `tmenu:{n}` of the card menu: the watched mark goes to the server and the card follows.
    fn episode_menu_pick(&mut self, a: &Action) -> bool {
        let Some(i) = self.ep_menu else {
            return false;
        };
        let Some(card) = self.ep_cards.get(i) else {
            return false;
        };
        let (cx, tile) = (Self::episode_menu_cx(), Self::card_tile(card));
        let entries = crate::tile_menu::entries(crate::home::Form::Desktop, &cx, Some(&tile));
        let Some((_, entry)) = entries
            .into_iter()
            .enumerate()
            .find(|(n, _)| *a == Action::from(format!("tmenu:{n}").as_str()))
        else {
            return false;
        };
        self.ep_menu = None;
        let on = matches!(entry, crate::tile_menu::Entry::Watched);
        self.log.push(format!("epmenu {entry:?} {}", tile.id));
        let _ = crate::tile_menu::run(&entry, &tile, &cx, &mut self.ep_writers);
        // The card shows the new state at once, like the Mac's reload of the season after the write.
        if let Some(card) = self.ep_cards.get_mut(i) {
            card.watched = on;
            if on {
                card.progress = None;
            }
        }
        true
    }

    fn action(&mut self, a: Action, now: f64) {
        let is = |s: &str| a == Action::from(s);
        // Any tap that reaches the screen while a menu is up is a choice or a click outside: the menu closes either way.
        self.menu_c.close();
        if a == popover::DISMISS {
            self.ep_menu = None;
            self.sync();
            return;
        }
        if self.episode_menu_pick(&a) {
            self.sync();
            return;
        }
        self.ep_menu = None;
        if is("tap:-1") {
            self.tap_area(-1, now);
        } else if is("tap:1") {
            self.tap_area(1, now);
        } else if is("toggle") || is("toggle-btn") {
            self.send(PlayerIntent::TogglePlay, now);
        } else if is("back") {
            self.send(PlayerIntent::Back, now);
        } else if is("fwd") {
            self.send(PlayerIntent::Forward, now);
        } else if is("tracks") {
            self.send(PlayerIntent::Layer(Some(PlayerLayer::Tracks)), now);
        } else if is("settings") {
            self.send(PlayerIntent::Layer(Some(PlayerLayer::Settings)), now);
        } else if is("layer-close") {
            self.send(PlayerIntent::Layer(None), now);
        } else if is("close") || is("fail-close") || is("fail-quiet") {
            self.send(PlayerIntent::Close, now);
        } else if is("retry") {
            self.send(PlayerIntent::Retry, now);
        } else if is("offer") {
            self.send(PlayerIntent::PressOffering, now);
        } else if is("season") {
            if self.desk() {
                self.open_seasons();
            } else {
                self.seasons_open = !self.seasons_open;
            }
        } else if is("strip:-1") || is("strip:1") {
            let g = strip_geometry(&self.env);
            let x = self.ui.scroll_offsets().first().copied().unwrap_or(0.0) as f32;
            let dir = if is("strip:1") { 1.0 } else { -1.0 };
            // `page(±1, cards: 3)` with the `reveal` animation (`PlayerEpisodeStrip.swift:94`).
            let _ = self.ui.scroll_first_to(
                Axis::Horizontal,
                f64::from((x + dir * (g.card + g.gap) * 3.0).max(0.0)),
                true,
                now,
            );
        } else if let Some(i) = (0..self.ep_seasons.len()).find(|i| is(&format!("season:{i}"))) {
            self.season = i;
            self.seasons_open = false;
            self.load_cards();
        } else if is("episodes") {
            self.send(PlayerIntent::Layer(Some(PlayerLayer::Episodes)), now);
        } else if is("fullscreen") {
            self.fs_request = true;
        } else if is("mute") {
            self.toggle_mute(now);
        } else if is("handover") {
            self.open_handover();
        } else if let Some(i) = (0..self.p_targets().len()).find(|i| is(&format!("handover:{i}"))) {
            self.start_hand_over(i, now);
        } else if is("group-error") {
            if let Some(hub) = &self.together {
                hub.dismiss_error();
            }
            self.error_gone = true;
        } else if is("group-leave") {
            self.leave_group(now);
        } else if is("tech:0") || is("tech:1") {
            self.tech = is("tech:1");
        } else if is("fill") || is("fill:0") || is("fill:1") {
            let on = if is("fill") { !self.fill } else { is("fill:1") };
            self.set_fill(on, now);
        } else {
            self.action_keyed(a, now);
        }
        self.sync();
    }

    /// The devices the film can go to: the account's (live) or the demo's one TV.
    fn p_targets(&self) -> Vec<(String, String)> {
        if self.together.is_some() {
            self.view
                .targets
                .iter()
                .map(|t| (t.device_id.clone(), t.name.clone()))
                .collect()
        } else if self.demo_targets {
            vec![("demo-tv".to_owned(), DEMO_TARGET.to_owned())]
        } else {
            Vec::new()
        }
    }

    /// The hand-over button is there: devices to send to, and not in a group (the group watches here, handing
    /// over would leave it without a word).
    fn handover_on(&self) -> bool {
        !(self.shared && self.view.group.is_some()) && !self.p_targets().is_empty()
    }

    /// The text of the group's error strip while it is up (4 s, or until tapped).
    fn group_error_text(&self) -> Option<String> {
        let (_, at) = self.error_seen?;
        let (_, text) = self.view.error.as_ref()?;
        (!self.error_gone && self.cur_s - at < ERROR_SECONDS).then(|| text.clone())
    }

    /// The player's state as the group's session reads it.
    fn group_view(&self) -> swiftly_sync::PlayerView {
        let t = self.vm.transport();
        swiftly_sync::PlayerView {
            title: self.ids.as_ref().map(|i| i.0.clone()).unwrap_or_default(),
            ready: t.picture_shown && !self.switching(),
            spot: t.position,
        }
    }

    /// Hands the player the hub of the account. When the group watches this title, the player joins in: its buttons
    /// become requests and the group's steps move it (`sharedAn`).
    pub fn attach_together(&mut self, hub: Arc<crate::together::Hub>, item_id: &str) {
        self.ids.get_or_insert_with(|| (item_id.to_owned(), None));
        self.view = hub.view();
        hub.player_open(true);
        if self.view.group.is_some() && hub.group_title().as_deref() == Some(item_id) {
            self.shared = true;
            self.vm
                .set_group(Some(Arc::clone(&hub) as Arc<dyn swiftly_vm::GroupHook>));
            hub.player_attached(self.group_view());
        }
        self.together = Some(hub);
        self.sync();
    }

    /// Is the player in the group right now?
    pub fn in_group(&self) -> bool {
        self.shared && self.view.group.is_some()
    }

    /// The title and the episode line the header shows.
    pub fn head(&self) -> &(String, String) {
        &self.head
    }

    /// The still frame of the video, at most 1280 wide: a box one step off the one the GPU path asks for, so libmpv
    /// renders the picture that stands (a paused engine has no "new" frame, a different size makes it render).
    fn grab_still(&self) -> Option<crate::together_ui::ExitStill> {
        let (engine, _) = self.live.as_ref()?;
        let mut got = None;
        for (w, h) in [(1278_u32, 718_u32), (1100, 618)] {
            engine.frame(w, h, &mut |fw, fh, rgba| {
                if fw > 0 && fh > 0 && rgba.len() == fw as usize * fh as usize * 4 {
                    got = Some(crate::together_ui::ExitStill {
                        w: fw,
                        h: fh,
                        rgba: Arc::new(rgba.to_vec()),
                    });
                }
            });
            if got.is_some() {
                break;
            }
        }
        got
    }

    /// The grabbed still, once (the suite hands it to the exit card).
    pub fn take_exit_still(&mut self) -> Option<crate::together_ui::ExitStill> {
        self.exit_still.take()
    }

    /// The device the picture leaves for after a hand-over or a takeover, once the player closed.
    pub fn taken_to(&self) -> Option<&str> {
        self.taken_to.as_deref()
    }

    /// Once per frame: reads the group, tells it how this player stands, times the error strip.
    fn together_tick(&mut self, s: f64) {
        let Some(hub) = self.together.clone() else {
            return;
        };
        let was = self.view.group.is_some();
        self.view = hub.view();
        if self.shared {
            if was && self.view.group.is_none() {
                // The group is gone (left from the sheet, or it ended): the buttons are the player's own again.
                self.shared = false;
                self.vm.set_group(None);
            } else {
                hub.player_update(self.group_view());
                if s - self.last_group_tick >= 0.5 {
                    self.last_group_tick = s;
                    hub.player_tick();
                }
            }
        }
        match (&self.view.error, self.error_seen) {
            (Some((n, _)), seen) if seen.map(|e| e.0) != Some(*n) => {
                self.error_seen = Some((*n, s));
                self.error_gone = false;
            }
            _ => {}
        }
    }

    /// One thing the hub has for this player (the suite hands it over once per frame).
    pub fn hub_event(&mut self, event: crate::together::HubEvent, now: f64) {
        use crate::together::HubEvent as E;
        use swiftly_sync::{PlayerAction as A, RemoteCommand as C};
        match event {
            E::Step { action, .. } => self.send(
                match action {
                    A::Proceed => PlayerIntent::EnginePlay,
                    A::Halt => PlayerIntent::EnginePause,
                    A::Jump(to) => PlayerIntent::EngineSeek(to),
                },
                now,
            ),
            E::Command(c) => {
                let running = self.vm.transport().running;
                let group = self.in_group();
                match c {
                    // In a group a pause or a resume is a request, never a direct stop of the picture.
                    C::Pause if group => {
                        if running {
                            self.send(PlayerIntent::TogglePlay, now);
                        }
                    }
                    C::Proceed if group => {
                        if !running {
                            self.send(PlayerIntent::TogglePlay, now);
                        }
                    }
                    C::Pause => self.send(PlayerIntent::EnginePause, now),
                    C::Proceed => self.send(PlayerIntent::EnginePlay, now),
                    C::Toggle => self.send(PlayerIntent::TogglePlay, now),
                    C::Stop => self.send(PlayerIntent::Close, now),
                    C::JumpOn(to) => self.send(PlayerIntent::SeekTo(to), now),
                    C::Forward => self.send(PlayerIntent::Forward, now),
                    C::Back => self.send(PlayerIntent::Back, now),
                    C::Next => self.send(PlayerIntent::NextEpisode, now),
                    C::Previous => {}
                }
                self.send(PlayerIntent::WakeControls, now);
            }
            E::TakenOver { device } | E::HandedOver { device } => {
                // The picture stands paused here; grab it before the engine is closed (`area.stillImage`).
                self.exit_still = self.grab_still();
                self.taken_to = Some(device);
                self.handover_ran = None;
                self.send(PlayerIntent::Close, now);
            }
            E::HandOverFailed { .. } => {
                if self.handover_ran.take() == Some(true) {
                    self.send(PlayerIntent::EnginePlay, now);
                }
            }
            E::LoadTitle { .. } | E::Play(_) | E::StartHere { .. } => {}
        }
        self.sync();
    }

    /// "Übergeben an <device>": pauses here so the other device does not start behind, then sends the title at this
    /// position with these tracks. If the device does not take it, the film plays on here.
    fn start_hand_over(&mut self, i: usize, now: f64) {
        let targets = self.p_targets();
        let Some((device_id, name)) = targets.get(i).cloned() else {
            return;
        };
        let (Some(hub), Some((item_id, source_id))) = (self.together.clone(), self.ids.clone())
        else {
            self.log.push(format!("handover:{name}"));
            return;
        };
        if self.handover_ran.is_some() {
            return;
        }
        let t = self.vm.transport();
        self.handover_ran = Some(t.running);
        let tracks = self.vm.tracks();
        let audio = tracks.audio.iter().find(|r| r.selected).map(|r| r.index);
        let subtitle = if tracks.subtitles_off {
            Some(-1)
        } else {
            tracks
                .subtitles
                .iter()
                .find(|r| r.selected)
                .map(|r| r.index)
        };
        self.send(PlayerIntent::EnginePause, now);
        hub.hand_over(crate::together::HandOver {
            device_id,
            item_id,
            position: t.position,
            source_id,
            audio,
            subtitle,
        });
    }

    /// "Gruppe verlassen": the player goes on alone.
    fn leave_group(&mut self, now: f64) {
        if let Some(hub) = &self.together {
            hub.leave();
        }
        self.shared = false;
        self.vm.set_group(None);
        self.send(PlayerIntent::Layer(None), now);
    }

    /// The handover menu under its rail button (`Menu` in `PS:703`): the entries are the devices that can take over.
    fn open_handover(&mut self) {
        let m = metrics(&self.env);
        let right = self.env.size.w - (m.edge - (m.button - m.glyph) / 2.0);
        let button =
            swiftly_layout::Rect::new(right - 2.0 * m.button - 2.0, m.rail_top, m.button, m.button);
        let mut entries = vec![MenuEntry::Item(
            MenuItem::new("handover-title", "Übergeben an …").disabled(),
        )];
        entries.extend(self.p_targets().iter().enumerate().map(|(i, (_, name))| {
            MenuEntry::Item(MenuItem::new(format!("handover:{i}").as_str(), name))
        }));
        self.menu_c.open(
            entries,
            Anchor::Button(button),
            swiftly_ui::feel::DROPDOWN_WIDTH,
            false,
        );
    }

    /// The season list under the season line of the episodes layer.
    fn open_seasons(&mut self) {
        let m = metrics(&self.env);
        let button = swiftly_layout::Rect::new(m.edge, m.title_top + 24.0, 110.0, 22.0);
        let entries = self
            .ep_seasons
            .iter()
            .enumerate()
            .map(|(i, row)| {
                MenuEntry::Item(
                    MenuItem::new(format!("season:{i}").as_str(), row.name.as_str())
                        .checked(i == self.season),
                )
            })
            .collect();
        self.menu_c.open(
            entries,
            Anchor::Button(button),
            swiftly_ui::feel::DROPDOWN_WIDTH,
            false,
        );
    }

    /// A key for the open menu.
    fn menu_key(&mut self, key: MenuKey, now: f64) {
        if let MenuOutcome::Activate(a) = self.menu_c.key(key, now) {
            self.action(a, now);
        }
        self.sync();
    }

    fn action_keyed(&mut self, a: Action, now: f64) {
        let tracks = self.vm.tracks();
        for t in &tracks.audio {
            if a == Action::from(format!("audio:{}", t.index).as_str()) {
                self.send(PlayerIntent::SelectAudio(t.index), now);
            }
        }
        for t in std::iter::once(-1).chain(tracks.subtitles.iter().map(|t| t.index)) {
            if a == Action::from(format!("sub:{t}").as_str()) {
                self.send(PlayerIntent::SelectSubtitle(t), now);
            }
        }
        for t in TEMPOS {
            if a == Action::from(format!("tempo:{t}").as_str()) {
                self.send(PlayerIntent::Tempo(t), now);
            }
        }
        for m in std::iter::once(0).chain(SLEEP_CHOICES) {
            if a == Action::from(format!("sleep:{m}").as_str()) {
                self.send(PlayerIntent::Sleep((m > 0).then_some(m)), now);
            }
        }
        for (i, card) in self.ep_cards.clone().iter().enumerate() {
            if a == Action::from(format!("episode:{i}").as_str()) {
                self.start_episode(card, now);
            }
        }
        if a == Action::from("quality:dp") {
            self.send(PlayerIntent::Quality(None), now);
        }
        for q in QUALITY_CAPS {
            if a == Action::from(format!("quality:{q}").as_str()) {
                self.send(PlayerIntent::Quality(Some(q)), now);
            }
        }
        for (tag, sub) in [("audio", false), ("sub", true)] {
            if a == Action::from(format!("delay:{tag}:0").as_str()) {
                let zero = Delay::from_milliseconds(0);
                self.send(
                    if sub {
                        PlayerIntent::SubtitleDelay(zero)
                    } else {
                        PlayerIntent::AudioDelay(zero)
                    },
                    now,
                );
            }
        }
        for (tag, sub, ms) in [
            ("audio", false, tracks.audio_delay_ms),
            ("sub", true, tracks.subtitle_delay_ms),
        ] {
            for (sign, bearing) in [("-", -1_i64), ("+", 1)] {
                if a == Action::from(format!("delay:{tag}:{sign}").as_str()) {
                    self.delay(sub, bearing, ms, now);
                }
            }
        }
    }

    fn delay(&mut self, subtitle: bool, bearing: i64, ms: i64, now: f64) {
        let next = Delay::from_milliseconds(ms).shifted(bearing, 1);
        // `postpone` (`PlayerScreen.swift:1581-1590`): the new value is announced through `notify`.
        let word = if subtitle {
            "Untertitelverzögerung"
        } else {
            "Tonverzögerung"
        };
        self.notice = Some((
            format!("{word} {}", delay_text(next.milliseconds())),
            now / 1000.0 + NOTICE_SECONDS,
        ));
        self.send(
            if subtitle {
                PlayerIntent::SubtitleDelay(next)
            } else {
                PlayerIntent::AudioDelay(next)
            },
            now,
        );
    }

    /// The window closes during playback: the sound stops and position and end go to the server, through the same
    /// close the Close button uses (`PS:583-589`, "the same calls as `finish()`"; the report is once-only).
    pub fn window_closing(&mut self, now: f64) {
        if self.closed {
            return;
        }
        self.send(PlayerIntent::Close, now);
        self.sync();
    }

    /// Esc (desktop, tv Menu): the card first, then a layer, then the controls, then the player.
    pub fn back(&mut self, now: f64) {
        if self.menu_c.is_open() {
            self.menu_c.close();
            self.sync();
            return;
        }
        if !self.desk() {
            self.send(PlayerIntent::Back2, now);
            return;
        }
        // The Mac (`PS:1294-1312`): layer, then offer/card, then leave fullscreen, then close.
        if self.vm.controls().layer.is_some() {
            self.send(PlayerIntent::Layer(None), now);
        } else if self.vm.offer().view != OfferView::Hidden {
            self.send(PlayerIntent::Back2, now);
        } else if self.fullscreen {
            self.fs_request = true;
        } else {
            self.send(PlayerIntent::Close, now);
        }
    }

    /// A desktop shortcut. Returns whether the key was taken. While a layer is open only Esc and Return work.
    pub fn key(&mut self, key: PlayerKey, now: f64) -> bool {
        if self.menu_c.is_open() {
            let k = match key {
                PlayerKey::Escape => MenuKey::Escape,
                PlayerKey::Enter => MenuKey::Enter,
                PlayerKey::Up => MenuKey::Up,
                PlayerKey::Down => MenuKey::Down,
                PlayerKey::Char(ch) => MenuKey::Char(ch),
                _ => return true,
            };
            self.menu_key(k, now);
            return true;
        }
        let layer = self.vm.controls().layer.is_some();
        match key {
            PlayerKey::Escape => self.back(now),
            PlayerKey::Enter => {
                if self.vm.offer().view == OfferView::Hidden {
                    return false;
                }
                self.send(PlayerIntent::PressOffering, now);
            }
            PlayerKey::NextEpisode => {
                if !self.has_next {
                    return false;
                }
                self.send(PlayerIntent::NextEpisode, now);
            }
            _ if layer => return false,
            PlayerKey::Space => self.send(PlayerIntent::TogglePlay, now),
            PlayerKey::Left => self.send(PlayerIntent::Back, now),
            PlayerKey::Right => self.send(PlayerIntent::Forward, now),
            PlayerKey::Up | PlayerKey::Down => {
                self.volume_step(if key == PlayerKey::Up { 5 } else { -5 }, now)
            }
            PlayerKey::Char(ch) => {
                let tracks = self.vm.tracks();
                match ch.to_ascii_lowercase() {
                    'm' => self.toggle_mute(now),
                    't' if self.desk() => {
                        self.send(PlayerIntent::Layer(Some(PlayerLayer::Tracks)), now)
                    }
                    'f' if self.desk() => self.fs_request = true,
                    'f' => {
                        let on = !self.fill;
                        self.set_fill(on, now);
                    }
                    'g' => self.delay(true, -1, tracks.subtitle_delay_ms, now),
                    'h' => self.delay(true, 1, tracks.subtitle_delay_ms, now),
                    'j' => self.delay(false, -1, tracks.audio_delay_ms, now),
                    'k' => self.delay(false, 1, tracks.audio_delay_ms, now),
                    _ => return false,
                }
            }
        }
        true
    }

    fn volume_step(&mut self, step: i32, now: f64) {
        // From a mute the arrow counts up from 0 (`volumeLevel`), and the key wakes the controls.
        self.volume = (self.volume + step).clamp(0, 100);
        self.vol_until = now / 1000.0 + 1.2;
        self.send(PlayerIntent::Volume(self.volume), now);
        self.send(PlayerIntent::WakeControls, now);
        self.persist_volume();
    }

    /// Arrow, Enter or Esc on the focus engine (tv remote, desktop Tab): the Siri-remote rules of the tvOS player.
    pub fn nav_key(&mut self, key: NavKey, down: bool, now: f64) -> swiftly_ui::Outcome {
        use swiftly_ui::{Dir, Outcome};
        if self.menu_c.is_open() {
            if down {
                let k = match key {
                    NavKey::Escape => Some(MenuKey::Escape),
                    NavKey::Enter => Some(MenuKey::Enter),
                    NavKey::Arrow(Dir::Up) => Some(MenuKey::Up),
                    NavKey::Arrow(Dir::Down) => Some(MenuKey::Down),
                    _ => None,
                };
                if let Some(k) = k {
                    self.menu_key(k, now);
                }
            }
            return Outcome::None;
        }
        let tv = self.env.idiom == swiftly_ui::Idiom::Tv;
        let c = self.vm.controls();
        if key == NavKey::Escape {
            if down {
                self.back(now);
            }
            return Outcome::None;
        }
        if tv && down {
            if !c.visible && c.layer.is_none() {
                // A key with the controls away: up opens them on the buttons, Select runs the offer, anything else wakes.
                let offering = self.vm.offer().view != OfferView::Hidden;
                match key {
                    NavKey::Enter if offering && self.ui.focused() != Some(focus_id("idle")) => {}
                    NavKey::Enter if offering => {
                        self.send(PlayerIntent::PressOffering, now);
                        return Outcome::None;
                    }
                    NavKey::Arrow(Dir::Up) => {
                        self.send(PlayerIntent::WakeControls, now);
                        self.sync();
                        let _ = self.ui.frame(now);
                        self.ui.set_focus(focus_id("tracks"), now);
                        self.seen_visible = true;
                        return Outcome::None;
                    }
                    _ => {
                        self.send(PlayerIntent::WakeControls, now);
                        return Outcome::None;
                    }
                }
            } else if c.visible {
                self.send(PlayerIntent::WakeControls, now);
            }
            if c.layer.is_none() && self.ui.focused() == Some(focus_id("bar")) {
                match key {
                    NavKey::Arrow(Dir::Left) => {
                        self.send(PlayerIntent::Back, now);
                        return Outcome::None;
                    }
                    NavKey::Arrow(Dir::Right) => {
                        self.send(PlayerIntent::Forward, now);
                        return Outcome::None;
                    }
                    NavKey::Enter => {
                        self.send(PlayerIntent::TogglePlay, now);
                        return Outcome::None;
                    }
                    _ => {}
                }
            }
        }
        self.sync();
        let out = self.ui.nav_key(key, down, now);
        let _ = self.drain(now);
        out
    }

    /// Typed characters (desktop letter shortcuts).
    pub fn type_text(&mut self, s: &str, now: f64) {
        for ch in s.chars() {
            let _ = self.key(PlayerKey::Char(ch), now);
        }
    }

    /// The subtitle surface seam: the UI draws text cues itself.
    pub fn surface_name(&self) -> &'static str {
        let _ = &self.surface;
        let _ = &self.glyphs;
        "test pattern"
    }
}

/// Wire-check: maps a map of menu keys (used by the focus-plan test).
pub fn layer_keys(tracks: &TracksPart) -> HashMap<&'static str, Vec<String>> {
    let mut m = HashMap::new();
    m.insert(
        "audio",
        tracks
            .audio
            .iter()
            .map(|t| format!("audio:{}", t.index))
            .collect(),
    );
    m.insert(
        "sub",
        tracks
            .subtitles
            .iter()
            .map(|t| format!("sub:{}", t.index))
            .collect(),
    );
    m
}

/// Clippy helper so the unused import of `OfferPart` stays meaningful for readers of the parts.
pub fn offer_visible(o: &OfferPart) -> bool {
    o.view != OfferView::Hidden
}

fn base() -> swiftly_design::TextStyle {
    swiftly_design::TextStyle {
        size: 15.0,
        weight: 400,
        tracking: 0.0,
        uppercase: false,
    }
}

#[cfg(test)]
mod layer_row_tests {
    use super::*;
    use swiftly_layout::Size;
    use swiftly_ui::a11y::Role;

    /// "Unbegrenzt" in the 200 pt "Qualität" column is drawn in full: the text gets its natural width.
    #[test]
    fn a_layer_row_gives_its_text_the_room_of_the_column() {
        let cx = Cx::deterministic();
        let env = Env::new(Size::new(600.0, 300.0), 1.0, swiftly_ui::Idiom::Desktop);
        let style = swiftly_design::TextStyle {
            size: 15.0,
            weight: 400,
            ..base()
        };
        let natural = cx
            .measure_text(
                "Unbegrenzt",
                &swiftly_text::TextStyle::from(style),
                Some(1),
                swiftly_layout::Proposal::NIL,
            )
            .w;
        let text = txt(&cx, "Unbegrenzt", style, colour::FONT_QUIET, Some(1));
        let row = row_layout(Node::fixed(13.0, 13.0), text).frame(
            Some(200.0),
            None,
            Alignment::TOP_LEADING,
        );
        let ui = Ui::new(move |_: &(), _: &Env, _: &Cx| row.clone(), (), env, cx);
        let nodes = ui.a11y_nodes();
        let shown = nodes
            .iter()
            .flat_map(|n| n.walk())
            .find(|n| n.role == Role::Text && n.label == "Unbegrenzt")
            .and_then(|n| n.bounds)
            .expect("the text is in the tree");
        assert!(
            shown[2] >= natural - 0.5,
            "the text is {} pt wide, it needs {natural}",
            shown[2]
        );
    }
}
