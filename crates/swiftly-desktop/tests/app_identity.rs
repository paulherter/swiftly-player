//! The taskbar shows the app's icon and name only when the window's application id equals the desktop file's id, the
//! desktop file names the product and an icon the packages install, and the Windows identity is the same string.

use swiftly_desktop::window_extras::{APP_ID, PRODUCT_NAME};

const DESKTOP_FILE: &str =
    include_str!("../../../Distribution/desktop/de.paulherter.swiftly.player.desktop");
const PACKAGER: &str = include_str!("../../../Werkzeuge/package-desktop.sh");

fn key(name: &str) -> Option<&'static str> {
    DESKTOP_FILE
        .lines()
        .find_map(|l| l.strip_prefix(name).and_then(|r| r.strip_prefix('=')))
}

#[test]
fn the_window_id_is_the_desktop_file_id() {
    assert_eq!(APP_ID, "de.paulherter.swiftly.player");
    // The packagers install the file under exactly that id.
    assert!(
        PACKAGER.contains(&format!("{APP_ID}.desktop")),
        "the packager does not install {APP_ID}.desktop"
    );
    assert_eq!(key("StartupWMClass"), Some(APP_ID), "X11 WM_CLASS");
}

#[test]
fn the_launcher_has_the_product_name_and_an_icon_the_packages_install() {
    assert_eq!(key("Name"), Some(PRODUCT_NAME));
    assert_eq!(PRODUCT_NAME, "Swiftly Player");
    let icon = key("Icon").expect("an Icon line");
    assert!(
        PACKAGER.contains(&format!("{icon}.png")),
        "the packager installs no {icon}.png icon"
    );
    assert_eq!(key("StartupNotify"), Some("true"));
}

#[cfg(windows)]
#[test]
fn the_windows_identity_is_the_same_string() {
    assert_eq!(swiftly_desktop::win_shell::APP_USER_MODEL_ID, APP_ID);
}
