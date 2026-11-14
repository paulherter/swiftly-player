//! A library page that found the server unreachable asks again by itself (the server may come back while the window
//! stays in front); the user's own "Erneut versuchen" stays as it is.
#![allow(clippy::unwrap_used)]

use swiftly_desktop::browse::Scenario;
use swiftly_desktop::library_screen::{Kind, LibraryScreen};
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

#[test]
fn an_offline_library_asks_again_with_growing_pauses() {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = LibraryScreen::new(env, Cx::deterministic(), &Kind::Movies, Scenario::Offline);
    let _ = s.frame(0.0);
    let _ = s.frame(2_900.0);
    assert_eq!(s.auto_retries(), 0, "not before 3 s");
    let _ = s.frame(3_100.0);
    assert_eq!(s.auto_retries(), 1);
    let _ = s.frame(8_000.0);
    assert_eq!(s.auto_retries(), 1, "the second pause is 6 s");
    let _ = s.frame(9_200.0);
    assert_eq!(s.auto_retries(), 2);
    let _ = s.frame(21_300.0);
    assert_eq!(s.auto_retries(), 3, "then 12 s");
}

#[test]
fn a_page_with_titles_never_retries_by_itself() {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = LibraryScreen::new(env, Cx::deterministic(), &Kind::Movies, Scenario::Ready);
    for t in 0..40 {
        let _ = s.frame(f64::from(t) * 1000.0);
    }
    assert_eq!(s.auto_retries(), 0);
}
