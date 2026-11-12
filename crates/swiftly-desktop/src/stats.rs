//! Frame statistics for `--stats`: CPU time per frame, the interval between frames while the UI animates, dropped frames.

/// Seconds between two reports.
pub const REPORT_EVERY_MS: f64 = 5000.0;

/// A frame is counted as dropped when it comes later than this many refresh periods after the previous one.
const LATE_FACTOR: f64 = 1.5;

/// `p` (0 to 1) percentile of an ascending list (nearest rank). 0 for an empty list.
pub fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let rank = (p * sorted.len() as f64).ceil().max(1.0) as usize;
    sorted[(rank - 1).min(sorted.len() - 1)]
}

/// Collects frame times and prints a line every [`REPORT_EVERY_MS`].
#[derive(Debug)]
pub struct FrameStats {
    period_ms: f64,
    cpu: Vec<f64>,
    intervals: Vec<f64>,
    dropped: u64,
    total_frames: u64,
    total_dropped: u64,
    window_start: f64,
    last_start: Option<f64>,
}

impl FrameStats {
    /// Statistics for a display with a refresh period of `period_ms`.
    pub fn new(period_ms: f64, now: f64) -> FrameStats {
        FrameStats {
            period_ms: period_ms.max(1.0),
            cpu: vec![],
            intervals: vec![],
            dropped: 0,
            total_frames: 0,
            total_dropped: 0,
            window_start: now,
            last_start: None,
        }
    }

    /// One frame that started at `start_ms`, took `cpu_ms` to build, draw and submit, and was asked for by the previous
    /// frame (`continuous`) or by an input event. Only continuous frames count for the interval and dropped frames.
    pub fn record(&mut self, start_ms: f64, cpu_ms: f64, continuous: bool) {
        self.cpu.push(cpu_ms);
        self.total_frames += 1;
        if let (true, Some(prev)) = (continuous, self.last_start) {
            let dt = start_ms - prev;
            self.intervals.push(dt);
            if dt > LATE_FACTOR * self.period_ms {
                let missed = (dt / self.period_ms).round() as u64 - 1;
                self.dropped += missed;
                self.total_dropped += missed;
            }
        }
        self.last_start = Some(start_ms);
    }

    /// The line to print when [`REPORT_EVERY_MS`] have passed since the last one, and the new window starts.
    pub fn report(&mut self, now: f64) -> Option<String> {
        let span = now - self.window_start;
        if span < REPORT_EVERY_MS {
            return None;
        }
        let line = self.line(span);
        self.cpu.clear();
        self.intervals.clear();
        self.dropped = 0;
        self.window_start = now;
        Some(line)
    }

    /// When the next report is due.
    pub fn next_report_ms(&self) -> f64 {
        self.window_start + REPORT_EVERY_MS
    }

    /// Totals since the start, for the line printed on exit.
    pub fn totals(&self) -> String {
        format!(
            "stats total frames={} dropped={}",
            self.total_frames, self.total_dropped
        )
    }

    fn line(&self, span_ms: f64) -> String {
        let secs = span_ms / 1000.0;
        if self.cpu.is_empty() {
            return format!("stats {secs:.1}s frames=0 (idle: nothing was redrawn)");
        }
        let mut cpu = self.cpu.clone();
        cpu.sort_by(f64::total_cmp);
        let mut iv = self.intervals.clone();
        iv.sort_by(f64::total_cmp);
        let mut s = format!(
            "stats {secs:.1}s frames={} cpu_ms p50={:.2} p99={:.2} max={:.2}",
            cpu.len(),
            percentile(&cpu, 0.5),
            percentile(&cpu, 0.99),
            cpu.last().copied().unwrap_or(0.0),
        );
        if iv.is_empty() {
            s.push_str(" | no continuous frames");
        } else {
            s.push_str(&format!(
                " | interval_ms p50={:.2} p99={:.2} max={:.2} (period {:.2}) | dropped={}",
                percentile(&iv, 0.5),
                percentile(&iv, 0.99),
                iv.last().copied().unwrap_or(0.0),
                self.period_ms,
                self.dropped,
            ));
        }
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percentiles_use_the_nearest_rank() {
        let v: Vec<f64> = (1..=100).map(f64::from).collect();
        assert_eq!(percentile(&v, 0.5), 50.0);
        assert_eq!(percentile(&v, 0.99), 99.0);
        assert_eq!(percentile(&v, 1.0), 100.0);
        assert_eq!(percentile(&[], 0.5), 0.0);
    }

    #[test]
    fn a_late_frame_counts_the_periods_it_missed() {
        let mut s = FrameStats::new(8.0, 0.0);
        s.record(0.0, 1.0, true);
        s.record(8.0, 1.0, true);
        s.record(32.0, 1.0, true); // 24 ms = 3 periods: 2 missed
        s.record(40.0, 5.0, true);
        let line = s.report(5000.0).unwrap_or_default();
        assert!(line.contains("frames=4"), "{line}");
        assert!(line.contains("dropped=2"), "{line}");
        assert!(line.contains("max=5.00"), "{line}");
        assert!(s.report(5001.0).is_none());
    }

    #[test]
    fn an_idle_window_says_so() {
        let mut s = FrameStats::new(16.7, 0.0);
        assert!(s.report(4000.0).is_none());
        let line = s.report(5000.0).unwrap_or_default();
        assert!(line.contains("frames=0"), "{line}");
    }

    #[test]
    fn frames_from_input_do_not_count_for_the_interval() {
        let mut s = FrameStats::new(8.0, 0.0);
        s.record(0.0, 1.0, false);
        s.record(500.0, 1.0, false);
        let line = s.report(5000.0).unwrap_or_default();
        assert!(line.contains("no continuous frames"), "{line}");
        assert!(!line.contains("dropped"));
    }
}
