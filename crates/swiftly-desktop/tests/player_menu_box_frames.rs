//! The desktop player's bar capsule and menu box, drawn from the core's menus (software renderer, fixed clock).
//! With `SWIFTLY_PROOF_DIR` set the frames are written there as PNGs (proof for the redesign).
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::sync::Arc;
use swiftly_desktop::login_screen::Pending;
use swiftly_desktop::player_host::{EpisodeCardData, EpisodeSource, SeasonRow};
use swiftly_desktop::player_screen::{PlayerKey, PlayerScenario, PlayerScreen};
use swiftly_layout::Size;
use swiftly_ui::{Cx, Dir, Env, Idiom, NavKey};

const FRAME_MS: f64 = 1000.0 / 60.0;

fn screen(scenario: PlayerScenario) -> PlayerScreen {
    let env = Env::new(Size::new(1280.0, 560.0), 2.0, Idiom::Desktop);
    PlayerScreen::new(env, Cx::deterministic(), scenario, 0.0)
}

fn run(s: &mut PlayerScreen, now: f64, frames: u32) -> f64 {
    let mut t = now;
    for _ in 0..frames {
        t += FRAME_MS;
        let _ = s.frame(t);
    }
    t
}

fn shot(s: &mut PlayerScreen, name: &str, now: f64) -> f64 {
    let t = run(s, now, 1);
    let (list, _) = s.frame(t);
    if let Some(dir) = std::env::var_os("SWIFTLY_PROOF_DIR") {
        let dir = std::path::PathBuf::from(dir);
        std::fs::create_dir_all(&dir).unwrap();
        s.render_software(&list)
            .write_png(&dir.join(format!("{name}.png")))
            .unwrap();
    }
    t
}

fn tap_key(s: &mut PlayerScreen, key: &str, now: f64) -> f64 {
    let [x, y, w, h] = s.frame_of(key).unwrap_or_else(|| panic!("no node {key}"));
    let (cx, cy) = (x + w / 2.0, y + h / 2.0);
    s.touch_down(cx, cy, now);
    s.touch_up(cx, cy, now + 40.0);
    run(s, now + 40.0, 40)
}

#[test]
fn the_capsule_opens_the_menus_in_one_box_and_switches_in_place() {
    let mut s = screen(PlayerScenario::ManyTracks);
    let mut now = run(&mut s, 0.0, 120);
    s.pointer_move(640.0, 400.0, now);
    now = shot(&mut s, "01-capsule", now);
    assert!(s.frame_of("tracks").is_some() && s.frame_of("settings").is_some());
    // Einstellungen opens the Optionen box under its half.
    now = tap_key(&mut s, "settings", now);
    let [bx, by, _, _] = s.frame_of("pm-box").expect("the box is open");
    let [sx, sy, sw, sh] = s.frame_of("settings").unwrap();
    assert!(
        by >= sy + sh,
        "the box hangs under the button ({by} vs {})",
        sy + sh
    );
    assert!(
        bx + 340.0 >= sx + sw - 1.0 && bx <= sx + sw,
        "right edge under the half"
    );
    now = shot(&mut s, "02-optionen", now);
    // Ton & Untertitel switches inside the box in one step: the box node stays.
    now = tap_key(&mut s, "tracks", now);
    assert!(s.frame_of("pm-box").is_some());
    now = shot(&mut s, "03-ton-untertitel", now);
    // Arrows move inside the box and keep the highlighted row in view.
    for _ in 0..9 {
        assert!(s.key(PlayerKey::Down, now));
        now = run(&mut s, now, 8);
    }
    now = shot(&mut s, "04-scrolled", now);
    // Esc closes the box, the bar stays and the player plays on.
    assert!(s.key(PlayerKey::Escape, now));
    now = run(&mut s, now, 60);
    assert!(s.frame_of("pm-box").is_none(), "Esc closes the box");
    assert!(!s.is_closed());
    // The same half again opens and a second tap closes it (open = close motion, one node).
    now = tap_key(&mut s, "settings", now);
    now = shot(&mut s, "05-open-mid", now);
    now = tap_key(&mut s, "settings", now);
    assert!(s.frame_of("pm-box").is_none());
    let _ = now;
}

fn form_screen(idiom: Idiom, size: Size, scenario: PlayerScenario) -> PlayerScreen {
    PlayerScreen::new(
        Env::new(size, 2.0, idiom),
        Cx::deterministic(),
        scenario,
        0.0,
    )
}

