//! A tour of the desktop app with the motion catalogue in strict mode: any animation whose curve is not one of the Mac's
//! (`swiftly_motion::catalogue`) panics at the screen that started it. Tabs (area switch), hover, press, push and pop,
//! resize and scrolling run on the demo app.

use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_motion::catalogue;
use swiftly_ui::{Cx, Env, Idiom, NavKey};

const STEP: f64 = 1000.0 / 60.0;

fn run_for(s: &mut Suite, now: &mut f64, ms: f64) {
    let end = *now + ms;
    while *now < end {
        *now += STEP;
        let _ = s.frame(*now);
    }
}

#[test]
fn the_desktop_tour_uses_only_catalogued_curves() {
    catalogue::set_strict(true);
    catalogue::clear_off_catalogue();
    let size = (1280.0_f32, 800.0_f32);
    let mut s = Suite::new(
        Env::new(Size::new(size.0, size.1), 1.0, Idiom::Desktop),
        Cx::deterministic(),
    );
    let mut now = 0.0;
    run_for(&mut s, &mut now, 800.0);
    // Hover over a grid of points (tiles, rows, arrows, sidebar), then press and release.
    for yi in 0..8 {
        for xi in 0..8 {
            let (x, y) = (
                size.0 * (0.12 + 0.1 * xi as f32),
                size.1 * (0.15 + 0.1 * yi as f32),
            );
            s.pointer_move(x, y, now);
            run_for(&mut s, &mut now, 40.0);
        }
    }
    s.pointer_leave(now);
    run_for(&mut s, &mut now, 300.0);
    // Every area in turn (the cross fade of the section switch).
    for tab in [1, 2, 4, 0, 3, 0] {
        let _ = s.goto_tab(tab, now);
        run_for(&mut s, &mut now, 500.0);
    }
    // Open a title and go back with the key.
    let before = s.pushes();
    'scan: for yi in 0..14 {
        for xi in 0..14 {
            let (x, y) = (
                size.0 * (0.30 + 0.05 * xi as f32),
                size.1 * (0.25 + 0.05 * yi as f32),
            );
            s.touch_down(x, y, now);
            s.touch_up(x, y, now + 40.0);
            now += 80.0;
            if s.pushes() > before {
                break 'scan;
            }
        }
    }
    run_for(&mut s, &mut now, 700.0);
    let _ = s.nav_key(NavKey::Escape, true, now);
    let _ = s.nav_key(NavKey::Escape, false, now);
    run_for(&mut s, &mut now, 700.0);
    s.set_env(Env::new(
        Size::new(size.0 * 0.7, size.1 * 0.8),
        1.0,
        Idiom::Desktop,
    ));
    run_for(&mut s, &mut now, 300.0);
    let off = catalogue::off_catalogue();
    catalogue::set_strict(false);
    assert!(off.is_empty(), "curves outside the catalogue: {off:?}");
}
