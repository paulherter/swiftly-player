//! The version the app tells the server, and the "is the other one newer" rule
//! (`JK/VersionNumber.swift`, `JK/VersionSame.swift`).
//!
//! Sans-I/O: the bundle values are passed in; the host reads them from its own place
//! (Info list, package version).

use unicode_segmentation::{GraphemeCursor, UnicodeSegmentation};

/// What the app shows when no version is known (`VersionNumber.outBundle`).
pub const UNKNOWN: &str = "unbekannt";

/// "1.0.3 (7)" from the short version and the build, `short` alone without a build, and
/// "unbekannt" without a version (`VersionNumber.outBundle`).
pub fn version_text(short: Option<&str>, build: Option<&str>) -> String {
    match short.filter(|s| !s.is_empty()) {
        Some(short) => match build.filter(|b| !b.is_empty()) {
            Some(build) => format!("{short} ({build})"),
            None => short.to_owned(),
        },
        None => UNKNOWN.to_owned(),
    }
}

/// Number parts of a version; a part reads up to its first non-digit, none counts as 0
/// (`VersionComparison.parts`).
fn parts(version: &str) -> Vec<i64> {
    version
        .split('.')
        .filter(|p| !p.is_empty())
        .map(|p| number_prefix(p).parse().unwrap_or(0))
        .collect()
}

/// Swift `Character.isNumber`: the first scalar of the grapheme cluster is numeric.
fn is_number(cluster: &str) -> bool {
    cluster.chars().next().is_some_and(char::is_numeric)
}

/// `prefix(while: \.isNumber)` over grapheme clusters. A digit with a combining mark stays
/// in the prefix, and then `Int(...)` of it fails (Swift reads 0 / no number).
fn number_prefix(text: &str) -> String {
    text.graphemes(true).take_while(|g| is_number(g)).collect()
}

/// Is `there` newer than `here` (`VersionComparison.newer`)? Compared by number parts, so
/// 1.0.10 is newer than 1.0.9; missing parts count as 0. On equal versions a higher
/// `build_there` wins; without a build over there an equal number is the same state.
pub fn newer(there: &str, here: &str, build_there: Option<i64>, build_here: i64) -> bool {
    let (a, b) = (parts(there), parts(here));
    for i in 0..a.len().max(b.len()) {
        let x = a.get(i).copied().unwrap_or(0);
        let y = b.get(i).copied().unwrap_or(0);
        if x != y {
            return x > y;
        }
    }
    build_there.is_some_and(|there| there > build_here)
}

/// The largest build number a release text names after the whole word "build " or "bau "
/// (`VersionComparison.buildNumber(fromText:)`). "Umbau 12" and "rebuild 9" do not count.
pub fn build_number_from_text(text: &str) -> Option<i64> {
    let small = text.to_lowercase();
    let mut largest: Option<i64> = None;
    for word in ["build ", "bau "] {
        let mut since = 0;
        while let Some(found) = small[since..].find(word) {
            let start = since + found;
            since = start + word.len();
            // Swift searches by `Character`: a match must start and end on a cluster boundary
            // ("build " + combining mark is one character and does not match), and the
            // character before it counts as a letter by its first scalar ("é" as e + U+0301).
            let on_boundary = |at: usize| {
                GraphemeCursor::new(at, small.len(), true)
                    .is_boundary(&small, 0)
                    .unwrap_or(true)
            };
            if !on_boundary(start) || !on_boundary(since) {
                continue;
            }
            if small[..start]
                .graphemes(true)
                .next_back()
                .is_some_and(|g| g.chars().next().is_some_and(char::is_alphabetic))
            {
                continue;
            }
            let digits = number_prefix(&small[since..]);
            if let Ok(figure) = digits.parse::<i64>()
                && figure > largest.unwrap_or(0)
            {
                largest = Some(figure);
            }
        }
    }
    largest
}

#[cfg(test)]
mod tests {
    use super::*;

    fn n(there: &str, here: &str) -> bool {
        newer(there, here, None, 0)
    }

    #[test]
    fn higher_version_is_newer() {
        assert!(n("1.0.4", "1.0.3"));
        assert!(n("1.1.0", "1.0.9"));
        assert!(n("2.0.0", "1.9.9"));
    }

    #[test]
    fn lower_or_equal_is_not() {
        assert!(!n("1.0.2", "1.0.3"));
        assert!(!n("1.0.3", "1.0.3"));
        assert!(!n("0.9.9", "1.0.0"));
    }

    #[test]
    fn ten_is_greater_than_nine() {
        assert!(n("1.0.10", "1.0.9"));
        assert!(!n("1.0.9", "1.0.10"));
    }

    #[test]
    fn missing_parts_count_as_zero() {
        assert!(!n("1.1", "1.1.0"));
        assert!(n("1.2", "1.1.9"));
    }

    #[test]
    fn same_version_higher_build_is_newer() {
        assert!(newer("1.0.3", "1.0.3", Some(2), 1));
        assert!(!newer("1.0.3", "1.0.3", Some(2), 2));
        assert!(!newer("1.0.3", "1.0.3", Some(1), 7));
    }

    #[test]
    fn without_build_number_the_same_version_is_the_same_state() {
        assert!(!newer("1.0.3", "1.0.3", None, 1));
    }

    #[test]
    fn higher_version_beats_any_build_number() {
        assert!(newer("1.0.4", "1.0.3", Some(1), 99));
    }

    #[test]
    fn build_number_is_read_from_the_text() {
        assert_eq!(
            build_number_from_text("## Update — September 20 (build 2, Windows)"),
            Some(2)
        );
        assert_eq!(build_number_from_text("Neu in Bau 7: schneller"), Some(7));
        assert_eq!(build_number_from_text("Nichts davon"), None);
    }

    #[test]
    fn build_number_counts_only_as_a_whole_word() {
        assert_eq!(build_number_from_text("Umbau 12 der Suche"), None);
        assert_eq!(build_number_from_text("rebuild 9 caches, build 3"), Some(3));
        assert_eq!(build_number_from_text("(Build 4)"), Some(4));
    }

    #[test]
    fn the_largest_named_number_wins() {
        assert_eq!(
            build_number_from_text("build 2 brachte X\n\nbuild 7 bringt Y"),
            Some(7)
        );
    }

    #[test]
    fn version_text_follows_the_bundle_rule() {
        assert_eq!(version_text(Some("1.0.3"), Some("7")), "1.0.3 (7)");
        assert_eq!(version_text(Some("1.0.3"), Some("")), "1.0.3");
        assert_eq!(version_text(Some("1.0.3"), None), "1.0.3");
        assert_eq!(version_text(None, Some("7")), UNKNOWN);
        assert_eq!(version_text(Some(""), None), UNKNOWN);
    }
}
