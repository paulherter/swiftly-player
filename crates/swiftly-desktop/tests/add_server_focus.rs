//! Settings > "Server hinzufügen": the address field has the keyboard on arrival, through the real pointer and text
//! path of the suite (tap the row, tap the Jellyfin card, then type).

use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

fn settle(s: &mut Suite, now: &mut f64, ms: f64) {
    let end = *now + ms;
    while *now < end {
        *now += 16.0;
        let _ = s.frame(*now);
    }
}

fn tap(s: &mut Suite, now: &mut f64, key: &str) {
    let f = s
        .top_frame_of(key)
        .unwrap_or_else(|| panic!("no control {key}"));
    let (x, y) = (f[0] + f[2] * 0.5, f[1] + f[3] * 0.5);
    s.pointer_move(x, y, *now);
    s.touch_down(x, y, *now);
    *now += 60.0;
    s.touch_up(x, y, *now);
    settle(s, now, 700.0);
}

#[test]
fn add_server_address_field_has_the_keyboard_on_arrival() {
    let env = Env::new(Size::new(1280.0, 800.0), 2.0, Idiom::Desktop);
    let mut s = Suite::new(env, Cx::deterministic());
    let mut now = 0.0;
    settle(&mut s, &mut now, 200.0);
    assert!(s.open_settings(now));
    settle(&mut s, &mut now, 1500.0);
    tap(&mut s, &mut now, "go:server");
    assert_eq!(s.form_open(), Some("login"), "the add flow opened");
    assert!(!s.wants_text(), "the kind picker has no text field");
    tap(&mut s, &mut now, "kind:0");
    assert!(s.wants_text(), "the address step takes text");
    assert!(
        s.ime_state().allowed,
        "the input method opens over the address field"
    );
    assert_eq!(
        s.login_address().map(|a| a.1),
        Some(true),
        "focused before any typing"
    );
    s.type_text("jelly.example.org");
    settle(&mut s, &mut now, 100.0);
    let (text, focused) = s.login_address().expect("sign-in page");
    assert_eq!(
        text, "jelly.example.org",
        "typed text lands in the address field"
    );
    assert!(focused, "the address field shows the keyboard");
}
