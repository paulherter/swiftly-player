//! The desktop toolbar bar (edge glow + small title, Mac `StateBar` / `DetailHeader`) on the pages that had none:
//! Settings pages and the title/person/genre pages, plus its worst cases (long and right-to-left titles, empty pages).
//! PNGs live in `swiftly-ui/tests/golden`; `UPDATE_GOLDENS=1` rewrites them (same tolerance rules as `forms_golden`).

use std::path::PathBuf;
use swiftly_desktop::detail_screen::DetailScreen;
use swiftly_desktop::home_data::Scenario;
use swiftly_desktop::pages_screen::{Kind, PageScreen};
use swiftly_desktop::series_screen::SeriesScreen;
use swiftly_desktop::settings_screen::SettingsScreen;
use swiftly_layout::Size;
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Env, Idiom};

const FRAME_MS: f64 = 1000.0 / 60.0;
// Icon edges are rasterised through the system libm, so macOS differs from the Linux goldens by a few edge pixels:
// there a difference above 2 levels may touch at most 0.05 % of the pixels (see `forms_golden`).
const TOLERANCE: u8 = if cfg!(target_os = "macos") { 16 } else { 12 };
const MAC_PIXEL_SHARE: f64 = 0.0005;

fn env(w: f32, h: f32) -> Env {
    Env::new(Size::new(w, h), 2.0, Idiom::Desktop)
}

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
    if let (true, Some(dir)) = (max > 0, std::env::var_os("GOLDEN_ACTUAL_DIR")) {
        let _ = img.write_png(&PathBuf::from(dir).join(format!("{name}.png")));
    }
    let share_ok = !cfg!(target_os = "macos") || max <= 2 || share <= MAC_PIXEL_SHARE;
    assert!(
        max <= TOLERANCE && share_ok,
        "golden {name} differs by {max} ({:.3} % of the pixels)",
        share * 100.0
    );
}

/// Rows `y0..y1` (device pixels) of `img` as a flat slice: the part of the page the bar covers.
fn band(img: &RgbaImage, y0: usize, y1: usize) -> &[u8] {
    &img.pixels[y0 * img.width * 4..y1 * img.width * 4]
}

macro_rules! drive {
    ($s:expr, $now:expr, $to:expr) => {{
        while *$now + FRAME_MS < $to {
            *$now += FRAME_MS;
            let _ = $s.frame(*$now);
        }
        *$now = $to;
        let (list, _) = $s.frame($to);
        $s.render_software(&list)
    }};
}

macro_rules! drag_up {
    ($s:expr, $now:expr, $x:expr, $y0:expr, $dy:expr) => {{
        $s.touch_down($x, $y0, *$now);
        for i in 1..=10 {
            *$now += FRAME_MS;
            $s.touch_move($x, $y0 - $dy * i as f32 / 10.0, *$now);
            let _ = $s.frame(*$now);
        }
        $s.touch_up($x, $y0 - $dy, *$now + FRAME_MS);
    }};
}

#[test]
fn settings_pages_get_the_glow_and_the_small_title_when_scrolled() {
    // A short window so the Allgemein page scrolls.
    for page in ["general", "playback", "presentation"] {
        let mut s = SettingsScreen::new(env(1100.0, 330.0), Cx::deterministic(), true);
        s.open_page(page);
        let mut now = 0.0;
        let rest = drive!(s, &mut now, 400.0);
        drag_up!(s, &mut now, 550.0, 300.0, 240.0);
        let to = now + 900.0;
        let scrolled = drive!(s, &mut now, to);
        let off = s.scroll_offsets().first().copied().unwrap_or(0.0);
        assert!(off > 65.0, "{page}: the page scrolled ({off})");
        // The bar zone (52 pt = 104 px; the glow 150 pt) differs from the resting top: glow plus title.
        assert_ne!(
            band(&rest, 0, 100),
            band(&scrolled, 0, 100),
            "{page}: no bar when scrolled"
        );
        if page == "general" {
            check("settings_desktop_scrolled", &scrolled);
        }
    }
}

#[test]
fn the_title_bar_does_not_show_at_rest() {
    let mut s = SettingsScreen::new(env(1100.0, 330.0), Cx::deterministic(), true);
    let mut now = 0.0;
    let a = drive!(s, &mut now, 400.0);
    let to = now + 300.0;
    let b = drive!(s, &mut now, to);
    assert_eq!(band(&a, 0, 104), band(&b, 0, 104));
}

