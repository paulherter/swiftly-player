//! One-axis scroll physics with the feel of `UIScrollView`: 1:1 drag inside the range, rubber band beyond it, closed-form
//! deceleration (0.998 per millisecond, 0.99 for fast), a critically damped spring back from outside the bounds or from the
//! point where a glide crosses a bound, freeze-on-touch, and projected snapping for paging and poster rows.
//!
//! Units: offsets in points, times in milliseconds (`now_ms` is passed in, there is no clock), velocities in points per
//! second at the API and points per millisecond inside the deceleration math. A larger offset means later content.
//! Sources: scroll research notes; constants in [`crate::tuning`].

use crate::blend::Blend;
use crate::curve::Curve;
use crate::profile::{Glide, mac_momentum_table};
use crate::spring::Spring;
use crate::tuning;

/// The scrollable range and viewport of one axis.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScrollMetrics {
    /// Smallest offset (usually 0).
    pub min: f64,
    /// Largest offset (usually content length minus viewport length).
    pub max: f64,
    /// Viewport length along the axis: the `d` of the rubber band.
    pub viewport: f64,
}

impl ScrollMetrics {
    /// Metrics for content of `content` points in a viewport of `viewport` points, range `0 ..= content - viewport`.
    pub fn new(content: f64, viewport: f64) -> ScrollMetrics {
        let viewport = if viewport.is_finite() {
            viewport.max(1.0)
        } else {
            1.0
        };
        let content = if content.is_finite() { content } else { 0.0 };
        ScrollMetrics {
            min: 0.0,
            max: (content - viewport).max(0.0),
            viewport,
        }
    }

    /// Metrics with an explicit range.
    pub fn with_range(min: f64, max: f64, viewport: f64) -> ScrollMetrics {
        let min = if min.is_finite() { min } else { 0.0 };
        let max = if max.is_finite() { max.max(min) } else { min };
        ScrollMetrics {
            min,
            max,
            viewport: if viewport.is_finite() {
                viewport.max(1.0)
            } else {
                1.0
            },
        }
    }

    /// Whether the content is longer than the viewport. Content that fits does not scroll or bounce.
    pub fn scrollable(&self) -> bool {
        self.max > self.min
    }

    /// `x` limited to the range.
    pub fn clamp(&self, x: f64) -> f64 {
        x.clamp(self.min, self.max)
    }
}

/// What a [`ScrollBody`] is doing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrollState {
    /// At rest.
    Idle,
    /// A finger holds the content (1:1, rubber band past the ends).
    Dragging,
    /// A released fling glides with closed-form deceleration.
    Decelerating,
    /// A spring pulls the content to a bound or a snap target.
    Spring,
}

#[derive(Clone, Copy, Debug)]
struct Crossing {
    /// Milliseconds after the glide start at which the path reaches the bound.
    t_ms: f64,
    bound: f64,
    /// Velocity (pt/s) at the crossing.
    v: f64,
}

#[derive(Clone, Copy, Debug)]
enum Mode {
    Idle,
    Dragging {
        raw: f64,
    },
    Decelerating {
        x0: f64,
        v0: f64,
        t0: f64,
        rate: f64,
        stop_ms: f64,
        cross: Option<Crossing>,
    },
    /// A glide read from `ScrollBody::table` (the Mac momentum curve): displacement every 8 ms from `x0`.
    Table {
        x0: f64,
        t0: f64,
        stop_ms: f64,
        cross: Option<Crossing>,
    },
    Spring {
        target: f64,
        spring: Spring,
        x0: f64,
        v0: f64,
        t0: f64,
    },
    /// An animation by catalogued curves, run by `ScrollBody::blend` (SwiftUI's interruption rule).
    Curve,
}

/// A scrolling axis. Feed it touches (`touch_down`, `touch_move`, `touch_up*`) and ask for the offset at a time.
#[derive(Clone, Debug)]
pub struct ScrollBody {
    mode: Mode,
    pos: f64,
    samples: Vec<(f64, f64)>,
    back_spring: Spring,
    /// Range and viewport; set freely (an idle body is clamped into the range, a moving one is not re-planned).
    pub metrics: ScrollMetrics,
    /// Velocity decay factor per millisecond of a released fling: [`tuning::DECELERATION_NORMAL`] or `_FAST`.
    pub deceleration: f64,
    /// Overrides the glide of a release: [`Glide::MacTrackpad`] for the Mac momentum curve, `Exponential` for another rate;
    /// `None` uses [`deceleration`](Self::deceleration) (the touch default).
    pub glide: Option<Glide>,
    /// A release slower than this (pt/s) does not glide.
    pub min_fling: f64,
    /// A finger that rested this long (ms) before lifting releases without velocity.
    pub stale_ms: f64,
    table: Vec<f64>,
    blend: Blend,
    /// Time of the last wheel event while a precision touchpad drives the body (see [`wheel_by`](Self::wheel_by)).
    wheel_last: Option<f64>,
}

/// True for a finite-or-infinite number above zero (false for NaN).
fn positive(x: f64) -> bool {
    x > 0.0
}

/// `L = -ln(d)` for a rate `d`, guarded against degenerate rates.
fn decay_constant(rate: f64) -> f64 {
    -sane_rate(rate).ln()
}

fn sane_rate(rate: f64) -> f64 {
    if rate.is_finite() {
        rate.clamp(1e-6, 1.0 - 1e-9)
    } else {
        tuning::DECELERATION_NORMAL
    }
}

/// Apple's projection helper (WWDC18 "Designing Fluid Interfaces"): where a fling of `velocity` pt/s ends,
/// `(v / 1000) * d / (1 - d)` (a first-order approximation of the exact [`project_exact`]).
pub fn project(velocity: f64, rate: f64) -> f64 {
    let d = sane_rate(rate);
    velocity / 1000.0 * d / (1.0 - d)
}

/// The exact landing distance of a fling of `velocity` pt/s: `v0 / L` with `L = -ln(d)` (v0 in pt/ms).
pub fn project_exact(velocity: f64, rate: f64) -> f64 {
    velocity / 1000.0 / decay_constant(rate)
}

/// Distance travelled `t_ms` milliseconds into a fling of `velocity` pt/s: `v0 (1 - d^t) / L`.
pub fn glide_distance(velocity: f64, rate: f64, t_ms: f64) -> f64 {
    let d = sane_rate(rate);
    velocity / 1000.0 * (1.0 - d.powf(t_ms.max(0.0))) / decay_constant(rate)
}

/// Milliseconds until the remaining glide distance of a fling of `velocity` pt/s drops below `eps_pt` points
/// (`ln(eps L / |v0|) / ln d`); 0 if it starts below that.
pub fn glide_duration_ms(velocity: f64, rate: f64, eps_pt: f64) -> f64 {
    let d = sane_rate(rate);
    let l = decay_constant(rate);
    let v0 = velocity.abs() / 1000.0;
    if v0 <= eps_pt * l || eps_pt <= 0.0 {
        return 0.0;
    }
    (eps_pt * l / v0).ln() / d.ln()
}

