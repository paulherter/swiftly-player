//! Focusing the search field must not move anything else on the page: the content keeps its resting position
//! (iOS: a header that shrank on focus shifted the results by one title row in a single step).
#![allow(clippy::unwrap_used, clippy::expect_used)]

use swiftly_desktop::browse::Scenario;
use swiftly_desktop::search_screen::SearchScreen;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

fn run(idiom: Idiom, size: Size) {
    let mut s = SearchScreen::new(
        Env::new(size, 1.0, idiom),
        Cx::deterministic(),
        Scenario::Ready,
        &["alpha", "beta"],
    );
    let mut now = 0.0;
    for _ in 0..5 {
        now += 16.0;
        let _ = s.frame(now);
    }
    let field = s.frame_of("field").expect("field");
    let row = s.frame_of("recent:0").expect("recent row");
    s.focus();
    // Every frame of the focus animation: neither the field nor the row below it moves.
    for _ in 0..60 {
        now += 16.0;
        let _ = s.frame(now);
        assert_eq!(
            s.frame_of("field").unwrap(),
            field,
            "{idiom:?} field moved on focus"
        );
        assert_eq!(
            s.frame_of("recent:0").unwrap(),
            row,
            "{idiom:?} content moved on focus"
        );
    }
}

#[test]
fn desktop_content_stays_put_when_the_field_is_focused() {
    run(Idiom::Desktop, Size::new(1100.0, 760.0));
}

#[test]
fn phone_content_stays_put_when_the_field_is_focused() {
    run(Idiom::Phone, Size::new(390.0, 844.0));
}
