//! `components`: design name = code name on every platform .
//!
//! Source of truth: the `Components` page of `design/Swiftly Player.isd`, snapshotted by
//! `cargo run -p swiftly-design --bin gen_tokens -- --isd <file>` into `crates/swiftly-design/data/components.tsv`
//! (one line per component family: `Family`, platforms, variants, sections, instances on the screens).
//!
//! What the command does:
//! 1. When the design file is at hand (`--isd <file>`, env `SWIFTLY_ISD`, or `design/Swiftly Player.isd`), it asks
//!    `gen_tokens --check` whether the snapshot is current. Fails when it is not.
//! 2. It reads the name column of the component map table (`SWIFTLY_COMPONENT_MAP`, default `design/component-map.md`) and fails when a family of the snapshot has no row.
//! 3. For every family it looks in the Rust UI (`crates/swiftly-ui`, `crates/swiftly-desktop`) for a free function
//!    `snake_case_name`, a type `Name`, or a `Design name: Name` doc comment (alias), and in the Swift and Kotlin
//!    sources for a definition `Name` (plain text search, informational).
//! 4. It fails when the map says a family exists in Rust (`same`, `alias`) and the code no longer has it.
//!
//! Prints one line per component; `summary` is the single line `check-all` shows.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const SNAPSHOT: &str = "crates/swiftly-design/data/components.tsv";
/// Default place of the component map table; `SWIFTLY_COMPONENT_MAP` overrides it.
const MAP: &str = "design/component-map.md";
const RUST_DIRS: [&str; 2] = ["crates/swiftly-ui/src", "crates/swiftly-desktop/src"];
const SWIFT_DIRS: [&str; 1] = ["Sources"];
const KOTLIN_DIRS: [&str; 1] = ["Android"];

pub struct Family {
    pub name: String,
    pub platforms: String,
    pub variants: String,
    pub section: String,
    pub instances: usize,
}

/// One line per family: how the Rust UI, Swift and Kotlin name it.
pub struct Row {
    pub name: String,
    pub rust: Found,
    pub swift: bool,
    pub kotlin: bool,
    /// The Rust status written in the map (`same`, `alias`, `differs`, `missing`), when the map has a row.
    pub mapped_rust: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Found {
    Name,
    Alias,
    Missing,
}

impl Found {
    fn word(self) -> &'static str {
        match self {
            Found::Name => "found",
            Found::Alias => "alias",
            Found::Missing => "missing",
        }
    }
}

pub fn snake(name: &str) -> String {
    let mut out = String::new();
    let chars: Vec<char> = name.chars().collect();
    for (i, c) in chars.iter().enumerate() {
        if c.is_uppercase()
            && i > 0
            && (chars[i - 1].is_lowercase() || chars[i - 1].is_ascii_digit())
        {
            out.push('_');
        }
        out.extend(c.to_lowercase());
    }
    out
}

pub fn read_snapshot(root: &Path) -> Result<Vec<Family>, String> {
    let path = root.join(SNAPSHOT);
    let text = fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(text
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| {
            let c: Vec<&str> = l.split('\t').collect();
            Family {
                name: c[0].to_owned(),
                platforms: c.get(1).unwrap_or(&"").to_string(),
                variants: c.get(2).unwrap_or(&"").to_string(),
                section: c.get(3).unwrap_or(&"").to_string(),
                instances: c.get(4).and_then(|n| n.parse().ok()).unwrap_or(0),
            }
        })
        .collect())
}

/// Design names (first column) and the Rust status column of the map table; the table header names the columns.
fn read_map(root: &Path) -> Result<BTreeMap<String, String>, String> {
    let path =
        std::env::var_os("SWIFTLY_COMPONENT_MAP").map_or_else(|| root.join(MAP), |p| root.join(p));
    let text = fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut rust_col = None;
    let mut out = BTreeMap::new();
    let mut in_table = false;
    for line in text.lines() {
        if !line.starts_with('|') {
            in_table = false;
            continue;
        }
        let cells: Vec<&str> = line
            .trim()
            .trim_matches('|')
            .split('|')
            .map(str::trim)
            .collect();
        if cells
            .first()
            .is_some_and(|c| c.eq_ignore_ascii_case("design name"))
        {
            rust_col = cells
                .iter()
                .position(|c| c.eq_ignore_ascii_case("rust status"));
            in_table = true;
            continue;
        }
        if !in_table {
            continue;
        }
        let name = cells[0].trim_matches('`');
        if rust_col.is_some()
            && !name.is_empty()
            && name.chars().all(|c| c.is_ascii_alphanumeric())
            && name.starts_with(|c: char| c.is_ascii_uppercase())
        {
            let status = rust_col
                .and_then(|i| cells.get(i))
                .map(|s| s.trim_matches('`').to_owned())
                .unwrap_or_default();
            out.insert(name.to_owned(), status);
        }
    }
    Ok(out)
}

