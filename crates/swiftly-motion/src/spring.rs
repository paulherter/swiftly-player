//! SwiftUI-style springs with an exact closed-form solver. A [`Spring`] is `(mass, stiffness, damping)`; its motion is
//! solved analytically for the under-, critically and over-damped case, so any `t` can be evaluated directly and stepping in
//! many small steps equals one big step. [`SpringAnim`] is the stateful animator with velocity-preserving retargeting.
//! Sources: published spring-animation research (see `tuning`).

use std::f64::consts::TAU;

use crate::tuning;

/// A damped spring `m x'' + c x' + k x = 0`, solved for the displacement `x = value - target`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Spring {
    /// Mass (SwiftUI presets use 1).
    pub mass: f64,
    /// Stiffness `k`.
    pub stiffness: f64,
    /// Damping `c`.
    pub damping: f64,
}

/// Below this `|zeta - 1|` the spring is treated as exactly critically damped.
const CRITICAL_BAND: f64 = 1e-9;
/// Above this `s*t` the over-damped basis switches to the overflow-safe exponent form.
const SAFE_SINH_ARG: f64 = 20.0;

/// `x` if it is finite and positive, else `fallback`.
fn positive_or(x: f64, fallback: f64) -> f64 {
    if x.is_finite() && x > 0.0 {
        x
    } else {
        fallback
    }
}

impl Spring {
    /// A spring from raw physical values (non-positive or non-finite values fall back to 1 so the solver stays finite;
    /// damping is clamped to be at least 0).
    pub fn new(mass: f64, stiffness: f64, damping: f64) -> Spring {
        Spring {
            mass: positive_or(mass, 1.0),
            stiffness: positive_or(stiffness, 1.0),
            damping: if damping.is_finite() {
                damping.max(0.0)
            } else {
                0.0
            },
        }
    }

    /// SwiftUI `Spring(duration:bounce:)` (mass 1): `stiffness = (2 pi / d)^2`; `damping = 4 pi (1 - bounce) / d` for
    /// `bounce >= 0`. For `bounce < 0` this uses `damping = 4 pi / (d (1 + bounce))`, see `NOTES.md` for why this differs from
    /// the form printed in the research note. `bounce` is clamped to `-0.99 ..= 1`, `duration` to at least 1 ms.
    pub fn from_duration_bounce(duration: f64, bounce: f64) -> Spring {
        let d = positive_or(duration, 0.5).max(1e-3);
        let b = if bounce.is_finite() {
            bounce.clamp(-0.99, 1.0)
        } else {
            0.0
        };
        let w = TAU / d;
        let damping = if b >= 0.0 {
            2.0 * w * (1.0 - b)
        } else {
            2.0 * w / (1.0 + b)
        };
        Spring {
            mass: 1.0,
            stiffness: w * w,
            damping,
        }
    }

    /// SwiftUI legacy `spring(response:dampingFraction:)` (mass 1): `k = (2 pi / response)^2`, `c = 4 pi zeta / response`.
    pub fn from_response_damping(response: f64, damping_fraction: f64) -> Spring {
        let r = positive_or(response, 0.5).max(1e-3);
        let z = if damping_fraction.is_finite() {
            damping_fraction.max(0.0)
        } else {
            1.0
        };
        let w = TAU / r;
        Spring {
            mass: 1.0,
            stiffness: w * w,
            damping: 2.0 * w * z,
        }
    }

    /// SwiftUI `.smooth`: duration 0.5, bounce 0 (critically damped).
    pub fn smooth() -> Spring {
        Spring::from_duration_bounce(tuning::PRESET_DURATION, tuning::SMOOTH_BOUNCE)
    }

    /// SwiftUI `.snappy`: duration 0.5, bounce 0.15.
    pub fn snappy() -> Spring {
        Spring::from_duration_bounce(tuning::PRESET_DURATION, tuning::SNAPPY_BOUNCE)
    }

