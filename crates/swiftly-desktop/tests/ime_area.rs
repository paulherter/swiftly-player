//! The input method's anchor: the candidate window sits at the caret or the composition of the field in front (window
//! points), the input method is closed without a field, and a password field says so.

use swiftly_desktop::browse::Scenario;
use swiftly_desktop::login_screen::{LoginScreen, Start};
use swiftly_desktop::search_screen::SearchScreen;
use swiftly_layout::Size;
use swiftly_text::TextInputEvent as E;
use swiftly_ui::{Cx, Env, Idiom};

fn env() -> Env {
    Env::new(Size::new(1100.0, 760.0), 1.0, Idiom::Desktop)
}

fn search() -> SearchScreen {
    let mut s = SearchScreen::new(env(), Cx::deterministic(), Scenario::Ready, &[]);
    let _ = s.frame(0.0);
    s
}

fn settle(s: &mut SearchScreen, now: f64) {
    let _ = s.frame(now);
    let _ = s.frame(now + 16.0);
}

#[test]
fn search_is_closed_without_focus_and_open_with_it() {
    let mut s = search();
    let st = s.ime_state();
    assert!(!st.allowed && st.area.is_none());
    s.text_event(&E::Text("a".into()));
    settle(&mut s, 100.0);
    let st = s.ime_state();
    assert!(st.allowed && !st.password && st.area.is_some());
    s.unfocus();
    settle(&mut s, 200.0);
    assert!(!s.ime_state().allowed);
}

#[test]
fn the_anchor_follows_the_caret_and_the_composition() {
    let mut s = search();
    s.text_event(&E::Text("ab".into()));
    settle(&mut s, 100.0);
    let at_caret = s.ime_state().area.unwrap();
    s.text_event(&E::Text("cdef".into()));
    settle(&mut s, 200.0);
    let further = s.ime_state().area.unwrap();
    assert!(
        further[0] > at_caret[0] + 10.0,
        "caret moved right: {at_caret:?} -> {further:?}"
    );
    assert!((further[1] - at_caret[1]).abs() < 0.5 && further[3] > 10.0);
    // A composition: the anchor is the preedit, so it is wider than a caret and starts where the preedit starts.
    s.text_event(&E::Preedit {
        text: "にほんご".into(),
        cursor: None,
    });
    settle(&mut s, 300.0);
    let preedit = s.ime_state().area.unwrap();
    assert!(preedit[2] > 20.0, "preedit width {preedit:?}");
    assert!(
        (preedit[0] - further[0]).abs() < 1.5,
        "preedit starts at the caret: {preedit:?} vs {further:?}"
    );
    // Commit: back to a caret, after the committed text.
    s.text_event(&E::Commit("日本語".into()));
    settle(&mut s, 400.0);
    let after = s.ime_state().area.unwrap();
    assert!(after[2] < 3.0 && after[0] > preedit[0], "{after:?}");
    assert_eq!(s.text(), "abcdef日本語");
}

#[test]
fn the_anchor_lies_inside_the_search_field_of_the_window() {
    let mut s = search();
    s.text_event(&E::Text("x".into()));
    settle(&mut s, 100.0);
    let [x, y, w, h] = s.ime_state().area.unwrap();
    assert!(
        x > 200.0 && x < 700.0,
        "x {x}: right of the sidebar, left of the field's end"
    );
    assert!(y > 0.0 && y + h < 300.0 && w > 0.0, "y {y} h {h}");
}

#[test]
fn sign_in_fields_open_the_input_method_and_the_password_says_so() {
    let mut l = LoginScreen::new(env(), Cx::deterministic(), Start::Address);
    let _ = l.frame(0.0);
    let _ = l.frame(16.0);
    let st = l.ime_state();
    assert!(st.allowed && !st.password && st.area.is_some(), "{st:?}");
    let first = st.area.unwrap();
    l.type_text("jellyfin.example.org");
    l.submit();
    l.type_text("paul");
    let _ = l.frame(100.0);
    let _ = l.frame(116.0);
    let user = l.ime_state();
    assert!(user.allowed && !user.password, "{user:?}");
    assert!(
        user.area.unwrap()[0] > first[0] + 15.0,
        "the user caret sits after 'paul': {first:?} vs {user:?}"
    );
}

#[test]
fn sign_in_composition_is_shown_and_committed() {
    let mut l = LoginScreen::new(env(), Cx::deterministic(), Start::Address);
    let _ = l.frame(0.0);
    let _ = l.frame(16.0);
    let before = l.ime_state().area.unwrap();
    l.set_preedit("かんじ");
    let _ = l.frame(100.0);
    let _ = l.frame(116.0);
    let during = l.ime_state().area.unwrap();
    assert!(
        during[0] > before[0] + 20.0,
        "the composition is drawn, the caret follows it: {before:?} -> {during:?}"
    );
    l.type_text("漢字");
    let _ = l.frame(200.0);
    let _ = l.frame(216.0);
    let after = l.ime_state().area.unwrap();
    assert!(
        after[0] > before[0] + 10.0 && after[0] < during[0] + 1.0,
        "committed text replaces the composition"
    );
}
