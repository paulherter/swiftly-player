//! Frame goldens, gesture tests and the tv focus plan of the Player screen (software renderer, bundled Inter, fixed
//! clock) for touch, desktop and tv. PNGs live in `swiftly-ui/tests/golden`; `UPDATE_GOLDENS=1` rewrites them.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::path::PathBuf;
use swiftly_desktop::player_screen::{DURATION, PlayerKey, PlayerScenario, PlayerScreen};
use swiftly_layout::Size;
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Dir, Env, Idiom, NavKey};
use swiftly_vm::{OfferView, Phase, PlayerIntent, PlayerLayer};

const FRAME_MS: f64 = 1000.0 / 60.0;

struct Form {
    name: &'static str,
    size: (f32, f32),
    scale: f32,
    idiom: Idiom,
}

const TOUCH: Form = Form {
    name: "touch",
    size: (844.0, 390.0),
    scale: 3.0,
    idiom: Idiom::Phone,
};
const DESKTOP: Form = Form {
    name: "desktop",
    size: (1280.0, 800.0),
    scale: 2.0,
    idiom: Idiom::Desktop,
};
const TV: Form = Form {
    name: "tv",
    size: (1920.0, 1080.0),
    scale: 1.0,
    idiom: Idiom::Tv,
};

fn env(f: &Form) -> Env {
    Env::new(Size::new(f.size.0, f.size.1), f.scale, f.idiom)
}

mod common;

fn check(name: &str, img: &RgbaImage) {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../swiftly-ui/tests/golden")
        .join(format!("{name}.png"));
    if std::env::var_os("UPDATE_GOLDENS").is_some() || !path.exists() {
        img.write_png(&path)
            .unwrap_or_else(|e| panic!("golden {name}: {e}"));
        println!("golden {name}: written");
        return;
    }
    let golden = RgbaImage::read_png(&path).unwrap_or_else(|e| panic!("golden {name}: {e}"));
    assert_eq!(
        (img.width, img.height),
        (golden.width, golden.height),
        "golden {name}: size"
    );
    let (max, share) = img.diff(&golden);
    assert!(
        common::golden_ok(max, share),
        "golden {name} differs by {max} ({:.4} % of the pixels)",
        share * 100.0
    );
}

/// Runs frames to `to` ms and returns the last picture.
fn shot(s: &mut PlayerScreen, now: &mut f64, to: f64) -> RgbaImage {
    while *now + FRAME_MS < to {
        *now += FRAME_MS;
        let _ = s.frame(*now);
    }
    *now = to;
    let (list, _) = s.frame(to);
    s.render_software(&list)
}

fn shot_for(s: &mut PlayerScreen, now: &mut f64, ms: f64) -> RgbaImage {
    let to = *now + ms;
    shot(s, now, to)
}

fn player(f: &Form, scenario: PlayerScenario) -> (PlayerScreen, f64) {
    let mut s = PlayerScreen::new(env(f), Cx::deterministic(), scenario, 0.0);
    let _ = s.frame(0.0);
    (s, 0.0)
}

