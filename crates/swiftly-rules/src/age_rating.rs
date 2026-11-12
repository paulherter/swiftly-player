//! Port of AgeRating.swift.
//!
//! The age rating as people write it: "18+", not "age18+". Only the `age` form is
//! rewritten; "PG-13", "FSK 12" or "TV-MA" stay as the server sends them.
//! (`Item.ageRating` is `AgeRating::text(officialRating)`; the model type is not needed.)

use crate::text::{characters, is_cf_whitespace, is_number, lowercased};

/// `AgeRating.text(_:)` (`AgeRating.swift:13-21`).
///
/// Foundation notes: `trimmingCharacters(in: .whitespaces)` is Zs plus tab (see
/// [`crate::text::is_cf_whitespace`]); `hasPrefix("age")`, `dropFirst(3)`, `drop { }` and
/// `prefix { isNumber }` work on Characters (grapheme clusters), as here.
pub fn text(raw: Option<&str>) -> Option<String> {
    let raw = raw?.trim_matches(is_cf_whitespace);
    if raw.is_empty() {
        return None;
    }
    let lowered = lowercased(raw);
    let head = characters(&lowered);
    if head.len() < 3 || head[0] != "a" || head[1] != "g" || head[2] != "e" {
        return Some(raw.to_owned());
    }
    let chars = characters(raw);
    let rest = chars
        .iter()
        .skip(3)
        .skip_while(|c| **c == " " || **c == "-" || **c == "_");
    let digits: String = rest.take_while(|c| is_number(c)).copied().collect();
    if digits.is_empty() {
        return Some(raw.to_owned());
    }
    Some(digits + "+")
}

#[cfg(test)]
mod tests {
    use super::*;

    // Swift: agePrefix()
    #[test]
    fn age_prefix() {
        assert_eq!(text(Some("age18+")).as_deref(), Some("18+"));
        assert_eq!(text(Some("age18")).as_deref(), Some("18+"));
        assert_eq!(text(Some("Age 16+")).as_deref(), Some("16+"));
        assert_eq!(text(Some("age-6")).as_deref(), Some("6+"));
    }

    // Swift: otherSystems()
    #[test]
    fn other_systems() {
        assert_eq!(text(Some("PG-13")).as_deref(), Some("PG-13"));
        assert_eq!(text(Some("FSK 12")).as_deref(), Some("FSK 12"));
        assert_eq!(text(Some("TV-MA")).as_deref(), Some("TV-MA"));
        assert_eq!(text(Some("18+")).as_deref(), Some("18+"));
    }

    // Swift: empty()
    #[test]
    fn empty() {
        assert_eq!(text(None), None);
        assert_eq!(text(Some("  ")), None);
        assert_eq!(text(Some("ageless")).as_deref(), Some("ageless"));
    }
}
