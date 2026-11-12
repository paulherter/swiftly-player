//! `cargo xtask hardening [--quick] [--regen-oracle] [--perf] [--soak-secs N] [--iters N] [suite ...]`
//!
//! One command for the machine hardening pass. One line per suite,
//! non-zero exit when a suite fails. Suites are the `crates/swiftly-hardening/tests/<suite>_*.rs`
//! files grouped by prefix:
//!
//! * `oracle`  Swift-vs-Rust differential tests (inputs and Swift outputs are recorded under
//!   `crates/swiftly-hardening/oracle/`; `--regen-oracle` rebuilds both with Xcode's Swift first)
//! * `props`   seeded state-machine and property tests (`HARDENING_ITERS`)
//! * `fuzz`    parser mutation fuzzing (`HARDENING_ITERS`)
//! * `soak`    long run against the fixture server, task/memory/lock watchdog (`HARDENING_SOAK_SECS`)
//! * `lint`    `clippy -D warnings` on the harness crate
//! * `perf`    only with `--perf`: Rust vs Swift benchmarks into a markdown baseline file
//!
//! The result is cached in `target/hardening/last.txt` for the extra column of `check-all`.

use std::fs;
use std::path::Path;
use std::process::Command;
use std::time::Instant;

const CRATE: &str = "swiftly-hardening";
const SUITES: [&str; 4] = ["oracle", "props", "fuzz", "soak"];

pub struct Line {
    pub suite: String,
    pub ok: bool,
    pub detail: String,
}

fn xcode_swift() -> Option<(String, String)> {
    let dev = std::env::var("DEVELOPER_DIR")
        .unwrap_or_else(|_| "/Applications/Xcode.app/Contents/Developer".to_owned());
    let swift = format!("{dev}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift");
    let sdk = format!("{dev}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk");
    (Path::new(&swift).exists() && Path::new(&sdk).exists()).then_some((swift, sdk))
}

fn tail(text: &str, n: usize) -> String {
    let lines: Vec<&str> = text.lines().rev().take(n).collect();
    lines.into_iter().rev().collect::<Vec<_>>().join("\n")
}

/// Test files of the suite: `tests/<suite>*.rs`, as cargo `--test` names.
fn test_files(root: &Path, suite: &str) -> Vec<String> {
    let dir = root.join("crates").join(CRATE).join("tests");
    let mut names: Vec<String> = fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            let stem = name.strip_suffix(".rs")?.to_owned();
            stem.starts_with(suite).then_some(stem)
        })
        .collect();
    names.sort();
    names
}

