//! Parity audit 10: title menu, collection cards, alphabet strip, strip jumps and scroll restore of the Library screen (software renderer, bundled Inter, three form
//! factors). PNGs live in `swiftly-ui/tests/golden`; `UPDATE_GOLDENS=1` rewrites them. Tolerance: 2 levels per channel.

use std::path::PathBuf;
use swiftly_desktop::browse::Scenario;
use swiftly_desktop::library_screen::{Kind, LibraryScreen};
use swiftly_layout::Size;
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Env, Idiom};

const FRAME_MS: f64 = 1000.0 / 60.0;
// The goldens come from macOS; the software renderer rounds a little differently on other systems (seen: up to 10 levels).
const TOLERANCE: u8 = if cfg!(target_os = "macos") { 2 } else { 12 };

struct Form {
    name: &'static str,
    size_pt: (f32, f32),
    scale: f32,
    idiom: Idiom,
}
const TOUCH: Form = Form {
    name: "touch",
    size_pt: (390.0, 844.0),
    scale: 3.0,
    idiom: Idiom::Phone,
};
const DESKTOP: Form = Form {
    name: "desktop",
    size_pt: (1280.0, 800.0),
    scale: 2.0,
    idiom: Idiom::Desktop,
};
const TV: Form = Form {
    name: "tv",
    size_pt: (1920.0, 1080.0),
    scale: 1.0,
    idiom: Idiom::Tv,
};

fn env(f: &Form) -> Env {
    Env::new(Size::new(f.size_pt.0, f.size_pt.1), f.scale, f.idiom)
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
    let (max, _) = img.diff(golden_ref(&golden));
    assert!(max <= TOLERANCE, "golden {name} differs by {max}");
}
fn golden_ref(g: &RgbaImage) -> &RgbaImage {
    g
}

fn screen(f: &Form, kind: &Kind) -> LibraryScreen {
    LibraryScreen::new(env(f), Cx::deterministic(), kind, Scenario::Ready)
}
fn run_to(s: &mut LibraryScreen, now: &mut f64, to: f64) {
    while *now + FRAME_MS < to {
        *now += FRAME_MS;
        let _ = s.frame(*now);
    }
    *now = to;
    let _ = s.frame(to);
}
fn shot(s: &mut LibraryScreen, now: &mut f64, dt: f64) -> RgbaImage {
    let to = *now + dt;
    run_to(s, now, to);
    let (list, _) = s.frame(*now);
    s.render_software(&list)
}
/// Where the strip is (touch and desktop): the right margin, a little under the controls.
fn rail_point(f: &Form, frac: f32) -> (f32, f32) {
    let x = f.size_pt.0 - 3.0 - 11.0;
    (x, f.size_pt.1 * frac)
}

fn scenes(f: &Form) {
    // title menu, cards
    let mut s = screen(f, &Kind::Movies);
    let mut t = 0.0;
    run_to(&mut s, &mut t, 400.0);
    let list = s.vm().list().unwrap_or_else(|| panic!("offering"));
    assert!(list.is_menu);
    assert_eq!(
        list.entries
            .iter()
            .map(|e| e.key.as_str())
            .collect::<Vec<_>>(),
        [
            "alle",
            "sammlungen",
            "wiedergabelisten",
            "lib-movies",
            "lib-more"
        ]
    );
    assert_eq!(list.entries[3].category.as_deref(), Some("Bibliotheken"));
    s.show_section();
    check(
        &format!("library_{}_section", f.name),
        &shot(&mut s, &mut t, 100.0),
    );
    assert!(s.vm().select("sammlungen"));
    assert_eq!(s.vm().cards().len(), 3);
    s.vm().select("alle");
    assert!(s.vm().cards().is_empty());
    let mut c = screen(f, &Kind::Movies);
    let mut t = 0.0;
    run_to(&mut c, &mut t, 400.0);
    c.vm().select("wiedergabelisten");
    assert_eq!(c.vm().cards().len(), 2);
    check(
        &format!("library_{}_cards", f.name),
        &shot(&mut c, &mut t, 400.0),
    );
    // a library switches the source and reloads
    let mut l = screen(f, &Kind::Movies);
    let mut t = 0.0;
    run_to(&mut l, &mut t, 400.0);
    assert!(l.vm().select("lib-more"));
    let started = std::time::Instant::now();
    while l.vm().grid().tiles.is_empty() {
        assert!(started.elapsed().as_secs() < 10, "the library did not load");
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
    run_to(&mut l, &mut t, 1200.0);
    assert!(!l.vm().select("lib-more"), "same choice is no change");
}

#[test]
fn library_menu_touch() {
    scenes(&TOUCH);
}
#[test]
fn library_menu_desktop() {
    swiftly_desktop::desk::force_hint_os(swiftly_motion::Os::MacOs); // the goldens are Mac-made
    scenes(&DESKTOP);
}

fn rail(f: &Form) {
    let mut s = screen(f, &Kind::Movies);
    let mut t = 0.0;
    run_to(&mut s, &mut t, 600.0);
    assert!(s.rail_shown(), "90 titles get a strip");
    let before = s.offset();
    let (x, y) = rail_point(f, 0.62);
    s.touch_down(x, y, t + FRAME_MS);
    let lit = s.rail_lit();
    s.touch_up(x, y, t + 2.0 * FRAME_MS);
    let to = t + 60.0;
    run_to(&mut s, &mut t, to);
    let mid = s.offset();
    let to = t + 1500.0;
    run_to(&mut s, &mut t, to);
    let after = s.offset();
    assert!(
        after > before + 100.0,
        "the jump scrolled ({before} -> {after})"
    );
    assert!(mid <= after, "animated, not a cut");
    assert!(lit.is_some());
    check(
        &format!("library_{}_rail", f.name),
        &shot(&mut s, &mut t, 100.0),
    );
    // the finger slides to another entry
    let (x2, y2) = rail_point(f, 0.3);
    s.touch_down(x, y, t + 10.0);
    s.touch_move(x2, y2, t + 30.0);
    s.touch_up(x2, y2, t + 50.0);
    let to = t + 1500.0;
    run_to(&mut s, &mut t, to);
    assert!(s.offset() < after, "a higher entry scrolls back up");
}
#[test]
fn library_rail_touch() {
    rail(&TOUCH);
}
#[test]
fn library_rail_desktop() {
    swiftly_desktop::desk::force_hint_os(swiftly_motion::Os::MacOs); // the goldens are Mac-made
    rail(&DESKTOP);
}
#[test]
fn library_no_rail_on_tv() {
    let mut s = screen(&TV, &Kind::Movies);
    let mut t = 0.0;
    run_to(&mut s, &mut t, 600.0);
    assert!(!s.rail_shown());
}

#[test]
fn library_scroll_is_restored_after_leaving() {
    let f = &TOUCH;
    let mut s = screen(f, &Kind::Movies);
    let mut t = 0.0;
    run_to(&mut s, &mut t, 600.0);
    let (x, y) = rail_point(f, 0.5);
    s.touch_down(x, y, t + 10.0);
    s.touch_up(x, y, t + 30.0);
    let to = t + 1500.0;
    run_to(&mut s, &mut t, to);
    let at = s.offset();
    assert!(at > 100.0);
    drop(s);
    let mut back = screen(f, &Kind::Movies);
    let mut t = 0.0;
    run_to(&mut back, &mut t, 800.0);
    assert!(
        (back.offset() - at).abs() < 1.0,
        "back at {at}, now {}",
        back.offset()
    );
}
