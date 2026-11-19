//! The language picker of the subtitle setting: ONE list for every host.
//!
//! First the languages of the short table (`swiftly_rules::language::ALL`: the six most used, then the rest of the
//! old list), which keep the values the settings stored since ever ("Deutsch", "עברית"). After them every other
//! ISO 639-1 language of the name table, alphabetical, with the two-letter code as the stored value (the same
//! form `track_rule::device_language_key` gives a language the short table does not list). All names are in the
//! interface language (the host's own names first, then the built-in CLDR table), so a German list reads
//! "Hebräisch", an English one "Hebrew".

use std::collections::HashSet;

use swiftly_l10n::Locale;
use swiftly_playback::track_rule::language_code;
use swiftly_rules::language;
use swiftly_rules::playback_selection::LanguageSelection;

use crate::language_data::NAMES;
use crate::language_names::language_name;

/// How many entries of the short table keep their fixed order at the top ("The six most used here first").
const MOST_USED: usize = 6;

/// "Wie die Datei" / "Aus" first, then the short table's languages, then every other language.
pub fn subtitle_selection(label: &str, locale: &Locale) -> Vec<LanguageSelection> {
    let lang = locale.language();
    let mut all = vec![LanguageSelection {
        name: label.to_owned(),
        value: String::new(),
    }];
    let mut seen_names: HashSet<String> = HashSet::new();
    let mut seen_codes: HashSet<String> = HashSet::new();

    let mut common: Vec<(String, LanguageSelection)> = Vec::new();
    for (i, entry) in language::ALL.iter().enumerate() {
        let code = language_code(entry.name);
        let name = code
            .as_deref()
            .and_then(|c| language_name(c, lang))
            .unwrap_or_else(|| entry.name.to_owned());
        if let Some(c) = code {
            seen_codes.insert(c);
        }
        seen_names.insert(name.clone());
        // The first six keep their place; the others are ordered by the name the user reads.
        let key = if i < MOST_USED {
            format!("\u{0}{i:02}")
        } else {
            fold(&name)
        };
        common.push((
            key,
            LanguageSelection {
                name,
                value: entry.name.to_owned(),
            },
        ));
    }
    common.sort_by(|a, b| a.0.cmp(&b.0));
    all.extend(common.into_iter().map(|(_, l)| l));

    let mut rest: Vec<(String, LanguageSelection)> = Vec::new();
    for row in NAMES.iter().filter(|r| r.0.len() == 2) {
        let code = row.0;
        if seen_codes.contains(code) {
            continue;
        }
        let Some(name) = language_name(code, lang) else {
            continue;
        };
        if !seen_names.insert(name.clone()) {
            continue;
        }
        seen_codes.insert(code.to_owned());
        rest.push((
            fold(&name),
            LanguageSelection {
                name,
                value: code.to_owned(),
            },
        ));
    }
    rest.sort_by(|a, b| a.0.cmp(&b.0));
    all.extend(rest.into_iter().map(|(_, l)| l));
    all
}

/// Sort key: lower case, the common Latin accents dropped ("Čeština" next to "Cebuano", "Ägyptisch" among the A).
fn fold(name: &str) -> String {
    name.chars()
        .flat_map(|c| c.to_lowercase())
        .map(|c| match c {
            'ä' | 'á' | 'à' | 'â' | 'ã' | 'å' | 'ā' | 'ă' | 'ą' => 'a',
            'ç' | 'č' | 'ć' => 'c',
            'đ' | 'ď' => 'd',
            'é' | 'è' | 'ê' | 'ë' | 'ē' | 'ė' | 'ę' | 'ě' => 'e',
            'í' | 'ì' | 'î' | 'ï' | 'ī' | 'ı' => 'i',
            'ł' | 'ľ' => 'l',
            'ñ' | 'ń' | 'ň' => 'n',
            'ö' | 'ó' | 'ò' | 'ô' | 'õ' | 'ø' | 'ő' => 'o',
            'ř' => 'r',
            'š' | 'ś' | 'ş' | 'ș' => 's',
            'ť' | 'ț' => 't',
            'ü' | 'ú' | 'ù' | 'û' | 'ū' | 'ů' | 'ű' => 'u',
            'ý' | 'ÿ' => 'y',
            'ž' | 'ź' | 'ż' => 'z',
            other => other,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn de() -> Vec<LanguageSelection> {
        subtitle_selection("Aus", &Locale::parse("de"))
    }

    #[test]
    fn the_list_starts_with_off_and_the_six_most_used_by_their_old_keys() {
        let all = de();
        assert_eq!((all[0].name.as_str(), all[0].value.as_str()), ("Aus", ""));
        let top: Vec<(&str, &str)> = all[1..7]
            .iter()
            .map(|l| (l.name.as_str(), l.value.as_str()))
            .collect();
        assert_eq!(
            top,
            vec![
                ("Deutsch", "Deutsch"),
                ("Englisch", "English"),
                ("Französisch", "Français"),
                ("Spanisch", "Español"),
                ("Italienisch", "Italiano"),
                ("Japanisch", "日本語"),
            ]
        );
    }

    #[test]
    fn hebrew_is_offered_by_its_german_name_and_keeps_its_old_key() {
        let all = de();
        let hebrew = all.iter().find(|l| l.name == "Hebräisch").expect("Hebrew");
        assert_eq!(hebrew.value, "עברית");
        let english = subtitle_selection("Off", &Locale::parse("en"));
        assert!(english.iter().any(|l| l.name == "Hebrew"));
    }

    #[test]
    fn languages_beyond_the_short_table_come_after_it_alphabetically_with_their_code() {
        let all = de();
        let common = language::ALL.len();
        // Off + the short table, then the others.
        let estonian = all
            .iter()
            .position(|l| l.name == "Estnisch")
            .expect("Estonian");
        assert!(estonian > common);
        assert_eq!(all[estonian].value, "et");
        let rest = &all[common + 1..];
        let keys: Vec<String> = rest.iter().map(|l| fold(&l.name)).collect();
        let mut sorted = keys.clone();
        sorted.sort();
        assert_eq!(keys, sorted, "the rest is alphabetical");
        assert!(
            rest.len() > 100,
            "the full ISO 639-1 table, not a short one"
        );
    }

    #[test]
    fn no_name_and_no_value_twice() {
        let all = de();
        let names: HashSet<&str> = all.iter().map(|l| l.name.as_str()).collect();
        let values: HashSet<&str> = all.iter().map(|l| l.value.as_str()).collect();
        assert_eq!(names.len(), all.len());
        assert_eq!(values.len(), all.len());
    }

    #[test]
    fn every_stored_value_of_the_old_list_is_still_offered() {
        let values: HashSet<String> = de().into_iter().map(|l| l.value).collect();
        for entry in language::ALL {
            assert!(values.contains(entry.name), "{} fell out", entry.name);
        }
    }
}
