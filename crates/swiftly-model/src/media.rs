//! Playback-side models (JellyfinKit/Models.swift:506-846).

use serde::{Deserialize, Serialize};

use crate::l10n::{Localizer, Source};
use crate::lenient::{NumberValue, null_default};

/// Answer of `PlaybackInfo` (Models.swift:508).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct PlaybackInfoResponse {
    /// The versions; a refusal often carries none, so missing or `null` is an
    /// empty list instead of an error (Models.swift:526-534).
    #[serde(default, deserialize_with = "null_default")]
    pub media_sources: Vec<MediaSource>,
    /// Session id for reports.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub play_session_id: Option<String>,
    /// Why the server names no version: `NotAllowed`, `NoCompatibleStream`,
    /// `RateLimitExceeded` (Models.swift:511).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
}

/// One file version of a title (Models.swift:537).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct MediaSource {
    /// Source id.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// Version name ("1080p").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Container (`mkv`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub container: Option<String>,
    /// File size in bytes.
    #[serde(
        default,
        deserialize_with = "crate::lenient::whole_number",
        skip_serializing_if = "Option::is_none"
    )]
    pub size: Option<i64>,
    /// Direct play possible.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub supports_direct_play: Option<bool>,
    /// Direct stream possible.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub supports_direct_stream: Option<bool>,
    /// Transcoding possible.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub supports_transcoding: Option<bool>,
    /// Relative transcoding address.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transcoding_url: Option<String>,
    /// Video, audio and subtitle tracks.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media_streams: Option<Vec<MediaStream>>,
    /// Audio track the server would choose for this user (Models.swift:547).
    #[serde(
        default,
        deserialize_with = "crate::lenient::whole_number",
        skip_serializing_if = "Option::is_none"
    )]
    pub default_audio_stream_index: Option<i64>,
    /// Subtitle track the server would choose; `-1` means none.
    #[serde(
        default,
        deserialize_with = "crate::lenient::whole_number",
        skip_serializing_if = "Option::is_none"
    )]
    pub default_subtitle_stream_index: Option<i64>,
    /// Runtime of the file in ticks.
    #[serde(
        default,
        deserialize_with = "crate::lenient::whole_number",
        skip_serializing_if = "Option::is_none"
    )]
    pub run_time_ticks: Option<i64>,
}

impl MediaSource {
    /// The runtime in seconds if the server knows it (Models.swift:560).
    /// libVLC reports no length for MPEG-TS over HTTP, so this is the fallback.
    pub fn runtime_seconds(&self) -> Option<f64> {
        let ticks = self.run_time_ticks.filter(|t| *t > 0)?;
        Some(ticks as f64 / 10_000_000.0)
    }

    /// Picture height of the first video track, for "2160p" (Models.swift:566).
    pub fn height(&self) -> Option<i64> {
        self.video_track().and_then(|s| s.height)
    }

    /// The first video track (FileDetails.swift:67).
    pub fn video_track(&self) -> Option<&MediaStream> {
        self.media_streams
            .iter()
            .flatten()
            .find(|s| s.type_.as_deref() == Some("Video"))
    }

    /// Codec of the first video track (FileDetails.swift:74).
    pub fn video_codec(&self) -> Option<&str> {
        self.video_track().and_then(|s| s.codec.as_deref())
    }

    /// How the server would deliver this source (Models.swift:587).
    pub fn delivery_method(&self) -> DeliveryMethod {
        if self.supports_direct_play == Some(true) {
            DeliveryMethod::DirectPlay
        } else if self.supports_direct_stream == Some(true) {
            DeliveryMethod::DirectStream
        } else {
            DeliveryMethod::Transcode
        }
    }

    /// The name the server gives this version; without one the placeholder
    /// (MediaVersions.swift:60), German source text.
    pub fn version_name(&self) -> String {
        self.version_name_with(&Source)
    }

    /// As [`MediaSource::version_name`] through a localizer (key `"Fassung"`).
    pub fn version_name_with(&self, l: &dyn Localizer) -> String {
        let trimmed = self.name.as_deref().map(str::trim).unwrap_or("");
        if trimmed.is_empty() {
            l.text("Fassung", &[])
        } else {
            trimmed.to_string()
        }
    }