    /// SwiftUI `.bouncy`: duration 0.5, bounce 0.3.
    pub fn bouncy() -> Spring {
        Spring::from_duration_bounce(tuning::PRESET_DURATION, tuning::BOUNCY_BOUNCE)
    }

    /// SwiftUI `.default` (iOS 17 / macOS 14): `spring(response: 0.55, dampingFraction: 1.0)`. The Mac uses it for bare
    /// `withAnimation {}` and `.animation(.default, ...)`.
    pub fn default_ui() -> Spring {
        Spring::from_response_damping(0.55, 1.0)
    }

    /// `.smooth(duration:)`: bounce 0, only the pace changes. Stiffness `(2 pi / d)^2`.
    pub fn smooth_d(duration: f64) -> Spring {
        Spring::from_duration_bounce(duration, tuning::SMOOTH_BOUNCE)
    }

    /// `.snappy(duration:)`: base bounce 0.15 whatever the duration.
    pub fn snappy_d(duration: f64) -> Spring {
        Spring::from_duration_bounce(duration, tuning::SNAPPY_BOUNCE)
    }

    /// `.bouncy(duration:)`: base bounce 0.3 whatever the duration.
    pub fn bouncy_d(duration: f64) -> Spring {
        Spring::from_duration_bounce(duration, tuning::BOUNCY_BOUNCE)
    }

    /// A critically damped spring of natural frequency `w` rad/s: `interpolatingSpring(mass 1, stiffness w^2, damping 2 w)`
    /// (the next-episode card uses w = 9, 10 and 12).
    pub fn critical_omega(w: f64) -> Spring {
        Spring::new(1.0, w * w, 2.0 * w)
    }

    /// Legacy `.spring()`: response 0.5, damping fraction 0.825.
    pub fn spring_default() -> Spring {
        Spring::from_response_damping(tuning::LEGACY_RESPONSE, tuning::LEGACY_DAMPING_FRACTION)
    }

    /// Legacy `.interactiveSpring()`: response 0.15, damping fraction 0.86.
    pub fn interactive() -> Spring {
        Spring::from_response_damping(
            tuning::INTERACTIVE_RESPONSE,
            tuning::INTERACTIVE_DAMPING_FRACTION,
        )
    }

    /// A critically damped spring that settles (to [`tuning::SETTLE_EPSILON`] of its travel) in `seconds`.
    pub fn critical_settling_in(seconds: f64) -> Spring {
        let reference = Spring::from_duration_bounce(1.0, 0.0);
        let s = reference.settling_duration(tuning::SETTLE_EPSILON);
        Spring::from_duration_bounce(positive_or(seconds, 0.5) / s, 0.0)
    }

    /// Natural angular frequency `sqrt(k / m)` (rad/s).
    pub fn omega(&self) -> f64 {
        (self.stiffness / self.mass).sqrt()
    }

    /// Damping ratio `c / (2 sqrt(k m))`: below 1 under-damped, 1 critical, above 1 over-damped.
    pub fn damping_ratio(&self) -> f64 {
        self.damping / (2.0 * (self.stiffness * self.mass).sqrt())
    }

    /// SwiftUI `duration`: `2 pi / sqrt(k / m)`.
    pub fn duration(&self) -> f64 {
        TAU / self.omega()
    }

    /// SwiftUI `bounce`: `1 - zeta` when under-damped or critical, `1 / zeta - 1` when over-damped (inverse of
    /// [`from_duration_bounce`](Self::from_duration_bounce) at mass 1).
    pub fn bounce(&self) -> f64 {
        let z = self.damping_ratio();
        if z <= 1.0 { 1.0 - z } else { 1.0 / z - 1.0 }
    }

