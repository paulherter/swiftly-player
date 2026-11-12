//! The exported player view model (`swiftly_vm::PlayerVm`) and the engine seam the Apple
//! players implement. Commands to the engine return `()` (the two that answer, `select_audio`
//! and `select_subtitle`, answer at once); everything else the engine learns comes back as a
//! `PlayerEngineEvent` through `PlayerVm::engine_event`. The core ticks itself (every 250 ms on
//! the runtime) and reports progress to the server through the host's HTTP.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use swiftly_jellyfin::{
    ClientConfig, JellyfinClient, PendingReport, PlayMethod, PostReportRules, ReportPlan, Session,
    TrackIndices,
};
use swiftly_model::MediaStream;
use swiftly_playback::engine::{
    self as eng, AudioDelivery, CueBody, EngineEvent, EngineState, PipCmd, Route,
};
use swiftly_playback::player_state::EngineRequest;
use swiftly_playback::sections::{Art, Segment};
use swiftly_playback::track_mapping::SubtitleFile;
use swiftly_playback::trickplay::Trickplay;
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_rules::chapter::Chapter;
use swiftly_rules::delay::Delay;
use swiftly_rules::episodes_switch::StopLock;
use swiftly_vm::{
    AccountRef, AfterPlay, Change, Clock, GroupHook, Host, NextEpisode, Nudge, OfferView,
    PendingSink, Phase, PlayerEffect, PlayerIntent as VmIntent, PlayerLayer, PlayerPrefs,
    PlayerSpec, Quality, REPORT_DEADLINE, ReportDesk, ReportKind, ReportMessage, ReportOutcome,
    Shared, SystemClock, TrackMemoryStore,
};

use crate::core::Platform;
use crate::error::CoreError;
use crate::library::TextKeys;
use crate::stores::KeyValueStore;
use crate::transport::ForeignTransport;

#[uniffi::remote(Record)]
pub struct PlayerPrefs {
    pub back_seconds: i64,
    pub forward_seconds: i64,
    pub auto_skip: bool,
    pub next_automatic: bool,
    pub network_favorable: bool,
    pub direct_play: bool,
    pub bitrate_limit: i64,
    pub convert_allowed: bool,
}