    /// What tells two versions apart at a glance: "2160p · HEVC · 18,6 GB"
    /// (MediaVersions.swift:66). `size_text` formats a byte count
    /// (`DownloadRules.size` in Swift, a UI concern).
    pub fn version_detail(&self, size_text: &dyn Fn(i64) -> String) -> String {
        let mut parts: Vec<String> = Vec::new();
        if let Some(h) = self.height().filter(|h| *h > 0) {
            parts.push(format!("{h}p"));
        }
        if let Some(codec) = self.video_codec().filter(|c| !c.is_empty()) {
            parts.push(codec.to_uppercase());
        }
        if let Some(size) = self.size.filter(|s| *s > 0) {
            parts.push(size_text(size));
        }
        parts.join(" · ")
    }
}

/// How a source reaches the player (Models.swift:594).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DeliveryMethod {
    /// File as is.
    DirectPlay,
    /// Re-muxed.
    DirectStream,
    /// Re-encoded.
    Transcode,
}

impl DeliveryMethod {
    /// The UI spelling, Swift `rawValue`: "Direct Play", "Direct Stream", "Transcode".
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::DirectPlay => "Direct Play",
            Self::DirectStream => "Direct Stream",
            Self::Transcode => "Transcode",
        }
    }

    /// Everything except transcoding (Models.swift:599).
    pub fn is_lossless(self) -> bool {
        self != Self::Transcode
    }

    /// The spelling Jellyfin expects in playback reports (Models.swift:603).
    pub fn wire_name(self) -> &'static str {
        match self {
            Self::DirectPlay => "DirectPlay",
            Self::DirectStream => "DirectStream",
            Self::Transcode => "Transcode",
        }
    }
}

/// Dynamic range of a video track (JellyfinKit/ColorSnap.swift:14), the
/// server's `VideoRangeType` values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ColorRange {
    /// `Unknown`
    Unknown,
    /// `SDR`
    Sdr,
    /// `HDR10`
    Hdr10,
    /// `HLG`
    Hlg,
    /// `DOVI`
    DolbyVision,
    /// `DOVIWithHDR10`
    DolbyVisionHdr10,
    /// `DOVIWithHLG`
    DolbyVisionHlg,
    /// `DOVIWithSDR`
    DolbyVisionSdr,
    /// `DOVIWithEL`
    DolbyVisionEl,
    /// `DOVIWithHDR10Plus`
    DolbyVisionHdr10Plus,
    /// `DOVIWithELHDR10Plus`
    DolbyVisionElHdr10Plus,
    /// `DOVIInvalid`
    DolbyVisionInvalid,
    /// `HDR10Plus`
    Hdr10Plus,
}

impl ColorRange {
    /// Parse the server string; unknown values give `None` (ColorSnap.swift:14).
    pub fn from_raw(raw: &str) -> Option<Self> {
        Some(match raw {
            "Unknown" => Self::Unknown,
            "SDR" => Self::Sdr,
            "HDR10" => Self::Hdr10,
            "HLG" => Self::Hlg,
            "DOVI" => Self::DolbyVision,
            "DOVIWithHDR10" => Self::DolbyVisionHdr10,
            "DOVIWithHLG" => Self::DolbyVisionHlg,
            "DOVIWithSDR" => Self::DolbyVisionSdr,
            "DOVIWithEL" => Self::DolbyVisionEl,
            "DOVIWithHDR10Plus" => Self::DolbyVisionHdr10Plus,
            "DOVIWithELHDR10Plus" => Self::DolbyVisionElHdr10Plus,
            "DOVIInvalid" => Self::DolbyVisionInvalid,
            "HDR10Plus" => Self::Hdr10Plus,
            _ => return None,
        })
    }

    /// The server string (Swift `rawValue`).
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Unknown => "Unknown",
            Self::Sdr => "SDR",
            Self::Hdr10 => "HDR10",
            Self::Hlg => "HLG",
            Self::DolbyVision => "DOVI",
            Self::DolbyVisionHdr10 => "DOVIWithHDR10",
            Self::DolbyVisionHlg => "DOVIWithHLG",
            Self::DolbyVisionSdr => "DOVIWithSDR",
            Self::DolbyVisionEl => "DOVIWithEL",
            Self::DolbyVisionHdr10Plus => "DOVIWithHDR10Plus",
            Self::DolbyVisionElHdr10Plus => "DOVIWithELHDR10Plus",
            Self::DolbyVisionInvalid => "DOVIInvalid",
            Self::Hdr10Plus => "HDR10Plus",
        }
    }

    /// Whether this is an extended range at all (ColorSnap.swift:30).
    pub fn is_hdr(self) -> bool {
        !matches!(
            self,
            Self::Unknown | Self::Sdr | Self::DolbyVisionSdr | Self::DolbyVisionInvalid
        )
    }
}

