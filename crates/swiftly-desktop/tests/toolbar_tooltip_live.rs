//! A click on a toolbar arrow hides its help tag until the pointer leaves it (AppKit hides a tag on mouse down). The
//! arrows decide a click by geometry, so the tag used to stay over "Zurück" after the page had gone back.
#![allow(clippy::unwrap_used)]

use swiftly_desktop::a11y_bridge;
use swiftly_desktop::shell::Shell;
use swiftly_ui::{Cx, Idiom};

const STEP: f64 = 1000.0 / 60.0;
const SCALE: f32 = 1.5;
/// The arrows' pointer targets in points (`desk::ARROWS_RECT`: 30 wide buttons 2 apart from x 241, 28 high from y 12).
const BACK: (f64, f64) = (256.0, 26.0);
const FORWARD: (f64, f64) = (287.0, 26.0);

fn frames(s: &mut Shell, now: &mut f64, ms: f64) {
    let end = *now + ms;
    while *now < end {
        *now += STEP;
        let _ = s.frame(*now);
    }
}

fn at(s: &mut Shell, now: &mut f64, p: (f64, f64)) {
    // A short glide, then rest on the point.
    for i in 0..6 {
        *now += STEP;
        s.cursor_moved(
            (
                (p.0 - 12.0 + f64::from(i) * 2.0) * f64::from(SCALE),
                p.1 * f64::from(SCALE),
            ),
            *now,
        );
        let _ = s.frame(*now);
    }
    s.cursor_moved((p.0 * f64::from(SCALE), p.1 * f64::from(SCALE)), *now);
}

fn tip(s: &mut Shell, now: f64) -> Option<String> {
    s.suite_mut().unwrap().arrows_tooltip(now)
}

#[test]
fn a_click_on_back_hides_its_help_tag_until_the_pointer_leaves() {
    let mut s = Shell::new_suite((1920, 1200), SCALE, Cx::deterministic(), Idiom::Desktop);
    let mut now = 0.0;
    frames(&mut s, &mut now, 600.0);
    // Something to go back to: open Filme from the sidebar.
    let (title, tree) = s.suite_mut().unwrap().a11y_nodes();
    let built = a11y_bridge::build(title, &tree, 1.0);
    let id = built
        .update
        .nodes
        .iter()
        .find(|(_, x)| x.label() == Some("Filme"))
        .map(|(i, _)| i.0)
        .unwrap();
    let &(x, y) = built.centres.get(&id).unwrap();
    s.cursor_moved((f64::from(x * SCALE), f64::from(y * SCALE)), now);
    s.primary_button(true, now);
    now += 80.0;
    s.primary_button(false, now);
    frames(&mut s, &mut now, 600.0);
    assert_eq!(s.suite_mut().unwrap().tab(), 1);

    // Rest on "Zurück": the tag appears.
    at(&mut s, &mut now, BACK);
    frames(&mut s, &mut now, 900.0);
    assert_eq!(
        tip(&mut s, now).as_deref(),
        Some("Zurück"),
        "the rest earns it"
    );

    // Click: the page goes back, the tag goes away and stays away while the pointer rests (even with repeated moves).
    s.primary_button(true, now);
    now += 80.0;
    s.primary_button(false, now);
    assert_eq!(s.suite_mut().unwrap().tab(), 0, "the click went back");
    let end = now + 3000.0;
    let mut n = 0;
    while now < end {
        now += STEP;
        n += 1;
        if n % 20 == 0 {
            s.cursor_moved((BACK.0 * f64::from(SCALE), BACK.1 * f64::from(SCALE)), now);
        }
        let _ = s.frame(now);
        assert_eq!(
            tip(&mut s, now),
            None,
            "the tag stays hidden at {now:.0} ms"
        );
    }

    // Another arrow earns its own tag again.
    at(&mut s, &mut now, FORWARD);
    frames(&mut s, &mut now, 900.0);
    assert_eq!(tip(&mut s, now).as_deref(), Some("Vorwärts"));
}
