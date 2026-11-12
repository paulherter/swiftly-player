//! Port of DownloadQuality.swift.
//!
//! In which quality a title is downloaded to the device: the original, or three transcoded
//! levels (H.264 + AAC in Matroska). Wording that needs the catalog ("Original",
//! "Direct Play") is not ported; `name` / `addition` / `badge` return `None` where Swift
//! returns a translated string. `DownloadItem`-based helpers take plain values instead.

use crate::whole_number::capped;

/// A download level. Raw values are persisted (`original`, `hd1080`, `hd720`, `sd480`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DownloadQuality {
    /// The original file.
    Original,
    /// 1080p.
    Hd1080,
    /// 720p.
    Hd720,
    /// 480p.
    Sd480,
}

impl DownloadQuality {
    /// `CaseIterable.allCases`.
    pub const ALL: [DownloadQuality; 4] = [Self::Original, Self::Hd1080, Self::Hd720, Self::Sd480];

    /// The levels that transcode: everything except the original.
    pub const LEVELS: [DownloadQuality; 3] = [Self::Hd1080, Self::Hd720, Self::Sd480];

    /// The container of a transcoded file.
    pub const CONTAINER: &'static str = "mkv";

    /// The persisted raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Original => "original",
            Self::Hd1080 => "hd1080",
            Self::Hd720 => "hd720",
            Self::Sd480 => "sd480",
        }
    }

    /// `init?(rawValue:)`.
    pub fn from_raw_value(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|q| q.raw_value() == raw)
    }

    /// Is this the original?
    pub fn is_original(self) -> bool {
        self == Self::Original
    }

    /// Picture height of the level; `None` for the original.
    pub fn height(self) -> Option<i64> {
        match self {
            Self::Original => None,
            Self::Hd1080 => Some(1080),
            Self::Hd720 => Some(720),
            Self::Sd480 => Some(480),
        }
    }

    /// Width for the height at 16:9.
    pub fn width(self) -> Option<i64> {
        match self {
            Self::Original => None,
            Self::Hd1080 => Some(1920),
            Self::Hd720 => Some(1280),
            Self::Sd480 => Some(854),
        }
    }

    /// Bits per second for the picture.
    pub fn image_bitrate(self) -> Option<i64> {
        match self {
            Self::Original => None,
            Self::Hd1080 => Some(8_000_000),
            Self::Hd720 => Some(4_000_000),
            Self::Sd480 => Some(1_500_000),
        }
    }

    /// Bits per second for the audio.
    pub fn audio_bitrate(self) -> Option<i64> {
        match self {
            Self::Original => None,
            Self::Hd1080 => Some(384_000),
            Self::Hd720 => Some(256_000),
            Self::Sd480 => Some(128_000),
        }
    }

    /// Audio channels (5.1 kept at 1080p and 720p, stereo at 480p).
    pub fn audio_channels(self) -> Option<i64> {
        match self {
            Self::Original => None,
            Self::Hd1080 | Self::Hd720 => Some(6),
            Self::Sd480 => Some(2),
        }
    }

    /// Picture and audio together, bit/s.
    pub fn total_bitrate(self) -> Option<i64> {
        Some(self.image_bitrate()? + self.audio_bitrate()?)
    }

    /// Whether a choice is allowed at all: transcoding needs both rights; only an explicit
    /// `false` blocks. (`DownloadQuality.swift:97-99`)
    pub fn selectable(video_convert: Option<bool>, audio_convert: Option<bool>) -> bool {
        video_convert.unwrap_or(true) && audio_convert.unwrap_or(true)
    }

    /// The levels for a selection, original first. A level that does not make the file
    /// smaller (total bitrate not below the source bitrate) is dropped; unknown source
    /// bitrate keeps all. (`DownloadQuality.swift:109-116`)
    pub fn offered(selectable: bool, source_bitrate_of: Option<i64>) -> Vec<DownloadQuality> {
        if !selectable {
            return vec![Self::Original];
        }
        let mut out = vec![Self::Original];
        out.extend(Self::LEVELS.into_iter().filter(|rung| {
            match (source_bitrate_of, rung.total_bitrate()) {
                (Some(q), Some(g)) if q > 0 => g < q,
                _ => true,
            }
        }));
        out
    }

    /// Bits per second of a file from size and runtime; `None` if either is missing.
    /// `Int(capped: Double(bytes) * 8 / seconds)`. (`DownloadQuality.swift:121-125`)
    pub fn bitrate(bytes: i64, runtime_ticks: Option<i64>) -> Option<i64> {
        let t = runtime_ticks?;
        if bytes <= 0 || t <= 0 {
            return None;
        }
        let seconds = t as f64 / 10_000_000.0;
        Some(capped(bytes as f64 * 8.0 / seconds))
    }

    /// The highest source bitrate of a selection of `(bytes, runtimeTicks)` files.
    pub fn source_bitrate_of(files: &[(i64, Option<i64>)]) -> Option<i64> {
        files
            .iter()
            .filter_map(|(b, t)| Self::bitrate(*b, *t))
            .max()
    }

    /// Roughly how big the file will be: bitrate times runtime plus three percent for the
    /// container; the original shows its real size; never larger than the original; 0 if the
    /// runtime is unknown. `Int64(seconds * Double(bitrate) / 8 * 1.03)` truncates.
    /// (`DownloadQuality.swift:141-147`)
    pub fn estimated_bytes(self, original: i64, runtime_ticks: Option<i64>) -> i64 {
        let Some(bitrate) = self.total_bitrate() else {
            return original;
        };
        let Some(t) = runtime_ticks.filter(|t| *t > 0) else {
            return 0;
        };
        let seconds = t as f64 / 10_000_000.0;
        let estimate = capped(seconds * bitrate as f64 / 8.0 * 1.03);
        if original > 0 {
            estimate.min(original)
        } else {
            estimate
        }
    }

    /// What a series group shows: the level (each given value is an item's effective level,
    /// `guete`), if all share the same non-original one; otherwise `None`.
    /// (`DownloadQuality.swift:155-159`; the `DownloadItem` is reduced to its level.)
    pub fn common(levels: &[DownloadQuality]) -> Option<DownloadQuality> {
        let first = *levels.first()?;
        if first.is_original() || !levels.iter().all(|l| *l == first) {
            return None;
        }
        Some(first)
    }

    /// "1080p", "720p", "480p"; `None` for the original (translated "Original" is catalog text).
    pub fn name(self) -> Option<&'static str> {
        match self {
            Self::Original => None,
            Self::Hd1080 => Some("1080p"),
            Self::Hd720 => Some("720p"),
            Self::Sd480 => Some("480p"),
        }
    }

    /// The bitrate label "1,5 Mbit/s": at most one fraction digit, trailing zero trimmed,
    /// separator as given. `None` for the original ("Direct Play" is catalog text).
    /// (`DownloadQuality.swift:176-181`)
    pub fn addition(self, decimal_separator: &str) -> Option<String> {
        let b = self.image_bitrate()?;
        let fixed = format!("{:.1}", b as f64 / 1_000_000.0);
        let trimmed = fixed.trim_end_matches('0').trim_end_matches('.');
        Some(format!(
            "{} Mbit/s",
            trimmed.replace('.', decimal_separator)
        ))
    }

    /// "720p · 4 Mbit/s"; `None` for the original (its badge is catalog text).
    pub fn badge(self, decimal_separator: &str) -> Option<String> {
        Some(format!(
            "{} · {}",
            self.name()?,
            self.addition(decimal_separator)?
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::DownloadQuality as Q;

    /// 45 minutes in ticks.
    const EPISODE: i64 = 45 * 60 * 10_000_000;

    // Swift: selectable()
    #[test]
    fn selectable() {
        assert!(Q::selectable(None, None));
        assert!(Q::selectable(Some(true), Some(true)));
        assert!(!Q::selectable(Some(false), Some(true)));
        assert!(!Q::selectable(Some(true), Some(false)));
    }

    // Swift: withoutRight()
    #[test]
    fn without_right() {
        assert_eq!(Q::offered(false, Some(50_000_000)), [Q::Original]);
    }

    // Swift: levelsFilter()
    #[test]
    fn levels_filter() {
        assert_eq!(
            Q::offered(true, None),
            [Q::Original, Q::Hd1080, Q::Hd720, Q::Sd480]
        );
        assert_eq!(
            Q::offered(true, Some(30_000_000)),
            [Q::Original, Q::Hd1080, Q::Hd720, Q::Sd480]
        );
        // A 720p episode at 3 Mbit/s: only 480p makes it smaller.
        assert_eq!(Q::offered(true, Some(3_000_000)), [Q::Original, Q::Sd480]);
    }

    // Swift: sourceBitrate()
    #[test]
    fn source_bitrate() {
        // 2.7 GB in 45 minutes = 8 Mbit/s
        assert_eq!(Q::bitrate(2_700_000_000, Some(EPISODE)), Some(8_000_000));
        assert_eq!(Q::bitrate(0, Some(EPISODE)), None);
        assert_eq!(Q::bitrate(1, None), None);
        let q = Q::source_bitrate_of(&[
            (1_350_000_000, Some(EPISODE)),
            (2_700_000_000, Some(EPISODE)),
            (5, None),
        ]);
        assert_eq!(q, Some(8_000_000));
    }

    // Swift: size()
    #[test]
    fn size() {
        let original: i64 = 10_000_000_000;
        assert_eq!(
            Q::Original.estimated_bytes(original, Some(EPISODE)),
            original
        );
        // 720p: 4.256 Mbit/s * 2700 s / 8 * 1.03 = about 1.48 GB
        let s720 = Q::Hd720.estimated_bytes(original, Some(EPISODE));
        assert!(s720 > 1_400_000_000 && s720 < 1_550_000_000);
        assert!(Q::Sd480.estimated_bytes(original, Some(EPISODE)) < s720);
        // Source smaller than the tier: never larger than the original.
        assert_eq!(
            Q::Hd1080.estimated_bytes(500_000_000, Some(EPISODE)),
            500_000_000
        );
        // Without a runtime, no number.
        assert_eq!(Q::Hd720.estimated_bytes(original, None), 0);
    }

    // Swift: gemeinsam() - the DownloadItem values are reduced to their level (`guete`).
    #[test]
    fn common() {
        assert_eq!(Q::common(&[Q::Sd480, Q::Sd480]), Some(Q::Sd480));
        assert_eq!(Q::common(&[Q::Sd480, Q::Original]), None);
        assert_eq!(Q::common(&[Q::Original, Q::Original]), None);
        assert_eq!(Q::common(&[]), None);
    }

    // Swift: phrases() (the locale becomes the decimal separator)
    #[test]
    fn phrases() {
        assert_eq!(Q::Sd480.addition(",").as_deref(), Some("1,5 Mbit/s"));
        assert_eq!(Q::Sd480.addition(".").as_deref(), Some("1.5 Mbit/s"));
        assert_eq!(Q::Hd720.badge(",").as_deref(), Some("720p · 4 Mbit/s"));
        assert_eq!(Q::Original.addition(","), None);
    }

    #[test]
    fn table_and_raw_values() {
        assert_eq!(Q::Hd1080.total_bitrate(), Some(8_384_000));
        assert_eq!(Q::Original.total_bitrate(), None);
        assert_eq!(Q::Hd720.width(), Some(1280));
        assert_eq!(Q::Sd480.audio_channels(), Some(2));
        for q in Q::ALL {
            assert_eq!(Q::from_raw_value(q.raw_value()), Some(q));
        }
    }
}
