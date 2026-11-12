use std::f64::consts::PI;

/// Flight path of the profile picture when switching accounts (`AccountSwitchCurve`).
///
/// Three springs, one per axis, computed in closed form so initial velocity, landing and rest
/// are known up front. Times are seconds from the tap, sizes points or dp.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AccountSwitchCurve {
    /// Start centre x.
    pub from_x: f64,
    /// Start centre y.
    pub from_y: f64,
    /// Start size.
    pub size: f64,
    /// Target centre x.
    pub to_x: f64,
    /// Target centre y.
    pub to_y: f64,
    /// Size at the target.
    pub target: f64,
    /// When the image is at rest (within 0.3).
    pub swap: f64,
    /// When it first falls back to target height: the ring pops here.
    pub landing: f64,
}

impl AccountSwitchCurve {
    /// The image grows 6 % in place for this long before it lifts off.
    pub const GROW: f64 = 0.1;
    /// Size of the profile picture at the top right.
    pub const TARGET_SIZE: f64 = 34.0;
    /// The account switches this long before the image rests.
    pub const SWITCH_PRE_IDLE: f64 = 0.3;
    /// The account switches no earlier than this after the tap.
    pub const SWITCH_EARLIEST: f64 = 0.6;
    /// Home rows pop in staggered: seconds per row.
    pub const RAILS_SEASON: f64 = 0.08;
    /// Opacity fade of a row.
    pub const RAILS_FADE: f64 = 0.22;
    /// Rows start this far lower (pt).
    pub const RAILS_OFFSET: f64 = 14.0;
    /// Rows start at this scale.
    pub const RAILS_MASS: f64 = 0.96;
    /// How long after the swap the rows may appear.
    pub const RAILS_POST_SWAP: f64 = 0.03;

    /// Builds the curve; `target_size` is usually [`Self::TARGET_SIZE`].
    pub fn new(from: (f64, f64), size: f64, to: (f64, f64), target_size: f64) -> Self {
        let (mut idle, mut over, mut land) = (0.0_f64, -1.0_f64, -1.0_f64);
        let dt = 1.0 / 240.0;
        let mut t = Self::GROW;
        while t < 5.0 {
            let (x, y, s) = Self::at(from, size, to, target_size, t);
            if (x - to.0)
                .abs()
                .max((y - to.1).abs())
                .max((s - target_size).abs())
                > 0.3
            {
                idle = t;
            }
            if over < 0.0 && y < to.1 - 0.5 {
                over = t;
            }
            if over >= 0.0 && land < 0.0 && y >= to.1 {
                land = t;
            }
            t += dt;
        }
        let swap = idle + dt;
        let landing = if land >= 0.0 {
            land
        } else if over >= 0.0 {
            over
        } else {
            swap - 0.3
        };
        Self {
            from_x: from.0,
            from_y: from.1,
            size,
            to_x: to.0,
            to_y: to.1,
            target: target_size,
            swap,
            landing,
        }
    }

    /// When the painting ends.
    pub fn paint_end(&self) -> f64 {
        self.landing + 0.8
    }

    /// When the account switches.
    pub fn change(&self) -> f64 {
        Self::SWITCH_EARLIEST.max(self.swap - Self::SWITCH_PRE_IDLE)
    }

    /// Centre and size of the image after `t` seconds.
    pub fn status(&self, t: f64) -> (f64, f64, f64) {
        Self::at(
            (self.from_x, self.from_y),
            self.size,
            (self.to_x, self.to_y),
            self.target,
            t,
        )
    }

    fn at(from: (f64, f64), size: f64, to: (f64, f64), zs: f64, t: f64) -> (f64, f64, f64) {
        if t < Self::GROW {
            let k = (t / Self::GROW).clamp(0.0, 1.0);
            return (from.0, from.1, size * (1.0 + 0.06 * k));
        }
        let u = t - Self::GROW;
        // The push grows with the distance so the arc keeps its shape on other screens.
        let vx = -900.0 * (to.0 - from.0) / 297.0;
        let vy = 80.0 * (to.1 - from.1) / -171.0;
        (
            spring(from.0, to.0, vx, 0.8, 1.0, u),
            spring(from.1, to.1, vy, 0.9, 0.88, u),
            spring(size * 1.06, zs, 0.0, 0.8, 0.95, u),
        )
    }

    /// The ring on landing, `r` seconds after landing: (scale, opacity).
    pub fn ring(r: f64) -> (f64, f64) {
        let d = if r < 0.45 {
            (r / 0.05).min(1.0)
        } else {
            1.0 - ((r - 0.45) / 0.35).min(1.0)
        };
        (spring(0.6, 1.0, 0.0, 0.35, 0.75, r), d.max(0.0) * 0.55)
    }
}

/// A damped spring in closed form: response `r` (s), damping `z`, initial velocity `v0`.
pub fn spring(from: f64, to: f64, v0: f64, r: f64, z: f64, t: f64) -> f64 {
    if t <= 0.0 {
        return from;
    }
    let w = 2.0 * PI / r;
    let x0 = from - to;
    let x = if z < 1.0 {
        let wd = w * (1.0 - z * z).sqrt();
        (-z * w * t).exp() * (x0 * (wd * t).cos() + (v0 + z * w * x0) / wd * (wd * t).sin())
    } else {
        (x0 + (v0 + w * x0) * t) * (-w * t).exp()
    };
    to + x
}

#[cfg(test)]
mod tests {
    use super::*;

    fn curve() -> AccountSwitchCurve {
        AccountSwitchCurve::new((60.0, 420.0), 40.0, (360.0, 70.0), 34.0)
    }

    #[test]
    fn grows_in_place_first() {
        let c = curve();
        let (x, y, s) = c.status(0.0);
        assert_eq!((x, y, s), (60.0, 420.0, 40.0));
        assert!((c.status(AccountSwitchCurve::GROW).2 - 42.4).abs() < 0.01);
    }

    #[test]
    fn schedule_is_ordered() {
        let c = curve();
        assert!(c.landing > AccountSwitchCurve::GROW);
        assert!(c.change() >= AccountSwitchCurve::SWITCH_EARLIEST);
        assert!(c.paint_end() > c.landing);
    }

    #[test]
    fn ring_values() {
        assert!((AccountSwitchCurve::ring(0.0).0 - 0.6).abs() < 0.001);
        assert_eq!(AccountSwitchCurve::ring(0.0).1, 0.0);
        assert!((AccountSwitchCurve::ring(0.3).1 - 0.55).abs() < 0.001);
        assert!(AccountSwitchCurve::ring(0.8).1 < 0.001);
    }

    #[test]
    fn rests_at_target_and_lifts_off() {
        let c = AccountSwitchCurve::new((100.0, 400.0), 72.0, (397.0, 229.0), 34.0);
        let (x, y, s) = c.status(c.swap + 0.5);
        assert!((x - 397.0).abs() < 0.3 && (y - 229.0).abs() < 0.3 && (s - 34.0).abs() < 0.3);
        let early = c.status(AccountSwitchCurve::GROW + 0.03);
        assert!(early.0 > 100.0 || early.1 != 400.0);
        assert!(c.landing > AccountSwitchCurve::GROW);
        assert!(c.change() <= c.swap.max(AccountSwitchCurve::SWITCH_EARLIEST));
    }

    #[test]
    fn without_distance_it_stays() {
        let c = AccountSwitchCurve::new((10.0, 10.0), 34.0, (10.0, 10.0), 34.0);
        let (x, y, _) = c.status(c.swap + 0.1);
        assert!((x - 10.0).abs() < 0.3 && (y - 10.0).abs() < 0.3);
    }
}
