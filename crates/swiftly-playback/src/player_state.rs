//! The pure, engine-neutral player state machine (Sources/Shared/AetherPlayerEngine.swift,
//! the facade part).
//!
//! `apply(event)` takes what an engine reports, `intent(...)` what the user or the screen wants;
//! both return [`Command`]s for the host to run (engine calls and host notifications). No I/O,
//! no clock: the 30 s start watchdog is a command the host arms and an event it feeds back.
//!
//! Rules ported 1:1:
//! - the seek target is shown instead of the clock until the seek lands (`:287-292`);
//! - `last_good` is the last clock value before a seek or a failure (`:222`, `:301`);
//! - the first picture settles the start (`:207-218`);
//! - a failure in the last 3 s is the end, not a failure (`:276-283`);
//! - no picture within 30 s is a failure (`:186-196`);
//! - tracks are applied without repeats (`:400-430`);
//! - external subtitle files map to engine track ids (`:139-150`, `:418`);
//! - cue choice and delay (`:454-477`).

use std::collections::HashMap;

use swiftly_jellyfin::TrackIndices;
use swiftly_model::MediaStream;
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_rules::delay::Delay;

use crate::engine::{
    AudioDelivery, Cue, CueBody, EngineEvent, EngineLoad, EngineState, EngineTrack,
    ExternalSubtitle, PipCmd, PlaybackEngine, Rect, Route,
};
use crate::track_mapping::SubtitleFile;

/// Seconds without a picture before the start counts as failed (AetherPlayerEngine.swift:191).
/// The ONE start timeout of every host: Swift reads it as `PlayerStartTimeout.seconds` (Sources/Shared), pinned by a test below.
pub const START_WATCHDOG_SECONDS: f64 = 30.0;
/// A failure this close to the end is the end of the film (AetherPlayerEngine.swift:279).
pub const END_FAILURE_WINDOW: f64 = 3.0;
/// Starts at or below this many seconds count as "from the beginning" (`:126`).
pub const START_THRESHOLD: f64 = 0.5;

/// What the engine opens (`EngineRequest`, AetherPlayerEngine.swift:31).
#[derive(Debug, Clone, PartialEq)]
pub struct EngineRequest {
    /// Item id; empty for a file on the device without a server description.
    pub item_id: String,
    /// The server's streams of the chosen source.
    pub streams: Vec<MediaStream>,
    /// Source runtime in seconds (the duration until the engine knows it).
    pub runtime: f64,
    /// External subtitle files with full addresses.
    pub subtitle_files: Vec<SubtitleFile>,
    /// Address to open.
    pub url: String,
    /// Own headers.
    pub headers: Vec<(String, String)>,
    /// Software-decoder hint from the first-frame rules.
    pub software_decode: bool,
    /// Buffer level.
    pub buffer_level: BufferLevel,
    /// Frame-rate matching.
    pub frame_rate_match: bool,
    /// The engine's base id for external subtitle tracks (`externalSubtitleTrackIDBase`).
    pub external_track_id_base: i64,
}

/// What the host should do. Engine calls map 1:1 to [`PlaybackEngine`] methods; the rest are
/// notifications for the screen.
#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    /// `PlaybackEngine::load`.
    Load(EngineLoad),
    /// `PlaybackEngine::play`.
    Play,
    /// `PlaybackEngine::pause`.
    Pause,
    /// `PlaybackEngine::seek`; the host answers with `SeekLanded`.
    Seek(f64),
    /// `PlaybackEngine::set_rate`.
    SetRate(f32),
    /// `PlaybackEngine::set_volume`.
    SetVolume(u8),
    /// `PlaybackEngine::set_audio_delay` in milliseconds.
    SetAudioDelay(i32),
    /// `PlaybackEngine::set_subtitle_delay` in milliseconds.
    SetSubtitleDelay(i32),
    /// `PlaybackEngine::select_audio`.
    SelectAudio(i64),
    /// `PlaybackEngine::select_subtitle` with the engine's track id.
    SelectSubtitle(i64),
    /// `PlaybackEngine::select_subtitle(-1)`: the engine may switch a forced or default track on
    /// by itself; the app's own rule decided already (`:426-428`).
    ClearSubtitle,
    /// `PlaybackEngine::set_fill`.
    SetFill(bool),
    /// `PlaybackEngine::stop`.
    Stop {
        /// Also reset the display mode.
        reset_display: bool,
    },
    /// Arm the start watchdog for this attempt; the host sends `StartWatchdog` after `seconds`.
    ArmStartWatchdog {
        /// Attempt number.
        attempt: u32,
        /// Delay.
        seconds: f64,
    },
    /// Disarm the start watchdog (the picture is there).
    CancelStartWatchdog,
    /// The running state changed (`avRunning`: idle timer, PiP state).
    Running(bool),
    /// Show the start error (`avFailed`).
    Failed(String),
    /// A wanted track is not in the engine; hand over (`avHandOver`).
    HandOver {
        /// The server subtitle index.
        subtitle: i64,
        /// Why.
        reason: String,
    },
    /// The running tracks, for the start and progress report.
    ReportTracks(TrackIndices),
    /// A log line (`AppLog`).
    Log(String),
}

impl Command {
    /// Runs an engine call on `engine`; returns `false` for host notifications.
    pub fn run(&self, engine: &dyn PlaybackEngine) -> bool {
        match self {
            Self::Load(r) => engine.load(r.clone()),
            Self::Play => engine.play(),
            Self::Pause => engine.pause(),
            Self::Seek(s) => engine.seek(*s),
            Self::SetRate(t) => engine.set_rate(*t),
            Self::SetVolume(p) => engine.set_volume(*p),
            Self::SetAudioDelay(ms) => engine.set_audio_delay(*ms),
            Self::SetSubtitleDelay(ms) => engine.set_subtitle_delay(*ms),
            Self::SelectAudio(i) => {
                engine.select_audio(i32::try_from(*i).unwrap_or(-1));
            }
            Self::SelectSubtitle(i) => {
                engine.select_subtitle(i32::try_from(*i).unwrap_or(-1));
            }
            Self::ClearSubtitle => {
                engine.select_subtitle(-1);
            }
            Self::SetFill(on) => engine.set_fill(*on),
            Self::Stop { reset_display } => engine.stop(*reset_display),
            _ => return false,
        }
        true
    }
}

