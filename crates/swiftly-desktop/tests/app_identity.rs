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

/// Linux shells draw the launcher icon exactly as given, so the files the packages install must carry their cut corners:
/// a full square in the taskbar was the bug.
#[test]
fn the_launcher_icons_have_round_corners_and_are_installed_in_every_size() {
    assert!(
        PACKAGER.contains("ICON_SIZES=\"32 48 64 128 256\""),
        "the packager installs not every size"
    );
    for side in [32u32, 48, 64, 128, 256] {
        let path = format!(
            "{}/../../Distribution/desktop/icons/swiftly-player-{side}.png",
            env!("CARGO_MANIFEST_DIR")
        );
        let file = std::fs::File::open(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
        let mut reader = png::Decoder::new(std::io::BufReader::new(file))
            .read_info()
            .unwrap();
        let mut buf = vec![0; reader.output_buffer_size().unwrap()];
        let info = reader.next_frame(&mut buf).unwrap();
        assert_eq!(info.color_type, png::ColorType::Rgba, "{path}");
        assert_eq!((info.width, info.height), (side, side), "{path}");
        let alpha = |x: u32, y: u32| buf[((y * side + x) * 4 + 3) as usize];
        let last = side - 1;
        for (x, y) in [(0, 0), (last, 0), (0, last), (last, last)] {
            assert_eq!(alpha(x, y), 0, "{path}: the corner ({x},{y}) is not cut");
        }
        assert_eq!(
            alpha(side / 2, side / 2),
            255,
            "{path}: the middle is see-through"
        );
        assert_eq!(alpha(side / 2, 0), 255, "{path}: the edge is cut away");
    }
}