fn scenes(f: &Form) {
    // Controls up right after the start.
    let (mut s, mut now) = player(f, PlayerScenario::Playing);
    let img = shot(&mut s, &mut now, 1000.0);
    assert!(s.vm().controls().visible);
    check(&format!("player_{}_controls", f.name), &img);
    // Skip intro.
    s.jump_clock(30.0, now);
    let img = shot_for(&mut s, &mut now, 400.0);
    assert!(
        matches!(
            s.vm().offer().view,
            OfferView::Button {
                next_episode: false,
                ..
            }
        ),
        "{:?}",
        s.vm().offer()
    );
    check(&format!("player_{}_skip", f.name), &img);
    // The scrubber held: preview box with chapter and time (touch and desktop).
    if f.idiom != Idiom::Tv {
        let (bx, bw) = (f.size.0 * 0.5, 0.0);
        let _ = bw;
        s.send_intent(PlayerIntent::ScrubStart, now);
        s.send_intent(PlayerIntent::ScrubMove(900.0), now);
        let img = shot_for(&mut s, &mut now, 200.0);
        let _ = bx;
        check(&format!("player_{}_scrub", f.name), &img);
        s.send_intent(PlayerIntent::ScrubEnd(900.0), now);
    }
    // Controls away after the 4 s.
    let img = shot(&mut s, &mut now, 7000.0);
    assert!(!s.vm().controls().visible, "auto-hide");
    check(&format!("player_{}_hidden", f.name), &img);
    // The tracks panel.
    s.send_intent(PlayerIntent::Layer(Some(PlayerLayer::Tracks)), now);
    let img = shot_for(&mut s, &mut now, 500.0);
    check(&format!("player_{}_menu", f.name), &img);
    s.send_intent(PlayerIntent::Layer(None), now);
    // The episodes layer, the Technikschild on the picture, the handover menu and the small-window hint.
    s.send_intent(PlayerIntent::Layer(Some(PlayerLayer::Episodes)), now);
    let img = shot_for(&mut s, &mut now, 500.0);
    check(&format!("player_{}_episodes", f.name), &img);
    s.send_intent(PlayerIntent::Layer(None), now);
    s.set_tech(true);
    s.send_intent(PlayerIntent::ToggleControls, now);
    let img = shot_for(&mut s, &mut now, 500.0);
    check(&format!("player_{}_tech", f.name), &img);
    s.set_tech(false);
    if f.idiom == Idiom::Desktop {
        s.set_handover(true);
        let img = shot_for(&mut s, &mut now, 300.0);
        check(&format!("player_{}_handover", f.name), &img);
        s.set_handover(false);
    }
    // The Mac has no small window: the hint only exists on touch and tv.
    if f.idiom != Idiom::Desktop {
        s.set_small_window(true);
        let img = shot_for(&mut s, &mut now, 300.0);
        check(&format!("player_{}_small", f.name), &img);
        s.set_small_window(false);
    }
    // The next-episode card near the end (a fresh player: the card is a state of its own).
    let (mut s, mut now) = player(f, PlayerScenario::Playing);
    let _ = shot(&mut s, &mut now, 500.0);
    s.jump_clock(DURATION - 50.0, now);
    let img = shot_for(&mut s, &mut now, 1200.0);
    assert!(
        matches!(s.vm().offer().view, OfferView::Card { .. }),
        "{:?}",
        s.vm().offer()
    );
    check(&format!("player_{}_next", f.name), &img);
    // A failed start.
    let (mut s, mut now) = player(f, PlayerScenario::Failed);
    let img = shot(&mut s, &mut now, 500.0);
    assert_eq!(s.vm().transport().phase, Phase::Failed);
    check(&format!("player_{}_error", f.name), &img);
}

#[test]
fn touch_phone() {
    scenes(&TOUCH);
}

#[test]
fn desktop() {
    scenes(&DESKTOP);
}

#[test]
fn tv() {
    scenes(&TV);
}

fn tap(s: &mut PlayerScreen, x: f32, y: f32, now: f64) {
    s.touch_down(x, y, now);
    s.touch_up(x, y, now + 40.0);
    let _ = s.frame(now + 41.0);
}

#[test]
fn double_tap_chain_seeks_and_leaves_the_controls_alone() {
    let (mut s, mut now) = player(&TOUCH, PlayerScenario::Playing);
    let _ = shot(&mut s, &mut now, 7000.0);
    assert!(!s.vm().controls().visible);
    let before = s.vm().transport().position;
    let (x, y) = (TOUCH.size.0 * 0.8, TOUCH.size.1 * 0.3);
    tap(&mut s, x, y, 7100.0); // the first tap shows the controls at once
    assert!(s.vm().controls().visible);
    tap(&mut s, x, y, 7300.0); // the second seeks forward and does not undo the first
    let after = s.vm().transport().position;
    assert!(after >= before + 9.0, "seek {before} -> {after}");
    assert!(s.vm().controls().jump_display.is_some());
    tap(&mut s, x, y, 7700.0); // within the chain window (0.5 s): seeks again
    assert!(s.vm().transport().position >= after + 9.0);
    // The other half seeks back.
    let at = s.vm().transport().position;
    tap(&mut s, TOUCH.size.0 * 0.2, y, 9000.0);
    tap(&mut s, TOUCH.size.0 * 0.2, y, 9200.0);
    assert!(s.vm().transport().position < at);
}

