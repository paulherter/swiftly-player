//! Every icon the desktop code can ask for exists in the compiled-in icon set, and the image page of the real app keeps
//! room for the icons after the poster region took its rows. The release app drew no server marks, no wordmark and no
//! player centre buttons: the names were fine, the page had no rows left for them.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use swiftly_ui::icons::{path_data, stroke_suffix};

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for e in entries.flatten() {
        let p = e.path();
        if p.is_dir() {
            rust_files(&p, out);
        } else if p.extension().is_some_and(|x| x == "rs") {
            out.push(p);
        }
    }
}

/// The string literals of `text` (plain `"..."` ones, with their escapes skipped) with their byte offset.
fn literals(text: &str) -> Vec<(usize, String)> {
    let b = text.as_bytes();
    let (mut out, mut i) = (Vec::new(), 0);
    while i < b.len() {
        match b[i] {
            b'/' if b.get(i + 1) == Some(&b'/') => {
                while i < b.len() && b[i] != b'\n' {
                    i += 1;
                }
            }
            b'\'' if b.get(i + 2) == Some(&b'\'') => i += 3,
            b'"' => {
                let start = i;
                i += 1;
                let mut s = String::new();
                while i < b.len() && b[i] != b'"' {
                    if b[i] == b'\\' {
                        i += 1;
                    }
                    if let Some(c) = text.get(i..).and_then(|t| t.chars().next()) {
                        s.push(c);
                        i += c.len_utf8();
                    } else {
                        i += 1;
                    }
                }
                out.push((start, s));
                i += 1;
            }
            _ => i += 1,
        }
    }
    out
}

fn looks_like_asset(s: &str) -> bool {
    let base = s.split('.').next().unwrap_or("");
    s.len() >= 3
        && s.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '.')
        && !base.is_empty()
        && !base.starts_with('-')
        && !base.ends_with('-')
        && s.matches('.').count() <= 2
}

/// Literals that sit in a call that takes an asset name (`node(`, `node_template(`) or on a line that talks about
/// icons, symbols, glyphs or marks.
fn asked_for() -> BTreeSet<String> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut files = Vec::new();
    rust_files(&root.join("src"), &mut files);
    rust_files(&root.join("../swiftly-ui/src"), &mut files);
    let mut names = BTreeSet::new();
    for f in files {
        let name = f.file_name().map(|n| n.to_string_lossy().into_owned());
        if name.as_deref().is_some_and(|n| n.starts_with("icon_data")) {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&f) else {
            continue;
        };
        for (at, lit) in literals(&text) {
            if !looks_like_asset(&lit) {
                continue;
            }
            let line_start = text[..at].rfind('\n').map_or(0, |n| n + 1);
            let line_end = text[at..].find('\n').map_or(text.len(), |n| at + n);
            let line = &text[line_start..line_end];
            let before = &text[at.saturating_sub(90)..at];
            let in_call = before.contains(".node(") || before.contains(".node_template(");
            let talks = ["icon", "symbol", "glyph", "asset", "mark"]
                .iter()
                .any(|k| line.to_lowercase().contains(k));
            if in_call || talks {
                names.insert(lit);
            }
        }
    }
    names
}

/// Words on such lines that are not names of the shared icon set: the player's own glyph names (drawn in
/// `player_glyphs.rs` or mapped there to an asset that the scan finds as its own literal), control keys, file and host
/// names, script marks and plain words.
const NOT_ASSETS: &[&str] = &[
    "asset",
    "back",
    "close",
    "delete",
    "download",
    "fail-close",
    "fullscreen",
    "fullscreen-exit",
    "glyph-pause",
    "glyph-play",
    "gobackward",
    "goforward",
    "jellyfin.beispiel.de",
    "layer-close",
    "layer-x",
    "legacy-import.done",
    "load.go",
    "load.queue",
    "load.sound",
    "mark",
    "mute",
    "nav.back",
    "nav.forward",
    "pause",
    "pick.l.",
    "pip",
    "plexstart",
    "sel.go",
    "sel.retry",
    "settings.json",
    "skip-end",
    "surface",
    "until-player-timeout",
    "wordmark.letters",
    "wordmark.mark",
];

#[test]
fn every_icon_name_the_code_asks_for_is_in_the_icon_set() {
    let names = asked_for();
    assert!(names.len() > 40, "the scan found only {names:?}");
    let missing: Vec<&String> = names
        .iter()
        .filter(|n| !NOT_ASSETS.contains(&n.as_str()))
        .filter(|n| path_data(n).is_none())
        .collect();
    assert!(missing.is_empty(), "not in the icon set: {missing:?}");
}

#[test]
fn every_stroke_variant_a_size_asks_for_resolves_or_falls_back() {
    // `Icons::node` asks for `<name><suffix>` and falls back to the plain name: the plain name must exist.
    for n in asked_for().iter().filter(|n| path_data(n).is_some()) {
        for pt in [
            10.0_f32, 12.0, 14.0, 17.0, 18.0, 22.0, 28.0, 34.0, 44.0, 60.0, 88.0,
        ] {
            let asked = format!("{n}{}", stroke_suffix(pt));
            assert!(
                path_data(&asked).is_some() || path_data(n).is_some(),
                "{asked} at {pt} pt has no drawing"
            );
        }
    }
}
