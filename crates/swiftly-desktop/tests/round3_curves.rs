//! Round 3 curves: headless frames at two time points of the rail stagger after an account switch and of the controls
//! settling on entering fullscreen, with and without Reduce Motion. Both run on catalogue curves (`AccountRows`,
//! `AccountRailsFade`, `Fullscreen`); strict mode panics on any curve outside the table.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use swiftly_desktop::home::HomeScreen;
use swiftly_desktop::home_data::Scenario;
use swiftly_desktop::player_screen::{PlayerScenario, PlayerScreen};
use swiftly_layout::Size;
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Env, Idiom};

const FRAME_MS: f64 = 1000.0 / 60.0;

fn env(reduce: bool) -> Env {
    let mut env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    env.reduce_motion = reduce;
    env
}

fn home_frames(reduce: bool, at: &[f64]) -> (RgbaImage, Vec<RgbaImage>) {
    swiftly_motion::catalogue::set_strict(true);
    let mut h = HomeScreen::new(env(reduce), Cx::deterministic(), Scenario::Ready);
    let mut now = 0.0;
    while now < 600.0 {
        now += FRAME_MS;
        let _ = h.frame(now);
    }
    let (list, _) = h.frame(now);
    let before = h.render_software(&list);
    h.begin_rail_stagger();
    let t0 = now;
    let mut out = Vec::new();
    for &t in at {
        while now + FRAME_MS < t0 + t {
            now += FRAME_MS;
            let _ = h.frame(now);
        }
        now = t0 + t;
        let _ = h.frame(now);
        let (list, _) = h.frame(now);
        out.push(h.render_software(&list));
    }
    (before, out)
}

#[test]
fn rails_stagger_in_and_settle_on_the_plain_page() {
    // Row 0 starts at once, row 3 lags 0.24 s: at 60 ms the page is far from rest, after 2 s it is the plain page again.
    let (before, f) = home_frames(false, &[60.0, 300.0, 2500.0]);
    assert!(
        f[0].diff(&f[1]).0 > 8,
        "the rows are on their way between 60 ms and 300 ms"
    );
    assert!(f[1].diff(&f[2]).0 > 8, "and still settling at 300 ms");
    assert!(
        f[2].diff(&before).0 <= 2,
        "the staggered page ends where the plain page was"
    );
}

#[test]
fn rails_only_fade_with_reduce_motion() {
    // linear 0.14 s: nothing is left to move after 600 ms, the page is the plain page.
    let (before, f) = home_frames(true, &[40.0, 700.0]);
    assert!(f[0].diff(&f[1]).0 > 8, "a fade is under way at 40 ms");
    assert!(f[1].diff(&before).0 <= 2);
}

/// The rows leave on the tap (`AccountRowsOut`, easeOut 0.12) and the new ones come in at the change: frames at three
/// time points of each half.
#[test]
fn old_rows_leave_on_ease_out_and_new_rows_come_in_at_scale_and_offset() {
    swiftly_motion::catalogue::set_strict(true);
    let mut h = HomeScreen::new(env(false), Cx::deterministic(), Scenario::Ready);
    let mut now = 0.0;
    while now < 600.0 {
        now += FRAME_MS;
        let _ = h.frame(now);
    }
    let (list, _) = h.frame(now);
    let before = h.render_software(&list);
    h.begin_rail_out();
    let t0 = now;
    let shot = |h: &mut HomeScreen, now: &mut f64, t: f64, base: f64| {
        while *now + FRAME_MS < base + t {
            *now += FRAME_MS;
            let _ = h.frame(*now);
        }
        *now = base + t;
        let _ = h.frame(*now);
        let (list, _) = h.frame(*now);
        h.render_software(&list)
    };
    let (a, b, c) = (
        shot(&mut h, &mut now, 30.0, t0),
        shot(&mut h, &mut now, 70.0, t0),
        shot(&mut h, &mut now, 400.0, t0),
    );
    assert!(
        a.diff(&before).0 > 8,
        "the rows are on their way out at 30 ms"
    );
    assert!(a.diff(&b).0 > 8, "and still going at 70 ms");
    assert!(b.diff(&c).0 > 8, "and gone at 400 ms (easeOut 0.12 s)");
    let empty = shot(&mut h, &mut now, 900.0, t0);
    assert!(c.diff(&empty).0 <= 2, "nothing moves after the rows left");
    h.begin_rail_stagger();
    let t1 = now;
    let (d, e, f) = (
        shot(&mut h, &mut now, 60.0, t1),
        shot(&mut h, &mut now, 300.0, t1),
        shot(&mut h, &mut now, 2500.0, t1),
    );
    assert!(d.diff(&empty).0 > 8, "the first row is coming in at 60 ms");
    assert!(
        d.diff(&e).0 > 8 && e.diff(&f).0 > 8,
        "the rows are still rising at 300 ms"
    );
    assert!(f.diff(&before).0 <= 2, "the new rows end on the plain page");
}

fn player_frames(reduce: bool, at: &[f64]) -> Vec<RgbaImage> {
    swiftly_motion::catalogue::set_strict(true);
    let mut s = PlayerScreen::new(
        env(reduce),
        Cx::deterministic(),
        PlayerScenario::Playing,
        0.0,
    );
    let mut now = 0.0;
    let _ = s.frame(now);
    while now < 800.0 {
        now += FRAME_MS;
        let _ = s.frame(now);
    }
    s.pointer_move(640.0, 400.0, now);
    s.set_fullscreen(true);
    let t0 = now;
    let mut out = Vec::new();
    for &t in at {
        while now + FRAME_MS < t0 + t {
            now += FRAME_MS;
            let _ = s.frame(now);
        }
        now = t0 + t;
        let _ = s.frame(now);
        let (list, _) = s.frame(now);
        out.push(s.render_software(&list));
    }
    out
}

#[test]
fn controls_settle_into_fullscreen_with_ease_in_out_half_a_second() {
    let f = player_frames(false, &[60.0, 250.0, 900.0]);
    assert!(
        f[0].diff(&f[1]).0 > 8 && f[1].diff(&f[2]).0 > 8,
        "still settling at 250 ms, done by 900 ms"
    );
}

#[test]
fn controls_settle_quickly_with_reduce_motion() {
    // Compared up to 600 ms only: the film keeps playing, and the elapsed-time label ticks once a second (at ~0.9 s here).
    let f = player_frames(true, &[40.0, 300.0, 600.0]);
    assert!(
        f[0].diff(&f[1]).0 > 8,
        "the short fade is under way at 40 ms"
    );
    assert!(f[1].diff(&f[2]).0 <= 2, "and over after 0.14 s");
}
