//! The heartbeat of the progress reports: wall-clock spacing instead of a count of ticks.
//!
//! The tick rules (`swiftly_rules::playback_tick`) report after twenty half-second ticks. When the host's tick loop
//! runs late (a busy main thread, a throttled timer), twenty ticks take far longer than ten seconds and the server
//! falls behind: after a crash it holds an old minute. The beat measures real seconds, so a late tick still reports
//! as soon as ten seconds have passed since the last report that went out, and a lost tick costs at most one tick.
//!
//! One state machine, driven by `now` only (seconds on any consistent clock), no I/O.

use swiftly_rules::playback_tick::{REPORT_SPACING, Snapshot, WorkItem};

/// Where the schedule stands.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ProgressBeat {
    /// No start report went out yet (or the title was replaced): nothing is due.
    Idle,
    /// The server heard from the player at `last`.
    Running {
        /// When the newest start or progress report was handed to the reporter.
        last: f64,
    },
}

impl ProgressBeat {
    /// The start report went out (or an episode switch carried it on).
    pub fn started(&mut self, now: f64) {
        *self = Self::Running { last: now };
    }

    /// Any progress report went out (the ten second one, a pause, a seek, the background report).
    pub fn reported(&mut self, now: f64) {
        if matches!(self, Self::Running { .. }) {
            *self = Self::Running { last: now };
        }
    }

    /// The title ended or was replaced.
    pub fn stopped(&mut self) {
        *self = Self::Idle;
    }

    /// Ten seconds of wall time passed since the last report: one is due now. A clock that went backwards never
    /// makes one due.
    #[must_use]
    pub fn due(&self, now: f64) -> bool {
        matches!(self, Self::Running { last } if now - last >= REPORT_SPACING)
    }

    /// One tick: does a progress report go out now? This is the **only** place that decides it.
    ///
    /// The tick rules keep their own count of twenty half-second ticks (`since_message`). That count and this beat
    /// ran side by side: with ticks of 0.6 s the beat reported at 10.2 s, the count at 12 s, and the server got two
    /// reports 1.8 s apart. The count is held at zero here, so what remains of the rules' report is the one they ask
    /// for outright (the tracks went out after an episode switch: the next report carries them at once). Everything
    /// regular comes from the wall clock, and only while a picture shows (a title that has no first frame yet, such as
    /// the one an episode switch has just started, reports no position).
    #[must_use]
    pub fn progress_due(&self, job: &WorkItem, snap: &mut Snapshot, now: f64) -> bool {
        snap.since_message = 0.0;
        if job.start_report {
            return false;
        }
        job.progress_report
            || (snap.start_reported
                && snap.first_image_present
                && snap.duration > 0.0
                && self.due(now))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nothing_is_due_before_the_start_report() {
        assert!(!ProgressBeat::Idle.due(1e9));
    }

    #[test]
    fn due_after_ten_seconds_and_reset_by_any_report() {
        let mut b = ProgressBeat::Idle;
        b.started(100.0);
        assert!(!b.due(109.9));
        assert!(b.due(110.0));
        b.reported(104.0);
        assert!(!b.due(110.0));
        assert!(b.due(114.0));
    }

    fn shown() -> Snapshot {
        Snapshot {
            first_image_present: true,
            start_reported: true,
            duration: 3600.0,
            ..Snapshot::default()
        }
    }

    #[test]
    fn the_tick_count_never_reports_on_its_own_and_the_beat_decides() {
        let mut b = ProgressBeat::Idle;
        b.started(0.0);
        let job = WorkItem::default();
        let mut snap = shown();
        // Ticks of 0.6 s: due at 10.2 s, not again at 12 s (twenty counted ticks).
        let mut at = Vec::new();
        let mut t = 0.0;
        while t < 40.0 {
            t += 0.6;
            // The rules count half seconds; the count must not matter.
            snap.since_message += 0.5;
            if b.progress_due(&job, &mut snap, t) {
                b.reported(t);
                at.push(t);
            }
        }
        assert!(at.windows(2).all(|w| w[1] - w[0] >= 10.0), "{at:?}");
        assert_eq!(at.len(), 3, "{at:?}");
    }

    #[test]
    fn a_report_the_rules_ask_for_outright_still_goes_out() {
        let b = ProgressBeat::Idle;
        let job = WorkItem {
            progress_report: true,
            ..WorkItem::default()
        };
        assert!(b.progress_due(&job, &mut shown(), 1.0));
    }

    #[test]
    fn no_beat_report_before_the_first_picture_of_a_switched_title() {
        let mut b = ProgressBeat::Idle;
        b.started(100.0);
        let mut snap = Snapshot {
            first_image_present: false,
            start_reported: true,
            ..Snapshot::default()
        };
        assert!(!b.progress_due(&WorkItem::default(), &mut snap, 500.0));
        snap.first_image_present = true;
        snap.duration = 3600.0;
        assert!(b.progress_due(&WorkItem::default(), &mut snap, 500.0));
    }

    #[test]
    fn a_backwards_clock_is_never_due_and_stopped_is_idle() {
        let mut b = ProgressBeat::Idle;
        b.started(100.0);
        assert!(!b.due(50.0));
        b.stopped();
        assert!(!b.due(1e9));
        b.reported(5.0);
        assert_eq!(b, ProgressBeat::Idle);
    }
}
