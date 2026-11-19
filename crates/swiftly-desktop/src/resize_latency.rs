//! How long a window resize takes to show: from the `Resized` event (the compositor's configure) to the frame that is
//! presented at the new size, plus a synthetic drag for measuring it without a pointer.
//!
//! `SWIFTLY_DESKTOP_TRACE=1` prints the latency of every resize and a summary line when a drag ends. A drag that
//! the app makes itself, for the nested compositor of the live checks: `SWIFTLY_RESIZE_BENCH=steps:dw:dh:interval_ms`
//! (for example `80:12:6:16`: 80 steps of 12 x 6 px every 16 ms, from three seconds after the start).

use std::time::Duration;

/// `SWIFTLY_RESIZE_INLINE=1`: draw inside the `Resized` event (the old behaviour, a frame per step) to measure it against
/// the one frame per redraw.
pub fn inline_resize_frames() -> bool {
    std::env::var_os("SWIFTLY_RESIZE_INLINE").is_some()
}

/// Collects the latencies (milliseconds) of the resizes seen so far.
#[derive(Debug, Default)]
pub struct ResizeLatency {
    /// When the first `Resized` event not yet answered by a presented frame arrived.
    pending: Option<f64>,
    done: Vec<f64>,
    /// What the app itself spent on each frame made at a new size (layout, drawing, queueing the present).
    cost: Vec<f64>,
    configure: Vec<f64>,
    acquire: Vec<f64>,
}

impl ResizeLatency {
    /// A `Resized` event arrived at `now` (ms).
    pub fn resized(&mut self, now: f64) {
        self.pending.get_or_insert(now);
    }

    /// A frame at the window's current size was presented at `now` (ms). Returns the latency it ended.
    pub fn presented(&mut self, now: f64) -> Option<f64> {
        let t = self.pending.take()?;
        let ms = (now - t).max(0.0);
        self.done.push(ms);
        Some(ms)
    }

    /// A frame made at a new size took `ms` of the app's own time.
    pub fn frame_cost(&mut self, ms: f64) {
        self.cost.push(ms);
    }

    /// A swap chain was refitted to a new size in `ms`.
    pub fn configure_cost(&mut self, ms: f64) {
        self.configure.push(ms);
    }

    /// Waiting for the next surface image took `ms` in a frame made at a new size.
    pub fn acquire_wait(&mut self, ms: f64) {
        self.acquire.push(ms);
    }

    /// The latencies and the app's own costs so far as one line (`n`, median, 95th percentile, maximum each); `None`
    /// before any resize was answered.
    pub fn summary(&self) -> Option<String> {
        if self.done.is_empty() {
            return None;
        }
        let series = |name: &str, v: &[f64]| -> String {
            if v.is_empty() {
                return String::new();
            }
            let mut v = v.to_vec();
            v.sort_by(f64::total_cmp);
            let at = |q: f64| v[((v.len() - 1) as f64 * q).round() as usize];
            format!(
                "; {name}: n={} p50={:.1} p95={:.1} max={:.1}",
                v.len(),
                at(0.5),
                at(0.95),
                v[v.len() - 1]
            )
        };
        Some(format!(
            "resize (ms){}{}{}{}",
            series("Resized to presented", &self.done),
            series("swap chain refit", &self.configure),
            series("wait for the surface image", &self.acquire),
            series("layout and drawing", &self.cost)
        ))
    }

    /// Forgets what was measured (a new drag).
    pub fn clear(&mut self) {
        self.pending = None;
        self.done.clear();
        self.cost.clear();
        self.configure.clear();
        self.acquire.clear();
    }
}

/// The synthetic drag: the window asks for a new size every `interval`.
#[derive(Debug, Clone)]
pub struct ResizeBench {
    steps: u32,
    dw: i32,
    dh: i32,
    interval_ms: f64,
    done: u32,
    base: Option<(u32, u32)>,
    next_at: f64,
}

/// Start of the drag after the launch (ms).
const START_AFTER_MS: f64 = 3000.0;

impl ResizeBench {
    /// From the text `steps:dw:dh:interval_ms`; `None` when it does not read so.
    pub fn parse(text: &str) -> Option<ResizeBench> {
        let mut p = text.split(':');
        let steps = p.next()?.trim().parse().ok()?;
        let dw = p.next()?.trim().parse().ok()?;
        let dh = p.next()?.trim().parse().ok()?;
        let interval_ms = p.next()?.trim().parse().ok()?;
        Some(ResizeBench {
            steps,
            dw,
            dh,
            interval_ms,
            done: 0,
            base: None,
            next_at: START_AFTER_MS,
        })
    }

    /// From the environment.
    pub fn from_env() -> Option<ResizeBench> {
        ResizeBench::parse(&std::env::var("SWIFTLY_RESIZE_BENCH").ok()?)
    }

    /// The size to ask for at `now` (ms) given the window's size, `None` when no step is due. The first call fixes the
    /// size the drag starts from.
    pub fn due(&mut self, now: f64, size: (u32, u32)) -> Option<(u32, u32)> {
        if self.done >= self.steps || now < self.next_at {
            return None;
        }
        let (w0, h0) = *self.base.get_or_insert(size);
        self.done += 1;
        self.next_at = now + self.interval_ms;
        // Out and back: the window grows for half of the steps and shrinks again, so it never leaves the screen.
        let half = (self.steps / 2).max(1);
        let k = if self.done <= half {
            self.done as i32
        } else {
            (self.steps - self.done) as i32
        };
        let w = (w0 as i32 + k * self.dw).max(200) as u32;
        let h = (h0 as i32 + k * self.dh).max(200) as u32;
        Some((w, h))
    }

    /// Whether every step was asked for.
    pub fn finished(&self) -> bool {
        self.done >= self.steps
    }

    /// When the next step is due (ms since the start), `None` after the last.
    pub fn next_at(&self) -> Option<f64> {
        (!self.finished()).then_some(self.next_at)
    }

    /// The pause after the last step before the summary is printed.
    pub fn settle() -> Duration {
        Duration::from_millis(600)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_latency_runs_from_the_first_unanswered_resize_to_the_presented_frame() {
        let mut l = ResizeLatency::default();
        assert_eq!(l.presented(5.0), None);
        l.resized(10.0);
        l.resized(14.0);
        assert_eq!(l.presented(30.0), Some(20.0));
        l.resized(40.0);
        assert_eq!(l.presented(46.0), Some(6.0));
        l.configure_cost(1.5);
        let s = l.summary().unwrap();
        assert!(
            s.contains("n=2") && s.contains("max=20.0") && s.contains("swap chain refit: n=1"),
            "{s}"
        );
    }

    #[test]
    fn the_bench_grows_and_shrinks_the_window_and_stops_after_its_steps() {
        let mut b = ResizeBench::parse("4:10:5:16").unwrap();
        assert_eq!(b.due(100.0, (800, 600)), None, "not before the start");
        let mut asked = Vec::new();
        let mut t = 3000.0;
        while let Some(s) = b.due(t, (800, 600)) {
            asked.push(s);
            t += 16.0;
        }
        assert_eq!(asked, [(810, 605), (820, 610), (810, 605), (800, 600)]);
        assert!(b.finished() && b.next_at().is_none());
        assert!(ResizeBench::parse("nonsense").is_none());
    }
}
