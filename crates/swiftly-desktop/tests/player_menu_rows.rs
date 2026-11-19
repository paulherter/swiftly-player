//! The player menu's speed and subtitle-offset rows on the desktop come from the shared core (`PlayerVm::menu`):
//! the screen draws the rows the core lists and a press sends the core's intent (no list of its own).
#![allow(clippy::unwrap_used)]

use swiftly_desktop::player_screen::{PlayerKey, PlayerScenario, PlayerScreen};
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};
use swiftly_vm::{PlayerIntent, PlayerLayer};

fn screen(idiom: Idiom, size: (f32, f32)) -> PlayerScreen {
    let env = Env::new(Size::new(size.0, size.1), 1.0, idiom);
    let mut s = PlayerScreen::new(env, Cx::deterministic(), PlayerScenario::Playing, 0.0);
    let _ = s.frame(0.0);
    s
}

/// Runs a few frames so the layer is built and settled.
fn settle(s: &mut PlayerScreen, from: f64) -> f64 {
    let mut now = from;
    for _ in 0..40 {
        now += 16.0;
        let _ = s.frame(now);
    }
    now
}

#[test]
fn the_settings_layer_lists_the_cores_speeds_and_a_press_sets_the_speed() {
    for (idiom, size) in [
        (Idiom::Desktop, (1280.0, 800.0)),
        (Idiom::Phone, (844.0, 390.0)),
    ] {
        let mut s = screen(idiom, size);
        let mut now = settle(&mut s, 0.0);
        s.send_intent(PlayerIntent::Layer(Some(PlayerLayer::Settings)), now);
        now = settle(&mut s, now);
        // Every form shows the core's Optionen in a box under the capsule; the arrows walk it, Return presses:
        // Geschwindigkeit opens the speeds, the fourth row (0.75, 1, 1.25, 1.5) sets 1.5.
        assert!(
            s.frame_of("pm-box").is_some(),
            "{idiom:?}: the box hangs under the capsule"
        );
        assert!(s.key(PlayerKey::Down, now));
        assert!(s.key(PlayerKey::Enter, now));
        for _ in 0..4 {
            assert!(s.key(PlayerKey::Down, now));
        }
        assert!(s.key(PlayerKey::Enter, now));
        assert!(
            (s.vm().transport().tempo - 1.5).abs() < 1e-3,
            "{idiom:?}: speed {}",
            s.vm().transport().tempo
        );
        assert!(s.engine_calls().contains(&"rate 1.5".to_owned()));
        let _ = now;
    }
}

#[test]
fn the_tracks_box_hangs_under_the_capsule_in_every_form() {
    for (idiom, size) in [
        (Idiom::Desktop, (1280.0, 800.0)),
        (Idiom::Phone, (844.0, 390.0)),
    ] {
        let mut s = screen(idiom, size);
        let mut now = settle(&mut s, 0.0);
        s.send_intent(PlayerIntent::Layer(Some(PlayerLayer::Tracks)), now);
        now = settle(&mut s, now);
        // Every form shows the core's Ton und Untertitel in the box under the capsule.
        assert!(
            s.frame_of("pm-box").is_some(),
            "{idiom:?}: the box hangs under the capsule"
        );
        let _ = now;
    }
}
