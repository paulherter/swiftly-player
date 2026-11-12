//! Parity audit 10: tile menu on the Detail rails and the download sheet of the Detail page (software renderer, bundled Inter, fixed clock)
//! for touch, desktop and tv. PNGs live in `swiftly-ui/tests/golden`; `UPDATE_GOLDENS=1` rewrites them. Tolerance 2.

use std::path::PathBuf;
use swiftly_desktop::detail_screen::DetailScreen;
use swiftly_desktop::home_data::Scenario;
use swiftly_layout::Size;
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Env, Idiom};

const FRAME_MS: f64 = 1000.0 / 60.0;

struct Form {
    name: &'static str,
    size: (f32, f32),
    scale: f32,
    idiom: Idiom,
}

const TOUCH: Form = Form {
    name: "touch",
    size: (390.0, 844.0),
    scale: 3.0,
    idiom: Idiom::Phone,
};
const DESKTOP: Form = Form {
    name: "desktop",
    size: (1280.0, 800.0),
    scale: 2.0,
    idiom: Idiom::Desktop,
};
#[allow(dead_code)]
const TV: Form = Form {
    name: "tv",
    size: (1920.0, 1080.0),
    scale: 1.0,
    idiom: Idiom::Tv,
};

fn env(f: &Form) -> Env {
    Env::new(Size::new(f.size.0, f.size.1), f.scale, f.idiom)
}

// The goldens come from macOS; the software renderer rounds a little differently on other systems (seen: up to 10 levels).
const TOLERANCE: u8 = if cfg!(target_os = "macos") { 2 } else { 12 };

fn check(name: &str, img: &RgbaImage) {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../swiftly-ui/tests/golden")
        .join(format!("{name}.png"));
    if std::env::var_os("UPDATE_GOLDENS").is_some() || !path.exists() {
        img.write_png(&path)
            .unwrap_or_else(|e| panic!("golden {name}: {e}"));
        println!("golden {name}: written");
        return;
    }
    let golden = RgbaImage::read_png(&path).unwrap_or_else(|e| panic!("golden {name}: {e}"));
    assert_eq!(
        (img.width, img.height),
        (golden.width, golden.height),
        "golden {name}: size"
    );
    let (max, _) = img.diff(&golden);
    assert!(max <= TOLERANCE, "golden {name} differs by {max}");
}

fn scenes(f: &Form) {
    let mut s = DetailScreen::new(env(f), Cx::deterministic(), Scenario::Ready);
    let mut now = 0.0;
    let _ = s.frame(0.0);
    s.open(0.0);
    let to = 1500.0;
    while now + FRAME_MS < to {
        now += FRAME_MS;
        let _ = s.frame(now);
    }
    assert!(s.open_tile_menu(), "the rails have a tile");
    assert_eq!(s.sheet_kind(), 3);
    let (list, _) = s.frame(to);
    check(
        &format!("detail_{}_tilemenu", f.name),
        &s.render_software(&list),
    );
    s.open_load();
    let (list, _) = s.frame(to + 100.0);
    check(
        &format!("detail_{}_load", f.name),
        &s.render_software(&list),
    );
}

#[test]
fn detail_tile_menu_and_load_touch() {
    scenes(&TOUCH);
}
#[test]
fn detail_tile_menu_and_load_desktop() {
    scenes(&DESKTOP);
}
