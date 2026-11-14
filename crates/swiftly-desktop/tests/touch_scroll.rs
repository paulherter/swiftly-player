//! Finger scrolling on the desktop shell (GitHub #56): winit touch events become a drag scroll with release-velocity
//! momentum and a rubber band at the ends. Scripted touch sequences, the page offset sampled every 8 ms.
#![allow(clippy::unwrap_used)]

use swiftly_desktop::shell::Shell;
use swiftly_ui::{Cx, Idiom};

fn shell() -> Shell {
    Shell::new_suite((1440, 900), 1.0, Cx::deterministic(), Idiom::Desktop)
}

fn settle(s: &mut Shell, now: &mut f64, ms: f64) {
    let end = *now + ms;
    while *now < end {
        *now += 8.0;
        let _ = s.frame(*now);
    }
}

fn off(s: &mut Shell) -> f64 {
    s.suite_mut().unwrap().page_offset()
}

/// A finger drags from (x, y0) by `dy` (negative = up) in `ms`, one move per 8 ms frame; returns the offsets seen.
fn drag(s: &mut Shell, now: &mut f64, x: f64, y0: f64, dy: f64, ms: f64) -> Vec<f64> {
    s.finger(0, (x, y0), *now);
    let n = (ms / 8.0).round() as usize;
    let mut seen = Vec::new();
    for i in 1..=n {
        *now += 8.0;
        s.finger(1, (x, y0 + dy * i as f64 / n as f64), *now);
        let _ = s.frame(*now);
        seen.push(off(s));
    }
    seen
}

#[test]
fn finger_drag_follows_one_to_one_and_carries_the_release_velocity() {
    let mut s = shell();
    let mut now = 0.0;
    settle(&mut s, &mut now, 500.0);
    let _base = off(&mut s);
    let base = _base;
    // 120 px up in 120 ms: 1:1 while down (inside the range), no easing.
    let seen = drag(&mut s, &mut now, 700.0, 600.0, -120.0, 120.0);
    // The touch slop is absorbed at the grab point; from there every frame moves exactly as far as the finger (8 px).
    let steps: Vec<f64> = seen.windows(2).map(|w| w[1] - w[0]).collect();
    assert!(
        steps.iter().skip(2).all(|d| (d - 8.0).abs() < 0.6),
        "not 1:1: {steps:?}"
    );
    let held = *seen.last().unwrap();
    // Release at speed: the page keeps going (momentum), monotone, and comes to rest.
    s.finger(2, (700.0, 480.0), now);
    let mut after = Vec::new();
    for _ in 0..120 {
        now += 8.0;
        let _ = s.frame(now);
        after.push(off(&mut s));
    }
    assert!(
        after.last().unwrap() - held > 20.0 || (after.last().unwrap() - base) > 150.0,
        "no momentum: {held} -> {}",
        after.last().unwrap()
    );
    // Up to the peak it only moves forward; a fling into the end may rubber-band past it and then only comes back.
    let peak = after
        .iter()
        .position(|v| *v == after.iter().copied().fold(f64::MIN, f64::max))
        .unwrap();
    assert!(
        after[..=peak].windows(2).all(|w| w[1] >= w[0] - 0.01),
        "moved back during momentum"
    );
    assert!(
        after[peak..].windows(2).all(|w| w[1] <= w[0] + 0.01),
        "moved forward again after the peak"
    );
    let end = *after.last().unwrap();
    assert!((after[after.len() - 20] - end).abs() < 0.5, "not at rest");
}

#[test]
fn finger_past_the_end_rubber_bands_and_springs_back() {
    let mut s = shell();
    let mut now = 0.0;
    settle(&mut s, &mut now, 500.0);
    let top = off(&mut s);
    // Pull down at the very top: content follows less than the finger, then returns to the top.
    let seen = drag(&mut s, &mut now, 700.0, 300.0, 300.0, 240.0);
    let pulled = seen.last().unwrap() - top;
    if !cfg!(target_os = "macos") {
        // Windows and Linux never bounce at the ends: the content stays at the top.
        assert!(pulled.abs() < 0.5, "moved {pulled} past the top");
        return;
    }
    assert!(
        pulled.abs() > 10.0 && pulled.abs() < 300.0 * 0.6,
        "rubber band moved {pulled} for a 300 px pull"
    );
    // Held still (no more moves), then lifted.
    s.finger(2, (700.0, 600.0), now);
    settle(&mut s, &mut now, 900.0);
    assert!((off(&mut s) - top).abs() < 0.5, "did not spring back");
}

#[test]
fn a_new_finger_catches_the_momentum_mid_flight() {
    let mut s = shell();
    let mut now = 0.0;
    settle(&mut s, &mut now, 500.0);
    let _ = drag(&mut s, &mut now, 700.0, 700.0, -300.0, 100.0);
    s.finger(2, (700.0, 400.0), now);
    settle(&mut s, &mut now, 40.0);
    let mid = off(&mut s);
    s.finger(0, (700.0, 400.0), now);
    settle(&mut s, &mut now, 200.0);
    let held = off(&mut s);
    assert!(
        (held - mid).abs() < 40.0 && held >= mid,
        "a finger down should hold the page: {mid} -> {held}"
    );
    s.finger(3, (700.0, 400.0), now);
}

#[test]
fn a_second_finger_does_not_move_the_page() {
    let mut s = shell();
    let mut now = 0.0;
    settle(&mut s, &mut now, 500.0);
    let base = off(&mut s);
    s.finger_id(7, 0, (700.0, 600.0), now);
    s.finger_id(9, 0, (300.0, 600.0), now);
    for i in 1..=10 {
        now += 8.0;
        s.finger_id(9, 1, (300.0, 600.0 - 20.0 * f64::from(i)), now);
        let _ = s.frame(now);
    }
    assert!(
        (off(&mut s) - base).abs() < 0.5,
        "second finger moved the page"
    );
    s.finger_id(9, 2, (300.0, 400.0), now);
    s.finger_id(7, 2, (700.0, 600.0), now);
}

#[test]
fn reduce_motion_lets_the_finger_go_without_a_fling() {
    let mut s = shell();
    let mut e = swiftly_ui::Env::new(
        swiftly_layout::Size::new(1440.0, 900.0),
        1.0,
        Idiom::Desktop,
    );
    e.reduce_motion = true;
    s.suite_mut().unwrap().set_env(e);
    let mut now = 0.0;
    settle(&mut s, &mut now, 500.0);
    let seen = drag(&mut s, &mut now, 700.0, 600.0, -120.0, 120.0);
    let held = *seen.last().unwrap();
    s.finger(2, (700.0, 480.0), now);
    let mut after = Vec::new();
    for _ in 0..120 {
        now += 8.0;
        let _ = s.frame(now);
        after.push(off(&mut s));
    }
    let end = *after.last().unwrap();
    // The same release at speed would travel hundreds of points; here the page stays where the finger left it.
    assert!(
        (end - held).abs() < 1.5,
        "fling under Reduce Motion: {held} -> {end}"
    );
    assert!((after[after.len() - 20] - end).abs() < 0.01, "not at rest");
}
