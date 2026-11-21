//! The screens draw their fixed texts through `swiftly_l10n::tr` (the German wording is the key). A bare German literal
//! that is a catalogue key with an English text of its own would show German on an English device, which is how build 52
//! showed "Was läuft bei dir?" under `LANG=en_US`: the desktop never asked the catalogue. This scan fails on such a
//! literal in the sources of the app, naming the line and the call to use.
//!
//! Allowed without a call: patterns and comparisons (`"Suche" =>`, `== "Suche"`), ids (`Action::from("…")`), a literal
//! inside a `const`/`static` table (the key; the table is read through `tr` where it is drawn), a test module, and a line
//! (or the one before it) marked `// l10n:keep` with the reason.

use std::path::Path;
use swiftly_l10n::{Catalog, Text};

fn unescape(raw: &str) -> String {
    let mut out = String::new();
    let mut chars = raw.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('"') => out.push('"'),
            Some('\\') => out.push('\\'),
            Some('u') => {
                let hex: String = chars.by_ref().skip(1).take_while(|c| *c != '}').collect();
                if let Some(ch) = u32::from_str_radix(&hex, 16).ok().and_then(char::from_u32) {
                    out.push(ch);
                }
            }
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => {}
        }
    }
    out
}

/// The string literals of one line with the byte range of each (a literal that does not close on the line is skipped).
fn literals(line: &str) -> Vec<(usize, usize, String)> {
    let b = line.as_bytes();
    let (mut out, mut i) = (Vec::new(), 0);
    while i < b.len() {
        if b[i] == b'\'' && i + 2 < b.len() && b[i + 2] == b'\'' {
            i += 3; // 'x' char literal, not a string start
            continue;
        }
        if b[i] != b'"' {
            i += 1;
            continue;
        }
        let start = i;
        i += 1;
        while i < b.len() && b[i] != b'"' {
            i += if b[i] == b'\\' { 2 } else { 1 };
        }
        if i >= b.len() {
            break;
        }
        out.push((start, i + 1, unescape(&line[start + 1..i])));
        i += 1;
    }
    out
}

const BEFORE: [&str; 24] = [
    "==",
    "!=",
    "Action::from(",
    ".key(",
    "focus_id(",
    ".contains(",
    "starts_with(",
    "ends_with(",
    ".eq(",
    "println!(",
    "panic!(",
    "expect(",
    ".get(",
    ".insert(",
    "env::var(",
    ".arg(",
    "swiftly_l10n::t(",
    "swiftly_l10n::tr(",
    ".t(",
    "t_args(",
    ".plural(",
    "try_t_args(",
    "Locale::parse(",
    "matches!(x,",
];

fn allowed_context(before: &str, after: &str) -> bool {
    let b = before.trim_end();
    let a = after.trim_start();
    a.starts_with("=>")
        || a.starts_with('|')
        || b.ends_with("\" |")
        || b.ends_with('|') && b.trim_end_matches('|').trim_end().ends_with('"')
        || (b.contains("assert") && b.ends_with('('))
        || BEFORE.iter().any(|p| b.ends_with(p.trim_end()))
}

fn in_table(lines: &[&str], at: usize) -> bool {
    let is_item = |l: &str| {
        let t = l.trim_start();
        let t = t
            .strip_prefix("pub(crate) ")
            .or_else(|| t.strip_prefix("pub "))
            .unwrap_or(t);
        t.starts_with("const ") || t.starts_with("static ")
    };
    let mut i = at;
    loop {
        if is_item(lines[i]) {
            return true;
        }
        if i == 0 || at - i > 12 {
            return false;
        }
        let up = lines[i - 1].trim_end();
        if up.ends_with(';') || up.ends_with('}') || up.is_empty() {
            return false;
        }
        i -= 1;
    }
}

#[test]
fn fixed_screen_texts_go_through_the_catalogue() {
    // Keys whose catalogue has a plain English (or other) text that differs from the German key.
    let keys: std::collections::HashSet<&str> = Catalog::builtin()
        .entries()
        .iter()
        .filter(|e| {
            e.langs
                .iter()
                .any(|(l, t)| *l != "de" && matches!(t, Text::Simple(s) if *s != e.key))
        })
        .map(|e| e.key)
        .collect();
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut bad = Vec::new();
    for entry in std::fs::read_dir(&src).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_none_or(|e| e != "rs") {
            continue;
        }
        let text = std::fs::read_to_string(&path).unwrap();
        let body = text.split("#[cfg(test)]").next().unwrap();
        let lines: Vec<&str> = body.lines().collect();
        for (n, line) in lines.iter().enumerate() {
            let t = line.trim_start();
            if t.starts_with("//") || t.starts_with("#[") {
                continue;
            }
            if line.contains("l10n:keep") || (n > 0 && lines[n - 1].contains("l10n:keep")) {
                continue;
            }
            for (from, to, lit) in literals(line) {
                if !keys.contains(lit.as_str()) {
                    continue;
                }
                let mut before = line[..from].to_owned();
                if before.trim().is_empty() && n > 0 {
                    before = lines[n - 1].to_owned();
                }
                if allowed_context(&before, &line[to..]) || in_table(&lines, n) {
                    continue;
                }
                bad.push(format!(
                    "{}:{}: {:?} -> swiftly_l10n::tr(\"…\")",
                    path.file_name().unwrap().to_string_lossy(),
                    n + 1,
                    lit
                ));
            }
        }
    }
    assert!(
        bad.is_empty(),
        "German screen texts outside the catalogue ({}):\n{}",
        bad.len(),
        bad.join("\n")
    );
}
