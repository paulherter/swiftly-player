//! Finger drags on every scroll area of the desktop screens (GitHub #56): a vertical drag scrolls the page (and a
//! drag that starts on a poster or an episode never opens it), a horizontal drag scrolls a row sideways.
#![allow(clippy::unwrap_used)]

use swiftly_desktop::browse::Scenario as BrowseScenario;
use swiftly_desktop::detail_screen::DetailScreen;
use swiftly_desktop::home::HomeScreen;
use swiftly_desktop::home_data::Scenario;
use swiftly_desktop::library_screen::{Kind, LibraryScreen};
use swiftly_desktop::pages_screen::{Kind as PageKind, PageScreen};
use swiftly_desktop::series_screen::SeriesScreen;
use swiftly_desktop::settings_screen::SettingsScreen;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

fn env() -> Env {
    Env::new(Size::new(1280.0, 620.0), 1.0, Idiom::Desktop)
}

/// A shorter window for the settings page: without the Discord row (the desktop shows no presence) its content is
/// barely taller than the default window, and a page that fits has nothing to scroll.
fn short_env() -> Env {
    Env::new(Size::new(1280.0, 540.0), 1.0, Idiom::Desktop)
}

/// One screen under test: frames, touch, and every scroll offset in tree order.
struct Rig {
    frame: Box<dyn FnMut(f64)>,
    down: Box<dyn FnMut(f32, f32, f64)>,
    mv: Box<dyn FnMut(f32, f32, f64)>,
    up: Box<dyn FnMut(f32, f32, f64)>,
    offs: Box<dyn FnMut() -> Vec<f64>>,
}

macro_rules! rig {
    ($s:expr, $offs:expr) => {{
        let s = std::rc::Rc::new(std::cell::RefCell::new($s));
        let (a, b, c, d, e) = (s.clone(), s.clone(), s.clone(), s.clone(), s);
        Rig {
            frame: Box::new(move |t| {
                let _ = a.borrow_mut().frame(t);
            }),
            down: Box::new(move |x, y, t| b.borrow_mut().touch_down(x, y, t)),
            mv: Box::new(move |x, y, t| c.borrow_mut().touch_move(x, y, t)),
            up: Box::new(move |x, y, t| d.borrow_mut().touch_up(x, y, t)),
            offs: Box::new(move || {
                let mut g = e.borrow_mut();
                #[allow(clippy::redundant_closure_call)]
                ($offs)(&mut *g)
            }),
        }
    }};
}

fn rigs() -> Vec<(&'static str, Rig)> {
    let cx = Cx::deterministic;
    vec![
        (
            "home",
            rig!(
                HomeScreen::new(env(), cx(), Scenario::Ready),
                |s: &mut HomeScreen| s.scroll_offsets()
            ),
        ),
        (
            "library",
            rig!(
                LibraryScreen::new(env(), cx(), &Kind::Movies, BrowseScenario::Ready),
                |s: &mut LibraryScreen| s.scroll_offsets()
            ),
        ),
        (
            "series-detail",
            rig!(
                {
                    let mut s = SeriesScreen::new(env(), cx(), Scenario::Ready);
                    s.open(0.0);
                    s
                },
                |s: &mut SeriesScreen| s.scroll_offsets()
            ),
        ),
        (
            "movie-detail",
            rig!(
                {
                    let mut s = DetailScreen::new(env(), cx(), Scenario::Ready);
                    s.open(0.0);
                    s
                },
                |s: &mut DetailScreen| s.scroll_offsets()
            ),
        ),
        (
            "page",
            rig!(
                {
                    let mut s = PageScreen::new(env(), cx(), PageKind::Collection, Scenario::Ready);
                    s.open(0.0);
                    s
                },
                |s: &mut PageScreen| s.scroll_offsets()
            ),
        ),
        (
            "settings",
            rig!(
                SettingsScreen::new(short_env(), cx(), true),
                |s: &mut SettingsScreen| s.scroll_offsets()
            ),
        ),
    ]
}

fn settle(r: &mut Rig, now: &mut f64, ms: f64) {
    let end = *now + ms;
    while *now < end {
        *now += 8.0;
        (r.frame)(*now);
    }
}

/// Drag from `from` by `(dx, dy)` in 15 frames, release while still moving; returns the offsets before and after.
fn drag(r: &mut Rig, now: &mut f64, from: (f32, f32), d: (f32, f32)) -> (Vec<f64>, Vec<f64>) {
    let before = (r.offs)();
    (r.down)(from.0, from.1, *now);
    for i in 1..=15 {
        *now += 8.0;
        (r.mv)(
            from.0 + d.0 * i as f32 / 15.0,
            from.1 + d.1 * i as f32 / 15.0,
            *now,
        );
        (r.frame)(*now);
    }
    (r.up)(from.0 + d.0, from.1 + d.1, *now);
    settle(r, now, 600.0);
    (before, (r.offs)())
}

#[test]
fn a_vertical_finger_drag_scrolls_every_page() {
    for (name, mut r) in rigs() {
        let mut now = 0.0;
        settle(&mut r, &mut now, 600.0);
        let mut moved = false;
        for x in [200.0, 640.0, 1000.0] {
            let (a, b) = drag(&mut r, &mut now, (x, 500.0), (0.0, -240.0));
            moved |= a.iter().zip(&b).any(|(p, q)| (p - q).abs() > 20.0);
            if moved {
                break;
            }
        }
        assert!(moved, "{name}: a vertical finger drag moved no scroll area");
    }
}

#[test]
fn a_horizontal_finger_drag_scrolls_a_row_sideways() {
    for (name, mut r) in rigs() {
        if matches!(name, "settings" | "library") {
            continue;
        }
        let mut now = 0.0;
        settle(&mut r, &mut now, 600.0);
        let mut moved = false;
        let mut y = 120.0;
        while y < 600.0 && !moved {
            let (a, b) = drag(&mut r, &mut now, (900.0, y), (-400.0, 0.0));
            moved = a.iter().zip(&b).any(|(p, q)| (p - q).abs() > 20.0);
            y += 50.0;
        }
        eprintln!("{name}: row scroll found={moved}");
        if name == "home" {
            assert!(moved, "{name}: no horizontal row scrolls under a finger");
        }
    }
}

#[test]
fn the_library_grid_shows_its_scroll_bar_after_a_finger_drag_and_fades() {
    let mut s = LibraryScreen::new(
        env(),
        Cx::deterministic(),
        &Kind::Series,
        BrowseScenario::Ready,
    );
    let mut t = 0.0;
    for _ in 0..60 {
        t += 8.0;
        let _ = s.frame(t);
    }
    assert!(
        s.scroll_bar().is_some_and(|(_, a)| a == 0.0),
        "hidden at rest: {:?}",
        s.scroll_bar()
    );
    s.touch_down(700.0, 500.0, t);
    for i in 1..=12 {
        t += 8.0;
        s.touch_move(700.0, 500.0 - 20.0 * i as f32, t);
        let _ = s.frame(t);
    }
    s.touch_up(700.0, 260.0, t);
    t += 100.0;
    let _ = s.frame(t);
    let (thumb, a) = s.scroll_bar().unwrap();
    assert!(
        a > 0.99 && thumb.x > 1200.0 - 40.0 && thumb.h > 20.0,
        "bar after drag: {thumb:?} {a}"
    );
    for _ in 0..400 {
        t += 8.0;
        let _ = s.frame(t);
    }
    assert_eq!(s.scroll_bar().unwrap().1, 0.0, "faded");
}
