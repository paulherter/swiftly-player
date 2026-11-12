//! Scroll test harness: feeds synthetic Windows wheel streams through the real `Shell` at a 60 Hz frame clock and logs
//! the page offset per frame (CSV in `$SCROLL_CSV_DIR`, default the temp dir) next to the cumulative input. The asserts
//! are the feel contract: a precision touchpad is 1:1 with the OS stream (no second smoothing), a wheel notch moves on
//! the first frame and lands fast, notches accumulate, the ends give like a rubber band and spring back.
#![allow(clippy::unwrap_used)]

use std::fmt::Write as _;
use swiftly_desktop::shell::Shell;
use swiftly_desktop::wheel::WheelDelta;
use swiftly_ui::{Cx, Idiom};

const FRAME: f64 = 1000.0 / 60.0;
/// Points per wheel notch on this OS for the 300 pt viewport of `shell()`: 100 on Windows and the Mac, `300^(2/3)` on
/// Linux (the GTK/libinput notch follows the viewport, see `ScrollTuning`).
fn notch_px() -> f64 {
    swiftly_motion::ScrollTuning::for_os(swiftly_motion::Os::current()).notch(300.0)
}

fn shell() -> Shell {
    // A short window so the Start page has a long way to scroll.
    let mut s = Shell::new_suite((1440, 300), 1.0, Cx::deterministic(), Idiom::Desktop);
    let mut t = 0.0;
    while t < 600.0 {
        t += FRAME;
        let _ = s.frame(t);
    }
    s.cursor_moved((700.0, 120.0), t);
    s
}

struct Curve {
    /// (time since the first event, input so far in px, page offset).
    rows: Vec<(f64, f64, f64)>,
}

/// Plays `events` (time ms from 0, lines of wheel; positive = away from the user = content down) for `total` ms.
fn play(name: &str, start_offset: f64, events: &[(f64, f64)], total: f64) -> Curve {
    let mut s = shell();
    let base = 2000.0;
    // Scroll to the starting offset first with the page's own call (not part of the curve).
    if start_offset != 0.0 {
        s.suite_mut()
            .unwrap()
            .wheel_scroll(700.0, 120.0, 0.0, start_offset as f32, base - 500.0);
        let mut t = base - 500.0;
        while t < base {
            t += FRAME;
            let _ = s.frame(t);
        }
    }
    let o0 = s.suite_mut().unwrap().page_offset();
    let (mut rows, mut input, mut i) = (vec![], 0.0, 0);
    let mut t = 0.0;
    while t <= total {
        while i < events.len() && events[i].0 <= t {
            s.wheel(
                WheelDelta::Lines(0.0, events[i].1 as f32),
                None,
                base + events[i].0,
            );
            input += -events[i].1 * notch_px();
            i += 1;
        }
        let _ = s.frame(base + t);
        rows.push((t, input, s.suite_mut().unwrap().page_offset() - o0));
        t += FRAME;
    }
    let mut csv = String::from("t_ms,input_px,offset_px\n");
    for r in &rows {
        let _ = writeln!(csv, "{:.1},{:.2},{:.2}", r.0, r.1, r.2);
    }
    let dir = std::env::var("SCROLL_CSV_DIR")
        .map_or_else(|_| std::env::temp_dir(), std::path::PathBuf::from);
    let _ = std::fs::create_dir_all(&dir);
    let _ = std::fs::write(dir.join(format!("scroll-{name}.csv")), csv);
    Curve { rows }
}

impl Curve {
    fn final_offset(&self) -> f64 {
        self.rows.last().unwrap().2
    }
    /// First time (ms) the offset reached `frac` of its final value.
    fn reach(&self, frac: f64) -> f64 {
        let f = self.final_offset();
        self.rows
            .iter()
            .find(|r| f != 0.0 && r.2 / f >= frac)
            .map_or(f64::NAN, |r| r.0)
    }
    /// Largest distance between the input stream and the page while the stream runs.
    fn max_lag(&self, until: f64) -> f64 {
        self.rows
            .iter()
            .filter(|r| r.0 <= until)
            .map(|r| (r.1 - r.2).abs())
            .fold(0.0, f64::max)
    }
    /// Largest step between two frames (judder shows as spikes).
    fn max_step(&self) -> f64 {
        self.rows
            .windows(2)
            .map(|w| (w[1].2 - w[0].2).abs())
            .fold(0.0, f64::max)
    }
}

/// A Windows precision touchpad: events every 8 ms with the finger (constant speed `v` px/s for `finger` ms), then the
/// OS's own inertia (exponential decay, time constant `tau` ms) until it is below a pixel per second.
fn touchpad(v: f64, finger: f64, tau: f64) -> Vec<(f64, f64)> {
    let mut out = vec![];
    let mut t = 0.0;
    let mut speed = v;
    while speed > 5.0 {
        let px = speed * 0.008;
        out.push((t, -px / notch_px()));
        t += 8.0;
        if t > finger {
            speed *= (-8.0 / tau).exp();
        }
    }
    out
}