#[test]
fn the_folgen_half_opens_the_box_with_the_season_button_and_the_chapter_tab() {
    let mut s = screen(PlayerScenario::Playing);
    let mut now = run(&mut s, 0.0, 120);
    s.pointer_move(640.0, 400.0, now);
    assert!(
        s.frame_of("folgen").is_some(),
        "the capsule has the Folgen half"
    );
    assert!(
        s.frame_of("chapters").is_none(),
        "no separate Kapitel button"
    );
    now = tap_key(&mut s, "folgen", now);
    assert!(s.frame_of("pm-box").is_some(), "Folgen opens the box");
    now = run(&mut s, now, 60);
    now = shot(&mut s, "02-folgen-box", now);
    // The Kapitel tab swaps the rows inside the same box.
    now = tap_key(&mut s, "pm:1", now);
    assert!(s.frame_of("pm-box").is_some());
    now = shot(&mut s, "03-kapitel-tab", now);
    let _ = now;
}

#[test]
fn touch_and_tv_forms_use_the_same_capsule_and_box() {
    // Touch: capsule with the X.
    let mut s = form_screen(
        Idiom::Phone,
        Size::new(844.0, 390.0),
        PlayerScenario::Playing,
    );
    let mut now = run(&mut s, 0.0, 120);
    s.pointer_move(400.0, 300.0, now);
    now = run(&mut s, now, 30);
    assert!(s.frame_of("folgen").is_some() && s.frame_of("close").is_some());
    now = tap_key(&mut s, "folgen", now);
    assert!(
        s.frame_of("pm-box").is_some(),
        "touch: Folgen opens the core box"
    );
    shot(&mut s, "04-touch-folgen", now);
    // Tv: capsule without X; Up from the bar focuses the capsule, Select opens the Folgen box, Menu closes it.
    let mut s = form_screen(
        Idiom::Tv,
        Size::new(1920.0, 1080.0),
        PlayerScenario::Playing,
    );
    let mut now = run(&mut s, 0.0, 120);
    let nav = |s: &mut PlayerScreen, k: NavKey, now: &mut f64| {
        *now += 100.0;
        s.nav_key(k, true, *now);
        s.nav_key(k, false, *now + 10.0);
        *now = run(s, *now + 20.0, 30);
    };
    nav(&mut s, NavKey::Arrow(Dir::Right), &mut now);
    assert!(s.frame_of("folgen").is_some());
    assert!(s.frame_of("close").is_none(), "tv: no X");
    assert!(s.frame_of("handover").is_none(), "tv: no Uebergeben");
    nav(&mut s, NavKey::Arrow(Dir::Up), &mut now);
    nav(&mut s, NavKey::Enter, &mut now);
    assert!(
        s.frame_of("pm-box").is_some(),
        "tv: Select on Folgen opens the core box"
    );
    shot(&mut s, "05-tv-folgen", now);
    nav(&mut s, NavKey::Escape, &mut now);
    now = run(&mut s, now, 60);
    assert!(s.frame_of("pm-box").is_none(), "tv: Back closes the box");
    let _ = now;
}

/// The box frames of the 30 frames after a tap on `key`: the box is one node that moves and resizes (never gone, never a
/// second one fading in), so a switch into Folgen has the same motion as a switch between two other menus.
fn switch_frames(s: &mut PlayerScreen, key: &str, now: f64) -> (Vec<[f32; 4]>, f64) {
    let [x, y, w, h] = s.frame_of(key).unwrap();
    let (cx, cy) = (x + w / 2.0, y + h / 2.0);
    s.touch_down(cx, cy, now);
    s.touch_up(cx, cy, now + 40.0);
    let mut t = now + 40.0;
    let mut frames = Vec::new();
    for _ in 0..30 {
        t += FRAME_MS;
        let _ = s.frame(t);
        frames.push(
            s.frame_of("pm-box")
                .expect("the box stays mounted during a switch"),
        );
    }
    (frames, t)
}

fn distinct(frames: &[[f32; 4]]) -> usize {
    let mut seen: Vec<[f32; 4]> = Vec::new();
    for f in frames {
        if !seen
            .iter()
            .any(|g| g.iter().zip(f).all(|(a, b)| (a - b).abs() < 0.01))
        {
            seen.push(*f);
        }
    }
    seen.len()
}

