//! Crate-private helpers that reproduce Swift's `Character` / `String` semantics.
//!
//! Swift's `Character` is an extended grapheme cluster; its `isLetter` / `isNumber` look at
//! the cluster's **first scalar** only (`Character.isLetter` is
//! `_firstScalar.properties.isAlphabetic`, `isNumber` is `numericType != nil`).
//! Rust's `char::is_alphabetic` is the same Unicode `Alphabetic` property; `char::is_numeric`
//! (general category N*) matches `numericType != nil` except for a few CJK numerals, which
//! are alphabetic anyway.

use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

/// The grapheme clusters of `s`, i.e. Swift's `[Character]`.
pub(crate) fn characters(s: &str) -> Vec<&str> {
    s.graphemes(true).collect()
}

/// `Character.isLetter`.
pub(crate) fn is_letter(character: &str) -> bool {
    character.chars().next().is_some_and(char::is_alphabetic)
}

/// `Character.isNumber`.
pub(crate) fn is_number(character: &str) -> bool {
    character.chars().next().is_some_and(char::is_numeric)
}

/// `String.uppercased()`: full Unicode mapping per scalar, no locale ("ß" gives "SS").
pub(crate) fn uppercased(s: &str) -> String {
    s.chars().flat_map(char::to_uppercase).collect()
}

/// `String.lowercased()`: per-scalar mapping. Rust's `str::to_lowercase` additionally
/// applies the final-sigma rule, which Swift does not, so map scalar by scalar.
pub(crate) fn lowercased(s: &str) -> String {
    s.chars().flat_map(char::to_lowercase).collect()
}

/// Canonical composition, so `==` / `contains` behave like Swift's canonical equivalence.
pub(crate) fn nfc(s: &str) -> String {
    s.nfc().collect()
}

/// First scalar of the canonical decomposition (`decomposedStringWithCanonicalMapping`).
pub(crate) fn nfd_first(s: &str) -> Option<char> {
    s.nfd().next()
}

/// Swift `CharacterSet.whitespaces`: general category Zs plus U+0009, and, measured against the
/// real Foundation (oracle `term_trim`, finding F-oracle-01), the zero-width space U+200B and the
/// byte order mark U+FEFF.
pub(crate) fn is_cf_whitespace(c: char) -> bool {
    c == '\u{9}' || c == '\u{200B}' || c == '\u{FEFF}' || (c.is_whitespace() && !is_cf_newline(c))
}

/// Swift `CharacterSet.newlines`: U+000A..U+000D, U+0085, U+2028, U+2029.
pub(crate) fn is_cf_newline(c: char) -> bool {
    matches!(c, '\u{A}'..='\u{D}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// Swift `trimmingCharacters(in: .whitespacesAndNewlines)`: [`is_cf_whitespace`] plus the newlines (F-oracle-E04).
pub fn trim_whitespaces_and_newlines(s: &str) -> &str {
    s.trim_matches(|c| is_cf_whitespace(c) || is_cf_newline(c))
}

/// Swift `trimmingCharacters(in: .whitespacesAndNewlines)` as measured on names: like
/// [`trim_whitespaces_and_newlines`], but a trailing U+FEFF stops the trim (F-oracle-H04).
pub fn trim_name(s: &str) -> &str {
    let start = s.trim_start_matches(|c| is_cf_whitespace(c) || is_cf_newline(c));
    start.trim_end_matches(|c| c != '\u{FEFF}' && (is_cf_whitespace(c) || is_cf_newline(c)))
}

/// Swift `a.caseInsensitiveCompare(b) == .orderedSame`: canonically equivalent after full case
/// folding (`ß` equals `ss`, `e` + U+0301 equals `é`), no diacritic folding (F-oracle-H03).
pub fn case_insensitive_equal(a: &str, b: &str) -> bool {
    fn fold(s: &str) -> String {
        s.nfc()
            .flat_map(char::to_uppercase)
            .flat_map(char::to_lowercase)
            .collect()
    }
    a == b || fold(a) == fold(b)
}

/// Swift `trimmingCharacters(in: .whitespaces)` (not the newlines), see [`is_cf_whitespace`].
pub fn trim_whitespaces(s: &str) -> &str {
    s.trim_matches(is_cf_whitespace)
}
