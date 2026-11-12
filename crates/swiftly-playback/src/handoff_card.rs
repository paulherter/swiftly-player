//! Port of `HandoffCard.swift` (JellyfinKit): "Continue watching here" as a card that grows
//! out of the badge.
//!
//! **Receiver:** tap on the badge; the page steps back, a card with the episode image grows
//! on a straight path from the badge to the middle, title and episode below it. While the
//! stream is not ready it hovers slightly, with a loading line if the wait is longer. Once
//! the first picture is there it zooms to the full picture; the video fades in underneath.
//!
//! **Sender:** the mirror image: the running picture stands still, shrinks to the card,
//! hovers briefly and flies out at the top; then the player closes.
//!
//! Position, size and opacity only, motion computed in advance. Springs as with the account
//! switch (`AccountSwitchCurve.spring`, `AccountSwitchCurve.swift:90`, closed form) with
//! momentum carried from phase to phase. Sizes in points, times in seconds from the tap
//! (receiver) or from the stop (sender).
//!
//! Swift default arguments (`since`, `bearing`, `jeSecond`) are explicit parameters here;
//! pass [`CARDS_START`], [`Direction::TOP`] and [`ANCHOR_POINTS_PER_SECOND`] for the defaults.

use std::f64::consts::PI;

/// A damped spring solved in closed form (`AccountSwitchCurve.spring`): response `r` (s),
/// damping `z`, initial velocity `v0` (per second).
fn spring(from: f64, to: f64, v0: f64, r: f64, z: f64, t: f64) -> f64 {
    if t <= 0.0 {
        return from;
    }
    let w = 2.0 * PI / r;
    let x0 = from - to;
    let x = if z < 1.0 {
        let wd = w * (1.0 - z * z).sqrt();
        (-z * w * t).exp() * (x0 * (wd * t).cos() + (v0 + z * w * x0) / wd * (wd * t).sin())
    } else {
        (x0 + (v0 + w * x0) * t) * (-w * t).exp()
    };
    to + x
}

// MARK: Dimensions

/// Card width at rest, corner, font sizes and distance to the line below
/// (`HandoffCard.Metrics`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Metrics {
    /// Card width at rest.
    pub width: f64,
    /// Corner radius at rest.
    pub corner: f64,
    /// Title font size.
    pub title: f64,
    /// Small (second line) font size.
    pub small: f64,
    /// Distance from the card to the lines below.
    pub spacing: f64,
}

/// iPhone metrics.
pub const IPHONE: Metrics = Metrics {
    width: 240.0,
    corner: 12.0,
    title: 17.0,
    small: 13.0,
    spacing: 12.0,
};
/// iPad metrics.
pub const IPAD: Metrics = Metrics {
    width: 320.0,
    corner: 14.0,
    title: 20.0,
    small: 15.0,
    spacing: 14.0,
};
/// TV metrics.
pub const TV: Metrics = Metrics {
    width: 600.0,
    corner: 24.0,
    title: 42.0,
    small: 30.0,
    spacing: 26.0,
};
/// Mac metrics.
pub const MAC: Metrics = Metrics {
    width: 320.0,
    corner: 12.0,
    title: 17.0,
    small: 13.0,
    spacing: 12.0,
};

/// Center and width of the card; the height is always 16:9 (`HandoffCard.Status`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Status {
    /// Center x.
    pub x: f64,
    /// Center y.
    pub y: f64,
    /// Width.
    pub width: f64,
}

impl Status {
    /// Builds a status.
    pub const fn new(x: f64, y: f64, width: f64) -> Self {
        Self { x, y, width }
    }

    /// Height, always 16:9 of the width.
    pub fn height(&self) -> f64 {
        self.width * 9.0 / 16.0
    }
}

/// The full picture: 16:9 fitted into the screen, centered. In portrait that is screen
/// width, which is exactly where the video sits in the player.
pub fn fullscreen(width: f64, height: f64) -> Status {
    Status::new(width / 2.0, height / 2.0, width.min(height * 16.0 / 9.0))
}

