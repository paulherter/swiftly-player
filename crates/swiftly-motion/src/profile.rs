//! Scroll feel per operating system, in one table.
//!
//! The Mac app has no custom scroll physics: AppKit's trackpad momentum and rubber band. On Windows and Linux the OS gives
//! the app wheel and touchpad events but no momentum, so the engine glides itself. [`ScrollTuning`] holds every number
//! of that emulation; [`ScrollTuning::for_os`] fills it with the documented public values, and the fields marked
//! `measured` are the slots for the Mac scroll measurements (`None` = still unmeasured, the documented
//! estimate stays in force).

use crate::tuning;

/// The operating system whose scroll feel is wanted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Os {
    /// macOS (the engine never runs there as the Mac app, but tests and the parity harness use it).
    MacOs,
    /// Windows.
    Windows,
    /// Linux (Wayland, X11).
    Linux,
}

impl Os {
    /// The OS this binary runs on.
    pub fn current() -> Os {
        if cfg!(target_os = "windows") {
            Os::Windows
        } else if cfg!(target_os = "macos") {
            Os::MacOs
        } else {
            Os::Linux
        }
    }
}

/// How a released flick glides.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Glide {
    /// Velocity keeps this factor per millisecond (UIKit `DecelerationRate`, GTK friction as a rate).
    Exponential(f64),
    /// The WebKit-derived macOS curve: 0.975 per 8 ms, tightening to 0.91 below 250 pt/s.
    MacTrackpad,
}

/// All scroll numbers of one OS.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScrollTuning {
    /// The OS this table is for.
    pub os: Os,
    /// Glide of a touchpad or pointer release.
    pub release: Glide,
    /// Window (ms) after which a still finger releases without velocity.
    pub velocity_stale_ms: f64,
    /// Slowest release (pt/s) that still glides.
    pub min_fling_speed: f64,
    /// Points per wheel notch (before the viewport rule of Linux).
    pub notch_px: f64,
    /// Linux: the notch is `viewport^(2/3)` instead of `notch_px`.
    pub notch_by_viewport: bool,
    /// Milliseconds a notch takes to land (easeInOut, retargeted).
    pub notch_smoothing_ms: f64,
    /// Multiplier of touchpad pixels (1.0 on the Mac; GTK uses 2.5).
    pub touchpad_gain: f64,
    /// Rubber band at the ends for touchpad flicks (a wheel never bounces).
    pub rubber_band: bool,
    /// Poster rails snap to item starts after a flick (the Mac rails do not).
    pub rail_snaps: bool,
    /// Measured: rubber band coefficient of AppKit (`None` = UIKit 0.55 stays).
    pub measured_rubber_c: Option<f64>,
    /// Measured: seconds of AppKit's rebound (`None` = 0.45 s stays).
    pub measured_rebound_s: Option<f64>,
}

impl ScrollTuning {
    /// The public values of `os`.
    pub fn for_os(os: Os) -> ScrollTuning {
        let base = ScrollTuning {
            os,
            release: Glide::MacTrackpad,
            velocity_stale_ms: tuning::MAC_VELOCITY_STALE_MS,
            min_fling_speed: tuning::MAC_MIN_FLING_SPEED,
            notch_px: tuning::WHEEL_NOTCH_PX_WINDOWS,
            notch_by_viewport: false,
            notch_smoothing_ms: tuning::WHEEL_SMOOTH_MS,
            touchpad_gain: 1.0,
            rubber_band: true,
            rail_snaps: false,
            measured_rubber_c: None,
            measured_rebound_s: None,
        };
        match os {
            Os::MacOs | Os::Windows => base,
            // The glide shape stays the Mac's on Linux because the goal is the Mac feel; GTK's friction is kept as the
            // documented alternative (`ScrollTuning::gtk_kinetic`). Only the notch size follows libinput/GTK.
            Os::Linux => ScrollTuning {
                notch_by_viewport: true,
                ..base
            },
        }
    }

