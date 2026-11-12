//! How an audio or subtitle track is named in a list (JellyfinKit/TrackLabel.swift), plus the
//! few `TechDetails` helpers the track rules need (TechDetails.swift:18-107).
//!
//! Language names come from CLDR in Swift (`Locale.localizedString`); here they come through
//! the [`LabelText`] trait so the l10n crate can provide them per interface language. The same
//! trait carries the four catalog words ("unbekannt", "Erzwungen", "Hörgeschädigt", "Datei").

use std::collections::HashSet;

use swiftly_model::MediaStream;
use swiftly_rules::language;

use crate::track_mapping::PlayerTrack;

/// Words between the parts of a label (TrackLabel.swift:17).
pub const SEPARATOR: &str = " · ";

/// Interface-language text the label rules need.
pub trait LabelText {
    /// The language name for an ISO code in the interface language (`Locale.localizedString`).
    fn language_name(&self, code: &str) -> Option<String>;
    /// Whether the (English) locale knows this code at all (TrackLabel.swift:89).
    fn knows_code(&self, code: &str) -> bool;
    /// Catalog word "unbekannt".
    fn unknown(&self) -> String;
    /// Catalog word "Erzwungen".
    fn forced(&self) -> String;
    /// Catalog word "Hörgeschädigt".
    fn hearing_impaired(&self) -> String;
    /// Catalog word "Datei".
    fn file(&self) -> String;
    /// Catalog word "(Original)", appended to the audio track of the title's original language.
    fn original_suffix(&self) -> String {
        "(Original)".to_owned()
    }
}

/// Codes a file carries when nobody set a language (TrackLabel.swift:45).
const UNDETERMINED: [&str; 5] = ["und", "unknown", "unbekannt", "mis", "zxx"];

/// Words a track title repeats from the structured fields (TrackLabel.swift:179-184).
const REPEATED_WORDS: &[&str] = &[
    "forced",
    "erzwungen",
    "форсированные",
    "принудительные",
    "sdh",
    "cc",
    "hi",
    "hörgeschädigt",
    "default",
    "standard",
    "full",
    "полные",
    "subtitle",
    "subtitles",
    "sub",
    "subs",
    "untertitel",
    "субтитры",
    "srt",
    "subrip",
    "ass",
    "ssa",
    "pgs",
    "vobsub",
    "webvtt",
    "vtt",
];

/// "ru", "rus", "pt-BR": a code, not a word (TrackLabel.swift:74-79).
pub fn looks_like_code(text: &str) -> bool {
    let parts: Vec<&str> = text.split(['-', '_']).filter(|p| !p.is_empty()).collect();
    let Some(first) = parts.first() else {
        return false;
    };
    (2..=3).contains(&first.chars().count())
        && text
            .chars()
            .all(|c| (c.is_ascii() && c.is_alphabetic()) || c == '-' || c == '_')
        && parts[1..]
            .iter()
            .all(|p| p.chars().all(|c| c.is_ascii() && c.is_alphanumeric()))
}

/// The ISO code behind a name from the language table (TrackLabel.swift:84-91).
fn code_of(name: &str, text: &dyn LabelText) -> Option<&'static str> {
    let entry = language::ALL.iter().find(|e| e.name == name)?;
    entry
        .shape
        .iter()
        .find(|f| (2..=3).contains(&f.chars().count()) && looks_like_code(f) && text.knows_code(f))
        .copied()
}

