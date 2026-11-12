//! The engine seam: the `PlaybackEngine` trait, its load request, and the events engines send
//! back (Sources/Shared/PlaybackBackend.swift:7-48).
//!
//! UniFFI foreign traits are synchronous and nonisolated (a UniFFI rule), so every
//! command returns `()` (or an immediate answer) and results come back as [`EngineEvent`]s. The
//! attribute `#[uniffi::export(with_foreign)]` is put on the trait by `swiftly-uniffi`; this crate
//! stays free of the macro.

use swiftly_rules::buffer_level::BufferLevel;

/// A rectangle in points, for [`PlaybackEngine::place`] (`place(in:)`, PlaybackBackend.swift:36).
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Rect {
    /// Left edge.
    pub x: f64,
    /// Top edge.
    pub y: f64,
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

/// How a chosen subtitle gets onto the picture (D4: `SubtitleRoute`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubtitleRoute {
    /// The engine delivers cues; the app draws them.
    Cues,
    /// The engine draws it itself (PGS in mpv).
    EngineDrawn,
    /// This engine cannot show the track; it stays off (PlaybackBackend.swift:38).
    Unsupported,
}

/// Picture-in-picture command; a no-op without PiP.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PipCmd {
    /// Start PiP.
    Start,
    /// Stop PiP.
    Stop,
    /// Rebuild/refresh the controller.
    Refresh,
}

/// An external subtitle file handed over at load (AetherPlayerEngine.swift:145-150).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExternalSubtitle {
    /// Address of the file.
    pub url: String,
    /// Display title of the stream, if known.
    pub name: Option<String>,
    /// Language of the stream, if known.
    pub language: Option<String>,
    /// Forced flag of the stream.
    pub is_forced: bool,
    /// `srt` when the address has no file extension, else none.
    pub format_hint: Option<String>,
}

/// Everything an engine needs to open a title (D4: `EngineLoad`).
#[derive(Debug, Clone, PartialEq)]
pub struct EngineLoad {
    /// Address to open.
    pub url: String,
    /// Own headers sent along.
    pub headers: Vec<(String, String)>,
    /// Start position; `None` for from the beginning (a start of 0.5 s or less).
    pub start: Option<f64>,
    /// The wanted audio track goes in with the load (a selection afterwards reloads).
    pub audio_server_index: Option<i64>,
    /// The wanted subtitle track (`-1` none).
    pub subtitle_server_index: i64,
    /// External subtitle files, in the order of their engine track ids.
    pub external_subtitles: Vec<ExternalSubtitle>,
    /// Open with the software decoder right away.
    pub software_decode: bool,
    /// Buffer level (`pufferstufe`).
    pub buffer_level: BufferLevel,
    /// Frame-rate matching (`bildrateAnpassen`).
    pub frame_rate_match: bool,
}

/// The thin driver behind the player (D4). Commands return at once; results arrive as
/// [`EngineEvent`]s through `PlayerVm::engine_event`.
pub trait PlaybackEngine: Send + Sync {
    /// Opens and starts loading.
    fn load(&self, request: EngineLoad);
    /// Plays.
    fn play(&self);
    /// Pauses.
    fn pause(&self);
    /// Seeks to a position in seconds.
    fn seek(&self, seconds: f64);
    /// Playback speed.
    fn set_rate(&self, tempo: f32);
    /// Volume 0...100.
    fn set_volume(&self, percent: u8);
    /// Audio delay in milliseconds.
    fn set_audio_delay(&self, milliseconds: i32);
    /// Subtitle delay in milliseconds (positive: later). Engines that draw the cues themselves
    /// (mpv) apply it, the others let the host's cue drawing shift; the default does nothing.
    fn set_subtitle_delay(&self, _milliseconds: i32) {}
    /// How text subtitles look when the engine draws them itself (mpv/libass). Takes effect at once, also
    /// for the cue on screen; engines that do not draw text ignore it.
    fn set_subtitle_style(&self, _style: &SubtitleTextStyle) {}
    /// Selects an audio track by server index; `false` if the engine has no such track.
    fn select_audio(&self, server_index: i32) -> bool;
    /// Selects a subtitle track by server index (`-1` off).
    fn select_subtitle(&self, server_index: i32) -> SubtitleRoute;
    /// Fill the frame instead of fitting it.
    fn set_fill(&self, on: bool);
    /// Places the video surface.
    fn place(&self, rect: Rect);
    /// Stops; `reset_display` also resets the display mode.
    fn stop(&self, reset_display: bool);
    /// Picture in picture.
    fn pip(&self, command: PipCmd);
    /// Audio passthrough and exclusive device access (`Player.passthrough(spdif:exclusive:)`),
    /// prepared as switches: effective from the next load. Engines that cannot do it ignore it
    /// (`Capabilities::audio_passthrough` says which can).
    fn set_audio_output(&self, _mode: &crate::decoder_choice::AudioOutputMode) {}
}

