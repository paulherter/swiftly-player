//! Port of EpisodesEnd.swift (`EpisodeEnd`).
//!
//! When an episode counts as "finished", and what happens then: the **button** (an offer) and
//! the **automatic advance** (an action) are different questions.

/// Below this runtime (seconds) nothing is checked.
pub const MIN_RUNTIME: f64 = 300.0;
/// From here an episode counts as nearly done: this many seconds before the end ...
pub const SECONDS_LEFT: f64 = 150.0;
/// ... or at this share of the runtime, whichever comes first.
pub const SHARE: f64 = 0.96;
/// How long after opening playback does not advance by itself (seconds).
pub const RAMP_UP_IDLE: f64 = 5.0;

/// Whether the "Next episode" button is offered. (`EpisodesEnd.swift:33-36`)
pub fn button_show(position: f64, duration: f64) -> bool {
    if duration <= MIN_RUNTIME {
        return false;
    }
    (duration - position) <= SECONDS_LEFT || (position / duration) >= SHARE
}

/// Is playback at the end of the file? (`EpisodesEnd.swift:56-58`)
pub fn at_end(position: f64, duration: f64) -> bool {
    duration > 60.0 && position >= duration - 1.0
}

/// Whether playback advances to the next episode by itself: not while the card counts down
/// (`card_counts`), not within [`RAMP_UP_IDLE`] seconds of opening, only for files longer
/// than a minute and at the end. (`EpisodesEnd.swift:70-77`)
pub fn advance(position: f64, duration: f64, since_open: f64, card_counts: bool) -> bool {
    // Swift guards are `sinceOpen > ramp` and `duration > 60`: NaN fails them.
    if card_counts
        || since_open.is_nan()
        || since_open <= RAMP_UP_IDLE
        || duration.is_nan()
        || duration <= 60.0
    {
        return false;
    }
    position >= duration - 1.0
}

#[cfg(test)]
mod tests {
    use super::*;

    // Swift: EpisodesEndTests.button
    #[test]
    fn button() {
        assert!(button_show(3500.0, 3600.0));
        assert!(!button_show(1800.0, 3600.0));
    }

    // Swift: short()
    #[test]
    fn short() {
        assert!(!button_show(200.0, 240.0));
    }

    // Swift: advance()
    #[test]
    fn advance_only_at_end() {
        assert!(!advance(3500.0, 3600.0, 600.0, false));
        assert!(advance(3599.5, 3600.0, 600.0, false));
        // The case with `:start-time`: no advance within the settling period.
        assert!(!advance(3721.0, 3721.0, 0.6, false));
        assert!(advance(3721.0, 3721.0, 6.0, false));
    }

    // Swift: EpisodesCardTests.endDoesNotSwitchPastCountdown (the `OfferingLayer` part is
    // not ported; the card counting is passed in as `true`).
    #[test]
    fn end_does_not_switch_past_countdown() {
        assert!(!advance(1500.0, 1500.0, 600.0, true));
        // Without a card (cancelled or none) as before.
        assert!(advance(1500.0, 1500.0, 600.0, false));
    }

    // Swift: EpisodesCardTests.atEndLimit
    #[test]
    fn at_end_limit() {
        assert!(at_end(1499.0, 1500.0));
        assert!(!at_end(1498.0, 1500.0));
    }
}
