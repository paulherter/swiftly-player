//! Port of EpisodesCard.swift (`EpisodeCard`).
//!
//! The next episode as a card at the bottom right and how it zooms into the picture: springs,
//! timings and sizes. All motion is critically damped springs from the current state.
//! Sizes are points, times seconds.

/// Without a credits section: this many seconds before the end.
pub const REMAINING_WINDOW: f64 = 30.0;

/// Slide in: natural frequency.
pub const APPEAR_OMEGA: f64 = 9.0;
/// Slide in starts 0.12 s after the credits start.
pub const APPEAR_LAG: f64 = 0.12;
/// Slide out (dismissed).
pub const DISTANCE_OMEGA: f64 = 12.0;
/// Zoom to the full picture.
pub const ZOOM_OMEGA: f64 = 10.0;

/// Ring and details below the card fade out over this many seconds.
pub const DETAILS_OUT: f64 = 0.15;
/// Only here is the new episode started: the card now covers the picture.
pub const SWAP: f64 = 0.6;
/// The thumbnail fades out over this many seconds once the first frame is there.
pub const IMAGE_FADE: f64 = 0.4;
/// The longest the card covers without a picture arriving (seconds).
pub const AT_MOST_COVERS: f64 = 5.0;

/// Slide-in offset from the right, points.
pub const OFFSET: f64 = 40.0;
/// Slide-in start scale.
pub const START_METRIC: f64 = 0.94;
/// TV: the focused card lifts by 6 %.
pub const FOCUS_METRIC: f64 = 1.06;
/// TV: a click presses in by 3.5 % ...
pub const CLICK_PRESS: f64 = 0.035;
/// ... for 0.3 s.
pub const CLICK_DURATION: f64 = 0.3;

/// At most this share of the safe width.
pub const AT_MOST_SHARE: f64 = 0.3;
/// Gap between the lines under the card and the bottom safe edge.
pub const BOTTOM_SPACING: f64 = 12.0;
/// Swiped this far (points) right or down, the card is gone ...
pub const SWIPE_AWAY: f64 = 70.0;
/// ... left and up it follows the finger only by a fifth.
pub const RESISTANCE: f64 = 0.2;

/// Sizes per platform: card width, corner, ring, gap to the line below, font sizes.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Metrics {
    /// Card width.
    pub width: f64,
    /// Corner radius.
    pub corner: f64,
    /// Ring diameter.
    pub ring: f64,
    /// Gap to the line below.
    pub spacing: f64,
    /// Small line font size.
    pub small: f64,
    /// Title font size.
    pub title: f64,
}

/// iPhone sizes.
pub const IPHONE: Metrics = Metrics {
    width: 240.0,
    corner: 12.0,
    ring: 52.0,
    spacing: 12.0,
    small: 12.0,
    title: 17.0,
};
/// TV sizes.
pub const TV: Metrics = Metrics {
    width: 600.0,
    corner: 24.0,
    ring: 130.0,
    spacing: 32.0,
    small: 30.0,
    title: 42.0,
};

/// Stiffness and damping of a critically damped spring with mass 1: `(omega^2, 2 omega)`.
pub fn spring(omega: f64) -> (f64, f64) {
    (omega * omega, 2.0 * omega)
}

/// How far such a spring is after `t` seconds, 0 to 1: `1 - e^(-wt) (1 + wt)`.
pub fn spring_travel(t: f64, omega: f64) -> f64 {
    if t <= 0.0 {
        0.0
    } else {
        1.0 - (-omega * t).exp() * (1.0 + omega * t)
    }
}

/// When the thumbnail starts fading out, measured from the start.
pub fn fade_off(image_since: f64) -> f64 {
    image_since.max(SWAP)
}

/// Should the card go now? `image_since` is `None` while the first frame of the new episode
/// is missing. (`EpisodesCard.swift:66-68`)
pub fn yields(since: f64, image_since: Option<f64>) -> bool {
    image_since.is_none() && since >= AT_MOST_COVERS
}