/// Where the card rests: horizontally centered, so far above the middle that the card and
/// the two lines below it together are centered.
pub fn idle_status(width: f64, height: f64, metrics: Metrics) -> Status {
    let b = metrics.width.min(width * 0.7);
    let rows = metrics.spacing + metrics.title * 1.2 + metrics.small * 1.2 + 6.0;
    Status::new(width / 2.0, height / 2.0 - rows / 2.0, b)
}

/// Top edge of the lines under a card in this position.
pub fn rows_top(l: Status, metrics: Metrics) -> f64 {
    l.y + l.height() / 2.0 + metrics.spacing * 0.6
}

/// The visible corner: at rest the metrics corner, towards the full picture down to zero,
/// and never more than 5.5 % of the width, so the small card at the badge does not become
/// a pill.
pub fn corner(l: Status, metrics: Metrics, full: Status) -> f64 {
    let extent_span = (full.width - metrics.width).max(1.0);
    let share = ((full.width - l.width) / extent_span).clamp(0.0, 1.0);
    (metrics.corner * share).min(l.width * 0.055)
}

// MARK: Curves

fn linear(t: f64, a: f64, b: f64) -> f64 {
    ((t - a) / (b - a)).clamp(0.0, 1.0)
}

fn smooth(u: f64) -> f64 {
    u * u * (3.0 - 2.0 * u)
}

// MARK: Receiver

/// The page steps back (opacity of the backdrop above it, linear): from.
pub const PAGE_FROM: f64 = 0.08;
/// The page steps back: until.
pub const PAGE_UNTIL: f64 = 0.28;
/// From here the card is there; it fades in over [`CARDS_SHOW`].
pub const CARDS_START: f64 = 0.1;
/// Fade-in duration of the card.
pub const CARDS_SHOW: f64 = 0.05;
/// The straight path out of the badge: response 0.55 s, damping 0.8 for position.
pub const TRANSITION_RESPONSE: f64 = 0.55;
/// Damping of the flight (a small overshoot as with the account switch).
pub const TRANSITION_DAMPING: f64 = 0.8;
/// Damping of the size during the flight.
pub const SIZES_DAMPING: f64 = 0.8;
/// Title and episode under the card: from.
pub const ROWS_FROM: f64 = 0.45;
/// Title and episode under the card: until.
pub const ROWS_UNTIL: f64 = 0.7;
/// Earliest zoom. If the picture is there earlier, the card waits until here; if it is
/// later, the card hovers.
pub const FLOAT: f64 = 0.7;
/// Hovering: this many points up and down.
pub const HOVER_TRAVEL: f64 = 1.8;
/// Hovering: one oscillation in this many seconds.
pub const HOVER_PERIOD: f64 = 1.8;
/// The loading line only appears if the picture is still missing at this time.
pub const LOADING_BAR_OUT: f64 = FLOAT + 0.05;
/// Fade-in of the loading line.
pub const LOADING_BAR_SHOW: f64 = 0.2;
/// One sweep of the loading line across the card width (seconds).
pub const LOADING_BAR_TICK: f64 = 1.0 / 0.9;
/// Zoom to the full picture: spring response (s).
pub const ZOOM_RESPONSE: f64 = 0.5;
/// Zoom to the full picture: damping, with the momentum the card currently has.
pub const ZOOM_DAMPING: f64 = 0.85;
/// After the zoom starts: the lines go away over this long.
pub const ROWS_OUT: f64 = 0.15;
/// Black behind the picture, fade duration.
pub const BLACK_DURATION: f64 = 0.3;
/// Stage fade-out begins (seconds after the zoom start).
pub const CARDS_OUT_FROM: f64 = 0.42;
/// Stage fade-out ends (seconds after the zoom start).
pub const CARDS_OUT_UNTIL: f64 = 0.72;
/// After that the stage is cleared.
pub const END: f64 = CARDS_OUT_UNTIL + 0.05;
/// The longest the card waits for the first picture, from the moment the player is up.
pub const AT_MOST_WAIT: f64 = 6.0;
/// With reduced motion: each fade this long.
pub const FADE: f64 = 0.2;
/// With reduced motion: the fade out.
pub const FADE_OUT: f64 = 0.3;

