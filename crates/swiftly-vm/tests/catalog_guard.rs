//! Guard: every German text the core hands to the translator exists in the catalogue in German, English and Russian.
//!
//! **Why.** The core looks a text up by its German wording. A key that is not in `Localizable.xcstrings` falls back to
//! the German key itself, so an English or Russian device shows German words and nothing fails: no build, no test.
//! The Android proof run on an English device showed exactly that ("%@ ist da", "Wird gesucht", "Holen
//! fehlgeschlagen", the month names). This test reads the production code of every crate, takes each string literal
//! that goes into `.t(`, `.t_args(`, `.plural(` or a `Words::Key/Count/Pair(` and the player menu's `key(`, plus the
//! word tables listed in `TABLES`, and fails with the file and line of each key that lacks a language.
//!
//! A new text therefore needs its three languages in `Sources/Shared/Localizable.xcstrings` (then
//! `cargo run -p swiftly-l10n --bin gen_catalog`) before CI goes green.
//!
//! The Android UI looks texts up the same way with `translated("…")` (Kotlin, `Texts.kt`). A second test scans
//! `Android/**/*.kt` (not `build/` or the test source sets) for the string literals in the first argument of
//! `translated(`, including the branches of `if`/`when` inside it, and checks them like the core keys. Kotlin writes
//! `%d`/`%s` where the catalogue has `%lld`/`%@`; both spellings count.
//!
//! Limits: a text that is built at run time (`t.t(name)`) is not seen; keep such words in a table named in `TABLES`
//! or as literals in a `match`, and add them to `EXTRA_KEYS`.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::path::{Path, PathBuf};

use swiftly_l10n::Catalog;

const LANGS: [&str; 3] = ["de", "en", "ru"];

/// Word tables whose entries are looked up one by one (`t.t(MONTHS[m - 1])`).
const TABLES: &[&str] = &["const MONTHS"];

/// Words chosen in a `match` and looked up afterwards (`let unit = match … { "Filme" … }; t.t(unit)`).
const EXTRA_KEYS: &[&str] = &["Staffel", "Staffeln", "Film", "Filme"];

/// Calls whose first string literal is a catalogue key.
const CALLS: &[&str] = &[
    ".t(",
    ".t_args(",
    ".plural(",
    "Words::Key(",
    "Words::Count(",
    "Words::Pair(",
];

fn android_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Android")
}