/// First letter upper case, the rest as written (TrackLabel.swift:93).
pub fn capitalised(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// A track's language as a list entry: interface language, capitalised (TrackLabel.swift:61-71).
///
/// Unknown codes are shown in capitals ("QAA"), unknown words as written.
pub fn language(raw: Option<&str>, text: &dyn LabelText) -> Option<String> {
    let raw = raw?.trim();
    if raw.is_empty() {
        return None;
    }
    if UNDETERMINED.contains(&raw.to_lowercase().as_str()) {
        return Some(capitalised(&text.unknown()));
    }
    let name = if looks_like_code(raw) {
        text.language_name(&raw.to_lowercase())
    } else {
        language::detected(raw)
            .and_then(|n| code_of(n, text))
            .and_then(|c| text.language_name(c))
    };
    if let Some(name) = name {
        return Some(capitalised(&name));
    }
    Some(if looks_like_code(raw) {
        raw.to_uppercase()
    } else {
        capitalised(raw)
    })
}

/// "Russian · AC-3 · 5.1": language, codec, channel layout, as far as known
/// (TrackLabel.swift:104-109).
pub fn audio(
    language_raw: Option<&str>,
    codec: Option<&str>,
    channels: Option<i64>,
    text: &dyn LabelText,
) -> Option<String> {
    let parts: Vec<String> = [
        language(language_raw, text),
        codec.map(str::to_owned),
        channel_word(channels),
    ]
    .into_iter()
    .flatten()
    .collect();
    (!parts.is_empty()).then(|| parts.join(SEPARATOR))
}

/// A subtitle the server knows: "English · Forced · SRT · File" (TrackLabel.swift:124-130).
///
/// Built from the structured fields, never from `DisplayTitle`.
pub fn subtitle(feed: &MediaStream, text: &dyn LabelText) -> Option<String> {
    subtitle_parts(
        feed.language.as_deref(),
        feed.title.as_deref(),
        codec_name_value(feed.codec.as_deref()).as_deref(),
        feed.is_forced == Some(true),
        feed.is_hearing_impaired == Some(true),
        feed.is_external == Some(true),
        text,
    )
}

/// A subtitle only the player knows (TrackLabel.swift:136-141); `None` without a language.
pub fn subtitle_of_track(track: &PlayerTrack, text: &dyn LabelText) -> Option<String> {
    language(track.language.as_deref(), text)?;
    subtitle_parts(
        track.language.as_deref(),
        None,
        track.codec.as_deref(),
        language::sounds_forced(&track.name),
        false,
        track.addition_id().is_some(),
        text,
    )
}

fn subtitle_parts(
    raw: Option<&str>,
    title: Option<&str>,
    codec: Option<&str>,
    forced: bool,
    hearing_impaired: bool,
    external: bool,
    text: &dyn LabelText,
) -> Option<String> {
    let language_word = language(raw, text);
    let extra = extra_title(title);
    if language_word.is_none() && extra.is_none() {
        return None;
    }
    let parts: Vec<String> = [
        language_word,
        extra,
        forced.then(|| text.forced()),
        hearing_impaired.then(|| text.hearing_impaired()),
        codec.map(str::to_owned),
        external.then(|| text.file()),
    ]
    .into_iter()
    .flatten()
    .collect();
    Some(parts.join(SEPARATOR))
}

/// Equal names get a running number: "English · SRT · 1", "English · SRT · 2"
/// (TrackLabel.swift:166-175). Unique names stay untouched.
pub fn distinct(labels: &[String]) -> Vec<String> {
    use std::collections::HashMap;
    let mut counts: HashMap<&str, usize> = HashMap::new();
    for l in labels {
        *counts.entry(l.as_str()).or_insert(0) += 1;
    }
    let mut seen: HashMap<&str, usize> = HashMap::new();
    labels
        .iter()
        .map(|label| {
            if counts.get(label.as_str()).copied().unwrap_or(0) <= 1 {
                return label.clone();
            }
            let n = seen.entry(label.as_str()).or_insert(0);
            *n += 1;
            format!("{label}{SEPARATOR}{n}")
        })
        .collect()
}

/// The track title, only if it adds something (TrackLabel.swift:193-202).
pub fn extra_title(title: Option<&str>) -> Option<String> {
    let title = title?.trim();
    if title.is_empty() {
        return None;
    }
    let repeated: HashSet<&str> = REPEATED_WORDS.iter().copied().collect();
    let lowered = title.to_lowercase();
    let remaining = lowered
        .split(|c: char| !c.is_alphabetic())
        .filter(|w| !w.is_empty())
        .any(|w| {
            !repeated.contains(w) && language::detected(w).is_none() && !looks_like_language_code(w)
        });
    remaining.then(|| title.to_owned())
}

/// "en", "ru": a bare code in a title such as "en.forced" (TrackLabel.swift:205).
///
/// Swift asks the English locale whether it knows the code; the same two-letter/three-letter
/// codes that [`LabelText::knows_code`] knows are used by the callers' tables, so this checks
/// the shape and the language table's own short forms.
fn looks_like_language_code(word: &str) -> bool {
    (2..=3).contains(&word.chars().count())
        && looks_like_code(word)
        && language::ALL.iter().any(|e| e.shape.contains(&word))
}

// MARK: TechDetails pieces

/// How a codec is written when a human reads it (TechDetails.swift:18-49).
pub fn codec_name_value(raw: Option<&str>) -> Option<String> {
    let raw = raw.filter(|r| !r.is_empty())?;
    Some(
        match raw.to_lowercase().as_str() {
            "h264" | "avc" => "H.264",
            "hevc" | "h265" => "HEVC",
            "av1" => "AV1",
            "vp9" => "VP9",
            "mpeg2video" => "MPEG-2",
            "vc1" => "VC-1",
            "aac" | "aac_latm" => "AAC",
            "ac3" => "AC-3",
            "eac3" => "E-AC-3",
            "dts" | "dca" => "DTS",
            "dtshd" => "DTS-HD",
            "truehd" => "TrueHD",
            "mlp" => "MLP",
            "flac" => "FLAC",
            "alac" => "ALAC",
            "opus" => "Opus",
            "mp3" => "MP3",
            "hdmv_pgs_subtitle" | "pgssub" => "PGS",
            "dvd_subtitle" | "dvdsub" => "VobSub",
            "subrip" | "srt" => "SRT",
            "ass" | "ssa" => "ASS",
            "mov_text" => "MOV-Text",
            "webvtt" | "vtt" => "WebVTT",
            "ttml" | "stpp" => "TTML",
            "dvbsub" | "dvb_subtitle" => "DVB",
            _ => return Some(raw.to_uppercase()),
        }
        .to_owned(),
    )
}

/// Codec name from libVLC's FourCC, least significant byte first (TechDetails.swift:56-85).
pub fn codec_name_value_vlc_id(identifier: u32) -> Option<String> {
    let bytes = identifier.to_le_bytes();
    if !bytes.is_ascii() {
        return None;
    }
    let symbol: String = bytes.iter().map(|b| char::from(*b)).collect();
    let raw = match symbol.to_lowercase().trim() {
        "mp4a" => "aac",
        "a52" => "ac3",
        "eac3" => "eac3",
        "dts" => "dts",
        "trhd" | "mlpa" => "truehd",
        "mlp" => "mlp",
        "flac" => "flac",
        "alac" => "alac",
        "opus" => "opus",
        "mp3" => "mp3",
        "vorb" => "vorbis",
        "subt" => "subrip",
        "ssa" => "ass",
        "bdpg" => "hdmv_pgs_subtitle",
        "spu" => "dvd_subtitle",
        "tx3g" => "mov_text",
        "wvtt" => "webvtt",
        "stpp" => "ttml",
        "dvbs" => "dvbsub",
        _ => return None,
    };
    codec_name_value(Some(raw))
}

/// How many channels, in the notation everyone knows (TechDetails.swift:98-107).
pub fn channel_word(count: Option<i64>) -> Option<String> {
    match count {
        Some(1) => Some("Mono".to_owned()),
        Some(2) => Some("Stereo".to_owned()),
        Some(6) => Some("5.1".to_owned()),
        Some(8) => Some("7.1".to_owned()),
        Some(n) if n > 0 => Some(format!("{n} ch")),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Stand-in for CLDR names of the test locales (en, de, ru).
    struct Names(&'static str);

    impl LabelText for Names {
        fn language_name(&self, code: &str) -> Option<String> {
            let table: &[(&str, &str, &str, &str)] = &[
                ("ru", "русский", "Russisch", "Russian"),
                ("rus", "русский", "Russisch", "Russian"),
                ("en", "английский", "Englisch", "English"),
                ("eng", "английский", "Englisch", "English"),
                ("de", "немецкий", "Deutsch", "German"),
                ("ger", "немецкий", "Deutsch", "German"),
                ("deu", "немецкий", "Deutsch", "German"),
            ];
            let row = table.iter().find(|r| r.0 == code)?;
            Some(
                match self.0 {
                    "ru" => row.1,
                    "de" => row.2,
                    _ => row.3,
                }
                .to_owned(),
            )
        }
        fn knows_code(&self, code: &str) -> bool {
            matches!(
                code,
                "ru" | "rus" | "en" | "eng" | "de" | "ger" | "deu" | "fr" | "fre" | "fra"
            )
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

    fn sub(
        language: Option<&str>,
        title: Option<&str>,
        codec: &str,
        forced: bool,
        hi: bool,
        ext: bool,
    ) -> MediaStream {
        MediaStream {
            codec: Some(codec.to_owned()),
            type_: Some("Subtitle".to_owned()),
            language: language.map(str::to_owned),
            display_title: Some(format!("server words - [{}]", language.unwrap_or(""))),
            is_default: Some(false),
            index: Some(3),
            is_forced: Some(forced),
            is_external: Some(ext),
            title: title.map(str::to_owned),
            is_hearing_impaired: Some(hi),
            ..MediaStream::default()
        }
    }

    /// TrackLabelTests.languageInInterfaceLanguage
    #[test]
    fn language_in_interface_language() {
        assert_eq!(
            language(Some("rus"), &Names("ru")).as_deref(),
            Some("Русский")
        );
        assert_eq!(
            language(Some("eng"), &Names("ru")).as_deref(),
            Some("Английский")
        );
        assert_eq!(
            language(Some("ger"), &Names("en")).as_deref(),
            Some("German")
        );
        assert_eq!(
            language(Some("deu"), &Names("de")).as_deref(),
            Some("Deutsch")
        );
        assert_eq!(
            language(Some("ru"), &Names("de")).as_deref(),
            Some("Russisch")
        );
    }

    /// TrackLabelTests.writtenOutNames
    #[test]
    fn written_out_names() {
        assert_eq!(
            language(Some("Russian"), &Names("ru")).as_deref(),
            Some("Русский")
        );
        assert_eq!(
            language(Some("German"), &Names("en")).as_deref(),
            Some("German")
        );
        assert_eq!(
            language(Some("русский"), &Names("de")).as_deref(),
            Some("Russisch")
        );
        assert_eq!(
            language(Some("English"), &Names("de")).as_deref(),
            Some("Englisch")
        );
    }

    /// TrackLabelTests.unknownLanguage
    #[test]
    fn unknown_language() {
        let n = Names("en");
        assert_eq!(language(Some("und"), &n), Some(capitalised(&n.unknown())));
        assert_eq!(language(Some("qaa"), &n).as_deref(), Some("QAA"));
        assert_eq!(language(Some(""), &n), None);
        assert_eq!(language(None, &n), None);
    }

    /// TrackLabelTests.audio
    #[test]
    fn audio_label() {
        assert_eq!(
            audio(Some("rus"), Some("AC-3"), Some(2), &Names("ru")).as_deref(),
            Some("Русский · AC-3 · Stereo")
        );
        assert_eq!(
            audio(Some("Russian"), Some("E-AC-3"), Some(6), &Names("en")).as_deref(),
            Some("Russian · E-AC-3 · 5.1")
        );
        assert_eq!(
            audio(None, Some("AAC"), Some(2), &Names("de")).as_deref(),
            Some("AAC · Stereo")
        );
        assert_eq!(audio(None, None, Some(0), &Names("de")), None);
    }

    /// TrackLabelTests.subtitleStructure
    #[test]
    fn subtitle_structure() {
        assert_eq!(
            subtitle(
                &sub(Some("rus"), None, "ass", false, false, false),
                &Names("ru")
            )
            .as_deref(),
            Some("Русский · ASS")
        );
        assert_eq!(
            subtitle(
                &sub(
                    Some("eng"),
                    Some("English [Forced]"),
                    "subrip",
                    true,
                    false,
                    false
                ),
                &Names("en")
            )
            .as_deref(),
            Some("English · Erzwungen · SRT")
        );
        assert_eq!(
            subtitle(
                &sub(Some("eng"), None, "subrip", false, false, true),
                &Names("de")
            )
            .as_deref(),
            Some("Englisch · SRT · Datei")
        );
        assert_eq!(
            subtitle(
                &sub(Some("ger"), Some("SDH"), "subrip", false, true, false),
                &Names("de")
            )
            .as_deref(),
            Some("Deutsch · Hörgeschädigt · SRT")
        );
        let ru = subtitle(
            &sub(Some("rus"), None, "subrip", false, false, false),
            &Names("ru"),
        );
        assert!(!ru.expect("label").contains("server"));
    }

    /// TrackLabelTests.extraTitle
    #[test]
    fn extra_title_rules() {
        for t in [
            "Forced - [Russian]",
            "Русский",
            "English [Forced]",
            "Deutsch SDH",
            "en.forced",
            "  ",
        ] {
            assert_eq!(extra_title(Some(t)), None, "{t}");
        }
        assert_eq!(
            extra_title(Some("Commentary")).as_deref(),
            Some("Commentary")
        );
        assert_eq!(
            extra_title(Some("Signs & Songs")).as_deref(),
            Some("Signs & Songs")
        );
        assert_eq!(extra_title(Some("Надписи")).as_deref(), Some("Надписи"));
        assert_eq!(
            subtitle(
                &sub(
                    Some("eng"),
                    Some("Commentary"),
                    "subrip",
                    false,
                    false,
                    false
                ),
                &Names("en")
            )
            .as_deref(),
            Some("English · Commentary · SRT")
        );
    }

    /// TrackLabelTests.distinct
    #[test]
    fn distinct_numbers() {
        let s = |v: &[&str]| v.iter().map(|x| (*x).to_owned()).collect::<Vec<_>>();
        assert_eq!(
            distinct(&s(&["English · SRT", "Русский · ASS", "English · SRT"])),
            s(&["English · SRT · 1", "Русский · ASS", "English · SRT · 2"])
        );
        assert_eq!(distinct(&s(&["Deutsch · PGS"])), s(&["Deutsch · PGS"]));
        assert!(distinct(&[]).is_empty());
    }

    /// TrackLabelTests.subtitleWithoutLanguage
    #[test]
    fn subtitle_without_language() {
        let en = Names("en");
        assert_eq!(
            subtitle(&sub(None, None, "subrip", false, false, false), &en),
            None
        );
        assert_eq!(
            subtitle(
                &sub(None, Some("Signs"), "subrip", false, false, false),
                &en
            )
            .as_deref(),
            Some("Signs · SRT")
        );
        let bare = PlayerTrack::new("spu/2", "Track 1", None, Some("SRT"), None);
        assert_eq!(subtitle_of_track(&bare, &en), None);
        let known = PlayerTrack::new(
            "spu/3",
            "Forced - [Russian]",
            Some("rus"),
            Some("ASS"),
            None,
        );
        assert_eq!(
            subtitle_of_track(&known, &Names("ru")).as_deref(),
            Some("Русский · Erzwungen · ASS")
        );
    }
}