    /// The same table with the GTK kinetic glide (`v = v0 e^(-4 t)`) and its touchpad gain, for a native Linux feel.
    #[must_use]
    pub fn gtk_kinetic(mut self) -> ScrollTuning {
        self.release = Glide::Exponential((-tuning::GTK_KINETIC_FRICTION / 1000.0).exp());
        self.touchpad_gain = tuning::GTK_TOUCHPAD_GAIN;
        self
    }

    /// The touch-screen table: UIKit deceleration 0.998 per millisecond, rubber band, rails snap.
    pub fn touch() -> ScrollTuning {
        ScrollTuning {
            release: Glide::Exponential(tuning::DECELERATION_NORMAL),
            velocity_stale_ms: tuning::VELOCITY_STALE_MS,
            min_fling_speed: tuning::MIN_FLING_SPEED,
            rail_snaps: true,
            ..ScrollTuning::for_os(Os::Windows)
        }
    }

    /// Points one wheel notch moves a viewport of `viewport` points.
    pub fn notch(&self, viewport: f64) -> f64 {
        if self.notch_by_viewport {
            viewport.max(1.0).powf(tuning::GTK_NOTCH_EXPONENT)
        } else {
            self.notch_px
        }
    }
}

/// Cumulative displacement (pt) of the Mac momentum curve every [`tuning::MAC_MOMENTUM_STEP_MS`] ms for a release at
/// `v0` pt/s (signed); entry 0 is 0. The last entry is the resting place.
pub fn mac_momentum_table(v0: f64) -> Vec<f64> {
    let step = tuning::MAC_MOMENTUM_STEP_MS / 1000.0;
    let (fast, slow, below) = (
        tuning::MAC_MOMENTUM_DECAY_FAST,
        tuning::MAC_MOMENTUM_DECAY_SLOW,
        tuning::MAC_MOMENTUM_SLOW_BELOW,
    );
    let mut table = vec![0.0];
    let (mut v, mut x) = (v0, 0.0);
    while v.abs() > tuning::MAC_MOMENTUM_STOP_SPEED && table.len() < 4000 {
        let alpha = fast - (fast - slow) * ((below - v.abs()) / below).clamp(0.0, 1.0);
        v *= alpha;
        x += v * step;
        table.push(x);
    }
    table
}

/// Smooth landing of discrete wheel notches: every notch adds to the target and the value moves toward it with an
/// ease-out of [`ScrollTuning::notch_smoothing_ms`], restarting from where it is (Chromium's retargeting, our curve).
#[derive(Clone, Copy, Debug, Default)]
pub struct NotchGlide {
    from: f64,
    target: f64,
    t0: f64,
    ms: f64,
    /// How much of the way was already handed out.
    given: f64,
}

