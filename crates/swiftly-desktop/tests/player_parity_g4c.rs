//! Player parity with the Mac, round 3: the context menu of the episode cards, the transcode reason in the technical overlay.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use swiftly_desktop::player_screen::{PlayerScenario, PlayerScreen};
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

fn screen() -> PlayerScreen {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = PlayerScreen::new(env, Cx::deterministic(), PlayerScenario::Playing, 0.0);
    let _ = s.frame(0.0);
    s
}

fn run(s: &mut PlayerScreen, from: u32, to: u32) {
    for t in from..to {
        let _ = s.frame(f64::from(t) * 16.0);
    }
}

/// The Folgen box rows (`pm:{act}`) that are on screen, as window centres.
fn box_rows(s: &PlayerScreen) -> Vec<(f32, f32)> {
    (0..60)
        .filter_map(|k| s.frame_of(&format!("pm:{k}")))
        .map(|[x, y, w, h]| (x + w / 2.0, y + h / 2.0))
        .collect()
}

fn open_folgen(s: &mut PlayerScreen) {
    run(s, 0, 150);
    // The capsule's Folgen key opens the box (the controls are up after the start).
    let [x, y, w, h] = s.frame_of("folgen").expect("the capsule's Folgen key");
    s.touch_down(x + w / 2.0, y + h / 2.0, 151.0 * 16.0);
    s.touch_up(x + w / 2.0, y + h / 2.0, 152.0 * 16.0);
    run(s, 153, 300);
}

/// A right click on an episode row of the Folgen box opens the shared tile menu in its player form (`inPlayer`): only
/// the watched mark; picking it is sent and the row follows (`PlayerEpisodeStrip.swift:56`).
#[test]
fn a_right_click_on_an_episode_card_offers_the_watched_mark() {
    let mut s = screen();
    open_folgen(&mut s);
    let rows = box_rows(&s);
    assert!(rows.len() >= 3, "the Folgen box lists rows: {rows:?}");
    // The rows in order: the season caret, then the episodes; the second episode is demo-e2.
    let (mut px, mut py) = (0.0, 0.0);
    for (x, y) in rows {
        // The season caret and the tabs take no right click.
        let _ = s.secondary_click(x, y, 301.0 * 16.0);
        if s.log().iter().any(|l| l.starts_with("epmenu open")) {
            (px, py) = (x, y);
            break;
        }
    }
    assert!(
        s.log().iter().any(|l| l.starts_with("epmenu open demo-e")),
        "no menu opened: {:?}",
        s.log()
    );
    run(&mut s, 302, 330);
    // The one row ("Als gesehen markieren") sits just under the pointer, inside the panel.
    s.touch_down(px + 40.0, py + 20.0, 331.0 * 16.0);
    s.touch_up(px + 40.0, py + 20.0, 332.0 * 16.0);
    run(&mut s, 333, 360);
    assert!(
        s.log()
            .iter()
            .any(|l| l.starts_with("epmenu Watched demo-e")
                || l.starts_with("epmenu Unwatched demo-e")),
        "the pick did not run: {:?}",
        s.log()
    );
}

/// A long press on an episode row (touch, and the tv's held select button) opens the same menu.
#[test]
fn a_long_press_on_an_episode_row_offers_the_watched_mark() {
    let mut s = screen();
    open_folgen(&mut s);
    let rows = box_rows(&s);
    let mut t = 300.0 * 16.0;
    // The episodes sit below the season caret, whose tap would open the season list: try the lower rows first.
    for (x, y) in rows.into_iter().rev() {
        s.touch_down(x, y, t);
        for _ in 0..40 {
            t += 16.0;
            let _ = s.frame(t);
        }
        s.touch_up(x, y, t);
        if s.log().iter().any(|l| l.starts_with("epmenu open")) {
            break;
        }
    }
    assert!(
        s.log().iter().any(|l| l.starts_with("epmenu open demo-e")),
        "no menu opened: {:?}",
        s.log()
    );
}

/// The menu key opens it for the highlighted episode row.
#[test]
fn the_menu_key_on_an_episode_row_offers_the_watched_mark() {
    use swiftly_desktop::player_screen::PlayerKey;
    let mut s = screen();
    open_folgen(&mut s);
    let mut t = 300.0 * 16.0;
    for _ in 0..4 {
        assert!(s.key(PlayerKey::Down, t));
        t += 100.0;
        if s.key(PlayerKey::Context, t) && s.log().iter().any(|l| l.starts_with("epmenu open")) {
            break;
        }
    }
    assert!(
        s.log().iter().any(|l| l.starts_with("epmenu open demo-e")),
        "no menu opened: {:?}",
        s.log()
    );
}

/// The overlay's reason line comes from the plan's first transcode reason, in the sentence the Mac shows.
#[test]
fn the_tech_facts_carry_the_first_transcode_reason() {
    use swiftly_desktop::player_host::TechFacts;
    use swiftly_model::DeliveryMethod;
    use swiftly_playback::playback_plan::{
        PlaybackPlan, ReasonDetail, ReasonKind, TranscodeReason,
    };
    swiftly_l10n::set_locale(swiftly_l10n::Locale::parse("de"));
    let plan = |method| PlaybackPlan {
        url: "http://x/master.m3u8".into(),
        method,
        media_source_id: None,
        play_session_id: None,
        container: None,
        reasons: vec![TranscodeReason {
            kind: ReasonKind::Audio,
            codec: "dts".into(),
            detail: Some(ReasonDetail::Channels(6)),
        }],
        source: None,
        offline_video_codec: None,
        item_id: None,
    };
    assert_eq!(
        TechFacts::from_plan(&plan(DeliveryMethod::Transcode))
            .reason
            .as_deref(),
        Some("Audio „dts“ wird nicht direkt unterstützt (6 Kanäle).")
    );
    assert_eq!(
        TechFacts::from_plan(&plan(DeliveryMethod::DirectPlay)).reason,
        None
    );
}
