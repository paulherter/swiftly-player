//! The player's reading list: in window points like the buttons (no sidebar shift) and with the Mac's German labels.
#![allow(clippy::unwrap_used)]

use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_ui::a11y::A11yNode;
use swiftly_ui::{Cx, Env, Idiom};

const STEP: f64 = 1000.0 / 60.0;

fn run_for(s: &mut Suite, now: &mut f64, ms: f64) {
    let end = *now + ms;
    while *now < end {
        *now += STEP;
        let _ = s.frame(*now);
    }
}

fn flat<'a>(n: &'a [A11yNode], out: &mut Vec<&'a A11yNode>) {
    for x in n {
        out.push(x);
        flat(&x.children, out);
    }
}

fn open_title(s: &mut Suite, now: &mut f64, size: (f32, f32)) {
    // The Movies grid, then taps on a 48 pt grid over the content column until a cover opens its title page.
    assert!(s.goto_tab(1, *now));
    run_for(s, now, 600.0);
    let mut y = size.1 * 0.2;
    while y < size.1 - 10.0 {
        let mut x = 240.0;
        while x < size.0 - 10.0 {
            s.touch_down(x, y, *now);
            s.touch_up(x, y, *now + 40.0);
            *now += 80.0;
            if s.title_open() {
                return;
            }
            x += 48.0;
        }
        y += 48.0;
    }
    panic!("no title at {size:?}");
}

fn open_player(size: (f32, f32)) -> (Suite, f64) {
    let env = Env::new(Size::new(size.0, size.1), 1.0, Idiom::Desktop);
    let mut s = Suite::new(env, Cx::deterministic());
    let mut now = 0.0;
    run_for(&mut s, &mut now, 300.0);
    open_title(&mut s, &mut now, size);
    run_for(&mut s, &mut now, 1300.0);
    'play: for yi in 0..40 {
        for xi in 0..24 {
            let (x, y) = (
                size.0 * (0.20 + 0.03 * xi as f32),
                size.1 * (0.08 + 0.022 * yi as f32),
            );
            s.touch_down(x, y, now);
            s.touch_up(x, y, now + 40.0);
            now += 80.0;
            if s.player_open() {
                break 'play;
            }
        }
    }
    assert!(s.player_open());
    run_for(&mut s, &mut now, 800.0);
    (s, now)
}

#[test]
fn the_player_nodes_sit_on_the_buttons_and_speak_german() {
    let (mut s, _) = open_player((1280.0, 800.0));
    let mine = s.player().unwrap().a11y_nodes();
    let own: Vec<[f32; 4]> = {
        let mut v = Vec::new();
        flat(&mine, &mut v);
        v.iter().filter_map(|n| n.bounds).collect()
    };
    let (_, nodes) = s.a11y_nodes();
    let mut all = Vec::new();
    flat(&nodes, &mut all);
    let shown: Vec<[f32; 4]> = all.iter().filter_map(|n| n.bounds).collect();
    assert_eq!(
        shown, own,
        "the window nodes are the player's own, unshifted"
    );
    let labels: Vec<&str> = all.iter().map(|n| n.label.as_str()).collect();
    for raw in [
        "fullscreen",
        "mute",
        "close",
        "tracks",
        "episodes",
        "settings",
    ] {
        assert!(!labels.contains(&raw), "raw label {raw}: {labels:?}");
    }
    assert!(
        labels.iter().any(|l| l.starts_with("Vollbild")),
        "{labels:?}"
    );
    assert!(
        labels.iter().any(|l| l.starts_with("Ton a")),
        "mute speaks German: {labels:?}"
    );
}

/// The detail page has one "Zurück", the window bar's chevron: at the left of the content column, in the 52 pt strip
/// (the page's own header used to add a second one in the middle of the page).
#[test]
fn the_detail_back_node_sits_on_the_chevron() {
    for size in [(1280.0_f32, 800.0_f32), (1920.0, 1080.0)] {
        let env = Env::new(Size::new(size.0, size.1), 1.0, Idiom::Desktop);
        let mut s = Suite::new(env, Cx::deterministic());
        let mut now = 0.0;
        run_for(&mut s, &mut now, 300.0);
        open_title(&mut s, &mut now, size);
        run_for(&mut s, &mut now, 1300.0);
        let (_, nodes) = s.a11y_nodes();
        let mut all = Vec::new();
        flat(&nodes, &mut all);
        let back: Vec<[f32; 4]> = all
            .iter()
            .filter(|n| n.label == "Zurück")
            .filter_map(|n| n.bounds)
            .collect();
        assert_eq!(back.len(), 1, "{size:?}: one back node, got {back:?}");
        for b in &back {
            let (cx, cy) = (b[0] + b[2] / 2.0, b[1] + b[3] / 2.0);
            // Sidebar 220 pt + chevron box at 20 pt (30 wide), 12 pt down in the 52 pt strip.
            assert!(
                (220.0..320.0).contains(&cx) && cy < 52.0,
                "{size:?}: back centred at ({cx}, {cy})"
            );
        }
    }
}
