//! "(Original)" on audio tracks (JellyfinKit/OriginalAudio.swift).
//!
//! Decides whether a track is the original language of the title. Two sources, in this order:
//! the track's own `IsOriginal`, then the title's `OriginalLanguage` equal to the track's
//! language, compared as languages (two-letter, three-letter code or name). The suffix text is a
//! catalog string, so [`label`] takes it as a parameter.

use std::collections::HashMap;
use std::sync::OnceLock;

use swiftly_model::MediaStream;

/// Two-letter code, three-letter codes and English names (OriginalAudio.swift:51-71).
const TABLE: &[(&str, &[&str])] = &[
    ("ar", &["ara", "arabic"]),
    ("bg", &["bul", "bulgarian"]),
    ("ca", &["cat", "catalan"]),
    ("cs", &["ces", "cze", "czech"]),
    ("da", &["dan", "danish"]),
    ("de", &["deu", "ger", "german", "deutsch"]),
    ("el", &["ell", "gre", "greek"]),
    ("en", &["eng", "english"]),
    ("es", &["spa", "spanish", "español"]),
    ("et", &["est", "estonian"]),
    ("fa", &["fas", "per", "persian"]),
    ("fi", &["fin", "finnish"]),
    ("fr", &["fra", "fre", "french", "français"]),
    ("he", &["heb", "hebrew"]),
    ("hi", &["hin", "hindi"]),
    ("hr", &["hrv", "croatian"]),
    ("hu", &["hun", "hungarian"]),
    ("id", &["ind", "indonesian"]),
    ("is", &["isl", "ice", "icelandic"]),
    ("it", &["ita", "italian", "italiano"]),
    ("ja", &["jpn", "japanese"]),
    ("ko", &["kor", "korean"]),
    ("lt", &["lit", "lithuanian"]),
    ("lv", &["lav", "latvian"]),
    ("ms", &["msa", "may", "malay"]),
    ("nb", &["nob"]),
    ("nl", &["nld", "dut", "dutch"]),
    ("no", &["nor", "norwegian", "nob", "nb"]),
    ("pl", &["pol", "polish"]),
    ("pt", &["por", "portuguese", "português"]),
    ("ro", &["ron", "rum", "romanian"]),
    ("ru", &["rus", "russian"]),
    ("sk", &["slk", "slo", "slovak"]),
    ("sl", &["slv", "slovenian"]),
    ("sr", &["srp", "serbian"]),
    ("sv", &["swe", "swedish"]),
    ("ta", &["tam", "tamil"]),
    ("te", &["tel", "telugu"]),
    ("th", &["tha", "thai"]),
    ("tr", &["tur", "turkish"]),
    ("uk", &["ukr", "ukrainian"]),
    ("vi", &["vie", "vietnamese"]),
    (
        "zh",
        &[
            "zho",
            "chi",
            "cmn",
            "yue",
            "chinese",
            "mandarin",
            "cantonese",
        ],
    ),
];

fn lookup() -> &'static HashMap<&'static str, &'static str> {
    static LOOKUP: OnceLock<HashMap<&'static str, &'static str>> = OnceLock::new();
    LOOKUP.get_or_init(|| {
        let mut result = HashMap::new();
        for (two, others) in TABLE {
            result.insert(*two, *two);
            for other in *others {
                result.entry(*other).or_insert(*two);
            }
        }
        // Norwegian Bokmål counts as Norwegian (OriginalAudio.swift:80).
        result.insert("nb", "no");
        result.insert("nob", "no");
        result
    })
}

/// The two-letter code for any spelling, the lowercase text for a language not in the table,
/// `None` for "no language" (OriginalAudio.swift:87-96).
pub fn canonical(raw: Option<&str>) -> Option<String> {
    // `CharacterSet.whitespaces`: also no-break space, ideographic space, ZWSP and BOM
    // (oracle `original_audio`, F-oracle-B01).
    let mut text = swiftly_rules::trim_whitespaces(raw?).to_lowercase();
    if text.is_empty() {
        return None;
    }
    if let Some(cut) = text.find(['-', '_']) {
        text.truncate(cut);
    }
    if ["und", "unk", "zxx", "mul", "mis", "unknown", "undetermined"].contains(&text.as_str()) {
        return None;
    }
    Some(
        lookup()
            .get(text.as_str())
            .map_or(text, |c| (*c).to_owned()),
    )
}

