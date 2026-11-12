//! What the tech badge shows: the rules, not the presentation (JellyfinKit/TechDetails.swift),
//! plus the pure line model of the measuring badge (Sources/Shared/TechBadge.swift).
//!
//! The codec, VLC-id and channel pieces live in [`crate::track_label`] (the track rules need them
//! too) and are re-exported here under the Swift names. Everything else is ported 1:1.
//! German texts go through [`Localizer`] with the exact German key of the Swift catalog.

use swiftly_model::{ColorRange, DeliveryMethod, Localizer, MediaStream};

use crate::track_label::{self, LabelText};
pub use crate::track_label::{
    channel_word, codec_name_value, codec_name_value_vlc_id as codec_name_value_vlc,
};

// MARK: Track names

/// An audio track in one line, e.g. "German · AAC · 5.1" (TechDetails.swift:90).
///
/// For tracks the player reports itself; the rule lives in [`track_label::audio`].
pub fn audio_track_name(
    language: Option<&str>,
    codec: Option<&str>,
    channels: Option<i64>,
    text: &dyn LabelText,
) -> Option<String> {
    track_label::audio(language, codec, channels, text)
}

/// A track's language as a human reads it (TechDetails.swift:115); the rule is
/// [`track_label::language`], so badge and track list agree.
pub fn language(raw: Option<&str>, text: &dyn LabelText) -> Option<String> {
    track_label::language(raw, text)
}

// MARK: Numbers

/// Bits per second as text. From one megabit in Mbit/s, below that in kbit/s
/// (TechDetails.swift:123).
pub fn bitrate(bit_per_second: Option<f64>) -> Option<String> {
    let b = bit_per_second.filter(|b| *b > 0.0)?;
    Some(if b >= 1_000_000.0 {
        format!("{:.1} Mbit/s", b / 1_000_000.0)
    } else {
        format!("{:.0} kbit/s", b / 1_000.0)
    })
}

/// Frame rate with at most three decimals, without the zeros nobody reads: 23.976 stays,
/// 59.94 stays 59.94 and 25.000 becomes 25 (TechDetails.swift:136).
pub fn frame_rate(value: Option<f64>) -> Option<String> {
    let w = value.filter(|w| *w > 0.0)?;
    let mut text = format!("{:.3}", (w * 1000.0).round() / 1000.0);
    while text.ends_with('0') {
        text.pop();
    }
    if text.ends_with('.') {
        text.pop();
    }
    Some(text)
}

/// Resolution plus bit depth and range, as far as known (TechDetails.swift:145).
pub fn image_row(
    width: Option<i64>,
    height: Option<i64>,
    depth: Option<i64>,
    reach: Option<&str>,
) -> Option<String> {
    let (width, height) = (width.filter(|w| *w > 0)?, height.filter(|h| *h > 0)?);
    let mut text = format!("{width}×{height}");
    if let Some(depth) = depth.filter(|d| *d > 0) {
        text.push_str(&format!(" · {depth} bit"));
    }
    if let Some(reach) = reach.filter(|r| !r.is_empty() && r.to_uppercase() != "SDR") {
        text.push_str(&format!(" · {}", reach.to_uppercase()));
    }
    Some(text)
}

// MARK: Dynamic range

/// The range a track reaches (`ColorInfo.reach`, ColorSnap.swift:66): the server's type if it
/// says anything, else the transfer curve. Wide primaries alone are not HDR.
pub fn reach(
    range: Option<ColorRange>,
    curve: Option<&str>,
    _primaries: Option<&str>,
) -> ColorRange {
    if let Some(range) = range.filter(|r| *r != ColorRange::Unknown) {
        return range;
    }
    match curve.map(str::to_lowercase).as_deref() {
        Some("smpte2084" | "smpte-st-2084" | "pq") => ColorRange::Hdr10,
        Some("arib-std-b67" | "hlg") => ColorRange::Hlg,
        _ => ColorRange::Unknown,
    }
}

