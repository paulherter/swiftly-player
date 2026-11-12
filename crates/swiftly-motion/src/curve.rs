//! SwiftUI's timing curves as data: the cubic-bezier ease family (`easeIn`, `easeOut`, `easeInOut`, `linear`) and the
//! springs of [`crate::spring`], each with an optional start delay. A [`Curve`] answers one question exactly: how far
//! from its target is a value `t` seconds after the animation began (`displacement`), and how fast is it moving
//! (`velocity`). The `catalogue` module lists the curves the Mac app uses; the UI layer animates with nothing else.
//!
//! Interruption (one rule for the whole app): a spring that is interrupted by
//! another spring keeps position and velocity (SwiftUI documents this for `Animation.spring`); a bezier tween that is
//! interrupted restarts from the current value at rest.

use crate::spring::Spring;

/// The shape of a bezier tween: the control points are those of `UnitCurve` in SwiftUI.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ease {
    /// Constant speed.
    Linear,
    /// Slow start, fast end: (0.42, 0, 1, 1).
    In,
    /// Fast start, slow end: (0, 0, 0.58, 1).
    Out,
    /// Slow at both ends: (0.42, 0, 0.58, 1).
    InOut,
}

impl Ease {
    /// The two inner control points `(x1, y1, x2, y2)` of the curve through (0, 0) and (1, 1).
    pub fn points(self) -> (f64, f64, f64, f64) {
        match self {
            Ease::Linear => (0.0, 0.0, 1.0, 1.0),
            Ease::In => (0.42, 0.0, 1.0, 1.0),
            Ease::Out => (0.0, 0.0, 0.58, 1.0),
            Ease::InOut => (0.42, 0.0, 0.58, 1.0),
        }
    }

    /// Progress `u` in 0..1 mapped through the curve.
    pub fn at(self, u: f64) -> f64 {
        let u = u.clamp(0.0, 1.0);
        match self {
            Ease::Linear => u,
            e => {
                let (a, b, c, d) = e.points();
                bezier(a, b, c, d, u)
            }
        }
    }

    /// Slope `d value / d progress` at `u` (per unit of progress).
    pub fn slope(self, u: f64) -> f64 {
        let u = u.clamp(0.0, 1.0);
        match self {
            Ease::Linear => 1.0,
            e => {
                let (a, b, c, d) = e.points();
                bezier_slope(a, b, c, d, u)
            }
        }
    }
}

/// One coordinate of a cubic bezier from 0 through `p1` and `p2` to 1.
fn coord(t: f64, p1: f64, p2: f64) -> f64 {
    let m = 1.0 - t;
    3.0 * m * m * t * p1 + 3.0 * m * t * t * p2 + t * t * t
}

/// Derivative of [`coord`] with respect to `t`.
fn coord_slope(t: f64, p1: f64, p2: f64) -> f64 {
    let m = 1.0 - t;
    3.0 * m * m * p1 + 6.0 * m * t * (p2 - p1) + 3.0 * t * t * (1.0 - p2)
}

/// The curve parameter `t` whose x equals `u` (Newton steps, bisection as the safe fallback).
fn solve_t(x1: f64, x2: f64, u: f64) -> f64 {
    let mut t = u;
    for _ in 0..8 {
        let err = coord(t, x1, x2) - u;
        if err.abs() < 1e-12 {
            return t;
        }
        let d = coord_slope(t, x1, x2);
        if d.abs() < 1e-9 {
            break;
        }
        t -= err / d;
        if !(0.0..=1.0).contains(&t) {
            break;
        }
    }
    let (mut lo, mut hi) = (0.0, 1.0);
    for _ in 0..60 {
        let mid = 0.5 * (lo + hi);
        if coord(mid, x1, x2) < u {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    0.5 * (lo + hi)
}

/// Cubic bezier easing through `(0,0)`, `(x1,y1)`, `(x2,y2)`, `(1,1)`: the y at progress `u` on x.
pub fn bezier(x1: f64, y1: f64, x2: f64, y2: f64, u: f64) -> f64 {
    let u = u.clamp(0.0, 1.0);
    coord(solve_t(x1, x2, u), y1, y2)
}

/// `dy/dx` of [`bezier`] at progress `u`.
pub fn bezier_slope(x1: f64, y1: f64, x2: f64, y2: f64, u: f64) -> f64 {
    let t = solve_t(x1, x2, u.clamp(0.0, 1.0));
    let dx = coord_slope(t, x1, x2);
    if dx.abs() < 1e-9 {
        return 0.0;
    }
    coord_slope(t, y1, y2) / dx
}

/// What moves the value.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Kind {
    /// A bezier tween of `seconds`.
    Tween {
        /// The curve.
        ease: Ease,
        /// Duration in seconds.
        seconds: f64,
    },
    /// A spring (starts at rest or with the velocity it inherits).
    Spring(Spring),
}

/// A timing curve: [`Kind`] plus the delay before it starts (`Animation.delay`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Curve {
    /// What moves.
    pub kind: Kind,
    /// Seconds the value rests before the motion starts.
    pub delay: f64,
}

impl Curve {
    /// A tween without delay.
    pub const fn tween(ease: Ease, seconds: f64) -> Curve {
        Curve {
            kind: Kind::Tween { ease, seconds },
            delay: 0.0,
        }
    }

    /// A spring without delay.
    pub const fn spring(spring: Spring) -> Curve {
        Curve {
            kind: Kind::Spring(spring),
            delay: 0.0,
        }
    }

    /// The same curve after `seconds` of rest.
    #[must_use]
    pub const fn delayed(mut self, seconds: f64) -> Curve {
        self.delay = seconds;
        self
    }