/// What the screen or the user wants.
#[derive(Debug, Clone, PartialEq)]
pub enum Intent {
    /// Open the address and start at this position (`load(start:)`, `:115`).
    Start(f64),
    /// Seek (`move(to:)`, `:308`).
    Seek(f64),
    /// Pause.
    Pause,
    /// Resume; after the end it replays from 0.
    Resume,
    /// Playback speed (`tempo`, `:341`).
    SetTempo(f32),
    /// Volume in percent (`:349`).
    SetVolume(i32),
    /// Fill the frame (`:353`).
    SetFill(bool),
    /// Switch the audio track by server index (`:372`).
    SwitchAudio(i64),
    /// Select a subtitle by server index, `-1` off (`:433`).
    SelectSubtitle(i64),
    /// Subtitle delay (`:67`).
    SetSubtitleDelay(Delay),
    /// Audio delay (`:68`).
    SetAudioDelay(Delay),
    /// Stop (`:63`).
    Stop {
        /// Also reset the display mode.
        reset_display: bool,
    },
    /// PiP; the engine decides (a no-op without PiP).
    Pip(PipCmd),
}

/// The subtitle cues on screen now (`refreshSubtitle`, `:454-477`).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ActiveCues {
    /// The text lines joined with line breaks; `\N` becomes a line break.
    pub text: Option<String>,
    /// Ids of the bitmap cues on screen.
    pub images: Vec<i64>,
}

/// The player state. Pure data; feed it events and intents.
#[derive(Debug, Clone)]
pub struct PlayerState {
    request: EngineRequest,
    audio_index: Option<i64>,
    subtitle_index: i64,
    audio_applied: Option<i64>,
    subtitle_applied: Option<i64>,
    /// The subtitle index already handed over because the engine lacked it (reported once).
    handed_over_subtitle: Option<i64>,
    /// A hand-pick whose external file the engine may still be adding: the next track list decides, not this one.
    pick_grace: bool,
    external_track_ids: HashMap<i64, i64>,
    attempt: u32,
    seek_target: Option<f64>,
    last_position: f64,
    clock: f64,
    source_time: f64,
    duration: f64,
    video_size: (f64, f64),
    ended: bool,
    picture_shown: bool,
    stopped: bool,
    running: bool,
    failure_reported: bool,
    tempo: f32,
    fill_on: bool,
    subtitle_delay: Delay,
    audio_delay: Delay,
    engine_state: EngineState,
    engine_audio: Vec<EngineTrack>,
    engine_subtitles: Vec<EngineTrack>,
    active_audio: Option<i64>,
    active_subtitle: Option<i64>,
    cues: Vec<Cue>,
    route: Route,
    pip_possible: bool,
    pip_active: bool,
}

fn finite_ok(seconds: f64) -> bool {
    seconds.is_finite() && seconds >= 0.0
}

impl PlayerState {
    /// A fresh state for a request with the tracks chosen by the track rules.
    pub fn new(request: EngineRequest, audio_index: Option<i64>, subtitle_index: i64) -> Self {
        Self {
            request,
            audio_index,
            subtitle_index,
            audio_applied: None,
            subtitle_applied: None,
            handed_over_subtitle: None,
            pick_grace: false,
            external_track_ids: HashMap::new(),
            attempt: 0,
            seek_target: None,
            last_position: 0.0,
            clock: f64::NAN,
            source_time: 0.0,
            duration: 0.0,
            video_size: (0.0, 0.0),
            ended: false,
            picture_shown: false,
            stopped: false,
            running: false,
            failure_reported: false,
            tempo: 1.0,
            fill_on: false,
            subtitle_delay: Delay::from_milliseconds(0),
            audio_delay: Delay::from_milliseconds(0),
            engine_state: EngineState::Idle,
            engine_audio: Vec::new(),
            engine_subtitles: Vec::new(),
            active_audio: None,
            active_subtitle: None,
            cues: Vec::new(),
            route: Route::Local,
            pip_possible: false,
            pip_active: false,
        }
    }

    // MARK: Readouts

    /// The position shown: the end, else the seek target until it lands, else the clock
    /// (AetherPlayerEngine.swift:287-292).
    pub fn position(&self) -> f64 {
        if self.ended && self.duration_seconds() > 0.0 {
            return self.duration_seconds();
        }
        if let Some(t) = self.seek_target {
            return t;
        }
        if finite_ok(self.clock) {
            self.clock
        } else {
            self.last_position
        }
    }

    /// The engine's duration if known, else the source runtime (`:294-297`).
    pub fn duration_seconds(&self) -> f64 {
        if self.duration.is_finite() && self.duration > 0.0 {
            self.duration
        } else {
            self.request.runtime
        }
    }

    /// The last position the clock reported before a seek or a failure (`:301`).
    pub fn last_good(&self) -> f64 {
        self.last_position
    }

    /// Whether the start seek has landed (or there was none) (`:300`).
    pub fn start_settled(&self) -> bool {
        self.seek_target.is_none()
    }

    /// Whether the first picture is there (`:61`).
    pub fn picture_shown(&self) -> bool {
        self.picture_shown
    }

    /// Whether playback runs (`:299`).
    pub fn is_playing(&self) -> bool {
        self.running
    }

    /// The server audio track that plays (`audioIndex`).
    pub fn audio_index(&self) -> Option<i64> {
        self.audio_index
    }

    /// The server subtitle track that shows; `-1` none (`subtitleIndex`).
    pub fn subtitle_index(&self) -> i64 {
        self.subtitle_index
    }

    /// Source picture size (`:303-306`).
    pub fn video_size(&self) -> (f64, f64) {
        self.video_size
    }

    /// Playback speed.
    pub fn tempo(&self) -> f32 {
        self.tempo
    }

