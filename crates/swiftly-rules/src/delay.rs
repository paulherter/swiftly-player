//! Port of Delay.swift.
//!
//! Subtitle or audio delay in the player: one rule for all platforms. Shifted in 50 ms
//! steps, positive means later, VLC counts it in microseconds.

/// A subtitle/audio delay. Always a multiple of [`Delay::STEP`], always within
/// +-[`Delay::LIMIT`] milliseconds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Delay {
    /// Always a multiple of `STEP`, always within +-`LIMIT`.
    milliseconds: i64,
}

impl Delay {
    /// One press of - or +.
    pub const STEP: i64 = 50;
    /// Beyond ten seconds it is the wrong track.
    pub const LIMIT: i64 = 10_000;
    /// No delay.
    pub const NULL: Delay = Delay { milliseconds: 0 };

    /// Clamps to +-`LIMIT`, then rounds to the nearest step, halves away from zero, so a
    /// value VLC reads back as 199 999 us becomes 200 ms again. (`Delay.swift:35-40`)
    pub fn from_milliseconds(milliseconds: i64) -> Self {
        let limited = milliseconds.clamp(-Self::LIMIT, Self::LIMIT);
        // Swift: `(Double(limited) / Double(step)).rounded(.toNearestOrAwayFromZero)`.
        let steps = (limited as f64 / Self::STEP as f64).round();
        Self {
            milliseconds: steps as i64 * Self::STEP,
        }
    }

    /// From VLC's microseconds: `Int((Double(us) / 1000).rounded())` (half away from zero).
    pub fn from_microseconds(microseconds: i64) -> Self {
        Self::from_milliseconds(crate::whole_number::capped(
            (microseconds as f64 / 1000.0).round(),
        ))
    }

    /// The delay in milliseconds.
    pub fn milliseconds(self) -> i64 {
        self.milliseconds
    }

    /// For VLC.
    pub fn microseconds(self) -> i64 {
        self.milliseconds * 1000
    }

    /// Is the delay zero?
    pub fn is_null(self) -> bool {
        self.milliseconds == 0
    }

    /// At the lower limit.
    pub fn at_start(self) -> bool {
        self.milliseconds <= -Self::LIMIT
    }

    /// At the upper limit.
    pub fn at_end(self) -> bool {
        self.milliseconds >= Self::LIMIT
    }

    /// Earlier (-1) or later (+1), by `steps` steps (at least one). `bearing` only
    /// contributes its sign. (`Delay.swift:62-64`)
    pub fn shifted(self, bearing: i64, steps: i64) -> Delay {
        Delay::from_milliseconds(
            self.milliseconds.saturating_add(
                bearing
                    .signum()
                    .saturating_mul(steps.max(1))
                    .saturating_mul(Self::STEP),
            ),
        )
    }

    /// Holding speeds up: the first ten repeats are one step each, then two, from the
    /// thirtieth five. (`Delay.swift:73-79`)
    pub fn steps_on_repetition(n: i64) -> i64 {
        match n {
            ..10 => 1,
            10..30 => 2,
            _ => 5,
        }
    }

    /// "+0.20", "-1.50", "0,00": the minus as a real minus sign (U+2212), two decimals because
    /// a step is 0.05, separator as given. The unit (" s", in Russian " с") comes from the
    /// catalog: append it. (`Delay.swift:112-120`)
    pub fn figure(self, decimal_separator: &str) -> String {
        let magnitude = self.milliseconds.abs();
        let hundredths = (magnitude % 1000) / 10;
        let figure = format!(
            "{}{decimal_separator}{}{hundredths}",
            magnitude / 1000,
            if hundredths < 10 { "0" } else { "" }
        );
        let sign = match self.milliseconds {
            m if m > 0 => "+",
            m if m < 0 => "\u{2212}",
            _ => "",
        };
        format!("{sign}{figure}")
    }

    /// `figure` followed by the translated unit, which already starts with its space
    /// (Swift: `translated("\(figure) s")`).
    pub fn text(self, decimal_separator: &str, unit: &str) -> String {
        format!("{}{unit}", self.figure(decimal_separator))
    }

    /// What applies when switching to another title: the same title and the same series keep
    /// the value, anything else starts at zero. (`Delay.swift:127-132`)
    pub fn for_new_title(
        current: Delay,
        old_title: &str,
        old_series: Option<&str>,
        new_title: &str,
        added_series: Option<&str>,
    ) -> Delay {
        if old_title == new_title {
            return current;
        }
        match (old_series, added_series) {
            (Some(a), Some(b)) if a == b => current,
            _ => Delay::NULL,
        }
    }

