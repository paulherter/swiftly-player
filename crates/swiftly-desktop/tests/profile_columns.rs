//! The profile page keeps its two columns when the window is narrower than 964 points (the Mac's `HStack` of two
//! columns that shrink), and a really narrow window stacks them with the gap every other card has.
#![allow(clippy::unwrap_used)]

use swiftly_desktop::settings_screen::SettingsScreen;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

fn profile(w: f32) -> SettingsScreen {
    let env = Env::new(Size::new(w, 900.0), 1.25, Idiom::Desktop);
    let mut s = SettingsScreen::new(env, Cx::deterministic(), false);
    let mut now = 0.0;
    for _ in 0..60 {
        now += 16.0;
        let _ = s.frame(now);
    }
    s
}

#[test]
fn a_page_800_points_wide_keeps_two_columns() {
    let s = profile(800.0);
    let left = s.frame_of("go:settings").unwrap();
    let right = s.frame_of("go:signout").unwrap();
    assert!(
        right[0] >= left[0] + left[2] + 20.0,
        "the second column stands beside the first, not below it: {left:?} {right:?}"
    );
}

#[test]
fn a_really_narrow_page_stacks_the_columns_with_a_gap() {
    let s = profile(480.0);
    let left = s.frame_of("go:settings").unwrap();
    let right = s.frame_of("go:signout").unwrap();
    assert!(
        (left[0] - right[0]).abs() < 1.0,
        "one column: {left:?} {right:?}"
    );
    assert!(
        right[1] - (left[1] + left[3]) >= 18.0,
        "the cards are 18 points apart at least: {left:?} {right:?}"
    );
}
