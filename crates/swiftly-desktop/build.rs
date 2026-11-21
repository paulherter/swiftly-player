//! Build number and Windows resource of the desktop app.
//!
//! * The build number is the one the Apple apps ship (`CURRENT_PROJECT_VERSION` in `project.yml`), read here once and
//!   handed to the crate as `SWIFTLY_BUILD_NUMBER` (`build_info.rs`). `SWIFTLY_BUILD_NUMBER` in the environment wins
//!   (the packaging script sets it); a source tree without `project.yml` and without the variable has no build number.
//!   The Settings row (`SWIFTLY_VERSION_ROW`) is composed here too, as one literal that ends up in the binary.
//! * Windows target (native or cross-compiled): embeds the program icon and the version details ("Swiftly Player") into
//!   the exe. The decision uses the target, not the build host, so `cargo xwin build` from Linux gets the icon too.
#![allow(clippy::unwrap_used)] // a build script: failing to embed the icon must stop the build

/// The first `CURRENT_PROJECT_VERSION:` of `project.yml`, digits only.
fn build_from_project() -> Option<String> {
    let text = std::fs::read_to_string("../../project.yml").ok()?;
    text.lines()
        .find_map(|l| l.trim().strip_prefix("CURRENT_PROJECT_VERSION:"))
        .map(|v| v.trim().trim_matches('"').to_owned())
        .filter(|v| !v.is_empty() && v.bytes().all(|b| b.is_ascii_digit()))
}

fn main() {
    println!("cargo:rerun-if-changed=assets/swiftly-player.rc");
    println!("cargo:rerun-if-changed=assets/swiftly-player.ico");
    println!("cargo:rerun-if-changed=../../project.yml");
    println!("cargo:rerun-if-env-changed=SWIFTLY_BUILD_NUMBER");
    let build = std::env::var("SWIFTLY_BUILD_NUMBER")
        .ok()
        .filter(|v| !v.is_empty() && v.bytes().all(|b| b.is_ascii_digit()))
        .or_else(build_from_project);
    let version = std::env::var("CARGO_PKG_VERSION").unwrap_or_default();
    if let Some(build) = &build {
        println!("cargo:rustc-env=SWIFTLY_BUILD_NUMBER={build}");
    }
    // The Settings row as one finished text, so it sits in the binary as a literal (`build_info.rs`): the packaging
    // script greps for it, and a row composed at run time would never be found there.
    let row = match &build {
        Some(b) => format!("Swiftly Player {version} (Build {b})"),
        None => format!("Swiftly Player {version}"),
    };
    println!("cargo:rustc-env=SWIFTLY_VERSION_ROW={row}");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        // The exe's file and product version: major.minor.patch.build, from the crate version and the build number.
        let mut parts = version
            .split('.')
            .map(|p| p.parse::<u32>().unwrap_or(0))
            .chain(std::iter::repeat(0));
        let (major, minor, patch) = (
            parts.next().unwrap(),
            parts.next().unwrap(),
            parts.next().unwrap(),
        );
        let build_part: u32 = build.as_deref().and_then(|b| b.parse().ok()).unwrap_or(0);
        let text = match &build {
            Some(b) => format!("{version}.{b}"),
            None => version.clone(),
        };
        let out = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap());
        let rc = std::fs::read_to_string("assets/swiftly-player.rc")
            .unwrap()
            .replace(
                "@VER_NUMBERS@",
                &format!("{major},{minor},{patch},{build_part}"),
            )
            .replace("@VER_TEXT@", &format!("\"{text}\""));
        std::fs::write(out.join("swiftly-player.rc"), rc).unwrap();
        std::fs::copy("assets/swiftly-player.ico", out.join("swiftly-player.ico")).unwrap();
        embed_resource::compile(out.join("swiftly-player.rc"), embed_resource::NONE)
            .manifest_optional()
            .unwrap();
    }
}