/// The look of text subtitles as plain numbers, the same for every engine that draws them (`SubtitleLook` in
/// `swiftly-support` turns into this). Sizes are shares of the picture, so the text keeps its weight in any window:
/// the Apple overlay's text is `picture height * 0.0625 * base scale * size step` tall.
#[derive(Clone, Debug, PartialEq)]
pub struct SubtitleTextStyle {
    /// Font family as the engine's font lookup knows it.
    pub font: String,
    /// Text size (em) as a share of the picture height.
    pub text_share: f64,
    /// Fill colour `0xRRGGBB`.
    pub colour: u32,
    /// Outline thickness as a share of the text size (0 = none).
    pub outline_em: f64,
    /// Hard shadow below the text.
    pub shadow: bool,
    /// Box behind the text.
    pub background: bool,
    /// Distance of the text from the bottom of the picture: this many points (logical pixels at the window's UI
    /// scale; 16 like the Apple overlay) ...
    pub margin_px: f64,
    /// Height of the picture on screen in points (window height / UI scale, letterboxing taken out). The frame the
    /// engine draws is the picture at some pixel size, so a point is `frame height / picture_pt` frame pixels.
    /// 0 = unknown: a point is one frame pixel.
    pub picture_pt: f64,
    /// ... plus this share of the picture height (the "raised" position).
    pub margin_share: f64,
    /// ASS and SSA keep the file's own style (colours, outline, bold, italic, position).
    pub keep_file_style: bool,
}

/// The engine's playback state (D4: `State(Idle|Loading|Playing|Paused|Seeking|Ended|Error)`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EngineState {
    /// Nothing loaded.
    Idle,
    /// Opening.
    Loading,
    /// Playing.
    Playing,
    /// Paused.
    Paused,
    /// Seeking.
    Seeking,
    /// The stream ended; final for the engine (a replay is a new load).
    Ended,
    /// An error with the engine's message and error kind.
    Error {
        /// Engine message.
        message: String,
        /// Error kind, shown in brackets (`errorInfo.kind`).
        kind: Option<String>,
    },
}

/// A track as the engine lists it (`TrackInfo` in AetherPlayerEngine.swift:383).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineTrack {
    /// The engine's track id (the server's `Index` for the file's own tracks).
    pub id: i64,
    /// Codec name.
    pub codec: String,
    /// Language.
    pub language: Option<String>,
    /// Name.
    pub name: String,
    /// Channels (audio).
    pub channels: i64,
    /// Default flag.
    pub is_default: bool,
    /// Forced flag.
    pub is_forced: bool,
}

/// Body of a subtitle cue (AetherPlayerEngine.swift:462-465).
#[derive(Debug, Clone, PartialEq)]
pub enum CueBody {
    /// Plain text.
    Text(String),
    /// Styled text runs; the app flattens them.
    Rich(Vec<String>),
    /// A bitmap (RGBA) placed on a canvas.
    Image {
        /// Position on the canvas.
        position: Rect,
        /// Canvas size (width, height).
        canvas: (f64, f64),
    },
}

/// A timed subtitle cue.
#[derive(Debug, Clone, PartialEq)]
pub struct Cue {
    /// Cue id.
    pub id: i64,
    /// Start in source time (seconds).
    pub start: f64,
    /// End in source time (seconds).
    pub end: f64,
    /// Content.
    pub body: CueBody,
}

/// How the audio reaches the output (`audioDelivery`); only the failing case matters here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AudioDelivery {
    /// Playing normally (any non-failing delivery).
    Ok,
    /// The source has sound and none of it could be delivered
    /// (`droppedNoPipeline`, AetherPlayerEngine.swift:231).
    DroppedNoPipeline,
}

/// Where the sound goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Route {
    /// AirPlay.
    AirPlay,
    /// Cast.
    Cast,
    /// This device.
    Local,
}

/// Driver to core (D4). The host forwards these to `PlayerState::apply`.
#[derive(Debug, Clone, PartialEq)]
pub enum EngineEvent {
    /// Playback state changed.
    State(EngineState),
    /// The first picture is ready for display (`hasFirstFrameReadyForDisplay`).
    FirstFrame,
    /// The clock: position and the source time used for subtitle cues.
    Clock {
        /// Playback position in seconds.
        position: f64,
        /// Source time in seconds.
        source_time: f64,
    },
    /// Duration in seconds.
    Duration(f64),
    /// Source picture size, pixel aspect ratio already applied to the width.
    VideoSize {
        /// Width.
        width: f64,
        /// Height.
        height: f64,
    },
    /// The engine's track lists and its active tracks.
    Tracks {
        /// Audio tracks.
        audio: Vec<EngineTrack>,
        /// Subtitle tracks.
        subtitles: Vec<EngineTrack>,
        /// Active audio track id.
        active_audio: Option<i64>,
        /// Active subtitle track id.
        active_subtitle: Option<i64>,
    },
    /// The subtitle cues the engine currently holds.
    Cues(Vec<Cue>),
    /// Audio delivery changed.
    AudioDelivery(AudioDelivery),
    /// Output route changed.
    Route(Route),
    /// PiP possible or not.
    PipPossible(bool),
    /// PiP active or not.
    PipActive(bool),
    /// The user returned from PiP.
    PipRestoreUi,
    /// The display mode was switched (HDR/frame rate).
    DisplayModeSwitch,
    /// The `load` call of this attempt returned successfully.
    LoadFinished {
        /// The attempt number from [`Command::Load`]'s `ArmStartWatchdog`.
        attempt: u32,
    },
    /// The `load` call of this attempt failed.
    LoadFailed {
        /// The attempt number.
        attempt: u32,
        /// Error text of the engine.
        message: String,
        /// Error kind of the engine.
        kind: Option<String>,
    },
    /// The 30 s start watchdog of this attempt fired.
    StartWatchdog {
        /// The attempt number.
        attempt: u32,
    },
    /// A seek to `target` has landed.
    SeekLanded {
        /// The target the seek was started with.
        target: f64,
    },
}
