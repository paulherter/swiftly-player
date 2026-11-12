//! Port of TimeAssumption.swift (a dependency of `PlaybackTick`; not on the requested list).
//!
//! When VLC's time value may be believed, and when not.
//!
//! **Deliberate difference:** Swift reads the wall clock (`Date()`) inside
//! [`image_present`] and [`position`]; here the current time is a parameter `now` (seconds on
//! the same clock as `since_start`), so the rules are testable. Callers pass the real clock,
//! which gives the Swift behaviour.

/// How close the player must be to the target for the seek to count as arrived (seconds).
pub const JUMP_ARRIVED: f64 = 2.0;
/// How long after opening a backward jump counts as setup flicker (seconds).
///
/// **The start's own deadline, not a shorter number (issue #43).** While the engine homes in on a
/// resume point it reports the time of the unseeked stream (0-based, then the old time); the start
/// seek is retried up to 20 s and the loading screen waits [`SETTLE_DEADLINE`]. A guard of 8 s let
/// the first low value after it through, the display fell to 0:00 and the server was told about a
/// position near zero. A real backward seek is not affected: it takes the jump path before this
/// guard is asked.
pub const FRESH_WINDOW: f64 = SETTLE_DEADLINE;
/// From when the loading screen goes away in any case (seconds).
pub const EMERGENCY_BRAKE: f64 = 12.0;
/// The same emergency brake while VLC is still homing in on the start position (seconds).
pub const SETTLE_DEADLINE: f64 = 25.0;
/// How far ahead of the wall clock the new episode's clock may be (seconds).
pub const SWITCH_PLAY_SPACE: f64 = 5.0;

/// Whether the video output belongs to the **current** media. (`TimeAssumption.swift:47-50`)
pub fn image_belongs_medium(video_output: bool, shown_images: u64, after_change: bool) -> bool {
    video_output && (!after_change || shown_images > 0)
}

/// Whether the loading screen may go away. (`TimeAssumption.swift:59-65`)
pub fn image_present(shows_image: bool, seeks_to_start: bool, since_start: f64, now: f64) -> bool {
    let since = now - since_start;
    // While homing in, the longer deadline applies.
    if seeks_to_start {
        return since > SETTLE_DEADLINE;
    }
    if since > EMERGENCY_BRAKE {
        return true;
    }
    shows_image
}

/// Which time the display adopts, or `None` if none: nothing under half a second, no jump
/// back by more than thirty seconds while freshly opened, and after an episode switch nothing
/// that cannot have been played yet. (`TimeAssumption.swift:86-95`)
pub fn position(
    reported: f64,
    until_from: f64,
    since_start: f64,
    after_change: bool,
    now: f64,
) -> Option<f64> {
    // Swift `guard reported > 0.5`: NaN fails the guard too.
    if reported.is_nan() || reported <= 0.5 {
        return None;
    }
    let since = now - since_start;
    let fresh_opened = since < FRESH_WINDOW;
    if after_change && since < SETTLE_DEADLINE && reported > since + SWITCH_PLAY_SPACE {
        return None;
    }
    let backward = reported < until_from - 30.0;
    if backward && fresh_opened {
        return None;
    }
    Some(reported)
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: f64 = 1_000_000.0;
    fn forward(seconds: f64) -> f64 {
        NOW - seconds
    }

    // Swift: TimeAssumptionTests.imagePresent
    #[test]
    fn image_present_at_once() {
        assert!(image_present(true, false, forward(1.0), NOW));
    }

    #[test]
    fn emergency_brake() {
        assert!(!image_present(false, false, forward(5.0), NOW));
        assert!(image_present(false, false, forward(13.0), NOW));
    }

    #[test]
    fn settle_outlasts_emergency_brake() {
        assert!(!image_present(true, true, forward(15.0), NOW));
    }

    #[test]
    fn settle_has_end() {
        assert!(image_present(true, true, forward(30.0), NOW));
    }

    #[test]
    fn jump_back() {
        assert_eq!(position(5.0, 1200.0, forward(2.0), false, NOW), None);
        // Issue #43: the old expectation (adopted at 20 s) was the bug; the guard holds for the whole start.
        assert_eq!(position(5.0, 1200.0, forward(20.0), false, NOW), None);
        assert_eq!(position(5.0, 1200.0, forward(30.0), false, NOW), Some(5.0));
    }

    /// Issue #43: engine times 0..30 s after a resume at 1053 s (the engine clock is 0-based after
    /// the start seek) never reach the display while the start is on.
    #[test]
    fn zero_based_engine_clock_never_reaches_the_display() {
        let resume = 1053.0;
        for since in [0.0, 2.0, 8.0, 9.0, 12.0, 20.0, 24.9] {
            for engine in [0.6, 5.0, 18.0, 30.0] {
                assert_eq!(
                    position(engine, resume, forward(since), false, NOW),
                    None,
                    "engine {engine} s, {since} s after the start"
                );
            }
        }
        // Near the target the engine's time is the display's time.
        assert_eq!(
            position(1054.0, resume, forward(3.0), false, NOW),
            Some(1054.0)
        );
    }
}