/// The card width for a given safe width. (`EpisodesCard.swift:100-102`)
pub fn width(m: &Metrics, safe_width: f64, large: bool) -> f64 {
    (m.width * if large { 1.25 } else { 1.0 }).min(safe_width * AT_MOST_SHARE)
}

/// The offset while dragging: free to the right and down, stiff left and up.
pub fn dragged(x: f64, y: f64) -> (f64, f64) {
    (
        if x > 0.0 { x } else { x * RESISTANCE },
        if y > 0.0 { y } else { y * RESISTANCE },
    )
}

/// Whether a swipe pushes the card away.
pub fn swiped_away(x: f64, y: f64, momentum_x: f64, momentum_y: f64) -> bool {
    x > SWIPE_AWAY
        || y > SWIPE_AWAY
        || momentum_x > 2.0 * SWIPE_AWAY
        || momentum_y > 2.0 * SWIPE_AWAY
}

/// A frame: x, y, width, height.
pub type Frame = (f64, f64, f64, f64);

/// The frame between card (`zoom` 0) and full picture (1). `whole` is (width, height).
pub fn frame_rect(card: Frame, whole: (f64, f64), zoom: f64) -> Frame {
    let l = |a: f64, b: f64| a + (b - a) * zoom;
    (
        l(card.0, 0.0),
        l(card.1, 0.0),
        l(card.2, whole.0),
        l(card.3, whole.1),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    // Swift: springIsCriticallyDamped
    #[test]
    fn spring_is_critically_damped() {
        let f = spring(10.0);
        assert!(f.0 == 100.0 && f.1 == 20.0);
        assert_eq!(spring_travel(0.0, 10.0), 0.0);
        // For the swap the card covers almost the whole image.
        assert!(spring_travel(SWAP, ZOOM_OMEGA) > 0.98);
        // No overshoot.
        assert!(spring_travel(3.0, 10.0) <= 1.0);
    }

    // Swift: fadeWaitsSwap
    #[test]
    fn fade_waits_swap() {
        assert_eq!(fade_off(0.2), SWAP);
        assert_eq!(fade_off(1.5), 1.5);
    }

    // Swift: frameGoesFromCardImage
    #[test]
    fn frame_goes_from_card_image() {
        let k = (548.0, 171.0, 240.0, 135.0);
        let a = frame_rect(k, (844.0, 390.0), 0.0);
        assert!(a.0 == 548.0 && a.2 == 240.0);
        let e = frame_rect(k, (844.0, 390.0), 1.0);
        assert!(e.0 == 0.0 && e.1 == 0.0 && e.2 == 844.0 && e.3 == 390.0);
    }

    // Swift: narrowPhonesGetSmallerCard
    #[test]
    fn narrow_phones_get_smaller_card() {
        assert_eq!(width(&IPHONE, 667.0, false), 200.1);
        assert_eq!(width(&IPHONE, 814.0, false), 240.0);
        assert_eq!(width(&IPHONE, 1366.0, true), 300.0);
    }

    // Swift: swipe
    #[test]
    fn swipe() {
        assert_eq!(dragged(-100.0, 50.0), (-20.0, 50.0));
        assert!(swiped_away(80.0, 0.0, 80.0, 0.0));
        assert!(swiped_away(30.0, 0.0, 200.0, 0.0));
        assert!(!swiped_away(30.0, 20.0, 60.0, 40.0));
    }

    // Swift: cardSoftWithoutImage
    #[test]
    fn card_soft_without_image() {
        assert!(!yields(SWAP, None));
        assert!(!yields(AT_MOST_COVERS - 0.1, None));
        assert!(yields(AT_MOST_COVERS, None));
        assert!(!yields(30.0, Some(1.2)));
        const { assert!(AT_MOST_COVERS > SWAP + IMAGE_FADE) };
    }
}
