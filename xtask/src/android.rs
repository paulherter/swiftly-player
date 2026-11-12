//! `cargo xtask android [--release]`: builds `swiftly-android` for arm64-v8a and x86_64 with `cargo ndk` and packages
//! the two `.so` files into the debug APK of `Android/rust-shell` with Gradle. `check-all` calls `build` for the
//! android-phone and android-tv lines.

use std::path::{Path, PathBuf};
use std::process::Command;

/// What a build run produced, or why it could not run.
pub enum Built {
    /// The APK exists.
    Ok(PathBuf),
    /// A tool is missing (text for "not run (needs ...)").
    Missing(String),
}

fn env_paths() -> Result<(String, String, String), String> {
    let home = std::env::var("HOME").map_err(|_| "HOME".to_owned())?;
    let sdk =
        std::env::var("ANDROID_HOME").unwrap_or_else(|_| format!("{home}/Library/Android/sdk"));
    let ndk = std::fs::read_dir(format!("{sdk}/ndk"))
        .ok()
        .and_then(|d| {
            let mut v: Vec<_> = d
                .filter_map(|e| e.ok())
                .map(|e| e.path())
                .filter(|p| p.to_string_lossy().contains("/27."))
                .collect();
            v.sort();
            v.pop()
        })
        .map(|p| p.to_string_lossy().into_owned())
        .ok_or_else(|| "the Android NDK 27 under the SDK".to_owned())?;
    let java = std::env::var("JAVA_HOME")
        .ok()
        .filter(|j| Path::new(j).join("bin/java").exists())
        .or_else(|| {
            let out = Command::new("/usr/libexec/java_home")
                .args(["-v", "21"])
                .output()
                .ok()?;
            out.status
                .success()
                .then(|| String::from_utf8_lossy(&out.stdout).trim().to_owned())
        });
    Ok((sdk, ndk, java.ok_or_else(|| "JDK 21".to_owned())?))
}

fn tool_ok(name: &str, args: &[&str]) -> bool {
    Command::new(name)
        .args(args)
        .output()
        .is_ok_and(|o| o.status.success())
}

fn tail(o: &std::process::Output) -> String {
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    );
    let lines: Vec<&str> = text.lines().rev().take(25).collect();
    lines.into_iter().rev().collect::<Vec<_>>().join("\n")
}

/// Builds both ABIs and the debug APK. `Err` is a failed build; `Built::Missing` is a machine without the tools.
pub fn build(root: &Path, release: bool) -> Result<Built, String> {
    let (sdk, ndk, java) = match env_paths() {
        Ok(p) => p,
        Err(need) => return Ok(Built::Missing(need)),
    };
    if !tool_ok("cargo", &["ndk", "--version"]) {
        return Ok(Built::Missing("cargo-ndk".to_owned()));
    }
    let targets = tool_ok("rustup", &["target", "list", "--installed"]) && {
        let o = Command::new("rustup")
            .args(["target", "list", "--installed"])
            .output()
            .map_err(|e| e.to_string())?;
        let t = String::from_utf8_lossy(&o.stdout).into_owned();
        t.contains("aarch64-linux-android") && t.contains("x86_64-linux-android")
    };
    if !targets {
        return Ok(Built::Missing(
            "rustup targets aarch64-linux-android and x86_64-linux-android".to_owned(),
        ));
    }
    let shell = root.join("Android/rust-shell");
    let jni = shell.join("app/src/main/jniLibs");
    let mut ndk_cmd = Command::new("cargo");
    ndk_cmd
        .args(["ndk", "-t", "arm64-v8a", "-t", "x86_64", "-o"])
        .arg(&jni)
        .args(["build", "-p", "swiftly-android"])
        .env("ANDROID_NDK_HOME", &ndk)
        .env("ANDROID_HOME", &sdk)
        .current_dir(root);
    if release {
        ndk_cmd.arg("--release");
    }
    let o = ndk_cmd.output().map_err(|e| format!("cargo ndk: {e}"))?;
    if !o.status.success() {
        return Err(format!("cargo ndk failed:\n{}", tail(&o)));
    }
    let o = Command::new("./gradlew")
        .args(["-q", "assembleDebug"])
        .env("JAVA_HOME", &java)
        .env("ANDROID_HOME", &sdk)
        .env("ANDROID_SDK_ROOT", &sdk)
        .current_dir(&shell)
        .output()
        .map_err(|e| format!("gradlew: {e}"))?;
    if !o.status.success() {
        return Err(format!("gradle failed:\n{}", tail(&o)));
    }
    Ok(Built::Ok(
        shell.join("app/build/outputs/apk/debug/app-debug.apk"),
    ))
}

/// The `android` command.
pub fn run(root: &Path, args: &[String]) -> Result<(), String> {
    let release = args.iter().any(|a| a == "--release");
    match build(root, release)? {
        Built::Ok(apk) => {
            println!("xtask: APK {}", apk.display());
            Ok(())
        }
        Built::Missing(need) => Err(format!("needs {need}")),
    }
}
