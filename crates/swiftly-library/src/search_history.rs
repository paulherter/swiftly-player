//! `SearchHistory` and `SearchHistoryStore` (Swift `SearchHistory.swift`): the last eight
//! searches, most recent first, one term per line.

use unicode_segmentation::UnicodeSegmentation;

use crate::store::KeyValue;

/// The shared key from before the history belonged to the account (:13).
pub const KEY: &str = "letzteSuchen";
/// How many terms are kept (:14).
pub const AT_MOST: usize = 8;

/// The key for an account; without one, the shared key (:19-22).
pub fn key_for(account: Option<&str>) -> String {
    match account {
        Some(a) if !a.is_empty() => format!("{KEY}.{a}"),
        _ => KEY.to_string(),
    }
}

/// The terms of a stored string; empty lines are omitted like `split(separator:)` (:24-26).
pub fn list(raw: &str) -> Vec<String> {
    // Swift splits on the Character "\n"; "\r\n" is one Character, so it does not split there.
    let mut out = Vec::new();
    let mut line = String::new();
    for g in raw.graphemes(true) {
        if g == "\n" {
            if !line.is_empty() {
                out.push(std::mem::take(&mut line));
            }
        } else {
            line.push_str(g);
        }
    }
    if !line.is_empty() {
        out.push(line);
    }
    out
}

fn fold_case(s: &str) -> String {
    s.to_uppercase().to_lowercase()
}

/// Records a term and returns the new state (:36-42). Nothing under two characters; the
/// same term in a different spelling replaces the old one and moves to the front.
pub fn remember(word: &str, raw: &str) -> String {
    // Foundation's `.whitespacesAndNewlines` also holds U+200B, but (measured here) not a trailing U+FEFF.
    let clean = word.trim_matches(|c: char| {
        c != '\u{FEFF}'
            && swiftly_rules::trim_whitespaces_and_newlines(c.encode_utf8(&mut [0; 4])).is_empty()
    });
    if clean.graphemes(true).count() < 2 {
        return raw.to_string();
    }
    // `caseInsensitiveCompare` folds fully (`ß` equals `SS`, final sigma equals sigma).
    let lower = fold_case(clean);
    let mut new: Vec<String> = list(raw)
        .into_iter()
        .filter(|w| fold_case(w) != lower)
        .collect();
    new.insert(0, clean.to_string());
    new.truncate(AT_MOST);
    new.join("\n")
}

/// Loads the history of an account. An account without history of its own starts from the
/// shared one (:54-60).
pub fn load(account: Option<&str>, store: &dyn KeyValue) -> String {
    let key = key_for(account);
    if key != KEY && store.get(&key).is_none() {
        store.set(&key, &store.get(KEY).unwrap_or_default());
    }
    store.get(&key).unwrap_or_default()
}

/// Saves the history of an account (:62-64).
pub fn save(raw: &str, account: Option<&str>, store: &dyn KeyValue) {
    store.set(&key_for(account), raw);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::MemoryKeyValue;

    #[test]
    fn youngest_first() {
        let mut raw = String::new();
        raw = remember("Dune", &raw);
        raw = remember("Severance", &raw);
        assert_eq!(list(&raw), ["Severance", "Dune"]);
    }
    #[test]
    fn no_double_in_other_spelling() {
        let mut raw = remember("dune", "");
        raw = remember("Severance", &raw);
        raw = remember("Dune", &raw);
        assert_eq!(list(&raw), ["Dune", "Severance"]);
    }
    #[test]
    fn too_short_is_not_kept() {
        assert_eq!(remember(" a ", "Dune"), "Dune");
    }
    #[test]
    fn edge_whitespace_is_cut() {
        assert_eq!(list(&remember("  Dune \n", "")), ["Dune"]);
    }
    #[test]
    fn at_most_eight() {
        let mut raw = String::new();
        for i in 1..=12 {
            raw = remember(&format!("Titel {i}"), &raw);
        }
        let l = list(&raw);
        assert_eq!(l.len(), AT_MOST);
        assert_eq!(l.first().map(String::as_str), Some("Titel 12"));
        assert_eq!(l.last().map(String::as_str), Some("Titel 5"));
    }
    #[test]
    fn previous_state_reads_unchanged() {
        assert_eq!(list("Dune\nSeverance"), ["Dune", "Severance"]);
        assert!(list("").is_empty());
    }
    #[test]
    fn account_starts_from_the_shared_history() {
        let kv = MemoryKeyValue::new();
        kv.set(KEY, "Dune");
        assert_eq!(load(Some("u1"), &kv), "Dune");
        save("Severance", Some("u1"), &kv);
        assert_eq!(load(Some("u1"), &kv), "Severance");
        assert_eq!(load(None, &kv), "Dune");
        assert_eq!(key_for(Some("")), KEY);
        assert_eq!(key_for(Some("u1")), "letzteSuchen.u1");
    }
}
