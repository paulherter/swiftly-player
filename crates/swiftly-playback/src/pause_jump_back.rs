//! Port of `PauseJumpBack.swift` (JellyfinKit): after a long pause, a few seconds back,
//! without anyone noticing. Not in a SyncPlay group. Time is `f64` seconds on any consistent
//! clock (Swift used `Date`).

/// From a pause this long the position is set back: ten minutes (PauseJumpBack.swift:17).
pub const THRESHOLD: f64 = 600.0;

/// By this much: five seconds (PauseJumpBack.swift:21).
pub const RANGE: f64 = 5.0;

/// Where to jump before playing on, or `None` if not (PauseJumpBack.swift:31).
///
/// `position` is where it stopped, `paused_since` since when it has been stopped (`None`
/// means it was not stopped), `now` the moment of resuming, `in_group` whether watching
/// together right now.
pub fn target(position: f64, paused_since: Option<f64>, now: f64, in_group: bool) -> Option<f64> {
    if in_group {
        return None;
    }
    let paused_since = paused_since?;
    if !(position.is_finite() && position > 0.0) {
        return None;
    }
    if now - paused_since <= THRESHOLD {
        return None;
    }
    Some((position - RANGE).max(0.0))
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: f64 = 1_000_000.0;

    #[test]
    fn short_pause_stays_state() {
        let since = NOW - THRESHOLD;
        assert_eq!(target(600.0, Some(since), NOW, false), None);
    }

    #[test]
    fn long_pause_sets_back() {
        let since = NOW - THRESHOLD - 1.0;
        assert_eq!(target(600.0, Some(since), NOW, false), Some(600.0 - RANGE));
    }

    #[test]
    fn not_pre_start() {
        let since = NOW - 3600.0;
        assert_eq!(target(2.0, Some(since), NOW, false), Some(0.0));
        assert_eq!(target(0.0, Some(since), NOW, false), None);
        assert_eq!(target(f64::NAN, Some(since), NOW, false), None);
    }

    #[test]
    fn in_group_never() {
        let since = NOW - 3600.0;
        assert_eq!(target(600.0, Some(since), NOW, true), None);
    }

    #[test]
    fn without_pause_never() {
        assert_eq!(target(600.0, None, NOW, false), None);
    }
}