/// Which HDR kind the file carries: "HDR10", "HDR10+", "HLG", "SDR" or "Dolby Vision P8.1 ·
/// HDR10". The file's format, not the output; names are not translated. `None` if the server
/// says nothing usable (TechDetails.swift:168).
pub fn dynamics(track: Option<&MediaStream>) -> Option<String> {
    let track = track?;
    let curve = track.color_transfer.as_deref();
    let primaries = track.color_primaries.as_deref();
    let mut range = reach(track.video_range_type(), curve, primaries);
    // Invalid DV data plays as the base layer; then what the raw data says counts.
    if range == ColorRange::DolbyVisionInvalid {
        range = reach(None, curve, primaries);
    }
    let base = match range {
        ColorRange::Unknown | ColorRange::DolbyVisionInvalid => return None,
        ColorRange::Sdr => return Some("SDR".to_owned()),
        ColorRange::Hdr10 => return Some("HDR10".to_owned()),
        ColorRange::Hdr10Plus => return Some("HDR10+".to_owned()),
        ColorRange::Hlg => return Some("HLG".to_owned()),
        ColorRange::DolbyVision => None,
        ColorRange::DolbyVisionHdr10 => Some("HDR10"),
        ColorRange::DolbyVisionHlg => Some("HLG"),
        ColorRange::DolbyVisionSdr => Some("SDR"),
        ColorRange::DolbyVisionEl => Some("EL"),
        ColorRange::DolbyVisionHdr10Plus => Some("HDR10+"),
        ColorRange::DolbyVisionElHdr10Plus => Some("EL · HDR10+"),
    };
    let mut text = "Dolby Vision".to_owned();
    if let Some(profile) =
        dv_profile_word(track.dv_profile(), track.dv_bl_signal_compatibility_id())
    {
        text.push_str(&format!(" P{profile}"));
    }
    if let Some(base) = base {
        text.push_str(&format!(" · {base}"));
    }
    Some(text)
}

/// "8.1", "5", "7": the part after the dot exists only for profiles 8 and 10
/// (TechDetails.swift:205).
pub fn dv_profile_word(profile: Option<i64>, compatible: Option<i64>) -> Option<String> {
    let profile = profile.filter(|p| *p > 0)?;
    if [8, 10].contains(&profile)
        && let Some(compatible) = compatible.filter(|c| *c >= 0)
        && !(profile == 8 && compatible == 0)
    {
        return Some(format!("{profile}.{compatible}"));
    }
    Some(profile.to_string())
}

// MARK: Delivery

/// How much the delivery method weighs; the colour depends on it (TechDetails.swift:221).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Weight {
    /// Direct Play and Direct Stream: lossless, look the same.
    Good,
    /// Transcoding, the one thing this app promises to avoid.
    Cautionary,
}

/// Only transcoding stands out (TechDetails.swift:223).
pub fn weight(method: DeliveryMethod) -> Weight {
    if method.is_lossless() {
        Weight::Good
    } else {
        Weight::Cautionary
    }
}

/// The word on the badge (TechDetails.swift:228); keys are the German catalog texts.
pub fn delivery(method: DeliveryMethod, l: &dyn Localizer) -> String {
    l.text(
        match method {
            DeliveryMethod::DirectPlay => "Direct Play",
            DeliveryMethod::DirectStream => "Direct Stream",
            DeliveryMethod::Transcode => "Transkodiert",
        },
        &[],
    )
}

// MARK: Measuring badge (TechBadge.swift)

/// One line of the badge: an optional quiet name and the value. A conspicuous line is drawn
/// entirely in the warning colour with a symbol, so it stands out by shape too
/// (TechBadge.swift:502).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BadgeLine {
    /// Quiet name of a detail line ("Bild", "Puffer"); `None` for measuring lines.
    pub name: Option<String>,
    /// The value, or the whole text of a measuring line.
    pub text: String,
    /// Whether the line is drawn as a warning.
    pub conspicuous: bool,
}

impl BadgeLine {
    fn detail(name: String, value: String, conspicuous: bool) -> Self {
        Self {
            name: Some(name),
            text: value,
            conspicuous,
        }
    }

    fn measure(text: String, conspicuous: bool) -> Self {
        Self {
            name: None,
            text,
            conspicuous,
        }
    }

    /// Name and value in one string, as a conspicuous detail line is drawn.
    pub fn full_text(&self) -> String {
        match &self.name {
            Some(name) => format!("{name} {}", self.text),
            None => self.text.clone(),
        }
    }
}

