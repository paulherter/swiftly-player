//! Which build of the app this is: the version (`MARKETING_VERSION`, the crate version) and the build number
//! (`CURRENT_PROJECT_VERSION`) the Apple apps ship, read by `build.rs` from `project.yml` or from `SWIFTLY_BUILD_NUMBER`.
//! The Settings row, the update check and the Windows file version all take it from here, so none of them keeps its own
//! copy of the number.

/// The app's version, "1.1.0".
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// The build number as text, `None` in a tree built without `project.yml` and without `SWIFTLY_BUILD_NUMBER`.
pub const BUILD: Option<&str> = option_env!("SWIFTLY_BUILD_NUMBER");

/// The build number, 0 when unknown (the update check then treats any named build as newer).
pub fn build_number() -> i64 {
    BUILD.and_then(|b| b.parse().ok()).unwrap_or(0)
}

/// The Settings row of the Mac (`Version.row`): "Swiftly Player 1.1.0 (Build 49)". Without a build number the bracket is
/// left out instead of showing a made-up one.
pub fn version_row_for(version: &str, build: Option<&str>) -> String {
    match build.filter(|b| !b.is_empty()) {
        Some(build) => format!("Swiftly Player {version} (Build {build})"),
        None => format!("Swiftly Player {version}"),
    }
}

/// The row of this build as `build.rs` composed it: a literal in the binary, which `Werkzeuge/package-desktop.sh`
/// finds with `grep` to prove that the packaged app shows the version and build number of `project.yml`.
const ROW: &str = env!("SWIFTLY_VERSION_ROW");

/// The row for this build.
pub fn version_row() -> String {
    ROW.to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_row_names_the_build_when_there_is_one() {
        assert_eq!(
            version_row_for("1.1.0", Some("49")),
            "Swiftly Player 1.1.0 (Build 49)"
        );
    }

    /// `build.rs` and `version_row_for` compose the same text, so the literal in the binary is what Settings shows.
    #[test]
    fn the_baked_row_is_the_composed_row() {
        assert_eq!(version_row(), version_row_for(VERSION, BUILD));
    }

    #[test]
    fn the_row_has_no_made_up_build_without_one() {
        assert_eq!(version_row_for("1.1.0", None), "Swiftly Player 1.1.0");
        assert_eq!(version_row_for("1.1.0", Some("")), "Swiftly Player 1.1.0");
    }
}
