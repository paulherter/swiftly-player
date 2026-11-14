//! The player window moves by its background, like the Mac's: a press on nothing that travels past the slop asks the host to
//! move the window; a tap on nothing still only wakes the controls; a press on a control, the bar or a layer never moves it.
#![allow(clippy::unwrap_used)]

use swiftly_desktop::player_screen::{PlayerScenario, PlayerScreen};
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};
use swiftly_vm::{PlayerIntent, PlayerLayer};

const STEP: f64 = 1000.0 / 60.0;

fn screen() -> (PlayerScreen, f64) {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = PlayerScreen::new(env, Cx::deterministic(), PlayerScenario::Playing, 0.0);
    let mut now = 0.0;
    for _ in 0..90 {
        now += STEP;
        let _ = s.frame(now);
    }
    (s, now)
}

fn drag(s: &mut PlayerScreen, from: (f32, f32), by: (f32, f32), now: &mut f64) -> bool {
    s.touch_down(from.0, from.1, *now);
    let mut asked = false;
    for i in 1..=6 {
        *now += STEP;
        let f = i as f32 / 6.0;
        s.touch_move(from.0 + by.0 * f, from.1 + by.1 * f, *now);
        asked |= s.take_window_drag();
    }
    s.touch_up(from.0 + by.0, from.1 + by.1, *now);
    asked
}

#[test]
fn a_drag_of_the_bare_background_asks_to_move_the_window() {
    let (mut s, mut now) = screen();
    assert!(drag(&mut s, (640.0, 300.0), (90.0, 40.0), &mut now));
    // Along the top and in the letterbox corners as well.
    assert!(drag(&mut s, (900.0, 30.0), (-60.0, 0.0), &mut now));
    assert!(drag(&mut s, (60.0, 420.0), (0.0, 60.0), &mut now));
}

#[test]
fn a_tap_or_a_tiny_wobble_is_no_window_drag() {
    let (mut s, mut now) = screen();
    assert!(!drag(&mut s, (640.0, 300.0), (2.0, 1.0), &mut now));
    assert!(!drag(&mut s, (640.0, 300.0), (0.0, 0.0), &mut now));
}

#[test]
fn a_press_on_the_bar_or_in_a_layer_never_moves_the_window() {
    let (mut s, mut now) = screen();
    // The scrubber sits near the bottom edge, centred.
    assert!(!drag(&mut s, (640.0, 742.0), (80.0, 6.0), &mut now));
    s.send_intent(PlayerIntent::Layer(Some(PlayerLayer::Settings)), now);
    for _ in 0..40 {
        now += STEP;
        let _ = s.frame(now);
    }
    // Inside the settings layer's columns.
    assert!(!drag(&mut s, (330.0, 400.0), (0.0, -50.0), &mut now));
}
