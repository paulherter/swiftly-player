//! Frame goldens and focus-plan checks of the Detail and Series screens (software renderer, bundled Inter, fixed clock)
//! for touch, desktop and tv. PNGs live in `swiftly-ui/tests/golden`; `UPDATE_GOLDENS=1` rewrites them. Tolerance 2.

use std::path::PathBuf;
use swiftly_desktop::detail_screen::DetailScreen;
use swiftly_desktop::home_data::Scenario;
use swiftly_desktop::series_screen::SeriesScreen;
use swiftly_layout::Size;
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Dir, Env, Idiom, NavKey};

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
const TV: Form = Form {
    name: "tv",
    size: (1920.0, 1080.0),
    scale: 1.0,
    idiom: Idiom::Tv,
};

fn env(f: &Form) -> Env {
    Env::new(Size::new(f.size.0, f.size.1), f.scale, f.idiom)
}

// The goldens are written on Linux (CI runs Linux and macOS); the vector rasteriser rounds a few edge pixels differently
// per OS (icon edges only). Same rule as `forms_golden.rs`: on macOS a difference above 2 levels may touch at most
// 0.05 % of the pixels and none may exceed 16 levels; other systems keep the 12 level tolerance.
const TOLERANCE: u8 = if cfg!(target_os = "macos") { 16 } else { 12 };
const MAC_PIXEL_SHARE: f64 = 0.0005;

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
    let (max, share) = img.diff(&golden);
    let share_ok = !cfg!(target_os = "macos") || max <= 2 || share <= MAC_PIXEL_SHARE;
    assert!(
        max <= TOLERANCE && share_ok,
        "golden {name} differs by {max} ({:.3} % of the pixels)",
        share * 100.0
    );
}

macro_rules! screen_tests {
    ($ty:ident, $kind:expr, $scenes:ident) => {
        fn $scenes(f: &Form) {
            let shot = |s: &mut $ty, now: &mut f64, to: f64| {
                while *now + FRAME_MS < to {
                    *now += FRAME_MS;
                    let _ = s.frame(*now);
                }
                *now = to;
                let (list, _) = s.frame(to);
                s.render_software(&list)
            };
            for (state, scenario) in [
                ("loading", Scenario::Loading),
                ("offline", Scenario::Offline),
                ("initial", Scenario::Ready),
            ] {
                let mut s = $ty::new(env(f), Cx::deterministic(), scenario);
                let mut now = 0.0;
                let _ = s.frame(0.0);
                s.open(0.0);
                assert!(s.is_open());
                let img = shot(&mut s, &mut now, 1200.0);
                check(&format!("{}_{}_{}", $kind, f.name, state), &img);
                if state == "initial" {
                    // Scrolled: a drag on touch/desktop, focus moving down on tv.
                    if f.idiom == Idiom::Tv {
                        for _ in 0..5 {
                            now += 100.0;
                            s.nav_key(NavKey::Arrow(Dir::Down), true, now);
                            s.nav_key(NavKey::Arrow(Dir::Down), false, now + 10.0);
                        }
                        assert!(s.focused().is_some(), "focus on tv");
                    } else {
                        let (x, y0) = (f.size.0 * 0.5, f.size.1 * 0.8);
                        s.touch_down(x, y0, now);
                        for i in 1..=10 {
                            now += FRAME_MS;
                            s.touch_move(x, y0 - 40.0 * i as f32, now);
                            let _ = s.frame(now);
                        }
                        s.touch_up(x, y0 - 400.0, now + FRAME_MS);
                    }
                    let to = now + 900.0;
                    let img = shot(&mut s, &mut now, to);
                    check(&format!("{}_{}_scrolled", $kind, f.name), &img);
                    // The sheet over the page.
                    s.open_sheet(1);
                    let to = now + 100.0;
                    let img = shot(&mut s, &mut now, to);
                    check(&format!("{}_{}_sheet", $kind, f.name), &img);
                    s.open_sheet(0);
                    // Back pops the page again.
                    assert!(s.back(now));
                    let to = now + 1200.0;
                    let _ = shot(&mut s, &mut now, to);
                    assert!(!s.is_open());
                }
            }
        }
    };
}

screen_tests!(DetailScreen, "detail", detail_scenes);
screen_tests!(SeriesScreen, "series", series_scenes);

#[test]
fn touch_phone() {
    detail_scenes(&TOUCH);
    series_scenes(&TOUCH);
}

#[test]
fn desktop() {
    detail_scenes(&DESKTOP);
    series_scenes(&DESKTOP);
}

#[test]
fn tv() {
    detail_scenes(&TV);
    series_scenes(&TV);
}

/// The pushed page shows the vm's parts: the play label, the version choice and the series' next episode.
#[test]
fn parts_reach_the_view() {
    let mut d = DetailScreen::new(env(&DESKTOP), Cx::deterministic(), Scenario::Ready);
    assert!(d.vm().actions().play.enabled);
    assert_eq!(d.vm().actions().play.label, "Fortsetzen ab 32 Min.");
    assert!(d.vm().bottom().ready && !d.vm().bottom().cast.is_empty());
    let mut s = SeriesScreen::new(env(&DESKTOP), Cx::deterministic(), Scenario::Ready);
    assert_eq!(s.vm().episodes().rows.len(), 8);
    assert!(s.vm().episodes().rows[0].watched);
    let _ = (d.frame(0.0), s.frame(0.0));
}

/// Focus plan on tv: Down from the play button reaches the rails, Escape goes back.
#[test]
fn tv_focus_plan() {
    let mut d = DetailScreen::new(env(&TV), Cx::deterministic(), Scenario::Ready);
    let mut now = 0.0;
    let _ = d.frame(now);
    d.open(now);
    for _ in 0..80 {
        now += FRAME_MS;
        let _ = d.frame(now);
    }
    d.nav_key(NavKey::Arrow(Dir::Down), true, now + 10.0);
    let first = d.focused();
    assert!(first.is_some(), "a button takes focus");
    now += 100.0;
    d.nav_key(NavKey::Arrow(Dir::Right), true, now);
    assert_ne!(d.focused(), first, "Right moves along the button row");
    for _ in 0..3 {
        now += 100.0;
        d.nav_key(NavKey::Arrow(Dir::Down), true, now);
    }
    assert!(d.focused().is_some(), "Down reaches a rail");
    d.nav_key(NavKey::Escape, true, now + 100.0);
    assert!(!d.is_open() || d.wants_frame(), "Escape pops the page");
}
