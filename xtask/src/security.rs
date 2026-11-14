//! `cargo xtask security`: the supply-chain and safety checks of the core, one line each, exit code 1 if any fails.
//!
//! * `audit`   cargo-audit: known vulnerabilities in `Cargo.lock` (RustSec).
//! * `deny`    cargo-deny: licences (GPL/AGPL out, MPL-2.0 in), bans, sources, duplicate versions (see `deny.toml`).
//! * `unsafe`  every `unsafe` stays in the audited FFI files; every crate inherits the workspace lints (`unsafe_code = forbid`).
//! * `tests`   the `swiftly-security` suite (planted-secret scans, parser limits, atomic writes, redaction) and the net checks.
//!
//! A missing tool (cargo-audit, cargo-deny) is reported as `MISSING` and fails the run: `cargo install --locked cargo-audit cargo-deny`.

use std::fs;
use std::path::Path;
use std::process::Command;

/// Files that may contain `unsafe`: each is a foreign-function boundary.
const UNSAFE_ALLOWED: &[&str] = &[
    "crates/swiftly-ios/src/",
    "crates/swiftly-android/src/",
    "crates/swiftly-player-surface/src/mpv.rs",
    // The Windows window shell: the class brush behind the window and the shell calls (each block is commented).
    "crates/swiftly-desktop/src/win_backdrop.rs",
    "crates/swiftly-desktop/src/win_shell.rs",
    // Single calls into the C library or the Windows API, each commented: the dark title bar, the local time of day,
    // the quit guard's `_exit` and the free-space query of the downloads.
    "crates/swiftly-desktop/src/win_dark.rs",
    "crates/swiftly-desktop/src/local_clock.rs",
    "crates/swiftly-desktop/src/quit_guard.rs",
    "crates/swiftly-desktop/src/live_downloads.rs",
    // The Wayland window icon over winit's own connection: two pointer handles, each commented.
    "crates/swiftly-desktop/src/toplevel_icon.rs",
];

struct Line {
    name: &'static str,
    ok: bool,
    detail: String,
}

pub fn run(root: &Path, _args: &[String]) -> Result<(), String> {
    let lines = [
        audit(root),
        deny(root),
        unsafe_scan(root),
        lints(root),
        tests(root),
    ];
    for l in &lines {
        println!(
            "{:<8} {:<6} {}",
            l.name,
            if l.ok { "ok" } else { "FAILED" },
            l.detail
        );
    }
    if lines.iter().all(|l| l.ok) {
        Ok(())
    } else {
        Err("a security check failed".into())
    }
}

/// One line for `check-all`.
pub fn column(root: &Path) -> (bool, String) {
    let lines = [audit(root), deny(root), unsafe_scan(root), lints(root)];
    let ok = lines.iter().all(|l| l.ok);
    let parts: Vec<String> = lines
        .iter()
        .map(|l| format!("{} {}", l.name, if l.ok { "ok" } else { "FAILED" }))
        .collect();
    (ok, format!("security: {}", parts.join(", ")))
}

fn last_lines(text: &str, n: usize) -> String {
    let v: Vec<&str> = text.lines().collect();
    v[v.len().saturating_sub(n)..].join(" | ")
}

fn tool(root: &Path, name: &'static str, args: &[&str], ok_text: &str) -> Line {
    match Command::new("cargo").args(args).current_dir(root).output() {
        Ok(o) if o.status.success() => Line {
            name,
            ok: true,
            detail: ok_text.into(),
        },
        Ok(o) => {
            let text = format!(
                "{}{}",
                String::from_utf8_lossy(&o.stdout),
                String::from_utf8_lossy(&o.stderr)
            );
            if text.contains("no such command") || text.contains("no such subcommand") {
                Line {
                    name,
                    ok: false,
                    detail: format!("MISSING: cargo install --locked cargo-{name}"),
                }
            } else {
                Line {
                    name,
                    ok: false,
                    detail: last_lines(&text, 6),
                }
            }
        }
        Err(e) => Line {
            name,
            ok: false,
            detail: format!("cargo: {e}"),
        },
    }
}

fn audit(root: &Path) -> Line {
    tool(
        root,
        "audit",
        &["audit", "--deny", "warnings", "--quiet"],
        "no known vulnerabilities, no unmaintained or yanked crates",
    )
}

