//! Retained animated values: a catalogued curve (bezier tween or spring, `swiftly_motion::catalogue`) toward a target,
//! with a clock passed in. The value is a closed form of the time since the animation began, so any frame rate gives
//! the same path; a spring interrupted by a spring keeps position and velocity, a tween restarts from the current value.

use crate::tuning;
use swiftly_motion::catalogue::{self, Id};
pub use swiftly_motion::curve::{Curve, Ease, Kind};
use swiftly_motion::{Blend, Spring};

/// How a value moves to a new target. Every moving variant is a catalogued curve (`swiftly_motion::catalogue`); the
/// engine records any other and a test fails (`catalogue::off_catalogue`). Screens get their motions from [`crate::feel`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Motion {
    /// Jump on the next frame.
    Instant,
    /// Ease-out curve over `seconds`.
    EaseOut(f64),
    /// Linear over `seconds`.
    Linear(f64),
    /// A closed-form spring from `swiftly-motion`; keeps the velocity when it retargets.
    Spring(Spring),
    /// Ease-in over `seconds` (bezier 0.42, 0, 1, 1): a leaving fade.
    EaseIn(f64),
    /// Ease-in-out over `seconds` (bezier 0.42, 0, 0.58, 1): `reveal` 0.28, `timeArrow` 0.18, page push 0.45.
    EaseInOut(f64),
    /// A tween that starts after `delay` seconds: `timeSectionFromIn` is `easeOut(0.22)` delayed 0.12.
    Delayed {
        /// Curve of the tween.
        ease: Ease,
        /// Seconds of the tween.
        seconds: f64,
        /// Seconds waited before it starts (the value rests meanwhile).
        delay: f64,
    },
    /// `easeInOut(seconds).repeatForever(autoreverses: true)` between the value at the time of the call and the target
    /// (the placeholder pulse 0.5 to 1 over 0.9 s). Retargeting to the same target keeps it running.
    Pulse(f64),
    /// Any curve of the catalogue (a spring with a delay, for instance).
    Curve(Curve),
}

impl Motion {
    /// The motion of a catalogue entry (`Repeat::Pulse` entries give [`Motion::Pulse`]).
    pub fn of(id: Id) -> Motion {
        let e = id.entry();
        match (e.repeat, e.curve().kind) {
            (catalogue::Repeat::Pulse, Kind::Tween { seconds, .. }) => Motion::Pulse(seconds),
            _ => Motion::Curve(e.curve()),
        }
    }

    /// The curve this motion runs, `None` for [`Motion::Instant`] and the pulse.
    pub fn curve(self) -> Option<Curve> {
        Some(match self {
            Motion::Instant | Motion::Pulse(_) => return None,
            Motion::EaseOut(s) => Curve::tween(Ease::Out, s),
            Motion::Linear(s) => Curve::tween(Ease::Linear, s),
            Motion::EaseIn(s) => Curve::tween(Ease::In, s),
            Motion::EaseInOut(s) => Curve::tween(Ease::InOut, s),
            Motion::Delayed {
                ease,
                seconds,
                delay,
            } => Curve::tween(ease, seconds).delayed(delay),
            Motion::Spring(s) => Curve::spring(s),
            Motion::Curve(c) => c,
        })
    }