#[test]
fn scrubbing_the_bar_seeks_on_release() {
    let (mut s, mut now) = player(&DESKTOP, PlayerScenario::Playing);
    let _ = shot(&mut s, &mut now, 1000.0);
    let y = DESKTOP.size.1 - 22.0 - 22.0;
    s.touch_down(640.0, y, now);
    assert!(s.vm().controls().scrubbing);
    s.touch_move(900.0, y, now + 16.0);
    let mid = s.vm().transport().position;
    s.touch_up(900.0, y, now + 32.0);
    assert!(!s.vm().controls().scrubbing);
    assert!(
        mid > 1000.0 && s.engine_calls().iter().any(|c| c.starts_with("seek ")),
        "{:?}",
        s.engine_calls()
    );
}

#[test]
fn desktop_keys() {
    let (mut s, mut now) = player(&DESKTOP, PlayerScenario::Playing);
    let _ = shot(&mut s, &mut now, 1000.0);
    assert!(s.key(PlayerKey::Space, now));
    let _ = shot_for(&mut s, &mut now, 600.0);
    assert_eq!(s.vm().transport().phase, Phase::Paused);
    assert!(s.key(PlayerKey::Space, now + 10.0));
    assert!(s.key(PlayerKey::Right, now + 20.0));
    assert!(s.key(PlayerKey::Down, now + 30.0));
    assert!(s.engine_calls().contains(&"volume 95".to_owned()));
    // F asks the window for real fullscreen (the Mac), it does not fill the picture.
    assert!(s.key(PlayerKey::Char('f'), now + 40.0));
    assert!(s.take_fullscreen_request());
    assert!(!s.engine_calls().contains(&"fill true".to_owned()));
    assert!(s.key(PlayerKey::Char('h'), now + 50.0));
    assert_eq!(s.vm().tracks().subtitle_delay_ms, 50);
    assert_eq!(s.notice(), Some("Untertitelverzögerung +0,05 s"));
    assert!(s.key(PlayerKey::Char('j'), now + 60.0));
    assert_eq!(s.vm().tracks().audio_delay_ms, -50);
    assert_eq!(s.notice(), Some("Tonverzögerung −0,05 s"));
    // The line goes after 3 s (`notify`).
    let _ = s.frame(now + 60.0 + 2900.0);
    assert!(s.notice().is_some());
    let _ = s.frame(now + 60.0 + 3100.0);
    assert!(s.notice().is_none());
    // With a panel open the letters and arrows are not taken; Esc closes the panel first.
    s.send_intent(PlayerIntent::Layer(Some(PlayerLayer::Tracks)), now + 70.0);
    assert!(!s.key(PlayerKey::Space, now + 80.0));
    assert!(s.key(PlayerKey::Escape, now + 90.0));
    assert!(s.vm().controls().layer.is_none());
    assert!(!s.is_closed());
}

#[test]
fn pinch_switches_fill_with_the_swift_thresholds() {
    let (mut s, mut now) = player(&TOUCH, PlayerScenario::Playing);
    let _ = shot(&mut s, &mut now, 500.0);
    s.pinch(1.10, now);
    assert!(!s.engine_calls().contains(&"fill true".to_owned()));
    s.pinch(1.20, now);
    assert!(s.engine_calls().contains(&"fill true".to_owned()));
    let off = |s: &PlayerScreen| {
        s.engine_calls()
            .iter()
            .filter(|c| *c == "fill false")
            .count()
    };
    let n = off(&s);
    s.pinch(0.90, now);
    assert_eq!(off(&s), n);
    s.pinch(0.80, now);
    assert_eq!(off(&s), n + 1);
}

fn key(s: &mut PlayerScreen, k: NavKey, now: &mut f64) {
    *now += 100.0;
    s.nav_key(k, true, *now);
    s.nav_key(k, false, *now + 10.0);
    let _ = s.frame(*now + 20.0);
}

