//! The desktop app's version (Settings, update check, crash log) is the one the Apple apps ship: `MARKETING_VERSION` in
//! `project.yml`, which `Werkzeuge/package-desktop.sh` also reads for the packages. A snapshot without `project.yml` skips.

#[test]
fn the_desktop_version_is_the_marketing_version() {
    let project = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../project.yml");
    let Ok(text) = std::fs::read_to_string(&project) else {
        println!("skipped: no project.yml here");
        return;
    };
    let marketing = text
        .lines()
        .find_map(|l| l.trim().strip_prefix("MARKETING_VERSION:"))
        .map(|v| v.trim().trim_matches('"').to_owned())
        .expect("MARKETING_VERSION in project.yml");
    assert_eq!(
        env!("CARGO_PKG_VERSION"),
        marketing,
        "bump crates/swiftly-desktop/Cargo.toml (and Cargo.lock) with project.yml"
    );
}

/// The Settings row of a build made from this tree names the Apple apps' build number (`CURRENT_PROJECT_VERSION`), never a
/// placeholder; `Werkzeuge/package-desktop.sh` checks the same row inside the packaged binaries.
#[test]
fn the_settings_row_names_the_apple_build_number() {
    let project = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../project.yml");
    let Ok(text) = std::fs::read_to_string(&project) else {
        println!("skipped: no project.yml here");
        return;
    };
    let value_of = |key: &str| {
        text.lines()
            .find_map(|l| l.trim().strip_prefix(key))
            .map(|v| v.trim().trim_matches('"').to_owned())
            .unwrap_or_else(|| panic!("{key} in project.yml"))
    };
    let (marketing, build) = (
        value_of("MARKETING_VERSION:"),
        value_of("CURRENT_PROJECT_VERSION:"),
    );
    if let Ok(forced) = std::env::var("SWIFTLY_BUILD_NUMBER") {
        // A package build sets it from the same file; any other value would be a second source of truth.
        assert_eq!(
            forced, build,
            "SWIFTLY_BUILD_NUMBER differs from project.yml"
        );
    }
    assert_eq!(
        swiftly_desktop::build_info::BUILD,
        Some(build.as_str()),
        "the build did not pick up CURRENT_PROJECT_VERSION"
    );
    assert_eq!(
        swiftly_desktop::build_info::version_row(),
        format!("Swiftly Player {marketing} (Build {build})")
    );
    assert_eq!(
        swiftly_desktop::build_info::build_number(),
        build.parse::<i64>().unwrap()
    );
}
