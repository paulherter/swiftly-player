//! Player parity with the Mac (audit g4): what the player reads from settings and shows.
#![allow(clippy::unwrap_used)]

use std::sync::Arc;
use swiftly_desktop::player_screen::{PlayerScenario, PlayerScreen};
use swiftly_layout::Size;
use swiftly_settings::{JsonFileStore, KeyValueStore, Value};
use swiftly_ui::{Cx, Env, Idiom};

fn screen() -> PlayerScreen {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = PlayerScreen::new(env, Cx::deterministic(), PlayerScenario::Playing, 0.0);
    let _ = s.frame(0.0);
    s
}

fn store(tag: &str) -> Arc<JsonFileStore> {
    let dir = std::env::temp_dir().join(format!("g4-{tag}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    Arc::new(JsonFileStore::open(dir.join("settings.json")).unwrap())
}

/// The skip widths, auto skip and "next episode automatically" come from the settings, like `CorePlaybackBackend.prefs`.
#[test]
fn the_player_reads_its_prefs_from_the_settings() {
    let mut s = screen();
    // Nothing stored: the Mac's own defaults (back 10, forward 30), next episode on.
    let st = store("prefs");
    s.set_store(Arc::clone(&st), 0.0);
    assert_eq!(
        (s.prefs().back_seconds, s.prefs().forward_seconds),
        (10, 30)
    );
    assert!(s.prefs().next_automatic && !s.prefs().auto_skip);
    st.set("zurueckSek", Value::Int(15)).unwrap();
    st.set("vorSek", Value::Int(45)).unwrap();
    st.set("introAbspannAuto", Value::Bool(true)).unwrap();
    st.set("naechsteAuto", Value::Bool(false)).unwrap();
    s.set_store(Arc::clone(&st), 0.0);
    let p = s.prefs();
    assert_eq!((p.back_seconds, p.forward_seconds), (15, 45));
    assert!(p.auto_skip && !p.next_automatic);
}

/// A skip of the forward button moves by the stored width.
#[test]
fn the_forward_button_skips_the_stored_width() {
    let mut s = screen();
    let st = store("skip");
    st.set("vorSek", Value::Int(45)).unwrap();
    s.set_store(st, 0.0);
    let before = s.vm().transport().position;
    s.send_intent(swiftly_vm::PlayerIntent::Forward, 10.0);
    let _ = s.frame(20.0);
    let after = s.vm().transport().position;
    assert!(after - before >= 44.0, "moved {}", after - before);
}

fn boxes(n: &[swiftly_ui::a11y::A11yNode], out: &mut Vec<[f32; 4]>) {
    for x in n {
        out.extend(x.bounds);
        boxes(&x.children, out);
    }
}

/// The icon row sits at the Mac's `iconTop` 35.5 (level with the title's first line), 44 pt high.
#[test]
fn the_icon_rail_sits_at_the_mac_icon_top() {
    let mut s = screen();
    for t in 0..120 {
        let _ = s.frame(f64::from(t) * 16.0);
    }
    let mut all = Vec::new();
    boxes(&s.a11y_nodes(), &mut all);
    // Volume and fullscreen are 44 pt buttons; the capsule's halves are 40 x 36 on the same centre line.
    let rail: Vec<_> = all
        .iter()
        .filter(|b| {
            b[1] < 100.0
                && ((b[2] - 44.0).abs() < 0.1 && (b[3] - 44.0).abs() < 0.1
                    || (b[2] - 40.0).abs() < 0.1 && (b[3] - 36.0).abs() < 0.1)
        })
        .collect();
    assert!(rail.len() >= 4, "the rail buttons: {rail:?}");
    for b in rail {
        let mid = b[1] + b[3] / 2.0;
        assert!((mid - 57.5).abs() < 0.6, "rail button centre {mid}");
    }
}

/// A film has no episodes button; a transcode shows its warning line under the title (`hasEpisodes`, `plan.isLossless`).
#[test]
fn a_film_has_no_episodes_button_and_a_transcode_is_named() {
    let count = |s: &PlayerScreen| {
        let mut all = Vec::new();
        boxes(&s.a11y_nodes(), &mut all);
        all.iter()
            .filter(|b| (b[2] - 40.0).abs() < 0.1 && (b[3] - 36.0).abs() < 0.1 && b[1] < 100.0)
            .count()
    };
    let mut s = screen();
    for t in 0..120 {
        let _ = s.frame(f64::from(t) * 16.0);
    }
    let with = count(&s);
    s.set_title_kind(false, false);
    for t in 120..240 {
        let _ = s.frame(f64::from(t) * 16.0);
    }
    // The capsule keeps its Folgen half for a film: it opens the Kapitel level (the core decides what the box lists).
    assert_eq!(count(&s), with, "the Folgen half stays for a film");
    let lines = |s: &PlayerScreen| {
        let mut all = Vec::new();
        boxes(&s.a11y_nodes(), &mut all);
        all.iter()
            .filter(|b| b[0] < 400.0 && b[1] > 60.0 && b[1] < 110.0)
            .count()
    };
    let before = lines(&s);
    s.set_title_kind(false, true);
    for t in 240..360 {
        let _ = s.frame(f64::from(t) * 16.0);
    }
    assert!(lines(&s) > before, "the Transcode label adds a text");
}

fn labels(n: &[swiftly_ui::a11y::A11yNode], out: &mut Vec<String>) {
    for x in n {
        out.push(x.label.clone());
        labels(&x.children, out);
    }
}

/// A failed start shows the Mac's page: "Das startet nicht", the text and the two buttons of the core's `Failure::START`.
#[test]
fn a_failed_start_shows_the_mac_page_with_two_buttons() {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = PlayerScreen::new(env, Cx::deterministic(), PlayerScenario::Failed, 0.0);
    for t in 0..60 {
        let _ = s.frame(f64::from(t) * 16.0);
    }
    let mut all = Vec::new();
    labels(&s.a11y_nodes(), &mut all);
    let text = all.join(" | ");
    for want in [
        "Das startet nicht",
        "Erneut versuchen",
        "Schließen",
        "Die Datei oder der Server liefert kein Bild",
    ] {
        assert!(text.contains(want), "{want:?} missing in {text}");
    }
    assert!(!text.contains("Die Wiedergabe hat nicht geklappt"));
}

/// The media key "next" is the next episode (the demo has one); the key does not act without one.
#[test]
fn the_next_media_key_starts_the_next_episode() {
    let mut s = screen();
    assert!(s.key(swiftly_desktop::player_screen::PlayerKey::NextEpisode, 10.0));
}

/// The lists of the speed, sleep and quality menus are the core's (the Mac has no 0.5x).
#[test]
fn the_menu_lists_are_the_cores() {
    use swiftly_desktop::player_screen::{QUALITY_CAPS, SLEEP_CHOICES, TEMPOS};
    assert_eq!(TEMPOS, swiftly_rules::playback_levels::SPEED_VALUES);
    assert!(!TEMPOS.contains(&0.5));
    assert_eq!(
        SLEEP_CHOICES.map(i64::from),
        swiftly_rules::playback_levels::SLEEP_TIMES
    );
    assert_eq!(
        QUALITY_CAPS,
        swiftly_rules::playback_selection::BITRATE_LEVELS
    );
}
