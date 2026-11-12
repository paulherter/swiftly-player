//! More player rules of the desktop and Apple player that the view model carries: volume and
//! mute (`PlayerPage.volumeApply` / `mutedToggle` / `volumeLevel` / `volumeWheel`), the end-time
//! clock (`PlayerPage.timesShow`, setting `endzeitImPlayer`), the "plays in the small window"
//! state of picture in picture (`PlayerScreen.smallWindow`), and the mid-play stream check
//! (`PlayerPage.streamCheck`, `streamNewBuildUp`, `woke`) built on `swiftly_playback::stream_watch`.
//!
//! Pure: every time is passed in. The wall clock for the end time is passed as epoch seconds.

use swiftly_playback::stream_watch::{Sample, StreamCheck};
use swiftly_rules::playback_levels::play_time_text;

/// The notice over a picture that plays in the small window (`Läuft im kleinen Fenster`).
pub const SMALL_WINDOW_TEXT: &str = "Läuft im kleinen Fenster";
/// Label when the end time is shown (`Endet um %@`, the `%@` is the clock text).
pub const ENDS_AT_KEY: &str = "Endet um %@";
/// Caption of the remaining-time label (`Restzeit`).
pub const REMAINING_KEY: &str = "Restzeit";

/// Volume as a share 0...1 plus the value to come back to when un-muting (`selection.volume`,
/// `selection.volumePrior`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VolumeState {
    volume: f64,
    prior: f64,
}

impl Default for VolumeState {
    fn default() -> Self {
        Self::new(1.0)
    }
}

impl VolumeState {
    /// Starts at `volume` (0...1).
    pub fn new(volume: f64) -> Self {
        Self {
            volume: volume.clamp(0.0, 1.0),
            prior: 1.0,
        }
    }

    /// The share 0...1.
    pub fn share(&self) -> f64 {
        self.volume
    }

    /// The percent the engine gets.
    pub fn percent(&self) -> u8 {
        (self.volume * 100.0).round() as u8
    }

    /// Silent (volume zero).
    pub fn is_muted(&self) -> bool {
        self.volume <= 0.0
    }

    /// `volumeApply`: clamps to 0...1 and returns the engine percent.
    pub fn apply(&mut self, share: f64) -> u8 {
        self.volume = share.clamp(0.0, 1.0);
        self.percent()
    }

    /// The slider / `Volume(0...100)` intent. A value above zero ends the mute.
    pub fn set_percent(&mut self, percent: i32) -> u8 {
        self.apply(f64::from(percent.clamp(0, 100)) / 100.0)
    }

    /// `mutedToggle`: sound on goes to zero and remembers the level; sound off comes back to
    /// the remembered level, or to 1 percent when it was never above zero.
    pub fn toggle_mute(&mut self) -> u8 {
        if self.volume > 0.0 {
            self.prior = self.volume;
            self.apply(0.0)
        } else {
            let back = if self.prior > 0.0 { self.prior } else { 0.01 };
            self.apply(back)
        }
    }

    /// `volumeLevel`: arrow up/down, a step in shares (0.05 is 5 %), rounded to a whole percent.
    pub fn step(&mut self, step: f64) -> u8 {
        self.apply(((self.volume + step) * 100.0).round() / 100.0)
    }

    /// `volumeWheel`: continuous, the wheel's step added as is.
    pub fn wheel(&mut self, step: f64) -> u8 {
        self.apply(self.volume + step)
    }
}

/// What the lower right label of the time bar says.
#[derive(Debug, Clone, PartialEq)]
pub enum TimesLabel {
    /// "Endet um ..." with this moment (epoch seconds); the host formats the time of day.
    Ends {
        /// Epoch seconds the title ends, if it runs on from now at speed 1.
        at: f64,
    },
    /// "−1:02:03" with the caption "Restzeit".
    Remaining {
        /// The text, minus sign included.
        text: String,
    },
}

/// `timesShow` (desktop) and `endzeitImPlayer`: the end-time clock is now + remaining, or the
/// remaining time. `None` while the duration is unknown.
pub fn times_label(
    position: f64,
    duration: f64,
    end_time_in_player: bool,
    now_epoch: f64,
) -> Option<TimesLabel> {
    if duration.is_nan() || duration <= 0.0 {
        return None;
    }
    let rest = (duration - position).max(0.0);
    Some(if end_time_in_player {
        TimesLabel::Ends {
            at: now_epoch + rest,
        }
    } else {
        TimesLabel::Remaining {
            text: format!("−{}", play_time_text(rest)),
        }
    })
}

/// "22:41" or "10:41 PM" for epoch seconds in a zone `utc_offset_seconds` from UTC (the
/// `.short` time style; the host passes its locale's 12/24-hour choice).
pub fn clock_text(epoch: f64, utc_offset_seconds: i64, twenty_four_hour: bool) -> String {
    let day = (epoch.floor() as i64)
        .saturating_add(utc_offset_seconds)
        .rem_euclid(86_400);
    let (hour, minute) = (day / 3600, (day / 60) % 60);
    if twenty_four_hour {
        format!("{hour:02}:{minute:02}")
    } else {
        let (h12, suffix) = match hour {
            0 => (12, "AM"),
            1..=11 => (hour, "AM"),
            12 => (12, "PM"),
            _ => (hour - 12, "PM"),
        };
        format!("{h12}:{minute:02} {suffix}")
    }
}