#[test]
fn a_menu_turns_into_folgen_with_the_motion_of_menu_to_menu() {
    let mut s = screen(PlayerScenario::Playing);
    let mut now = run(&mut s, 0.0, 120);
    s.pointer_move(640.0, 400.0, now);
    now = tap_key(&mut s, "settings", now);
    now = run(&mut s, now, 40);
    let (to_tracks, now) = switch_frames(&mut s, "tracks", now);
    let now = run(&mut s, now, 40);
    let (to_folgen, now) = switch_frames(&mut s, "folgen", now);
    let now = run(&mut s, now, 40);
    let (to_menu, _) = switch_frames(&mut s, "settings", now);
    // Whatever the box does for menu to menu, it does for Folgen in both directions (the layout frame carries no
    // tween here: the box node stays and takes its new place in one step, for every pair).
    assert_eq!(
        distinct(&to_tracks),
        distinct(&to_folgen),
        "menu->Folgen moves unlike menu->menu"
    );
    assert_eq!(
        distinct(&to_tracks),
        distinct(&to_menu),
        "Folgen->menu moves unlike menu->menu"
    );
    eprintln!(
        "box frames: menu->menu {} menu->Folgen {} Folgen->menu {}",
        distinct(&to_tracks),
        distinct(&to_folgen),
        distinct(&to_menu)
    );
}

/// A server whose answers wait until the test lets them go (a request made later is answered later).
#[derive(Default)]
struct Slow {
    waiting: std::sync::Mutex<Vec<Box<dyn FnOnce() + Send>>>,
}

impl Slow {
    fn answer_all(&self) {
        let all: Vec<_> = self.waiting.lock().unwrap().drain(..).collect();
        for send in all {
            send();
        }
    }
}

impl EpisodeSource for Slow {
    fn seasons(&self, _: &str, _: Option<&str>) -> Pending<Option<(Vec<SeasonRow>, usize)>> {
        let (tx, p) = Pending::channel();
        let row = SeasonRow {
            id: "s1".into(),
            name: "Staffel 1".into(),
        };
        self.waiting.lock().unwrap().push(Box::new(move || {
            let _ = tx.send(Some((vec![row], 0)));
        }));
        p
    }
    fn episodes(&self, _: &str, _: &str) -> Pending<Option<Vec<EpisodeCardData>>> {
        let (tx, p) = Pending::channel();
        let card = |n: u32| EpisodeCardData {
            id: format!("e{n}"),
            title: format!("Folge {n}"),
            header: format!("F{n} · Folge {n}"),
            sub: Some("52 Min.".into()),
            progress: None,
            watched: false,
            image: None,
        };
        self.waiting.lock().unwrap().push(Box::new(move || {
            let _ = tx.send(Some((1..=6).map(card).collect()));
        }));
        p
    }
    fn still(&self, _: &str, _: Option<&str>) -> swiftly_desktop::player_card::StillSource {
        Arc::new(|| None)
    }
}

#[test]
fn the_folgen_box_is_complete_in_the_first_frame_of_a_switch_from_a_menu() {
    // Seen live: menu -> Folgen showed a sliver in frame 0 and grew over the next frames, because the seasons and
    // episodes were only asked for once the layer opened. They are asked for as soon as the episode plays, so the
    // answers are in by the time anyone taps (here: released while the Optionen box is open).
    let source = Arc::new(Slow::default());
    let mut s = screen(PlayerScenario::Playing);
    s.set_episode_source(Arc::<Slow>::clone(&source));
    let mut now = run(&mut s, 0.0, 120);
    s.pointer_move(640.0, 400.0, now);
    now = tap_key(&mut s, "settings", now);
    source.answer_all(); // the seasons
    now = run(&mut s, now, 10);
    source.answer_all(); // the episodes of the season the seasons asked for
    now = run(&mut s, now, 40);
    let (to_folgen, _) = switch_frames(&mut s, "folgen", now);
    let first = to_folgen[0];
    let last = *to_folgen.last().unwrap();
    assert!(
        last[3] > 150.0,
        "the Folgen box carries the season button and rows: {last:?}"
    );
    assert!(
        (first[3] - last[3]).abs() < 0.5,
        "frame 0 of menu->Folgen already has the final box size: {first:?} vs {last:?}"
    );
    eprintln!("folgen box frame 0 {first:?} last {last:?}");
}
