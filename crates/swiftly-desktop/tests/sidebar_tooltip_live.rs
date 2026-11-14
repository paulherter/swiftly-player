//! A sidebar click hides the row's help tag until the pointer leaves it, also when the click opens another page.
//! Drives the shell the way the window does: pointer move, press, release, then frames with no movement.
#![allow(clippy::unwrap_used)]

use swiftly_desktop::a11y_bridge;
use swiftly_desktop::shell::Shell;
use swiftly_ui::{Cx, Idiom};

const STEP: f64 = 1000.0 / 60.0;
const SCALE: f32 = 1.5;

fn frames(s: &mut Shell, now: &mut f64, ms: f64) {
    let end = *now + ms;
    while *now < end {
        *now += STEP;
        let _ = s.frame(*now);
    }
}

fn row_centre_px(s: &mut Shell, label: &str) -> (f64, f64) {
    let (title, tree) = s.suite_mut().unwrap().a11y_nodes();
    let built = a11y_bridge::build(title, &tree, 1.0);
    let id = built
        .update
        .nodes
        .iter()
        .find(|(_, x)| x.label() == Some(label))
        .map(|(i, _)| i.0)
        .unwrap_or_else(|| panic!("no row {label}"));
    let &(x, y) = built.centres.get(&id).unwrap();
    (f64::from(x * SCALE), f64::from(y * SCALE))
}

fn tip(s: &mut Shell, now: f64) -> Option<String> {
    s.suite_mut().unwrap().base_tooltip(now).map(|(t, _)| t)
}

fn click_row_and_rest(label: &str, expect_tab: usize) {
    let mut s = Shell::new_suite((1920, 1200), SCALE, Cx::deterministic(), Idiom::Desktop);
    let mut now = 0.0;
    frames(&mut s, &mut now, 600.0);
    let (x, y) = row_centre_px(&mut s, label);
    // The pointer glides onto the row, then rests: the help tag appears.
    for i in 0..6 {
        now += STEP;
        s.cursor_moved((x - 40.0 + f64::from(i) * 8.0, y), now);
        let _ = s.frame(now);
    }
    s.cursor_moved((x, y), now);
    frames(&mut s, &mut now, 900.0);
    assert_eq!(
        tip(&mut s, now).as_deref(),
        Some(label),
        "the rest earns it"
    );
    // Press, release 80 ms later, then no movement for 3 s (the window may repeat the same position now and then).
    s.primary_button(true, now);
    now += 80.0;
    s.primary_button(false, now);
    assert_eq!(
        s.suite_mut().unwrap().tab(),
        expect_tab,
        "the click went to the page"
    );
    let end = now + 3000.0;
    let mut n = 0;
    while now < end {
        now += STEP;
        n += 1;
        if n % 20 == 0 {
            s.cursor_moved((x, y), now);
        }
        let _ = s.frame(now);
        assert_eq!(
            tip(&mut s, now),
            None,
            "the tag stays hidden at {now:.0} ms"
        );
    }
    // The pointer leaves the row and comes back: the tag is earned again.
    s.cursor_moved((x + 600.0, y + 300.0), now);
    frames(&mut s, &mut now, 100.0);
    s.cursor_moved((x, y), now);
    frames(&mut s, &mut now, 900.0);
    assert_eq!(
        tip(&mut s, now).as_deref(),
        Some(label),
        "back on the row it returns"
    );
}

#[test]
fn a_click_that_opens_another_section_keeps_the_help_tag_hidden() {
    click_row_and_rest("Filme", 1);
    click_row_and_rest("Serien", 2);
}

#[test]
fn a_click_on_the_open_section_keeps_the_help_tag_hidden() {
    click_row_and_rest("Start", 0);
}
