//! Every async export must return `Result<_, CoreError>`: the generated Swift then reads
//! `try await`, so a cancelled `Task` throws `CancellationError` instead of trapping in `try!`.
//! The xtask patch refuses to build the bindings otherwise; this finds the offender earlier.
#![allow(clippy::expect_used)]

use std::fs;
use std::path::{Path, PathBuf};

fn sources(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in fs::read_dir(dir).expect("read src dir") {
        let path = entry.expect("dir entry").path();
        if path.is_dir() {
            sources(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

/// The return type of the signature that starts at `from` (text from `async fn` on).
fn return_type(from: &str) -> String {
    let mut depth = 0_i32;
    let mut end = from.len();
    for (at, c) in from.char_indices() {
        match c {
            '(' | '<' | '[' => depth += 1,
            ')' | ']' => depth -= 1,
            '>' if !from[..at].ends_with('-') => depth -= 1,
            '{' | ';' if depth <= 0 => {
                end = at;
                break;
            }
            _ => {}
        }
    }
    let signature = &from[..end];
    // The `->` after the parameter list's closing parenthesis.
    let mut depth = 0_i32;
    for (at, c) in signature.char_indices() {
        match c {
            '(' => depth += 1,
            ')' => depth -= 1,
            '-' if depth == 0 && signature[at..].starts_with("->") => {
                return signature[at + 2..]
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ");
            }
            _ => {}
        }
    }
    String::new()
}

#[test]
fn every_async_export_returns_a_result_with_core_error() {
    let mut files = Vec::new();
    sources(
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("src"),
        &mut files,
    );
    let mut offenders = Vec::new();
    for file in files {
        // The Android-only objects (`TakeoverCalls`) answer plain JSON strings and are never called from Swift (the
        // xtask Swift patch exempts them by class name too); everything else must return a Result.
        if file.file_name().is_some_and(|n| n == "takeover_calls.rs") {
            continue;
        }
        let text = fs::read_to_string(&file).expect("read source");
        let lines: Vec<&str> = text.lines().collect();
        // Inside a `#[uniffi::export] impl` block every fn is exported, `pub` or not.
        let mut in_export_impl = false;
        let mut export_pending = false;
        // `Legacy*` objects are Android-only (Kotlin), like `TakeoverCalls`; the xtask Swift patch exempts them by name too.
        let mut legacy_owner = false;
        for (n, line) in lines.iter().enumerate() {
            if line.starts_with("impl") {
                legacy_owner = line.starts_with("impl Legacy");
            }
            if line.starts_with("#[uniffi::export") {
                export_pending = true;
            } else if line.starts_with("impl")
                || line.starts_with("pub fn")
                || line.starts_with("fn")
                || line.starts_with("pub async")
                || line.starts_with("async")
                || line.starts_with("pub struct")
                || line.starts_with("pub trait")
                || line.starts_with("trait")
            {
                in_export_impl = export_pending && line.starts_with("impl");
                export_pending = false;
            }
            if in_export_impl && *line == "}" {
                in_export_impl = false;
            }
            if !line.trim_start().starts_with("pub async fn ")
                && !line.trim_start().starts_with("async fn ")
            {
                continue;
            }
            // Exported when an attribute block right above (doc lines skipped) names uniffi.
            let exported = in_export_impl
                || lines[..n]
                    .iter()
                    .rev()
                    .take_while(|l| {
                        let t = l.trim_start();
                        t.starts_with("#[") || t.starts_with("///") || t.starts_with("//")
                    })
                    .any(|l| l.contains("uniffi::export") || l.contains("uniffi::method"));
            if !exported || legacy_owner {
                continue;
            }
            let rest = lines[n..].join("\n");
            let ret = return_type(&rest);
            if !(ret.starts_with("Result<") && ret.contains("CoreError")) {
                offenders.push(format!(
                    "{}:{}: -> {}",
                    file.display(),
                    n + 1,
                    if ret.is_empty() { "()" } else { &ret }
                ));
            }
        }
    }
    assert!(
        offenders.is_empty(),
        "async exports must return Result<_, CoreError> (a cancelled Task must not trap):\n{}",
        offenders.join("\n")
    );
}