    /// The streams the panels work from; for a file on the device they are taken from the
    /// engine once its lists are there (`:381`).
    pub fn streams(&self) -> &[MediaStream] {
        &self.request.streams
    }

    /// Whether PiP is possible / active.
    pub fn pip(&self) -> (bool, bool) {
        (self.pip_possible, self.pip_active)
    }

    /// The output route.
    pub fn route(&self) -> Route {
        self.route
    }

    /// The cues on screen now, with the subtitle delay applied (`refreshSubtitle`, `:454-477`).
    pub fn active_cues(&self) -> ActiveCues {
        if self.subtitle_index < 0 {
            return ActiveCues::default();
        }
        let time = self.source_time - f64::from(self.subtitle_delay.milliseconds() as i32) / 1000.0;
        let on = |c: &&Cue| c.start <= time && time < c.end;
        let lines: Vec<String> = self
            .cues
            .iter()
            .filter(on)
            .filter_map(|c| match &c.body {
                CueBody::Text(t) => Some(t.clone()),
                CueBody::Rich(runs) => Some(runs.concat()),
                CueBody::Image { .. } => None,
            })
            .collect();
        let text = (!lines.is_empty()).then(|| lines.join("\n").replace("\\N", "\n"));
        let images = self
            .cues
            .iter()
            .filter(on)
            .filter(|c| matches!(c.body, CueBody::Image { .. }))
            .map(|c| c.id)
            .collect();
        ActiveCues { text, images }
    }

    // MARK: Events

    /// Takes one engine event and returns what to do about it.
    pub fn apply(&mut self, event: EngineEvent) -> Vec<Command> {
        // The engine's state is recorded even when stopped; every reaction is guarded (`:244`).
        if let EngineEvent::State(s) = &event {
            self.engine_state = s.clone();
        }
        if self.stopped {
            return Vec::new();
        }
        let mut out = Vec::new();
        match event {
            EngineEvent::State(state) => match state {
                EngineState::Playing => self.run_changed(true, &mut out),
                EngineState::Paused => self.run_changed(false, &mut out),
                EngineState::Ended => {
                    self.ended = true;
                    self.run_changed(false, &mut out);
                    out.push(Command::Log("[Aether] Ende".to_owned()));
                }
                EngineState::Error { message, kind } => {
                    let kind = kind.map(|k| format!(" ({k})")).unwrap_or_default();
                    self.failed(&format!("{message}{kind}"), &mut out);
                }
                EngineState::Idle | EngineState::Loading | EngineState::Seeking => {}
            },
            EngineEvent::FirstFrame => self.first_frame(&mut out),
            EngineEvent::Clock {
                position,
                source_time,
            } => {
                self.clock = position;
                self.source_time = source_time;
                if finite_ok(position) && self.seek_target.is_none() && !self.ended {
                    self.last_position = position;
                }
            }
            EngineEvent::Duration(d) => self.duration = d,
            EngineEvent::VideoSize { width, height } => self.video_size = (width, height),
            EngineEvent::Tracks {
                audio,
                subtitles,
                active_audio,
                active_subtitle,
            } => {
                self.engine_audio = audio;
                self.engine_subtitles = subtitles;
                self.active_audio = active_audio;
                self.active_subtitle = active_subtitle;
                self.check_tracks(&mut out);
            }
            EngineEvent::Cues(cues) => self.cues = cues,
            EngineEvent::AudioDelivery(d) => {
                if d == AudioDelivery::DroppedNoPipeline {
                    self.failed("Ton nicht lieferbar", &mut out);
                }
            }
            EngineEvent::Route(r) => self.route = r,
            EngineEvent::PipPossible(p) => self.pip_possible = p,
            EngineEvent::PipActive(p) => self.pip_active = p,
            EngineEvent::PipRestoreUi | EngineEvent::DisplayModeSwitch => {}
            EngineEvent::LoadFinished { attempt } => {
                if attempt == self.attempt {
                    out.push(Command::Play);
                    self.settle_start(&mut out);
                    self.seek_target = None;
                    self.check_tracks(&mut out);
                }
            }
            EngineEvent::LoadFailed {
                attempt,
                message,
                kind,
            } => {
                if attempt == self.attempt {
                    let kind = kind.map(|k| format!(" ({k})")).unwrap_or_default();
                    self.failed(&format!("Laden: {message}{kind}"), &mut out);
                }
            }
            EngineEvent::StartWatchdog { attempt } => {
                if attempt == self.attempt && !self.picture_shown {
                    self.failed("kein Bild nach 30 s", &mut out);
                }
            }
            EngineEvent::SeekLanded { target } => {
                if self.seek_target == Some(target) {
                    self.seek_target = None;
                }
            }
        }
        out
    }

    fn run_changed(&mut self, go: bool, out: &mut Vec<Command>) {
        if go == self.running {
            return;
        }
        self.running = go;
        out.push(Command::Running(go));
    }

    /// Fill mode and speed after the start landed (`:170-171`, `:212-214`).
    fn settle_start(&self, out: &mut Vec<Command>) {
        if self.tempo != 1.0 && self.engine_state_is_load_play_rate() {
            out.push(Command::SetRate(self.tempo));
        }
        out.push(Command::SetFill(self.fill_on));
    }

    fn engine_state_is_load_play_rate(&self) -> bool {
        true
    }

    fn first_frame(&mut self, out: &mut Vec<Command>) {
        if self.picture_shown {
            return;
        }
        self.picture_shown = true;
        out.push(Command::CancelStartWatchdog);
        out.push(Command::Log("[Aether] erstes Bild".to_owned()));
        // The first picture settles the start: when the engine rebuilds itself for the chosen
        // audio track right after `load`, the original call never reports back (`:207-211`).
        if self.seek_target.is_some() {
            self.seek_target = None;
            out.push(Command::SetFill(self.fill_on));
            if self.tempo != 1.0 {
                out.push(Command::SetRate(self.tempo));
            }
            self.check_tracks(out);
        }
        self.check_tracks(out);
    }