/// The curve of a wheel notch: `cubic-bezier(0.23, 1, 0.32, 1)` (ease-out, the house enter curve). It moves on the very
/// first frame (an ease-in-out is slow to start and feels like lag) and settles softly.
fn ease_in_out(u: f64) -> f64 {
    let (x1, y1, x2, y2) = (0.23, 1.0, 0.32, 1.0);
    let at = |t: f64, a: f64, b: f64| {
        let m = 1.0 - t;
        3.0 * m * m * t * a + 3.0 * m * t * t * b + t * t * t
    };
    let (mut lo, mut hi) = (0.0, 1.0);
    for _ in 0..32 {
        let mid = 0.5 * (lo + hi);
        if at(mid, x1, x2) < u {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    at(0.5 * (lo + hi), y1, y2)
}

impl NotchGlide {
    /// A resting glide.
    pub fn new() -> NotchGlide {
        NotchGlide::default()
    }

    /// Whether points are still on their way.
    pub fn is_active(&self) -> bool {
        (self.target - self.given).abs() > 1e-6
    }

    /// One notch of `delta` points at `now` ms, landing over `ms` milliseconds.
    pub fn push(&mut self, delta: f64, now: f64, ms: f64) {
        self.from = self.value_at(now);
        self.target += delta;
        self.t0 = now;
        self.ms = ms.max(1.0);
    }

    fn value_at(&self, now: f64) -> f64 {
        if !self.is_active() {
            return self.target;
        }
        let u = ((now - self.t0) / self.ms).clamp(0.0, 1.0);
        if u >= 1.0 {
            return self.target;
        }
        self.from + (self.target - self.from) * ease_in_out(u)
    }

    /// The points to move since the last call, as of `now`.
    pub fn take(&mut self, now: f64) -> f64 {
        let v = self.value_at(now);
        let d = v - self.given;
        self.given = v;
        d
    }

    /// Drops what has not been handed out yet (the pointer left, the page changed).
    pub fn cancel(&mut self) {
        self.target = self.given;
        self.from = self.given;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rest(v0: f64) -> (f64, f64) {
        let t = mac_momentum_table(v0);
        (
            *t.last().unwrap_or(&0.0),
            (t.len() - 1) as f64 * tuning::MAC_MOMENTUM_STEP_MS / 1000.0,
        )
    }

    #[test]
    fn mac_momentum_matches_the_derived_distance_table() {
        // D-motion-and-feel.md section 3.2: (v0, distance, seconds).
        for (v0, dist, secs) in [
            (500.0, 115.0, 0.82),
            (1000.0, 269.0, 1.03),
            (2000.0, 576.0, 1.25),
            (4000.0, 1192.0, 1.48),
        ] {
            let (d, t) = rest(v0);
            assert!((d - dist).abs() / dist < 0.03, "{v0}: {d} vs {dist}");
            assert!((t - secs).abs() < 0.05, "{v0}: {t} vs {secs}");
        }
    }

    #[test]
    fn mac_momentum_goes_much_less_far_than_the_iphone_glide_and_is_symmetric() {
        let (mac, _) = rest(2000.0);
        let iphone = crate::scroll::project_exact(2000.0, tuning::DECELERATION_NORMAL);
        assert!(mac < iphone * 0.65, "{mac} vs {iphone}");
        let (back, _) = rest(-2000.0);
        assert!((back + mac).abs() < 1e-9, "symmetric");
    }

    #[test]
    fn os_tables_differ_where_the_inputs_differ() {
        let win = ScrollTuning::for_os(Os::Windows);
        let lin = ScrollTuning::for_os(Os::Linux);
        assert_eq!(win.notch(800.0), 100.0);
        assert!((lin.notch(1000.0) - 100.0).abs() < 1e-9, "1000^(2/3) = 100");
        assert!(!win.rail_snaps && !lin.rail_snaps);
        assert!(ScrollTuning::touch().rail_snaps);
        assert_eq!(ScrollTuning::touch().release, Glide::Exponential(0.998));
        let Glide::Exponential(r) = lin.gtk_kinetic().release else {
            panic!("exponential")
        };
        assert!((r - 0.996_008).abs() < 1e-5, "{r}");
    }

    #[test]
    fn notches_land_ease_out_and_retarget_without_going_back() {
        let mut g = NotchGlide::new();
        g.push(100.0, 0.0, 150.0);
        let mut total = 0.0;
        let mut half = 0.0;
        for i in 1..=10 {
            total += g.take(f64::from(i) * 16.0);
            if i == 5 {
                half = total;
            }
        }
        assert!((total - 100.0).abs() < 1e-6, "{total}");
        assert!(
            half > 60.0 && half < 98.0,
            "ease-out is mostly there at 80 ms: {half}"
        );
        assert!(!g.is_active());
        let mut g = NotchGlide::new();
        g.push(100.0, 0.0, 150.0);
        let mut sum = g.take(50.0);
        g.push(100.0, 50.0, 150.0);
        for i in 1..=20 {
            let d = g.take(50.0 + f64::from(i) * 10.0);
            assert!(d >= -1e-9, "never backwards: {d}");
            sum += d;
        }
        assert!((sum - 200.0).abs() < 1e-6, "{sum}");
    }
}