/// What the player counts while playing (`PlayValues`); `None` fields are not measured yet.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct PlayValues {
    /// Demuxer name.
    pub demuxer: String,
    /// Input counter text ("Eingang ...").
    pub input: String,
    /// Reserve ahead of the playhead in seconds, already computed from the counters.
    pub reserve_seconds: Option<f64>,
    /// Bytes read ahead (shown in measure mode as KiB).
    pub pre_advice_bytes: i64,
    /// Dropped frames.
    pub discarded: i64,
    /// Late frames.
    pub too_late: i64,
    /// Lost audio buffers.
    pub audio_lost: i64,
    /// Corrupted blocks.
    pub damaged: i64,
    /// Jumps.
    pub jumps: i64,
    /// Frames shown in total.
    pub shown: i64,
    /// Average shown frames per second.
    pub shows_per_second: Option<f64>,
    /// Average decoded frames per second.
    pub decoded_per_second: Option<f64>,
    /// Playback pace against the clock, 1.0 = real time.
    pub run_share: Option<f64>,
}

impl PlayValues {
    /// Any frame or audio loss (TechBadge.swift:288).
    pub fn has_loss(&self) -> bool {
        self.discarded > 0 || self.too_late > 0 || self.audio_lost > 0
    }
}

/// The pure line texts of the tech badge. The upper part describes the file, the lower part
/// (separated by a hairline in measure mode) counts up while playing.
pub struct MeasuredBadge;

impl MeasuredBadge {
    /// `1.5` -> "1,5" (TechBadge.swift:284).
    pub fn comma(value: f64) -> String {
        format!("{value:.1}").replace('.', ",")
    }

    /// `m:ss` or `h:mm:ss` (TechBadge.swift:326).
    pub fn clock(seconds: f64) -> String {
        let whole = seconds.max(0.0) as i64;
        let (s, m, h) = (whole % 60, (whole / 60) % 60, whole / 3600);
        if h > 0 {
            format!("{h}:{m:02}:{s:02}")
        } else {
            format!("{m}:{s:02}")
        }
    }

    /// Codec, resolution and HDR kind; the frame rate only in measure mode
    /// (TechBadge.swift:200).
    pub fn image(video: Option<&MediaStream>, measure: bool) -> Option<String> {
        let parts: Vec<String> = [
            codec_name_value(video.and_then(|v| v.codec.as_deref())),
            image_row(
                video.and_then(|v| v.width),
                video.and_then(|v| v.height),
                None,
                None,
            ),
            dynamics(video),
            if measure {
                frame_rate(video.and_then(MediaStream::frame_rate)).map(|r| format!("{r} fps"))
            } else {
                None
            },
        ]
        .into_iter()
        .flatten()
        .collect();
        (!parts.is_empty()).then(|| parts.join(" · "))
    }

    /// Codec, channels, language of the playing audio track (TechBadge.swift:211).
    pub fn audio(audio: Option<&MediaStream>, text: &dyn LabelText) -> Option<String> {
        let mut out = codec_name_value(audio?.codec.as_deref())?;
        if let Some(k) = channel_word(audio.and_then(|a| a.channels)) {
            out.push_str(&format!(" · {k}"));
        }
        if let Some(l) = language(audio.and_then(|a| a.language.as_deref()), text) {
            out.push_str(&format!(" · {l}"));
        }
        Some(out)
    }

    /// Codec and language of the playing subtitle (TechBadge.swift:219).
    pub fn subtitle(subtitle: Option<&MediaStream>, text: &dyn LabelText) -> Option<String> {
        let mut out = codec_name_value(subtitle?.codec.as_deref())?;
        if let Some(l) = language(subtitle.and_then(|s| s.language.as_deref()), text) {
            out.push_str(&format!(" · {l}"));
        }
        Some(out)
    }

    /// Container line ("MP4 · 0.3 GB", it already carries the size) plus the average bitrate
    /// (size over runtime) once both are known (TechBadge.swift:243).
    pub fn file(
        container: Option<&str>,
        size: Option<i64>,
        duration: Option<f64>,
    ) -> Option<String> {
        let container = container?;
        let bytes_per_second = size
            .filter(|b| *b > 0)
            .zip(duration.filter(|d| *d > 1.0))
            .map(|(b, d)| b as f64 / d);
        match bitrate(bytes_per_second.map(|b| b * 8.0)) {
            Some(rate) => Some(format!("{container} · Ø {rate}")),
            None => Some(container.to_owned()),
        }
    }

