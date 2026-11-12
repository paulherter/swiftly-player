//! Drives the whole app (`--demo app`) headless per form factor: tap a tile, the title page slides in, back, and again
//! with Esc; a resize re-flows. No window, software renderer, fixed clock.

use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom, NavKey};

const STEP: f64 = 1000.0 / 60.0;

fn run_for(s: &mut Suite, now: &mut f64, ms: f64) {
    let end = *now + ms;
    while *now < end {
        *now += STEP;
        let _ = s.frame(*now);
    }
}

fn flow(idiom: Idiom, size: (f32, f32)) {
    let env = Env::new(Size::new(size.0, size.1), 1.0, idiom);
    let mut s = Suite::new(env, Cx::deterministic());
    let mut now = 0.0;
    run_for(&mut s, &mut now, 300.0);
    assert_eq!(s.tab(), 0);
    assert!(!s.title_open());
    // Home's Continue rail resumes playback at once (no title page), so the title pages are opened from Movies.
    assert!(s.goto_tab(1, now));
    run_for(&mut s, &mut now, 400.0);

    for round in 0..2 {
        // Find a tile by tapping a grid of points below the header until a title page opens.
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
                if s.tab() != 1 {
                    panic!("{idiom:?}: a tap switched to tab {}", s.tab());
                }
            }
        }
        assert!(
            s.pushes() > before,
            "{idiom:?}: no tile opened a title page"
        );
        assert!(s.title_open());
        run_for(&mut s, &mut now, 1200.0);
        let (list, _) = s.frame(now + STEP);
        assert!(
            !list.quads().is_empty(),
            "{idiom:?}: title page drew nothing"
        );
        if round == 0 {
            assert!(s.back(now), "{idiom:?}: back did nothing");
        } else {
            let _ = s.nav_key(NavKey::Escape, true, now);
            let _ = s.nav_key(NavKey::Escape, false, now);
        }
        run_for(&mut s, &mut now, 1200.0);
        assert!(!s.title_open(), "{idiom:?}: round {round} did not pop");
    }

    // Window resize re-flows without trouble.
    let small = Env::new(Size::new(size.0 * 0.7, size.1 * 0.8), 1.0, idiom);
    s.set_env(small);
    run_for(&mut s, &mut now, 100.0);
    let (list, _) = s.frame(now + STEP);
    assert!(!list.quads().is_empty());
}

#[test]
fn touch_flow() {
    flow(Idiom::Phone, (390.0, 844.0));
}

#[test]
fn desktop_flow() {
    flow(Idiom::Desktop, (1280.0, 800.0));
}

#[test]
fn tv_flow() {
    flow(Idiom::Tv, (1920.0, 1080.0));
}
