//! How SwiftUI mixes an animation that is interrupted by a new one, as a value you can ask at any time.
//!
//! Apple documents it in `CustomAnimation.shouldMerge(previous:value:time:context:)` and WWDC23 "Explore SwiftUI
//! animation" (10156): animations work on the *difference* between values (1 to 1.5 animates 0.5). When a new animation
//! starts on a value that is already animating, the new instance asks `shouldMerge`:
//!
//! * `true` (springs): the new animation takes over the previous one's state and elapsed time, the previous is removed.
//!   Position and velocity stay continuous.
//! * `false` (the default, so every bezier curve: `easeIn`, `easeOut`, `easeInOut`, `linear`): "both animations run together
//!   and the system combines their results"; the vectors are added. The old animation keeps running its course toward
//!   the old target while the new one animates the step from the old target to the new one.
//!
//! So with model targets `M0` (start), `M1`, `M2` ... and one [`Curve`] per step, the shown value is
//! `M_n + sum_i x_i(t - t_i)` where `x_i` is the displacement of step `i` (starting at `M_{i-1} - M_i`, ending at 0). A change
//! of target never jumps the shown value. A step that is merged (spring after spring) replaces all layers by one layer
//! that starts at the shown value with the shown velocity.
//!
//! One thing Apple does not document: whether a spring merges with a *bezier* previous animation. This model adds it
//! (does not merge): `SpringAnimation.shouldMerge` is only known to merge springs into springs.

use crate::curve::{Curve, Kind};
use crate::tuning;

/// Most layers kept (so the type stays `Copy`); the oldest is dropped beyond this (it is almost always finished by then).
const MAX_LAYERS: usize = 3;

#[derive(Clone, Copy, Debug)]
struct Layer {
    curve: Curve,
    /// Displacement at the start (relative to the model value then in force) and velocity at the start.
    x0: f64,
    v0: f64,
    /// Start time in seconds.
    t0: f64,
}

impl Layer {
    const EMPTY: Layer = Layer {
        curve: Curve::tween(crate::curve::Ease::Linear, 0.0),
        x0: 0.0,
        v0: 0.0,
        t0: 0.0,
    };

    fn displacement(&self, now: f64) -> f64 {
        self.curve
            .displacement_from(self.x0, self.v0, (now - self.t0).max(0.0))
    }

    fn velocity(&self, now: f64) -> f64 {
        self.curve
            .velocity_from(self.x0, self.v0, (now - self.t0).max(0.0))
    }

    fn finished(&self, now: f64) -> bool {
        let t = (now - self.t0).max(0.0);
        match self.curve.kind {
            Kind::Tween { seconds, .. } => t + 1e-9 >= self.curve.delay + seconds,
            Kind::Spring(_) => {
                t > self.curve.delay
                    && self.displacement(now).abs() < tuning::ANIM_SETTLE_DISTANCE
                    && self.velocity(now).abs() < tuning::ANIM_SETTLE_SPEED
            }
        }
    }

    fn is_spring(&self) -> bool {
        self.curve.as_spring().is_some()
    }
}

/// A value that follows a model target through SwiftUI-style animations. Times are seconds on the caller's clock.
#[derive(Clone, Copy, Debug)]
pub struct Blend {
    target: f64,
    layers: [Layer; MAX_LAYERS],
    len: usize,
}

impl Blend {
    /// A value at rest.
    pub fn new(value: f64) -> Blend {
        Blend {
            target: value,
            layers: [Layer::EMPTY; MAX_LAYERS],
            len: 0,
        }
    }

    fn active(&self) -> &[Layer] {
        &self.layers[..self.len]
    }

    fn push(&mut self, now: f64, mut layer: Layer) {
        if self.len == MAX_LAYERS {
            // Dropping the oldest layer must not move the shown value: its displacement moves to the newest layer.
            layer.x0 += self.layers[0].displacement(now);
            self.layers.copy_within(1.., 0);
            self.len -= 1;
        }
        self.layers[self.len] = layer;
        self.len += 1;
    }

    /// The model value the animations are heading for.
    pub fn target(&self) -> f64 {
        self.target
    }

    /// Whether any layer is still running.
    pub fn is_active(&self) -> bool {
        self.len > 0
    }

    /// The shown value at `now`.
    pub fn value(&self, now: f64) -> f64 {
        self.target
            + self
                .active()
                .iter()
                .map(|l| l.displacement(now))
                .sum::<f64>()
    }

    /// The shown velocity at `now` (value units per second).
    pub fn velocity(&self, now: f64) -> f64 {
        self.active().iter().map(|l| l.velocity(now)).sum()
    }

    /// Drops the layers that have finished (the value is then exactly the target when none is left). Returns whether
    /// something still runs.
    pub fn settle(&mut self, now: f64) -> bool {
        let mut kept = 0;
        for i in 0..self.len {
            if !self.layers[i].finished(now) {
                self.layers[kept] = self.layers[i];
                kept += 1;
            }
        }
        self.len = kept;
        self.is_active()
    }

    /// Sets a new model target and animates the step with `curve`. Same target while running: nothing changes.
    pub fn retarget(&mut self, now: f64, target: f64, curve: Curve) {
        self.settle(now);
        if target == self.target {
            return;
        }
        if matches!(curve.kind, Kind::Tween { seconds, .. } if seconds <= 0.0) {
            self.target = target;
            self.len = 0;
            return;
        }
        let merge = curve.as_spring().is_some()
            && self.len > 0
            && self.active().iter().all(Layer::is_spring);
        if merge {
            let (value, velocity) = (self.value(now), self.velocity(now));
            self.len = 0;
            self.target = target;
            self.push(
                now,
                Layer {
                    curve,
                    x0: value - target,
                    v0: velocity,
                    t0: now,
                },
            );
            return;
        }
        let step = self.target - target;
        self.target = target;
        self.push(
            now,
            Layer {
                curve,
                x0: step,
                v0: 0.0,
                t0: now,
            },
        );
    }