    /// `e^(-zeta w t) * cos|cosh (w_d t)` and `e^(-zeta w t) * sin|sinh (w_d t) / w_d` (critical: `e^(-w t)` and `t e^(-w t)`),
    /// plus `q = w^2 (zeta^2 - 1)` (the sign picks the regime). `t >= 0`.
    fn basis(&self, t: f64) -> (f64, f64, f64) {
        let w = self.omega();
        let z = self.damping_ratio();
        let zw = z * w;
        let q = w * w * (z - 1.0) * (z + 1.0);
        if (z - 1.0).abs() < CRITICAL_BAND {
            let e = (-w * t).exp();
            (e, t * e, 0.0)
        } else if z < 1.0 {
            let wd = (-q).sqrt();
            let e = (-zw * t).exp();
            (e * (wd * t).cos(), e * (wd * t).sin() / wd, q)
        } else {
            let s = q.sqrt();
            if s * t <= SAFE_SINH_ARG {
                let e = (-zw * t).exp();
                (e * (s * t).cosh(), e * (s * t).sinh() / s, q)
            } else {
                let a = ((s - zw) * t).exp();
                let b = ((-s - zw) * t).exp();
                ((a + b) * 0.5, (a - b) / (2.0 * s), q)
            }
        }
    }

    /// Displacement from the target after `t` seconds, starting at displacement `x0` with velocity `v0` (both relative to
    /// the target). `t < 0` is treated as 0.
    pub fn value(&self, x0: f64, v0: f64, t: f64) -> f64 {
        let t = t.max(0.0);
        let (ec, es, _) = self.basis(t);
        let c = v0 + self.damping_ratio() * self.omega() * x0;
        x0 * ec + c * es
    }

    /// Velocity after `t` seconds (the analytic derivative of [`value`](Self::value)).
    pub fn velocity(&self, x0: f64, v0: f64, t: f64) -> f64 {
        let t = t.max(0.0);
        let (ec, es, q) = self.basis(t);
        let zw = self.damping_ratio() * self.omega();
        let c = v0 + zw * x0;
        let x = x0 * ec + c * es;
        x0 * q * es + c * ec - zw * x
    }

    /// Time in seconds after which the displacement stays below `eps` of the travel for a unit step from rest
    /// (Apple's `settlingDuration`, target 1). Undamped springs never settle: infinity.
    pub fn settling_duration(&self, eps: f64) -> f64 {
        let eps = positive_or(eps, tuning::SETTLE_EPSILON).min(0.5);
        let w = self.omega();
        let z = self.damping_ratio();
        if z <= 0.0 {
            return f64::INFINITY;
        }
        let slowest = if z > 1.0 {
            w * (z - (z * z - 1.0).sqrt())
        } else {
            z * w
        };
        let t_max = ((1.0 / eps).ln() + 12.0) / slowest;
        let period = if z < 1.0 {
            TAU / (w * (1.0 - z * z).sqrt())
        } else {
            TAU / w
        };
        let step = (period / 24.0).min(t_max / 400.0);
        let steps = ((t_max / step).ceil() as usize).min(400_000);
        let step = t_max / steps as f64;
        let mut last_above = 0.0;
        for i in 0..=steps {
            let t = i as f64 * step;
            if self.value(1.0, 0.0, t).abs() >= eps {
                last_above = t;
            }
        }
        // Refine the final downward crossing between the last sample above and the next one.
        let (mut lo, mut hi) = (last_above, last_above + step);
        for _ in 0..60 {
            let mid = 0.5 * (lo + hi);
            if self.value(1.0, 0.0, mid).abs() >= eps {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        hi
    }
}

/// A spring-driven value with a movable target. Position and velocity are stored absolutely, so
/// [`retarget`](Self::retarget) keeps both continuous (the SwiftUI rule for interrupted animations).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SpringAnim {
    /// The spring that moves the value.
    pub spring: Spring,
    /// Current value.
    pub value: f64,
    /// Current velocity (value units per second).
    pub velocity: f64,
    /// Where the value is heading.
    pub target: f64,
}

impl SpringAnim {
    /// A resting animator at `value`.
    pub fn new(spring: Spring, value: f64) -> SpringAnim {
        SpringAnim {
            spring,
            value,
            velocity: 0.0,
            target: value,
        }
    }

