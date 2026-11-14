//! Scroll test harness: feeds synthetic Windows wheel streams through the real `Shell` at a 60 Hz frame clock and logs
//! the page offset per frame (CSV in `$SCROLL_CSV_DIR`, default the temp dir) next to the cumulative input. The asserts
//! are the feel contract: a precision touchpad is 1:1 with the OS stream (no second smoothing), a wheel notch moves on
//! the first frame and lands fast, notches accumulate, the ends give like a rubber band and spring back on the Mac, and never give on Windows and Linux.
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

/// Whether this OS's table lets the ends give (the Mac only; Windows and Linux stop dead).
fn bounces() -> bool {
    swiftly_motion::ScrollTuning::for_os(swiftly_motion::Os::current()).rubber_band
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
fn a_precision_touchpad_stream_in_wheel_lines_never_gives_at_the_top_on_any_os() {
    // Windows delivers a precision touchpad as fractional wheel lines; the shell applies that stream 1:1 and clamped on
    // every OS (the Mac's own touchpad arrives as points with phases, see the next test).
    let ev = touchpad(900.0, 160.0, 120.0);
    let ev: Vec<(f64, f64)> = ev.into_iter().map(|(t, l)| (t, -l)).collect();
    let end = ev.last().unwrap().0;
    let c = play("top-pull-lines", 0.0, &ev, end + 900.0);
    let lowest = c.rows.iter().map(|r| r.2).fold(0.0, f64::min);
    println!(
        "lines pull: deepest {lowest:.1}, final {:.2}",
        c.final_offset()
    );
    assert!(lowest >= -1e-6, "the top never gives ({lowest:.1})");
    assert!(c.final_offset().abs() < 0.5);
}

/// Plays a touchpad pull of points (15 pt per frame for 160 ms, content pulled past the top, then the fingers lift)
/// through the real `Shell`; returns the offset per frame.
fn play_points(total: f64) -> Curve {
    use swiftly_desktop::wheel::WheelPhase;
    let mut s = shell();
    let base = 2000.0;
    let o0 = s.suite_mut().unwrap().page_offset();
    let (mut rows, mut input) = (vec![], 0.0);
    let (mut t, mut lifted) = (0.0, false);
    while t <= total {
        let now = base + t;
        if t <= 160.0 {
            let phase = if t == 0.0 {
                WheelPhase::Started
            } else {
                WheelPhase::Moved
            };
            s.wheel(WheelDelta::Points(0.0, 15.0), Some(phase), now);
            input += 15.0;
        } else if !lifted {
            lifted = true;
            s.wheel(WheelDelta::Points(0.0, 0.0), Some(WheelPhase::Ended), now);
        }
        let _ = s.frame(now);
        rows.push((t, input, s.suite_mut().unwrap().page_offset() - o0));
        t += FRAME;
    }
    Curve { rows }
}

#[test]
fn a_touchpad_pull_past_the_top_gives_like_a_rubber_band_only_on_the_os_that_has_one() {
    let c = play_points(1400.0);
    let lowest = c.rows.iter().map(|r| r.2).fold(0.0, f64::min);
    let sent = c.rows.last().unwrap().1;
    println!(
        "points pull: sent {sent:.0} px, deepest {lowest:.1}, final {:.2}",
        c.final_offset()
    );
    if !bounces() {
        assert!(lowest >= -1e-6, "the top never gives ({lowest:.1})");
        assert!(c.final_offset().abs() < 0.5);
        return;
    }
    assert!(lowest < -10.0, "the top gives ({lowest:.1})");
    assert!(
        lowest > -sent * 0.8,
        "with resistance ({lowest:.1} of {sent:.0})"
    );
    assert!(
        c.final_offset().abs() < 0.5,
        "back at the top: {}",
        c.final_offset()
    );
}

/// Drags the demo's page down past its top with the scroll table of `os` (whatever OS the test runs on) and lets go;
/// returns the deepest page offset during the drag and the offset after the release has settled.
fn demo_pull(os: swiftly_motion::Os) -> (f64, f64) {
    use swiftly_ui::Env;
    let env = Env::new(
        swiftly_layout::Size::new(1100.0, 400.0),
        1.0,
        Idiom::Desktop,
    );
    let mut d = swiftly_desktop::demo::Demo::new(env, Cx::deterministic());
    d.set_scroll_tuning(swiftly_motion::ScrollTuning::for_os(os));
    let mut now = 0.0;
    while now < 1500.0 {
        now += FRAME;
        let _ = d.frame(now);
    }
    let page = |d: &swiftly_desktop::demo::Demo| d.scroll_offsets()[0];
    let mut deepest = page(&d).min(0.0);
    d.touch_down(550.0, 100.0, now);
    for i in 1..=12_u8 {
        now += FRAME;
        d.touch_move(550.0, 100.0 + 25.0 * f32::from(i), now);
        let _ = d.frame(now);
        deepest = deepest.min(page(&d));
    }
    d.touch_up(550.0, 400.0, now);
    let end = now + 1500.0;
    while now < end {
        now += FRAME;
        let _ = d.frame(now);
        deepest = deepest.min(page(&d));
    }
    (deepest, page(&d))
}

#[test]
fn every_scroll_table_decides_alone_whether_the_top_gives() {
    use swiftly_motion::Os;
    let (deep, rest) = demo_pull(Os::MacOs);
    println!("mac table: deepest {deep:.1}, rest {rest:.2}");
    assert!(deep < -10.0, "the Mac keeps its rubber band ({deep:.1})");
    assert!(rest.abs() < 0.5, "and springs back ({rest:.2})");
    for os in [Os::Windows, Os::Linux] {
        let (deep, rest) = demo_pull(os);
        println!("{os:?} table: deepest {deep:.1}, rest {rest:.2}");
        assert!(deep >= -1e-6, "{os:?} never gives ({deep:.1})");
        assert!(rest.abs() < 0.5, "{os:?} rests at the top ({rest:.2})");
    }
}

#[test]
fn wheel_notches_past_the_top_give_a_soft_stop_on_the_mac_and_stop_dead_elsewhere() {
    // Two notches up at the very top: the page gives a few points (a quarter of the excess, at most 28), then settles at 0.
    let c = play("notch-top-bounce", 0.0, &[(8.0, 1.0), (28.0, 1.0)], 900.0);
    let lowest = c.rows.iter().map(|r| r.2).fold(0.0, f64::min);
    println!(
        "notch at the top: deepest {lowest:.1}, final {:.2}",
        c.final_offset()
    );
    if !bounces() {
        assert!(lowest >= -1e-6, "no soft stop ({lowest:.1})");
        assert!(c.final_offset().abs() < 0.5);
        return;
    }
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