    /// The upper part: the file's lines "Bild", "Ton", "Untertitel", "Datei" for the rows that
    /// have a value (TechBadge.swift:94-97).
    pub fn upper_lines(
        image: Option<String>,
        audio: Option<String>,
        subtitle: Option<String>,
        file: Option<String>,
        l: &dyn Localizer,
    ) -> Vec<BadgeLine> {
        [
            ("Bild", image),
            ("Ton", audio),
            ("Untertitel", subtitle),
            ("Datei", file),
        ]
        .into_iter()
        .filter_map(|(name, value)| value.map(|v| BadgeLine::detail(l.text(name, &[]), v, false)))
        .collect()
    }

    /// "Stelle 41:12 / 1:30:00", only with a known runtime (TechBadge.swift:317).
    pub fn time_row(position: f64, duration: f64, l: &dyn Localizer) -> Option<BadgeLine> {
        (duration > 1.0).then(|| {
            BadgeLine::measure(
                format!(
                    "{} {} / {}",
                    l.text("Stelle", &[]),
                    Self::clock(position),
                    Self::clock(duration)
                ),
                false,
            )
        })
    }

    /// The lower, measured part. Outside measure mode only the buffer line, plus the loss line
    /// if something was lost; in measure mode all lines (TechBadge.swift:101-153).
    ///
    /// `should_fps` is the file's frame rate, `screen_hertz` the measured refresh rate of the
    /// screen (iOS only), `bytes_per_second` the file's average need.
    pub fn lower_lines(
        values: &PlayValues,
        should_fps: Option<f64>,
        screen_hertz: Option<f64>,
        measure: bool,
        l: &dyn Localizer,
    ) -> Vec<BadgeLine> {
        let mut lines = vec![Self::buffer_row(values, measure, l)];
        let loss = values.has_loss();
        if measure || loss {
            lines.push(BadgeLine::measure(
                format!(
                    "{} {} · {} {} · {} {}",
                    l.text("Verworfen", &[]),
                    values.discarded,
                    l.text("zu spät", &[]),
                    values.too_late,
                    l.text("Ton weg", &[]),
                    values.audio_lost
                ),
                loss,
            ));
        }
        if !measure {
            return lines;
        }
        lines.push(BadgeLine::measure(
            format!("{} {}", l.text("Demuxer", &[]), values.demuxer),
            false,
        ));
        lines.push(Self::shows_row(values, should_fps, l));
        lines.push(Self::run_row(values, l));
        if let Some(hz) = screen_hertz {
            lines.push(BadgeLine::measure(
                format!("{} {} Hz", l.text("Schirm", &[]), hz.round() as i64),
                hz < 70.0,
            ));
        }
        lines.push(Self::decode_row(values, should_fps, l));
        let bad = values.damaged > 0 || values.jumps > 0;
        lines.push(BadgeLine::measure(
            format!(
                "{} {} · {} {}",
                l.text("Beschädigt", &[]),
                values.damaged,
                l.text("Sprünge", &[]),
                values.jumps
            ),
            bad,
        ));
        lines
    }

    /// Reserve in seconds (conspicuous below two), KiB in measure mode, intake counter
    /// (TechBadge.swift:274).
    fn buffer_row(values: &PlayValues, measure: bool, l: &dyn Localizer) -> BadgeLine {
        let mut parts: Vec<String> = Vec::new();
        if let Some(seconds) = values.reserve_seconds {
            parts.push(format!("{} s", Self::comma(seconds)));
        }
        if measure {
            parts.push(format!("{} KiB", values.pre_advice_bytes / 1024));
        }
        parts.push(format!("{} {}", l.text("Eingang", &[]), values.input));
        let conspicuous = values.reserve_seconds.unwrap_or(f64::INFINITY) < 2.0;
        BadgeLine::detail(l.text("Puffer", &[]), parts.join(" · "), conspicuous)
    }

    fn rate_text(value: Option<f64>) -> String {
        value.map_or_else(|| "—".to_owned(), Self::comma)
    }

    /// Lags when more than two frames below the file's rate (window edge noise otherwise).
    fn lags(actual: Option<f64>, should: Option<f64>) -> bool {
        matches!((actual, should), (Some(a), Some(s)) if a < s - 2.0)
    }

    /// Shown frames per second against the file's rate (TechBadge.swift:340).
    fn shows_row(values: &PlayValues, should: Option<f64>, l: &dyn Localizer) -> BadgeLine {
        BadgeLine::measure(
            format!(
                "{} {} fps · {} {}",
                l.text("Zeigt Ø", &[]),
                Self::rate_text(values.shows_per_second),
                l.text("Gezeigt", &[]),
                values.shown
            ),
            Self::lags(values.shows_per_second, should),
        )
    }