/// One track of a source (Models.swift:641).
///
/// The `*_raw` fields hold what the wire carried; use the accessor methods.
/// They are separate on purpose (Models.swift:707-727): an unknown range type
/// must not make the whole track unreadable, and numbers sent as text must
/// not either.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct MediaStream {
    /// Codec name (`h264`, `eac3` ...).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codec: Option<String>,
    /// `Video`, `Audio` or `Subtitle`.
    #[serde(rename = "Type", skip_serializing_if = "Option::is_none")]
    pub type_: Option<String>,
    /// Language code.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    /// The server's long label; unusable for one line, see [`MediaStream::short`].
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display_title: Option<String>,
    /// Audio channels.
    #[serde(
        default,
        deserialize_with = "crate::lenient::whole_number",
        skip_serializing_if = "Option::is_none"
    )]
    pub channels: Option<i64>,
    /// Default track.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_default: Option<bool>,
    /// Forced subtitles (Models.swift:675).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_forced: Option<bool>,
    /// A subtitle file next to the film (Models.swift:679).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_external: Option<bool>,
    /// SDH/CC subtitles (Models.swift:682).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_hearing_impaired: Option<bool>,
    /// Audio is in the title's original language; Jellyfin 12 and later.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_original: Option<bool>,
    /// Displayed aspect ratio ("16:9").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub aspect_ratio: Option<String>,
    /// Track title from the file ("Forced", "SDH", "Kommentar").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Where the server delivers an external subtitle file.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delivery_url: Option<String>,
    /// How the server delivers a subtitle in this answer: `External` (a file at `DeliveryUrl`, also for a track
    /// inside the container when the playback is a transcode), `Embed`, `Encode` (burned in), `Hls`, `Drop`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delivery_method: Option<String>,
    /// Track index.
    #[serde(
        default,
        deserialize_with = "crate::lenient::whole_number",
        skip_serializing_if = "Option::is_none"
    )]
    pub index: Option<i64>,
    /// The stream's place inside the file, where [`MediaStream::index`] is not that number: Plex's `index` is its
    /// stream id (unique per item), the engine counts the file's streams. `None` where `index` already is it
    /// (Jellyfin, Emby). The engine numbers a track by this (Models.swift `containerIndex`, wire name `ContainerIndex`).
    #[serde(
        default,
        deserialize_with = "crate::lenient::whole_number",
        skip_serializing_if = "Option::is_none"
    )]
    pub container_index: Option<i64>,
    /// Picture height.
    #[serde(
        default,
        deserialize_with = "crate::lenient::whole_number",
        skip_serializing_if = "Option::is_none"
    )]
    pub height: Option<i64>,
    /// Picture width.
    #[serde(
        default,
        deserialize_with = "crate::lenient::whole_number",
        skip_serializing_if = "Option::is_none"
    )]
    pub width: Option<i64>,
    /// `VideoRangeType` as text; see [`MediaStream::video_range_type`].
    #[serde(rename = "VideoRangeType", skip_serializing_if = "Option::is_none")]
    pub video_range_type_raw: Option<String>,
    /// Transfer curve.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color_transfer: Option<String>,
    /// Colour primaries.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color_primaries: Option<String>,
    /// `DvProfile` as sent; see [`MediaStream::dv_profile`].
    #[serde(rename = "DvProfile", skip_serializing_if = "Option::is_none")]
    pub dv_profile_raw: Option<NumberValue>,
    /// `DvBlSignalCompatibilityId` as sent; see [`MediaStream::dv_bl_signal_compatibility_id`].
    #[serde(
        rename = "DvBlSignalCompatibilityId",
        skip_serializing_if = "Option::is_none"
    )]
    pub dv_compatible_raw: Option<NumberValue>,
    /// `RealFrameRate` as sent (Models.swift:747).
    #[serde(rename = "RealFrameRate", skip_serializing_if = "Option::is_none")]
    pub real_frame_rate_raw: Option<NumberValue>,
    /// `AverageFrameRate` as sent.
    #[serde(rename = "AverageFrameRate", skip_serializing_if = "Option::is_none")]
    pub average_frame_rate_raw: Option<NumberValue>,
}

impl MediaStream {
    /// Set the dynamic range (the Swift initializer takes a `ColorRange`).
    pub fn with_video_range_type(mut self, range: ColorRange) -> Self {
        self.video_range_type_raw = Some(range.raw_value().to_string());
        self
    }

    /// Set both frame rates (Models.swift:665).
    pub fn with_frame_rates(mut self, real: Option<f64>, average: Option<f64>) -> Self {
        self.real_frame_rate_raw = Some(NumberValue::new(real));
        self.average_frame_rate_raw = Some(NumberValue::new(average));
        self
    }