    /// Under Reduce Motion every moving curve becomes linear [`tuning::REDUCE_MOTION_SECONDS`].
    pub fn resolved(self, reduce: bool) -> Motion {
        match self {
            Motion::Instant => Motion::Instant,
            // A pulse is off under Reduce Motion (the Mac stops it).
            Motion::Pulse(_) if reduce => Motion::Instant,
            _ if reduce => Motion::Linear(tuning::REDUCE_MOTION_SECONDS),
            m => m,
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct PulseRun {
    a: f64,
    b: f64,
    t0: f64,
    seconds: f64,
}

/// A value that animates to a target. Times are milliseconds on the caller's clock. Interruption follows SwiftUI
/// (`swiftly_motion::Blend`): a spring interrupted by a spring merges and keeps velocity; a bezier curve keeps running and
/// the new step is added to it.
#[derive(Clone, Copy, Debug)]
pub struct Animated {
    value: f64,
    target: f64,
    velocity: f64,
    blend: Blend,
    pulse: Option<PulseRun>,
}

impl Animated {
    /// A resting value.
    pub fn new(value: f64) -> Animated {
        Animated {
            value,
            target: value,
            velocity: 0.0,
            blend: Blend::new(value),
            pulse: None,
        }
    }
    /// Current value (as of the last [`advance`](Self::advance)).
    pub fn value(&self) -> f64 {
        self.value
    }
    /// Current velocity in value units per second (as of the last [`advance`](Self::advance)).
    pub fn velocity(&self) -> f64 {
        self.velocity
    }
    /// Where it is heading.
    pub fn target(&self) -> f64 {
        self.target
    }
    /// Moving.
    pub fn is_active(&self) -> bool {
        self.blend.is_active() || self.pulse.is_some()
    }

    /// Heads for `target` with `motion`. SwiftUI's blending rule applies when it is already moving (see the type).
    pub fn set_target(&mut self, target: f64, now: f64, motion: Motion) {
        self.advance(now);
        if self.target == target && self.is_active() {
            return;
        }
        if self.target == target && self.value == target {
            return;
        }
        match motion {
            Motion::Instant => {
                self.pulse = None;
                self.blend.jump(target);
                self.set_rest(target);
            }
            Motion::Pulse(seconds) if seconds <= 0.0 => {
                self.pulse = None;
                self.blend.jump(target);
                self.set_rest(target);
            }
            Motion::Pulse(seconds) => {
                catalogue::record(&Curve::tween(Ease::InOut, seconds));
                self.pulse = Some(PulseRun {
                    a: self.value,
                    b: target,
                    t0: now,
                    seconds,
                });
                self.blend.jump(target);
                self.target = target;
            }
            m => {
                let Some(curve) = m.curve() else { return };
                if matches!(curve.kind, Kind::Tween { seconds, .. } if seconds <= 0.0) {
                    self.pulse = None;
                    self.blend.jump(target);
                    self.set_rest(target);
                    return;
                }
                catalogue::record(&curve);
                if self.pulse.take().is_some() || !self.blend.is_active() {
                    self.blend.jump(self.value);
                }
                self.blend.retarget(now / 1000.0, target, curve);
                self.target = target;
            }
        }
    }

    fn set_rest(&mut self, value: f64) {
        self.value = value;
        self.target = value;
        self.velocity = 0.0;
    }

    /// Moves time forward to `now`.
    pub fn advance(&mut self, now: f64) {
        if let Some(p) = self.pulse {
            let phase = ((now - p.t0) / 1000.0 / p.seconds).max(0.0) % 2.0;
            let tri = if phase < 1.0 { phase } else { 2.0 - phase };
            self.value = p.a + (p.b - p.a) * Ease::InOut.at(tri);
            return;
        }
        if !self.blend.is_active() {
            return;
        }
        let t = now / 1000.0;
        if self.blend.settle(t) {
            self.value = self.blend.value(t);
            self.velocity = self.blend.velocity(t);
        } else {
            self.value = self.target;
            self.velocity = 0.0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_motion::curve::bezier;

    #[test]
    fn ease_out_starts_fast_ends_at_one_and_never_goes_back() {
        let (a, b, c, d) = Ease::Out.points();
        let mut last = 0.0;
        for i in 0..=100 {
            let y = bezier(a, b, c, d, f64::from(i) / 100.0);
            assert!(y >= last - 1e-9);
            last = y;
        }
        assert!((last - 1.0).abs() < 1e-9);
        assert!(
            bezier(a, b, c, d, 0.25) > 0.3,
            "ease-out is ahead of linear early on"
        );
    }

    #[test]
    fn a_tween_reaches_its_target_after_its_duration() {
        let mut v = Animated::new(1.0);
        v.set_target(0.5, 100.0, Motion::EaseOut(0.12));
        v.advance(160.0);
        assert!(v.value() < 1.0 && v.value() > 0.5);
        v.advance(221.0);
        assert_eq!(v.value(), 0.5);
        assert!(!v.is_active());
    }

    #[test]
    fn retargeting_a_spring_keeps_position_and_velocity() {
        let mut v = Animated::new(0.0);
        v.set_target(1.0, 0.0, Motion::Spring(Spring::snappy()));
        v.advance(100.0);
        let (x, speed) = (v.value(), v.velocity());
        assert!(speed.abs() > 0.1, "the spring is moving");
        v.set_target(2.0, 100.0, Motion::Spring(Spring::snappy()));
        assert_eq!(v.value(), x, "no jump in position");
        assert_eq!(v.velocity(), speed, "no jump in velocity");
    }

    #[test]
    fn reduce_motion_turns_every_moving_curve_linear_and_keeps_instant() {
        assert_eq!(
            Motion::Spring(Spring::smooth()).resolved(true),
            Motion::Linear(tuning::REDUCE_MOTION_SECONDS)
        );
        assert_eq!(Motion::Instant.resolved(true), Motion::Instant);
        assert_eq!(Motion::EaseOut(0.3).resolved(false), Motion::EaseOut(0.3));
    }

    #[test]
    fn ease_in_out_is_symmetric_and_ease_in_starts_slow() {
        assert!((Ease::InOut.at(0.5) - 0.5).abs() < 1e-6);
        assert!((Ease::InOut.at(0.25) + Ease::InOut.at(0.75) - 1.0).abs() < 1e-6);
        assert!(Ease::In.at(0.5) < 0.35, "slow start");
        assert!(Ease::Out.at(0.5) > 0.65, "fast start");
        assert_eq!(Ease::Linear.at(0.3), 0.3);
    }

    #[test]
    fn a_delayed_tween_rests_then_runs() {
        let mut v = Animated::new(0.0);
        let m = Motion::Delayed {
            ease: Ease::Out,
            seconds: 0.22,
            delay: 0.12,
        };
        v.set_target(1.0, 0.0, m);
        v.advance(100.0);
        assert!(v.value().abs() < 1e-9, "waits 120 ms");
        assert!(v.is_active());
        v.advance(120.0 + 110.0);
        assert!(v.value() > 0.5 && v.value() < 1.0, "running: {}", v.value());
        v.advance(120.0 + 221.0);
        assert_eq!(v.value(), 1.0);
        assert!(!v.is_active());
    }

    #[test]
    fn a_pulse_goes_back_and_forth_forever_and_is_off_under_reduce_motion() {
        let mut v = Animated::new(1.0);
        v.set_target(0.5, 0.0, Motion::Pulse(0.9));
        v.advance(900.0);
        assert!((v.value() - 0.5).abs() < 1e-6, "low after one leg");
        v.advance(1800.0);
        assert!((v.value() - 1.0).abs() < 1e-6, "back up after two");
        assert!(v.is_active(), "never rests");
        v.set_target(0.5, 1800.0, Motion::Pulse(0.9));
        v.advance(2250.0);
        assert!(
            (v.value() - 0.75).abs() < 0.01,
            "retargeting the same value keeps the phase"
        );
        assert_eq!(Motion::Pulse(0.9).resolved(true), Motion::Instant);
    }

    #[test]
    fn an_interrupted_tween_keeps_running_and_the_new_step_is_added() {
        let mut v = Animated::new(0.0);
        v.set_target(1.0, 0.0, Motion::EaseInOut(0.45));
        v.advance(225.0);
        let mid = v.value();
        v.set_target(0.0, 225.0, Motion::EaseInOut(0.45));
        assert!((v.value() - mid).abs() < 1e-9, "no jump");
        v.advance(225.0 + 225.0);
        // e1 has finished (1.0), e2 is at half: 1 - 0.5
        assert!((v.value() - 0.5).abs() < 0.01, "{}", v.value());
        v.advance(225.0 + 451.0);
        assert_eq!(v.value(), 0.0);
        assert!(!v.is_active());
    }

    #[test]
    fn design_tokens_equal_the_catalogue() {
        use crate::feel;
        use swiftly_design::tokens::desktop::motion as tok;
        for (token, id) in [
            (tok::HOVER, Id::Float),
            (tok::TOGGLE, Id::Toggle),
            (tok::LEAP, Id::Leap),
            (tok::CHANGE, Id::Change),
            (tok::SELECT, Id::Select),
            (tok::SHEET, Id::Sheet),
            (tok::LAND, Id::Land),
            (tok::PAGE, Id::Page),
        ] {
            let c = feel::from_curve(token).curve().expect("a moving curve");
            assert_eq!(catalogue::find(&c), Some(id), "{id:?}");
        }
        assert_eq!(feel::hover().curve(), Some(Id::Float.curve()));
        assert_eq!(
            feel::reveal().curve(),
            Some(Curve::tween(Ease::InOut, 0.28))
        );
        assert_eq!(
            feel::pages_push().curve(),
            Some(Curve::tween(Ease::InOut, 0.45))
        );
        // The stiffness of `.snappy(duration: 0.22)` is (2 pi / 0.22)^2 = 815.7 (D section 2.2).
        let s = feel::leap()
            .curve()
            .and_then(|c| c.as_spring())
            .expect("spring");
        assert!((s.stiffness - 815.7).abs() < 0.5, "{}", s.stiffness);
        assert_eq!(feel::pulse(), Motion::Pulse(0.9));
    }
}