/// The rubber band: how far content moves when the finger is `x` points past an edge of a viewport of `d` points,
/// `(1 - 1 / (x c / d + 1)) d` with `c = 0.55`. Never exceeds `d`.
pub fn rubber_band(x: f64, d: f64) -> f64 {
    if !positive(x) || !positive(d) {
        return 0.0;
    }
    (1.0 - 1.0 / (x * tuning::RUBBER_COEFFICIENT / d + 1.0)) * d
}

/// Inverse of [`rubber_band`]: the finger distance that shows `y` points of overscroll.
pub fn rubber_band_inverse(y: f64, d: f64) -> f64 {
    if !positive(y) || !positive(d) {
        return 0.0;
    }
    let q = (y / d).min(1.0 - 1e-12);
    d / tuning::RUBBER_COEFFICIENT * (1.0 / (1.0 - q) - 1.0)
}

/// Slope of [`rubber_band`] at `x`: how fast content moves per point of finger movement.
fn rubber_slope(x: f64, d: f64) -> f64 {
    let k = tuning::RUBBER_COEFFICIENT / d;
    let u = 1.0 + k * x.max(0.0);
    tuning::RUBBER_COEFFICIENT / (u * u)
}

/// Snap target for paging: the page index nearest to `projected`, at most [`tuning::PAGING_MAX_PAGES`] pages away from
/// the page that contains `origin` (the offset the drag started at). Returns an offset (`index * page`).
pub fn page_target(origin: f64, page: f64, projected: f64) -> f64 {
    if !positive(page) || !origin.is_finite() || !projected.is_finite() {
        return if origin.is_finite() { origin } else { 0.0 };
    }
    let start = (origin / page).round();
    let want = (projected / page).round();
    let max = tuning::PAGING_MAX_PAGES as f64;
    (start + (want - start).clamp(-max, max)) * page
}

/// Snap target for rows of items: the item start in `starts` nearest to `projected` (`projected` itself if the list is empty).
pub fn nearest_start(starts: &[f64], projected: f64) -> f64 {
    starts
        .iter()
        .copied()
        .filter(|s| s.is_finite())
        .min_by(|a, b| (a - projected).abs().total_cmp(&(b - projected).abs()))
        .unwrap_or(projected)
}

impl ScrollBody {
    /// A resting body at `offset` (clamped into the range).
    pub fn new(metrics: ScrollMetrics, offset: f64) -> ScrollBody {
        ScrollBody {
            mode: Mode::Idle,
            pos: metrics.clamp(if offset.is_finite() { offset } else { 0.0 }),
            samples: Vec::new(),
            back_spring: Spring::critical_settling_in(tuning::BACK_SETTLE_SECONDS),
            metrics,
            deceleration: tuning::DECELERATION_NORMAL,
            glide: None,
            min_fling: tuning::MIN_FLING_SPEED,
            stale_ms: tuning::VELOCITY_STALE_MS,
            table: Vec::new(),
            blend: Blend::new(0.0),
            wheel_last: None,
        }
    }

    /// A precision touchpad event: moves the content by `delta` points 1:1 (the OS already shapes the stream, including its
    /// own inertia, so there is no smoothing and no glide of ours), with the rubber band past the ends. When the stream
    /// goes quiet ([`tuning::WHEEL_IDLE_MS`]) a stretched body springs back with the last velocity; inside the range it
    /// just stops.
    pub fn wheel_by(&mut self, delta: f64, now_ms: f64) {
        self.advance(now_ms);
        self.touch_move(delta, now_ms);
        self.wheel_last = Some(now_ms);
    }

    /// Ends a wheel-driven drag once the stream is quiet: a stretch springs back, nothing else glides.
    fn wheel_release(&mut self, now_ms: f64) {
        self.wheel_last = None;
        let Some((v_disp, _)) = self.take_release(now_ms) else {
            return;
        };
        let m = self.metrics;
        if m.scrollable() && (self.pos < m.min || self.pos > m.max) {
            let bound = if self.pos < m.min { m.min } else { m.max };
            let disp = self.pos - bound;
            let v = if v_disp * disp < 0.0 { v_disp } else { 0.0 };
            self.start_spring(bound, self.back_spring, disp, v, now_ms);
        }
    }

    /// Takes the release behaviour of an OS table (glide shape, thresholds).
    pub fn apply_tuning(&mut self, t: &crate::profile::ScrollTuning) {
        self.glide = Some(t.release);
        self.min_fling = t.min_fling_speed;
        self.stale_ms = t.velocity_stale_ms;
    }

    /// Moves the content by `delta` points without a finger (a discrete wheel notch): clamped into the range, no rubber
    /// band, any glide or spring stops. Returns the offset actually moved.
    pub fn scroll_by_clamped(&mut self, delta: f64) -> f64 {
        let before = self.pos;
        self.mode = Mode::Idle;
        self.wheel_last = None;
        self.samples.clear();
        let m = self.metrics;
        self.pos = if m.scrollable() {
            m.clamp(self.pos + delta)
        } else {
            m.min
        };
        self.pos - before
    }

    /// A discrete wheel notch (or a share of its glide) on the OUTERMOST scroller of an axis: like
    /// [`scroll_by_clamped`](Self::scroll_by_clamped) inside the range, but what would pass an end gives a soft stop like the
    /// Mac: a quarter of the excess (at most [`tuning::NOTCH_BOUNCE_CAP_PT`]) is shown past the end and springs back with the
    /// back spring, no velocity. A stretch that is already shown keeps growing under further outward notches (capped) and
    /// is worked off by inward ones. Returns the points the offset changed.
    pub fn notch_by(&mut self, delta: f64, now_ms: f64) -> f64 {
        self.advance(now_ms);
        self.wheel_last = None;
        self.samples.clear();
        let m = self.metrics;
        if !m.scrollable() {
            self.mode = Mode::Idle;
            self.pos = m.min;
            return 0.0;
        }
        let from = self.pos;
        let inside = m.clamp(from);
        let stretch = from - inside;
        let cap = tuning::NOTCH_BOUNCE_CAP_PT;
        let to = if stretch == 0.0 {
            let t = from + delta;
            let c = m.clamp(t);
            c + ((t - c) * 0.25).clamp(-cap, cap)
        } else if delta * stretch > 0.0 {
            inside
                + (stretch.abs() + delta.abs() * 0.25)
                    .min(cap)
                    .copysign(stretch)
        } else {
            from + delta
        };
        let (lo, hi) = (m.min, m.max);
        if to < lo || to > hi {
            let bound = if to < lo { lo } else { hi };
            self.pos = to;
            self.start_spring(bound, self.back_spring, to - bound, 0.0, now_ms);
        } else {
            self.mode = Mode::Idle;
            self.pos = to;
        }
        (self.pos - from).abs()
    }

