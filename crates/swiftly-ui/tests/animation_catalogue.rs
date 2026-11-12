//! Frame-sampled check of every catalogued animation: the value the UI engine shows every 8 ms against an independent
//! reference built only from the SwiftUI definition (bezier table, RK4 of the damped spring with `k = (2 pi / d)^2`,
//! `c = 4 pi zeta / d`). Max error 0.5 % of the travel. Also: no screen source builds a curve of its own.

use swiftly_motion::ScrollMetrics;
use swiftly_motion::catalogue::{self, ALL, Id, Repeat, Spec};
use swiftly_motion::curve::{Ease, Kind};
use swiftly_ui::nav::{Nav, NavStyle};
use swiftly_ui::{Animated, Motion};

const TRAVEL_FROM: f64 = 100.0;
const TRAVEL_TO: f64 = 340.0;
const TOLERANCE: f64 = 0.005 * (TRAVEL_TO - TRAVEL_FROM);

/// Independent bezier: a dense table of the parametric curve read back by interpolation on x.
fn table_ease(e: Ease, u: f64) -> f64 {
    let (x1, y1, x2, y2) = e.points();
    let n = 100_000;
    let pt = |i: usize| {
        let t = i as f64 / n as f64;
        let m = 1.0 - t;
        (
            3.0 * m * m * t * x1 + 3.0 * m * t * t * x2 + t * t * t,
            3.0 * m * m * t * y1 + 3.0 * m * t * t * y2 + t * t * t,
        )
    };
    let (mut lo, mut hi) = (0, n);
    while hi - lo > 1 {
        let mid = (lo + hi) / 2;
        if pt(mid).0 < u {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    let ((xa, ya), (xb, yb)) = (pt(lo), pt(hi));
    if xb == xa {
        ya
    } else {
        ya + (yb - ya) * (u - xa) / (xb - xa)
    }
}

/// `(stiffness, damping)` of a spring spec from the SwiftUI definitions, mass 1.
fn kc(spec: Spec) -> Option<(f64, f64)> {
    let tau = std::f64::consts::TAU;
    let preset = |d: f64, bounce: f64| ((tau / d).powi(2), 2.0 * tau / d * (1.0 - bounce));
    Some(match spec {
        Spec::Smooth(d) => preset(d, 0.0),
        Spec::Snappy(d) => preset(d, 0.15),
        Spec::Bouncy(d) => preset(d, 0.3),
        Spec::Response(r, z) => ((tau / r).powi(2), 2.0 * tau / r * z),
        Spec::Interpolating(w) => (w * w, 2.0 * w),
        _ => return None,
    })
}

/// RK4 state `(displacement, velocity)` of `x'' = -k x - c x'` after `t` seconds.
fn rk4(k: f64, c: f64, mut x: f64, mut v: f64, t: f64) -> (f64, f64) {
    let dt = 0.00005;
    let n = (t / dt).round() as usize;
    let f = |x: f64, v: f64| (v, -k * x - c * v);
    for _ in 0..n {
        let (k1x, k1v) = f(x, v);
        let (k2x, k2v) = f(x + 0.5 * dt * k1x, v + 0.5 * dt * k1v);
        let (k3x, k3v) = f(x + 0.5 * dt * k2x, v + 0.5 * dt * k2v);
        let (k4x, k4v) = f(x + dt * k3x, v + dt * k3v);
        x += dt / 6.0 * (k1x + 2.0 * k2x + 2.0 * k3x + k4x);
        v += dt / 6.0 * (k1v + 2.0 * k2v + 2.0 * k3v + k4v);
    }
    (x, v)
}

/// The reference value of entry `e` `t` seconds after a 0 -> 1 step.
fn reference_progress(e: &catalogue::Entry, t: f64) -> f64 {
    let t = t - e.delay;
    if t <= 0.0 {
        return 0.0;
    }
    match e.spec {
        Spec::Linear(s) => (t / s).min(1.0),
        Spec::EaseIn(s) => table_ease(Ease::In, (t / s).min(1.0)),
        Spec::EaseOut(s) => table_ease(Ease::Out, (t / s).min(1.0)),
        Spec::EaseInOut(s) => table_ease(Ease::InOut, (t / s).min(1.0)),
        spec => {
            let Some((k, c)) = kc(spec) else {
                return f64::NAN;
            };
            1.0 - rk4(k, c, 1.0, 0.0, t).0
        }
    }
}

#[test]
fn every_catalogued_animation_follows_its_swiftui_curve_every_8_ms() {
    let mut checked = 0;
    for e in ALL {
        // Rust-only and repeating entries have their own tests below.
        if e.repeat != Repeat::Once || matches!(e.spec, Spec::SettlingIn(_)) {
            continue;
        }
        let t0 = 5_000.0;
        let mut a = Animated::new(TRAVEL_FROM);
        a.set_target(TRAVEL_TO, t0, Motion::of(e.id));
        let end = e.curve().settle_seconds() + 0.25;
        let mut worst: f64 = 0.0;
        let mut ms = 0.0;
        while ms <= end * 1000.0 {
            a.advance(t0 + ms);
            let want = TRAVEL_FROM + (TRAVEL_TO - TRAVEL_FROM) * reference_progress(e, ms / 1000.0);
            worst = worst.max((a.value() - want).abs());
            ms += 8.0;
        }
        assert!(
            worst < TOLERANCE,
            "{} ({}): max error {worst:.4} of {} travel",
            e.name,
            e.swift,
            TRAVEL_TO - TRAVEL_FROM
        );
        // The engine rests once the remaining distance and speed are invisible (0.001 pt): within a second more.
        let mut late = end * 1000.0;
        while a.is_active() && late < (end + 1.5) * 1000.0 {
            late += 8.0;
            a.advance(t0 + late);
        }
        assert!(
            !a.is_active() && a.value() == TRAVEL_TO,
            "{} rests on its target",
            e.name
        );
        checked += 1;
    }
    let expected = ALL
        .iter()
        .filter(|e| e.repeat == Repeat::Once && !matches!(e.spec, Spec::SettlingIn(_)))
        .count();
    assert_eq!(checked, expected);
    assert!(checked >= 45, "only {checked} animations were checked");
}

#[test]
fn an_interrupted_spring_keeps_position_and_velocity_like_swiftui() {
    for id in [
        Id::Leap,
        Id::Sheet,
        Id::Default,
        Id::AccountPicker,
        Id::CardAppear,
    ] {
        let e = id.entry();
        let (k, c) = kc(e.spec).expect("a spring");
        let mut a = Animated::new(0.0);
        a.set_target(100.0, 0.0, Motion::of(id));
        // Interrupt at 90 ms, reverse to -50; the reference continues the same ODE from the state at the interruption.
        let (x1, v1) = rk4(k, c, -100.0, 0.0, 0.09);
        a.set_target(-50.0, 90.0, Motion::of(id));
        a.advance(90.0);
        assert!(
            (a.value() - (100.0 + x1)).abs() < 0.01,
            "{id:?}: position continuous"
        );
        assert!(
            (a.velocity() - v1).abs() < 0.5,
            "{id:?}: velocity continuous {} vs {v1}",
            a.velocity()
        );
        // After the interruption the displacement from the new target starts at (100 + x1) + 50 with velocity v1.
        let (x0, v0) = (100.0 + x1 + 50.0, v1);
        let mut worst: f64 = 0.0;
        let mut ms = 8.0;
        while ms < 900.0 {
            a.advance(90.0 + ms);
            let (x, _) = rk4(k, c, x0, v0, ms / 1000.0);
            worst = worst.max((a.value() - (-50.0 + x)).abs());
            ms += 8.0;
        }
        assert!(
            worst < 0.005 * 150.0,
            "{id:?}: interrupted path off by {worst}"
        );
    }
}

/// SwiftUI blends an interrupted bezier animation additively (`CustomAnimation.shouldMerge` returns false, "both animations run
/// together and the system combines their results"; WWDC23 10156: the vectors are added). Reference: the two steps as
/// independent curves, summed.
#[test]
fn an_interrupted_tween_runs_on_and_the_new_step_is_added() {
    for (id, cut_ms) in [
        (Id::Reveal, 100.0),
        (Id::Float, 40.0),
        (Id::Arrow, 70.0),
        (Id::PagesPush, 200.0),
    ] {
        let (secs, ease) = match id.entry().spec {
            Spec::EaseInOut(s) => (s, Ease::InOut),
            Spec::EaseOut(s) => (s, Ease::Out),
            _ => panic!("a tween"),
        };
        let mut a = Animated::new(0.0);
        a.set_target(1.0, 0.0, Motion::of(id));
        a.advance(cut_ms);
        let mid = a.value();
        a.set_target(0.0, cut_ms, Motion::of(id));
        assert!(
            (a.value() - mid).abs() < 1e-9,
            "{id:?}: the shown value does not jump"
        );
        let mut worst: f64 = 0.0;
        let mut ms = 0.0;
        while ms <= secs * 1000.0 + 20.0 {
            a.advance(cut_ms + ms);
            let first = table_ease(ease, ((cut_ms + ms) / 1000.0 / secs).min(1.0));
            let second = table_ease(ease, (ms / 1000.0 / secs).min(1.0));
            worst = worst.max((a.value() - (first - second)).abs());
            ms += 8.0;
        }
        assert!(worst < 0.005, "{id:?}: additive path off by {worst}");
    }
}

#[test]
fn a_hover_in_and_out_in_quick_succession_never_jumps_and_ends_at_rest() {
    let mut a = Animated::new(0.0);
    let mut now = 0.0;
    for i in 0..30 {
        a.set_target(
            if i % 2 == 0 { 1.0 } else { 0.0 },
            now,
            Motion::of(Id::Float),
        );
        let before = a.value();
        a.advance(now + 0.001);
        assert!((a.value() - before).abs() < 0.2, "no jump at {i}");
        now += 37.0;
    }
    a.advance(now + 2000.0);
    assert!(!a.is_active());
    assert_eq!(a.value(), 0.0);
}

#[test]
fn the_page_push_follows_easeinout_0_45_and_the_pop_mirrors_it() {
    let e = Id::PagesPush.entry();
    let Spec::EaseInOut(secs) = e.spec else {
        panic!("a tween")
    };
    let mut nav: Nav<u8> = Nav::new(0, NavStyle::Desktop);
    nav.push(1, 1_000.0);
    let mut worst: f64 = 0.0;
    let mut ms = 0.0;
    while ms <= 600.0 {
        nav.update(1_000.0 + ms);
        let want = table_ease(Ease::InOut, (ms / 1000.0 / secs).min(1.0));
        worst = worst.max((nav.position() - want).abs());
        ms += 8.0;
    }
    assert!(worst < 0.005, "push off by {worst}");
    assert!(!nav.is_animating() && nav.position() == 1.0);
    assert!(nav.pop(2_000.0));
    let mut ms = 0.0;
    while ms <= 600.0 {
        nav.update(2_000.0 + ms);
        let want = 1.0 - table_ease(Ease::InOut, (ms / 1000.0 / secs).min(1.0));
        worst = worst.max((nav.position() - want).abs());
        ms += 8.0;
    }
    assert!(worst < 0.005, "pop off by {worst}");
}

#[test]
fn rail_paging_scrolls_with_reveal_and_the_alphabet_jump_with_select() {
    for (id, tween) in [(Id::Reveal, true), (Id::Select, false)] {
        let e = id.entry();
        let mut body = swiftly_motion::ScrollBody::new(ScrollMetrics::new(5_000.0, 800.0), 0.0);
        body.animate_curve(498.0, id.curve(), 0.0);
        let mut worst: f64 = 0.0;
        let mut ms = 0.0;
        while ms <= 900.0 {
            body.advance(ms);
            let want = 498.0 * reference_progress(e, ms / 1000.0);
            worst = worst.max((body.position() - want).abs());
            ms += 8.0;
        }
        assert!(worst < 0.005 * 498.0, "{id:?}: scroll off by {worst}");
        assert_eq!(body.position(), 498.0);
        assert_eq!(matches!(id.curve().kind, Kind::Tween { .. }), tween);
    }
}

#[test]
fn the_pulse_runs_easeinout_0_9_back_and_forth() {
    let mut a = Animated::new(1.0);
    a.set_target(0.5, 0.0, Motion::of(Id::Pulse));
    let mut ms = 0.0;
    while ms <= 3_600.0 {
        a.advance(ms);
        let phase = (ms / 900.0) % 2.0;
        let tri = if phase < 1.0 { phase } else { 2.0 - phase };
        let want = 1.0 - 0.5 * table_ease(Ease::InOut, tri);
        assert!((a.value() - want).abs() < 0.0025, "{ms} ms");
        ms += 8.0;
    }
    assert!(a.is_active());
}

#[test]
fn reduce_motion_is_linear_0_14_for_every_curve() {
    for e in ALL {
        let m = Motion::of(e.id).resolved(true);
        if e.repeat == Repeat::Pulse {
            assert_eq!(m, Motion::Instant, "{}", e.name);
        } else {
            assert_eq!(m.curve(), Some(Id::Reduced.curve()), "{}", e.name);
        }
    }
}

/// Source files under `dir` (`*.rs`, recursive), skipping `tests` folders.
fn rust_files(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in rd.flatten() {
        let p = entry.path();
        if p.is_dir() {
            if p.file_name().is_some_and(|n| n != "tests" && n != "target") {
                rust_files(&p, out);
            }
        } else if p.extension().is_some_and(|x| x == "rs") {
            out.push(p);
        }
    }
}

/// No screen or UI file builds a timing curve by hand: motions come from `feel::*` or `Motion::of(Id::..)`. The
/// allowed files are the ones that define the vocabulary (the engine, the feel table, tests inside them).
#[test]
fn no_screen_source_animates_with_a_curve_outside_the_catalogue() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
    let mut files = Vec::new();
    for c in [
        "swiftly-ui/src",
        "swiftly-desktop/src",
        "swiftly-android/src",
        "swiftly-ios/src",
    ] {
        rust_files(&root.join(c), &mut files);
    }
    let forbidden = [
        "Motion::EaseOut(",
        "Motion::EaseIn(",
        "Motion::EaseInOut(",
        "Motion::Linear(",
        "Motion::Spring(",
        "Motion::Delayed",
        "Motion::Pulse(",
        "Motion::Curve(",
        "Spring::from_",
        "Spring::smooth",
        "Spring::snappy",
        "Spring::bouncy",
        "Spring::critical",
        "Spring::interactive",
        "Spring::default_ui",
        "Spring::spring_default",
        "Curve::tween(",
        "Curve::spring(",
        "bezier(",
    ];
    // `lottie.rs` plays the easing of the Lottie file itself (the start animation), not a UI curve.
    let allowed = [
        "swiftly-ui/src/anim.rs",
        "swiftly-ui/src/feel.rs",
        "swiftly-ui/src/nav.rs",
        "swiftly-desktop/src/lottie.rs",
    ];
    let mut offenders = Vec::new();
    for f in files {
        let rel = f.to_string_lossy().replace('\\', "/");
        if allowed.iter().any(|a| rel.ends_with(a)) {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&f) else {
            continue;
        };
        let text = text.split("#[cfg(test)]").next().unwrap_or_default();
        for (n, line) in text.lines().enumerate() {
            if line.trim_start().starts_with("//") {
                continue;
            }
            if let Some(bad) = forbidden.iter().find(|b| line.contains(**b)) {
                offenders.push(format!(
                    "{}:{}: {bad}",
                    rel.rsplit("crates/").next().unwrap_or(&rel),
                    n + 1
                ));
            }
        }
    }
    assert!(
        offenders.is_empty(),
        "curves outside the catalogue (use feel::* or Motion::of(Id::..)):\n{}",
        offenders.join("\n")
    );
}
