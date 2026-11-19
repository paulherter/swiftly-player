//! Guard for `crates/swiftly-uniffi/data/core-words.json`: the core sends the playback and player words
//! (`ergebnis`, `angebot`, `einblendung`, `art`, the first-frame and stream-watch advice) only through
//! `swiftly_vm::core_words`.
//!
//! **Why.** The lists in the contract file come from the constants in `core_words.rs`. A producer that writes the
//! word as a raw literal keeps sending the old text after a constant changes, while the JSON file and every UI
//! follow the constant: the UI then compares against a word the core never sends. This test reads the contract
//! file and fails for every quoted word of those groups that appears in the production code of any crate outside
//! `core_words.rs`.
//!
//! Scope: the groups whose producer is `core_words.rs` (`playback.*`, `player.*`). The other groups are derived
//! from their own producer enum (`DownloadState`, `LibraryFilter`, `DownloadQuality`, the wire `command` module,
//! the Plex step list with its own test), which is the one place that holds those words.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

const ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../..");

/// Files where a word of the checked groups is a different vocabulary, not a word the core sends in an answer
/// (file under `crates/`, word, why). Keep this list short; every entry needs a reason.
const OTHER_VOCABULARY: &[(&str, &str, &str)] = &[
    (
        "swiftly-seerr/src/status.rs",
        "gesperrt",
        "label of a Seerr request status, not the `ergebnis` of a switch",
    ),
    (
        "swiftly-vm/src/seerr.rs",
        "gesperrt",
        "short word of a Seerr request status, not the `ergebnis` of a switch",
    ),
    (
        "swiftly-vm/src/seerr_title.rs",
        "gesperrt",
        "translation key of a Seerr badge, not the `ergebnis` of a switch",
    ),
    (
        "swiftly-l10n/src/catalog_data.rs",
        "gesperrt",
        "German key of the Seerr badge word in the generated catalogue",
    ),
    (
        "swiftly-uniffi/src/legacy_handoff.rs",
        "warten",
        "`art` of a handoff animation the UI sends in, not a first-frame advice",
    ),
];

/// The words of the groups produced by `core_words.rs`.
fn checked_words() -> BTreeSet<String> {
    let text =
        std::fs::read_to_string(Path::new(ROOT).join("crates/swiftly-uniffi/data/core-words.json"))
            .expect("crates/swiftly-uniffi/data/core-words.json");
    let json: serde_json::Value = serde_json::from_str(&text).unwrap();
    let mut words = BTreeSet::new();
    for (group, list) in json.as_object().unwrap() {
        if group.starts_with("playback.") || group.starts_with("player.") {
            for w in list.as_array().unwrap() {
                words.insert(w.as_str().unwrap().to_owned());
            }
        }
    }
    words
}

/// The string literals of one line, without comments (`//` outside a literal ends the line).
fn literals(line: &str) -> Vec<String> {
    let bytes = line.as_bytes();
    let (mut out, mut start, mut i) = (Vec::new(), None::<usize>, 0);
    while i < bytes.len() {
        match (start, bytes[i]) {
            (Some(_), b'\\') => i += 1,
            (Some(s), b'"') => {
                out.push(line[s..i].to_owned());
                start = None;
            }
            (None, b'"') => start = Some(i + 1),
            (None, b'/') if bytes.get(i + 1) == Some(&b'/') => break,
            _ => {}
        }
        i += 1;
    }
    out
}

/// The lines before the first `#[cfg(test)]` module (the attribute, optional further attributes, then `mod`).
fn production_lines(source: &str) -> Vec<&str> {
    let lines: Vec<&str> = source.lines().collect();
    for (n, line) in lines.iter().enumerate() {
        if *line == "#[cfg(test)]" {
            let next = lines[n + 1..]
                .iter()
                .find(|l| !l.trim_start().starts_with("#["));
            if next.is_some_and(|l| l.starts_with("mod ")) {
                return lines[..n].to_vec();
            }
        }
    }
    lines
}

/// `(line, word)` for every quoted word in the production part of a source (up to the test module). Attribute
/// lines (`#[serde(rename = "naechste")]` is a JSON key, not a word) are skipped.
fn raw_words(source: &str, words: &BTreeSet<String>) -> Vec<(usize, String)> {
    let mut found = Vec::new();
    for (n, line) in production_lines(source).into_iter().enumerate() {
        if line.trim_start().starts_with("#[") {
            continue;
        }
        for lit in literals(line) {
            if words.contains(&lit) {
                found.push((n + 1, lit));
            }
        }
    }
    found
}

fn sources(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(read) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in read.flatten() {
        let path = entry.path();
        if path.is_dir() {
            sources(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

#[test]
fn no_crate_sends_a_contract_word_as_a_raw_literal() {
    let words = checked_words();
    assert!(
        words.len() >= 20,
        "the contract file lost its playback words: {words:?}"
    );
    let crates = Path::new(ROOT).join("crates");
    let mut files = Vec::new();
    for krate in std::fs::read_dir(&crates).unwrap().flatten() {
        sources(&krate.path().join("src"), &mut files);
    }
    files.sort();
    let mut offences = Vec::new();
    for file in &files {
        let rel = file
            .strip_prefix(&crates)
            .unwrap()
            .to_string_lossy()
            .replace('\\', "/");
        // core_words.rs defines the words; `*_tests.rs` files are test modules declared with `#[cfg(test)]`.
        if rel == "swiftly-vm/src/core_words.rs" || rel.ends_with("_tests.rs") {
            continue;
        }
        let source = std::fs::read_to_string(file).unwrap();
        for (line, word) in raw_words(&source, &words) {
            let allowed = OTHER_VOCABULARY
                .iter()
                .any(|(f, w, _)| *f == rel && *w == word);
            if !allowed {
                offences.push(format!("crates/{rel}:{line}: \"{word}\""));
            }
        }
    }
    assert!(
        offences.is_empty(),
        "contract words written as literals; use the constants of swiftly_vm::core_words:\n{}",
        offences.join("\n")
    );
}

#[test]
fn the_scan_sees_a_literal_and_ignores_comments_and_attributes() {
    let words: BTreeSet<String> = ["gewechselt".to_owned(), "nichts".to_owned()].into();
    let source = "\
fn a() -> &'static str { \"gewechselt\" }
// \"nichts\" in a comment
#[serde(rename = \"nichts\")]
fn b() { f(\"x\", \"nichts\"); } // \"gewechselt\"
#[cfg(test)]
#[allow(clippy::expect_used)]
mod tests { fn c() { \"nichts\"; } }
";
    assert_eq!(
        raw_words(source, &words),
        [(1, "gewechselt".to_owned()), (4, "nichts".to_owned())]
    );
}