#[test]
fn precision_touchpad_follows_the_os_stream_one_to_one() {
    let ev = touchpad(900.0, 160.0, 350.0);
    let sent: f64 = ev.iter().map(|e| -e.1 * notch_px()).sum();
    let end = ev.last().unwrap().0;
    let c = play("touchpad-900", 0.0, &ev, end + 600.0);
    let lag = c.max_lag(end);
    println!(
        "touchpad: sent {sent:.0} px, final {:.0}, max lag {lag:.1} px, max step {:.1} px",
        c.final_offset(),
        c.max_step()
    );
    // Within one frame of the stream (at most 900 px/s * 16.7 ms = 15 px, plus the events of the same frame).
    assert!(lag < 20.0, "the page trails the OS stream by {lag:.1} px");
    assert!(
        (c.final_offset() - sent).abs() < 1.0,
        "no extra glide: {} vs {sent}",
        c.final_offset()
    );
}

#[test]
fn a_wheel_notch_starts_on_the_first_frame_and_lands_fast() {
    let c = play("notch-1", 0.0, &[(8.0, -1.0)], 700.0);
    // The event lands half a frame before the first frame that shows it.
    let first = c.rows[1].2;
    for r in c.rows.iter().take(14) {
        println!("  t {:.0} ms  offset {:.1}", r.0, r.2);
    }
    println!(
        "notch: first frame {first:.1} px, 50% {:.0} ms, 90% {:.0} ms, final {:.0}",
        c.reach(0.5),
        c.reach(0.9),
        c.final_offset()
    );
    assert!((c.final_offset() - notch_px()).abs() < 0.5);
    assert!(first > 5.0, "the first frame already moves ({first:.1} px)");
    assert!(c.reach(0.9) <= 160.0, "90 % in {} ms", c.reach(0.9));
}

#[test]
fn six_notches_accumulate_without_lag_or_overshoot() {
    let ev: Vec<(f64, f64)> = (0..6).map(|i| (f64::from(i) * 20.0, -1.0)).collect();
    let c = play("notch-10", 0.0, &ev, 900.0);
    println!(
        "6 notches: final {:.0}, 90% {:.0} ms, max step {:.1}",
        c.final_offset(),
        c.reach(0.9),
        c.max_step()
    );
    assert!((c.final_offset() - 6.0 * notch_px()).abs() < 0.5);
    assert!(
        c.rows.windows(2).all(|w| w[1].2 >= w[0].2 - 1e-6),
        "never backwards"
    );
    assert!(
        c.reach(0.9) <= 200.0 + 170.0,
        "settles within {} ms of the first",
        c.reach(0.9)
    );
}

#[test]
fn pulling_past_the_top_gives_like_a_rubber_band_and_springs_back() {
    // A touchpad pull of 300 px past the top.
    let ev = touchpad(900.0, 160.0, 120.0);
    let sent: f64 = -ev.iter().map(|e| -e.1 * notch_px()).sum::<f64>();
    let ev: Vec<(f64, f64)> = ev.into_iter().map(|(t, l)| (t, -l)).collect();
    let end = ev.last().unwrap().0;
    let c = play("top-pull", 0.0, &ev, end + 900.0);
    let lowest = c.rows.iter().map(|r| r.2).fold(0.0, f64::min);
    println!(
        "top pull: sent {sent:.0} px, deepest {lowest:.1}, final {:.2}",
        c.final_offset()
    );
    assert!(lowest < -10.0, "the top gives ({lowest:.1})");
    assert!(
        lowest > -(sent.abs()) * 0.8,
        "with resistance ({lowest:.1} of {sent:.0})"
    );
    assert!(
        c.final_offset().abs() < 0.5,
        "back at the top: {}",
        c.final_offset()
    );
}

#[test]
fn wheel_notches_past_the_top_give_a_soft_stop_and_spring_back() {
    // Two notches up at the very top: the page gives a few points (a quarter of the excess, at most 28), then settles at 0.
    let c = play("notch-top-bounce", 0.0, &[(8.0, 1.0), (28.0, 1.0)], 900.0);
    let lowest = c.rows.iter().map(|r| r.2).fold(0.0, f64::min);
    println!(
        "notch at the top: deepest {lowest:.1}, final {:.2}",
        c.final_offset()
    );
    assert!((-28.5..-5.0).contains(&lowest), "soft stop ({lowest:.1})");
    assert!(
        c.final_offset().abs() < 0.5,
        "back at the top: {}",
        c.final_offset()
    );
    assert!(
        c.rows.iter().all(|r| r.2 <= 1e-6),
        "never past the top the other way"
    );
}