    /// Set the Dolby Vision profile and base-layer compatibility (Models.swift:663).
    pub fn with_dolby_vision(mut self, profile: Option<i64>, compat: Option<i64>) -> Self {
        self.dv_profile_raw = profile.map(|v| NumberValue::new(Some(v as f64)));
        self.dv_compatible_raw = compat.map(|v| NumberValue::new(Some(v as f64)));
        self
    }

    /// Dynamic range; an unknown server value is `None` (Models.swift:715).
    pub fn video_range_type(&self) -> Option<ColorRange> {
        self.video_range_type_raw
            .as_deref()
            .and_then(ColorRange::from_raw)
    }

    /// Dolby Vision profile (5, 7, 8 ...) (Models.swift:730).
    pub fn dv_profile(&self) -> Option<i64> {
        exact_int(self.dv_profile_raw?.value?)
    }

    /// Base-layer compatibility (for profile 8: 1 = HDR10, 2 = SDR, 4 = HLG)
    /// (Models.swift:731).
    pub fn dv_bl_signal_compatibility_id(&self) -> Option<i64> {
        exact_int(self.dv_compatible_raw?.value?)
    }

    /// Exact frame rate (Models.swift:750).
    pub fn real_frame_rate(&self) -> Option<f64> {
        self.real_frame_rate_raw?.value
    }

    /// Averaged frame rate (Models.swift:751).
    pub fn average_frame_rate(&self) -> Option<f64> {
        self.average_frame_rate_raw?.value
    }

    /// The more reliable of the two frame rates, or `None` if it cannot be
    /// trusted (Models.swift:759). Plausible is above 1 and below 250; if the
    /// two differ by more than 0.5 the rate fluctuates and nothing is returned.
    pub fn frame_rate(&self) -> Option<f64> {
        let plausible = |v: Option<f64>| v.filter(|v| *v > 1.0 && *v < 250.0);
        let Some(real) = plausible(self.real_frame_rate()) else {
            return plausible(self.average_frame_rate());
        };
        if let Some(avg) = plausible(self.average_frame_rate())
            && (real - avg).abs() > 0.5
        {
            return None;
        }
        Some(real)
    }

    /// Short readable label, "Deutsch · DTS-HD MA 5.1" (Models.swift:800),
    /// German source text.
    pub fn short(&self) -> String {
        self.short_with(&Source)
    }

    /// As [`MediaStream::short`] through a localizer (keys `"Stereo"`,
    /// `"Mono"`, plus [`Localizer::language_name`]).
    pub fn short_with(&self, l: &dyn Localizer) -> String {
        let mut parts: Vec<String> = Vec::new();
        if let Some(language) = l.language_name(self.language.as_deref()) {
            parts.push(language);
        }
        if let Some(codec) = &self.codec {
            parts.push(codec_name(codec));
        }
        // Below one channel the value is broken and is omitted.
        if let Some(channels) = self.channels.filter(|c| *c > 0)
            && self.type_.as_deref() == Some("Audio")
        {
            parts.push(match channels {
                2 => l.text("Stereo", &[]),
                1 => l.text("Mono", &[]),
                n => format!("{}.1", n - 1),
            });
        }
        if parts.is_empty() {
            self.display_title.clone().unwrap_or_else(|| "—".into())
        } else {
            parts.join(" · ")
        }
    }

    /// Language name in the interface language (Models.swift:815).
    pub fn language_name(&self, l: &dyn Localizer) -> Option<String> {
        l.language_name(self.language.as_deref())
    }
}

/// `Int(exactly:)`: only whole, finite values that fit.
fn exact_int(v: f64) -> Option<i64> {
    // 2^63 as f64 is exact; i64::MIN as f64 is -2^63.
    (v.is_finite()
        && v.fract() == 0.0
        && (-9_223_372_036_854_775_808.0..9_223_372_036_854_775_808.0).contains(&v))
    .then_some(v as i64)
}

