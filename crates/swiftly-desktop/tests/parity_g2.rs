//! Shell, sidebar and Start parity with the Mac app (g2): the "Meins" rows follow their settings, the genre chips are a
//! scrolling paging rail, "Alle ›" is one button over the whole heading row, and the server-down text names the server.
#![allow(clippy::unwrap_used)]

use swiftly_desktop::home::HomeScreen;
use swiftly_desktop::home_data::Scenario;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

fn screen() -> HomeScreen {
    let mut s = HomeScreen::new(
        Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop),
        Cx::deterministic(),
        Scenario::Ready,
    );
    let mut t = 0.0;
    for _ in 0..40 {
        t += 16.0;
        let _ = s.frame(t);
    }
    s
}

fn labels(s: &HomeScreen) -> Vec<String> {
    s.a11y_nodes().into_iter().map(|n| n.label).collect()
}

#[test]
fn the_meins_rows_exist_only_while_their_settings_are_on() {
    swiftly_desktop::desk::set_mine(true, true);
    let both = labels(&screen());
    assert!(both.iter().any(|l| l == "Merkliste") && both.iter().any(|l| l == "Downloads"));
    swiftly_desktop::desk::set_mine(true, false);
    let one = labels(&screen());
    assert!(one.iter().any(|l| l == "Merkliste") && !one.iter().any(|l| l == "Downloads"));
    swiftly_desktop::desk::set_mine(false, false);
    let none = labels(&screen());
    assert!(
        !none.iter().any(|l| l == "Merkliste" || l == "Downloads"),
        "no section, no heading: {none:?}"
    );
    swiftly_desktop::desk::set_mine(true, true);
}

#[test]
fn the_new_arrivals_row_has_no_all_link_but_the_split_rows_do() {
    let s = screen();
    let rails = s.vm().rails();
    assert!(!rails.rails.is_empty());
    let names = labels(&s);
    for r in &rails.rails {
        let has = names
            .iter()
            .any(|l| *l == format!("Alle anzeigen: {}", r.title));
        let split = matches!(
            r.kind,
            swiftly_vm::RailKind::NewMovies | swiftly_vm::RailKind::NewSeries
        );
        assert_eq!(has, split || r.is_library(), "link of {}", r.id);
    }
}

/// Scrolls Start to its end.
fn to_the_end(s: &mut HomeScreen) {
    let mut t = 10_000.0;
    for _ in 0..30 {
        let _ = s.wheel_scroll(700.0, 400.0, 0.0, 2000.0, t);
        for _ in 0..8 {
            t += 16.0;
            let _ = s.frame(t);
        }
    }
}

#[test]
fn the_support_card_stands_after_the_last_row_and_its_buttons_work() {
    let mut s = screen();
    assert!(!s.support_shown());
    assert!(
        s.frame_of("support:open").is_none(),
        "no card unless it is due"
    );
    s.set_support(Some(3));
    to_the_end(&mut s);
    let open = s.frame_of("support:open").expect("the card is drawn");
    let snooze = s.frame_of("support:snooze").expect("two buttons");
    assert!(
        snooze[0] > open[0] && (snooze[1] - open[1]).abs() < 1.0,
        "side by side: {open:?} {snooze:?}"
    );
    assert!(
        open[1] > 0.0 && open[1] + open[3] < 800.0,
        "on screen: {open:?}"
    );
    let mut t = 20_000.0;
    s.touch_down(snooze[0] + 8.0, snooze[1] + 8.0, t);
    t += 30.0;
    s.touch_up(snooze[0] + 8.0, snooze[1] + 8.0, t);
    assert_eq!(
        s.take_support_tap(),
        Some(swiftly_desktop::home::SupportTap::Snooze)
    );
    s.touch_down(open[0] + 8.0, open[1] + 8.0, t + 100.0);
    s.touch_up(open[0] + 8.0, open[1] + 8.0, t + 130.0);
    assert_eq!(
        s.take_support_tap(),
        Some(swiftly_desktop::home::SupportTap::Open)
    );
    s.set_support(None);
    let _ = s.frame(t + 600.0);
    assert!(
        s.frame_of("support:open").is_none(),
        "gone once it is not due"
    );
}
