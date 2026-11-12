//! Mouse wheel and touchpad scroll as a finger: a state machine that turns wheel deltas into the touch calls of
//! `swiftly_ui::Ui`, so the scroll bodies (deceleration, rubber band, snapping) are the same as on a touch screen.
//!
//! What winit gives (0.30.13): macOS reports `PixelDelta` for a touchpad with a phase, but it folds the finger phase and
//! the OS momentum phase into one `TouchPhase` (momentum begin is `Started` again, momentum end is `Ended`). Windows
//! reports `LineDelta` and always `Moved`. X11 and Wayland report `LineDelta` or `PixelDelta` without phases. So this
//! machine ends a session by `Ended` or by silence, and swallows what looks like OS momentum (a `Started` right after an
//! `Ended`) because the scroll body glides on its own.

/// Points one wheel notch scrolls. Source: estimated (Windows scrolls 3 lines of ~19 px; Chrome uses 100 px per notch).
pub const LINE_POINTS: f32 = 48.0;
/// Time constant (ms) of the smoothing of discrete wheel notches. Source: estimated.
pub const SMOOTHING_MS: f64 = 70.0;
/// Silence (ms) after which a session without phases ends.
pub const SESSION_END_MS: f64 = 90.0;
/// A `Started` this soon (ms) after an `Ended` is taken as the OS momentum, not a new touch. Source: estimated.
pub const MOMENTUM_GAP_MS: f64 = 60.0;
/// OS momentum is swallowed until its `Ended` or this much silence (ms).
pub const MOMENTUM_SILENCE_MS: f64 = 250.0;

/// The phase of a wheel event (winit's `TouchPhase`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WheelPhase {
    /// The fingers landed.
    Started,
    /// Scrolling.
    Moved,
    /// The fingers lifted (on macOS also the end of the OS momentum).
    Ended,
    /// Cancelled.
    Cancelled,
}

/// The unit of a wheel event.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum WheelDelta {
    /// Notches of a mouse wheel.
    Lines(f32, f32),
    /// Points of a touchpad (already divided by the scale factor).
    Points(f32, f32),
}

/// A touch call for the UI.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Touch {
    /// Finger down at a point.
    Down(f32, f32),
    /// Finger moved to a point.
    Move(f32, f32),
    /// Finger up at a point.
    Up(f32, f32),
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum State {
    Idle,
    /// Collecting movement until it is more than a tap could be (a tap must never fire from the wheel).
    Pending {
        dx: f32,
        dy: f32,
        last: f64,
    },
    Active {
        x: f32,
        y: f32,
        last: f64,
    },
    /// OS momentum after the fingers lifted: swallowed.
    Momentum {
        last: f64,
    },
}

/// The wheel state machine.
#[derive(Clone, Debug)]
pub struct Wheel {
    state: State,
    cursor: (f32, f32),
    /// Smoothed notches not yet applied.
    queue: (f32, f32),
    ended_at: f64,
    last_tick: f64,
    threshold: f32,
}

impl Wheel {
    /// A machine; `threshold` is the movement (pt) after which a touch may start (the pan hysteresis).
    pub fn new(threshold: f32) -> Wheel {
        Wheel {
            state: State::Idle,
            cursor: (0.0, 0.0),
            queue: (0.0, 0.0),
            ended_at: f64::NEG_INFINITY,
            last_tick: 0.0,
            threshold,
        }
    }

    /// A session is running or notches are queued: the shell must keep drawing frames.
    pub fn is_active(&self) -> bool {
        !matches!(self.state, State::Idle) || self.queue != (0.0, 0.0)
    }

    /// The pointer moved (the finger of a session starts under it).
    pub fn set_cursor(&mut self, x: f32, y: f32) {
        self.cursor = (x, y);
    }

    /// One wheel event at `now` ms.
    pub fn event(
        &mut self,
        delta: WheelDelta,
        phase: Option<WheelPhase>,
        now: f64,
        out: &mut Vec<Touch>,
    ) {
        if let Some(WheelPhase::Cancelled | WheelPhase::Ended) = phase {
            self.end(now, phase == Some(WheelPhase::Ended), out);
            return;
        }
        if let State::Momentum { last } = self.state {
            if now - last <= MOMENTUM_SILENCE_MS {
                self.state = State::Momentum { last: now };
                return;
            }
            self.state = State::Idle;
        }
        if phase == Some(WheelPhase::Started)
            && matches!(self.state, State::Idle)
            && now - self.ended_at <= MOMENTUM_GAP_MS
        {
            self.state = State::Momentum { last: now };
            return;
        }
        match delta {
            WheelDelta::Points(dx, dy) => self.apply(dx, dy, now, out),
            WheelDelta::Lines(lx, ly) => {
                self.queue.0 += lx * LINE_POINTS;
                self.queue.1 += ly * LINE_POINTS;
                self.touch_state(now);
            }
        }
    }