    fn failed(&mut self, reason: &str, out: &mut Vec<Command>) {
        if self.stopped || self.failure_reported {
            return;
        }
        // A stream that died within the last seconds is the end of the film, not a failure.
        let duration = self.duration_seconds();
        if duration > 0.0 && self.position() > duration - END_FAILURE_WINDOW {
            self.ended = true;
            return;
        }
        self.failure_reported = true;
        out.push(Command::Log(format!("[Aether] Fehler: {reason}")));
        out.push(Command::Failed(reason.to_owned()));
    }

    /// Hands the wanted tracks to the engine once its own lists are there, and only if the engine
    /// has the track under that number; each choice is applied once (`:400-430`).
    fn check_tracks(&mut self, out: &mut Vec<Command>) {
        if self.stopped {
            return;
        }
        if self.engine_audio.is_empty() && self.engine_subtitles.is_empty() {
            return;
        }
        self.adopt_engine_tracks(out);
        if let Some(want) = self.audio_index
            && self.audio_applied != Some(want)
            && !self.engine_audio.is_empty()
        {
            self.audio_applied = Some(want);
            if self.engine_audio.iter().any(|t| t.id == want) {
                if self.active_audio != Some(want) {
                    out.push(Command::SelectAudio(want));
                }
            } else {
                out.push(Command::Log(format!(
                    "[Aether] Tonspur {want} nicht in der Liste der Engine"
                )));
            }
        }
        if self.engine_subtitles.is_empty() && self.engine_state == EngineState::Loading {
            return;
        }
        if self.subtitle_index >= 0 {
            if self.subtitle_applied == Some(self.subtitle_index) {
                return;
            }
            let wanted = self
                .external_track_ids
                .get(&self.subtitle_index)
                .copied()
                .unwrap_or(self.subtitle_index);
            if self.engine_subtitles.iter().any(|t| t.id == wanted) {
                self.subtitle_applied = Some(self.subtitle_index);
                self.handed_over_subtitle = None;
                out.push(Command::SelectSubtitle(wanted));
            } else if self.pick_grace && self.external_track_ids.contains_key(&self.subtitle_index)
            {
                self.pick_grace = false;
            } else if self.picture_shown && self.handed_over_subtitle != Some(self.subtitle_index) {
                // Only once the first picture is up: an engine adds external files after its first track list
                // (libmpv: sub-add after file-loaded), so a missing track before that is not yet a missing track.
                // Not latched as applied: an engine adds external tracks after the first track
                // list, and the later list must still select the wanted one.
                self.handed_over_subtitle = Some(self.subtitle_index);
                out.push(Command::HandOver {
                    subtitle: self.subtitle_index,
                    reason: format!("Untertitel {} nicht in der Engine", self.subtitle_index),
                });
            }
        } else if self.subtitle_applied != Some(-1) {
            self.subtitle_applied = Some(-1);
            if self.active_subtitle.is_some() {
                out.push(Command::ClearSubtitle);
            }
        }
    }

    /// A file on the device has no server description: the lists then come from the engine's own
    /// tracks (same numbers) so panels, memory and selection work as for a server title (`:381`).
    /// A kind the stored title already lists (the subtitles a download kept in `info.json`) stays as it is; only the
    /// missing kinds come from the engine, as on the Mac (`AetherPlayerEngine.adoptEngineTracks`).
    fn adopt_engine_tracks(&mut self, out: &mut Vec<Command>) {
        if !self.request.item_id.is_empty() {
            return;
        }
        let kind = |ty: &str| {
            self.request
                .streams
                .iter()
                .any(|s| s.type_.as_deref() == Some(ty))
        };
        let want_audio = !kind("Audio");
        let want_subtitles = !kind("Subtitle");
        if !((want_audio && !self.engine_audio.is_empty())
            || (want_subtitles && !self.engine_subtitles.is_empty()))
        {
            return;
        }
        let entry = |t: &EngineTrack, ty: &str| MediaStream {
            index: Some(t.id),
            type_: Some(ty.to_owned()),
            codec: Some(t.codec.clone()),
            language: Some(t.language.clone().unwrap_or_default()),
            display_title: Some(t.name.clone()),
            channels: Some(t.channels),
            is_default: Some(t.is_default),
            is_forced: Some(t.is_forced),
            ..MediaStream::default()
        };
        let mut streams = std::mem::take(&mut self.request.streams);
        if want_audio {
            streams.extend(self.engine_audio.iter().map(|t| entry(t, "Audio")));
        }
        if want_subtitles {
            streams.extend(self.engine_subtitles.iter().map(|t| entry(t, "Subtitle")));
        }
        self.request.streams = streams;
        if self.audio_index.is_none() {
            self.audio_index = self
                .active_audio
                .or_else(|| {
                    self.engine_audio
                        .iter()
                        .find(|t| t.is_default)
                        .map(|t| t.id)
                })
                .or_else(|| self.engine_audio.first().map(|t| t.id));
        }
        self.audio_applied = self.audio_index;
        out.push(Command::ReportTracks(TrackIndices {
            audio: self.audio_index,
            subtitle: Some(self.subtitle_index),
        }));
        out.push(Command::Log(format!(
            "[Aether] Datei ohne Beschreibung: {} Töne, {} Untertitel {}",
            if want_audio {
                self.engine_audio.len()
            } else {
                0
            },
            if want_subtitles {
                self.engine_subtitles.len()
            } else {
                self.request
                    .streams
                    .iter()
                    .filter(|s| s.type_.as_deref() == Some("Subtitle"))
                    .count()
            },
            if want_subtitles {
                "aus der Engine"
            } else {
                "aus dem Download"
            }
        )));
    }

    // MARK: Intents

