//! Input-to-present: from the arrival of an input event in the app to the `present` call of the frame that shows it.
//! The photon itself (the pixels lighting up) cannot be measured without a camera or a photodiode; this is the part the
//! app and the swap chain own. With FIFO present the wait for the next vblank is inside the number, as it is for the user.
//!
//! `--latency` also runs a scripted wheel session from a thread (mouse notches and touchpad bursts), delivered through
//! the event-loop proxy, so the run needs nobody at the mouse. The stamp of such an event is taken in the sending
//! thread, which adds the queue wait of the event loop (what a real event waits for as well).

use crate::stats::percentile;
use crate::wheel::{WheelDelta, WheelPhase};
use std::time::Instant;

/// Upper edges (ms) of the histogram buckets; the last bucket is open.
pub const EDGES_MS: [f64; 9] = [4.0, 8.0, 12.0, 16.0, 20.0, 25.0, 33.0, 50.0, 100.0];

/// Collects input-to-present samples.
#[derive(Debug, Default)]
pub struct InputLatency {
    pending: Option<Instant>,
    samples: Vec<f64>,
}

/// The result of a run.
#[derive(Clone, Debug, PartialEq)]
pub struct Summary {
    /// Samples (one per presented frame that showed an input).
    pub n: usize,
    /// Median (ms).
    pub p50: f64,
    /// 95th percentile (ms).
    pub p95: f64,
    /// 99th percentile (ms).
    pub p99: f64,
    /// Slowest (ms).
    pub max: f64,
    /// Counts per bucket of [`EDGES_MS`] (one more than edges).
    pub histogram: Vec<usize>,
}

impl InputLatency {
    /// An input event arrived at `at`. Only the oldest input that is not yet shown counts for the next frame.
    pub fn mark(&mut self, at: Instant) {
        self.pending.get_or_insert(at);
    }

    /// A frame is presented at `now`: closes the pending input, if any. Returns its latency (ms).
    pub fn presented(&mut self, now: Instant) -> Option<f64> {
        let at = self.pending.take()?;
        let ms = now.saturating_duration_since(at).as_secs_f64() * 1000.0;
        self.samples.push(ms);
        Some(ms)
    }

    /// Statistics of everything collected.
    pub fn summary(&self) -> Summary {
        let mut s = self.samples.clone();
        s.sort_by(f64::total_cmp);
        let mut histogram = vec![0; EDGES_MS.len() + 1];
        for v in &s {
            histogram[EDGES_MS
                .iter()
                .position(|e| v < e)
                .unwrap_or(EDGES_MS.len())] += 1;
        }
        Summary {
            n: s.len(),
            p50: percentile(&s, 0.50),
            p95: percentile(&s, 0.95),
            p99: percentile(&s, 0.99),
            max: s.last().copied().unwrap_or(0.0),
            histogram,
        }
    }

    /// The printable report: percentiles and the histogram, with the refresh period they should be read against.
    pub fn report(&self, period_ms: f64) -> String {
        let s = self.summary();
        let mut out = format!(
            "input-to-present: {} inputs, p50 {:.2} ms, p95 {:.2} ms, p99 {:.2} ms, max {:.2} ms (refresh period {period_ms:.2} ms = {:.0} Hz)\nhistogram (ms):",
            s.n,
            s.p50,
            s.p95,
            s.p99,
            s.max,
            1000.0 / period_ms.max(1.0)
        );
        for (i, c) in s.histogram.iter().enumerate() {
            let lo = if i == 0 { 0.0 } else { EDGES_MS[i - 1] };
            match EDGES_MS.get(i) {
                Some(hi) => out.push_str(&format!(
                    "\n  {lo:>5.0} to {hi:<5.0} {c:>5} {}",
                    "#".repeat((*c).min(60))
                )),
                None => out.push_str(&format!(
                    "\n  {lo:>5.0} and up    {c:>5} {}",
                    "#".repeat((*c).min(60))
                )),
            }
        }
        out
    }
}

/// One scripted event: send time since the start of the script (ms), and what it is.
pub type Step = (f64, WheelDelta, Option<WheelPhase>);

/// The script of one second: five mouse notches 40 ms apart, then a touchpad burst of 40 events 8 ms apart with a
/// decaying speed (fingers land, move, lift) after a pause. Repeated `rounds` times.
pub fn script(rounds: u32) -> Vec<Step> {
    let mut steps = Vec::new();
    for r in 0..rounds {
        let t0 = f64::from(r) * 1000.0;
        for i in 0..5 {
            steps.push((
                t0 + 40.0 * f64::from(i),
                WheelDelta::Lines(0.0, -1.0),
                Some(WheelPhase::Moved),
            ));
        }
        let t1 = t0 + 500.0;
        steps.push((t1, WheelDelta::Points(0.0, 0.0), Some(WheelPhase::Started)));
        for i in 0..40 {
            let k = 1.0 - i as f32 / 40.0;
            steps.push((
                t1 + 8.0 * f64::from(i + 1),
                WheelDelta::Points(0.0, 30.0 * k),
                Some(WheelPhase::Moved),
            ));
        }
        steps.push((
            t1 + 8.0 * 41.0,
            WheelDelta::Points(0.0, 0.0),
            Some(WheelPhase::Ended),
        ));
    }
    steps
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn the_oldest_input_closes_at_the_next_present() {
        let t0 = Instant::now();
        let mut l = InputLatency::default();
        l.mark(t0);
        l.mark(t0 + Duration::from_millis(5));
        let ms = l.presented(t0 + Duration::from_millis(12)).unwrap();
        assert!((ms - 12.0).abs() < 0.01);
        assert_eq!(l.presented(t0 + Duration::from_millis(20)), None);
    }

    #[test]
    fn percentiles_and_histogram() {
        let t0 = Instant::now();
        let mut l = InputLatency::default();
        for ms in [3, 6, 6, 10, 14, 14, 14, 18, 40, 120] {
            l.mark(t0);
            l.presented(t0 + Duration::from_millis(ms));
        }
        let s = l.summary();
        assert_eq!(s.n, 10);
        assert!((s.p50 - 14.0).abs() < 0.01);
        assert!((s.max - 120.0).abs() < 0.01);
        assert_eq!(s.histogram.iter().sum::<usize>(), 10);
        assert_eq!(s.histogram[0], 1);
        assert_eq!(*s.histogram.last().unwrap(), 1);
        assert!(l.report(6.94).contains("144 Hz"));
    }

    #[test]
    fn the_script_is_ordered_and_balanced() {
        let s = script(3);
        assert!(s.windows(2).all(|w| w[0].0 <= w[1].0));
        let started = s
            .iter()
            .filter(|x| x.2 == Some(WheelPhase::Started))
            .count();
        let ended = s.iter().filter(|x| x.2 == Some(WheelPhase::Ended)).count();
        assert_eq!((started, ended), (3, 3));
    }
}
