//! The profile panel lists every account one under the other, the active one ticked, and a plus row at the end (the
//! Mac's account card), and taps on an account row pick that account.

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
    let f: Vec<[f32; 4]> = ["go:acct:0", "go:acct:1", "go:acct:2", "go:server"]
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
    let (x, y) = (f[1][0] + f[1][2] / 2.0, f[1][1] + f[1][3] / 2.0);
    s.touch_down(x, y, now);
    s.touch_up(x, y, now + 60.0);
    for _ in 0..10 {
        now += 16.0;
        let _ = s.frame(now);
    }
    assert_eq!(
        s.take_picked(),
        Some(1),
        "a tap on the second account row picks it"
    );
}