    /// Takes one intent and returns what to do about it.
    pub fn intent(&mut self, intent: Intent) -> Vec<Command> {
        let mut out = Vec::new();
        match intent {
            Intent::Start(start) => self.load(start, &mut out),
            Intent::Seek(seconds) => {
                let target = seconds.max(0.0);
                if self.ended {
                    self.load(target, &mut out);
                } else {
                    self.seek_target = Some(target);
                    self.last_position = target;
                    out.push(Command::Seek(target));
                }
            }
            Intent::Pause => out.push(Command::Pause),
            Intent::Resume => {
                if self.ended {
                    self.load(0.0, &mut out);
                } else {
                    out.push(Command::Play);
                }
            }
            Intent::SetTempo(t) => {
                self.tempo = t;
                if self.running || self.engine_state == EngineState::Paused {
                    out.push(Command::SetRate(t));
                }
            }
            Intent::SetVolume(p) => out.push(Command::SetVolume(p.clamp(0, 100) as u8)),
            Intent::SetFill(on) => {
                self.fill_on = on;
                out.push(Command::SetFill(on));
            }
            Intent::SwitchAudio(index) => {
                if Some(index) != self.audio_index {
                    self.audio_index = Some(index);
                    self.audio_applied = None;
                    self.check_tracks(&mut out);
                }
            }
            Intent::SelectSubtitle(index) => {
                self.select_subtitle(index, &mut out);
            }
            Intent::SetSubtitleDelay(d) => {
                if d != self.subtitle_delay {
                    self.subtitle_delay = d;
                    out.push(Command::SetSubtitleDelay(d.milliseconds() as i32));
                }
            }
            Intent::SetAudioDelay(d) => {
                if d != self.audio_delay {
                    self.audio_delay = d;
                    out.push(Command::SetAudioDelay(d.milliseconds() as i32));
                }
            }
            Intent::Stop { reset_display } => {
                self.stopped = true;
                out.push(Command::Stop { reset_display });
            }
            Intent::Pip(_) => {}
        }
        out
    }

    /// Selects a subtitle by server index; `false` if this source has no such track, in which
    /// case nothing changes (`selectSubtitle`, `:433-448`).
    pub fn select_subtitle(&mut self, index: i64, out: &mut Vec<Command>) -> bool {
        if index < 0 {
            self.subtitle_index = -1;
            self.subtitle_applied = None;
            if self.active_subtitle.is_some() {
                out.push(Command::ClearSubtitle);
            }
            self.subtitle_applied = Some(-1);
            return true;
        }
        let known = self
            .request
            .streams
            .iter()
            .any(|s| s.type_.as_deref() == Some("Subtitle") && s.index == Some(index));
        if !known {
            return false;
        }
        self.subtitle_index = index;
        self.subtitle_applied = None;
        self.pick_grace = true;
        self.check_tracks(out);
        self.pick_grace = false;
        true
    }

    /// Opens the address and starts at `start` (`load(start:)`, `:115-184`).
    fn load(&mut self, start: f64, out: &mut Vec<Command>) {
        if self.stopped {
            return;
        }
        // A start that is negative or not a number (a damaged resume point) means the beginning.
        let start = if finite_ok(start) { start } else { 0.0 };
        self.attempt += 1;
        self.ended = false;
        self.picture_shown = false;
        self.last_position = start;
        self.audio_applied = None;
        self.subtitle_applied = None;
        self.handed_over_subtitle = None;
        self.failure_reported = false;
        self.seek_target = (start > START_THRESHOLD).then_some(start);
        out.push(Command::ArmStartWatchdog {
            attempt: self.attempt,
            seconds: START_WATCHDOG_SECONDS,
        });

        // External subtitle files are not in the container: the engine only knows them when
        // they are handed over at load; its track id is base + position in that list.
        let external: Vec<&SubtitleFile> = self
            .request
            .subtitle_files
            .iter()
            .filter(|f| {
                self.request
                    .streams
                    .iter()
                    .any(|s| s.index == Some(f.index) && s.is_external == Some(true))
            })
            .collect();
        self.external_track_ids = external
            .iter()
            .enumerate()
            .map(|(i, f)| (f.index, self.request.external_track_id_base + i as i64))
            .collect();
        let external_subtitles: Vec<ExternalSubtitle> = external
            .iter()
            .map(|f| {
                let stream = self
                    .request
                    .streams
                    .iter()
                    .find(|s| s.index == Some(f.index));
                let path = f.address.split('?').next().unwrap_or("");
                let has_ext = path
                    .rsplit('/')
                    .next()
                    .is_some_and(|name| name.contains('.'));
                ExternalSubtitle {
                    url: f.address.clone(),
                    name: stream.and_then(|s| s.display_title.clone()),
                    language: stream.and_then(|s| s.language.clone()),
                    is_forced: stream.and_then(|s| s.is_forced).unwrap_or(false),
                    format_hint: (!has_ext).then(|| "srt".to_owned()),
                }
            })
            .collect();
        // The wanted audio track goes in with the load: a selection afterwards reloads the session.
        let first_audio = self.audio_index.filter(|want| {
            self.request
                .streams
                .iter()
                .any(|s| s.type_.as_deref() == Some("Audio") && s.index == Some(*want))
        });
        self.audio_applied = first_audio;
        out.push(Command::Load(EngineLoad {
            url: self.request.url.clone(),
            headers: self.request.headers.clone(),
            start: (start > START_THRESHOLD).then_some(start),
            audio_server_index: first_audio,
            subtitle_server_index: self.subtitle_index,
            external_subtitles,
            software_decode: self.request.software_decode,
            buffer_level: self.request.buffer_level,
            frame_rate_match: self.request.frame_rate_match,
        }));
    }

    /// The place command for the surface is a plain pass-through for hosts that route it here.
    pub fn place(&self, _rect: Rect) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stream(index: i64, ty: &str, lang: &str, external: bool) -> MediaStream {
        MediaStream {
            index: Some(index),
            type_: Some(ty.into()),
            language: Some(lang.into()),
            codec: Some(if ty == "Audio" { "eac3" } else { "subrip" }.into()),
            is_external: Some(external),
            ..MediaStream::default()
        }
    }

    fn track(id: i64) -> EngineTrack {
        EngineTrack {
            id,
            codec: "x".into(),
            language: None,
            name: String::new(),
            channels: 2,
            is_default: false,
            is_forced: false,
        }
    }

