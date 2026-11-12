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
