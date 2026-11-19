//! The desktop player's top bar: the menu capsule (Folgen, Ton & Untertitel, Einstellungen, volume) and the system
//! capsule (fullscreen, close), the volume dropping down from its button, and whole track titles in the box.
//! With `SWIFTLY_PROOF_DIR` set the frames are written there as PNGs.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use swiftly_desktop::player_screen::{PlayerScenario, PlayerScreen};
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

const FRAME_MS: f64 = 1000.0 / 60.0;

fn screen(w: f32, h: f32) -> PlayerScreen {
    let env = Env::new(Size::new(w, h), 1.0, Idiom::Desktop);
    PlayerScreen::new(env, Cx::deterministic(), PlayerScenario::ManyTracks, 0.0)
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

fn centre(s: &PlayerScreen, key: &str) -> (f32, f32) {
    let [x, y, w, h] = s.frame_of(key).unwrap_or_else(|| panic!("no node {key}"));
    (x + w / 2.0, y + h / 2.0)
}

fn tap_key(s: &mut PlayerScreen, key: &str, now: f64) -> f64 {
    let (cx, cy) = centre(s, key);
    s.touch_down(cx, cy, now);
    s.touch_up(cx, cy, now + 40.0);
    run(s, now + 40.0, 40)
}

fn volume_calls(s: &PlayerScreen) -> Vec<String> {
    s.engine_calls()
        .into_iter()
        .filter(|c| c.starts_with("volume"))
        .collect()
}

#[test]
fn fullscreen_and_close_share_one_capsule_and_the_speaker_sits_in_the_menu_capsule() {
    let mut s = screen(1920.0, 1080.0);
    let mut now = run(&mut s, 0.0, 120);
    s.pointer_move(960.0, 600.0, now);
    now = run(&mut s, now, 30);
    shot(&mut s, "01-leiste", now);
    let f = |k: &str| s.frame_of(k).unwrap_or_else(|| panic!("no node {k}"));
    let (tracks, settings, mute) = (f("tracks"), f("settings"), f("mute"));
    let (full, close) = (f("fullscreen"), f("close"));
    // One height for every half of both capsules.
    for h in [tracks, settings, mute, full, close] {
        assert_eq!(h[3], tracks[3], "same height");
        assert_eq!(h[1], tracks[1], "same row");
    }
    // Menu capsule: the halves run on without a gap and the speaker is the last one.
    assert!((tracks[0] + tracks[2] - settings[0]).abs() < 0.5);
    // (Übergeben, when offered, sits between Einstellungen and the speaker.)
    assert!(
        settings[0] + settings[2] <= mute[0] + 0.5,
        "speaker right of Einstellungen"
    );
    // Window capsule: fullscreen and close touch, a gap separates them from the menu capsule.
    assert!(
        (full[0] + full[2] - close[0]).abs() < 0.5,
        "fullscreen and close in one capsule"
    );
    let gap = full[0] - (mute[0] + mute[2]);
    assert!((gap - 8.0).abs() < 0.5, "gap between the capsules: {gap}");
    assert!(close[0] + close[2] < 1920.0, "inside the window");
}

#[test]
fn the_volume_drops_down_from_the_speaker_and_follows_drag_wheel_and_leaving() {
    let mut s = screen(1920.0, 1080.0);
    let mut now = run(&mut s, 0.0, 120);
    s.pointer_move(960.0, 600.0, now);
    now = run(&mut s, now, 30);
    let mute = s.frame_of("mute").unwrap();
    let (mx, my) = (mute[0] + mute[2] / 2.0, mute[1] + mute[3] / 2.0);
    // Out of the zone below the speaker the panel is not there: a press there sets nothing.
    s.touch_down(mx, mute[1] + mute[3] + 30.0, now);
    s.touch_up(mx, mute[1] + mute[3] + 30.0, now + 30.0);
    assert!(volume_calls(&s).is_empty());
    // Hover opens it downward.
    s.pointer_move(mx, my, now);
    now = run(&mut s, now, 40);
    let panel = s.frame_of("vol-slider").expect("the drop-down exists");
    assert!(
        panel[1] >= mute[1] + mute[3],
        "hangs below the capsule: {panel:?}"
    );
    assert!(
        (panel[0] - mute[0]).abs() < 0.5 && (panel[2] - mute[2]).abs() < 0.5,
        "as wide as the speaker half"
    );
    now = shot(&mut s, "02-lautstaerke", now);
    // The pointer travels down through the gap into the panel and the panel stays.
    s.pointer_move(mx, panel[1] - 2.0, now);
    s.pointer_move(mx, panel[1] + 40.0, now + 20.0);
    now = run(&mut s, now + 20.0, 30);
    // Drag: the top of the track is 100 %, the bottom 0 %, outside the panel it clamps.
    let top = panel[1] + 10.0 + 6.0;
    s.touch_down(mx, top - 4.0, now);
    assert_eq!(
        volume_calls(&s).last().map(String::as_str),
        Some("volume 100")
    );
    s.touch_move(mx + 200.0, top + 88.0 - 12.0 + 40.0, now + 20.0);
    assert_eq!(
        volume_calls(&s).last().map(String::as_str),
        Some("volume 0")
    );
    s.touch_move(mx, top + (88.0 - 12.0) / 2.0, now + 40.0);
    assert_eq!(
        volume_calls(&s).last().map(String::as_str),
        Some("volume 50")
    );
    s.touch_up(mx, top + (88.0 - 12.0) / 2.0, now + 60.0);
    now = run(&mut s, now + 60.0, 10);
    // The wheel over the speaker changes the volume (a notch = 5 %).
    let before = volume_calls(&s).len();
    assert!(s.volume_wheel(mx, my, -1.0, false, now));
    assert_eq!(volume_calls(&s).len(), before + 1);
    // Leaving collapses it: a press where the panel was sets nothing any more.
    s.pointer_move(960.0, 700.0, now + 20.0);
    now = run(&mut s, now + 20.0, 90);
    let n = volume_calls(&s).len();
    s.touch_down(mx, panel[1] + 40.0, now);
    s.touch_up(mx, panel[1] + 40.0, now + 30.0);
    assert_eq!(
        volume_calls(&s).len(),
        n,
        "the panel is gone after the pointer left"
    );
}

#[test]
fn a_long_subtitle_title_uses_the_width_of_its_row() {
    for (w, h) in [(1920.0, 1080.0), (1280.0, 720.0)] {
        let mut s = screen(w, h);
        let mut now = run(&mut s, 0.0, 120);
        s.pointer_move(w / 2.0, h / 2.0, now);
        now = run(&mut s, now, 30);
        now = tap_key(&mut s, "tracks", now);
        now = shot(&mut s, &format!("03-untertitel-{w}"), now);
        let _ = now;
        let [bx, _, bw, _] = s.frame_of("pm-box").expect("the box is open");
        assert!(bx >= 0.0 && bx + bw <= w, "the box stays in the window");
        let mut widest = 0.0_f32;
        for k in 0..40 {
            let (Some(t), Some(r)) = (
                s.frame_of(&format!("pmt:{k}")),
                s.frame_of(&format!("pm:{k}")),
            ) else {
                continue;
            };
            // The label ends inside its row (padding 10 on the right) and has not been given half of it only.
            assert!(
                t[0] + t[2] + 10.0 <= r[0] + r[2] + 0.5,
                "row {k}: {t:?} in {r:?}"
            );
            widest = widest.max(t[2]);
        }
        // Before the fix the longest title was offered 136 pt of a 328 pt row.
        assert!(widest > 300.0, "the long title keeps its width: {widest}");
        assert!(bw > 340.0, "the box grows for a long title: {bw}");
    }
}
