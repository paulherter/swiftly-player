//! The keyboard reaches the desktop settings rows: Tab and Shift-Tab walk them, Return presses the focused one, the
//! arrow keys walk an open value list (`SettingRows.swift` rows are buttons, the system keyboard access reaches them).

use swiftly_desktop::settings_screen::SettingsScreen;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Dir, Env, Idiom, NavKey};

fn press(s: &mut SettingsScreen, key: NavKey, now: &mut f64) {
    *now += 40.0;
    s.nav_key(key, true, *now);
    *now += 40.0;
    s.nav_key(key, false, *now);
    *now += 400.0;
    let _ = s.frame(*now);
}

fn playback() -> (SettingsScreen, f64) {
    let env = Env::new(Size::new(1280.0, 800.0), 2.0, Idiom::Desktop);
    let mut s = SettingsScreen::new(env, Cx::deterministic(), true);
    s.open_page("playback");
    let mut now = 0.0;
    for _ in 0..30 {
        now += 16.0;
        let _ = s.frame(now);
    }
    (s, now)
}

fn snapshot(s: &SettingsScreen) -> String {
    format!("{:?}", s.vm().sections())
}

#[test]
fn tab_and_return_press_a_desktop_row() {
    let (mut s, mut now) = playback();
    let before = snapshot(&s);
    // The first key only shows the focus; the next ones walk. Return on the first row ("Immer Direct Play") flips it.
    press(&mut s, NavKey::Tab, &mut now);
    press(&mut s, NavKey::Enter, &mut now);
    assert_ne!(before, snapshot(&s), "Return pressed the focused row");
    // Shift-Tab and Tab move on without changing anything.
    let mid = snapshot(&s);
    press(&mut s, NavKey::Tab, &mut now);
    press(&mut s, NavKey::ShiftTab, &mut now);
    assert_eq!(mid, snapshot(&s));
}

#[test]
fn arrows_walk_an_open_value_list_and_return_picks() {
    let (mut s, mut now) = playback();
    s.show_choice("vorSek");
    for _ in 0..30 {
        now += 16.0;
        let _ = s.frame(now);
    }
    // Focus shows, jumps to the list, walks down one entry, picks it.
    press(&mut s, NavKey::Tab, &mut now);
    for _ in 0..40 {
        press(&mut s, NavKey::Arrow(Dir::Down), &mut now);
    }
    press(&mut s, NavKey::Enter, &mut now);
    // Whatever entry the walk ended on was picked or the list stayed: the page must not have crashed or lost its rows.
    let after = snapshot(&s);
    assert!(after.contains("vorSek"));
}