    /// What the body is doing.
    pub fn state(&self) -> ScrollState {
        match self.mode {
            Mode::Idle => ScrollState::Idle,
            Mode::Dragging { .. } => ScrollState::Dragging,
            Mode::Decelerating { .. } | Mode::Table { .. } => ScrollState::Decelerating,
            Mode::Spring { .. } | Mode::Curve => ScrollState::Spring,
        }
    }

    /// The offset at `now_ms` (advances the body to that time).
    pub fn offset(&mut self, now_ms: f64) -> f64 {
        self.advance(now_ms);
        self.position()
    }

    /// The offset as of the last advance, without moving time. An idle body is clamped into the range.
    pub fn position(&mut self) -> f64 {
        if matches!(self.mode, Mode::Idle) {
            self.pos = self.metrics.clamp(self.pos);
        }
        self.pos
    }

    /// Whether frames are needed (a glide or a spring runs).
    pub fn needs_frames(&self) -> bool {
        self.wheel_last.is_some()
            || matches!(
                self.mode,
                Mode::Decelerating { .. } | Mode::Table { .. } | Mode::Spring { .. } | Mode::Curve
            )
    }

    /// Sets the offset directly and stops all motion (for resets and scroll-into-view).
    pub fn jump_to(&mut self, offset: f64) {
        self.mode = Mode::Idle;
        self.samples.clear();
        self.pos = self
            .metrics
            .clamp(if offset.is_finite() { offset } else { 0.0 });
    }

    /// Animates to `offset` with `spring` from the current position (scroll-into-view, `scrollTo` in an animation).
    pub fn animate_to(&mut self, offset: f64, spring: Spring, now_ms: f64) {
        self.animate_curve(offset, Curve::spring(spring), now_ms);
    }

    /// Animates to `offset` with a catalogued curve (`withAnimation(Theme.reveal) { scrollTo }` is an easeInOut tween, `Motion.select`
    /// a spring). Interrupting an animation follows SwiftUI (`Blend`): a spring interrupted by a spring keeps position and
    /// velocity, a bezier curve keeps running and the new step is added to it.
    pub fn animate_curve(&mut self, offset: f64, curve: Curve, now_ms: f64) {
        self.advance(now_ms);
        let to = self
            .metrics
            .clamp(if offset.is_finite() { offset } else { self.pos });
        crate::catalogue::record(&curve);
        self.samples.clear();
        if !matches!(self.mode, Mode::Curve) {
            self.blend.jump(self.pos);
        }
        self.mode = Mode::Curve;
        self.blend.retarget(now_ms / 1000.0, to, curve);
        if !self.blend.is_active() {
            self.pos = to;
            self.mode = Mode::Idle;
        }
    }

    /// Current velocity in pt/s (0 at rest and while dragging; use [`touch_up`](Self::touch_up) for the finger).
    pub fn velocity(&self, now_ms: f64) -> f64 {
        match self.mode {
            Mode::Decelerating {
                v0,
                t0,
                rate,
                cross,
                ..
            } => {
                let t = (now_ms - t0).max(0.0);
                if cross.is_some_and(|c| t >= c.t_ms) {
                    0.0
                } else {
                    v0 * sane_rate(rate).powf(t) * 1000.0
                }
            }
            Mode::Table {
                t0, stop_ms, cross, ..
            } => {
                let t = (now_ms - t0).max(0.0);
                if cross.is_some_and(|c| t >= c.t_ms) || (cross.is_none() && t >= stop_ms) {
                    0.0
                } else {
                    self.table_velocity(t)
                }
            }
            Mode::Spring {
                spring, x0, v0, t0, ..
            } => spring.velocity(x0, v0, (now_ms - t0).max(0.0) / 1000.0),
            Mode::Curve => self.blend.velocity(now_ms / 1000.0),
            _ => 0.0,
        }
    }

    /// A finger touches down. A moving glide or spring freezes at its current offset with no jump.
    pub fn touch_down(&mut self, now_ms: f64) {
        if matches!(self.mode, Mode::Dragging { .. }) {
            return;
        }
        self.advance(now_ms);
        let m = self.metrics;
        let d = m.viewport;
        let raw = if !m.scrollable() {
            m.min
        } else if self.pos < m.min {
            m.min - rubber_band_inverse(m.min - self.pos, d)
        } else if self.pos > m.max {
            m.max + rubber_band_inverse(self.pos - m.max, d)
        } else {
            self.pos
        };
        self.mode = Mode::Dragging { raw };
        self.samples.clear();
        self.samples.push((now_ms, raw));
    }

    /// The finger moved by `delta` points of offset (positive = later content). Starts a drag if none is running.
    pub fn touch_move(&mut self, delta: f64, now_ms: f64) {
        if !matches!(self.mode, Mode::Dragging { .. }) {
            self.touch_down(now_ms);
        }
        if let Mode::Dragging { raw } = &mut self.mode {
            if delta.is_finite() {
                *raw += delta;
            }
            if !self.metrics.scrollable() {
                *raw = self.metrics.min;
            }
            let raw = *raw;
            self.samples.push((now_ms, raw));
            self.samples
                .retain(|s| now_ms - s.0 <= tuning::VELOCITY_WINDOW_MS * 2.0);
            self.pos = Self::display(raw, &self.metrics);
        }
    }

    /// Where the content shows the finger-driven `raw` position: 1:1 inside the range, rubber band beyond it.
    fn display(raw: f64, m: &ScrollMetrics) -> f64 {
        if !m.scrollable() {
            m.min
        } else if raw < m.min {
            m.min - rubber_band(m.min - raw, m.viewport)
        } else if raw > m.max {
            m.max + rubber_band(raw - m.max, m.viewport)
        } else {
            raw
        }
    }

    /// Finger velocity in raw (finger) space, pt/s: least-squares slope of the touch samples of the last
    /// [`tuning::VELOCITY_WINDOW_MS`]; 0 if the finger rested before lifting or there are too few samples.
    pub fn finger_velocity(&self, now_ms: f64) -> f64 {
        let Some(&(last, _)) = self.samples.last() else {
            return 0.0;
        };
        if now_ms - last > self.stale_ms {
            return 0.0;
        }
        let recent: Vec<&(f64, f64)> = self
            .samples
            .iter()
            .filter(|s| last - s.0 <= tuning::VELOCITY_WINDOW_MS)
            .collect();
        if recent.len() < 2 {
            return 0.0;
        }
        let n = recent.len() as f64;
        let tm = recent.iter().map(|s| s.0).sum::<f64>() / n;
        let xm = recent.iter().map(|s| s.1).sum::<f64>() / n;
        let den: f64 = recent.iter().map(|s| (s.0 - tm) * (s.0 - tm)).sum();
        if den < 1e-9 {
            return 0.0;
        }
        let num: f64 = recent.iter().map(|s| (s.0 - tm) * (s.1 - xm)).sum();
        num / den * 1000.0
    }

