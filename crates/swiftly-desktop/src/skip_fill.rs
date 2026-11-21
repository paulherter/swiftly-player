//! The fill of the skip button while "skip automatically" counts down, and the ring of the next-episode card.
//!
//! The core reports the share (0 to 1) when the player ticks, a few times a second, so a fill drawn from it moves in
//! steps. The Apple players compute the fill from the clock on every frame (`FillClock`); this does the same: between two
//! reports the share runs on at the pace of the countdown, on the render clock, and each report only pulls it back to a
//! small band around the core's value, so it never jumps backwards and never drifts away.

/// Length of the skip countdown in seconds (`OfferingLayer.buttonDuration`).
pub const SKIP_SECONDS: f64 = 6.0;

/// How far ahead of or behind the core's last report the drawn share may run, in shares of the whole button.
const AHEAD: f64 = 0.08;
const BEHIND: f64 = 0.02;

/// Length of the card's countdown in seconds (`OfferingLayer.countdown`).
pub const CARD_SECONDS: f64 = 7.0;

/// The smoothed share of one countdown.
#[derive(Debug)]
pub struct SkipFill {
    /// Seconds the countdown takes from 0 to 1.
    length: f64,
    /// The drawn share at `at`, and the core's last reported value.
    base: f64,
    at: f64,
    core: f64,
    /// Whether a countdown is running (the core reported a share).
    active: bool,
}

impl Default for SkipFill {
    fn default() -> SkipFill {
        SkipFill::over(SKIP_SECONDS)
    }
}

impl SkipFill {
    /// A fill for a countdown of `length` seconds.
    pub fn over(length: f64) -> SkipFill {
        SkipFill {
            length,
            base: 0.0,
            at: 0.0,
            core: 0.0,
            active: false,
        }
    }

    /// The share to draw at `now` (seconds), given the core's `reported` share and whether the film plays.
    /// `None` when no countdown is shown.
    pub fn share(&mut self, reported: Option<f64>, running: bool, now: f64) -> Option<f64> {
        let Some(c) = reported else {
            *self = SkipFill::over(self.length);
            return None;
        };
        if !self.active {
            self.active = true;
            self.base = c;
            self.at = now;
            self.core = c;
        }
        let here = self.predict(running, now);
        if (c - self.core).abs() > f64::EPSILON {
            // A report: keep the drawn value, held in a band around the core's.
            self.core = c;
            self.base = here.clamp(c - BEHIND, c + AHEAD).clamp(0.0, 1.0);
            self.at = now;
            return Some(self.base);
        }
        self.base = here;
        self.at = now;
        Some(here)
    }

    /// The share drawn at the last call, `None` while no countdown shows.
    pub fn drawn(&self) -> Option<f64> {
        self.active.then_some(self.base)
    }

    fn predict(&self, running: bool, now: f64) -> f64 {
        if !running {
            return self.base;
        }
        (self.base + ((now - self.at).max(0.0) / self.length)).min(1.0)
    }

    /// Whether the fill is still moving and needs frames.
    pub fn moving(&self, running: bool) -> bool {
        self.active && running && self.base < 1.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_runs_between_two_reports_and_never_steps_back() {
        let mut f = SkipFill::default();
        let mut last = -1.0;
        // The core reports every 0.5 s with the real share; the frames come at 60 Hz.
        let mut t: f64 = 0.0;
        while t < 6.0 {
            let reported = (t / 0.5).floor() * 0.5 / SKIP_SECONDS;
            let s = f.share(Some(reported), true, t).expect("share");
            assert!(s >= last - 1e-9, "went back at {t}: {s} < {last}");
            assert!((s - t / SKIP_SECONDS).abs() < 0.09, "off at {t}: {s}");
            // Smooth: a frame never moves more than a frame's worth of the countdown plus the pull of a report.
            assert!(
                s - last < 0.05 || last < 0.0,
                "stepped at {t}: {last} -> {s}"
            );
            last = s;
            t += 1.0 / 60.0;
        }
        assert!(last > 0.95);
    }

    #[test]
    fn a_pause_holds_the_fill_and_no_countdown_is_none() {
        let mut f = SkipFill::default();
        assert_eq!(f.share(None, true, 0.0), None);
        let a = f.share(Some(0.2), true, 0.0).expect("share");
        let b = f.share(Some(0.2), false, 3.0).expect("share");
        assert!((a - b).abs() < 1e-9, "paused fill moved: {a} -> {b}");
        assert!(!f.moving(false));
        assert!(f.moving(true));
        assert_eq!(f.share(None, true, 4.0), None);
        assert!(!f.moving(true));
    }

    #[test]
    fn a_report_far_ahead_pulls_the_fill_to_the_band() {
        let mut f = SkipFill::default();
        let _ = f.share(Some(0.0), true, 0.0);
        // A seek moved the core far ahead: the drawn share follows within the band, not by a jump of the whole gap.
        let s = f.share(Some(0.5), true, 0.016).expect("share");
        assert!((0.5 - BEHIND - 1e-9..=0.5 + AHEAD).contains(&s), "{s}");
    }

    #[test]
    fn the_card_ring_runs_over_seven_seconds() {
        let mut f = SkipFill::over(CARD_SECONDS);
        let _ = f.share(Some(0.0), true, 0.0);
        // No new report for 3.5 s: the ring has run on by half (inside the band the next report allows).
        let s = f.share(Some(0.0), true, 3.5).expect("share");
        assert!((s - 0.5).abs() < 1e-9, "{s}");
        assert_eq!(f.share(None, true, 4.0), None);
        let s = f.share(Some(0.0), true, 4.0).expect("share");
        assert!(s.abs() < 1e-9 && f.moving(true));
    }
}