fn deny(root: &Path) -> Line {
    tool(
        root,
        "deny",
        &[
            "deny",
            "--log-level",
            "error",
            "check",
            "licenses",
            "bans",
            "sources",
            "advisories",
        ],
        "licences, bans, sources, advisories",
    )
}

fn rust_files(dir: &Path, out: &mut Vec<std::path::PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
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

/// True if a line of source uses the `unsafe` keyword in code (not in a comment, string or identifier).
fn has_unsafe(line: &str) -> bool {
    // Drop string literals first (a literal may hold `//` or the word), then the comment.
    let mut code = String::new();
    let mut chars = line.chars().peekable();
    let mut in_string = false;
    while let Some(c) = chars.next() {
        if in_string {
            match c {
                '\\' => {
                    chars.next();
                }
                '"' => in_string = false,
                _ => {}
            }
        } else if c == '"' {
            in_string = true;
        } else if c == '/' && chars.peek() == Some(&'/') {
            break;
        } else {
            code.push(c);
        }
    }
    code.split(|c: char| !(c.is_alphanumeric() || c == '_'))
        .any(|w| w == "unsafe")
}

fn unsafe_scan(root: &Path) -> Line {
    let mut files = vec![];
    rust_files(&root.join("crates"), &mut files);
    rust_files(&root.join("xtask"), &mut files);
    let mut bad = vec![];
    let mut total = 0usize;
    for f in files {
        let rel = f
            .strip_prefix(root)
            .unwrap_or(&f)
            .to_string_lossy()
            .replace('\\', "/");
        let text = fs::read_to_string(&f).unwrap_or_default();
        let count = text.lines().filter(|l| has_unsafe(l)).count();
        total += count;
        if count > 0 && !UNSAFE_ALLOWED.iter().any(|a| rel.starts_with(a)) {
            bad.push(format!("{rel} ({count})"));
        }
    }
    if bad.is_empty() {
        Line {
            name: "unsafe",
            ok: true,
            detail: format!("{total} uses, all in the audited FFI files"),
        }
    } else {
        Line {
            name: "unsafe",
            ok: false,
            detail: format!("unsafe outside the allow list: {}", bad.join(", ")),
        }
    }
}

fn lints(root: &Path) -> Line {
    let mut missing = vec![];
    if let Ok(entries) = fs::read_dir(root.join("crates")) {
        for e in entries.flatten() {
            let manifest = e.path().join("Cargo.toml");
            let Ok(text) = fs::read_to_string(&manifest) else {
                continue;
            };
            let inherits = text.split("[lints]").nth(1).is_some_and(|rest| {
                rest.lines()
                    .take(3)
                    .any(|l| l.replace(' ', "") == "workspace=true")
            });
            // The FFI crates (and the desktop app, for its Windows and libc files) cannot forbid `unsafe` (see UNSAFE_ALLOWED); they deny it per file and carry the same
            // clippy set themselves.
            let own = [
                "swiftly-android",
                "swiftly-ios",
                "swiftly-player-surface",
                "swiftly-desktop",
            ]
            .contains(&e.file_name().to_string_lossy().as_ref())
                && text.contains("unsafe_code = \"deny\"")
                && ["unwrap_used", "expect_used", "await_holding_lock"]
                    .iter()
                    .all(|l| text.contains(&format!("{l} = \"deny\"")));
            if !inherits && !own {
                missing.push(e.file_name().to_string_lossy().into_owned());
            }
        }
    }
    if missing.is_empty() {
        Line { name: "lints", ok: true, detail: "every crate inherits the workspace lints (unsafe forbidden, unwrap/expect denied); the 4 FFI crates deny the same themselves".into() }
    } else {
        missing.sort();
        Line {
            name: "lints",
            ok: false,
            detail: format!("no [lints] workspace = true in: {}", missing.join(", ")),
        }
    }
}

fn tests(root: &Path) -> Line {
    let o = Command::new("cargo")
        .args(["test", "-q", "-p", "swiftly-security", "-p", "swiftly-net"])
        .current_dir(root)
        .output();
    match o {
        Ok(o) if o.status.success() => Line {
            name: "tests",
            ok: true,
            detail: "swiftly-security, swiftly-net".into(),
        },
        Ok(o) => Line {
            name: "tests",
            ok: false,
            detail: last_lines(&String::from_utf8_lossy(&o.stdout), 8),
        },
        Err(e) => Line {
            name: "tests",
            ok: false,
            detail: format!("cargo: {e}"),
        },
    }
}
