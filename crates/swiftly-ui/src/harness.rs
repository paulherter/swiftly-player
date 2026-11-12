//! Headless test harness: feed synthetic touch traces (down / move / up with timestamps) to a [`Ui`], step the frame
//! loop at a fixed rate, and look at scroll offsets, press states and draw lists.

use crate::ui::{Ui, UiEvent};
use swiftly_render::{Color, DrawList, RgbaImage};

/// One synthetic touch sample.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Touch {
    /// Finger down.
    Down,
    /// Finger moved.
    Move,
    /// Finger up.
    Up,
}

/// A timestamped touch.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Sample {
    /// Time in ms.
    pub t: f64,
    /// Kind.
    pub kind: Touch,
    /// X in points.
    pub x: f32,
    /// Y in points.
    pub y: f32,
}

/// A touch trace builder.
#[derive(Clone, Debug, Default)]
pub struct Trace {
    /// The samples in time order.
    pub samples: Vec<Sample>,
}

impl Trace {
    /// An empty trace.
    pub fn new() -> Trace {
        Trace::default()
    }
    /// Finger down.
    #[must_use]
    pub fn down(mut self, t: f64, x: f32, y: f32) -> Trace {
        self.samples.push(Sample {
            t,
            kind: Touch::Down,
            x,
            y,
        });
        self
    }
    /// Finger moved.
    #[must_use]
    pub fn move_to(mut self, t: f64, x: f32, y: f32) -> Trace {
        self.samples.push(Sample {
            t,
            kind: Touch::Move,
            x,
            y,
        });
        self
    }
    /// Finger up.
    #[must_use]
    pub fn up(mut self, t: f64, x: f32, y: f32) -> Trace {
        self.samples.push(Sample {
            t,
            kind: Touch::Up,
            x,
            y,
        });
        self
    }
    /// A straight drag from `from` to `to` sampled every `step_ms` between `t0` and `t0 + duration` (down and moves,
    /// no up), as a touch screen reports it.
    #[must_use]
    pub fn drag(
        mut self,
        t0: f64,
        duration: f64,
        step_ms: f64,
        from: (f32, f32),
        to: (f32, f32),
    ) -> Trace {
        let n = (duration / step_ms).round().max(1.0) as usize;
        for i in 0..=n {
            let k = i as f32 / n as f32;
            let (x, y) = (from.0 + (to.0 - from.0) * k, from.1 + (to.1 - from.1) * k);
            let t = t0 + duration * f64::from(k);
            self = if i == 0 {
                self.down(t, x, y)
            } else {
                self.move_to(t, x, y)
            };
        }
        self
    }
}

/// A [`Ui`] with a clock, a frame rate and an event log.
pub struct Harness<P> {
    /// The UI under test.
    pub ui: Ui<P>,
    /// Current time in ms.
    pub now: f64,
    /// Frame interval in ms (120 Hz by default).
    pub frame_ms: f64,
    /// Every event reported so far.
    pub events: Vec<UiEvent>,
}

impl<P: PartialEq + Clone> Harness<P> {
    /// Wraps a UI; time starts at 0.
    pub fn new(ui: Ui<P>) -> Harness<P> {
        Harness {
            ui,
            now: 0.0,
            frame_ms: 1000.0 / 120.0,
            events: vec![],
        }
    }

    fn collect(&mut self) {
        let e = self.ui.take_events();
        self.events.extend(e);
    }

    /// Runs frames until `t` (inclusive of a final frame at `t`).
    pub fn advance_to(&mut self, t: f64) {
        while self.now + self.frame_ms < t {
            self.now += self.frame_ms;
            let _ = self.ui.frame(self.now);
            self.collect();
        }
        self.now = t.max(self.now);
        let _ = self.ui.frame(self.now);
        self.collect();
    }

    /// Plays a trace: frames run between the samples, each sample is delivered at its timestamp.
    pub fn play(&mut self, trace: &Trace) {
        for s in &trace.samples {
            self.advance_to(s.t);
            match s.kind {
                Touch::Down => self.ui.touch_down(s.x, s.y, s.t),
                Touch::Move => self.ui.touch_move(s.x, s.y, s.t),
                Touch::Up => self.ui.touch_up(s.x, s.y, s.t),
            }
            self.collect();
        }
    }

    /// The draw list of a frame at `t`.
    pub fn frame_at(&mut self, t: f64) -> DrawList {
        self.advance_to(t);
        let list = self.ui.frame(self.now);
        self.collect();
        list
    }

    /// Renders a frame at `t` with the software renderer.
    pub fn render_at(&mut self, t: f64, clear: Color) -> RgbaImage {
        let list = self.frame_at(t);
        self.ui.render(&list, clear)
    }
}