/// Is this track the title's original language? (OriginalAudio.swift:23-29)
pub fn is_original(
    language: Option<&str>,
    stream: Option<&MediaStream>,
    original_language: Option<&str>,
) -> bool {
    if stream.is_some_and(|s| s.is_original == Some(true)) {
        return true;
    }
    let Some(wanted) = canonical(original_language) else {
        return false;
    };
    let own = canonical(language.or_else(|| stream.and_then(|s| s.language.as_deref())));
    own.as_deref() == Some(wanted.as_str())
}

/// `base` with the suffix when the track is the original, otherwise unchanged
/// (OriginalAudio.swift:32-36). `suffix` is the catalog string "(Original)".
pub fn label(
    base: &str,
    language: Option<&str>,
    stream: Option<&MediaStream>,
    original_language: Option<&str>,
    suffix: &str,
) -> String {
    if is_original(language, stream, original_language) {
        format!("{base} {suffix}")
    } else {
        base.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stream(language: Option<&str>, original: Option<bool>) -> MediaStream {
        MediaStream {
            codec: Some("eac3".into()),
            type_: Some("Audio".into()),
            language: language.map(str::to_owned),
            channels: Some(6),
            index: Some(1),
            is_original: original,
            ..MediaStream::default()
        }
    }

    /// OriginalAudioTests.streamFlag
    #[test]
    fn stream_flag() {
        assert!(is_original(
            Some("ger"),
            Some(&stream(Some("ger"), Some(true))),
            Some("en")
        ));
    }

    /// OriginalAudioTests.codesCompare
    #[test]
    fn codes_compare() {
        for (track, original) in [
            ("eng", "en"),
            ("ger", "de"),
            ("deu", "de"),
            ("fre", "fr"),
            ("fra", "fr"),
            ("jpn", "ja"),
            ("zho", "zh"),
            ("chi", "zh"),
            ("English", "en"),
            ("pt-BR", "por"),
            ("nob", "no"),
        ] {
            assert!(
                is_original(Some(track), None, Some(original)),
                "{track} vs {original}"
            );
        }
    }

    /// OriginalAudioTests.noLabel
    #[test]
    fn no_label() {
        assert!(!is_original(
            Some("ger"),
            Some(&stream(Some("ger"), Some(false))),
            Some("en")
        ));
        assert!(!is_original(Some("ger"), None, None));
        assert!(!is_original(None, None, Some("en")));
        assert!(!is_original(Some("und"), None, Some("und")));
        assert!(!is_original(Some("eng"), None, Some("")));
    }

    /// OriginalAudioTests.unknownLanguage
    #[test]
    fn unknown_language() {
        assert!(is_original(Some("ben"), None, Some("ben")));
        assert!(!is_original(Some("ben"), None, Some("en")));
    }

    /// OriginalAudioTests.labelText
    #[test]
    fn label_text() {
        let original = label("English · AAC", Some("eng"), None, Some("en"), "(Original)");
        assert!(original.starts_with("English · AAC "));
        assert!(original.contains("Original"));
        assert_eq!(
            label("Deutsch · AAC", Some("ger"), None, Some("en"), "(Original)"),
            "Deutsch · AAC"
        );
        let s = stream(Some("jpn"), None);
        assert!(
            label(
                "x",
                s.language.as_deref(),
                Some(&s),
                Some("ja"),
                "(Original)"
            )
            .contains("Original")
        );
    }

    /// OriginalAudioTests.decoding
    #[test]
    fn decoding() {
        let s: MediaStream =
            serde_json::from_str(r#"{"Type":"Audio","Index":1,"IsOriginal":true}"#).expect("json");
        assert_eq!(s.is_original, Some(true));
        let s2: MediaStream = serde_json::from_str(r#"{"Type":"Audio","Index":1}"#).expect("json");
        assert_eq!(s2.is_original, None);
        let item: swiftly_model::Item =
            serde_json::from_str(r#"{"Id":"1","Name":"x","Type":"Movie","OriginalLanguage":"ja"}"#)
                .expect("json");
        assert_eq!(item.original_language.as_deref(), Some("ja"));
    }
}