/// Readable codec name (Models.swift:820-844); unknown codecs in capitals.
pub fn codec_name(codec: &str) -> String {
    match codec.to_lowercase().as_str() {
        "dca" | "dts" => "DTS".into(),
        "dtshd" | "dts-hd" => "DTS-HD".into(),
        "truehd" => "TrueHD".into(),
        "eac3" => "Dolby Digital+".into(),
        "ac3" => "Dolby Digital".into(),
        "aac" => "AAC".into(),
        "flac" => "FLAC".into(),
        "opus" => "Opus".into(),
        "pgssub" | "pgs" => "PGS".into(),
        "subrip" | "srt" => "SRT".into(),
        "ass" | "ssa" => "ASS".into(),
        "dvdsub" | "vobsub" => "VOBSUB".into(),
        "hevc" | "h265" => "HEVC".into(),
        "h264" | "avc" => "H.264".into(),
        "av1" => "AV1".into(),
        _ => codec.to_uppercase(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stream(json: &str) -> MediaStream {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn frame_rate_rules() {
        let s = |r: Option<f64>, a: Option<f64>| MediaStream::default().with_frame_rates(r, a);
        assert_eq!(s(Some(23.976), Some(23.976)).frame_rate(), Some(23.976));
        assert_eq!(s(Some(24.0), Some(30.0)).frame_rate(), None);
        assert_eq!(s(None, Some(25.0)).frame_rate(), Some(25.0));
        assert_eq!(s(Some(0.0), Some(25.0)).frame_rate(), Some(25.0));
        assert_eq!(s(Some(500.0), None).frame_rate(), None);
        assert_eq!(s(Some(24.0), None).frame_rate(), Some(24.0));
    }

    #[test]
    fn tolerant_numbers_and_unknown_range() {
        let m = stream(
            r#"{"Codec":"hevc","Type":"Video","RealFrameRate":"23.976","AverageFrameRate":"x",
                "DvProfile":"8","DvBlSignalCompatibilityId":1.5,"VideoRangeType":"BrandNew"}"#,
        );
        assert_eq!(m.codec.as_deref(), Some("hevc"));
        assert_eq!(m.real_frame_rate(), Some(23.976));
        assert_eq!(m.average_frame_rate(), None);
        assert_eq!(m.dv_profile(), Some(8));
        assert_eq!(m.dv_bl_signal_compatibility_id(), None);
        assert_eq!(m.video_range_type(), None);
        let m = stream(r#"{"VideoRangeType":"DOVIWithHDR10"}"#);
        assert_eq!(m.video_range_type(), Some(ColorRange::DolbyVisionHdr10));
        assert!(ColorRange::DolbyVisionHdr10.is_hdr() && !ColorRange::Sdr.is_hdr());
    }

    #[test]
    fn short_label() {
        let m = stream(r#"{"Codec":"dts","Type":"Audio","Language":"ger","Channels":6}"#);
        assert_eq!(m.short(), "GER · DTS · 5.1");
        let m = stream(r#"{"Codec":"aac","Type":"Audio","Channels":2}"#);
        assert_eq!(m.short(), "AAC · Stereo");
        assert_eq!(stream(r#"{"DisplayTitle":"X"}"#).short(), "X");
        assert_eq!(stream("{}").short(), "—");
        assert_eq!(codec_name("mpeg4"), "MPEG4");
    }

    #[test]
    fn delivery_and_playback_info() {
        let info: PlaybackInfoResponse =
            serde_json::from_str(r#"{"ErrorCode":"NotAllowed"}"#).unwrap();
        assert!(info.media_sources.is_empty());
        assert_eq!(info.error_code.as_deref(), Some("NotAllowed"));
        let info: PlaybackInfoResponse = serde_json::from_str(r#"{"MediaSources":null}"#).unwrap();
        assert!(info.media_sources.is_empty());
        let s = MediaSource {
            supports_direct_stream: Some(true),
            ..Default::default()
        };
        assert_eq!(s.delivery_method(), DeliveryMethod::DirectStream);
        assert_eq!(
            MediaSource::default().delivery_method(),
            DeliveryMethod::Transcode
        );
        assert!(!DeliveryMethod::Transcode.is_lossless());
        assert_eq!(DeliveryMethod::DirectPlay.raw_value(), "Direct Play");
        assert_eq!(DeliveryMethod::DirectPlay.wire_name(), "DirectPlay");
    }

    #[test]
    fn runtime_and_roundtrip() {
        let s: MediaSource = serde_json::from_str(r#"{"RunTimeTicks":606000000}"#).unwrap();
        assert_eq!(s.runtime_seconds(), Some(60.6));
        let s: MediaSource = serde_json::from_str(r#"{"RunTimeTicks":0}"#).unwrap();
        assert_eq!(s.runtime_seconds(), None);
        let m = stream(r#"{"Codec":"h264","RealFrameRate":"24"}"#);
        let back: MediaStream = serde_json::from_str(&serde_json::to_string(&m).unwrap()).unwrap();
        assert_eq!(back.real_frame_rate(), Some(24.0));
    }
}
