//! Port of Language.swift.
//!
//! The languages offered for preselection, with the spellings under which they appear in
//! track names. Depending on the file, VLC reports "German", "Deutsch" or "ger".
//!
//! # Foundation behaviour
//!
//! `lowercased()` maps scalar by scalar (no final-sigma rule, see [`crate::text::lowercased`]);
//! `String ==`, `Set.contains` and `String.contains` use canonical equivalence, so both sides
//! are NFC-normalised before comparing; `Character.count` and `isLetter` work on grapheme
//! clusters.

use std::collections::HashSet;

use crate::text::{characters, is_letter, lowercased, nfc};

/// A selectable language: display name and the spellings found in track names.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LanguageEntry {
    /// Display name in the language itself ("Deutsch").
    pub name: &'static str,
    /// Lower-case spellings.
    pub shape: &'static [&'static str],
}

/// The languages to choose from. The six most used here first; the rest alphabetically.
/// **Short forms only where they are not an ordinary word** (no "no", "is").
pub const ALL: &[LanguageEntry] = &[
    LanguageEntry {
        name: "Deutsch",
        shape: &["deutsch", "german", "ger", "deu"],
    },
    LanguageEntry {
        name: "English",
        shape: &["english", "eng", "en"],
    },
    LanguageEntry {
        name: "Français",
        shape: &["français", "french", "fre", "fra"],
    },
    LanguageEntry {
        name: "Español",
        shape: &["español", "spanish", "spa", "esp"],
    },
    LanguageEntry {
        name: "Italiano",
        shape: &["italiano", "italian", "ita"],
    },
    LanguageEntry {
        name: "日本語",
        shape: &["japanese", "jpn", "japanisch"],
    },
    LanguageEntry {
        name: "العربية",
        shape: &["arabic", "ara", "arabisch"],
    },
    LanguageEntry {
        name: "Български",
        shape: &["bulgarian", "bul", "bulgarisch"],
    },
    LanguageEntry {
        name: "Català",
        shape: &["català", "catalan", "cat", "katalanisch"],
    },
    LanguageEntry {
        name: "Čeština",
        shape: &["čeština", "cestina", "czech", "cze", "ces", "tschechisch"],
    },
    LanguageEntry {
        name: "Dansk",
        shape: &["dansk", "danish", "dan", "dänisch", "daenisch"],
    },
    LanguageEntry {
        name: "Ελληνικά",
        shape: &["ελληνικά", "greek", "gre", "ell", "griechisch"],
    },
    LanguageEntry {
        name: "עברית",
        shape: &["hebrew", "heb", "hebräisch", "hebraeisch"],
    },
    LanguageEntry {
        name: "हिन्दी",
        shape: &["hindi", "hin"],
    },
    LanguageEntry {
        name: "Hrvatski",
        shape: &["hrvatski", "croatian", "hrv", "kroatisch"],
    },
    LanguageEntry {
        name: "Indonesia",
        shape: &["indonesia", "indonesian", "ind", "indonesisch"],
    },
    LanguageEntry {
        name: "Magyar",
        shape: &["magyar", "hungarian", "hun", "ungarisch"],
    },
    LanguageEntry {
        name: "Nederlands",
        shape: &[
            "nederlands",
            "dutch",
            "dut",
            "nld",
            "niederländisch",
            "niederlaendisch",
        ],
    },
    LanguageEntry {
        name: "Norsk",
        shape: &["norsk", "norwegian", "nor", "nob", "norwegisch"],
    },
    LanguageEntry {
        name: "Polski",
        shape: &["polski", "polish", "pol", "polnisch"],
    },
    LanguageEntry {
        name: "Português",
        shape: &[
            "português",
            "portugues",
            "portuguese",
            "por",
            "portugiesisch",
        ],
    },
    LanguageEntry {
        name: "Română",
        shape: &[
            "română",
            "romana",
            "romanian",
            "rum",
            "ron",
            "rumänisch",
            "rumaenisch",
        ],
    },
    LanguageEntry {
        name: "Русский",
        shape: &["русский", "russian", "rus", "russisch"],
    },
    LanguageEntry {
        name: "Slovenčina",
        shape: &[
            "slovenčina",
            "slovencina",
            "slovak",
            "slo",
            "slk",
            "slowakisch",
        ],
    },
    LanguageEntry {
        name: "Slovenščina",
        shape: &[
            "slovenščina",
            "slovenscina",
            "slovenian",
            "slv",
            "slowenisch",
        ],
    },
    LanguageEntry {
        name: "Suomi",
        shape: &["suomi", "finnish", "fin", "finnisch"],
    },
    LanguageEntry {
        name: "Svenska",
        shape: &["svenska", "swedish", "swe", "schwedisch"],
    },
    LanguageEntry {
        name: "ไทย",
        shape: &["thai", "tha"],
    },
    LanguageEntry {
        name: "Türkçe",
        shape: &[
            "türkçe",
            "turkce",
            "turkish",
            "tur",
            "türkisch",
            "tuerkisch",
        ],
    },
    LanguageEntry {
        name: "Українська",
        shape: &["українська", "ukrainian", "ukr", "ukrainisch"],
    },
    LanguageEntry {
        name: "Tiếng Việt",
        shape: &["tiếng việt", "vietnamese", "vie", "vietnamesisch"],
    },
    LanguageEntry {
        name: "中文",
        shape: &[
            "chinese",
            "chi",
            "zho",
            "zh",
            "chinesisch",
            "mandarin",
            "cantonese",
        ],
    },
    LanguageEntry {
        name: "한국어",
        shape: &["korean", "kor", "koreanisch"],
    },
];