    /// Position pace against the clock; below 97 percent it is hanging (TechBadge.swift:372).
    fn run_row(values: &PlayValues, l: &dyn Localizer) -> BadgeLine {
        let value = values.run_share.map_or_else(
            || "—".to_owned(),
            |s| format!("{} %", (s * 100.0).round() as i64),
        );
        BadgeLine::measure(
            format!("{} {value}", l.text("Lauf", &[])),
            values.run_share.unwrap_or(1.0) < 0.97,
        )
    }

    /// Decoded frames per second against the file's rate (TechBadge.swift:407).
    fn decode_row(values: &PlayValues, should: Option<f64>, l: &dyn Localizer) -> BadgeLine {
        BadgeLine::measure(
            format!(
                "{} {} fps",
                l.text("Dekodiert Ø", &[]),
                Self::rate_text(values.decoded_per_second)
            ),
            Self::lags(values.decoded_per_second, should),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_model::Source;

    /// Stand-in for the CLDR names of the German test locale.
    struct De;

    impl LabelText for De {
        fn language_name(&self, code: &str) -> Option<String> {
            match code {
                "deu" | "ger" | "de" => Some("Deutsch".to_owned()),
                "eng" | "en" => Some("Englisch".to_owned()),
                _ => None,
            }
        }
        fn knows_code(&self, code: &str) -> bool {
            matches!(code, "deu" | "ger" | "de" | "eng" | "en")
        }
        fn unknown(&self) -> String {
            "unbekannt".to_owned()
        }
        fn forced(&self) -> String {
            "Erzwungen".to_owned()
        }
        fn hearing_impaired(&self) -> String {
            "Hörgeschädigt".to_owned()
        }
        fn file(&self) -> String {
            "Datei".to_owned()
        }
    }

    fn vlc_id(s: &str) -> u32 {
        s.bytes()
            .enumerate()
            .fold(0, |a, (i, b)| a | (u32::from(b) << (8 * i)))
    }

    /// TechDetailsTests.codecNames
    #[test]
    fn codec_names() {
        assert_eq!(codec_name_value(Some("hevc")).as_deref(), Some("HEVC"));
        assert_eq!(codec_name_value(Some("h264")).as_deref(), Some("H.264"));
        assert_eq!(codec_name_value(Some("eac3")).as_deref(), Some("E-AC-3"));
        assert_eq!(
            codec_name_value(Some("hdmv_pgs_subtitle")).as_deref(),
            Some("PGS")
        );
        assert_eq!(
            codec_name_value(Some("wasauchimmer")).as_deref(),
            Some("WASAUCHIMMER")
        );
        assert_eq!(codec_name_value(Some("")), None);
        assert_eq!(codec_name_value(None), None);
    }

    /// TechDetailsTests.vlcIds
    #[test]
    fn vlc_ids() {
        let by = |s: &str| codec_name_value_vlc(vlc_id(s));
        assert_eq!(by("mp4a").as_deref(), Some("AAC"));
        assert_eq!(by("a52 ").as_deref(), Some("AC-3"));
        assert_eq!(by("dts ").as_deref(), Some("DTS"));
        assert_eq!(by("trhd").as_deref(), Some("TrueHD"));
        assert_eq!(by("mlpa"), codec_name_value(Some("truehd")));
        assert_eq!(by("wvtt"), codec_name_value(Some("webvtt")));
        assert_eq!(by("stpp"), codec_name_value(Some("ttml")));
        assert_eq!(by("dvbs"), codec_name_value(Some("DVBSUB")));
        assert_eq!(by("spu "), codec_name_value(Some("DVDSUB")));
        assert_eq!(by("bdpg"), codec_name_value(Some("PGSSUB")));
        assert_eq!(by("xxxx"), None);
        assert_eq!(codec_name_value_vlc(0), None);
    }

    /// TechDetailsTests.audioTrackName
    #[test]
    fn audio_track_names() {
        let n = |l, c, ch| audio_track_name(l, c, ch, &De);
        assert_eq!(
            n(Some("deu"), Some("AAC"), Some(6)).as_deref(),
            Some("Deutsch · AAC · 5.1")
        );
        assert_eq!(
            n(Some("German"), Some("DTS"), Some(2)).as_deref(),
            Some("Deutsch · DTS · Stereo")
        );
        assert_eq!(
            n(None, Some("AAC"), Some(2)).as_deref(),
            Some("AAC · Stereo")
        );
        assert_eq!(n(Some(""), None, Some(0)), None);
        let ger = n(Some("ger"), None, None);
        assert!(ger.as_deref().is_some_and(|s| !s.is_empty()));
        assert_ne!(ger.as_deref(), Some("ger"));
    }

    /// TechDetailsTests.channels
    #[test]
    fn channels() {
        assert_eq!(channel_word(Some(6)).as_deref(), Some("5.1"));
        assert_eq!(channel_word(Some(8)).as_deref(), Some("7.1"));
        assert_eq!(channel_word(Some(2)).as_deref(), Some("Stereo"));
        assert_eq!(channel_word(Some(1)).as_deref(), Some("Mono"));
        assert_eq!(channel_word(Some(3)).as_deref(), Some("3 ch"));
        assert_eq!(channel_word(Some(0)), None);
        assert_eq!(channel_word(None), None);
    }

    /// TechDetailsTests.bitrates
    #[test]
    fn bitrates() {
        assert_eq!(bitrate(Some(12_400_000.0)).as_deref(), Some("12.4 Mbit/s"));
        assert_eq!(bitrate(Some(640_000.0)).as_deref(), Some("640 kbit/s"));
        assert_eq!(bitrate(Some(0.0)), None);
        assert_eq!(bitrate(None), None);
    }

    /// TechDetailsTests.frameRates
    #[test]
    fn frame_rates() {
        assert_eq!(frame_rate(Some(23.976)).as_deref(), Some("23.976"));
        assert_eq!(frame_rate(Some(25.0)).as_deref(), Some("25"));
        assert_eq!(frame_rate(Some(59.94)).as_deref(), Some("59.94"));
        assert_eq!(frame_rate(Some(0.0)), None);
    }

    /// TechDetailsTests.imageRow
    #[test]
    fn image_rows() {
        assert_eq!(
            image_row(Some(1920), Some(1080), Some(10), Some("HDR10")).as_deref(),
            Some("1920×1080 · 10 bit · HDR10")
        );
        assert_eq!(
            image_row(Some(1920), Some(1080), None, Some("SDR")).as_deref(),
            Some("1920×1080")
        );
        assert_eq!(image_row(None, Some(1080), None, None), None);
    }

    /// TechDetailsTests.weight
    #[test]
    fn weights() {
        assert_eq!(weight(DeliveryMethod::DirectPlay), Weight::Good);
        assert_eq!(weight(DeliveryMethod::DirectStream), Weight::Good);
        assert_eq!(weight(DeliveryMethod::Transcode), Weight::Cautionary);
    }

    fn track(
        range: Option<ColorRange>,
        transfer: Option<&str>,
        profile: Option<i64>,
        compatible: Option<i64>,
    ) -> MediaStream {
        let mut s = MediaStream {
            codec: Some("hevc".to_owned()),
            type_: Some("Video".to_owned()),
            index: Some(0),
            height: Some(2160),
            width: Some(3840),
            color_transfer: transfer.map(str::to_owned),
            ..MediaStream::default()
        };
        if let Some(range) = range {
            s = s.with_video_range_type(range);
        }
        if profile.is_some() || compatible.is_some() {
            s = s.with_dolby_vision(profile, compatible);
        }
        s
    }

    fn dyn_of(range: Option<ColorRange>, p: Option<i64>, c: Option<i64>) -> Option<String> {
        dynamics(Some(&track(range, None, p, c)))
    }

    /// TechDetailsTests.dynamics
    #[test]
    fn dynamics_kinds() {
        use ColorRange::*;
        assert_eq!(dyn_of(Some(Sdr), None, None).as_deref(), Some("SDR"));
        assert_eq!(dyn_of(Some(Hdr10), None, None).as_deref(), Some("HDR10"));
        assert_eq!(
            dyn_of(Some(Hdr10Plus), None, None).as_deref(),
            Some("HDR10+")
        );
        assert_eq!(dyn_of(Some(Hlg), None, None).as_deref(), Some("HLG"));
        assert_eq!(
            dyn_of(Some(DolbyVision), Some(5), Some(0)).as_deref(),
            Some("Dolby Vision P5")
        );
        assert_eq!(
            dyn_of(Some(DolbyVisionHdr10), Some(8), Some(1)).as_deref(),
            Some("Dolby Vision P8.1 · HDR10")
        );
        assert_eq!(
            dyn_of(Some(DolbyVisionEl), Some(7), Some(6)).as_deref(),
            Some("Dolby Vision P7 · EL")
        );
        assert_eq!(
            dyn_of(Some(DolbyVisionHlg), Some(8), Some(4)).as_deref(),
            Some("Dolby Vision P8.4 · HLG")
        );
        // Without a profile only what is certain is shown.
        assert_eq!(
            dyn_of(Some(DolbyVisionHdr10), None, None).as_deref(),
            Some("Dolby Vision · HDR10")
        );
    }

    /// TechDetailsTests.dynamicsWithoutType
    #[test]
    fn dynamics_without_type() {
        use ColorRange::*;
        let with = |range, transfer| dynamics(Some(&track(range, transfer, None, None)));
        assert_eq!(
            with(Some(Unknown), Some("smpte2084")).as_deref(),
            Some("HDR10")
        );
        assert_eq!(with(None, Some("arib-std-b67")).as_deref(), Some("HLG"));
        assert_eq!(with(Some(Unknown), None), None);
        assert_eq!(dynamics(None), None);
        // Invalid Dolby Vision plays as the base layer.
        assert_eq!(
            with(Some(DolbyVisionInvalid), Some("smpte2084")).as_deref(),
            Some("HDR10")
        );
        assert_eq!(with(Some(DolbyVisionInvalid), None), None);
    }

    /// TechDetailsTests.dvOutJSON: the numbers may arrive as text.
    #[test]
    fn dolby_vision_fields_from_json() {
        let raw = r#"{"Codec":"hevc","Type":"Video","VideoRangeType":"DOVIWithHDR10","DvProfile":8,"DvBlSignalCompatibilityId":"1"}"#;
        let s: MediaStream = serde_json::from_str(raw).unwrap();
        assert_eq!(s.dv_profile(), Some(8));
        assert_eq!(s.dv_bl_signal_compatibility_id(), Some(1));
        assert_eq!(s.codec.as_deref(), Some("hevc"));
        assert_eq!(
            dynamics(Some(&s)).as_deref(),
            Some("Dolby Vision P8.1 · HDR10")
        );
    }

    #[test]
    fn dv_profile_words() {
        assert_eq!(dv_profile_word(Some(8), Some(0)).as_deref(), Some("8"));
        assert_eq!(dv_profile_word(Some(10), Some(1)).as_deref(), Some("10.1"));
        assert_eq!(dv_profile_word(Some(5), Some(1)).as_deref(), Some("5"));
        assert_eq!(dv_profile_word(Some(0), Some(1)), None);
    }

    #[test]
    fn delivery_words_use_german_keys() {
        assert_eq!(delivery(DeliveryMethod::DirectPlay, &Source), "Direct Play");
        assert_eq!(
            delivery(DeliveryMethod::DirectStream, &Source),
            "Direct Stream"
        );
        assert_eq!(delivery(DeliveryMethod::Transcode, &Source), "Transkodiert");
    }

    fn values() -> PlayValues {
        PlayValues {
            demuxer: "mkv".to_owned(),
            input: "4,2 Mbit/s".to_owned(),
            reserve_seconds: Some(11.4),
            pre_advice_bytes: 4096,
            shows_per_second: Some(23.9),
            decoded_per_second: Some(23.9),
            run_share: Some(1.0),
            shown: 539,
            ..PlayValues::default()
        }
    }

    #[test]
    fn badge_upper_part_describes_the_file() {
        let video = track(Some(ColorRange::Hdr10), None, None, None)
            .with_frame_rates(Some(23.976), Some(23.976));
        assert_eq!(
            MeasuredBadge::image(Some(&video), false).as_deref(),
            Some("HEVC · 3840×2160 · HDR10")
        );
        // The frame rate only explains stutter, so it shows in measure mode only.
        assert_eq!(
            MeasuredBadge::image(Some(&video), true).as_deref(),
            Some("HEVC · 3840×2160 · HDR10 · 23.976 fps")
        );
        assert_eq!(MeasuredBadge::image(None, true), None);
        let audio = MediaStream {
            codec: Some("eac3".to_owned()),
            channels: Some(6),
            language: Some("deu".to_owned()),
            ..MediaStream::default()
        };
        assert_eq!(
            MeasuredBadge::audio(Some(&audio), &De).as_deref(),
            Some("E-AC-3 · 5.1 · Deutsch")
        );
        let lines =
            MeasuredBadge::upper_lines(None, Some("A".into()), None, Some("B".into()), &Source);
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[1].full_text(), "Datei B");
    }

    #[test]
    fn badge_file_row_adds_average_rate() {
        assert_eq!(
            MeasuredBadge::file(Some("MP4 · 1 GB"), None, None).as_deref(),
            Some("MP4 · 1 GB")
        );
        // 150 MB over 100 s = 12 Mbit/s.
        assert_eq!(
            MeasuredBadge::file(Some("MKV"), Some(150_000_000), Some(100.0)).as_deref(),
            Some("MKV · Ø 12.0 Mbit/s")
        );
        assert_eq!(MeasuredBadge::file(None, Some(1), Some(100.0)), None);
    }

    #[test]
    fn badge_outside_measure_mode_shows_buffer_and_loss_only_if_lost() {
        let mut v = values();
        let lines = MeasuredBadge::lower_lines(&v, Some(23.976), Some(120.0), false, &Source);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].full_text(), "Puffer 11,4 s · Eingang 4,2 Mbit/s");
        assert!(!lines[0].conspicuous);
        v.discarded = 3;
        let lines = MeasuredBadge::lower_lines(&v, Some(23.976), None, false, &Source);
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[1].text, "Verworfen 3 · zu spät 0 · Ton weg 0");
        assert!(lines[1].conspicuous);
    }

    #[test]
    fn badge_measure_mode_lists_all_lines_in_order() {
        let lines = MeasuredBadge::lower_lines(&values(), Some(23.976), Some(120.0), true, &Source);
        let texts: Vec<String> = lines.iter().map(BadgeLine::full_text).collect();
        assert_eq!(
            texts,
            [
                "Puffer 11,4 s · 4 KiB · Eingang 4,2 Mbit/s",
                "Verworfen 0 · zu spät 0 · Ton weg 0",
                "Demuxer mkv",
                "Zeigt Ø 23,9 fps · Gezeigt 539",
                "Lauf 100 %",
                "Schirm 120 Hz",
                "Dekodiert Ø 23,9 fps",
                "Beschädigt 0 · Sprünge 0",
            ]
        );
        assert!(lines.iter().all(|l| !l.conspicuous));
    }

    #[test]
    fn badge_conspicuous_thresholds() {
        let mut v = values();
        v.reserve_seconds = Some(1.9);
        v.shows_per_second = Some(20.0); // more than two below 23.976
        v.decoded_per_second = Some(22.0); // 1.976 below: still within the window edge
        v.run_share = Some(0.96);
        v.jumps = 1;
        let lines = MeasuredBadge::lower_lines(&v, Some(23.976), Some(60.0), true, &Source);
        let flag = |prefix: &str| {
            lines
                .iter()
                .find(|l| l.full_text().starts_with(prefix))
                .unwrap()
                .conspicuous
        };
        assert!(flag("Puffer"));
        assert!(flag("Zeigt"));
        assert!(!flag("Dekodiert"));
        assert!(flag("Lauf"));
        assert!(flag("Schirm")); // below 70 Hz
        assert!(flag("Beschädigt"));
    }

    #[test]
    fn badge_missing_numbers_show_a_dash_and_never_warn() {
        let v = PlayValues::default();
        let lines = MeasuredBadge::lower_lines(&v, Some(24.0), None, true, &Source);
        let texts: Vec<String> = lines.iter().map(BadgeLine::full_text).collect();
        assert!(texts.contains(&"Zeigt Ø — fps · Gezeigt 0".to_owned()));
        assert!(texts.contains(&"Lauf —".to_owned()));
        assert!(texts.contains(&"Dekodiert Ø — fps".to_owned()));
        assert!(lines.iter().all(|l| !l.conspicuous));
    }

    #[test]
    fn badge_clock_and_time_row() {
        assert_eq!(MeasuredBadge::clock(61.9), "1:01");
        assert_eq!(MeasuredBadge::clock(3725.0), "1:02:05");
        assert_eq!(MeasuredBadge::clock(-5.0), "0:00");
        assert_eq!(
            MeasuredBadge::time_row(2472.0, 5400.0, &Source)
                .unwrap()
                .text,
            "Stelle 41:12 / 1:30:00"
        );
        assert_eq!(MeasuredBadge::time_row(0.0, 1.0, &Source), None);
    }
}
