//! Port of PlaybackSelection.swift.
//!
//! The values offered in the playback settings: which bitrates, skip lengths and languages
//! exist. Wording ("Unbegrenzt", "%d Mbit/s", "Wie die Datei") is catalog text and is not
//! ported; the caller passes the label.

use crate::language;

/// Bitrate limits in Mbit/s; 0 means unlimited. (`Bitrate.levels`)
pub const BITRATE_LEVELS: [i64; 6] = [0, 4, 8, 20, 40, 80];

/// Skip lengths in seconds. (`Span.levels`)
pub const SPAN_LEVELS: [i64; 5] = [5, 10, 15, 30, 60];

/// One entry of the language picker; an empty value means "do not preselect".
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LanguageSelection {
    /// Shown name.
    pub name: String,
    /// Stored value (the language's display name, or empty).
    pub value: String,
}

/// `LanguageSelection.all(from:)`: the "like the file" entry with the given label, then
/// every language of [`language::ALL`].
pub fn language_selection_all(label: &str) -> Vec<LanguageSelection> {
    let mut all = vec![LanguageSelection {
        name: label.to_owned(),
        value: String::new(),
    }];
    all.extend(language::ALL.iter().map(|l| LanguageSelection {
        name: l.name.to_owned(),
        value: l.name.to_owned(),
    }));
    all
}

#[cfg(test)]
mod tests {
    use super::*;

    // Swift has no tests for this file; these pin the constants and the list shape.
    #[test]
    fn levels_and_selection() {
        assert_eq!(BITRATE_LEVELS, [0, 4, 8, 20, 40, 80]);
        assert_eq!(SPAN_LEVELS, [5, 10, 15, 30, 60]);
        let all = language_selection_all("Wie die Datei");
        assert_eq!(all.len(), language::ALL.len() + 1);
        assert_eq!(all[0].value, "");
        assert_eq!(all[1].value, "Deutsch");
    }
}