#[test]
fn tv_focus_plan_and_remote_rules() {
    let (mut s, mut now) = player(&TV, PlayerScenario::Playing);
    let _ = shot(&mut s, &mut now, 1000.0);
    // Controls up: focus rests on the bar; Left/Right skip, Select pauses.
    assert_eq!(s.focused(), Some(swiftly_ui::components::focus_id("bar")));
    let p0 = s.vm().transport().position;
    key(&mut s, NavKey::Arrow(Dir::Left), &mut now);
    assert!(s.vm().transport().position < p0);
    key(&mut s, NavKey::Enter, &mut now);
    let _ = shot_for(&mut s, &mut now, 600.0);
    assert_eq!(
        s.vm().transport().phase,
        Phase::Paused,
        "{:?}",
        s.engine_calls()
    );
    key(&mut s, NavKey::Enter, &mut now);
    // Up leaves the bar for the buttons.
    key(&mut s, NavKey::Arrow(Dir::Up), &mut now);
    assert_eq!(
        s.focused(),
        Some(swiftly_ui::components::focus_id("tracks"))
    );
    // Select opens the panel (a trap); Menu closes it before anything else.
    key(&mut s, NavKey::Enter, &mut now);
    assert_eq!(s.vm().controls().layer, Some(PlayerLayer::Tracks));
    key(&mut s, NavKey::Arrow(Dir::Down), &mut now);
    key(&mut s, NavKey::Arrow(Dir::Down), &mut now);
    key(&mut s, NavKey::Enter, &mut now);
    // Focus is trapped in the panel: it moved off the button row onto a row of the panel.
    assert_ne!(
        s.focused(),
        Some(swiftly_ui::components::focus_id("tracks"))
    );
    assert_eq!(s.vm().controls().layer, Some(PlayerLayer::Tracks));
    key(&mut s, NavKey::Escape, &mut now);
    assert!(s.vm().controls().layer.is_none());
    // Menu again hides the controls, the next Menu leaves the film.
    assert!(s.vm().controls().visible);
    key(&mut s, NavKey::Escape, &mut now);
    assert!(!s.vm().controls().visible);
    assert!(!s.is_closed());
    // A key with the controls away only wakes them.
    key(&mut s, NavKey::Arrow(Dir::Right), &mut now);
    assert!(s.vm().controls().visible);
    key(&mut s, NavKey::Escape, &mut now);
    key(&mut s, NavKey::Escape, &mut now);
    assert!(s.is_closed());
}

#[test]
fn failed_start_retries_and_closes() {
    let (mut s, mut now) = player(&TV, PlayerScenario::Failed);
    let _ = shot(&mut s, &mut now, 300.0);
    let loads = s
        .engine_calls()
        .iter()
        .filter(|c| c.starts_with("load"))
        .count();
    key(&mut s, NavKey::Enter, &mut now);
    let _ = shot_for(&mut s, &mut now, 300.0);
    assert!(
        s.engine_calls()
            .iter()
            .filter(|c| c.starts_with("load"))
            .count()
            > loads,
        "{:?}",
        s.engine_calls()
    );
}

#[test]
fn desktop_escape_order_and_volume_keys() {
    let (mut s, mut now) = player(&DESKTOP, PlayerScenario::Playing);
    let _ = shot(&mut s, &mut now, 1000.0);
    // Esc: layer first, then (in fullscreen) leave fullscreen, then close.
    s.send_intent(PlayerIntent::Layer(Some(PlayerLayer::Settings)), now);
    s.set_fullscreen(true);
    s.back(now + 10.0);
    assert!(s.vm().controls().layer.is_none() && !s.is_closed() && !s.take_fullscreen_request());
    s.back(now + 20.0);
    assert!(
        s.take_fullscreen_request() && !s.is_closed(),
        "second Esc leaves fullscreen"
    );
    s.set_fullscreen(false);
    s.back(now + 30.0);
    assert!(s.is_closed(), "third Esc closes");
    // Up and Down move the volume by 5 %, M mutes and restores.
    let (mut s, mut now) = player(&DESKTOP, PlayerScenario::Playing);
    let _ = shot(&mut s, &mut now, 1000.0);
    assert!(s.key(PlayerKey::Down, now));
    assert!(s.engine_calls().contains(&"volume 95".to_owned()));
    assert!(s.key(PlayerKey::Char('m'), now + 10.0));
    assert!(s.engine_calls().contains(&"volume 0".to_owned()));
    assert!(s.key(PlayerKey::Char('m'), now + 20.0));
    assert!(s.engine_calls().last().is_some_and(|c| c == "volume 95"));
    // The wheel is only taken over the speaker and its compartment.
    assert!(!s.volume_wheel(10.0, 400.0, 1.0, false, now + 40.0));
}