    /// Does VLC report a different value than intended? Under one millisecond is rounding.
    pub fn soft_off(self, read_microseconds: i64) -> bool {
        read_microseconds.abs_diff(self.microseconds()) >= 1000
    }
}

/// Counts the repeats of a held button. A press that follows the previous one within
/// [`HoldCounter::RAILS_GAP`] seconds belongs to the same series.
#[derive(Debug, Clone, Copy, Default)]
pub struct HoldCounter {
    last_one: Option<f64>,
    rail: i64,
}

impl HoldCounter {
    /// Longer than the system's repeat pause, shorter than a deliberate second tap.
    pub const RAILS_GAP: f64 = 0.3;

    /// A new counter.
    pub fn new() -> Self {
        Self::default()
    }

    /// How many steps this press counts for. `now` is in seconds on any consistent clock.
    pub fn press(&mut self, now: f64) -> i64 {
        if let Some(last) = self.last_one
            && now - last < Self::RAILS_GAP
        {
            self.rail += 1;
        } else {
            self.rail = 0;
        }
        self.last_one = Some(now);
        Delay::steps_on_repetition(self.rail)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(ms: i64) -> Delay {
        Delay::from_milliseconds(ms)
    }

    // Swift: step()
    #[test]
    fn step() {
        assert_eq!(Delay::NULL.shifted(1, 1).milliseconds(), 50);
        assert_eq!(Delay::NULL.shifted(-1, 1).milliseconds(), -50);
        assert_eq!(d(200).shifted(1, 5).milliseconds(), 450);
    }

    // Swift: limits()
    #[test]
    fn limits() {
        let top = d(9_950).shifted(1, 5);
        assert_eq!(top.milliseconds(), 10_000);
        assert!(top.at_end());
        assert_eq!(top.shifted(1, 1), top);
        let bottom = d(-12_000);
        assert_eq!(bottom.milliseconds(), -10_000);
        assert!(bottom.at_start());
    }

    // Swift: grid()
    #[test]
    fn grid() {
        assert_eq!(d(74).milliseconds(), 50);
        assert_eq!(d(75).milliseconds(), 100);
        assert_eq!(d(-75).milliseconds(), -100);
    }

    // Swift: microseconds()
    #[test]
    fn microseconds() {
        assert_eq!(d(250).microseconds(), 250_000);
        assert_eq!(Delay::from_microseconds(199_999).milliseconds(), 200);
        assert_eq!(
            Delay::from_microseconds(-10_000_000).milliseconds(),
            -10_000
        );
        assert!(!d(200).soft_off(199_999));
        assert!(d(200).soft_off(0));
    }

    // Swift: text() - the unit comes from the catalog, here " s".
    #[test]
    fn text() {
        let unit = " s";
        assert_eq!(d(200).text(",", unit), "+0,20 s");
        assert_eq!(d(-1_550).text(",", unit), "\u{2212}1,55 s");
        assert_eq!(d(50).text(".", unit), "+0.05 s");
        assert_eq!(Delay::NULL.text(",", unit), "0,00 s");
        assert_eq!(d(10_000).text(",", unit), "+10,00 s");
    }

    // Swift: hold()
    #[test]
    fn hold() {
        assert_eq!(Delay::steps_on_repetition(0), 1);
        let mut before = 0;
        for n in 0..60 {
            let s = Delay::steps_on_repetition(n);
            assert!(s >= before);
            before = s;
        }
        assert!(before > 1);
    }

    // Swift: holdCounter()
    #[test]
    fn hold_counter() {
        let mut z = HoldCounter::new();
        let steps: Vec<i64> = (0..40).map(|i| z.press(f64::from(i) * 0.1)).collect();
        assert_eq!(steps.first(), Some(&1));
        assert_eq!(steps.last(), Some(&5));
        assert_eq!(z.press(10.0), 1);
    }

    // Swift: keep()
    #[test]
    fn keep() {
        let value = d(300);
        let new = |a: &str, sa: Option<&str>, b: &str, sb: Option<&str>| {
            Delay::for_new_title(value, a, sa, b, sb)
        };
        assert_eq!(new("f1", Some("s"), "f2", Some("s")), value);
        assert_eq!(new("f1", Some("s"), "f2", Some("t")), Delay::NULL);
        assert_eq!(new("film", None, "anderer", None), Delay::NULL);
        assert_eq!(new("f1", Some("s"), "film", None), Delay::NULL);
        // The same film reloaded (different quality) keeps it.
        assert_eq!(new("film", None, "film", None), value);
    }
}
