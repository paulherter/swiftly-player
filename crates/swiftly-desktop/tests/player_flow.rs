//! Play on the Detail page opens the player over the app (fake engine) and closing it returns to the page.
#![allow(clippy::unwrap_used)]

use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Dir, Env, Idiom, NavKey};

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
    let tv = idiom == Idiom::Tv;
    // Open a title page.
    'open: for yi in 0..14 {
        for xi in 0..14 {
            let (x, y) = (
                size.0 * (0.12 + 0.06 * xi as f32),
                size.1 * (0.25 + 0.05 * yi as f32),
            );
            s.touch_down(x, y, now);
            s.touch_up(x, y, now + 40.0);
            now += 80.0;
            if s.title_open() {
                break 'open;
            }
            // The Continue rail resumes at once (no page first, like the Mac): close that player and scan on.
            if s.player_open() {
                for _ in 0..3 {
                    let _ = s.nav_key(NavKey::Escape, true, now);
                    let _ = s.nav_key(NavKey::Escape, false, now + 10.0);
                    now += 100.0;
                }
                run_for(&mut s, &mut now, 600.0);
                assert!(
                    !s.player_open(),
                    "{idiom:?}: Esc did not close the resumed player"
                );
            }
        }
    }
    if !s.title_open() && tv {
        // The TV home is all hero and Continue rail (which plays at once): walk the focus on and press Enter.
        for step in 0..30 {
            let _ = s.nav_key(NavKey::Enter, true, now);
            let _ = s.nav_key(NavKey::Enter, false, now + 20.0);
            run_for(&mut s, &mut now, 300.0);
            if s.title_open() {
                break;
            }
            for _ in 0..3 {
                let _ = s.nav_key(NavKey::Escape, true, now);
                let _ = s.nav_key(NavKey::Escape, false, now + 10.0);
                now += 100.0;
            }
            run_for(&mut s, &mut now, 600.0);
            let dir = if step % 3 == 2 { Dir::Right } else { Dir::Down };
            let _ = s.nav_key(NavKey::Arrow(dir), true, now);
            let _ = s.nav_key(NavKey::Arrow(dir), false, now + 20.0);
            run_for(&mut s, &mut now, 300.0);
        }
    }
    assert!(s.title_open());
    run_for(&mut s, &mut now, 1300.0);
    // Press Play: Enter on the default focus (tv) or a scan of taps over the hero buttons.
    if tv {
        for _ in 0..3 {
            let _ = s.nav_key(NavKey::Enter, true, now);
            let _ = s.nav_key(NavKey::Enter, false, now + 20.0);
            now += 100.0;
            if s.player_open() {
                break;
            }
        }
    } else {
        'play: for yi in 0..40 {
            for xi in 0..24 {
                let (x, y) = (
                    size.0 * (0.20 + 0.03 * xi as f32),
                    size.1 * (0.08 + 0.022 * yi as f32),
                );
                s.touch_down(x, y, now);
                s.touch_up(x, y, now + 40.0);
                now += 80.0;
                if s.player_open() {
                    break 'play;
                }
            }
        }
    }
    assert!(s.player_open(), "{idiom:?}: Play did not open the player");
    run_for(&mut s, &mut now, 600.0);
    let (list, wants) = s.frame(now + STEP);
    assert!(!list.quads().is_empty() && wants);
    // Esc closes the controls, then the player; the page is still there.
    for _ in 0..3 {
        let _ = s.nav_key(NavKey::Escape, true, now);
        let _ = s.nav_key(NavKey::Escape, false, now + 10.0);
        now += 100.0;
    }
    assert!(!s.player_open(), "{idiom:?}: Esc did not close the player");
    assert!(s.title_open());
}

#[test]
fn touch_player_flow() {
    flow(Idiom::Phone, (390.0, 844.0));
}

#[test]
fn desktop_player_flow() {
    flow(Idiom::Desktop, (1280.0, 800.0));
}

#[test]
fn tv_player_flow() {
    flow(Idiom::Tv, (1920.0, 1080.0));
}
