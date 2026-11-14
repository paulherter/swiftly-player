//! The strip at the bottom of the content (the Mac's `TileMessageStrip`): a refused plan says itself there, and a click or
//! four seconds withdraws it. No window, software renderer, fixed clock.

use swiftly_desktop::suite::{Suite, plan_refused_text};
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

fn suite() -> Suite {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = Suite::new(env, Cx::deterministic());
    for i in 1..=20 {
        let _ = s.frame(f64::from(i) * 16.0);
    }
    s
}

#[test]
fn the_refusal_names_the_server_like_the_mac() {
    assert_eq!(
        plan_refused_text(Some("jf.example:8096")),
        "Die Wiedergabe hat nicht geklappt. Von jf.example:8096 kamen keine Daten zum Abspielen."
    );
    assert_eq!(
        plan_refused_text(None),
        "Die Wiedergabe hat nicht geklappt. Von dem Server kamen keine Daten zum Abspielen."
    );
}

#[test]
fn the_strip_shows_in_the_main_view_and_goes_after_four_seconds() {
    let mut s = suite();
    let plain = s.frame(400.0).0;
    s.show_hint("Die Wiedergabe hat nicht geklappt.", 500.0);
    assert!(s.hint_text().is_some());
    assert!(!s.player_open(), "no player opens for a refused plan");
    let shown = s.frame(900.0).0;
    assert!(
        shown.quads().len() > plain.quads().len(),
        "the strip is drawn over the page"
    );
    let _ = s.frame(4300.0);
    assert!(s.hint_text().is_some(), "still there before four seconds");
    let _ = s.frame(4600.0);
    assert!(s.hint_text().is_none(), "withdrawn after four seconds");
}

#[test]
fn a_click_on_the_strip_withdraws_it() {
    let mut s = suite();
    s.show_hint("Die Wiedergabe hat nicht geklappt.", 500.0);
    let _ = s.frame(900.0);
    // Bottom centre of the content column (the sidebar takes the left 220 pt), 20 pt above the edge, 34 high.
    s.touch_down(750.0, 763.0, 1000.0);
    s.touch_up(750.0, 763.0, 1040.0);
    assert!(s.hint_text().is_none());
}

#[test]
fn the_discord_card_comes_after_the_delay_and_the_x_closes_it() {
    let mut s = suite();
    s.queue_nudge(swiftly_vm::Nudge::Discord, 1000.0);
    let _ = s.frame(2000.0);
    assert!(!s.discord_card_open(), "not before 1.5 s");
    let _ = s.frame(2600.0);
    assert!(s.discord_card_open());
    let _ = s.frame(2900.0);
    // The X at the top right of the 320 pt card, 20 pt in from the corner of the content.
    s.touch_down(1232.0, 632.0, 3000.0);
    s.touch_up(1232.0, 632.0, 3040.0);
    assert!(!s.discord_card_open());
}

#[test]
fn the_group_error_stacks_above_the_tile_message_and_each_goes_on_its_own() {
    let mut s = suite();
    s.show_hint("Die Wiedergabe hat nicht geklappt.", 500.0);
    s.show_shared_error("Die Gruppe ist nicht mehr erreichbar.", 600.0);
    let one = {
        let mut t = suite();
        t.show_hint("Die Wiedergabe hat nicht geklappt.", 500.0);
        t.frame(900.0).0.quads().len()
    };
    let both = s.frame(900.0).0.quads().len();
    assert!(both > one, "two capsules are drawn: {one} < {both}");
    assert!(s.hint_text().is_some() && s.shared_error_text().is_some());
    // The tile strip sits at the bottom (746..780), the group error 10 pt above it (702..736).
    s.touch_down(750.0, 763.0, 1000.0);
    s.touch_up(750.0, 763.0, 1040.0);
    assert!(s.hint_text().is_none(), "the click withdrew the tile strip");
    assert!(s.shared_error_text().is_some(), "and only that one");
    // Each strip has its own four seconds: the group error came 100 ms later.
    let _ = s.frame(4550.0);
    assert!(s.shared_error_text().is_some());
    let _ = s.frame(4700.0);
    assert!(s.shared_error_text().is_none());
}

/// A page that cannot start a play (a placeholder title) posts the words; the suite shows them in the strip at the bottom
/// of the content on its next frame, and the page itself draws nothing for it.
#[test]
fn a_hint_posted_by_a_page_shows_in_the_strip() {
    let mut s = suite();
    assert!(s.hint_text().is_none());
    swiftly_desktop::desk::post_hint(plan_refused_text(None));
    let (_, more) = s.frame(500.0);
    assert!(more, "the suite asks for another frame to draw it");
    assert_eq!(s.hint_text(), Some(plan_refused_text(None).as_str()));
}