/// What the host reads from the engine for the stream check, once a second.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct StreamReading {
    /// The title is a local file: never rebuilt.
    pub is_file: bool,
    /// Pictures shown so far for this media.
    pub pictures_shown: Option<u64>,
    /// Bytes read so far for this media.
    pub bytes_read: Option<u64>,
    /// Audio blocks lost so far.
    pub audio_lost: Option<u64>,
}

/// The state the view model adds to a title.
#[derive(Debug, Clone, Default)]
pub(crate) struct PlayerExtra {
    pub volume: VolumeState,
    pub check: StreamCheck,
    /// Pause as soon as the rebuilt stream is loaded.
    pub pause_after_load: bool,
    /// The title's `OriginalLanguage`, for the "(Original)" audio tag.
    pub original_language: Option<String>,
}

impl PlayerExtra {
    pub(crate) fn sample(
        reading: StreamReading,
        now: f64,
        position: f64,
        running: bool,
        start_reported: bool,
        jump_open: bool,
    ) -> Sample {
        Sample {
            now,
            position,
            running,
            start_reported,
            is_file: reading.is_file,
            jump_open,
            pictures_shown: reading.pictures_shown,
            bytes_read: reading.bytes_read,
            audio_lost: reading.audio_lost,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mute_toggle_remembers_the_level() {
        let mut v = VolumeState::new(0.6);
        assert_eq!(v.toggle_mute(), 0);
        assert!(v.is_muted());
        assert_eq!(v.toggle_mute(), 60);
        assert!(!v.is_muted());
    }

    #[test]
    fn unmuting_from_a_zero_start_gives_one_percent() {
        let mut v = VolumeState::new(0.0);
        // Never above zero since the start: the remembered level is the default 1.0 (100 %).
        assert_eq!(v.toggle_mute(), 100);
        let mut w = VolumeState::new(0.4);
        w.set_percent(0);
        w.prior = 0.0;
        assert_eq!(w.toggle_mute(), 1);
    }

    #[test]
    fn steps_round_to_whole_percent_and_clamp() {
        let mut v = VolumeState::new(0.5);
        assert_eq!(v.step(0.05), 55);
        assert_eq!(v.step(-0.05), 50);
        assert_eq!(v.step(1.0), 100);
        assert_eq!(v.step(-2.0), 0);
        assert_eq!(v.wheel(0.123), 12);
        assert_eq!(v.wheel(0.5), 62);
    }

    #[test]
    fn the_slider_percent_is_clamped_and_ends_a_mute() {
        let mut v = VolumeState::new(0.5);
        v.toggle_mute();
        assert_eq!(v.set_percent(30), 30);
        assert!(!v.is_muted());
        assert_eq!(v.set_percent(250), 100);
        assert_eq!(v.set_percent(-5), 0);
    }

    #[test]
    fn end_time_is_now_plus_remaining() {
        let l = times_label(600.0, 3600.0, true, 1_000_000.0);
        assert_eq!(l, Some(TimesLabel::Ends { at: 1_003_000.0 }));
    }

    #[test]
    fn remaining_text_has_a_minus_and_stops_at_zero() {
        assert_eq!(
            times_label(600.0, 3600.0, false, 0.0),
            Some(TimesLabel::Remaining {
                text: "−50:00".to_owned()
            })
        );
        assert_eq!(
            times_label(3700.0, 3600.0, false, 0.0),
            Some(TimesLabel::Remaining {
                text: "−0:00".to_owned()
            })
        );
        assert_eq!(
            times_label(0.0, 7325.0, false, 0.0),
            Some(TimesLabel::Remaining {
                text: "−2:02:05".to_owned()
            })
        );
    }

    #[test]
    fn no_label_without_a_duration() {
        assert_eq!(times_label(5.0, 0.0, true, 0.0), None);
        assert_eq!(times_label(5.0, f64::NAN, false, 0.0), None);
    }

    // F-cast-04: the epoch saturates to i64::MAX, adding a zone offset to it must not overflow.
    #[test]
    fn clock_text_survives_hostile_numbers() {
        for epoch in [
            f64::NAN,
            f64::INFINITY,
            f64::NEG_INFINITY,
            1e30,
            -1e30,
            f64::MAX,
        ] {
            for offset in [0, 3600, -3600, i64::MAX, i64::MIN] {
                for hours in [true, false] {
                    assert!(!clock_text(epoch, offset, hours).is_empty());
                }
            }
        }
    }

    #[test]
    fn clock_text_follows_the_zone_and_the_hour_style() {
        // 2026-01-01 21:41:00 UTC.
        let epoch = 1_767_303_660.0;
        assert_eq!(clock_text(epoch, 3600, true), "22:41");
        assert_eq!(clock_text(epoch, 3600, false), "10:41 PM");
        assert_eq!(clock_text(epoch, 2 * 3600 + 19 * 60, true), "00:00");
        assert_eq!(clock_text(epoch, 2 * 3600 + 19 * 60, false), "12:00 AM");
        assert_eq!(clock_text(epoch, -21 * 3600, false), "12:41 AM");
        assert_eq!(clock_text(epoch - 9.0 * 3600.0, 0, false), "12:41 PM");
    }

    #[test]
    fn small_window_text_is_the_catalog_key() {
        assert_eq!(SMALL_WINDOW_TEXT, "Läuft im kleinen Fenster");
    }
}
