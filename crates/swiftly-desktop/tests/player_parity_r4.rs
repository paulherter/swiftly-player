//! Player parity with the Mac, round 4: the technical overlay follows the `technikschild` setting.
#![allow(clippy::unwrap_used)]

use std::sync::Arc;
use swiftly_desktop::player_screen::{PlayerScenario, PlayerScreen};
use swiftly_layout::Size;
use swiftly_settings::{JsonFileStore, KeyValueStore, Value};
use swiftly_ui::{Cx, Env, Idiom};

fn screen_with(tag: &str, technikschild: Option<bool>) -> PlayerScreen {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = PlayerScreen::new(env, Cx::deterministic(), PlayerScenario::Playing, 0.0);
    let _ = s.frame(0.0);
    let dir = std::env::temp_dir().join(format!("r4-{tag}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let store = Arc::new(JsonFileStore::open(dir.join("settings.json")).unwrap());
    if let Some(on) = technikschild {
        store.set("technikschild", Value::Bool(on)).unwrap();
    }
    s.set_store(store, 0.0);
    for t in 1..30 {
        let _ = s.frame(f64::from(t) * 16.0);
    }
    s
}

/// The Mac reads `@AppStorage("technikschild")`; the desktop player never read the key, so a saved "on" showed nothing
/// (round 1 and 3 measured a settings file with the key set and no overlay).
#[test]
fn a_saved_technikschild_shows_the_overlay_and_no_setting_hides_it() {
    let on = screen_with("on", Some(true));
    assert!(
        on.frame_of("tech-badge").is_some(),
        "the overlay is missing"
    );
    let off = screen_with("off", Some(false));
    assert!(off.frame_of("tech-badge").is_none());
    let unset = screen_with("unset", None);
    assert!(unset.frame_of("tech-badge").is_none());
}