/// When the zoom happens if the first picture came at `ready` (from the tap).
pub fn zoom_start(ready: f64) -> f64 {
    FLOAT.max(ready)
}

/// The card in flight: center and width after `t` seconds, without hovering. Before
/// `since` it sits at the badge. `since` is [`CARDS_START`] for a normal flight; if the
/// screen rotates on the way, the card flies anew from where it is to the landscape resting
/// position.
pub fn transition(t: f64, from: Status, to: Status, since: f64) -> Status {
    let u = t - since;
    if u <= 0.0 {
        return from;
    }
    Status::new(
        spring(
            from.x,
            to.x,
            0.0,
            TRANSITION_RESPONSE,
            TRANSITION_DAMPING,
            u,
        ),
        spring(
            from.y,
            to.y,
            0.0,
            TRANSITION_RESPONSE,
            TRANSITION_DAMPING,
            u,
        ),
        spring(
            from.width,
            to.width,
            0.0,
            TRANSITION_RESPONSE,
            SIZES_DAMPING,
            u,
        ),
    )
}

/// Vertical offset while hovering.
pub fn hover_offset(t: f64) -> f64 {
    let since = FLOAT - 0.15;
    if t <= since {
        return 0.0;
    }
    // Faded in softly: the breathing starts without a kink.
    ((t - since) * 2.0 * PI / HOVER_PERIOD).sin()
        * HOVER_TRAVEL
        * smooth(linear(t, since, FLOAT + 0.4))
}

/// Flight plus hovering: how the card stands while the picture is missing.
pub fn wait(t: f64, from: Status, to: Status, since: f64) -> Status {
    let mut l = transition(t, from, to, since);
    l.y += hover_offset(t);
    l
}

/// How fast the card currently moves while waiting (per second, per axis): the momentum the
/// zoom takes over.
pub fn momentum(t: f64, from: Status, to: Status, since: f64) -> Status {
    let h = 1.0 / 240.0;
    let a = wait((t - h).max(0.0), from, to, since);
    let b = wait(t + h, from, to, since);
    let d = t + h - (t - h).max(0.0);
    Status::new((b.x - a.x) / d, (b.y - a.y) / d, (b.width - a.width) / d)
}

/// The zoom `z` seconds after its start, from the position and momentum the card had at
/// that moment.
pub fn zoom(z: f64, from: Status, v: Status, full: Status) -> Status {
    Status::new(
        spring(from.x, full.x, v.x, ZOOM_RESPONSE, ZOOM_DAMPING, z),
        spring(from.y, full.y, v.y, ZOOM_RESPONSE, ZOOM_DAMPING, z),
        spring(
            from.width,
            full.width,
            v.width,
            ZOOM_RESPONSE,
            ZOOM_DAMPING,
            z,
        ),
    )
}

/// Opacity of the card until the zoom.
pub fn cards_coverage(t: f64) -> f64 {
    linear(t, CARDS_START, CARDS_START + CARDS_SHOW)
}

/// Opacity of the backdrop above the page.
pub fn pages_coverage(t: f64) -> f64 {
    smooth(linear(t, PAGE_FROM, PAGE_UNTIL))
}

/// Opacity of the lines; `zoom_off` is the zoom start, if already known.
pub fn rows_coverage(t: f64, zoom_off: Option<f64>) -> f64 {
    let an = linear(t, ROWS_FROM, ROWS_UNTIL);
    match zoom_off {
        None => an,
        Some(z) => an * (1.0 - linear(t, z, z + ROWS_OUT)),
    }
}

/// Opacity of the whole stage after the zoom start `z`: fully visible first, then softly
/// out, the video stands underneath.
pub fn stage_coverage(to_zoom: f64) -> f64 {
    1.0 - smooth(linear(to_zoom, CARDS_OUT_FROM, CARDS_OUT_UNTIL))
}