    fn request(files: Vec<SubtitleFile>) -> EngineRequest {
        EngineRequest {
            item_id: "i".into(),
            streams: vec![
                stream(1, "Audio", "ger", false),
                stream(2, "Audio", "eng", false),
                stream(3, "Subtitle", "ger", false),
                stream(5, "Subtitle", "eng", true),
            ],
            runtime: 100.0,
            subtitle_files: files,
            url: "https://s/v".into(),
            headers: vec![],
            software_decode: false,
            buffer_level: BufferLevel::Normal,
            frame_rate_match: true,
            external_track_id_base: 1000,
        }
    }

    fn file(index: i64) -> SubtitleFile {
        SubtitleFile {
            index,
            address: format!("https://s/s/{index}"),
            attribute: None,
        }
    }

    fn state() -> PlayerState {
        PlayerState::new(request(vec![file(5)]), Some(2), -1)
    }

    fn tracks_event(active_audio: Option<i64>, active_sub: Option<i64>) -> EngineEvent {
        EngineEvent::Tracks {
            audio: vec![track(1), track(2)],
            subtitles: vec![track(3), track(1000)],
            active_audio,
            active_subtitle: active_sub,
        }
    }

    fn clock(p: f64) -> EngineEvent {
        EngineEvent::Clock {
            position: p,
            source_time: p,
        }
    }

    /// Start with resume: the load carries the start and the audio track, the target is shown.
    #[test]
    fn start_with_resume() {
        let mut s = state();
        let cmds = s.intent(Intent::Start(61.0));
        assert_eq!(
            cmds[0],
            Command::ArmStartWatchdog {
                attempt: 1,
                seconds: 30.0
            }
        );
        let Command::Load(load) = &cmds[1] else {
            panic!("no load")
        };
        assert_eq!(load.start, Some(61.0));
        assert_eq!(load.audio_server_index, Some(2));
        assert_eq!(load.external_subtitles.len(), 1);
        assert_eq!(
            load.external_subtitles[0].format_hint.as_deref(),
            Some("srt")
        );
        // The clock reads 0 while the start seek is outstanding: the target is shown.
        s.apply(clock(0.0));
        assert_eq!(s.position(), 61.0);
        assert!(!s.start_settled());
        // The load returns: play, fill, tracks.
        let cmds = s.apply(EngineEvent::LoadFinished { attempt: 1 });
        assert_eq!(cmds[0], Command::Play);
        assert!(cmds.contains(&Command::SetFill(false)));
        assert!(s.start_settled());
        s.apply(clock(61.4));
        assert_eq!(s.position(), 61.4);
        assert_eq!(s.last_good(), 61.4);
    }

    /// A start at 0.5 s or less loads without a start position and without a seek target.
    #[test]
    fn start_from_beginning() {
        let mut s = state();
        let cmds = s.intent(Intent::Start(0.3));
        let Command::Load(load) = &cmds[1] else {
            panic!("no load")
        };
        assert_eq!(load.start, None);
        assert!(s.start_settled());
    }

    /// The first picture settles the start when `load` never reports back.
    #[test]
    fn first_picture_settles_start() {
        let mut s = state();
        s.intent(Intent::Start(120.0));
        assert!(!s.start_settled());
        s.intent(Intent::SetTempo(1.5));
        let cmds = s.apply(EngineEvent::FirstFrame);
        assert!(s.start_settled() && s.picture_shown());
        assert!(cmds.contains(&Command::CancelStartWatchdog));
        assert!(cmds.contains(&Command::SetFill(false)));
        assert!(cmds.contains(&Command::SetRate(1.5)));
        // A second first-frame event does nothing.
        assert!(s.apply(EngineEvent::FirstFrame).is_empty());
    }

    /// Seek then settle: the target is shown until it lands; lastGood holds the target.
    #[test]
    fn seek_then_settle() {
        let mut s = state();
        s.intent(Intent::Start(0.0));
        s.apply(EngineEvent::LoadFinished { attempt: 1 });
        s.apply(clock(10.0));
        assert_eq!(s.intent(Intent::Seek(50.0)), vec![Command::Seek(50.0)]);
        s.apply(clock(10.2));
        assert_eq!(
            s.position(),
            50.0,
            "target shown while the clock still reads the old time"
        );
        assert_eq!(
            s.last_good(),
            50.0,
            "clock updates are ignored during the seek"
        );
        // A landing for another target changes nothing.
        s.apply(EngineEvent::SeekLanded { target: 40.0 });
        assert_eq!(s.position(), 50.0);
        s.apply(EngineEvent::SeekLanded { target: 50.0 });
        s.apply(clock(50.3));
        assert_eq!(s.position(), 50.3);
        // Negative targets clamp to 0.
        assert_eq!(s.intent(Intent::Seek(-4.0)), vec![Command::Seek(0.0)]);
    }

    /// A failure in the last 3 s is the end, not an error; elsewhere it is reported once.
    #[test]
    fn failure_near_the_end() {
        let mut s = state();
        s.intent(Intent::Start(0.0));
        s.apply(EngineEvent::Duration(100.0));
        s.apply(clock(98.5));
        let err = EngineEvent::State(EngineState::Error {
            message: "boom".into(),
            kind: Some("net".into()),
        });
        let cmds = s.apply(err.clone());
        assert!(!cmds.iter().any(|c| matches!(c, Command::Failed(_))));
        assert_eq!(s.position(), 100.0, "the end shows the duration");
        // Mid-film the same error is a failure, with the kind in brackets, once.
        let mut s = state();
        s.intent(Intent::Start(0.0));
        s.apply(EngineEvent::Duration(100.0));
        s.apply(clock(40.0));
        let cmds = s.apply(err.clone());
        assert!(cmds.contains(&Command::Failed("boom (net)".into())));
        assert!(!s.apply(err).iter().any(|c| matches!(c, Command::Failed(_))));
    }

    /// Pinned: Swift's `PlayerStartTimeout.seconds` is the same number.
    #[test]
    fn start_timeout_is_thirty_seconds() {
        assert_eq!(START_WATCHDOG_SECONDS, 30.0);
    }

