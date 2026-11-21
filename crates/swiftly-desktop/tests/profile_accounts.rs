//! The profile panel lists every account one under the other (the signed-in one as the header, the others as switch
//! rows) and a plus row at the end (the Mac's account card); a tap on a switch row picks that account.

use swiftly_desktop::settings_screen::SettingsScreen;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

#[test]
fn accounts_stand_under_each_other_with_a_plus_row_last() {
    let env = Env::new(Size::new(1280.0, 800.0), 2.0, Idiom::Desktop);
    let mut s = SettingsScreen::new(env, Cx::deterministic(), false);
    s.set_accounts(vec![
        ("Anna".into(), "https://a.example".into(), true),
        ("Ben".into(), "https://b.example".into(), false),
        ("Clara".into(), "https://c.example".into(), false),
    ]);
    let mut now = 0.0;
    for _ in 0..90 {
        now += 16.0;
        let _ = s.frame(now);
    }
    let f: Vec<[f32; 4]> = ["go:acct:1", "go:acct:2", "go:server"]
        .iter()
        .map(|k| s.frame_of(k).unwrap_or_else(|| panic!("no row {k}")))
        .collect();
    for w in f.windows(2) {
        assert!(
            w[1][1] >= w[0][1] + w[0][3] - 1.0,
            "rows overlap or stand side by side: {w:?}"
        );
        assert!(
            (w[1][0] - w[0][0]).abs() < 1.0,
            "rows do not share a left edge: {w:?}"
        );
    }
    assert!(
        s.frame_of("go:accounts").is_none(),
        "the old 'switch account' row is gone"
    );
    let (x, y) = (f[0][0] + f[0][2] / 2.0, f[0][1] + f[0][3] / 2.0);
    s.touch_down(x, y, now);
    s.touch_up(x, y, now + 60.0);
    for _ in 0..10 {
        now += 16.0;
        let _ = s.frame(now);
    }
    assert_eq!(
        s.take_picked(),
        Some(1),
        "a tap on the first switch row picks that account"
    );
}

/// The Mac's card: the signed-in account heads it (not a switch row), every other account says how to switch.
#[test]
fn the_signed_in_account_heads_the_card_and_the_others_offer_a_switch() {
    let env = Env::new(Size::new(1280.0, 800.0), 2.0, Idiom::Desktop);
    let mut s = SettingsScreen::new(env, Cx::deterministic(), false);
    s.set_accounts(vec![
        ("Anna".into(), "https://a.example".into(), false),
        ("Ben".into(), "https://b.example".into(), true),
        ("Clara".into(), "https://c.example".into(), false),
    ]);
    let mut now = 0.0;
    for _ in 0..90 {
        now += 16.0;
        let _ = s.frame(now);
    }
    let nodes = s.a11y_nodes();
    let hint = |n: &str| {
        nodes
            .iter()
            .filter(|x| x.label.contains(n) && x.label.contains("Klicken zum Wechseln"))
            .count()
    };
    assert_eq!(hint("Anna"), 1, "Anna is offered as a switch");
    assert_eq!(hint("Clara"), 1, "Clara is offered as a switch");
    assert_eq!(
        hint("Ben"),
        0,
        "the signed-in account carries no switch hint"
    );
    // The header is the first thing in the card, above the other accounts, whatever their order in the list.
    assert!(
        s.frame_of("go:acct:1").is_none(),
        "the header is no switch row"
    );
    let y = |k: &str| s.frame_of(k).map(|f| f[1]);
    assert!(
        y("go:acct:0")
            .zip(y("go:acct:2"))
            .is_some_and(|(a, c)| a < c),
        "the other accounts keep their order"
    );
}