    fn touch_state(&mut self, now: f64) {
        if let State::Pending { last, .. } | State::Active { last, .. } = &mut self.state {
            *last = now;
        } else {
            self.state = State::Pending {
                dx: 0.0,
                dy: 0.0,
                last: now,
            };
        }
    }

    fn apply(&mut self, dx: f32, dy: f32, now: f64, out: &mut Vec<Touch>) {
        match self.state {
            State::Idle | State::Momentum { .. } => {
                self.state = State::Pending { dx, dy, last: now };
                self.flush_pending(now, out);
            }
            State::Pending { dx: px, dy: py, .. } => {
                self.state = State::Pending {
                    dx: px + dx,
                    dy: py + dy,
                    last: now,
                };
                self.flush_pending(now, out);
            }
            State::Active { x, y, .. } => {
                let (nx, ny) = (x + dx, y + dy);
                self.state = State::Active {
                    x: nx,
                    y: ny,
                    last: now,
                };
                out.push(Touch::Move(nx, ny));
            }
        }
    }

    fn flush_pending(&mut self, now: f64, out: &mut Vec<Touch>) {
        if let State::Pending { dx, dy, .. } = self.state
            && dx.hypot(dy) > self.threshold
        {
            let (cx, cy) = self.cursor;
            out.push(Touch::Down(cx, cy));
            out.push(Touch::Move(cx + dx, cy + dy));
            self.state = State::Active {
                x: cx + dx,
                y: cy + dy,
                last: now,
            };
        }
    }

    fn end(&mut self, now: f64, finger_lift: bool, out: &mut Vec<Touch>) {
        self.flush_queue(out, now, true);
        match self.state {
            State::Active { x, y, .. } => out.push(Touch::Up(x, y)),
            State::Momentum { .. } | State::Pending { .. } | State::Idle => {}
        }
        self.queue = (0.0, 0.0);
        if matches!(self.state, State::Momentum { .. }) {
            // The end of the OS momentum.
            self.state = State::Idle;
        } else {
            self.state = State::Idle;
            if finger_lift {
                self.ended_at = now;
            }
        }
    }

    /// Applies the queued notches (smoothed, or all at once with `all`).
    fn flush_queue(&mut self, out: &mut Vec<Touch>, now: f64, all: bool) {
        let dt = (now - self.last_tick).clamp(0.0, 100.0);
        self.last_tick = now;
        let k = if all {
            1.0
        } else {
            1.0 - (-(dt / SMOOTHING_MS)).exp() as f32
        };
        let (mut mx, mut my) = (self.queue.0 * k, self.queue.1 * k);
        if self.queue.0.abs() + self.queue.1.abs() < 0.5 {
            (mx, my) = self.queue;
        }
        if mx == 0.0 && my == 0.0 {
            return;
        }
        self.queue.0 -= mx;
        self.queue.1 -= my;
        if self.queue.0.abs() < 1e-3 && self.queue.1.abs() < 1e-3 {
            self.queue = (0.0, 0.0);
        }
        self.apply(mx, my, now, out);
    }