#[test]
fn next_card_drags_away_and_the_menu_takes_escape_first() {
    use swiftly_desktop::player_card::{CardLook, card_rect};
    let (mut s, mut now) = player(&DESKTOP, PlayerScenario::Playing);
    let _ = shot(&mut s, &mut now, 500.0);
    s.jump_clock(DURATION - 50.0, now);
    let _ = shot_for(&mut s, &mut now, 1500.0);
    assert!(matches!(s.vm().offer().view, OfferView::Card { .. }));
    let r = card_rect(
        1280.0,
        800.0,
        28.0,
        76.0,
        &CardLook {
            shown: true,
            opacity: 1.0,
            scale: 1.0,
            ..CardLook::default()
        },
    );
    let (cx, cy) = (r.x + r.w / 2.0, r.y + r.h / 2.0);
    // A small click zooms and keeps the card; a drag of more than 70 pt keeps the credits and removes it.
    s.touch_down(cx, cy, now);
    s.touch_up(cx, cy, now + 20.0);
    now += 20.0;
    assert!(
        matches!(s.vm().offer().view, OfferView::Card { .. }),
        "a click only zooms"
    );
    s.touch_down(cx, cy, now);
    s.touch_move(cx - 60.0, cy + 60.0, now + 30.0);
    s.touch_up(cx - 60.0, cy + 60.0, now + 60.0);
    assert!(
        !matches!(s.vm().offer().view, OfferView::Card { .. }),
        "{:?}",
        s.vm().offer()
    );
    // The handover menu: Esc closes the menu, the next one the player.
    let (mut s, mut now) = player(&DESKTOP, PlayerScenario::Playing);
    let _ = shot(&mut s, &mut now, 1000.0);
    s.set_handover(true);
    s.back(now + 10.0);
    assert!(!s.is_closed(), "Esc closes the menu first");
    s.back(now + 20.0);
    assert!(s.is_closed());
}

#[test]
fn volume_is_kept_between_sessions() {
    use swiftly_settings::{JsonFileStore, KeyValueStore, Value};
    let path =
        std::env::temp_dir().join(format!("swiftly-player-volume-{}.json", std::process::id()));
    let store = std::sync::Arc::new(JsonFileStore::open(path.clone()).unwrap());
    store.set("playerLautstaerke", Value::Double(0.4)).unwrap();
    let (mut s, mut now) = player(&DESKTOP, PlayerScenario::Playing);
    let _ = shot(&mut s, &mut now, 500.0);
    s.set_store(std::sync::Arc::clone(&store), now);
    assert!(
        s.engine_calls().contains(&"volume 40".to_owned()),
        "{:?}",
        s.engine_calls()
    );
    assert!(s.key(PlayerKey::Down, now + 10.0));
    assert!(
        matches!(store.get("playerLautstaerke"), Some(Value::Double(v)) if (v - 0.35).abs() < 1e-9)
    );
    assert!(s.key(PlayerKey::Char('m'), now + 20.0));
    assert!(matches!(store.get("playerLautstaerke"), Some(Value::Double(v)) if v == 0.0));
    assert!(
        matches!(store.get("playerLautstaerkeDavor"), Some(Value::Double(v)) if (v - 0.35).abs() < 1e-9)
    );
    let _ = std::fs::remove_file(path);
}
