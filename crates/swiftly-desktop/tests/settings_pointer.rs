//! The suite forwards the pointer to the settings page in front (hover surfaces on rows).

use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

#[test]
fn suite_pointer_reaches_the_settings_page() {
    let env = Env::new(Size::new(1280.0, 800.0), 2.0, Idiom::Desktop);
    let mut suite = Suite::new(env, Cx::deterministic());
    let mut now = 0.0;
    for _ in 0..10 {
        now += 16.0;
        let _ = suite.frame(now);
    }
    assert!(suite.open_settings(now));
    for _ in 0..120 {
        now += 16.0;
        let _ = suite.frame(now);
    }
    assert_eq!(suite.form_open(), Some("settings"));
    let shot = |suite: &mut Suite, now: f64| {
        let _ = suite.frame(now);
        let (l, _) = suite.frame(now + 400.0);
        suite.render_software(&l)
    };
    now += 1000.0;
    let base = shot(&mut suite, now);
    let mut lit = false;
    for y in (100..500).step_by(10) {
        now += 1000.0;
        suite.pointer_move(200.0, y as f32, now);
        now += 1000.0;
        if base.diff(&shot(&mut suite, now)).0 > 0 {
            lit = true;
            break;
        }
    }
    assert!(lit, "the pointer lights a row of the settings page");
    now += 1000.0;
    suite.pointer_leave(now);
    now += 1000.0;
    assert_eq!(base.diff(&shot(&mut suite, now)).0, 0, "leaving clears it");
}