#[test]
fn title_pages_show_the_bar_when_scrolled_in_the_demo_too() {
    // Regression: the demo host read the root list's scroll (always 0), so the bar never showed in the goldens.
    let mut now = 0.0;
    let mut p = PageScreen::new(
        env(1100.0, 400.0),
        Cx::deterministic(),
        Kind::Person,
        Scenario::Ready,
    );
    p.set_scroll_tuning(swiftly_motion::ScrollTuning::for_os(
        swiftly_motion::Os::Linux,
    ));
    let _ = p.frame(0.0);
    p.open(0.0);
    let rest = drive!(p, &mut now, 1200.0);
    drag_up!(p, &mut now, 550.0, 360.0, 300.0);
    let to = now + 900.0;
    let scrolled = drive!(p, &mut now, to);
    assert_ne!(
        band(&rest, 0, 100),
        band(&scrolled, 0, 100),
        "person page: no bar when scrolled"
    );
    check("person_desktop_scrolled", &scrolled);
    let mut d = DetailScreen::new(env(1100.0, 400.0), Cx::deterministic(), Scenario::Ready);
    let mut now = 0.0;
    let _ = d.frame(0.0);
    d.open(0.0);
    let rest = drive!(d, &mut now, 1200.0);
    drag_up!(d, &mut now, 550.0, 360.0, 300.0);
    let to = now + 900.0;
    let scrolled = drive!(d, &mut now, to);
    assert_ne!(
        band(&rest, 0, 100),
        band(&scrolled, 0, 100),
        "detail page: no bar when scrolled"
    );
    let mut v = SeriesScreen::new(env(1100.0, 400.0), Cx::deterministic(), Scenario::Ready);
    let mut now = 0.0;
    let _ = v.frame(0.0);
    v.open(0.0);
    let rest = drive!(v, &mut now, 1200.0);
    drag_up!(v, &mut now, 550.0, 360.0, 300.0);
    let to = now + 900.0;
    let scrolled = drive!(v, &mut now, to);
    assert_ne!(
        band(&rest, 0, 100),
        band(&scrolled, 0, 100),
        "series page: no bar when scrolled"
    );
}

/// Glyph boxes (x0, x1, y1) inside the toolbar zone (top 52 pt) of a frame at scale 1.
fn bar_glyphs(list: &swiftly_render::DrawList) -> Vec<(f32, f32, f32)> {
    list.quads()
        .iter()
        .filter(|q| q.kind == swiftly_render::QuadKind::Glyph && q.rect.y < 52.0)
        .map(|q| (q.rect.x, q.rect.x + q.rect.w, q.rect.y + q.rect.h))
        .collect()
}

#[test]
fn long_arabic_and_cjk_titles_stay_between_the_arrows_and_the_right_edge() {
    // break-ui for the new bar: the title is one line, starts 94 pt from the left (after the arrows) and ends at the window's
    // right edge less 16, like the Mac `StateBar` (one line, tail ellipsis, 16 trailing). Nothing is drawn over the arrows.
    for (w, h) in [(1100.0_f32, 400.0_f32), (720.0, 400.0)] {
        for i in 0..9 {
            let title = swiftly_desktop::browse::worst_title(i);
            let mut d = DetailScreen::overlay_for(
                Env::new(Size::new(w, h), 1.0, Idiom::Desktop),
                Cx::deterministic(),
                Scenario::Worst,
                ("m1", title),
            );
            let mut now = 0.0;
            let _ = d.frame(0.0);
            d.open(0.0);
            let _ = drive!(d, &mut now, 1200.0);
            drag_up!(d, &mut now, w / 2.0, 360.0, 330.0);
            let to = now + 900.0;
            let _ = drive!(d, &mut now, to);
            let (list, _) = d.frame(to + 1.0);
            let g = bar_glyphs(&list);
            assert!(
                !g.is_empty(),
                "{title}: the small title shows once the page scrolled ({w} pt)"
            );
            let (left, right) = g
                .iter()
                .fold((f32::MAX, 0.0_f32), |a, g| (a.0.min(g.0), a.1.max(g.1)));
            assert!(
                left >= 94.0 - 1.0,
                "{title}: starts at {left}, over the arrows ({w} pt)"
            );
            assert!(
                right <= w - 16.0 + 1.0,
                "{title}: ends at {right}, past the edge ({w} pt)"
            );
            assert!(
                g.iter().all(|g| g.2 <= 52.0),
                "{title}: one line, inside the 52 pt bar ({w} pt)"
            );
        }
    }
}

#[test]
fn a_short_person_name_is_not_cut_in_the_bar() {
    // "Mara Brandt" has room in a 1100 pt window: the Mac shows it whole (the tail ellipsis is only for names that do not fit).
    let (w, h) = (1100.0_f32, 400.0_f32);
    let mut p = PageScreen::new(
        Env::new(Size::new(w, h), 1.0, Idiom::Desktop),
        Cx::deterministic(),
        Kind::Person,
        Scenario::Ready,
    );
    let mut now = 0.0;
    let _ = p.frame(0.0);
    p.open(0.0);
    let _ = drive!(p, &mut now, 1200.0);
    drag_up!(p, &mut now, w / 2.0, 360.0, 330.0);
    let to = now + 900.0;
    let _ = drive!(p, &mut now, to);
    let (list, _) = p.frame(to + 1.0);
    let g = bar_glyphs(&list);
    let right = g.iter().fold(0.0_f32, |a, g| a.max(g.1));
    assert!(right > 94.0 + 60.0, "the name reaches {right}: cut short");
}
