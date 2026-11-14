//! Player parity with the Mac, round 3: the context menu of the episode cards, the transcode reason in the technical overlay.
#![allow(clippy::unwrap_used)]

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

fn all_labels(n: &[swiftly_ui::a11y::A11yNode], out: &mut Vec<(String, Option<[f32; 4]>)>) {
    for x in n {
        out.push((x.label.clone(), x.bounds));
        all_labels(&x.children, out);
    }
}

fn labels(s: &PlayerScreen) -> Vec<(String, Option<[f32; 4]>)> {
    let mut v = Vec::new();
    all_labels(&s.a11y_nodes(), &mut v);
    v
}

/// A right click on an episode card of the player opens the shared tile menu in its player form (`inPlayer`): only the
/// watched mark; picking it is sent and the card follows (`PlayerEpisodeStrip.swift:56`).
#[test]
fn a_right_click_on_an_episode_card_offers_the_watched_mark() {
    let mut s = screen();
    run(&mut s, 0, 150);
    s.send_intent(
        swiftly_vm::PlayerIntent::Layer(Some(swiftly_vm::PlayerLayer::Episodes)),
        151.0 * 16.0,
    );
    run(&mut s, 152, 300);
    let card = labels(&s)
        .into_iter()
        .find(|(l, _)| l == "F2 · Die Nachricht, 44 Min.")
        .expect("the second card");
    let b = card.1.expect("bounds");
    let (px, py) = (b[0] + 20.0, b[1] + 20.0);
    let (list, _) = s.frame(300.0 * 16.0);
    let before = s.render_software(&list);
    assert!(s.secondary_click(px, py, 301.0 * 16.0));
    run(&mut s, 302, 330);
    let (list, _) = s.frame(330.0 * 16.0);
    let after = s.render_software(&list);
    let mut changed = 0;
    for y in (py as usize)..(py as usize + 70) {
        for x in (px as usize)..(px as usize + 220) {
            if before.pixel(x, y) != after.pixel(x, y) {
                changed += 1;
            }
        }
    }
    assert!(
        s.log().iter().any(|l| l == "epmenu open demo-e2"),
        "no menu opened: {:?}",
        s.log()
    );
    assert!(
        changed > 100,
        "no menu panel at the pointer ({changed} pixels changed)"
    );
    // The one row ("Als gesehen markieren") sits just under the pointer, inside the panel.
    s.touch_down(px + 40.0, py + 20.0, 331.0 * 16.0);
    s.touch_up(px + 40.0, py + 20.0, 332.0 * 16.0);
    run(&mut s, 333, 360);
    assert!(
        s.log().iter().any(|l| l == "epmenu Unwatched demo-e2"),
        "the pick did not run: {:?}",
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
