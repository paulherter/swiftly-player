//! Video under the Rust UI on the non-Apple targets (gate G3).
//!
//! Two kinds of engine sit behind one contract:
//! - [`FrameDelivery::Frames`]: the engine hands the host RGBA frames (libmpv software render today; GL texture later).
//!   The host draws them as a picture under the UI in the same pass.
//! - [`FrameDelivery::NativeOverlay`]: the engine draws on a native surface that lies below the UI surface
//!   (Media3 `SurfaceView` on Android). The host only reports where the video goes and keeps its own layer transparent.
//!
//! Commands are the [`PlaybackEngine`] trait of `swiftly-playback`; results come back as `EngineEvent`s that the host
//! pulls with [`SurfaceEngine::poll_events`] and forwards to `PlayerVm::engine_event`. Everything in this file is plain
//! Rust and host-testable; the libmpv binding lives in `mpv` (feature `mpv`).

use swiftly_playback::engine::{EngineEvent, PlaybackEngine, Rect};

pub mod translate;
pub mod wire;

#[cfg(feature = "mpv")]
pub mod mpv;

/// How the picture reaches the screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameDelivery {
    /// The host pulls RGBA frames with [`VideoSurface::acquire_frame`] and draws them itself.
    Frames,
    /// The engine owns a native surface below the UI; the host only places it ([`VideoSurface::place`]).
    NativeOverlay,
}

/// Dynamic range of the picture that plays.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DynamicRange {
    /// Standard dynamic range.
    #[default]
    Sdr,
    /// HDR10 / HDR10+ (PQ, BT.2020).
    Hdr10,
    /// Hybrid log-gamma.
    Hlg,
    /// Dolby Vision (profile unknown at this level).
    DolbyVision,
}

/// What the display should do for this picture (Apple's `preferredDisplayCriteria`, `Surface.setFrameRate` on Android).
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct DisplayHints {
    /// Dynamic range of the source.
    pub range: DynamicRange,
    /// Source frame rate in Hz, if known.
    pub frame_rate: Option<f64>,
    /// Source picture size in pixels.
    pub size: Option<(u32, u32)>,
}

/// Counters of one playback, for the gate measurements and the technical badge.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct VideoStats {
    /// Frames the host drew or the engine rendered.
    pub frames_rendered: u64,
    /// Frames the decoder dropped.
    pub decoder_drops: u64,
    /// Frames the output dropped because it was late.
    pub output_drops: u64,
    /// Average time to produce one frame in ms (software render), 0 when not measured.
    pub avg_render_ms: f64,
    /// Decoded frame rate the engine estimates.
    pub decoded_fps: f64,
    /// Name of the hardware decoder in use (`none` = software).
    pub hwdec: String,
}

/// One audio output device.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioDevice {
    /// Engine id (`auto` = system default).
    pub id: String,
    /// Name to show.
    pub name: String,
}

/// What an engine can do; the UI hides what it cannot.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Capabilities {
    /// Keeps HDR and Dolby Vision to the display.
    pub hdr_passthrough: bool,
    /// Can ask the display for the source frame rate.
    pub frame_rate_match: bool,
    /// Picture in picture.
    pub pip: bool,
    /// Can pick the audio output device.
    pub audio_devices: bool,
    /// Draws bitmap subtitles (PGS) itself.
    pub draws_bitmap_subtitles: bool,
    /// Can send codecs as they are to the receiver (S/PDIF passthrough,
    /// `swiftly_playback::decoder_choice::AudioOutputMode::spdif_codecs`).
    pub audio_passthrough: bool,
    /// Can open the audio device exclusively (WASAPI exclusive mode).
    pub exclusive_audio: bool,
}

/// Result of [`VideoSurface::acquire_frame`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameStatus {
    /// A new frame was written into the buffer.
    New,
    /// The last frame is still current; the buffer is unchanged.
    Unchanged,
    /// Nothing to show yet (before the first picture, or the surface is a native overlay).
    NotReady,
}

/// A reusable RGBA buffer (straight alpha, 4 bytes per pixel, rows packed).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FrameBuffer {
    /// Width in pixels.
    pub width: u32,
    /// Height in pixels.
    pub height: u32,
    /// `width * height * 4` bytes.
    pub rgba: Vec<u8>,
}

impl FrameBuffer {
    /// Resizes to `width x height` (keeps the allocation when it fits).
    pub fn resize(&mut self, width: u32, height: u32) {
        self.width = width;
        self.height = height;
        self.rgba.resize(width as usize * height as usize * 4, 0);
    }
}

/// The place where video appears (the seam `player_screen::VideoSurface` of the desktop crate sits on).
pub trait VideoSurface: Send + Sync {
    /// Frames to the host or a native overlay.
    fn delivery(&self) -> FrameDelivery;
    /// Where the video goes in UI points (a [`FrameDelivery::NativeOverlay`] engine moves its surface).
    fn place(&self, rect: Rect);
    /// Fills `out` with the newest frame, scaled to fit `max_width x max_height` (aspect kept). Native overlays
    /// answer [`FrameStatus::NotReady`].
    fn acquire_frame(&self, max_width: u32, max_height: u32, out: &mut FrameBuffer) -> FrameStatus;
    /// Display hints of the picture that plays.
    fn display_hints(&self) -> DisplayHints;
}

/// A [`PlaybackEngine`] that also owns a [`VideoSurface`] and reports through pulled events.
pub trait SurfaceEngine: PlaybackEngine + VideoSurface {
    /// Engine events since the last call, in order. The host calls it once per UI frame.
    fn poll_events(&self) -> Vec<EngineEvent>;
    /// Counters since the last `load`.
    fn stats(&self) -> VideoStats;
    /// Audio outputs the engine knows.
    fn audio_devices(&self) -> Vec<AudioDevice>;
    /// Switches the audio output; `false` if the id is unknown.
    fn set_audio_device(&self, id: &str) -> bool;
    /// What this engine supports.
    fn capabilities(&self) -> Capabilities;
}
