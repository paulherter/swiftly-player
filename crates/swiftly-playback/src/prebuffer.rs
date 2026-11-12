//! Port of the pure rules of `Prebuffer.swift` (JellyfinKit): prepare the next episode before
//! it is needed. Frugal: only near the end, once per episode, only over a free network, not
//! for downloaded episodes. The network fetch (`startRequest`) is I/O and not ported; the
//! pieces it needs (size, `Range` header value) are here. Time is `f64` seconds.

use swiftly_model::DeliveryMethod;
use swiftly_rules::episodes_end::MIN_RUNTIME;

/// Preparation starts at this much remaining time: three minutes (Prebuffer.swift:20).
pub const SECONDS_LEFT: f64 = 180.0;

/// This much of the start of the file is preloaded: 4 MiB (Prebuffer.swift:24).
pub const INITIAL_BYTES: usize = 4 * 1024 * 1024;

/// How long a prepared plan is valid, in seconds (Prebuffer.swift:28).
pub const LIFETIME: f64 = 600.0;

/// Whether to prepare now (Prebuffer.swift:36).
///
/// `credits_from` is where the credits section begins, if the server knows one; from there
/// the episode also counts as almost done. `network_favorable` means Wi-Fi or cable,
/// without data saver.
pub fn now(
    position: f64,
    duration: f64,
    credits_from: Option<f64>,
    network_favorable: bool,
) -> bool {
    if !network_favorable {
        return false;
    }
    if !(duration > MIN_RUNTIME && position.is_finite() && position > 0.0) {
        return false;
    }
    if duration - position <= SECONDS_LEFT {
        return true;
    }
    if let Some(credits_from) = credits_from
        && credits_from > 0.0
        && position >= credits_from
    {
        return true;
    }
    false
}

/// Whether a prepared plan is still used at the switch (Prebuffer.swift:46).
pub fn fresh_value(prepared: f64, now: f64) -> bool {
    now - prepared < LIFETIME
}

/// Whether the start of the file is preloaded: only over `http`/`https`, not for a file on
/// the device, and only for direct play, because a transcode URL would trigger a transcode on
/// the server that may never be needed (Prebuffer.swift:53).
///
/// `address` is the URL as text; its scheme is compared case-insensitively. Text without a
/// scheme (a bare path) counts as not loadable.
pub fn start_load(address: &str, method: DeliveryMethod) -> bool {
    let Some(scheme) = url_scheme(address) else {
        return false;
    };
    if !(scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https")) {
        return false;
    }
    method == DeliveryMethod::DirectPlay
}

/// The value of the `Range` header for the start request: `bytes=0-4194303`
/// (Prebuffer.swift:66).
pub fn range_header() -> String {
    format!("bytes=0-{}", INITIAL_BYTES - 1)
}

/// The scheme of a URL (RFC 3986: a letter, then letters, digits, `+`, `-`, `.`, then `:`).
fn url_scheme(address: &str) -> Option<&str> {
    let (scheme, _) = address.split_once(':')?;
    let mut chars = scheme.chars();
    let first = chars.next()?;
    let valid = first.is_ascii_alphabetic()
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
    valid.then_some(scheme)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_against_end() {
        assert!(!now(1000.0, 2600.0, None, true));
        assert!(now(2600.0 - SECONDS_LEFT, 2600.0, None, true));
    }

    #[test]
    fn off_credits() {
        assert!(now(2300.0, 2600.0, Some(2290.0), true));
        assert!(!now(2280.0, 2600.0, Some(2290.0), true));
    }

    #[test]
    fn not_over_expensive_network() {
        assert!(!now(2550.0, 2600.0, None, false));
    }

    #[test]
    fn not_short_titles() {
        assert!(!now(200.0, 240.0, None, true));
        assert!(!now(f64::NAN, 2600.0, None, true));
    }

    #[test]
    fn plan_expires() {
        let t = 1000.0;
        assert!(fresh_value(t, t + 60.0));
        assert!(!fresh_value(t, t + LIFETIME));
    }

    #[test]
    fn start_only_direct_play_over_network() {
        let network = "https://server.example/Videos/1/stream.mkv?static=true";
        assert!(start_load(network, DeliveryMethod::DirectPlay));
        assert!(!start_load(network, DeliveryMethod::Transcode));
        assert!(!start_load("file:///tmp/a.mkv", DeliveryMethod::DirectPlay));
    }

    #[test]
    fn range_header_covers_initial_bytes() {
        assert_eq!(range_header(), "bytes=0-4194303");
    }
}
