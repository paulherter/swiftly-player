//! The episodes layer of the player through the app's own event path (`Shell` pointer, button and wheel events into the
//! suite, into the player with the layer open): the strip of cards moves under a wheel, a drag and the paging arrows.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use swiftly_desktop::player_screen::{PlayerScenario, PlayerScreen};
use swiftly_desktop::shell::Shell;
use swiftly_desktop::wheel::WheelDelta;
use swiftly_ui::{Cx, Env, Idiom};
use swiftly_vm::{PlayerIntent, PlayerLayer};

const SIZE: (u32, u32) = (1000, 800);

fn find(n: &[swiftly_ui::a11y::A11yNode], pred: &dyn Fn(&str) -> bool, out: &mut Vec<[f32; 4]>) {
    for x in n {
        if pred(&x.label)
            && let Some(b) = x.bounds
        {
            out.push(b);
        }
        find(&x.children, pred, out);
    }
}

fn bounds(sh: &Shell, pred: &dyn Fn(&str) -> bool) -> Vec<[f32; 4]> {
    let mut v = Vec::new();
    find(&sh.a11y_nodes().1, pred, &mut v);
    v
}

struct Rig {
    sh: Shell,
    now: f64,
}

impl Rig {
    fn new() -> Rig {
        let mut sh = Shell::new_suite(SIZE, 1.0, Cx::deterministic(), Idiom::Desktop);
        let env = Env::new(
            swiftly_layout::Size::new(SIZE.0 as f32, SIZE.1 as f32),
            1.0,
            Idiom::Desktop,
        );
        sh.suite_mut().unwrap().show_player(PlayerScreen::new(
            env,
            Cx::deterministic(),
            PlayerScenario::Playing,
            0.0,
        ));
        let mut r = Rig { sh, now: 0.0 };
        r.run(2000.0);
        r.sh.player_intent(PlayerIntent::Layer(Some(PlayerLayer::Episodes)), r.now);
        r.run(1500.0);
        r
    }

    fn run(&mut self, ms: f64) {
        let end = self.now + ms;
        while self.now < end {
            self.now += 16.0;
            let _ = self.sh.frame(self.now);
        }
    }

    /// The left edge of the first episode card.
    fn first_card_x(&self) -> f32 {
        let v = bounds(&self.sh, &|l| l.starts_with("F1 "));
        v.first().expect("first card").first().copied().unwrap()
    }

    fn move_to(&mut self, x: f64, y: f64) {
        self.sh.cursor_moved((x, y), self.now);
        self.run(32.0);
    }
}

#[test]
fn the_wheel_scrolls_the_strip() {
    let mut r = Rig::new();
    let before = r.first_card_x();
    r.move_to(600.0, 230.0);
    for _ in 0..4 {
        r.sh.wheel(WheelDelta::Lines(0.0, -3.0), None, r.now);
        r.run(300.0);
    }
    assert!(
        (r.first_card_x() - before).abs() > 20.0,
        "the wheel left the strip at {before}"
    );
}

#[test]
fn a_drag_scrolls_the_strip() {
    let mut r = Rig::new();
    let before = r.first_card_x();
    r.move_to(700.0, 230.0);
    r.sh.primary_button(true, r.now);
    r.run(32.0);
    for i in 1..=12 {
        r.sh.cursor_moved((700.0 - 30.0 * f64::from(i), 230.0), r.now);
        r.run(16.0);
    }
    r.sh.primary_button(false, r.now);
    r.run(800.0);
    assert!(
        (r.first_card_x() - before).abs() > 40.0,
        "the drag left the strip at {before}"
    );
}

#[test]
fn the_arrows_page_the_strip() {
    let mut r = Rig::new();
    let before = r.first_card_x();
    let arrow = bounds(&r.sh, &|l| l.contains("Weiterbl"));
    let b = arrow.first().expect("a right arrow while there is more");
    let (x, y) = (f64::from(b[0] + b[2] / 2.0), f64::from(b[1] + b[3] / 2.0));
    r.move_to(x, y);
    r.sh.primary_button(true, r.now);
    r.run(48.0);
    r.sh.primary_button(false, r.now);
    r.run(1200.0);
    assert!(
        (r.first_card_x() - before).abs() > 100.0,
        "the arrow left the strip at {before}"
    );
}