    /// The finger lifts. Outside the range the content springs back (with the finger's velocity if it moves toward the edge);
    /// inside, a fast enough release glides, and a glide whose destination lies beyond a bound ends in a spring at the bound.
    pub fn touch_up(&mut self, now_ms: f64) {
        let Some((v_disp, _)) = self.take_release(now_ms) else {
            return;
        };
        let m = self.metrics;
        if !m.scrollable() {
            self.mode = Mode::Idle;
            self.pos = m.min;
        } else if self.pos < m.min || self.pos > m.max {
            let bound = if self.pos < m.min { m.min } else { m.max };
            let disp = self.pos - bound;
            let v = if v_disp * disp < 0.0 { v_disp } else { 0.0 };
            self.start_spring(bound, self.back_spring, disp, v, now_ms);
        } else if v_disp.abs() >= self.min_fling {
            self.start_glide(self.pos, v_disp / 1000.0, now_ms);
        } else {
            self.mode = Mode::Idle;
        }
    }

    /// The finger lifts and the content snaps (paging, poster rows): the landing point is projected from the release velocity,
    /// `target` picks the snap offset for that projection (see [`page_target`], [`nearest_start`]; the result is clamped into
    /// the range), and a snap spring runs from the current offset with the release velocity.
    pub fn touch_up_snap(&mut self, now_ms: f64, target: impl Fn(f64) -> f64) {
        let Some((v_disp, _)) = self.take_release(now_ms) else {
            return;
        };
        let projected = self.pos + project(v_disp, tuning::SNAP_PROJECTION_RATE);
        let wanted = target(projected);
        let to = self
            .metrics
            .clamp(if wanted.is_finite() { wanted } else { self.pos });
        let spring = Spring::from_duration_bounce(tuning::SNAP_DURATION, tuning::SNAP_BOUNCE);
        self.start_spring(to, spring, self.pos - to, v_disp, now_ms);
    }

    /// Ends a drag and returns the release velocity in content space (pt/s) and the raw finger velocity; `None` if not dragging.
    fn take_release(&mut self, now_ms: f64) -> Option<(f64, f64)> {
        self.wheel_last = None;
        if !matches!(self.mode, Mode::Dragging { .. }) {
            return None;
        }
        let v_raw = self.finger_velocity(now_ms);
        self.samples.clear();
        let m = self.metrics;
        let v_disp = if m.scrollable() && (self.pos < m.min || self.pos > m.max) {
            let over = if self.pos < m.min {
                m.min - self.pos
            } else {
                self.pos - m.max
            };
            v_raw * rubber_slope(rubber_band_inverse(over, m.viewport), m.viewport)
        } else {
            v_raw
        };
        self.mode = Mode::Idle;
        Some((v_disp, v_raw))
    }

    fn start_spring(&mut self, target: f64, spring: Spring, x0: f64, v0: f64, now_ms: f64) {
        self.mode = Mode::Spring {
            target,
            spring,
            x0,
            v0,
            t0: now_ms,
        };
    }

    /// Starts a glide from `x0` at `v0` pt/ms. If the destination lies beyond a bound the crossing is planned.
    fn start_glide(&mut self, x0: f64, v0: f64, now_ms: f64) {
        if let Some(Glide::MacTrackpad) = self.glide {
            self.start_table_glide(x0, v0 * 1000.0, now_ms);
            return;
        }
        let rate = match self.glide {
            Some(Glide::Exponential(r)) => sane_rate(r),
            _ => sane_rate(self.deceleration),
        };
        let l = decay_constant(rate);
        let m = self.metrics;
        let dest = x0 + v0 / l;
        let bound = if v0 > 0.0 { m.max } else { m.min };
        let beyond = (v0 > 0.0 && dest > m.max) || (v0 < 0.0 && dest < m.min);
        let mut cross = None;
        if beyond {
            let frac = ((bound - x0) * l / v0).clamp(0.0, 1.0 - 1e-12);
            let t_ms = (1.0 - frac).ln() / rate.ln();
            let v = (v0 - l * (bound - x0)) * 1000.0;
            cross = Some(Crossing { t_ms, bound, v });
        }
        let stop_ms = glide_duration_ms(v0 * 1000.0, rate, tuning::STOP_REMAINING_PT);
        self.mode = Mode::Decelerating {
            x0,
            v0,
            t0: now_ms,
            rate,
            stop_ms,
            cross,
        };
    }

    /// Displacement of the table glide `t_ms` after its start (linear between the 8 ms entries).
    fn table_at(&self, t_ms: f64) -> f64 {
        let k = t_ms.max(0.0) / tuning::MAC_MOMENTUM_STEP_MS;
        let i = k.floor() as usize;
        let last = self.table.len().saturating_sub(1);
        if i >= last {
            return self.table.last().copied().unwrap_or(0.0);
        }
        let f = k - i as f64;
        self.table[i] + (self.table[i + 1] - self.table[i]) * f
    }

    /// Speed (pt/s) of the table glide `t_ms` after its start.
    fn table_velocity(&self, t_ms: f64) -> f64 {
        let i = (t_ms.max(0.0) / tuning::MAC_MOMENTUM_STEP_MS).floor() as usize;
        match (self.table.get(i), self.table.get(i + 1)) {
            (Some(a), Some(b)) => (b - a) / (tuning::MAC_MOMENTUM_STEP_MS / 1000.0),
            _ => 0.0,
        }
    }

    /// Starts the Mac momentum glide from `x0` at `v0` pt/s; a destination beyond a bound ends in a spring at the bound.
    fn start_table_glide(&mut self, x0: f64, v0: f64, now_ms: f64) {
        self.table = mac_momentum_table(v0);
        let m = self.metrics;
        let total = self.table.last().copied().unwrap_or(0.0);
        let stop_ms = (self.table.len() - 1) as f64 * tuning::MAC_MOMENTUM_STEP_MS;
        let bound = if v0 > 0.0 { m.max } else { m.min };
        let beyond = (v0 > 0.0 && x0 + total > m.max) || (v0 < 0.0 && x0 + total < m.min);
        let mut cross = None;
        if beyond
            && let Some(i) = self.table.iter().position(|d| {
                if v0 > 0.0 {
                    x0 + d >= bound
                } else {
                    x0 + d <= bound
                }
            })
        {
            let t_ms = i as f64 * tuning::MAC_MOMENTUM_STEP_MS;
            let v = self.table_velocity((t_ms - tuning::MAC_MOMENTUM_STEP_MS).max(0.0));
            cross = Some(Crossing { t_ms, bound, v });
        }
        self.mode = Mode::Table {
            x0,
            t0: now_ms,
            stop_ms,
            cross,
        };
    }

