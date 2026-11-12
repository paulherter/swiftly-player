//! Port of `AudioGuards.swift` (JellyfinKit, `AudioWatch`): when a route change may rebuild
//! the audio output. Two guards: only real device changes, and a grace period after opening.

/// Ignore route changes for this long after opening, in seconds. **Unmeasured**, a plausible
/// number, see the Swift note (AudioGuards.swift:32).
pub const RAMP_UP_IDLE: f64 = 5.0;

/// Whether this route change should rebuild the output (AudioGuards.swift:44).
///
/// `real_device_switch` is whether the reason was `newDeviceAvailable` or `override`, the
/// only two where someone really changed the destination (the caller decides). `plays_now`
/// is whether anything is playing at all. `since_takeover` is how long the player has held
/// the central controller, in seconds.
pub fn output_new_build_up(real_device_switch: bool, plays_now: bool, since_takeover: f64) -> bool {
    if !(real_device_switch && plays_now) {
        return false;
    }
    since_takeover > RAMP_UP_IDLE
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normal() {
        assert!(output_new_build_up(true, true, 30.0));
    }

    #[test]
    fn ramp_up() {
        assert!(!output_new_build_up(true, true, 4.9));
        assert!(output_new_build_up(true, true, 5.1));
    }

    #[test]
    fn no_switch() {
        assert!(!output_new_build_up(false, true, 30.0));
    }

    #[test]
    fn halted() {
        assert!(!output_new_build_up(true, false, 30.0));
    }
}