/// Whether the loading line appears: only if the picture is missing at [`LOADING_BAR_OUT`].
pub fn load_line(ready: Option<f64>) -> bool {
    ready.is_none_or(|r| r > LOADING_BAR_OUT)
}

// MARK: Sender

/// The picture stands still, then starts to shrink.
pub const EXIT_START: f64 = 0.12;
/// Title and episode appear when the card is almost small: from.
pub const EXIT_ROWS_FROM: f64 = EXIT_START + 0.35;
/// Title and episode appear when the card is almost small: until.
pub const EXIT_ROWS_UNTIL: f64 = EXIT_START + 0.6;
/// Short hovering from here (faded in softly as with the receiver).
pub const EXIT_FLOAT_OFF: f64 = EXIT_START + 0.55;
/// Departure, with position and momentum from the hovering.
pub const DEPARTURE: f64 = EXIT_START + 1.1;
/// On departure the card shrinks further to this fraction.
pub const DEPARTURE_MASS: f64 = 0.6;
/// With reduced motion: picture off, then closed.
pub const EXIT_REDUCED_END: f64 = FADE_OUT + 0.1;

/// Where the card flies: to where the other device usually is. Ordered by size (Apple
/// TV/Android TV > Mac > iPad > iPhone/Android; Linux and Windows count as desk like the
/// Mac): if the target is larger, up, if it is smaller, down. Equal or unknown: up.
/// `from`, `to`: device names as in the handoff notice.
pub fn departure_post_top(from: &str, to: &str) -> bool {
    match (sizes_rank(from), sizes_rank(to)) {
        (Some(a), Some(b)) => b >= a,
        _ => true,
    }
}

fn sizes_rank(name: &str) -> Option<i32> {
    match name {
        // The Android version reports as "Android TV" or "Android" (phone).
        "Apple TV" | "Android TV" => Some(3),
        "Mac" | "Linux" | "Windows" => Some(2),
        "iPad" => Some(1),
        "iPhone" | "Android" => Some(0),
        _ => None,
    }
}

/// A direction on the screen, unit vector, y pointing down (`HandoffCard.Direction`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Direction {
    /// X component.
    pub x: f64,
    /// Y component.
    pub y: f64,
}

impl Direction {
    /// Towards the top edge.
    pub const TOP: Direction = Direction { x: 0.0, y: -1.0 };
    /// Towards the bottom edge.
    pub const BOTTOM: Direction = Direction { x: 0.0, y: 1.0 };

    /// Builds a direction.
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

/// How the interface is oriented (`UIInterfaceOrientation`): portrait, upside down,
/// landscape with the home button on the right or left.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UserInterface {
    /// Portrait.
    Up,
    /// Portrait upside down.
    UpsideDown,
    /// Landscape, home button right.
    LandscapeHomeRight,
    /// Landscape, home button left.
    LandscapeHomeLeft,
}

/// Below this (share of gravity in the glass plane) the device lies flat.
pub const FLAT_LIMIT: f64 = 0.35;

/// Where "physically up" lies on the screen, from gravity (device coordinates: x right, y
/// to the top edge, z out of the glass) and the interface orientation. If the device lies
/// flat (gravity almost only on z), the interface's own up applies. `to_top` false: the
/// opposite direction (towards the smaller device).
pub fn departure_direction(gx: f64, gy: f64, surface: UserInterface, to_top: bool) -> Direction {
    let length = (gx * gx + gy * gy).sqrt();
    if length < FLAT_LIMIT {
        return if to_top {
            Direction::TOP
        } else {
            Direction::BOTTOM
        };
    }
    // "Up" is against gravity; on a portrait screen y points down.
    let px = -gx / length;
    let py = gy / length;
    let r = match surface {
        UserInterface::Up => Direction::new(px, py),
        UserInterface::UpsideDown => Direction::new(-px, -py),
        UserInterface::LandscapeHomeRight => Direction::new(py, -px),
        UserInterface::LandscapeHomeLeft => Direction::new(-py, px),
    };
    if to_top {
        r
    } else {
        Direction::new(-r.x, -r.y)
    }
}