    /// Runs glide and spring up to `now_ms`.
    pub fn advance(&mut self, now_ms: f64) {
        if let Some(last) = self.wheel_last
            && now_ms - last > tuning::WHEEL_IDLE_MS
        {
            self.wheel_release(now_ms);
        }
        if let Mode::Table {
            x0,
            t0,
            stop_ms,
            cross,
        } = self.mode
        {
            let t = (now_ms - t0).max(0.0);
            if let Some(c) = cross
                && t >= c.t_ms
            {
                self.pos = c.bound;
                self.mode = Mode::Spring {
                    target: c.bound,
                    spring: self.back_spring,
                    x0: 0.0,
                    v0: c.v,
                    t0: t0 + c.t_ms,
                };
            } else if cross.is_none() && t >= stop_ms {
                self.pos = x0 + self.table_at(stop_ms);
                self.mode = Mode::Idle;
            } else {
                self.pos = x0 + self.table_at(t);
            }
        }
        if let Mode::Decelerating {
            x0,
            v0,
            t0,
            rate,
            stop_ms,
            cross,
        } = self.mode
        {
            let t = (now_ms - t0).max(0.0);
            if let Some(c) = cross
                && t >= c.t_ms
            {
                self.pos = c.bound;
                self.mode = Mode::Spring {
                    target: c.bound,
                    spring: self.back_spring,
                    x0: 0.0,
                    v0: c.v,
                    t0: t0 + c.t_ms,
                };
            } else if cross.is_none() && t >= stop_ms {
                self.pos = x0 + v0 * (1.0 - rate.powf(stop_ms)) / decay_constant(rate);
                self.mode = Mode::Idle;
            } else {
                self.pos = x0 + v0 * (1.0 - rate.powf(t)) / decay_constant(rate);
            }
        }
        if matches!(self.mode, Mode::Curve) {
            let t = now_ms / 1000.0;
            if self.blend.settle(t) {
                self.pos = self.blend.value(t);
            } else {
                self.pos = self.blend.target();
                self.mode = Mode::Idle;
            }
        }
        if let Mode::Spring {
            target,
            spring,
            x0,
            v0,
            t0,
        } = self.mode
        {
            let t = (now_ms - t0).max(0.0) / 1000.0;
            let x = spring.value(x0, v0, t);
            let v = spring.velocity(x0, v0, t);
            if t > 0.0
                && x.abs() < tuning::SPRING_SETTLE_DISTANCE
                && v.abs() < tuning::SPRING_SETTLE_SPEED
            {
                self.pos = target;
                self.mode = Mode::Idle;
            } else {
                self.pos = target + x;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::Rng;

    fn close(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() <= tol
    }

    /// Drags at a constant velocity (pt/s) for `ms` milliseconds with events every `step` ms, lifts at the last event, and
    /// returns the time of the lift.
    fn flick(b: &mut ScrollBody, t0: f64, v: f64, ms: f64, step: f64) -> f64 {
        b.touch_down(t0);
        let mut t = t0;
        while t < t0 + ms - 1e-9 {
            t += step;
            b.touch_move(v * step / 1000.0, t);
        }
        b.touch_up(t);
        t
    }

    fn run_to_idle(b: &mut ScrollBody, mut t: f64) -> f64 {
        let mut guard = 0;
        while b.state() != ScrollState::Idle && guard < 100_000 {
            t += 1000.0 / 120.0;
            b.offset(t);
            guard += 1;
        }
        t
    }

    #[test]
    fn research_flick_2000_normal_travels_999_and_stops_after_3_8_s() {
        assert!(
            close(project_exact(2000.0, 0.998), 999.0, 1.0),
            "{}",
            project_exact(2000.0, 0.998)
        );
        assert!(close(glide_distance(2000.0, 0.998, 1e9), 999.0, 1.0));
        let ms = glide_duration_ms(2000.0, 0.998, 0.5);
        assert!(close(ms / 1000.0, 3.8, 0.05), "{ms}");
        // Apple's first-order projection is the documented 499 vs 499.5 approximation.
        assert!(close(project(2000.0, 0.998), 998.0, 1e-9));
    }

    #[test]
    fn research_flick_2000_fast_travels_199_and_stops_after_0_60_s() {
        assert!(
            close(project_exact(2000.0, 0.99), 199.0, 1.0),
            "{}",
            project_exact(2000.0, 0.99)
        );
        let ms = glide_duration_ms(2000.0, 0.99, 0.5);
        assert!(close(ms / 1000.0, 0.60, 0.01), "{ms}");
    }

    #[test]
    fn research_rubber_band_852() {
        assert!(
            close(rubber_band(100.0, 852.0), 51.7, 0.2),
            "{}",
            rubber_band(100.0, 852.0)
        );
        assert!(
            close(rubber_band(200.0, 852.0), 97.4, 0.2),
            "{}",
            rubber_band(200.0, 852.0)
        );
        assert!(rubber_band(1e9, 852.0) < 852.0);
        assert_eq!(rubber_band(0.0, 852.0), 0.0);
        assert_eq!(rubber_band(-5.0, 852.0), 0.0);
    }

    #[test]
    fn rubber_band_properties() {
        let mut rng = Rng(1);
        for _ in 0..1000 {
            let d = rng.range(100.0, 2000.0);
            let x = rng.range(0.0, 20_000.0);
            let y = rubber_band(x, d);
            assert!(y >= 0.0 && y < d);
            assert!(rubber_band(x + 1.0, d) > y - 1e-12, "monotone");
            assert!(y <= x * tuning::RUBBER_COEFFICIENT + 1e-9, "resists");
            let back = rubber_band_inverse(y, d);
            assert!(
                close(back, x, 1e-6 * (1.0 + x * (1.0 + x / d))),
                "{x} {back}"
            );
            let h = 1e-4;
            let fd = (rubber_band(x + h, d) - rubber_band(x, d)) / h;
            assert!(close(fd, rubber_slope(x, d), 1e-3));
        }
    }

    #[test]
    fn simulated_flick_matches_the_closed_form() {
        let mut b = ScrollBody::new(ScrollMetrics::with_range(-1e9, 1e9, 852.0), 0.0);
        let lift = flick(&mut b, 0.0, 2000.0, 200.0, 8.0);
        assert!(close(b.finger_velocity(lift), 2000.0, 1e-6) || b.state() != ScrollState::Dragging);
        let x_lift = b.position();
        assert_eq!(b.state(), ScrollState::Decelerating);
        assert!(close(b.velocity(lift), 2000.0, 1e-6));
        let end = run_to_idle(&mut b, lift);
        let travelled = b.position() - x_lift;
        assert!(close(travelled, 999.0, 1.0), "{travelled}");
        assert!(
            close((end - lift) / 1000.0, 3.8, 0.1),
            "{}",
            (end - lift) / 1000.0
        );

        let mut f = ScrollBody::new(ScrollMetrics::with_range(-1e9, 1e9, 852.0), 0.0);
        f.deceleration = tuning::DECELERATION_FAST;
        let lift = flick(&mut f, 0.0, 2000.0, 200.0, 8.0);
        let x_lift = f.position();
        let end = run_to_idle(&mut f, lift);
        assert!(
            close(f.position() - x_lift, 199.0, 1.0),
            "{}",
            f.position() - x_lift
        );
        assert!(close((end - lift) / 1000.0, 0.60, 0.03));
    }

    #[test]
    fn glide_is_monotone_and_never_passes_its_destination() {
        let mut b = ScrollBody::new(ScrollMetrics::with_range(-1e9, 1e9, 600.0), 0.0);
        let lift = flick(&mut b, 0.0, -1500.0, 120.0, 8.0);
        let dest = b.position() + project_exact(-1500.0, 0.998);
        let mut last = b.position();
        let mut t = lift;
        while b.state() != ScrollState::Idle {
            t += 4.0;
            let p = b.offset(t);
            assert!(p <= last + 1e-9 && p >= dest - 1e-9);
            last = p;
        }
    }

    #[test]
    fn velocity_estimate_is_least_squares_over_the_last_100_ms() {
        let mut b = ScrollBody::new(ScrollMetrics::with_range(-1e9, 1e9, 600.0), 0.0);
        b.touch_down(0.0);
        // 300 ms slow (100 pt/s), then 100 ms at 1200 pt/s: only the last window counts.
        let mut t = 0.0;
        for _ in 0..30 {
            t += 10.0;
            b.touch_move(1.0, t);
        }
        for _ in 0..10 {
            t += 10.0;
            b.touch_move(12.0, t);
        }
        assert!(
            close(b.finger_velocity(t), 1200.0, 60.0),
            "{}",
            b.finger_velocity(t)
        );
        // a finger that rested before lifting does not fling
        assert_eq!(b.finger_velocity(t + 200.0), 0.0);
        b.touch_up(t + 200.0);
        assert_eq!(b.state(), ScrollState::Idle);
    }

    #[test]
    fn velocity_estimate_survives_noise() {
        let mut rng = Rng(77);
        for _ in 0..200 {
            let v = rng.range(-3000.0, 3000.0);
            let mut b = ScrollBody::new(ScrollMetrics::with_range(-1e9, 1e9, 600.0), 0.0);
            b.touch_down(0.0);
            let mut t = 0.0;
            let mut x = 0.0;
            for _ in 0..30 {
                t += 8.33;
                let nx = v * t / 1000.0 + rng.range(-0.3, 0.3);
                b.touch_move(nx - x, t);
                x = nx;
            }
            assert!(
                close(b.finger_velocity(t), v, 80.0 + 0.05 * v.abs()),
                "{v} {}",
                b.finger_velocity(t)
            );
        }
    }

    #[test]
    fn touch_down_freezes_motion_without_a_jump() {
        let mut b = ScrollBody::new(ScrollMetrics::with_range(0.0, 1e6, 852.0), 1000.0);
        let lift = flick(&mut b, 0.0, 3000.0, 150.0, 8.0);
        let mid = b.offset(lift + 700.0);
        b.touch_down(lift + 700.0);
        assert_eq!(b.state(), ScrollState::Dragging);
        assert!(close(b.position(), mid, 1e-9));
        assert!(
            close(b.offset(lift + 5000.0), mid, 1e-9),
            "no drift while held"
        );
        // a quick tap afterwards (no movement) does not fling
        b.touch_up(lift + 5000.0);
        assert_eq!(b.state(), ScrollState::Idle);
        assert!(close(b.position(), mid, 1e-9));
    }

    #[test]
    fn touch_down_freezes_a_spring_and_an_overscroll_without_a_jump() {
        let m = ScrollMetrics::with_range(0.0, 1000.0, 852.0);
        let mut b = ScrollBody::new(m, 0.0);
        b.touch_down(0.0);
        b.touch_move(-300.0, 16.0);
        let over = b.position();
        assert!(over < 0.0 && over > -300.0);
        b.touch_up(2000.0);
        assert_eq!(b.state(), ScrollState::Spring);
        let mid = b.offset(2060.0);
        assert!(mid < 0.0 && mid > over);
        b.touch_down(2060.0);
        assert!(close(b.position(), mid, 1e-9));
        // dragging on continues from where the content is, still through the band
        b.touch_move(-10.0, 2076.0);
        assert!(b.position() < mid);
    }

    #[test]
    fn dragging_inside_the_range_is_one_to_one_and_overscroll_resists() {
        let m = ScrollMetrics::with_range(0.0, 1000.0, 852.0);
        let mut b = ScrollBody::new(m, 500.0);
        b.touch_down(0.0);
        b.touch_move(100.0, 16.0);
        assert!(close(b.position(), 600.0, 1e-12));
        b.touch_move(500.0, 32.0);
        assert!(close(
            b.position(),
            1000.0 + rubber_band(100.0, 852.0),
            1e-9
        ));
        b.touch_move(-100.0, 48.0);
        assert!(close(b.position(), 1000.0, 1e-9));
    }

    #[test]
    fn release_outside_bounds_springs_back_without_overshoot_in_about_half_a_second() {
        let m = ScrollMetrics::with_range(0.0, 1000.0, 852.0);
        let mut b = ScrollBody::new(m, 0.0);
        b.touch_down(0.0);
        b.touch_move(-400.0, 16.0);
        let start = b.position();
        b.touch_up(5000.0); // rested: no velocity
        assert_eq!(b.state(), ScrollState::Spring);
        let mut t = 5000.0;
        let mut last = start;
        while b.state() != ScrollState::Idle {
            t += 1000.0 / 240.0;
            let p = b.offset(t);
            assert!(p >= last - 1e-9 && p <= 1e-9, "monotone, no overshoot");
            last = p;
        }
        assert_eq!(b.position(), 0.0);
        let settle = (t - 5000.0) / 1000.0;
        assert!(settle < 0.6 && settle > 0.3, "{settle}");
        // the tuned settle time: within 0.1 % of the travel after 0.45 s
        let mut c = ScrollBody::new(m, 0.0);
        c.touch_down(0.0);
        c.touch_move(-400.0, 16.0);
        let travel = c.position().abs();
        c.touch_up(5000.0);
        assert!(c.offset(5000.0 + 450.0).abs() <= 0.001 * travel + 1e-9);
    }

    #[test]
    fn release_outside_bounds_starts_with_the_finger_velocity_toward_the_edge() {
        let m = ScrollMetrics::with_range(0.0, 1000.0, 852.0);
        let mut b = ScrollBody::new(m, 0.0);
        b.touch_down(0.0);
        let mut t = 0.0;
        for _ in 0..10 {
            t += 8.0;
            b.touch_move(-40.0, t);
        }
        for _ in 0..20 {
            t += 8.0;
            b.touch_move(10.0, t); // finger already heading back, still outside
        }
        let p0 = b.position();
        assert!(p0 < 0.0);
        b.touch_up(t);
        assert_eq!(b.state(), ScrollState::Spring);
        let v = b.velocity(t);
        assert!(v > 0.0, "toward the edge: {v}");
        assert!(b.offset(t + 4.0) > p0);
        // moving further out: released with zero velocity
        let mut c = ScrollBody::new(m, 0.0);
        c.touch_down(0.0);
        let mut t = 0.0;
        for _ in 0..10 {
            t += 8.0;
            c.touch_move(-40.0, t);
        }
        c.touch_up(t);
        assert!(close(c.velocity(t), 0.0, 1e-9));
    }

    #[test]
    fn glide_toward_a_bound_crosses_then_springs_with_the_crossing_velocity() {
        let m = ScrollMetrics::with_range(0.0, 1000.0, 852.0);
        let mut b = ScrollBody::new(m, 700.0);
        let lift = flick(&mut b, 0.0, 2000.0, 120.0, 8.0);
        let x0 = b.position();
        let v0 = 2000.0;
        assert!(x0 + project_exact(v0, 0.998) > 1000.0);
        let l = -(0.998f64).ln();
        let v_cross = v0 - l * 1000.0 * (1000.0 - x0);
        // just before the crossing: still gliding and in range
        let t_c = (1.0 - (1000.0 - x0) * l / (v0 / 1000.0)).ln() / (0.998f64).ln();
        b.offset(lift + t_c - 1.0);
        assert_eq!(b.state(), ScrollState::Decelerating);
        assert!(b.position() < 1000.0);
        let p = b.offset(lift + t_c + 1.0);
        assert_eq!(b.state(), ScrollState::Spring);
        assert!(
            p > 1000.0 - 1.0 && p < 1000.0 + 5.0,
            "continuous across the handover: {p}"
        );
        assert!(
            close(b.velocity(lift + t_c), v_cross, 1e-6),
            "{} vs {v_cross}",
            b.velocity(lift + t_c)
        );
        // overshoots beyond the bound, then comes back to it
        let mut peak: f64 = 0.0;
        let mut t = lift + t_c;
        while b.state() != ScrollState::Idle {
            t += 4.0;
            peak = peak.max(b.offset(t));
        }
        assert!(peak > 1000.0 + 1.0);
        assert_eq!(b.position(), 1000.0);
    }

    #[test]
    fn glide_that_stays_inside_never_springs() {
        let m = ScrollMetrics::with_range(0.0, 5000.0, 852.0);
        let mut b = ScrollBody::new(m, 100.0);
        let lift = flick(&mut b, 0.0, 1000.0, 120.0, 8.0);
        let mut t = lift;
        while b.state() != ScrollState::Idle {
            assert_eq!(b.state(), ScrollState::Decelerating);
            t += 8.0;
            b.offset(t);
        }
        assert!(b.position() > 100.0 && b.position() < 5000.0);
    }

    #[test]
    fn slow_release_does_not_glide_and_content_that_fits_does_not_scroll() {
        let mut b = ScrollBody::new(ScrollMetrics::with_range(0.0, 1000.0, 852.0), 300.0);
        flick(&mut b, 0.0, 60.0, 100.0, 10.0);
        assert_eq!(b.state(), ScrollState::Idle);
        let mut f = ScrollBody::new(ScrollMetrics::new(300.0, 852.0), 0.0);
        assert!(!f.metrics.scrollable());
        f.touch_down(0.0);
        f.touch_move(80.0, 10.0);
        f.touch_move(-80.0, 20.0);
        assert_eq!(f.position(), 0.0);
        f.touch_up(30.0);
        assert_eq!(f.state(), ScrollState::Idle);
    }

    #[test]
    fn snap_projects_picks_an_item_start_and_springs_there_without_overshoot() {
        let starts: Vec<f64> = (0..20).map(|i| i as f64 * 160.0).collect();
        let m = ScrollMetrics::with_range(0.0, 3000.0, 390.0);
        // short flick: next item; long flick: further; no flick: nearest
        let go = |v: f64| {
            let mut b = ScrollBody::new(m, 0.0);
            b.touch_down(0.0);
            let mut t = 0.0;
            for _ in 0..8 {
                t += 8.0;
                b.touch_move(v * 8.0 / 1000.0, t);
            }
            let p_lift = b.position();
            b.touch_up_snap(t, |p| nearest_start(&starts, p));
            assert_eq!(b.state(), ScrollState::Spring);
            let mut prev = p_lift;
            let mut tt = t;
            while b.state() != ScrollState::Idle {
                tt += 4.0;
                let p = b.offset(tt);
                if v > 0.0 {
                    assert!(p >= prev - 1e-9, "no backwards motion");
                }
                prev = p;
            }
            b.position()
        };
        let short = go(1200.0);
        let long = go(6000.0);
        assert!(short >= 160.0 && short % 160.0 == 0.0, "{short}");
        assert!(long > short && long % 160.0 == 0.0, "{long}");
        assert_eq!(go(0.0), 0.0);
    }

    #[test]
    fn snap_target_is_always_inside_the_range() {
        let m = ScrollMetrics::with_range(0.0, 500.0, 390.0);
        let mut b = ScrollBody::new(m, 400.0);
        b.touch_down(0.0);
        for i in 1..=8 {
            b.touch_move(30.0, i as f64 * 8.0);
        }
        b.touch_up_snap(64.0, |p| p + 10_000.0);
        let mut t = 64.0;
        while b.state() != ScrollState::Idle {
            t += 8.0;
            b.offset(t);
        }
        assert_eq!(b.position(), 500.0);
        let mut c = ScrollBody::new(m, 100.0);
        c.touch_down(0.0);
        c.touch_up_snap(10.0, |_| f64::NAN);
        let mut t = 10.0;
        while c.state() != ScrollState::Idle {
            t += 8.0;
            c.offset(t);
        }
        assert!(c.position().is_finite());
    }

    #[test]
    fn paging_moves_at_most_one_page() {
        assert_eq!(page_target(390.0, 390.0, 390.0 + 1000.0), 780.0);
        assert_eq!(page_target(390.0, 390.0, -1000.0), 0.0);
        assert_eq!(page_target(390.0, 390.0, 400.0), 390.0);
        assert_eq!(page_target(0.0, 390.0, 250.0), 390.0);
        assert_eq!(page_target(5.0, 0.0, 250.0), 5.0);
        assert_eq!(nearest_start(&[], 12.0), 12.0);
        assert_eq!(nearest_start(&[0.0, 100.0, 200.0], 140.0), 100.0);
        assert_eq!(nearest_start(&[0.0, 100.0, 200.0], 151.0), 200.0);
    }

    #[test]
    fn property_random_gestures_stay_finite_and_end_inside_the_range() {
        let mut rng = Rng(0xC0FFEE);
        for _ in 0..300 {
            let content = rng.range(200.0, 20_000.0);
            let viewport = rng.range(200.0, 1000.0);
            let m = ScrollMetrics::new(content, viewport);
            let mut b = ScrollBody::new(m, rng.range(0.0, content));
            if rng.unit() < 0.3 {
                b.deceleration = tuning::DECELERATION_FAST;
            }
            let mut t = 0.0;
            for _ in 0..6 {
                // touch, move a bit, lift (maybe interrupting a glide), then let time pass
                b.touch_down(t);
                let n = (rng.range(0.0, 12.0)) as usize;
                for _ in 0..n {
                    t += rng.range(4.0, 20.0);
                    b.touch_move(rng.range(-80.0, 80.0), t);
                    assert!(b.position().is_finite());
                }
                if rng.unit() < 0.3 {
                    t += rng.range(0.0, 300.0);
                }
                if rng.unit() < 0.25 {
                    b.touch_up_snap(t, |p| (p / 100.0).round() * 100.0);
                } else {
                    b.touch_up(t);
                }
                let wait = rng.range(0.0, 1500.0);
                let end = t + wait;
                while t < end {
                    t += 1000.0 / 120.0;
                    assert!(b.offset(t).is_finite());
                }
            }
            let t = run_to_idle(&mut b, t);
            assert_eq!(b.state(), ScrollState::Idle);
            let p = b.offset(t + 100.0);
            assert!(
                p >= m.min - 1e-9 && p <= m.max + 1e-9,
                "{p} not in {}..{}",
                m.min,
                m.max
            );
        }
    }

    #[test]
    fn property_glide_destination_matches_prediction() {
        let mut rng = Rng(5150);
        for _ in 0..200 {
            let v = rng.range(300.0, 6000.0) * if rng.unit() < 0.5 { 1.0 } else { -1.0 };
            let rate = if rng.unit() < 0.5 { 0.998 } else { 0.99 };
            let mut b = ScrollBody::new(ScrollMetrics::with_range(-1e9, 1e9, 600.0), 0.0);
            b.deceleration = rate;
            let lift = flick(&mut b, 0.0, v, 120.0, 8.0);
            let x_lift = b.position();
            let vel = b.velocity(lift);
            run_to_idle(&mut b, lift);
            let predicted = project_exact(vel, rate);
            // the last <= 0.5 pt of the tail is dropped on purpose
            assert!(
                close(b.position() - x_lift, predicted, 0.55),
                "{} vs {predicted}",
                b.position() - x_lift
            );
        }
    }

    #[test]
    fn jump_to_stops_everything() {
        let mut b = ScrollBody::new(ScrollMetrics::with_range(0.0, 1000.0, 600.0), 0.0);
        flick(&mut b, 0.0, 2000.0, 100.0, 10.0);
        b.jump_to(42.0);
        assert_eq!(b.state(), ScrollState::Idle);
        assert_eq!(b.position(), 42.0);
        b.jump_to(f64::NAN);
        assert_eq!(b.position(), 0.0);
    }

    fn mac_body(content: f64, offset: f64) -> ScrollBody {
        let mut b = ScrollBody::new(ScrollMetrics::new(content, 600.0), offset);
        b.apply_tuning(&crate::profile::ScrollTuning::for_os(
            crate::profile::Os::Windows,
        ));
        b
    }

    #[test]
    fn the_mac_release_glides_the_documented_distance_and_stops() {
        let mut b = mac_body(1_000_000.0, 0.0);
        let t = flick(&mut b, 0.0, 2000.0, 100.0, 10.0);
        assert_eq!(b.state(), ScrollState::Decelerating);
        let start = b.position();
        let end_t = run_to_idle(&mut b, t);
        let travelled = b.position() - start;
        assert!(close(travelled, 576.0, 576.0 * 0.04), "{travelled}");
        assert!(close(end_t - t, 1250.0, 80.0), "{}", end_t - t);
        assert!(close(b.velocity(end_t), 0.0, 1e-9));
    }

    #[test]
    fn the_mac_glide_into_a_bound_ends_in_the_back_spring_at_the_bound() {
        let mut b = mac_body(1000.0, 380.0);
        let t = flick(&mut b, 0.0, 3000.0, 100.0, 10.0);
        let end_t = run_to_idle(&mut b, t);
        assert!(close(b.position(), 400.0, 1e-6), "{}", b.position());
        assert!(end_t > t);
    }

    #[test]
    fn a_slow_pointer_release_stays_put_and_a_wheel_notch_never_bounces() {
        let mut b = mac_body(1_000_000.0, 0.0);
        let t = flick(&mut b, 0.0, 60.0, 100.0, 10.0);
        assert_eq!(
            b.state(),
            ScrollState::Idle,
            "below the fling threshold at {t}"
        );
        let mut b = mac_body(1000.0, 390.0);
        let moved = b.scroll_by_clamped(100.0);
        assert!(close(moved, 10.0, 1e-9) && close(b.position(), 400.0, 1e-9));
        assert_eq!(b.state(), ScrollState::Idle);
        assert!(close(b.scroll_by_clamped(-1000.0), -400.0, 1e-9));
    }

    #[test]
    fn a_notch_past_an_end_shows_a_quarter_of_the_excess_capped_and_springs_back() {
        let mut b = mac_body(1000.0, 390.0);
        // 10 pt inside, 90 pt excess: 22.5 pt shown past the end.
        assert!(close(b.notch_by(100.0, 0.0), 32.5, 1e-9));
        assert!(close(b.position(), 422.5, 1e-9) && b.state() == ScrollState::Spring);
        // The same notch again only grows the stretch up to the cap.
        b.notch_by(100.0, 0.0);
        assert!(close(b.position(), 428.0, 1e-9), "{}", b.position());
        let end_t = run_to_idle(&mut b, 0.0);
        assert!(close(b.position(), 400.0, 1e-6) && end_t > 0.0);
        // Back-spring never undershoots the end.
        let mut b = mac_body(1000.0, 0.0);
        b.notch_by(-40.0, 0.0);
        assert!(close(b.position(), -10.0, 1e-9));
        for i in 1..60 {
            assert!(b.offset(f64::from(i) * 16.0) >= -10.0 - 1e-9);
        }
        run_to_idle(&mut b, 960.0);
        assert!(close(b.position(), 0.0, 1e-6));
        // Inside the range it is the plain clamped move; content that fits never gives.
        let mut b = mac_body(1000.0, 100.0);
        assert!(close(b.notch_by(100.0, 0.0), 100.0, 1e-9) && b.state() == ScrollState::Idle);
        let mut b = ScrollBody::new(ScrollMetrics::new(300.0, 600.0), 0.0);
        assert_eq!(b.notch_by(100.0, 0.0), 0.0);
        assert_eq!(b.position(), 0.0);
    }
}