    /// No picture within 30 s fails the start; a picture disarms it.
    #[test]
    fn start_watchdog() {
        let mut s = state();
        s.intent(Intent::Start(0.0));
        let cmds = s.apply(EngineEvent::StartWatchdog { attempt: 1 });
        assert!(cmds.contains(&Command::Failed("kein Bild nach 30 s".into())));
        let mut s = state();
        s.intent(Intent::Start(0.0));
        s.apply(EngineEvent::FirstFrame);
        assert!(
            s.apply(EngineEvent::StartWatchdog { attempt: 1 })
                .is_empty()
        );
        // A watchdog of an older attempt is ignored.
        let mut s = state();
        s.intent(Intent::Start(0.0));
        s.intent(Intent::Start(0.0));
        assert!(
            s.apply(EngineEvent::StartWatchdog { attempt: 1 })
                .is_empty()
        );
    }

    /// Audio switch with the lists present selects once.
    #[test]
    fn audio_switch_selects_once() {
        let mut s = state();
        s.intent(Intent::Start(0.0));
        s.apply(tracks_event(Some(2), None));
        assert_eq!(
            s.intent(Intent::SwitchAudio(1)),
            vec![Command::SelectAudio(1)]
        );
        // Same track again: no command; the list publishing again: no repeat.
        assert!(s.intent(Intent::SwitchAudio(1)).is_empty());
        assert!(
            s.apply(tracks_event(Some(2), None))
                .iter()
                .all(|c| !matches!(c, Command::SelectAudio(_)))
        );
        // A track the engine does not list is logged, not selected.
        let cmds = s.intent(Intent::SwitchAudio(9));
        assert!(cmds.iter().all(|c| !matches!(c, Command::SelectAudio(_))));
        assert!(cmds.iter().any(|c| matches!(c, Command::Log(_))));
    }

    /// Subtitle switch with an external file: the server index maps to base + position.
    #[test]
    fn subtitle_switch_with_external_file() {
        let mut s = state();
        s.intent(Intent::Start(0.0));
        // Off by rule, the engine switched one on by itself: cleared once.
        let cmds = s.apply(tracks_event(Some(2), Some(3)));
        assert!(cmds.contains(&Command::ClearSubtitle));
        assert!(
            !s.apply(tracks_event(Some(2), Some(3)))
                .contains(&Command::ClearSubtitle)
        );
        // External file (server index 5) -> engine id 1000.
        let mut out = Vec::new();
        assert!(s.select_subtitle(5, &mut out));
        assert_eq!(out, vec![Command::SelectSubtitle(1000)]);
        // Embedded track 3 maps to itself; selecting it again after another is a new choice.
        let mut out = Vec::new();
        assert!(s.select_subtitle(3, &mut out));
        assert_eq!(out, vec![Command::SelectSubtitle(3)]);
        // A subtitle the source does not have: refused, nothing changes.
        let mut out = Vec::new();
        assert!(!s.select_subtitle(77, &mut out));
        assert!(out.is_empty());
        assert_eq!(s.subtitle_index(), 3);
        // Off clears the engine's track.
        let mut out = Vec::new();
        assert!(s.select_subtitle(-1, &mut out));
        assert_eq!(out, vec![Command::ClearSubtitle]);
    }

    /// Cue choice and delay: the delay shifts the time the cues are matched against.
    #[test]
    fn cue_choice_and_delay() {
        let mut s = state();
        let mut out = Vec::new();
        s.select_subtitle(3, &mut out);
        let cue = |id, a, b, t: &str| Cue {
            id,
            start: a,
            end: b,
            body: CueBody::Text(t.into()),
        };
        s.apply(EngineEvent::Cues(vec![
            cue(1, 10.0, 12.0, "one\\Ntwo"),
            Cue {
                id: 2,
                start: 10.0,
                end: 12.0,
                body: CueBody::Rich(vec!["ri".into(), "ch".into()]),
            },
            Cue {
                id: 3,
                start: 10.0,
                end: 12.0,
                body: CueBody::Image {
                    position: Rect::default(),
                    canvas: (1.0, 1.0),
                },
            },
        ]));
        s.apply(EngineEvent::Clock {
            position: 11.0,
            source_time: 11.0,
        });
        let now = s.active_cues();
        assert_eq!(now.text.as_deref(), Some("one\ntwo\nrich"));
        assert_eq!(now.images, vec![3]);
        // A 2 s delay looks 2 s back: at 11.0 the cues of 9.0 are due, so none.
        s.intent(Intent::SetSubtitleDelay(Delay::from_milliseconds(2000)));
        assert_eq!(s.active_cues(), ActiveCues::default());
        // Subtitles off: nothing is drawn.
        s.intent(Intent::SetSubtitleDelay(Delay::from_milliseconds(0)));
        let mut out = Vec::new();
        s.select_subtitle(-1, &mut out);
        assert_eq!(s.active_cues(), ActiveCues::default());
    }

    /// After the end a resume or a seek reloads (`.ended` is final for the engine).
    #[test]
    fn ended_replays_with_a_new_load() {
        let mut s = state();
        s.intent(Intent::Start(0.0));
        s.apply(EngineEvent::Duration(100.0));
        s.apply(EngineEvent::State(EngineState::Playing));
        let cmds = s.apply(EngineEvent::State(EngineState::Ended));
        assert!(cmds.contains(&Command::Running(false)));
        assert_eq!(s.position(), 100.0);
        let cmds = s.intent(Intent::Resume);
        assert!(matches!(cmds[1], Command::Load(_)));
        assert!(cmds.contains(&Command::ArmStartWatchdog {
            attempt: 2,
            seconds: 30.0
        }));
        // A late event of the first attempt is ignored.
        assert!(s.apply(EngineEvent::LoadFinished { attempt: 1 }).is_empty());
    }

