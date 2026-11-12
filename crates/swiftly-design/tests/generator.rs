//! Runs the generator binary against the design file. Skips with a message when the file is absent.

// Test helpers may panic on a broken fixture.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::path::PathBuf;
use std::process::Command;

fn isd_path() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("SWIFTLY_ISD") {
        let p = PathBuf::from(p);
        return p.exists().then_some(p);
    }
    let p =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../App/design/Swiftly Player.isd");
    p.exists().then_some(p)
}

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_gen_tokens"))
}

#[test]
fn committed_files_are_up_to_date() {
    let Some(isd) = isd_path() else {
        eprintln!("skipped: design file not found (set SWIFTLY_ISD)");
        return;
    };
    let out = bin()
        .arg("--check")
        .arg("--isd")
        .arg(&isd)
        .output()
        .expect("run gen_tokens");
    assert!(
        out.status.success(),
        "tokens are out of date:\n{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn output_is_deterministic() {
    let Some(isd) = isd_path() else {
        eprintln!("skipped: design file not found (set SWIFTLY_ISD)");
        return;
    };
    let dir = std::env::temp_dir().join(format!("swiftly-design-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let run = |name: &str| {
        let rs = dir.join(name).join("tokens.rs");
        let swift = dir.join(name).join("Tokens.swift");
        let st = bin()
            .arg("--isd")
            .arg(&isd)
            .arg("--out-rs")
            .arg(&rs)
            .arg("--out-swift")
            .arg(&swift)
            .status()
            .expect("run gen_tokens");
        assert!(st.success());
        (
            std::fs::read(rs).expect("rs"),
            std::fs::read(swift).expect("swift"),
        )
    };
    let (a, b) = (run("a"), run("b"));
    assert_eq!(a, b);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn check_fails_when_a_file_differs() {
    let Some(isd) = isd_path() else {
        eprintln!("skipped: design file not found (set SWIFTLY_ISD)");
        return;
    };
    let dir = std::env::temp_dir().join(format!("swiftly-design-drift-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("mkdir");
    let rs = dir.join("tokens.rs");
    let swift = dir.join("Tokens.swift");
    std::fs::write(&rs, "// stale\n").expect("write");
    std::fs::write(&swift, "// stale\n").expect("write");
    let st = bin()
        .args(["--check", "--isd"])
        .arg(&isd)
        .arg("--out-rs")
        .arg(&rs)
        .arg("--out-swift")
        .arg(&swift)
        .output()
        .expect("run");
    assert_eq!(st.status.code(), Some(1));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn rejects_a_file_that_is_not_a_zip() {
    let dir = std::env::temp_dir().join(format!("swiftly-design-bad-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("mkdir");
    let bad = dir.join("bad.isd");
    std::fs::write(&bad, "not a zip").expect("write");
    let st = bin()
        .arg("--check")
        .arg("--isd")
        .arg(&bad)
        .output()
        .expect("run");
    assert_eq!(st.status.code(), Some(2));
    let _ = std::fs::remove_dir_all(&dir);
}