    /// Heads for `new_target` from the current value with the current velocity: no jump in position or velocity.
    pub fn retarget(&mut self, new_target: f64) {
        self.target = new_target;
    }

    /// Like [`retarget`](Self::retarget) but also swaps the spring (a different curve takes over the motion).
    pub fn retarget_with(&mut self, new_target: f64, spring: Spring) {
        self.target = new_target;
        self.spring = spring;
    }

    /// Advances by `dt` seconds (exact; any step size gives the same path). Snaps to the target once settled.
    pub fn step(&mut self, dt: f64) {
        if !dt.is_finite() || dt <= 0.0 {
            return;
        }
        let x0 = self.value - self.target;
        let v0 = self.velocity;
        let x = self.spring.value(x0, v0, dt);
        let v = self.spring.velocity(x0, v0, dt);
        if x.abs() < tuning::ANIM_SETTLE_DISTANCE && v.abs() < tuning::ANIM_SETTLE_SPEED {
            self.value = self.target;
            self.velocity = 0.0;
        } else {
            self.value = self.target + x;
            self.velocity = v;
        }
    }

    /// At the target and not moving (within the tuning thresholds).
    pub fn is_settled(&self) -> bool {
        (self.value - self.target).abs() < tuning::ANIM_SETTLE_DISTANCE
            && self.velocity.abs() < tuning::ANIM_SETTLE_SPEED
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::Rng;

    fn close(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() <= tol
    }

    /// Reference: RK4 integration of `m x'' = -k x - c x'`.
    fn rk4(s: &Spring, x0: f64, v0: f64, t: f64, dt: f64) -> (f64, f64) {
        let f = |x: f64, v: f64| (v, (-s.stiffness * x - s.damping * v) / s.mass);
        let (mut x, mut v) = (x0, v0);
        let n = (t / dt).round() as usize;
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

    #[test]
    fn apple_example_duration_bounce() {
        let s = Spring::from_duration_bounce(0.5, 0.3);
        assert_eq!(s.mass, 1.0);
        assert!(close(s.stiffness, 157.9, 0.05), "{}", s.stiffness);
        assert!(close(s.damping, 17.6, 0.05), "{}", s.damping);
    }

    #[test]
    fn apple_example_stiffness_damping() {
        let s = Spring::new(1.0, 100.0, 10.0);
        assert!(close(s.duration(), 0.63, 0.005), "{}", s.duration());
        assert!(close(s.bounce(), 0.5, 1e-9), "{}", s.bounce());
    }

    #[test]
    fn computed_preset_table() {
        let rows = [
            (Spring::smooth(), 157.9, 25.13),
            (Spring::snappy(), 157.9, 21.36),
            (Spring::bouncy(), 157.9, 17.59),
            (Spring::interactive(), 1754.6, 72.05),
            (Spring::spring_default(), 157.9, 20.7),
        ];
        for (s, k, c) in rows {
            // the research table is rounded (20.73 is printed as 20.7)
            assert!(close(s.stiffness, k, 0.06), "k {} vs {k}", s.stiffness);
            assert!(close(s.damping, c, 0.05), "c {} vs {c}", s.damping);
        }
    }

    #[test]
    fn duration_bounce_roundtrip() {
        let mut rng = Rng(7);
        for _ in 0..500 {
            let d = rng.range(0.05, 3.0);
            let b = rng.range(-0.9, 1.0);
            let s = Spring::from_duration_bounce(d, b);
            assert!(close(s.duration(), d, 1e-9));
            assert!(close(s.bounce(), b, 1e-9), "{b} vs {}", s.bounce());
        }
    }

    #[test]
    fn smooth_settles_in_about_0_735_s() {
        let t = Spring::smooth().settling_duration(0.001);
        assert!(close(t, 0.735, 0.002), "{t}");
    }

    #[test]
    fn settling_duration_is_a_true_envelope() {
        let mut rng = Rng(11);
        for _ in 0..60 {
            let s = Spring::from_duration_bounce(rng.range(0.1, 2.0), rng.range(-0.8, 0.9));
            let t = s.settling_duration(0.001);
            assert!(t.is_finite() && t > 0.0);
            assert!(s.value(1.0, 0.0, t + 1e-6).abs() < 0.001 + 1e-9);
            assert!(s.value(1.0, 0.0, t + 3.0 * s.duration()).abs() < 0.001);
            assert!(s.value(1.0, 0.0, (t - 0.02 * t).max(0.0)).abs() > 0.0005);
        }
        assert!(
            Spring::new(1.0, 100.0, 0.0)
                .settling_duration(0.001)
                .is_infinite()
        );
    }

    #[test]
    fn closed_form_matches_numeric_integration_in_all_regimes() {
        let mut rng = Rng(3);
        let regimes = [(0.5, 0.3), (0.5, 0.0), (0.5, -0.6), (0.3, 0.8), (1.0, -0.2)];
        for (d, b) in regimes {
            let s = Spring::from_duration_bounce(d, b);
            for _ in 0..20 {
                let (x0, v0, t) = (
                    rng.range(-100.0, 100.0),
                    rng.range(-2000.0, 2000.0),
                    rng.range(0.0, 2.0),
                );
                let (rx, rv) = rk4(&s, x0, v0, t, 1e-5);
                assert!(
                    close(s.value(x0, v0, t), rx, 1e-4 * (1.0 + x0.abs() + v0.abs())),
                    "x {d} {b}"
                );
                assert!(
                    close(
                        s.velocity(x0, v0, t),
                        rv,
                        1e-3 * (1.0 + x0.abs() + v0.abs())
                    ),
                    "v {d} {b}"
                );
            }
        }
        // mass other than 1
        let s = Spring::new(2.5, 300.0, 40.0);
        let (rx, rv) = rk4(&s, 10.0, -50.0, 1.3, 1e-5);
        assert!(close(s.value(10.0, -50.0, 1.3), rx, 1e-5));
        assert!(close(s.velocity(10.0, -50.0, 1.3), rv, 1e-4));
    }

    #[test]
    fn start_values_and_velocity_is_the_derivative() {
        let mut rng = Rng(5);
        for _ in 0..300 {
            let s = Spring::from_duration_bounce(rng.range(0.1, 2.0), rng.range(-0.9, 0.95));
            let (x0, v0, t) = (
                rng.range(-50.0, 50.0),
                rng.range(-500.0, 500.0),
                rng.range(0.0, 3.0),
            );
            assert!(close(s.value(x0, v0, 0.0), x0, 1e-12));
            assert!(close(s.velocity(x0, v0, 0.0), v0, 1e-9));
            let h = 1e-6;
            let fd = (s.value(x0, v0, t + h) - s.value(x0, v0, (t - h).max(0.0)))
                / (t + h - (t - h).max(0.0));
            assert!(
                close(
                    fd,
                    s.velocity(x0, v0, t),
                    1e-3 * (1.0 + v0.abs() + x0.abs())
                ),
                "{fd}"
            );
        }
    }

    #[test]
    fn regimes_are_continuous_around_critical_damping() {
        let (x0, v0, t) = (1.0, 3.0, 0.4);
        let critical = Spring::from_duration_bounce(0.5, 0.0);
        for b in [1e-7, -1e-7, 1e-5, -1e-5] {
            let s = Spring::from_duration_bounce(0.5, b);
            assert!(close(
                s.value(x0, v0, t),
                critical.value(x0, v0, t),
                1e-3 * b.abs().sqrt() + 1e-6
            ));
            assert!(close(
                s.velocity(x0, v0, t),
                critical.velocity(x0, v0, t),
                1e-2 * b.abs().sqrt() + 1e-6
            ));
        }
    }

    #[test]
    fn extreme_inputs_stay_finite() {
        let s = Spring::from_duration_bounce(0.5, -0.99);
        assert!(s.value(100.0, 5000.0, 1e6).is_finite());
        assert!(s.velocity(100.0, 5000.0, 1e6).is_finite());
        let weird = Spring::new(f64::NAN, -3.0, f64::INFINITY);
        assert!(weird.value(1.0, 1.0, 1.0).is_finite());
        assert!(Spring::smooth().value(1.0, 0.0, -5.0) == 1.0);
    }

    #[test]
    fn critical_settling_in_hits_the_requested_time() {
        let s = Spring::critical_settling_in(0.45);
        assert!(close(s.damping_ratio(), 1.0, 1e-12));
        assert!(close(s.settling_duration(0.001), 0.45, 0.002));
    }

    #[test]
    fn retarget_keeps_position_and_velocity() {
        let mut rng = Rng(21);
        for _ in 0..200 {
            let mut a = SpringAnim::new(
                Spring::from_duration_bounce(rng.range(0.1, 1.5), rng.range(-0.5, 0.6)),
                0.0,
            );
            a.retarget(rng.range(-100.0, 100.0));
            a.velocity = rng.range(-500.0, 500.0);
            for _ in 0..rng.range(1.0, 20.0) as usize {
                a.step(1.0 / 60.0);
            }
            let (v, vel) = (a.value, a.velocity);
            a.retarget(rng.range(-100.0, 100.0));
            assert!((a.value - v).abs() < 1e-9);
            assert!((a.velocity - vel).abs() < 1e-9);
            // the path stays smooth: first-order extrapolation with the carried velocity agrees
            let h = 1e-6;
            let before = a.value;
            a.step(h);
            let x = a.value - a.target;
            let accel = a.spring.stiffness * x.abs() + a.spring.damping * vel.abs();
            assert!(close(a.value - before, vel * h, h * h * accel + 1e-12));
        }
    }

    #[test]
    fn frame_rate_independence() {
        let mut rng = Rng(99);
        for _ in 0..200 {
            let spring = Spring::from_duration_bounce(rng.range(0.15, 1.5), rng.range(-0.7, 0.8));
            let (v0, to) = (rng.range(-300.0, 300.0), rng.range(-50.0, 50.0));
            let total = 0.2 + 0.2 * rng.unit();
            let make = || {
                let mut a = SpringAnim::new(spring, 0.0);
                a.retarget(to);
                a.velocity = v0;
                a
            };
            let n60 = (total * 60.0).round() / 60.0;
            let mut one = make();
            one.step(n60);
            let a60 = {
                let mut a = make();
                for _ in 0..((n60 * 60.0).round() as usize) {
                    a.step(1.0 / 60.0);
                }
                a
            };
            let a120 = {
                let mut a = make();
                for _ in 0..((n60 * 120.0).round() as usize) {
                    a.step(1.0 / 120.0);
                }
                a
            };
            assert!(
                close(a60.value, one.value, 1e-6),
                "{} {}",
                a60.value,
                one.value
            );
            assert!(close(a120.value, one.value, 1e-6));
            assert!(close(a60.velocity, one.velocity, 1e-5));
        }
    }

    #[test]
    fn anim_settles_and_snaps() {
        let mut a = SpringAnim::new(Spring::smooth(), 0.0);
        a.retarget(1.0);
        assert!(!a.is_settled());
        let mut steps = 0;
        while !a.is_settled() && steps < 1000 {
            a.step(1.0 / 120.0);
            steps += 1;
        }
        assert!(a.is_settled());
        assert_eq!(a.value, 1.0);
        assert_eq!(a.velocity, 0.0);
        assert!((steps as f64 / 120.0) < 1.2);
    }

    #[test]
    fn bouncy_overshoots_by_a_visible_amount_smooth_never() {
        let peak = |s: Spring| {
            (0..1000)
                .map(|i| 1.0 + s.value(-1.0, 0.0, i as f64 * 0.001))
                .fold(f64::MIN, f64::max)
        };
        assert!(peak(Spring::smooth()) <= 1.0 + 1e-9);
        assert!(peak(Spring::snappy()) > 1.0 + 1e-4);
        assert!(peak(Spring::bouncy()) > peak(Spring::snappy()));
    }
}