fn walk(dir: &Path, ext: &str, out: &mut Vec<PathBuf>) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        let name = e.file_name().to_string_lossy().into_owned();
        if p.is_dir() {
            if !matches!(
                name.as_str(),
                "build" | ".build" | "target" | ".gradle" | ".git" | "node_modules"
            ) {
                walk(&p, ext, out);
            }
        } else if p.extension().is_some_and(|x| x == ext) {
            out.push(p);
        }
    }
}

fn words(line: &str) -> impl Iterator<Item = &str> {
    line.split(|c: char| !(c.is_alphanumeric() || c == '_'))
        .filter(|w| !w.is_empty())
}

/// Names defined by `keywords` (the word after the keyword) in all files below `dirs`. With `free_only`, a Rust item
/// counts only at column 0, so methods and test helpers do not hide a missing component.
fn definitions(
    root: &Path,
    dirs: &[&str],
    ext: &str,
    keywords: &[&str],
    free_only: bool,
) -> (BTreeSet<String>, BTreeSet<String>) {
    let mut files = Vec::new();
    for d in dirs {
        walk(&root.join(d), ext, &mut files);
    }
    let (mut defs, mut aliases) = (BTreeSet::new(), BTreeSet::new());
    for f in files {
        let Ok(text) = fs::read_to_string(&f) else {
            continue;
        };
        for line in text.lines() {
            if let Some((_, after)) = line.split_once("Design name:")
                && let Some(w) = words(after).next()
            {
                aliases.insert(w.to_owned());
            }
            let code = line.split("//").next().unwrap_or("");
            if free_only && code.starts_with(char::is_whitespace) {
                continue;
            }
            let ws: Vec<&str> = words(code).collect();
            for pair in ws.windows(2) {
                if keywords.contains(&pair[0]) {
                    defs.insert(pair[1].to_owned());
                }
            }
        }
    }
    (defs, aliases)
}

pub fn scan(root: &Path) -> Result<Vec<Row>, String> {
    let fams = read_snapshot(root)?;
    let map = read_map(root).unwrap_or_default();
    let (rust, rust_alias) = definitions(
        root,
        &RUST_DIRS,
        "rs",
        &["fn", "struct", "enum", "type", "trait"],
        true,
    );
    let (swift, _) = definitions(
        root,
        &SWIFT_DIRS,
        "swift",
        &["struct", "class", "enum", "protocol", "typealias", "func"],
        false,
    );
    let (kotlin, _) = definitions(
        root,
        &KOTLIN_DIRS,
        "kt",
        &["fun", "class", "object", "interface", "typealias"],
        false,
    );
    Ok(fams
        .iter()
        .map(|f| {
            let found = if rust.contains(&f.name) || rust.contains(&snake(&f.name)) {
                Found::Name
            } else if rust_alias.contains(&f.name) {
                Found::Alias
            } else {
                Found::Missing
            };
            Row {
                name: f.name.clone(),
                rust: found,
                swift: swift.contains(&f.name),
                kotlin: kotlin.contains(&f.name),
                mapped_rust: map.get(&f.name).cloned(),
            }
        })
        .collect())
}

fn isd_path(root: &Path, args: &[String]) -> Option<PathBuf> {
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if a == "--isd" {
            return it.next().map(PathBuf::from);
        }
    }
    std::env::var_os("SWIFTLY_ISD")
        .map(PathBuf::from)
        .or_else(|| Some(root.join("design/Swiftly Player.isd")))
        .filter(|p| p.is_file())
}