    /// The spring, if this curve is one.
    pub fn as_spring(&self) -> Option<Spring> {
        match self.kind {
            Kind::Spring(s) => Some(s),
            Kind::Tween { .. } => None,
        }
    }

    /// Displacement from the target `t` seconds after the start, for a unit step (1 at the start, 0 at the end) from rest.
    /// For a spring this may pass through zero (overshoot) and come back.
    pub fn displacement(&self, t: f64) -> f64 {
        self.displacement_from(1.0, 0.0, t)
    }

    /// Displacement `t` seconds after the start from displacement `x0` with velocity `v0` (a tween ignores `v0`: a bezier
    /// animation always starts at rest).
    pub fn displacement_from(&self, x0: f64, v0: f64, t: f64) -> f64 {
        let t = t - self.delay;
        if t <= 0.0 {
            return x0;
        }
        match self.kind {
            Kind::Tween { ease, seconds } => {
                if seconds <= 0.0 {
                    return 0.0;
                }
                x0 * (1.0 - ease.at(t / seconds))
            }
            Kind::Spring(s) => s.value(x0, v0, t),
        }
    }

    /// Velocity of the displacement (value units per second) `t` seconds after the start from `x0`, `v0`.
    pub fn velocity_from(&self, x0: f64, v0: f64, t: f64) -> f64 {
        let t = t - self.delay;
        if t < 0.0 {
            return 0.0;
        }
        match self.kind {
            Kind::Tween { ease, seconds } => {
                if seconds <= 0.0 || t >= seconds || t == 0.0 {
                    return 0.0;
                }
                -x0 * ease.slope(t / seconds) / seconds
            }
            Kind::Spring(s) => s.velocity(x0, v0, t),
        }
    }

    /// How far a value has come from 0 to 1 after `t` seconds: `1 - displacement(t)`.
    pub fn progress(&self, t: f64) -> f64 {
        1.0 - self.displacement(t)
    }

    /// Seconds until a unit step has settled (a tween: delay plus duration; a spring: delay plus the 0.1 % settling time).
    pub fn settle_seconds(&self) -> f64 {
        self.delay
            + match self.kind {
                Kind::Tween { seconds, .. } => seconds.max(0.0),
                Kind::Spring(s) => s.settling_duration(crate::tuning::SETTLE_EPSILON),
            }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_ease_family_has_swiftuis_control_points_and_known_midpoints() {
        assert_eq!(Ease::InOut.points(), (0.42, 0.0, 0.58, 1.0));
        assert_eq!(Ease::In.points(), (0.42, 0.0, 1.0, 1.0));
        assert_eq!(Ease::Out.points(), (0.0, 0.0, 0.58, 1.0));
        for e in [Ease::In, Ease::Out, Ease::InOut, Ease::Linear] {
            assert!(e.at(0.0).abs() < 1e-12);
            assert!((e.at(1.0) - 1.0).abs() < 1e-12);
        }
        assert!((Ease::InOut.at(0.5) - 0.5).abs() < 1e-9);
    }

    /// An independent reference: the bezier as a dense table over the curve parameter, read back by interpolation on x.
    fn table_ease(e: Ease, u: f64) -> f64 {
        let (x1, y1, x2, y2) = e.points();
        let n = 200_000;
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

    #[test]
    fn the_solver_matches_a_dense_table_of_the_same_bezier() {
        for e in [Ease::In, Ease::Out, Ease::InOut] {
            for i in 0..=200 {
                let u = f64::from(i) / 200.0;
                assert!((e.at(u) - table_ease(e, u)).abs() < 1e-6, "{e:?} {u}");
            }
        }
        assert!(
            Ease::Out.at(0.5) > 0.6 && Ease::In.at(0.5) < 0.4,
            "out is ahead of linear, in is behind"
        );
    }

    #[test]
    fn the_slope_is_the_derivative_of_the_value() {
        for e in [Ease::In, Ease::Out, Ease::InOut] {
            for i in 1..100 {
                let u = f64::from(i) / 100.0;
                let h = 1e-6;
                let fd = (e.at(u + h) - e.at(u - h)) / (2.0 * h);
                assert!(
                    (fd - e.slope(u)).abs() < 1e-4 * (1.0 + fd.abs()),
                    "{e:?} {u}: {fd} vs {}",
                    e.slope(u)
                );
            }
        }
    }

    #[test]
    fn a_delayed_curve_rests_then_runs() {
        let c = Curve::tween(Ease::Out, 0.22).delayed(0.12);
        assert_eq!(c.displacement(0.1), 1.0);
        assert!(c.displacement(0.12 + 0.11) < 1.0);
        assert!(c.displacement(0.12 + 0.22).abs() < 1e-12);
        assert!((c.settle_seconds() - 0.34).abs() < 1e-12);
    }

    #[test]
    fn velocity_is_the_derivative_of_displacement() {
        let curves = [
            Curve::tween(Ease::InOut, 0.45),
            Curve::spring(Spring::from_duration_bounce(0.22, 0.15)),
            Curve::spring(Spring::from_response_damping(0.35, 0.86)).delayed(0.05),
        ];
        for c in curves {
            for i in 1..60 {
                let t = f64::from(i) * 0.01;
                let h = 1e-6;
                let fd = (c.displacement_from(1.0, 0.0, t + h)
                    - c.displacement_from(1.0, 0.0, t - h))
                    / (2.0 * h);
                let v = c.velocity_from(1.0, 0.0, t);
                if (t - c.delay).abs() > 2.0 * h {
                    assert!(
                        (fd - v).abs() < 1e-3 * (1.0 + v.abs()),
                        "{c:?} t {t}: {fd} vs {v}"
                    );
                }
            }
        }
    }
}