// ---- engine seam ---------------------------------------------------------------------------

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PlayerHeader {
    pub name: String,
    pub value: String,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PlayerExternalSubtitle {
    pub url: String,
    pub name: Option<String>,
    pub language: Option<String>,
    pub is_forced: bool,
    pub format_hint: Option<String>,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayerBuffer {
    Normal,
    Bad,
    VeryBad,
}

/// Everything an engine needs to open a title.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerLoad {
    pub url: String,
    pub headers: Vec<PlayerHeader>,
    /// `None`: from the beginning.
    pub start: Option<f64>,
    pub audio_server_index: Option<i64>,
    /// `-1` none.
    pub subtitle_server_index: i64,
    pub external_subtitles: Vec<PlayerExternalSubtitle>,
    pub software_decode: bool,
    pub buffer_level: PlayerBuffer,
    pub frame_rate_match: bool,
}

#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq)]
pub struct PlayerRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayerSubtitleRoute {
    Cues,
    EngineDrawn,
    Unsupported,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayerPip {
    Start,
    Stop,
    Refresh,
}

/// The thin driver behind the player (AetherDriver, AVPlayer, VLC on Apple). Commands return
/// at once; results come back as events.
#[uniffi::export(with_foreign)]
pub trait PlayerEngine: Send + Sync {
    fn load(&self, request: PlayerLoad);
    fn play(&self);
    fn pause(&self);
    fn seek(&self, seconds: f64);
    fn set_rate(&self, tempo: f32);
    fn set_volume(&self, percent: u8);
    fn set_audio_delay(&self, milliseconds: i32);
    /// Subtitle delay in milliseconds (positive: later); the host shifts the cues it draws.
    fn set_subtitle_delay(&self, milliseconds: i32);
    /// `false` if the engine has no such track.
    fn select_audio(&self, server_index: i32) -> bool;
    /// `-1` off.
    fn select_subtitle(&self, server_index: i32) -> PlayerSubtitleRoute;
    fn set_fill(&self, on: bool);
    fn place(&self, rect: PlayerRect);
    fn stop(&self, reset_display: bool);
    fn pip(&self, command: PlayerPip);
}

struct EngineAdapter(Arc<dyn PlayerEngine>, crate::forwarder::ForwarderSlot);

impl eng::PlaybackEngine for EngineAdapter {
    fn load(&self, r: eng::EngineLoad) {
        self.0.load(PlayerLoad {
            url: crate::forwarder::rewritten(&self.1, &r.url),
            headers: r
                .headers
                .into_iter()
                .map(|(name, value)| PlayerHeader { name, value })
                .collect(),
            start: r.start,
            audio_server_index: r.audio_server_index,
            subtitle_server_index: r.subtitle_server_index,
            external_subtitles: r
                .external_subtitles
                .into_iter()
                .map(|s| PlayerExternalSubtitle {
                    url: crate::forwarder::rewritten(&self.1, &s.url),
                    name: s.name,
                    language: s.language,
                    is_forced: s.is_forced,
                    format_hint: s.format_hint,
                })
                .collect(),
            software_decode: r.software_decode,
            buffer_level: match r.buffer_level {
                BufferLevel::Normal => PlayerBuffer::Normal,
                BufferLevel::Bad => PlayerBuffer::Bad,
                BufferLevel::VeryBad => PlayerBuffer::VeryBad,
            },
            frame_rate_match: r.frame_rate_match,
        });
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
    fn set_subtitle_delay(&self, milliseconds: i32) {
        self.0.set_subtitle_delay(milliseconds);
    }
    fn select_audio(&self, server_index: i32) -> bool {
        self.0.select_audio(server_index)
    }
    fn select_subtitle(&self, server_index: i32) -> eng::SubtitleRoute {
        match self.0.select_subtitle(server_index) {
            PlayerSubtitleRoute::Cues => eng::SubtitleRoute::Cues,
            PlayerSubtitleRoute::EngineDrawn => eng::SubtitleRoute::EngineDrawn,
            PlayerSubtitleRoute::Unsupported => eng::SubtitleRoute::Unsupported,
        }
    }
    fn set_fill(&self, on: bool) {
        self.0.set_fill(on);
    }
    fn place(&self, r: eng::Rect) {
        self.0.place(PlayerRect {
            x: r.x,
            y: r.y,
            width: r.width,
            height: r.height,
        });
    }
    fn stop(&self, reset_display: bool) {
        self.0.stop(reset_display);
    }
    fn pip(&self, command: PipCmd) {
        self.0.pip(match command {
            PipCmd::Start => PlayerPip::Start,
            PipCmd::Stop => PlayerPip::Stop,
            PipCmd::Refresh => PlayerPip::Refresh,
        });
    }
}

// ---- events from the engine ----------------------------------------------------------------

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum PlayerEngineState {
    Idle,
    Loading,
    Playing,
    Paused,
    Seeking,
    Ended,
    Error {
        message: String,
        kind: Option<String>,
    },
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerTrack {
    pub id: i64,
    pub codec: String,
    pub language: Option<String>,
    pub name: String,
    pub channels: i64,
    pub is_default: bool,
    pub is_forced: bool,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum PlayerCueBody {
    Text {
        text: String,
    },
    Rich {
        runs: Vec<String>,
    },
    Image {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        canvas_width: f64,
        canvas_height: f64,
    },
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerCue {
    pub id: i64,
    pub start: f64,
    pub end: f64,
    pub body: PlayerCueBody,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayerRoute {
    AirPlay,
    Cast,
    Local,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum PlayerEngineEvent {
    State {
        state: PlayerEngineState,
    },
    FirstFrame,
    Clock {
        position: f64,
        source_time: f64,
    },
    Duration {
        seconds: f64,
    },
    VideoSize {
        width: f64,
        height: f64,
    },
    Tracks {
        audio: Vec<PlayerTrack>,
        subtitles: Vec<PlayerTrack>,
        active_audio: Option<i64>,
        active_subtitle: Option<i64>,
    },
    Cues {
        cues: Vec<PlayerCue>,
    },
    /// `dropped`: the source has sound and none of it could be delivered.
    AudioDelivery {
        dropped: bool,
    },
    Route {
        route: PlayerRoute,
    },
    PipPossible {
        on: bool,
    },
    PipActive {
        on: bool,
    },
    PipRestoreUi,
    DisplayModeSwitch,
    LoadFinished {
        attempt: u32,
    },
    LoadFailed {
        attempt: u32,
        message: String,
        kind: Option<String>,
    },
    StartWatchdog {
        attempt: u32,
    },
    SeekLanded {
        target: f64,
    },
}

fn track(t: PlayerTrack) -> eng::EngineTrack {
    eng::EngineTrack {
        id: t.id,
        codec: t.codec,
        language: t.language,
        name: t.name,
        channels: t.channels,
        is_default: t.is_default,
        is_forced: t.is_forced,
    }
}

impl From<PlayerEngineEvent> for EngineEvent {
    fn from(e: PlayerEngineEvent) -> Self {
        match e {
            PlayerEngineEvent::State { state } => Self::State(match state {
                PlayerEngineState::Idle => EngineState::Idle,
                PlayerEngineState::Loading => EngineState::Loading,
                PlayerEngineState::Playing => EngineState::Playing,
                PlayerEngineState::Paused => EngineState::Paused,
                PlayerEngineState::Seeking => EngineState::Seeking,
                PlayerEngineState::Ended => EngineState::Ended,
                PlayerEngineState::Error { message, kind } => EngineState::Error { message, kind },
            }),
            PlayerEngineEvent::FirstFrame => Self::FirstFrame,
            PlayerEngineEvent::Clock {
                position,
                source_time,
            } => Self::Clock {
                position,
                source_time,
            },
            PlayerEngineEvent::Duration { seconds } => Self::Duration(seconds),
            PlayerEngineEvent::VideoSize { width, height } => Self::VideoSize { width, height },
            PlayerEngineEvent::Tracks {
                audio,
                subtitles,
                active_audio,
                active_subtitle,
            } => Self::Tracks {
                audio: audio.into_iter().map(track).collect(),
                subtitles: subtitles.into_iter().map(track).collect(),
                active_audio,
                active_subtitle,
            },
            PlayerEngineEvent::Cues { cues } => Self::Cues(
                cues.into_iter()
                    .map(|c| eng::Cue {
                        id: c.id,
                        start: c.start,
                        end: c.end,
                        body: match c.body {
                            PlayerCueBody::Text { text } => CueBody::Text(text),
                            PlayerCueBody::Rich { runs } => CueBody::Rich(runs),
                            PlayerCueBody::Image {
                                x,
                                y,
                                width,
                                height,
                                canvas_width,
                                canvas_height,
                            } => CueBody::Image {
                                position: eng::Rect {
                                    x,
                                    y,
                                    width,
                                    height,
                                },
                                canvas: (canvas_width, canvas_height),
                            },
                        },
                    })
                    .collect(),
            ),
            PlayerEngineEvent::AudioDelivery { dropped } => Self::AudioDelivery(if dropped {
                AudioDelivery::DroppedNoPipeline
            } else {
                AudioDelivery::Ok
            }),
            PlayerEngineEvent::Route { route } => Self::Route(match route {
                PlayerRoute::AirPlay => Route::AirPlay,
                PlayerRoute::Cast => Route::Cast,
                PlayerRoute::Local => Route::Local,
            }),
            PlayerEngineEvent::PipPossible { on } => Self::PipPossible(on),
            PlayerEngineEvent::PipActive { on } => Self::PipActive(on),
            PlayerEngineEvent::PipRestoreUi => Self::PipRestoreUi,
            PlayerEngineEvent::DisplayModeSwitch => Self::DisplayModeSwitch,
            PlayerEngineEvent::LoadFinished { attempt } => Self::LoadFinished { attempt },
            PlayerEngineEvent::LoadFailed {
                attempt,
                message,
                kind,
            } => Self::LoadFailed {
                attempt,
                message,
                kind,
            },
            PlayerEngineEvent::StartWatchdog { attempt } => Self::StartWatchdog { attempt },
            PlayerEngineEvent::SeekLanded { target } => Self::SeekLanded { target },
        }
    }
}

// ---- what a title needs --------------------------------------------------------------------

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayerMethod {
    DirectPlay,
    DirectStream,
    Transcode,
}

/// One stream of the chosen source (the track panel and the track rules read them).
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PlayerStream {
    pub index: i64,
    /// `Video`, `Audio` or `Subtitle`.
    pub kind: String,
    pub language: Option<String>,
    pub codec: Option<String>,
    pub channels: Option<i64>,
    pub title: Option<String>,
    pub is_default: bool,
    pub is_forced: bool,
    pub is_external: bool,
    pub is_hearing_impaired: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PlayerNext {
    pub id: String,
    pub title: String,
}

/// A playable title: the plan (address, headers, session ids) and the starting tracks.
#[derive(uniffi::Record, Clone, Debug)]
pub struct PlayerStart {
    pub item_id: String,
    pub title: String,
    pub play_session_id: Option<String>,
    pub media_source_id: Option<String>,
    pub method: PlayerMethod,
    pub url: String,
    pub headers: Vec<PlayerHeader>,
    pub streams: Vec<PlayerStream>,
    pub runtime: f64,
    pub start_at: f64,
    pub audio_index: Option<i64>,
    pub subtitle_index: i64,
    pub next: Option<PlayerNext>,
    pub series_id: Option<String>,
    /// Key of the track memory; `None` remembers nothing.
    pub track_title: Option<String>,
    pub downloaded: bool,
    pub software_decode: bool,
    pub frame_rate_match: bool,
    /// How much the engine buffers before the picture appears (`pufferstufe`).
    pub buffer_level: PlayerBuffer,
    /// External subtitle files (Jellyfin stream index, address, MD5 of the address).
    pub subtitle_files: Vec<PlayerSubtitleFile>,
    /// First engine track id given to external files.
    pub external_track_id_base: i64,
    /// The chosen version as the server's `MediaSource` JSON (`PlayReady.source_json`). The track rules read the
    /// whole streams from it (`IsOriginal`, `IsExternal`, titles, Dolby Vision fields, `DisplayTitle`), which
    /// `streams` cannot carry; without it (or when it does not parse) the player falls back to `streams`.
    /// `PlayerVm::source_json` hands it back.
    #[uniffi(default = None)]
    pub source_json: Option<String>,
}

/// The streams the rules read: the whole ones of the raw source if there are some, else the reduced list.
fn streams_of(source_json: Option<&str>, reduced: Vec<PlayerStream>) -> Vec<MediaStream> {
    let whole = source_json
        .and_then(|j| serde_json::from_str::<swiftly_model::MediaSource>(j).ok())
        .and_then(|m| m.media_streams)
        .filter(|v| !v.is_empty());
    whole.unwrap_or_else(|| {
        reduced
            .into_iter()
            .map(|t| MediaStream {
                index: Some(t.index),
                type_: Some(t.kind),
                language: t.language,
                codec: t.codec,
                channels: t.channels,
                title: t.title,
                is_default: Some(t.is_default),
                is_forced: Some(t.is_forced),
                is_external: Some(t.is_external),
                is_hearing_impaired: Some(t.is_hearing_impaired),
                ..MediaStream::default()
            })
            .collect()
    })
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PlayerSubtitleFile {
    pub index: i64,
    pub address: String,
    pub attribute: Option<String>,
}

/// Kind of an intro/outro section.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayerSectionKind {
    Unknown,
    Ads,
    Preview,
    LookBack,
    Credits,
    Intro,
}

/// A section of the title in seconds (`MediaSegments`).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerSection {
    pub kind: PlayerSectionKind,
    pub from: f64,
    pub until: f64,
}

/// One width of the trickplay sheets (`Trickplay`); the host fetches `/Trickplay/{width}/{n}.jpg`.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PlayerTrickplay {
    pub width: i64,
    pub height: i64,
    pub tiles_wide: i64,
    pub tiles_up: i64,
    pub count: i64,
    pub interval: i64,
}

/// SyncPlay seam the host implements: what the user's input means in a group.
#[uniffi::export(with_foreign)]
pub trait PlayerGroupHook: Send + Sync {
    /// Play/pause was pressed; `running` is the state before.
    fn toggle(&self, running: bool);
    /// A seek was asked for.
    fn jump(&self, to: f64);
}

struct GroupAdapter(Arc<dyn PlayerGroupHook>);

impl GroupHook for GroupAdapter {
    fn toggle(&self, running: bool) {
        self.0.toggle(running);
    }
    fn jump(&self, to: f64) {
        self.0.jump(to);
    }
}

/// Lets the vm hold either reporter (Jellyfin or Plex).
struct AnyReporter(Arc<dyn swiftly_vm::Reporter>);

impl swiftly_vm::Reporter for AnyReporter {
    fn report(&self, message: swiftly_vm::ReportMessage) {
        self.0.report(message);
    }
}

impl From<PlayerSection> for Segment {
    fn from(s: PlayerSection) -> Self {
        Segment::new(
            match s.kind {
                PlayerSectionKind::Unknown => Art::Unknown,
                PlayerSectionKind::Ads => Art::Ads,
                PlayerSectionKind::Preview => Art::Preview,
                PlayerSectionKind::LookBack => Art::LookBack,
                PlayerSectionKind::Credits => Art::Credits,
                PlayerSectionKind::Intro => Art::IntroSegment,
            },
            s.from,
            s.until,
        )
    }
}

impl From<PlayerStart> for PlayerSpec {
    fn from(s: PlayerStart) -> Self {
        let headers: Vec<(String, String)> =
            s.headers.into_iter().map(|h| (h.name, h.value)).collect();
        Self {
            item_id: s.item_id.clone(),
            title: s.title,
            plan: ReportPlan {
                play_session_id: s.play_session_id,
                media_source_id: s.media_source_id,
                method: match s.method {
                    PlayerMethod::DirectPlay => PlayMethod::DirectPlay,
                    PlayerMethod::DirectStream => PlayMethod::DirectStream,
                    PlayerMethod::Transcode => PlayMethod::Transcode,
                },
            },
            request: EngineRequest {
                item_id: s.item_id,
                streams: streams_of(s.source_json.as_deref(), s.streams),
                runtime: s.runtime,
                subtitle_files: s
                    .subtitle_files
                    .into_iter()
                    .map(|f| SubtitleFile {
                        index: f.index,
                        address: f.address,
                        attribute: f.attribute,
                    })
                    .collect(),
                url: s.url,
                headers,
                software_decode: s.software_decode,
                buffer_level: match s.buffer_level {
                    PlayerBuffer::Normal => BufferLevel::Normal,
                    PlayerBuffer::Bad => BufferLevel::Bad,
                    PlayerBuffer::VeryBad => BufferLevel::VeryBad,
                },
                frame_rate_match: s.frame_rate_match,
                external_track_id_base: s.external_track_id_base,
            },
            start_at: s.start_at,
            audio_index: s.audio_index,
            subtitle_index: s.subtitle_index,
            next: s.next.map(|n| NextEpisode {
                id: n.id,
                title: n.title,
            }),
            series_id: s.series_id,
            track_title: s.track_title,
            downloaded: s.downloaded,
        }
    }
}

// ---- intents, parts, effects ---------------------------------------------------------------

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayerPanel {
    Tracks,
    Episodes,
    Settings,
}

impl From<PlayerPanel> for PlayerLayer {
    fn from(p: PlayerPanel) -> Self {
        match p {
            PlayerPanel::Tracks => Self::Tracks,
            PlayerPanel::Episodes => Self::Episodes,
            PlayerPanel::Settings => Self::Settings,
        }
    }
}

fn panel(l: PlayerLayer) -> PlayerPanel {
    match l {
        PlayerLayer::Tracks => PlayerPanel::Tracks,
        PlayerLayer::Episodes => PlayerPanel::Episodes,
        PlayerLayer::Settings => PlayerPanel::Settings,
    }
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum PlayerIntent {
    TogglePlay,
    SeekTo {
        seconds: f64,
    },
    Forward,
    Back,
    ScrubStart,
    ScrubMove {
        seconds: f64,
    },
    ScrubEnd {
        seconds: f64,
    },
    ToggleControls,
    WakeControls,
    Panel {
        panel: Option<PlayerPanel>,
    },
    SelectAudio {
        index: i64,
    },
    /// `-1` off.
    SelectSubtitle {
        index: i64,
    },
    SubtitleDelay {
        milliseconds: i64,
    },
    AudioDelay {
        milliseconds: i64,
    },
    Tempo {
        tempo: f32,
    },
    Volume {
        percent: i32,
    },
    Fill {
        on: bool,
    },
    Sleep {
        minutes: Option<u32>,
    },
    PressOffering,
    /// Esc/Menu: closes the card, then a panel, then the controls, then the player.
    Dismiss,
    NextEpisode,
    Pip {
        command: PlayerPip,
    },
    Close,
    /// `None`: Direct Play; `Some(n)`: a cap of n Mbit/s.
    Quality {
        limit: Option<i64>,
    },
    Retry,
    EnginePlay,
    EnginePause,
    /// A rebuild after a network change is running: show the last good position.
    Restoring {
        on: bool,
    },
    EngineSeek {
        seconds: f64,
    },
}

impl From<PlayerIntent> for VmIntent {
    fn from(i: PlayerIntent) -> Self {
        match i {
            PlayerIntent::TogglePlay => Self::TogglePlay,
            PlayerIntent::SeekTo { seconds } => Self::SeekTo(seconds),
            PlayerIntent::Forward => Self::Forward,
            PlayerIntent::Back => Self::Back,
            PlayerIntent::ScrubStart => Self::ScrubStart,
            PlayerIntent::ScrubMove { seconds } => Self::ScrubMove(seconds),
            PlayerIntent::ScrubEnd { seconds } => Self::ScrubEnd(seconds),
            PlayerIntent::ToggleControls => Self::ToggleControls,
            PlayerIntent::WakeControls => Self::WakeControls,
            PlayerIntent::Panel { panel } => Self::Layer(panel.map(Into::into)),
            PlayerIntent::SelectAudio { index } => Self::SelectAudio(index),
            PlayerIntent::SelectSubtitle { index } => Self::SelectSubtitle(index),
            PlayerIntent::SubtitleDelay { milliseconds } => {
                Self::SubtitleDelay(Delay::from_milliseconds(milliseconds))
            }
            PlayerIntent::AudioDelay { milliseconds } => {
                Self::AudioDelay(Delay::from_milliseconds(milliseconds))
            }
            PlayerIntent::Tempo { tempo } => Self::Tempo(tempo),
            PlayerIntent::Volume { percent } => Self::Volume(percent),
            PlayerIntent::Fill { on } => Self::Fill(on),
            PlayerIntent::Sleep { minutes } => Self::Sleep(minutes),
            PlayerIntent::PressOffering => Self::PressOffering,
            PlayerIntent::Dismiss => Self::Back2,
            PlayerIntent::NextEpisode => Self::NextEpisode,
            PlayerIntent::Pip { command } => Self::Pip(match command {
                PlayerPip::Start => PipCmd::Start,
                PlayerPip::Stop => PipCmd::Stop,
                PlayerPip::Refresh => PipCmd::Refresh,
            }),
            PlayerIntent::Close => Self::Close,
            PlayerIntent::Quality { limit } => Self::Quality(limit),
            PlayerIntent::Retry => Self::Retry,
            PlayerIntent::EnginePlay => Self::EnginePlay,
            PlayerIntent::EnginePause => Self::EnginePause,
            PlayerIntent::Restoring { on } => Self::Restoring(on),
            PlayerIntent::EngineSeek { seconds } => Self::EngineSeek(seconds),
        }
    }
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayerPhase {
    Loading,
    Playing,
    Paused,
    Ended,
    Failed,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PlayerFailure {
    pub header: String,
    pub text: String,
    pub primary: String,
    pub quiet: String,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerTransport {
    pub phase: PlayerPhase,
    pub position: f64,
    pub running: bool,
    pub leap: Option<f64>,
    pub duration: f64,
    pub buffering: bool,
    pub tempo: f32,
    pub picture_shown: bool,
    pub chapter: Option<String>,
    pub hint: Option<String>,
    pub error: Option<String>,
    pub failure: Option<PlayerFailure>,
    pub subtitle: Option<String>,
    pub pip_possible: bool,
    pub pip_active: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PlayerJump {
    pub bearing: i32,
    pub seconds: i64,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PlayerPreview {
    pub sheet: i64,
    pub x: i64,
    pub y: i64,
    pub width: i64,
    pub height: i64,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PlayerQuality {
    pub direct_play: bool,
    pub limit: i64,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerControls {
    pub visible: bool,
    pub panel: Option<PlayerPanel>,
    pub scrubbing: bool,
    pub jump: Option<PlayerJump>,
    pub preview: Option<PlayerPreview>,
    pub sleep_minutes: Option<u32>,
    pub back_seconds: i64,
    pub forward_seconds: i64,
    pub quality: Option<PlayerQuality>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PlayerTrackRow {
    pub index: i64,
    pub label: String,
    pub selected: bool,
    /// A forced subtitle (`TrackName.erzwungen` of the old Android core); `false` for audio.
    pub forced: bool,
    /// A subtitle file next to the video (`datei`); `false` for audio.
    pub file: bool,
    /// A subtitle for the hard of hearing (`hoergeschaedigt`); `false` for audio.
    pub hearing_impaired: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PlayerTracks {
    pub audio: Vec<PlayerTrackRow>,
    pub subtitles: Vec<PlayerTrackRow>,
    pub subtitles_off: bool,
    pub audio_delay_ms: i64,
    pub subtitle_delay_ms: i64,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum PlayerOffer {
    Hidden,
    Button {
        label: String,
        next_episode: bool,
    },
    Card {
        title: String,
        share: f64,
        seconds_left: i64,
    },
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum PlayerEffectOut {
    /// Leave the screen.
    Close,
    /// Fetch the plan of this episode, then `load_title`. The old stop is reported already.
    StartEpisode {
        id: String,
        from_card: bool,
        since: f64,
    },
    /// A subtitle on a transcoded stream: `playPlanOnly(..., subtitle)`, then `loadTitle` at `since`, starting on
    /// `subtitle` (`-1` off). The old stop is reported already.
    ReloadForSubtitle {
        id: String,
        subtitle: i64,
        since: f64,
    },
    /// Write `alwaysDirectPlay` / `bitratesLimit`.
    QualityChosen {
        direct_play: bool,
        limit: i64,
    },
    ForgetPrepared,
    /// Rating (`rating`) or Discord prompt after the player is closed.
    Nudge {
        rating: bool,
    },
    PrepareNext {
        id: String,
    },
    HandOver {
        subtitle: i64,
        reason: String,
    },
    /// The stalled stream was reopened at the same position; the engine got its load already.
    StreamRebuilt {
        position: f64,
        paused: bool,
        reason: String,
    },
}

/// Bits of `Change.parts`.
#[uniffi::export]
pub fn part_player_transport() -> u32 {
    swiftly_vm::part::PLAYER_TRANSPORT
}
#[uniffi::export]
pub fn part_player_controls() -> u32 {
    swiftly_vm::part::PLAYER_CONTROLS
}
#[uniffi::export]
pub fn part_player_tracks() -> u32 {
    swiftly_vm::part::PLAYER_TRACKS
}
#[uniffi::export]
pub fn part_player_offer() -> u32 {
    swiftly_vm::part::PLAYER_OFFER
}

// ---- host pieces ---------------------------------------------------------------------------

/// Hand-chosen tracks per series or film, as JSON dictionaries in the host's store.
struct KvMemory(Arc<dyn KeyValueStore>);

impl TrackMemoryStore for KvMemory {
    fn load(&self, key: &str) -> HashMap<String, String> {
        self.0
            .get(format!("trackmemory.{key}"))
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }
    fn save(&self, key: &str, all: &HashMap<String, String>) {
        if let Ok(bytes) = serde_json::to_vec(all) {
            self.0.set(format!("trackmemory.{key}"), bytes);
        }
    }
}

/// A stop that did not get through: kept in the store so the position survives.
struct KvPending(Arc<dyn KeyValueStore>, Mutex<()>);

impl KvPending {
    const KEY: &'static str = "pending.reports";

    fn load(&self) -> Vec<PendingReport> {
        self.0
            .get(Self::KEY.to_owned())
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    fn store(&self, all: &[PendingReport]) {
        if let Ok(bytes) = serde_json::to_vec(all) {
            self.0.set(Self::KEY.to_owned(), bytes);
        }
    }
}

impl PendingSink for KvPending {
    /// One entry per title and account, the newest wins (`PostReportRules.record`).
    fn record(&self, report: PendingReport) {
        let _guard = self.1.lock().unwrap_or_else(PoisonError::into_inner);
        self.store(&PostReportRules::record(report, &self.load()));
    }

    /// `PostReportRules.overFetches`.
    fn forget(&self, item_id: &str, account: &str) {
        let _guard = self.1.lock().unwrap_or_else(PoisonError::into_inner);
        let all = self.load();
        let kept = PostReportRules::over_fetches(item_id, account, &all);
        if kept.len() != all.len() {
            self.store(&kept);
        }
    }
}

/// The report queue of one account: Jellyfin/Emby or Plex, kept stops in the host's store
/// (`pending.reports`, filed under `account_key`), six seconds for every report.
/// `runtime_seconds` is the title's length (Plex timelines carry it).
pub(crate) fn report_desk(
    transport: &ForeignTransport,
    host: &Host,
    kv: &Arc<dyn KeyValueStore>,
    account: &AccountRef,
    account_key: &str,
    runtime_seconds: f64,
) -> Result<ReportDesk, CoreError> {
    let pending =
        Arc::new(KvPending(Arc::clone(kv), Mutex::new(()))) as Arc<dyn swiftly_vm::PendingSink>;
    report_desk_with(
        transport,
        host,
        account,
        account_key,
        runtime_seconds,
        pending,
    )
}

/// The same queue with the caller's own place for stops that did not get through (the old Android core handed those to
/// the app, which stores them).
pub(crate) fn report_desk_with(
    transport: &ForeignTransport,
    host: &Host,
    account: &AccountRef,
    account_key: &str,
    runtime_seconds: f64,
    pending: Arc<dyn swiftly_vm::PendingSink>,
) -> Result<ReportDesk, CoreError> {
    let config = ClientConfig::new(&account.device_id, &host.device_name, &host.client_version)
        .kind(account.server_kind);
    let client = JellyfinClient::new(
        Shared(Arc::new(transport.clone())),
        &account.base_url,
        config,
    )?;
    client.set_session(Some(Session {
        access_token: account.token.clone(),
        user_id: account.user_id.clone(),
        user_name: String::new(),
        server_url: account.base_url.clone(),
        kind: account.server_kind,
    }));
    let spawner = Arc::clone(&host.spawner);
    let clock = Arc::new(SystemClock) as Arc<dyn Clock>;
    let plex = swiftly_vm::plex_client_for(&Arc::new(transport.clone()), host, account)
        .map_err(CoreError::from)?;
    let desk = if let Some(plex) = plex {
        // Plex reports its timeline; the length is in milliseconds.
        let duration_ms = (runtime_seconds > 0.0).then_some((runtime_seconds * 1000.0) as i64);
        ReportDesk::plex(plex, account_key, duration_ms, spawner, clock, pending)
    } else {
        ReportDesk::jellyfin(Arc::new(client), account_key, spawner, clock, pending)
    };
    Ok(desk.with_deadline(Arc::new(crate::search::TokioSleeper), REPORT_DEADLINE))
}

/// What became of a report the host awaited.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayReportOutcome {
    Sent,
    Failed,
    TimedOut,
    Discarded,
}

/// How the title is played, for the reports (`PlaybackPlan` of the old screens).
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PlayReportPlan {
    pub play_session_id: Option<String>,
    pub media_source_id: Option<String>,
    pub method: PlayerMethod,
    /// The chosen source's length in milliseconds (`plan.source?.runTimeTicks / 10_000`); Plex
    /// timelines carry it.
    pub runtime_ms: Option<i64>,
}

/// **The report queue of the old player screens** (`AppModel.reportStart/Progress/Stopped`):
/// order, coalescing, a deadline per report, the stop lock, the awaited stop and the kept stops
/// of the plane, all in the core. One per signed-in account; the screens keep their
/// `VLCPlayerView` and call through `AppModel`.
#[derive(uniffi::Object)]
pub struct PlayReporter {
    desk: Arc<ReportDesk>,
}

impl PlayReporter {
    pub(crate) fn build(
        transport: &ForeignTransport,
        host: &Host,
        kv: &Arc<dyn KeyValueStore>,
        account: &AccountRef,
        account_key: &str,
    ) -> Result<Arc<Self>, CoreError> {
        Ok(Arc::new(Self {
            desk: Arc::new(report_desk(transport, host, kv, account, account_key, 0.0)?),
        }))
    }

    /// The queue a `PlayerVm` shares with the app's own reports (one stop lock, one order).
    pub(crate) fn shared_desk(&self) -> Arc<ReportDesk> {
        Arc::clone(&self.desk)
    }

    fn message(
        kind: ReportKind,
        item_id: String,
        plan: PlayReportPlan,
        seconds: f64,
        audio: Option<i64>,
        subtitle: Option<i64>,
    ) -> ReportMessage {
        ReportMessage {
            kind,
            item_id,
            plan: ReportPlan {
                play_session_id: plan.play_session_id,
                media_source_id: plan.media_source_id,
                method: match plan.method {
                    PlayerMethod::DirectPlay => PlayMethod::DirectPlay,
                    PlayerMethod::DirectStream => PlayMethod::DirectStream,
                    PlayerMethod::Transcode => PlayMethod::Transcode,
                },
            },
            seconds,
            tracks: TrackIndices { audio, subtitle },
            runtime_ms: plan.runtime_ms,
        }
    }
}

#[uniffi::export]
impl PlayReporter {
    /// `Sessions/Playing` (with the capabilities before it). Returns at once.
    pub fn start(
        &self,
        item_id: String,
        plan: PlayReportPlan,
        seconds: f64,
        audio: Option<i64>,
        subtitle: Option<i64>,
    ) {
        self.desk.enqueue(Self::message(
            ReportKind::Start,
            item_id,
            plan,
            seconds,
            audio,
            subtitle,
        ));
    }

    /// `Sessions/Playing/Progress`. `false`: dropped (the session already stopped). Returns at once.
    pub fn progress(
        &self,
        item_id: String,
        plan: PlayReportPlan,
        seconds: f64,
        paused: bool,
        audio: Option<i64>,
        subtitle: Option<i64>,
    ) -> bool {
        self.desk.enqueue(Self::message(
            ReportKind::Progress { paused },
            item_id,
            plan,
            seconds,
            audio,
            subtitle,
        ))
    }

    /// A progress the host waits for (the report when the app goes to the background): answered
    /// when it is through, replaced by a newer one (that one's result), or its deadline has passed.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn progress_and_wait(
        &self,
        item_id: String,
        plan: PlayReportPlan,
        seconds: f64,
        paused: bool,
        audio: Option<i64>,
        subtitle: Option<i64>,
    ) -> Result<PlayReportOutcome, CoreError> {
        let message = Self::message(
            ReportKind::Progress { paused },
            item_id,
            plan,
            seconds,
            audio,
            subtitle,
        );
        Ok(outcome_of(self.desk.report_and_wait(message).await))
    }

    /// May progress still be reported for this title and session?
    pub fn progress_allowed(&self, item_id: String, play_session_id: Option<String>) -> bool {
        self.desk
            .progress_allowed(&StopLock::key(&item_id, play_session_id.as_deref()))
    }

    /// `Sessions/Playing/Stopped`, answered when it is through or its deadline has passed. A stop
    /// that did not get through is kept for the next connection.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn stop(
        &self,
        item_id: String,
        plan: PlayReportPlan,
        seconds: f64,
    ) -> Result<PlayReportOutcome, CoreError> {
        let message = Self::message(ReportKind::Stop, item_id, plan, seconds, None, None);
        Ok(outcome_of(self.desk.report_and_wait(message).await))
    }
}

fn outcome_of(outcome: ReportOutcome) -> PlayReportOutcome {
    match outcome {
        ReportOutcome::Sent => PlayReportOutcome::Sent,
        ReportOutcome::Failed => PlayReportOutcome::Failed,
        ReportOutcome::TimedOut => PlayReportOutcome::TimedOut,
        ReportOutcome::Discarded => PlayReportOutcome::Discarded,
    }
}

type Vm = swiftly_vm::PlayerVm<EngineAdapter, AnyReporter>;

struct Inner {
    vm: Vm,
    epoch: Instant,
    /// The stream forwarder the engine's addresses go through, if the host attached one.
    forwarder: crate::forwarder::ForwarderSlot,
    /// The raw `MediaSource` of the title that plays now (`PlayerStart.source_json`).
    source: Mutex<Option<String>>,
}

impl PlayerVm {
    pub(crate) fn forwarder_slot(&self) -> &crate::forwarder::ForwarderSlot {
        &self.inner.forwarder
    }
}

impl Inner {
    fn now(&self) -> f64 {
        self.epoch.elapsed().as_secs_f64()
    }
}

/// The player of one title. Drop it (or `Close`) when the screen goes.
#[derive(uniffi::Object)]
pub struct PlayerVm {
    inner: Arc<Inner>,
}

impl PlayerVm {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn build(
        transport: &ForeignTransport,
        host: &Host,
        kv: &Arc<dyn KeyValueStore>,
        platform: &Arc<dyn Platform>,
        account: &AccountRef,
        account_key: &str,
        start: PlayerStart,
        prefs: PlayerPrefs,
        engine: Arc<dyn PlayerEngine>,
        shared: Option<Arc<ReportDesk>>,
    ) -> Result<Arc<Self>, CoreError> {
        let reporter: Arc<dyn swiftly_vm::Reporter> = match shared {
            Some(desk) => desk,
            None => Arc::new(report_desk(
                transport,
                host,
                kv,
                account,
                account_key,
                start.runtime,
            )?),
        };
        let epoch = Instant::now();
        let forwarder = crate::forwarder::ForwarderSlot::default();
        let source = Mutex::new(start.source_json.clone());
        let vm = swiftly_vm::PlayerVm::new(
            Arc::new(EngineAdapter(engine, forwarder.clone())),
            Arc::new(AnyReporter(reporter)),
            Arc::new(swiftly_vm::LabelWords::new(host.locale.clone())),
            prefs,
            start.into(),
            0.0,
        );
        vm.set_memory(Some(Arc::new(KvMemory(Arc::clone(kv)))));
        vm.set_after_play(Some(Arc::new(AfterPlay::new(
            Arc::new(TextKeys(Arc::clone(kv))),
            env!("CARGO_PKG_VERSION"),
            false,
        ))));
        platform.log("player: created".to_owned());
        let inner = Arc::new(Inner {
            vm,
            epoch,
            forwarder,
            source,
        });
        // The clock of the player: a display tick every 250 ms, a full tick on every second one.
        let weak = Arc::downgrade(&inner);
        host.spawner.spawn(Box::pin(async move {
            let mut n: u64 = 0;
            loop {
                tokio::time::sleep(Duration::from_millis(250)).await;
                let Some(inner) = weak.upgrade() else { break };
                n += 1;
                if n % 2 == 1 {
                    inner.vm.display_tick(inner.now());
                } else {
                    inner.vm.tick(inner.now());
                }
            }
        }));
        Ok(Arc::new(Self { inner }))
    }
}

#[uniffi::export]
impl PlayerVm {
    pub fn version(&self) -> u64 {
        self.inner.vm.version()
    }

    pub fn transport(&self) -> PlayerTransport {
        let t = self.inner.vm.transport();
        PlayerTransport {
            phase: match t.phase {
                Phase::Loading => PlayerPhase::Loading,
                Phase::Playing => PlayerPhase::Playing,
                Phase::Paused => PlayerPhase::Paused,
                Phase::Ended => PlayerPhase::Ended,
                Phase::Failed => PlayerPhase::Failed,
            },
            position: t.position,
            running: t.running,
            leap: t.leap,
            duration: t.duration,
            buffering: t.buffering,
            tempo: t.tempo,
            picture_shown: t.picture_shown,
            chapter: t.chapter,
            hint: t.hint,
            error: t.error,
            failure: t.failure.map(|f| PlayerFailure {
                header: f.header.to_owned(),
                text: f.text.to_owned(),
                primary: f.primary.to_owned(),
                quiet: f.quiet.to_owned(),
            }),
            subtitle: t.subtitle,
            pip_possible: t.pip.0,
            pip_active: t.pip.1,
        }
    }

    /// The finer lifecycle (opening, playing, restoring, switching, hand-over, failed ...); `transport().phase` is its coarse form.
    pub fn stage(&self) -> crate::state::PlayerStageState {
        self.inner.vm.stage().into()
    }

    /// Where the picture goes: this screen, the small window, AirPlay.
    pub fn surface(&self) -> crate::state::PlayerSurface {
        self.inner.vm.surface().into()
    }

    /// The host reports a surface change (small window, AirPlay taken/refused/back); returns the new surface.
    pub fn surface_event(
        &self,
        event: crate::state::PlayerSurfaceEvent,
    ) -> crate::state::PlayerSurface {
        self.inner.vm.surface_event(event.into()).into()
    }

    /// The audio went to an AirPlay device: the core decides (live title, picture on this screen, file fits).
    /// `source_json` is the `MediaSource` of the playing plan; `None` source JSON is `Ignore`.
    pub fn airplay_start(&self, source_json: String) -> crate::airplay::AirPlayStartDecision {
        use crate::airplay::AirPlayStartDecision as D;
        let Ok(source) = serde_json::from_str::<swiftly_model::MediaSource>(&source_json) else {
            return D::Ignore;
        };
        match self.inner.vm.airplay_start(&source) {
            swiftly_vm::AirPlayStart::Ignore => D::Ignore,
            swiftly_vm::AirPlayStart::Go { audio_track } => D::Go { audio_track },
            swiftly_vm::AirPlayStart::Refused(s) => D::Refused {
                verdict: crate::airplay::verdict_of(&s),
            },
        }
    }

    /// The next-episode card's state (replaces `cardsSwitch`/`cardsEpisode`/`cardsZoom`).
    pub fn next_card(&self) -> crate::state_more::NextCardState {
        self.inner.vm.next_card().into()
    }

    /// Feed the card an event; an illegal one changes nothing. Returns the new state.
    pub fn feed_next_card(
        &self,
        event: crate::state_more::NextCardEvent,
    ) -> crate::state_more::NextCardState {
        self.inner.vm.feed_next_card(event.into()).into()
    }

    /// The control bar's lifecycle at the host clock `now` (seconds); `controls().visible` stays the flag.
    pub fn controls_stage(&self, now: f64) -> crate::state::ControlsStage {
        self.inner.vm.controls_stage(now).into()
    }

    /// The seek chain at `now`; `controls().jump` is its overlay form.
    pub fn seek_chain(&self, now: f64) -> crate::state::SeekChainState {
        self.inner.vm.seek_chain(now).into()
    }

    pub fn controls(&self) -> PlayerControls {
        let c = self.inner.vm.controls();
        PlayerControls {
            visible: c.visible,
            panel: c.layer.map(panel),
            scrubbing: c.scrubbing,
            jump: c
                .jump_display
                .map(|(bearing, seconds)| PlayerJump { bearing, seconds }),
            preview: c.preview.map(|t| PlayerPreview {
                sheet: t.sheet,
                x: t.x,
                y: t.y,
                width: t.width,
                height: t.height,
            }),
            sleep_minutes: c.sleep_minutes,
            back_seconds: c.jump_seconds.0,
            forward_seconds: c.jump_seconds.1,
            quality: c
                .quality
                .map(|Quality { direct_play, limit }| PlayerQuality { direct_play, limit }),
        }
    }

    /// The title's `OriginalLanguage`: the audio track in that language gets the "(Original)" tag.
    pub fn set_original_language(&self, language: Option<String>) {
        self.inner.vm.set_original_language(language);
    }

    pub fn tracks(&self) -> PlayerTracks {
        let t = self.inner.vm.tracks();
        let rows = |v: Vec<swiftly_vm::TrackRow>| {
            v.into_iter()
                .map(|r| PlayerTrackRow {
                    index: r.index,
                    label: r.label,
                    selected: r.selected,
                    forced: r.forced,
                    file: r.file,
                    hearing_impaired: r.hearing_impaired,
                })
                .collect()
        };
        PlayerTracks {
            audio: rows(t.audio),
            subtitles: rows(t.subtitles),
            subtitles_off: t.subtitles_off,
            audio_delay_ms: t.audio_delay_ms,
            subtitle_delay_ms: t.subtitle_delay_ms,
        }
    }

    pub fn offer(&self) -> PlayerOffer {
        match self.inner.vm.offer().view {
            OfferView::Hidden => PlayerOffer::Hidden,
            OfferView::Button {
                label,
                next_episode,
                ..
            } => PlayerOffer::Button {
                label: label.to_owned(),
                next_episode,
            },
            OfferView::Card {
                title,
                share,
                seconds_left,
            } => PlayerOffer::Card {
                title,
                share,
                seconds_left,
            },
        }
    }

    /// Loads the title at its start position.
    pub fn start(&self) {
        self.inner.vm.start(self.inner.now());
    }

    /// This model replaces one that reloaded the title after a quality choice (call before `start`).
    pub fn after_quality_switch(&self) {
        self.inner.vm.after_quality_switch();
    }

    /// Replaces the title (after `StartEpisode`, once the host has the next plan).
    pub fn load_title(&self, start: PlayerStart) {
        *self
            .inner
            .source
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = start.source_json.clone();
        self.inner.vm.load_title(start.into(), self.inner.now());
    }

    /// The chosen version of the title that plays now as the server's `MediaSource` JSON, as the start gave it
    /// (`PlayerStart.source_json`); `None` if the start carried none (a copy on the device, an older host).
    pub fn source_json(&self) -> Option<String> {
        self.inner
            .source
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    pub fn send(&self, intent: PlayerIntent) {
        self.inner.vm.send(intent.into(), self.inner.now());
    }

    /// What the engine reported.
    pub fn engine_event(&self, event: PlayerEngineEvent) {
        self.inner.vm.engine_event(event.into(), self.inner.now());
    }

    pub fn set_prefs(&self, prefs: PlayerPrefs) {
        self.inner.vm.set_prefs(prefs);
    }

    pub fn set_next(&self, next: Option<PlayerNext>) {
        self.inner.vm.set_next(next.map(|n| NextEpisode {
            id: n.id,
            title: n.title,
        }));
    }

    /// Chapter starts and names, in seconds.
    pub fn set_chapters(&self, chapters: Vec<PlayerChapter>) {
        self.inner.vm.set_chapters(
            chapters
                .into_iter()
                .map(|c| Chapter {
                    name: c.name,
                    from: c.from,
                })
                .collect(),
        );
    }

    /// Intro/outro sections arrived (empty clears them).
    pub fn set_sections(&self, sections: Vec<PlayerSection>) {
        self.inner
            .vm
            .set_sections(sections.into_iter().map(Segment::from).collect());
    }

    /// The trickplay offer of the title (`None` when it has none).
    pub fn set_trickplay(&self, trickplay: Option<PlayerTrickplay>) {
        self.inner.vm.set_trickplay(trickplay.map(|t| Trickplay {
            width: t.width,
            height: t.height,
            tiles_wide: t.tiles_wide,
            tiles_up: t.tiles_up,
            count: t.count,
            interval: t.interval,
        }));
    }

    /// Joins (`Some`) or leaves (`None`) a SyncPlay group.
    pub fn set_group(&self, group: Option<Arc<dyn PlayerGroupHook>>) {
        self.inner
            .vm
            .set_group(group.map(|g| Arc::new(GroupAdapter(g)) as Arc<dyn GroupHook>));
    }

    /// What the host must do; empties the list.
    pub fn take_effects(&self) -> Vec<PlayerEffectOut> {
        self.inner
            .vm
            .take_effects()
            .into_iter()
            .map(|e| match e {
                PlayerEffect::Close => PlayerEffectOut::Close,
                PlayerEffect::StartEpisode {
                    id,
                    from_card,
                    since,
                } => PlayerEffectOut::StartEpisode {
                    id,
                    from_card,
                    since,
                },
                PlayerEffect::ReloadForSubtitle {
                    id,
                    subtitle,
                    since,
                } => PlayerEffectOut::ReloadForSubtitle {
                    id,
                    subtitle,
                    since,
                },
                PlayerEffect::QualityChosen(Quality { direct_play, limit }) => {
                    PlayerEffectOut::QualityChosen { direct_play, limit }
                }
                PlayerEffect::ForgetPrepared => PlayerEffectOut::ForgetPrepared,
                PlayerEffect::Nudge(n) => PlayerEffectOut::Nudge {
                    rating: n == Nudge::Rating,
                },
                PlayerEffect::PrepareNext(id) => PlayerEffectOut::PrepareNext { id },
                PlayerEffect::HandOver { subtitle, reason } => {
                    PlayerEffectOut::HandOver { subtitle, reason }
                }
                PlayerEffect::StreamRebuilt {
                    position,
                    paused,
                    reason,
                } => PlayerEffectOut::StreamRebuilt {
                    position,
                    paused,
                    reason,
                },
            })
            .collect()
    }

    #[uniffi::method(async_runtime = "tokio")]
    pub async fn changed(&self, seen: u64) -> Result<Change, CoreError> {
        Ok(self.inner.vm.changed(seen).await)
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerChapter {
    pub name: String,
    pub from: f64,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reduced() -> Vec<PlayerStream> {
        vec![PlayerStream {
            index: 1,
            kind: "Audio".into(),
            language: Some("deu".into()),
            codec: Some("aac".into()),
            channels: Some(2),
            title: None,
            is_default: true,
            is_forced: false,
            is_external: false,
            is_hearing_impaired: false,
        }]
    }

    #[test]
    fn the_raw_source_gives_the_whole_streams_and_the_reduced_list_is_the_fallback() {
        let json = r#"{"Id":"s","MediaStreams":[
            {"Index":0,"Type":"Video","Codec":"hevc","VideoRangeType":"DOVI","DvProfile":5},
            {"Index":1,"Type":"Audio","Codec":"aac","Language":"jpn","IsOriginal":true,"DisplayTitle":"Japanese - AAC"}]}"#;
        let whole = streams_of(Some(json), reduced());
        assert_eq!(whole.len(), 2);
        assert_eq!(whole[1].is_original, Some(true));
        assert_eq!(whole[0].dv_profile(), Some(5));
        // No source, a broken one, or one without streams: the reduced list.
        for none in [None, Some("{"), Some(r#"{"Id":"s","MediaStreams":[]}"#)] {
            let streams = streams_of(none, reduced());
            assert_eq!(streams.len(), 1);
            assert_eq!(streams[0].language.as_deref(), Some("deu"));
            assert_eq!(streams[0].is_original, None);
        }
    }
}