/// Problems that fail the check (empty = fine).
pub fn problems(root: &Path, rows: &[Row]) -> Result<Vec<String>, String> {
    let fams = read_snapshot(root)?;
    let map = read_map(root).map_err(|e| format!("{e} (write the map first)"))?;
    let mut bad = Vec::new();
    for f in &fams {
        if !map.contains_key(&f.name) {
            bad.push(format!(
                "{MAP} has no row for design component {} ({}); add it",
                f.name, f.section
            ));
        }
    }
    let known: BTreeSet<&str> = fams.iter().map(|f| f.name.as_str()).collect();
    for n in map.keys() {
        if !known.contains(n.as_str()) {
            bad.push(format!(
                "{MAP} lists {n}, which the design file no longer has; remove or rename the row"
            ));
        }
    }
    for r in rows {
        let claims = matches!(r.mapped_rust.as_deref(), Some("same" | "alias"));
        if claims && r.rust == Found::Missing {
            bad.push(format!(
                "{}: the map says the Rust UI has it, but no fn/type/`Design name:` is left",
                r.name
            ));
        }
    }
    Ok(bad)
}

/// The single line for `check-all`.
pub fn summary(root: &Path) -> (bool, String) {
    match scan(root).and_then(|rows| problems(root, &rows).map(|p| (rows, p))) {
        Ok((rows, bad)) => {
            let count = |f: &dyn Fn(&Row) -> bool| rows.iter().filter(|r| f(r)).count();
            let line = format!(
                "components: {} design names, Rust {} found/{} alias/{} missing (fails), Swift {}/{} and Kotlin {}/{} found (info){}",
                rows.len(),
                count(&|r| r.rust == Found::Name),
                count(&|r| r.rust == Found::Alias),
                count(&|r| r.rust == Found::Missing),
                count(&|r| r.swift),
                rows.len(),
                count(&|r| r.kotlin),
                rows.len(),
                bad.first()
                    .map(|b| format!("; FAIL: {b}"))
                    .unwrap_or_default()
            );
            (bad.is_empty(), line)
        }
        Err(e) => (false, format!("components: FAIL ({e})")),
    }
}

/// `components [--isd <file>] [--quiet]`
pub fn run(root: &Path, args: &[String]) -> Result<(), String> {
    let mut failures = Vec::new();
    match isd_path(root, args) {
        Some(isd) => {
            let out = Command::new("cargo")
                .current_dir(root)
                .args([
                    "run",
                    "-q",
                    "-p",
                    "swiftly-design",
                    "--bin",
                    "gen_tokens",
                    "--",
                    "--check",
                    "--isd",
                ])
                .arg(&isd)
                .output()
                .map_err(|e| format!("cargo: {e}"))?;
            let text = String::from_utf8_lossy(&out.stderr);
            if text.contains("components.tsv") {
                failures.push(format!(
                    "{SNAPSHOT} is out of date against {}; run gen_tokens --isd <file>",
                    isd.display()
                ));
            } else if !out.status.success() {
                failures.push(format!(
                    "gen_tokens --check failed: {}",
                    text.lines().last().unwrap_or("")
                ));
            } else {
                println!("design file: snapshot is current ({})", isd.display());
            }
        }
        None => println!("design file: not found (SWIFTLY_ISD or --isd), snapshot only"),
    }
    let rows = scan(root)?;
    let fams = read_snapshot(root)?;
    let quiet = args.iter().any(|a| a == "--quiet");
    for (f, r) in fams.iter().zip(&rows) {
        if quiet && r.rust != Found::Missing {
            continue;
        }
        println!(
            "{:<22} rust={:<7} swift={:<7} kotlin={:<7} map={:<8} [{}; {}; {} on screens]",
            f.name,
            r.rust.word(),
            if r.swift { "found" } else { "missing" },
            if r.kotlin { "found" } else { "missing" },
            r.mapped_rust.as_deref().unwrap_or("-"),
            f.platforms,
            f.section,
            f.instances
        );
        let _ = &f.variants;
    }
    failures.extend(problems(root, &rows)?);
    let (_, line) = summary(root);
    println!("{line}");
    if failures.is_empty() {
        Ok(())
    } else {
        Err(failures.join("\n"))
    }
}