/// Does the track name match the wanted language? (`Language.swift:60-62`)
pub fn fits(track_name: &str, toward: &str) -> bool {
    !toward.is_empty() && detected(track_name) == Some(toward)
}

/// The recognized display name ("Deutsch") if one of the stored languages appears in the
/// text, otherwise `None` rather than a guess.
///
/// Word by word, not as a substring, for short forms: "Slovenian" must not count as English
/// because it contains "en". Forms longer than three characters may also sit inside a
/// compound name ("Deutsch (Kommentar)"). (`Language.swift:70-79`)
pub fn detected(text: &str) -> Option<&'static str> {
    if text.is_empty() {
        return None;
    }
    let small = nfc(&lowercased(text));
    // `split(whereSeparator: { !$0.isLetter })` omits empty subsequences.
    let mut words: HashSet<String> = HashSet::new();
    let mut current = String::new();
    for c in characters(&small) {
        if is_letter(c) {
            current.push_str(c);
        } else if !current.is_empty() {
            words.insert(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        words.insert(current);
    }
    ALL.iter()
        .find(|entry| {
            entry.shape.iter().any(|form| {
                let form = nfc(form);
                words.contains(&form) || (characters(&form).len() > 3 && small.contains(&form))
            })
        })
        .map(|entry| entry.name)
}

/// Does the track name say that only the foreign-language parts are subtitled? Only for
/// tracks the server knows nothing about. (`Language.swift:84-87`)
pub fn sounds_forced(name: &str) -> bool {
    let small = lowercased(name);
    ["forced", "erzwungen"].iter().any(|w| small.contains(w))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Swift: noFormDouble() - the list has 33 entries and several spellings each.
    #[test]
    fn no_form_double() {
        let mut watched: std::collections::HashMap<&str, &str> = std::collections::HashMap::new();
        for entry in ALL {
            for form in entry.shape {
                assert!(
                    !watched.contains_key(form),
                    "\"{form}\" is in {} and in {}",
                    entry.name,
                    watched.get(form).copied().unwrap_or("")
                );
                watched.insert(form, entry.name);
            }
        }
        assert_eq!(ALL.len(), 33);
    }

    // Swift: noTripShorthands()
    #[test]
    fn no_trip_shorthands() {
        let forbidden = [
            "no", "is", "id", "he", "be", "or", "as", "in", "am", "so", "an", "da", "de", "it",
            "el", "la", "un",
        ];
        for entry in ALL {
            for form in entry.shape {
                assert!(
                    !forbidden.contains(form),
                    "{} carries the stumbling form {form}",
                    entry.name
                );
            }
        }
    }

    // Swift: newLanguagesWhoDetected()
    #[test]
    fn new_languages_detected() {
        assert_eq!(detected("Polski (forced)"), Some("Polski"));
        assert_eq!(detected("pol"), Some("Polski"));
        assert_eq!(detected("Portuguese (Brazil)"), Some("Português"));
        assert_eq!(detected("zh-Hans"), Some("中文"));
        assert_eq!(detected("No subtitles"), None);
        assert_eq!(detected("This is forced"), None);
    }

    // Extra (not in Swift): the rule from the doc comment.
    #[test]
    fn word_vs_substring() {
        assert_eq!(detected("Slovenian"), Some("Slovenščina"));
        assert_eq!(detected("Deutsch (Kommentar)"), Some("Deutsch"));
        assert!(fits("German", "Deutsch"));
        assert!(!fits("German", ""));
        assert!(sounds_forced("English FORCED"));
        assert!(!sounds_forced("English"));
    }
}
