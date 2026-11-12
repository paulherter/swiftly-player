//! Port of Counter.swift: VLC's counters, computed without VLC. The tech badge numbers come from
//! the difference of two measurements and the time between them. Times are seconds as `f64`
//! (Swift `Date` is the same double, `timeIntervalSince` is the plain difference).

/// The raw values of one measurement as VLC keeps them: totals since playback began.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct RawValues {
    pub has_read: u64,
    pub unpacked: u64,
    pub shown: u64,
    pub discarded: u64,
    pub too_late: u64,
    pub video_blocks: u64,
    pub audio_blocks: u64,
    pub audio_play: u64,
    pub audio_lost: u64,
    pub damaged: u64,
    pub jumps: u64,
}

/// One measurement and what it computes against the previous one.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Counter {
    pub raw: RawValues,
    /// When this measurement was taken (measured, not assumed).
    pub measured_at: f64,
    /// The position in the movie, in seconds.
    pub spot: f64,
    /// Bits per second at the input; `None` the first time.
    pub input: Option<f64>,
    pub demuxer: Option<f64>,
    /// Displayed frames per second over the long window.
    pub shows_per_second: Option<f64>,
    /// Decoded frames per second.
    pub decoded_per_second: Option<f64>,
    /// How fast the position advances against the real clock (1 is real time).
    pub run_share: Option<f64>,
    base_shown: u64,
    base_decoded: u64,
    base_point: f64,
    base_time: f64,
}

/// Twenty seconds: a short window is noisy.
pub const WINDOW: f64 = 20.0;
/// Nothing is reported before then.
pub const AT_LEAST: f64 = 4.0;
/// If VLC never filled the structure it contains garbage; above this is not a measurement.
pub const LIMIT: u64 = 1_000_000_000;

impl Counter {
    /// `Counter.init?`: `None` if a field looks like garbage.
    pub fn new(
        raw: RawValues,
        spot: f64,
        running: bool,
        before: Option<&Counter>,
        now: f64,
    ) -> Option<Counter> {
        if [
            raw.shown,
            raw.discarded,
            raw.too_late,
            raw.video_blocks,
            raw.audio_blocks,
            raw.audio_lost,
            raw.damaged,
            raw.jumps,
            raw.audio_play,
        ]
        .iter()
        .any(|v| *v >= LIMIT)
        {
            return None;
        }

        let seconds = before.map_or(0.0, |b| now - b.measured_at);

        // A seek invalidates the window, and the ramp-up does not count.
        let continues_running = running
            && before.is_some_and(|b| spot >= b.spot && spot - b.spot <= seconds * 2.0 + 1.0);

        let (base_shown, base_decoded, base_point, base_time) = match before {
            Some(v)
                if continues_running && raw.shown >= v.base_shown && now - v.base_time < WINDOW =>
            {
                (v.base_shown, v.base_decoded, v.base_point, v.base_time)
            }
            Some(v) if continues_running && raw.shown >= v.raw.shown => {
                (v.raw.shown, v.raw.video_blocks, v.spot, v.measured_at)
            }
            _ => (raw.shown, raw.video_blocks, spot, now),
        };

        let extent_span = now - base_time;
        let ripe = extent_span >= AT_LEAST;
        let shows_per_second = (ripe && raw.shown >= base_shown)
            .then(|| (raw.shown - base_shown) as f64 / extent_span);
        let decoded_per_second = (ripe && raw.video_blocks >= base_decoded)
            .then(|| (raw.video_blocks - base_decoded) as f64 / extent_span);
        let run_share = (ripe && spot >= base_point).then(|| (spot - base_point) / extent_span);

        Some(Counter {
            raw,
            measured_at: now,
            spot,
            input: rate(raw.has_read, before.map(|b| b.raw.has_read), seconds),
            demuxer: rate(raw.unpacked, before.map(|b| b.raw.unpacked), seconds),
            shows_per_second,
            decoded_per_second,
            run_share,
            base_shown,
            base_decoded,
            base_point,
            base_time,
        })
    }

    /// Read minus unpacked: the buffer in bytes.
    pub fn pre_advice_bytes(&self) -> u64 {
        self.raw.has_read.saturating_sub(self.raw.unpacked)
    }

    /// The buffer in seconds, if the file's bitrate demand is known.
    pub fn reserve_seconds(&self, bytes_per_second: f64) -> Option<f64> {
        (bytes_per_second > 0.0).then(|| self.pre_advice_bytes() as f64 / bytes_per_second)
    }
}

/// The rate is computed, not read: VLC's own floating-point fields were 0 on Apple TV.
fn rate(now: u64, before: Option<u64>, seconds: f64) -> Option<f64> {
    let before = before?;
    if seconds <= 0.0 || now < before {
        return None;
    }
    let bit = (now - before) as f64 * 8.0 / seconds;
    (bit > 0.0).then_some(bit)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw(shown: u64, blocks: u64, read: u64) -> RawValues {
        RawValues {
            shown,
            video_blocks: blocks,
            has_read: read,
            unpacked: read / 2,
            ..RawValues::default()
        }
    }

    #[test]
    fn first_measurement_reports_nothing() {
        let c = Counter::new(raw(10, 10, 1000), 1.0, true, None, 100.0).unwrap();
        assert!(c.input.is_none() && c.shows_per_second.is_none() && c.run_share.is_none());
        assert_eq!(c.pre_advice_bytes(), 500);
        assert_eq!(c.reserve_seconds(250.0), Some(2.0));
        assert_eq!(c.reserve_seconds(0.0), None);
    }

    #[test]
    fn rates_come_from_the_window() {
        let a = Counter::new(raw(0, 0, 0), 0.0, true, None, 0.0).unwrap();
        let b = Counter::new(raw(120, 125, 4000), 5.0, true, Some(&a), 5.0).unwrap();
        assert_eq!(b.shows_per_second, Some(24.0));
        assert_eq!(b.decoded_per_second, Some(25.0));
        assert_eq!(b.run_share, Some(1.0));
        assert_eq!(b.input, Some(6400.0));
    }

    #[test]
    fn garbage_is_refused_and_a_seek_restarts() {
        assert!(Counter::new(raw(LIMIT, 0, 0), 0.0, true, None, 0.0).is_none());
        let a = Counter::new(raw(0, 0, 0), 0.0, true, None, 0.0).unwrap();
        let b = Counter::new(raw(500, 500, 0), 600.0, true, Some(&a), 5.0).unwrap();
        assert!(b.shows_per_second.is_none());
    }
}