    /// A file on the device without description takes its tracks from the engine.
    #[test]
    fn file_without_description_adopts_engine_tracks() {
        let mut req = request(vec![]);
        req.item_id = String::new();
        req.streams = vec![];
        let mut s = PlayerState::new(req, None, -1);
        s.intent(Intent::Start(0.0));
        let cmds = s.apply(tracks_event(None, None));
        assert!(cmds.contains(&Command::ReportTracks(TrackIndices {
            audio: Some(1),
            subtitle: Some(-1)
        })));
        assert_eq!(s.streams().len(), 4);
        assert_eq!(s.audio_index(), Some(1));
    }

    /// A download keeps its subtitles in `info.json` but has no audio rows: the audio list comes from the engine's
    /// tracks while the stored subtitles stay as they are.
    #[test]
    fn download_with_stored_subtitles_takes_its_audio_from_the_engine() {
        let stored = MediaStream {
            index: Some(3),
            type_: Some("Subtitle".to_owned()),
            codec: Some("subrip".to_owned()),
            is_external: Some(true),
            ..MediaStream::default()
        };
        let mut req = request(vec![]);
        req.item_id = String::new();
        req.streams = vec![stored];
        let mut s = PlayerState::new(req, None, -1);
        s.intent(Intent::Start(0.0));
        s.apply(tracks_event(None, None));
        let of = |ty: &str| {
            s.streams()
                .iter()
                .filter(|m| m.type_.as_deref() == Some(ty))
                .map(|m| m.index)
                .collect::<Vec<_>>()
        };
        assert_eq!(of("Audio"), [Some(1), Some(2)]);
        assert_eq!(of("Subtitle"), [Some(3)], "the stored subtitles stay");
        assert_eq!(s.audio_index(), Some(1));
    }

    /// The engine lists its subtitles late (external ones are added after the file loaded): a
    /// start with a chosen subtitle must still select it when the later list has it.
    #[test]
    fn subtitle_chosen_at_start_is_selected_when_the_track_list_arrives_late() {
        let mut s = PlayerState::new(request(vec![file(5)]), Some(2), 5);
        s.intent(Intent::Start(0.0));
        s.apply(EngineEvent::State(EngineState::Playing));
        let early = s.apply(EngineEvent::Tracks {
            audio: vec![track(1), track(2)],
            subtitles: vec![],
            active_audio: Some(2),
            active_subtitle: None,
        });
        assert!(!early.contains(&Command::SelectSubtitle(1000)));
        let late = s.apply(tracks_event(Some(2), None));
        assert!(late.contains(&Command::SelectSubtitle(1000)), "{late:?}");
        // Once applied it is not sent again.
        assert!(
            !s.apply(tracks_event(Some(2), Some(1000)))
                .contains(&Command::SelectSubtitle(1000))
        );
    }

    /// A track list without the external file before the first picture is not a hand-over (the engine adds the file
    /// right after); one still missing at the first picture is. Failed before: the early list handed over at once.
    #[test]
    fn missing_subtitle_is_handed_over_only_after_the_first_picture() {
        let mut s = PlayerState::new(request(vec![file(5)]), Some(2), 5);
        s.intent(Intent::Start(0.0));
        s.apply(EngineEvent::State(EngineState::Playing));
        let none = || EngineEvent::Tracks {
            audio: vec![track(1), track(2)],
            subtitles: vec![],
            active_audio: Some(2),
            active_subtitle: None,
        };
        let early = s.apply(none());
        assert!(
            !early.iter().any(|c| matches!(c, Command::HandOver { .. })),
            "{early:?}"
        );
        let late = s.apply(EngineEvent::FirstFrame);
        assert!(
            late.iter().any(|c| matches!(c, Command::HandOver { .. })),
            "{late:?}"
        );
        // The file arrives after all: it is selected and the first picture adds no hand-over.
        let mut s = PlayerState::new(request(vec![file(5)]), Some(2), 5);
        s.intent(Intent::Start(0.0));
        s.apply(EngineEvent::State(EngineState::Playing));
        s.apply(none());
        s.apply(tracks_event(Some(2), None));
        let frame = s.apply(EngineEvent::FirstFrame);
        assert!(
            !frame.iter().any(|c| matches!(c, Command::HandOver { .. })),
            "{frame:?}"
        );
    }

    /// A hand-pick of an external file while the engine is still adding it is not a hand-over; the list that has it selects it.
    #[test]
    fn picking_an_external_file_the_engine_is_still_adding_is_not_a_hand_over() {
        let mut s = PlayerState::new(request(vec![file(5)]), Some(2), -1);
        s.intent(Intent::Start(0.0));
        s.apply(EngineEvent::State(EngineState::Playing));
        s.apply(EngineEvent::FirstFrame);
        s.apply(EngineEvent::Tracks {
            audio: vec![track(1), track(2)],
            subtitles: vec![],
            active_audio: Some(2),
            active_subtitle: None,
        });
        let mut out = Vec::new();
        assert!(s.select_subtitle(5, &mut out));
        assert!(
            !out.iter().any(|c| matches!(c, Command::HandOver { .. })),
            "{out:?}"
        );
        let late = s.apply(tracks_event(Some(2), None));
        assert!(late.contains(&Command::SelectSubtitle(1000)), "{late:?}");
    }

    /// Stopped states ignore everything; stop and volume/tempo intents.
    #[test]
    fn stop_volume_tempo() {
        let mut s = state();
        assert_eq!(
            s.intent(Intent::SetVolume(180)),
            vec![Command::SetVolume(100)]
        );
        assert_eq!(s.intent(Intent::SetVolume(-3)), vec![Command::SetVolume(0)]);
        // Tempo is only sent while running or paused.
        assert!(s.intent(Intent::SetTempo(2.0)).is_empty());
        s.apply(EngineEvent::State(EngineState::Playing));
        assert_eq!(
            s.intent(Intent::SetTempo(1.25)),
            vec![Command::SetRate(1.25)]
        );
        assert_eq!(
            s.intent(Intent::Stop {
                reset_display: true
            }),
            vec![Command::Stop {
                reset_display: true
            }]
        );
        assert!(s.apply(EngineEvent::State(EngineState::Paused)).is_empty());
        assert!(s.intent(Intent::Start(5.0)).is_empty());
    }
}