fn regen_oracle(root: &Path) -> Result<(), String> {
    let status = Command::new("cargo")
        .args(["run", "-q", "-p", CRATE, "--bin", "oracle_inputs"])
        .current_dir(root)
        .status()
        .map_err(|e| format!("cargo: {e}"))?;
    if !status.success() {
        return Err("oracle_inputs failed".into());
    }
    let (swift, sdk) = xcode_swift().ok_or("Xcode's swift not found (set DEVELOPER_DIR)")?;
    let scratch = std::env::temp_dir().join("swiftly-oracle-build");
    let out = Command::new(swift)
        .args(["run", "-q", "--scratch-path"])
        .arg(&scratch)
        .args(["oracle", "../../crates/swiftly-hardening/oracle"])
        .current_dir(root.join("Tools/Oracle"))
        .env("SDKROOT", sdk)
        .output()
        .map_err(|e| format!("swift: {e}"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(tail(
            &format!(
                "{}{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            ),
            12,
        ))
    }
}

/// Run `cargo test` for the given test files with the environment; returns (passed tests, text).
fn run_tests(root: &Path, files: &[String], env: &[(&str, String)]) -> (bool, usize, String) {
    let mut args = vec!["test".to_owned(), "-p".into(), CRATE.into()];
    for f in files {
        args.push("--test".into());
        args.push(f.clone());
    }
    args.push("--".into());
    args.push("--test-threads=4".into());
    let mut cmd = Command::new("cargo");
    cmd.args(&args).current_dir(root);
    for (k, v) in env {
        cmd.env(k, v);
    }
    match cmd.output() {
        Ok(o) => {
            let text = format!(
                "{}{}",
                String::from_utf8_lossy(&o.stdout),
                String::from_utf8_lossy(&o.stderr)
            );
            let passed = text
                .lines()
                .filter_map(|l| l.strip_prefix("test result: ok. "))
                .filter_map(|l| l.split_whitespace().next()?.parse::<usize>().ok())
                .sum();
            (o.status.success(), passed, text)
        }
        Err(e) => (false, 0, format!("cargo: {e}")),
    }
}

pub fn run(root: &Path, args: &[String]) -> Result<(), String> {
    let mut quick = false;
    let mut regen = false;
    let mut perf = false;
    let mut soak_secs: Option<String> = None;
    let mut iters: Option<String> = None;
    let mut only: Vec<String> = vec![];
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--quick" => quick = true,
            "--regen-oracle" => regen = true,
            "--perf" => perf = true,
            "--soak-secs" => soak_secs = it.next().cloned(),
            "--iters" => iters = it.next().cloned(),
            s if SUITES.contains(&s) || s == "lint" => only.push(s.to_owned()),
            other => return Err(format!("unknown option {other}")),
        }
    }
    let env = vec![
        (
            "HARDENING_ITERS",
            iters.unwrap_or_else(|| if quick { "200" } else { "20000" }.to_owned()),
        ),
        (
            "HARDENING_SOAK_SECS",
            soak_secs.unwrap_or_else(|| if quick { "5" } else { "120" }.to_owned()),
        ),
    ];
    let _ = fs::create_dir_all(root.join("target/hardening"));
    let mut lines: Vec<Line> = vec![];
    if regen {
        let t = Instant::now();
        let (ok, detail) = match regen_oracle(root) {
            Ok(()) => (
                true,
                format!(
                    "inputs + real Swift outputs rebuilt ({:.0}s)",
                    t.elapsed().as_secs_f64()
                ),
            ),
            Err(e) => (false, e),
        };
        lines.push(Line {
            suite: "regen".into(),
            ok,
            detail,
        });
    }
    let wanted = |s: &str| only.is_empty() || only.iter().any(|o| o == s);
    for suite in SUITES {
        if !wanted(suite) {
            continue;
        }
        let files = test_files(root, suite);
        if files.is_empty() {
            lines.push(Line {
                suite: suite.into(),
                ok: true,
                detail: "no tests yet".into(),
            });
            continue;
        }
        eprintln!("xtask: hardening {suite} ...");
        let t = Instant::now();
        let (ok, passed, text) = run_tests(root, &files, &env);
        if !ok {
            eprintln!("--- {suite} failed, last lines ---\n{}", tail(&text, 40));
        }
        lines.push(Line {
            suite: suite.into(),
            ok,
            detail: format!(
                "{passed} tests in {} file(s), {:.1}s",
                files.len(),
                t.elapsed().as_secs_f64()
            ),
        });
    }
    if wanted("lint") {
        eprintln!("xtask: hardening lint ...");
        let o = Command::new("cargo")
            .args([
                "clippy",
                "-q",
                "-p",
                CRATE,
                "--all-targets",
                "--",
                "-D",
                "warnings",
            ])
            .current_dir(root)
            .output()
            .map_err(|e| format!("cargo: {e}"))?;
        let ok = o.status.success();
        if !ok {
            eprintln!(
                "--- lint failed ---\n{}",
                tail(&String::from_utf8_lossy(&o.stderr), 40)
            );
        }
        lines.push(Line {
            suite: "lint".into(),
            ok,
            detail: "clippy -D warnings".into(),
        });
    }
    if perf {
        eprintln!("xtask: hardening perf ...");
        let o = Command::new("cargo")
            .args([
                "run",
                "-q",
                "--release",
                "-p",
                CRATE,
                "--bin",
                "perf",
                "--",
                "--write",
            ])
            .current_dir(root)
            .output()
            .map_err(|e| format!("cargo: {e}"))?;
        let ok = o.status.success();
        if !ok {
            eprintln!(
                "--- perf failed ---\n{}",
                tail(&String::from_utf8_lossy(&o.stderr), 30)
            );
        }
        lines.push(Line {
            suite: "perf".into(),
            ok,
            detail: "perf baseline written".into(),
        });
    }
    let mut summary = String::new();
    for l in &lines {
        let row = format!(
            "{:<8} {:<6} {}",
            l.suite,
            if l.ok { "ok" } else { "FAILED" },
            l.detail
        );
        println!("{row}");
        summary.push_str(&row);
        summary.push('\n');
    }
    let all_ok = lines.iter().all(|l| l.ok);
    let _ = fs::write(
        root.join("target/hardening/last.txt"),
        format!("{}\n{summary}", if all_ok { "ok" } else { "FAILED" }),
    );
    if all_ok {
        Ok(())
    } else {
        Err("a hardening suite failed".into())
    }
}

/// Extra column for `check-all`: the oracle and the fast property run once (quick mode), so the column is
/// always fresh and cheap; the long run is `cargo xtask hardening`.
pub fn column(root: &Path) -> (bool, String) {
    let mut parts = vec![];
    let mut ok_all = true;
    for suite in ["oracle", "props", "fuzz"] {
        let files = test_files(root, suite);
        if files.is_empty() {
            continue;
        }
        let (ok, passed, _) = run_tests(root, &files, &[("HARDENING_ITERS", "100".into())]);
        ok_all &= ok;
        parts.push(format!(
            "{suite} {}",
            if ok {
                format!("ok ({passed})")
            } else {
                "FAILED".into()
            }
        ));
    }
    let last = fs::read_to_string(root.join("target/hardening/last.txt"))
        .ok()
        .and_then(|t| t.lines().next().map(str::to_owned))
        .unwrap_or_else(|| "not run".into());
    parts.push(format!("long run: {last}"));
    (ok_all, format!("hardening: {}", parts.join(", ")))
}
