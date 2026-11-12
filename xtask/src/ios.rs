//! `cargo xtask apple-ui [ios|tvos]`: builds the `swiftly-ios` staticlib for the Apple device targets and the unsigned
//! comparison apps (`SwiftlyRust-iOS`, `SwiftlyRust-tvOS`, bundle id `de.paulherter.swiftly.rustui`) with xcodebuild.
//! `check-all` calls `build` for the iphone and appletv lines. Nothing is installed or launched here.

use std::path::{Path, PathBuf};
use std::process::Command;

/// What a build run produced, or why it could not run.
pub enum Built {
    /// The app bundle exists (path, size note).
    Ok(PathBuf, String),
    /// A tool is missing (text for "not run (needs ...)").
    Missing(String),
}

struct Slice {
    triple: &'static str,
    scheme: &'static str,
    sdk: &'static str,
    products: &'static str,
}

fn slice(which: &str) -> Option<Slice> {
    match which {
        "ios" => Some(Slice {
            triple: "aarch64-apple-ios",
            scheme: "SwiftlyRust-iOS",
            sdk: "generic/platform=iOS",
            products: "Release-iphoneos",
        }),
        "tvos" => Some(Slice {
            triple: "aarch64-apple-tvos",
            scheme: "SwiftlyRust-tvOS",
            sdk: "generic/platform=tvOS",
            products: "Release-appletvos",
        }),
        _ => None,
    }
}

fn tail(o: &std::process::Output) -> String {
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    );
    let lines: Vec<&str> = text
        .lines()
        .filter(|l| l.contains("error"))
        .take(15)
        .collect();
    if lines.is_empty() {
        text.lines().rev().take(15).collect::<Vec<_>>().join("\n")
    } else {
        lines.join("\n")
    }
}

/// Builds the staticlib (release) and the unsigned app for `which` (`ios` or `tvos`).
pub fn build(root: &Path, which: &str) -> Result<Built, String> {
    let Some(s) = slice(which) else {
        return Err(format!("unknown target {which} (ios or tvos)"));
    };
    for tool in ["xcodebuild", "xcodegen"] {
        if !Command::new(tool)
            .arg(if tool == "xcodegen" {
                "--version"
            } else {
                "-version"
            })
            .output()
            .is_ok_and(|o| o.status.success())
        {
            return Ok(Built::Missing(tool.to_owned()));
        }
    }
    let o = Command::new("cargo")
        .args([
            "build",
            "-q",
            "-p",
            "swiftly-ios",
            "--target",
            s.triple,
            "--release",
        ])
        .env("IPHONEOS_DEPLOYMENT_TARGET", "18.0")
        .env("TVOS_DEPLOYMENT_TARGET", "18.0")
        .current_dir(root)
        .output()
        .map_err(|e| format!("cargo: {e}"))?;
    if !o.status.success() {
        return Err(format!("cargo build ({}) failed:\n{}", s.triple, tail(&o)));
    }
    let o = Command::new("xcodegen")
        .arg("generate")
        .arg("-q")
        .current_dir(root)
        .output()
        .map_err(|e| format!("xcodegen: {e}"))?;
    if !o.status.success() {
        return Err(format!("xcodegen failed:\n{}", tail(&o)));
    }
    let o = Command::new("xcodebuild")
        .args([
            "-quiet",
            "-project",
            "Swiftly.xcodeproj",
            "-scheme",
            s.scheme,
        ])
        .args(["-configuration", "Release", "-destination", s.sdk])
        .args([
            "-derivedDataPath",
            "build/DD-rust",
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        ])
        .current_dir(root)
        .output()
        .map_err(|e| format!("xcodebuild: {e}"))?;
    if !o.status.success() {
        return Err(format!("xcodebuild {} failed:\n{}", s.scheme, tail(&o)));
    }
    let app = root
        .join("build/DD-rust/Build/Products")
        .join(s.products)
        .join("Swiftly Rust.app");
    let bin = std::fs::metadata(app.join("Swiftly Rust"))
        .map_err(|e| format!("no binary: {e}"))?
        .len();
    Ok(Built::Ok(
        app,
        format!("binary {:.1} MB", bin as f64 / 1_048_576.0),
    ))
}

/// The `apple-ui` command.
pub fn run(root: &Path, args: &[String]) -> Result<(), String> {
    let which: Vec<&str> = if args.is_empty() {
        vec!["ios", "tvos"]
    } else {
        args.iter().map(String::as_str).collect()
    };
    for w in which {
        match build(root, w)? {
            Built::Ok(app, size) => println!("xtask: {w}: {} ({size})", app.display()),
            Built::Missing(need) => return Err(format!("needs {need}")),
        }
    }
    Ok(())
}