/// Where the card flies: along `bearing` until it is fully off the screen, plus half a card
/// height. The screen follows from the centered `full`.
pub fn departure_target(card: Status, full: Status, bearing: Direction) -> Status {
    let b = card.width * DEPARTURE_MASS;
    let half = (b / 2.0, b * 9.0 / 32.0);
    let screen = (full.x * 2.0, full.y * 2.0);
    let mut distance = f64::INFINITY;
    if bearing.x.abs() > 1e-6 {
        let margin = if bearing.x > 0.0 {
            screen.0 - card.x
        } else {
            card.x
        };
        distance = distance.min((margin + half.0) / bearing.x.abs());
    }
    if bearing.y.abs() > 1e-6 {
        let margin = if bearing.y > 0.0 {
            screen.1 - card.y
        } else {
            card.y
        };
        distance = distance.min((margin + half.1) / bearing.y.abs());
    }
    distance += card.height() / 2.0;
    Status::new(
        card.x + bearing.x * distance,
        card.y + bearing.y * distance,
        b,
    )
}

/// Vertical offset during the departer's short hovering.
fn exit_float(t: f64) -> f64 {
    hover_offset(t - EXIT_FLOAT_OFF + FLOAT - 0.15)
}

/// Shrinking and hovering, without departure.
fn exit_pre_departure(t: f64, full: Status, card: Status) -> Status {
    let u = t - EXIT_START;
    if u <= 0.0 {
        return full;
    }
    Status::new(
        spring(full.x, card.x, 0.0, ZOOM_RESPONSE, ZOOM_DAMPING, u),
        spring(full.y, card.y, 0.0, ZOOM_RESPONSE, ZOOM_DAMPING, u) + exit_float(t),
        spring(full.width, card.width, 0.0, ZOOM_RESPONSE, ZOOM_DAMPING, u),
    )
}

/// The outgoing picture after `t` seconds from the stop.
pub fn exit(t: f64, full: Status, card: Status, bearing: Direction) -> Status {
    if t <= DEPARTURE {
        return exit_pre_departure(t, full, card);
    }
    let start = exit_pre_departure(DEPARTURE, full, card);
    let h = 1.0 / 240.0;
    let prior = exit_pre_departure(DEPARTURE - h, full, card);
    let v = Status::new(
        (start.x - prior.x) / h,
        (start.y - prior.y) / h,
        (start.width - prior.width) / h,
    );
    let target = departure_target(card, full, bearing);
    let u = t - DEPARTURE;
    Status::new(
        spring(
            start.x,
            target.x,
            v.x,
            TRANSITION_RESPONSE,
            TRANSITION_DAMPING,
            u,
        ),
        spring(
            start.y,
            target.y,
            v.y,
            TRANSITION_RESPONSE,
            TRANSITION_DAMPING,
            u,
        ),
        spring(
            start.width,
            target.width,
            v.width,
            TRANSITION_RESPONSE,
            SIZES_DAMPING,
            u,
        ),
    )
}

/// Opacity of the lines under the outgoing card: they appear when it is small, leave on
/// departure.
pub fn exit_rows_coverage(t: f64) -> f64 {
    linear(t, EXIT_ROWS_FROM, EXIT_ROWS_UNTIL) * (1.0 - linear(t, DEPARTURE, DEPARTURE + ROWS_OUT))
}

/// When the card is fully out of the picture; then the player closes.
pub fn exit_out(full: Status, card: Status, bearing: Direction) -> f64 {
    let mut t = DEPARTURE;
    while t < DEPARTURE + 3.0 {
        let l = exit(t, full, card, bearing);
        let outside = l.y + l.height() / 2.0 < 0.0
            || l.y - l.height() / 2.0 > full.y * 2.0
            || l.x + l.width / 2.0 < 0.0
            || l.x - l.width / 2.0 > full.x * 2.0;
        if outside {
            return t;
        }
        t += 1.0 / 240.0;
    }
    t
}