    /// Time moves on (once per frame): applies queued notches and ends silent sessions.
    pub fn tick(&mut self, now: f64, out: &mut Vec<Touch>) {
        self.flush_queue(out, now, false);
        match self.state {
            State::Pending { last, .. } | State::Active { last, .. }
                if self.queue == (0.0, 0.0) && now - last > SESSION_END_MS =>
            {
                self.end(now, false, out);
            }
            State::Momentum { last } if now - last > MOMENTUM_SILENCE_MS => {
                self.state = State::Idle;
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(w: &mut Wheel, events: &[(f64, WheelDelta, Option<WheelPhase>)]) -> Vec<Touch> {
        let mut out = vec![];
        for &(t, d, p) in events {
            w.event(d, p, t, &mut out);
        }
        out
    }

    #[test]
    fn a_small_nudge_never_touches_the_ui() {
        let mut w = Wheel::new(10.0);
        w.set_cursor(100.0, 100.0);
        let mut out = run(
            &mut w,
            &[
                (0.0, WheelDelta::Points(0.0, 3.0), Some(WheelPhase::Started)),
                (10.0, WheelDelta::Points(0.0, 3.0), Some(WheelPhase::Moved)),
                (20.0, WheelDelta::Points(0.0, 0.0), Some(WheelPhase::Ended)),
            ],
        );
        w.tick(200.0, &mut out);
        assert!(out.is_empty(), "{out:?}: a tap would fire");
        assert!(!w.is_active());
    }

    #[test]
    fn touchpad_session_is_down_moves_up_and_the_os_momentum_is_swallowed() {
        let mut w = Wheel::new(10.0);
        w.set_cursor(100.0, 100.0);
        let out = run(
            &mut w,
            &[
                (0.0, WheelDelta::Points(0.0, 6.0), Some(WheelPhase::Started)),
                (8.0, WheelDelta::Points(0.0, 8.0), Some(WheelPhase::Moved)),
                (16.0, WheelDelta::Points(0.0, 8.0), Some(WheelPhase::Moved)),
                (24.0, WheelDelta::Points(0.0, 0.0), Some(WheelPhase::Ended)),
                // macOS momentum: Started right after Ended, then Moved, then Ended.
                (
                    30.0,
                    WheelDelta::Points(0.0, 20.0),
                    Some(WheelPhase::Started),
                ),
                (40.0, WheelDelta::Points(0.0, 15.0), Some(WheelPhase::Moved)),
                (50.0, WheelDelta::Points(0.0, 0.0), Some(WheelPhase::Ended)),
            ],
        );
        assert_eq!(out.first(), Some(&Touch::Down(100.0, 100.0)));
        assert_eq!(out.last(), Some(&Touch::Up(100.0, 122.0)));
        assert_eq!(
            out.iter().filter(|t| matches!(t, Touch::Down(..))).count(),
            1
        );
        assert!(!w.is_active());
        // A real new touch later starts a new session.
        let out = run(
            &mut w,
            &[
                (
                    500.0,
                    WheelDelta::Points(0.0, 30.0),
                    Some(WheelPhase::Started),
                ),
                (510.0, WheelDelta::Points(0.0, 0.0), Some(WheelPhase::Ended)),
            ],
        );
        assert_eq!(out.first(), Some(&Touch::Down(100.0, 100.0)));
    }

    #[test]
    fn mouse_wheel_notches_are_smoothed_and_the_session_ends_by_silence() {
        let mut w = Wheel::new(10.0);
        w.set_cursor(50.0, 60.0);
        let mut out = vec![];
        w.event(WheelDelta::Lines(0.0, -1.0), None, 0.0, &mut out);
        let mut t = 0.0;
        let mut guard = 0;
        while w.is_active() && guard < 200 {
            t += 8.0;
            w.tick(t, &mut out);
            guard += 1;
        }
        assert!(guard < 200, "session did end");
        let downs = out.iter().filter(|o| matches!(o, Touch::Down(..))).count();
        assert_eq!(downs, 1);
        let Some(Touch::Up(_, y)) = out.last().copied() else {
            panic!("ends with Up: {out:?}")
        };
        assert!(
            (y - (60.0 - LINE_POINTS)).abs() < 0.01,
            "all {LINE_POINTS} pt applied: {y}"
        );
        let moves: Vec<f32> = out
            .iter()
            .filter_map(|o| {
                if let Touch::Move(_, y) = o {
                    Some(*y)
                } else {
                    None
                }
            })
            .collect();
        assert!(moves.len() > 3, "spread over several frames: {moves:?}");
    }

    #[test]
    fn without_phases_a_precision_touchpad_session_ends_after_silence() {
        let mut w = Wheel::new(10.0);
        let mut out = vec![];
        for i in 0..10 {
            w.event(
                WheelDelta::Points(0.0, 5.0),
                Some(WheelPhase::Moved),
                f64::from(i) * 8.0,
                &mut out,
            );
        }
        assert!(matches!(out.first(), Some(Touch::Down(..))));
        w.tick(72.0 + SESSION_END_MS + 1.0, &mut out);
        assert!(matches!(out.last(), Some(Touch::Up(..))));
        assert!(!w.is_active());
    }
}
