//! Port of PlaybackLevels.swift.
//!
//! The playback speeds, sleep timer steps and the running-time text of the player.

use crate::whole_number::capped;

/// The playback speeds the player offers. (`SpeedLevels.values`)
pub const SPEED_VALUES: [f32; 5] = [0.75, 1.0, 1.25, 1.5, 2.0];

/// The sleep timer steps, in minutes. (`SleepTimes.values`)
pub const SLEEP_TIMES: [i64; 5] = [15, 30, 45, 60, 90];

/// "1,25×" / "1.25×" / "1×": the number as `value.formatted(.number)` writes it (up to three
/// fraction digits, trailing zeros trimmed) with the given decimal separator, then "×".
/// (`PlaybackLevels.swift:20-22`)
///
/// Foundation note: `.number` also applies the locale's digits and grouping; for the five
/// speeds only the decimal separator matters, which is why only that is a parameter.
pub fn speed_label(value: f32, decimal_separator: &str) -> String {
    let fixed = format!("{:.3}", f64::from(value));
    let trimmed = fixed.trim_end_matches('0').trim_end_matches('.');
    let number = if trimmed == "-0" { "0" } else { trimmed };
    format!("{}×", number.replace('.', decimal_separator))
}

/// The running time in the player: "1:23" or "1:23:45". Deliberately not locale-aware.
/// Nonsense (NaN, infinite, negative) gives "0:00". (`PlaybackLevels.swift:36-44`)
pub fn play_time_text(seconds: f64) -> String {
    if !seconds.is_finite() || seconds < 0.0 {
        return "0:00".to_owned();
    }
    let whole = capped(seconds);
    let (s, m, h) = (whole % 60, (whole / 60) % 60, whole / 3600);
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

/// "One billion effectively means unlimited" (`BitratesLimit.opened`).
pub const BITRATE_OPENED: i64 = 1_000_000_000;

/// The bitrate limit reported to the server (`BitratesLimit.of`): none when "Always Direct
/// Play" is on or the configured limit is zero or less, otherwise Mbit/s as bit/s.
pub fn bitrate_limit_of(always_direct_play: bool, megabit: i64) -> i64 {
    if always_direct_play || megabit <= 0 {
        BITRATE_OPENED
    } else {
        megabit.saturating_mul(1_000_000)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Swift: levels()
    #[test]
    fn levels() {
        assert_eq!(SPEED_VALUES, [0.75, 1.0, 1.25, 1.5, 2.0]);
        assert_eq!(SLEEP_TIMES, [15, 30, 45, 60, 90]);
    }

    // Swift: wholeNumber()
    #[test]
    fn whole_number() {
        assert_eq!(speed_label(1.0, ","), "1×");
        assert_eq!(speed_label(2.0, ","), "2×");
    }

    // Swift: separatorCharacter()
    #[test]
    fn separator_character() {
        let text = speed_label(1.25, ",");
        assert!(text.ends_with('×'));
        assert!(!text.contains("125"));
        assert_eq!(text, "1,25×");
        assert_eq!(speed_label(1.25, "."), "1.25×");
        assert_eq!(speed_label(0.75, "."), "0.75×");
    }

    // Swift: short()
    #[test]
    fn short() {
        assert_eq!(play_time_text(0.0), "0:00");
        assert_eq!(play_time_text(65.0), "1:05");
        assert_eq!(play_time_text(3599.0), "59:59");
    }

    // Swift: long()
    #[test]
    fn long() {
        assert_eq!(play_time_text(3600.0), "1:00:00");
        assert_eq!(play_time_text(5025.0), "1:23:45");
    }

    // Swift: unsinn()
    #[test]
    fn nonsense() {
        assert_eq!(play_time_text(-5.0), "0:00");
        assert_eq!(play_time_text(f64::NAN), "0:00");
        assert_eq!(play_time_text(f64::INFINITY), "0:00");
    }
}