// MARK: Keyframes

/// Default sample density of [`anchor_points`] (`jeSecond`).
pub const ANCHOR_POINTS_PER_SECOND: f64 = 120.0;

/// Keyframes for a keyframe animation: `steps + 1` evenly spaced values from `from` to
/// `until`, `per_second` steps per second (at least two steps).
pub fn anchor_points<T>(
    from: f64,
    until: f64,
    per_second: f64,
    value: impl Fn(f64) -> T,
) -> Vec<T> {
    let steps = (((until - from) * per_second).ceil().max(0.0) as usize).max(2);
    (0..=steps)
        .map(|i| value(from + (until - from) * i as f64 / steps as f64))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SCREEN: (f64, f64) = (390.0, 844.0);
    const EMBLEM: Status = Status::new(350.0, 70.0, 44.0);

    fn full() -> Status {
        fullscreen(SCREEN.0, SCREEN.1)
    }
    fn idle() -> Status {
        idle_status(SCREEN.0, SCREEN.1, IPHONE)
    }
    fn near(a: Direction, b: Direction) -> bool {
        (a.x - b.x).abs() < 1e-9 && (a.y - b.y).abs() < 1e-9
    }

    #[test]
    fn fullscreen_is_screen_wide_in_portrait_and_fitted_in_landscape() {
        assert_eq!(full().width, 390.0);
        assert!((full().height() - 219.375).abs() < 0.001);
        assert!((fullscreen(844.0, 390.0).width - 390.0 * 16.0 / 9.0).abs() < 1e-9);
        assert_eq!(fullscreen(1920.0, 1080.0).width, 1920.0);
    }

    #[test]
    fn idle_status_rests_centered_above_middle() {
        let idle = idle();
        assert_eq!(idle.x, 195.0);
        assert_eq!(idle.width, 240.0);
        assert!(idle.y < 422.0);
        let bottom = rows_top(idle, IPHONE) + 17.0 * 1.2 + 13.0 * 1.2;
        let top = idle.y - idle.height() / 2.0;
        assert!(((top + bottom) / 2.0 - 422.0).abs() < 8.0);
        assert_eq!(idle_status(300.0, 600.0, IPHONE).width, 210.0);
    }

    #[test]
    fn transition_starts_at_badge_and_settles() {
        let idle = idle();
        assert_eq!(transition(0.0, EMBLEM, idle, CARDS_START), EMBLEM);
        assert_eq!(transition(CARDS_START, EMBLEM, idle, CARDS_START), EMBLEM);
        let late = transition(1.4, EMBLEM, idle, CARDS_START);
        assert!((late.x - idle.x).abs() < 0.5);
        assert!((late.y - idle.y).abs() < 0.5);
        assert!((late.width - idle.width).abs() < 0.5);
        // Straight path: no arc, only a small settle.
        let mut widest = 0.0_f64;
        for i in 0..=300 {
            let l = transition(f64::from(i) / 200.0, EMBLEM, idle, CARDS_START);
            widest = widest.max(l.y - idle.y);
        }
        assert!(widest < (idle.y - EMBLEM.y) * 0.03);
    }

    #[test]
    fn hovering_starts_shortly_before_float_and_stays_small() {
        assert_eq!(hover_offset(0.5), 0.0);
        assert_eq!(hover_offset(FLOAT - 0.15), 0.0);
        for i in 0..=400 {
            assert!(hover_offset(0.5 + f64::from(i) / 100.0).abs() <= HOVER_TRAVEL + 1e-9);
        }
    }

    #[test]
    fn zoom_starts_at_float_at_the_earliest() {
        assert_eq!(zoom_start(0.3), 0.7);
        assert_eq!(zoom_start(1.9), 1.9);
    }

    #[test]
    fn zoom_ends_on_full_picture_with_small_overshoot() {
        let (full, idle) = (full(), idle());
        let start = wait(1.2, EMBLEM, idle, CARDS_START);
        let v = momentum(1.2, EMBLEM, idle, CARDS_START);
        assert_eq!(zoom(0.0, start, v, full), start);
        let fade = zoom(CARDS_OUT_FROM, start, v, full);
        assert!(fade.width > full.width * 0.9);
        let calm = zoom(1.5, start, v, full);
        assert!((calm.width - full.width).abs() < 0.5);
        for i in 0..=150 {
            assert!(zoom(f64::from(i) / 100.0, start, v, full).width <= full.width * 1.03);
        }
    }

    #[test]
    fn rotation_on_the_way_flies_anew_to_landscape() {
        let landscape = idle_status(844.0, 390.0, IPHONE);
        let now = transition(0.5, EMBLEM, idle(), CARDS_START);
        assert_eq!(transition(0.5, now, landscape, 0.5), now);
        let late = transition(2.0, now, landscape, 0.5);
        assert!((late.x - landscape.x).abs() < 0.5 && (late.y - landscape.y).abs() < 0.5);
    }

    #[test]
    fn zoom_takes_over_the_momentum_of_the_flight() {
        let (full, idle) = (full(), idle());
        let tz = zoom_start(0.3);
        let start = wait(tz, EMBLEM, idle, CARDS_START);
        let v = momentum(tz, EMBLEM, idle, CARDS_START);
        assert!(v.y.abs() > 1.0);
        let h = 1.0 / 240.0;
        let z = zoom(h, start, v, full);
        let vz = (z.y - start.y) / h;
        assert!((vz - v.y).abs() < 20.0_f64.max(v.y.abs() * 0.2));
    }

    #[test]
    fn corner_is_12_at_rest_0_at_full_and_never_a_pill() {
        let (full, idle) = (full(), idle());
        assert_eq!(corner(idle, IPHONE, full), 12.0);
        assert_eq!(corner(full, IPHONE, full), 0.0);
        assert!(corner(EMBLEM, IPHONE, full) <= 44.0 * 0.055);
    }

    #[test]
    fn rows_come_after_the_flight_and_leave_with_the_zoom() {
        assert_eq!(rows_coverage(0.3, None), 0.0);
        assert_eq!(rows_coverage(0.8, None), 1.0);
        assert_eq!(rows_coverage(1.0, Some(0.8)), 0.0);
        assert_eq!(stage_coverage(0.2), 1.0);
        assert_eq!(stage_coverage(CARDS_OUT_UNTIL), 0.0);
    }

    #[test]
    fn loading_line_only_if_picture_is_missing_at_threshold() {
        assert!(!load_line(Some(0.4)));
        assert!(load_line(Some(1.5)));
        assert!(load_line(None));
    }

    #[test]
    fn sender_is_the_mirror_image() {
        let landscape = fullscreen(844.0, 390.0);
        let card = idle_status(844.0, 390.0, IPHONE);
        let top = Direction::TOP;
        assert_eq!(exit(0.1, landscape, card, top), landscape);
        // Shrinking = zoom in reverse: after the same time the same fraction of the path.
        let u = 0.3;
        let since = exit(EXIT_START + u, landscape, card, top);
        let toward = zoom(u, card, Status::new(0.0, 0.0, 0.0), landscape);
        let share_off = (landscape.width - since.width) / (landscape.width - card.width);
        let fraction_to = (toward.width - card.width) / (landscape.width - card.width);
        assert!((share_off - fraction_to).abs() < 1e-9);
        // Before takeoff it rests (apart from hovering) at the rest position.
        let calm = exit(DEPARTURE, landscape, card, top);
        assert!((calm.width - card.width).abs() < 1.0);
        assert!((calm.y - card.y).abs() < HOVER_TRAVEL + 1.0);
        // No jump at takeoff.
        let after_that = exit(DEPARTURE + 1.0 / 240.0, landscape, card, top);
        assert!((after_that.y - calm.y).abs() < 3.0);
        // Then all the way out at the top, and the player closes only afterwards.
        let out = exit_out(landscape, card, top);
        assert!(out > DEPARTURE && out < DEPARTURE + 1.0);
        let l = exit(out, landscape, card, top);
        assert!(l.y + l.height() / 2.0 < 0.0);
        assert_eq!(exit_rows_coverage(DEPARTURE - 0.01), 1.0);
        assert_eq!(exit_rows_coverage(DEPARTURE + ROWS_OUT), 0.0);
    }

    #[test]
    fn departure_follows_device_size() {
        assert!(departure_post_top("iPhone", "Apple TV"));
        assert!(!departure_post_top("Apple TV", "iPhone"));
        assert!(!departure_post_top("Mac", "iPad"));
        assert!(departure_post_top("iPad", "Mac"));
        assert!(departure_post_top("iPhone", "iPhone"));
        assert!(departure_post_top("Apple TV", "Wohnzimmer"));
        // A desktop counts like the Mac.
        assert!(!departure_post_top("Linux", "iPhone"));
        assert!(departure_post_top("Windows", "Apple TV"));
        assert!(!departure_post_top("Apple TV", "Linux"));
        assert!(departure_post_top("Linux", "Mac"));
        assert!(departure_post_top("Android", "Android TV"));
        assert!(!departure_post_top("Android TV", "iPhone"));
        assert!(!departure_post_top("Mac", "Android"));
        // Downwards: all the way out at the bottom.
        let tv = fullscreen(1920.0, 1080.0);
        let card = idle_status(1920.0, 1080.0, TV);
        let out = exit_out(tv, card, Direction::BOTTOM);
        assert!(out > DEPARTURE && out < DEPARTURE + 1.0);
        let l = exit(out, tv, card, Direction::BOTTOM);
        assert!(l.y - l.height() / 2.0 > 1080.0);
    }

    #[test]
    fn physical_top_from_gravity() {
        use UserInterface::*;
        // Held upright, interface upright: up is up.
        assert!(near(
            departure_direction(0.0, -1.0, Up, true),
            Direction::TOP
        ));
        // Held upright, player still landscape: up is the left or right side.
        assert!(near(
            departure_direction(0.0, -1.0, LandscapeHomeRight, true),
            Direction::new(-1.0, 0.0)
        ));
        assert!(near(
            departure_direction(0.0, -1.0, LandscapeHomeLeft, true),
            Direction::new(1.0, 0.0)
        ));
        // Held in landscape: up is up.
        assert!(near(
            departure_direction(-1.0, 0.0, LandscapeHomeRight, true),
            Direction::TOP
        ));
        assert!(near(
            departure_direction(1.0, 0.0, LandscapeHomeLeft, true),
            Direction::TOP
        ));
        // To the smaller device: physically down.
        assert!(near(
            departure_direction(0.0, -1.0, Up, false),
            Direction::BOTTOM
        ));
        // Diagonal stays diagonal (unit vector).
        let s = departure_direction(-0.5, -0.5, Up, true);
        assert!((s.x * s.x + s.y * s.y - 1.0).abs() < 1e-9 && s.x > 0.0 && s.y < 0.0);
        // Flat on the table: the interface's up.
        assert_eq!(
            departure_direction(0.1, 0.1, LandscapeHomeRight, true),
            Direction::TOP
        );
        assert_eq!(departure_direction(0.1, 0.1, Up, false), Direction::BOTTOM);
        // Out sideways is also fully outside.
        let landscape = fullscreen(844.0, 390.0);
        let card = idle_status(844.0, 390.0, IPHONE);
        let left = Direction::new(-1.0, 0.0);
        let l = exit(exit_out(landscape, card, left), landscape, card, left);
        assert!(l.x + l.width / 2.0 < 0.0);
    }

    #[test]
    fn anchor_points_are_even_with_exact_ends() {
        let w = anchor_points(0.0, 1.0, ANCHOR_POINTS_PER_SECOND, |t| t);
        assert_eq!(w.len(), 121);
        assert!(w.first() == Some(&0.0) && w.last() == Some(&1.0));
    }
}