    /// Jumps to `value` with nothing running.
    pub fn jump(&mut self, value: f64) {
        self.target = value;
        self.len = 0;
    }

    /// Starts a new animation from the shown value with an explicit initial velocity (a released scroll or drag handing
    /// over to a spring), replacing everything that ran.
    pub fn start_from(&mut self, now: f64, value: f64, velocity: f64, target: f64, curve: Curve) {
        self.len = 0;
        self.target = target;
        if value != target || velocity != 0.0 {
            self.push(
                now,
                Layer {
                    curve,
                    x0: value - target,
                    v0: velocity,
                    t0: now,
                },
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::curve::Ease;
    use crate::spring::Spring;

    fn reveal() -> Curve {
        Curve::tween(Ease::InOut, 0.28)
    }

    #[test]
    fn a_single_tween_is_the_plain_curve() {
        let mut b = Blend::new(10.0);
        b.retarget(1.0, 30.0, reveal());
        for i in 0..=40 {
            let t = f64::from(i) * 0.01;
            let want = 10.0 + 20.0 * Ease::InOut.at(t / 0.28);
            assert!((b.value(1.0 + t) - want).abs() < 1e-9);
        }
        assert!(!b.settle(2.0));
        assert_eq!(b.value(2.0), 30.0);
    }

    #[test]
    fn an_interrupted_tween_adds_the_two_steps_like_swiftui() {
        // Hover in (0 to 1), interrupted at 60 ms by hover out (1 to 0): both curves keep running and their vectors add.
        let hover = Curve::tween(Ease::Out, 0.12);
        let mut b = Blend::new(0.0);
        b.retarget(0.0, 1.0, hover);
        let at_cut = b.value(0.06);
        b.retarget(0.06, 0.0, hover);
        assert!((b.value(0.06) - at_cut).abs() < 1e-12, "no jump");
        for i in 0..=30 {
            let t = f64::from(i) * 0.01;
            // independent: model 0 now; step 1 contributes -(1 - e1), step 2 contributes +(1 - e2)
            let e1 = Ease::Out.at((0.06 + t) / 0.12);
            let e2 = Ease::Out.at(t / 0.12);
            let want = -(1.0 - e1) + (1.0 - e2);
            assert!(
                (b.value(0.06 + t) - want).abs() < 1e-9,
                "t {t}: {} vs {want}",
                b.value(0.06 + t)
            );
        }
        // Both have run out after the second curve.
        assert!(!b.settle(0.06 + 0.12));
        assert_eq!(b.value(0.2), 0.0);
    }

    #[test]
    fn the_shown_value_never_jumps_when_the_target_changes() {
        let mut b = Blend::new(0.0);
        let mut now = 0.0;
        let curves = [
            reveal(),
            Curve::tween(Ease::In, 0.12),
            Curve::spring(Spring::snappy_d(0.22)),
            Curve::tween(Ease::InOut, 0.45),
        ];
        for (i, to) in [100.0, -40.0, 70.0, 5.0, 90.0, 0.0].into_iter().enumerate() {
            let before = b.value(now);
            b.retarget(now, to, curves[i % 4]);
            // a finished spring layer is dropped when it is within the settle distance of its target
            assert!((b.value(now) - before).abs() < 2e-3, "step {i}");
            now += 0.05;
        }
    }

    #[test]
    fn a_spring_interrupted_by_a_spring_merges_and_keeps_velocity() {
        let s = Curve::spring(Spring::snappy_d(0.22));
        let mut b = Blend::new(0.0);
        b.retarget(0.0, 100.0, s);
        let (x, v) = (b.value(0.07), b.velocity(0.07));
        b.retarget(0.07, -50.0, s);
        assert!((b.value(0.07) - x).abs() < 1e-9);
        assert!((b.velocity(0.07) - v).abs() < 1e-6);
        assert_eq!(b.len, 1, "merged into one layer");
        // Same spring twice is the same as one continuous spring toward the second target.
        let mut c = Blend::new(0.0);
        c.start_from(0.07, x, v, -50.0, s);
        for i in 0..40 {
            let t = 0.07 + f64::from(i) * 0.01;
            assert!((b.value(t) - c.value(t)).abs() < 1e-9);
        }
    }

    #[test]
    fn a_spring_over_a_tween_does_not_merge_it_adds() {
        let mut b = Blend::new(0.0);
        b.retarget(0.0, 100.0, reveal());
        b.retarget(0.1, 0.0, Curve::spring(Spring::snappy_d(0.22)));
        assert_eq!(b.len, 2);
    }

    #[test]
    fn zero_length_tweens_and_same_targets_are_instant_or_ignored() {
        let mut b = Blend::new(0.0);
        b.retarget(0.0, 5.0, Curve::tween(Ease::Linear, 0.0));
        assert_eq!((b.value(0.0), b.is_active()), (5.0, false));
        b.retarget(0.0, 5.0, reveal());
        assert!(!b.is_active());
    }

    #[test]
    fn many_interruptions_stay_bounded_and_finite() {
        let mut b = Blend::new(0.0);
        let mut now = 0.0;
        for i in 0..200 {
            b.retarget(
                now,
                if i % 2 == 0 { 1.0 } else { 0.0 },
                Curve::tween(Ease::InOut, 0.45),
            );
            now += 0.01;
            assert!(b.len <= MAX_LAYERS);
            assert!(b.value(now).is_finite());
        }
        assert!(!b.settle(now + 2.0));
        assert!((b.value(now + 2.0) - b.target()).abs() < 1e-12);
    }
}