fn crates_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..")
}

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(read) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in read.flatten() {
        let path = entry.path();
        if path.is_dir() {
            rust_files(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

fn kotlin_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(read) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in read.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        if path.is_dir() {
            // Build output and test source sets hold generated code and fixtures, not app texts.
            if !matches!(
                name.to_str(),
                Some("build" | "test" | "androidTest" | ".gradle")
            ) {
                kotlin_files(&path, out);
            }
        } else if path.extension().is_some_and(|e| e == "kt") {
            out.push(path);
        }
    }
}

/// Reads one Kotlin string literal starting at `at` (the opening quote); returns the text (`None` if it has a
/// `$` template or an escape we do not know, which cannot be a fixed key) and the index after the closing quote.
fn kotlin_literal(s: &str, at: usize) -> Option<(Option<String>, usize)> {
    let bytes = s.as_bytes();
    let mut out = Some(String::new());
    let mut i = at + 1;
    while i < bytes.len() {
        match bytes[i] {
            b'"' => return Some((out, i + 1)),
            b'\\' => {
                let next = *bytes.get(i + 1)?;
                let pushed = match next {
                    b'n' => Some('\n'),
                    b't' => Some('\t'),
                    b'"' | b'\\' | b'\'' | b'$' => Some(next as char),
                    b'u' => s
                        .get(i + 2..i + 6)
                        .and_then(|h| u32::from_str_radix(h, 16).ok())
                        .and_then(char::from_u32),
                    _ => None,
                };
                if next == b'u' {
                    i += 4;
                }
                match (&mut out, pushed) {
                    (Some(o), Some(c)) => o.push(c),
                    _ => out = None,
                }
                i += 2;
            }
            b'$' => {
                out = None;
                i += 1;
            }
            _ => {
                let c = s[i..].chars().next()?;
                if let Some(o) = &mut out {
                    o.push(c);
                }
                i += c.len_utf8();
            }
        }
    }
    None
}

/// (key, line) for every fixed literal in the first argument of a Kotlin `translated(` call.
fn android_keys_in(text: &str) -> Vec<(String, usize)> {
    let bytes = text.as_bytes();
    let line = |at: usize| text[..at].matches('\n').count() + 1;
    let mut found = Vec::new();
    let mut from = 0;
    while let Some(rel) = text[from..].find("translated(") {
        let at = from + rel;
        from = at + "translated(".len();
        let before = text[..at].chars().next_back();
        // `fun translated(` is the definition; `xtranslated(` is another name.
        if before.is_some_and(|c| c.is_alphanumeric() || matches!(c, '_' | '.'))
            || text[..at].ends_with("fun ")
        {
            continue;
        }
        let mut depth = 1;
        let mut i = from;
        while i < bytes.len() && depth > 0 {
            match bytes[i] {
                b'"' => {
                    let Some((lit, end)) = kotlin_literal(text, i) else {
                        break;
                    };
                    let head = text[..i].trim_end();
                    let tail = text[end..].trim_start();
                    // A `when` condition (`"small" ->`) or a comparison (`x == "tv"`) is not shown to anyone.
                    let condition =
                        tail.starts_with("->") || head.ends_with("==") || head.ends_with("!=");
                    if depth == 1
                        && !condition
                        && let Some(key) = lit
                    {
                        found.push((key, line(i)));
                    }
                    i = end;
                    continue;
                }
                b'(' => depth += 1,
                b')' => depth -= 1,
                b',' if depth == 1 => break,
                _ => {}
            }
            i += 1;
        }
    }
    found
}

/// The catalogue spells Kotlin's `%d` as `%lld` and `%s` as `%@`.
fn apple_form(key: &str) -> String {
    let mut out = String::new();
    let mut chars = key.chars().peekable();
    while let Some(c) = chars.next() {
        out.push(c);
        if c != '%' {
            continue;
        }
        // An optional position (`%2$s`) stays as written.
        while let Some(d) = chars.next_if(|d| d.is_ascii_digit() || *d == '$') {
            out.push(d);
        }
        if chars.next_if_eq(&'d').is_some() {
            out.push_str("lld");
        } else if chars.next_if_eq(&'s').is_some() {
            out.push('@');
        }
    }
    out
}

/// Reads one Rust string literal starting at `at` (which must point at the opening quote); returns the text and the
/// index after the closing quote.
fn literal(s: &str, at: usize) -> Option<(String, usize)> {
    let bytes = s.as_bytes();
    if bytes.get(at) != Some(&b'"') {
        return None;
    }
    let mut out = String::new();
    let mut i = at + 1;
    while i < bytes.len() {
        match bytes[i] {
            b'"' => return Some((out, i + 1)),
            b'\\' => {
                let next = *bytes.get(i + 1)?;
                match next {
                    b'n' => out.push('\n'),
                    b't' => out.push('\t'),
                    b'"' => out.push('"'),
                    b'\\' => out.push('\\'),
                    b'\'' => out.push('\''),
                    b'u' => {
                        let end = s[i..].find('}')? + i;
                        let hex = &s[i + 3..end];
                        out.push(char::from_u32(u32::from_str_radix(hex, 16).ok()?)?);
                        i = end + 1;
                        continue;
                    }
                    // A line continuation swallows the line break and the indent.
                    b'\n' => {
                        i += 2;
                        while bytes.get(i).is_some_and(u8::is_ascii_whitespace) {
                            i += 1;
                        }
                        continue;
                    }
                    _ => return None,
                }
                i += 2;
            }
            _ => {
                let c = s[i..].chars().next()?;
                out.push(c);
                i += c.len_utf8();
            }
        }
    }
    None
}

fn skip_space(s: &str, mut i: usize) -> usize {
    while s.as_bytes().get(i).is_some_and(u8::is_ascii_whitespace) {
        i += 1;
    }
    i
}

/// (key, line) for every catalogue key the production code of `text` uses.
fn keys_in(text: &str, player_menu: bool) -> Vec<(String, usize)> {
    // Unit tests sit at the end of the file; their literals are fixtures, not app texts.
    let code = text.find("#[cfg(test)]").map_or(text, |i| &text[..i]);
    let line = |at: usize| code[..at].matches('\n').count() + 1;
    let mut found = Vec::new();
    let mut calls: Vec<&str> = CALLS.to_vec();
    if player_menu {
        calls.push("key(");
    }
    for call in calls {
        let mut from = 0;
        while let Some(rel) = code[from..].find(call) {
            let at = from + rel;
            from = at + call.len();
            // `key(` must be the helper, not the tail of another name.
            if call == "key(" {
                let before = code[..at].chars().next_back();
                if before.is_some_and(|c| c.is_alphanumeric() || matches!(c, '_' | '.' | ':')) {
                    continue;
                }
            }
            let start = skip_space(code, from);
            let Some((first, end)) = literal(code, start) else {
                continue;
            };
            found.push((first, line(at)));
            if call == "Words::Pair(" {
                let comma = skip_space(code, end);
                if code.as_bytes().get(comma) == Some(&b',')
                    && let Some((second, _)) = literal(code, skip_space(code, comma + 1))
                {
                    found.push((second, line(at)));
                }
            }
        }
    }
    for table in TABLES {
        if let Some(at) = code.find(table) {
            let open = code[at..].find("= [").map_or(at, |i| at + i + 3);
            let close = code[open..].find("];").map_or(code.len(), |i| open + i);
            let mut i = open;
            while i < close {
                if code.as_bytes()[i] == b'"'
                    && let Some((word, end)) = literal(code, i)
                {
                    found.push((word, line(i)));
                    i = end;
                } else {
                    i += 1;
                }
            }
        }
    }
    found
}

#[test]
fn every_text_the_core_looks_up_has_german_english_and_russian() {
    let catalog = Catalog::builtin();
    let mut files = Vec::new();
    for entry in std::fs::read_dir(crates_dir()).unwrap().flatten() {
        // The catalogue's own crate holds the generated data and its tests, not app texts.
        if entry.file_name() != "swiftly-l10n" {
            rust_files(&entry.path().join("src"), &mut files);
        }
    }
    assert!(files.len() > 100, "found only {} source files", files.len());

    let mut problems = Vec::new();
    let mut seen = 0;
    let mut check = |key: &str, where_: String| {
        seen += 1;
        match catalog.get(key) {
            None => problems.push(format!("{where_}: {key:?} is not in the catalogue")),
            Some(entry) => {
                for lang in LANGS {
                    if entry.text(lang).is_none() {
                        problems.push(format!("{where_}: {key:?} has no {lang} text"));
                    }
                }
            }
        }
    };
    for file in &files {
        let text = std::fs::read_to_string(file).unwrap();
        let name = file
            .strip_prefix(crates_dir())
            .unwrap()
            .display()
            .to_string();
        let player_menu = name.ends_with("swiftly-vm/src/player_menu.rs");
        for (key, line) in keys_in(&text, player_menu) {
            check(&key, format!("crates/{name}:{line}"));
        }
    }
    for key in EXTRA_KEYS {
        check(key, "EXTRA_KEYS".to_owned());
    }
    assert!(
        seen > 200,
        "the scan found only {seen} keys; the patterns broke"
    );
    assert!(
        problems.is_empty(),
        "texts without en/ru in Sources/Shared/Localizable.xcstrings ({}):\n{}",
        problems.len(),
        problems.join("\n")
    );
}

#[test]
fn the_scanner_reads_literals_and_tables() {
    let src = "fn f(t: &T) {\n    t.t_args(\n        \"Noch %lld \\\"x\\\"\",\n        &[]);\n    Words::Pair(\"A\", \"B\");\n    const MONTHS: [&str; 2] = [\"Jan.\", \"Mai\"];\n}\n#[cfg(test)]\nmod t { fn g() { t.t(\"Ignored\"); } }";
    let keys: Vec<String> = keys_in(src, false).into_iter().map(|(k, _)| k).collect();
    assert_eq!(keys, ["Noch %lld \"x\"", "A", "B", "Jan.", "Mai"]);
}

#[test]
fn every_android_text_has_german_english_and_russian() {
    let catalog = Catalog::builtin();
    let mut files = Vec::new();
    kotlin_files(&android_dir(), &mut files);
    assert!(files.len() > 50, "found only {} Kotlin files", files.len());

    let mut problems = Vec::new();
    let mut seen = 0;
    for file in &files {
        let text = std::fs::read_to_string(file).unwrap();
        let name = file
            .strip_prefix(android_dir())
            .unwrap()
            .display()
            .to_string();
        for (key, line) in android_keys_in(&text) {
            seen += 1;
            let entry = catalog.get(&key).or_else(|| catalog.get(&apple_form(&key)));
            match entry {
                None => problems.push(format!(
                    "Android/{name}:{line}: {key:?} is not in the catalogue"
                )),
                Some(entry) => {
                    for lang in LANGS {
                        if entry.text(lang).is_none() {
                            problems
                                .push(format!("Android/{name}:{line}: {key:?} has no {lang} text"));
                        }
                    }
                }
            }
        }
    }
    assert!(
        seen > 300,
        "the scan found only {seen} Android keys; the pattern broke"
    );
    assert!(
        problems.is_empty(),
        "Android texts without en/ru in Sources/Shared/Localizable.xcstrings ({}):\n{}",
        problems.len(),
        problems.join("\n")
    );
}

#[test]
fn the_android_scanner_reads_branches_and_skips_conditions() {
    let src = "val a = translated(\"Anmelden\")\nval b = translated(if (x == \"tv\") \"Serie\" else \"Film\", n)\n\
               val c = translated(when (w) {\n \"small\" -> \"Klein\"; else -> \"Normal\" })\n\
               val d = translated(\"Von %s \\\"x\\\" $name\")\nfun translated(key: String) = key\nval e = translated(\n  \"S%d · F%d\", 1, 2)";
    let keys: Vec<String> = android_keys_in(src).into_iter().map(|(k, _)| k).collect();
    assert_eq!(
        keys,
        ["Anmelden", "Serie", "Film", "Klein", "Normal", "S%d · F%d"]
    );
    assert_eq!(apple_form("S%d · F%2$s %1$d"), "S%lld · F%2$@ %1$lld");
}
