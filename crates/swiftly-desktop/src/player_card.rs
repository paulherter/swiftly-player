//! Motion and geometry of the next-episode card of the desktop player (`EpisodeCardsView.swift`, `PlayerScreen.swift:1157`).
//!
//! The Swift card moves on critically damped springs: appearing (omega 9, after a 0.12 s delay), leaving (omega 12) and
//! zooming (omega 10). A critically damped spring from 0 to 1 is `1 - (1 + w t) e^(-w t)`, so every value is a pure
//! function of the time since its start and the screen only keeps the start times. Under Reduce Motion the card fades
//! linearly over 0.14 s and neither scales nor moves.

use std::sync::{Arc, Mutex, PoisonError};
use swiftly_layout::Rect;
use swiftly_ui::{Cx, ImageId, ImageSlot};

/// Spring frequency of the card appearing.
pub const OMEGA_APPEAR: f64 = 9.0;
/// Seconds the card waits before it appears.
pub const DELAY_APPEAR: f64 = 0.12;
/// Spring frequency of the card leaving (and of the drag springing back).
pub const OMEGA_LEAVE: f64 = 12.0;
/// Spring frequency of the zoom on a click.
pub const OMEGA_ZOOM: f64 = 10.0;
/// Scale the card starts from.
pub const START_SCALE: f32 = 0.94;
/// Points the card starts to the right.
pub const START_X: f32 = 40.0;
/// A drag farther than this (points) dismisses the card.
pub const DRAG_DISMISS: f32 = 70.0;
/// Movement below this (points) is a click.
pub const CLICK_SLOP: f32 = 6.0;
/// Seconds of the countdown, and of the window the card may be up.
pub const COUNTDOWN: f64 = 7.0;
/// Seconds before the end the card may show.
pub const WINDOW: f64 = 30.0;
/// Diameter of the close button and its hit box.
pub const X_SIZE: f32 = 24.0;
/// Hit box of the close button.
pub const X_HIT: f32 = 32.0;
/// Points the lines travel while the details fade (+6 y).
pub const DETAILS_RISE: f32 = 6.0;
/// Seconds the details stay away while the card swaps to the next episode.
pub const SWAP_SECONDS: f64 = 0.6;
/// Seconds the picture fades in once it has arrived (the catalogue's `CardImage`).
pub const IMAGE_FADE: f64 = 0.4;
/// Scale of the ring while the pointer rests on the card.
pub const RING_HOVER: f32 = 1.06;

/// The curve of every card tween, in one place: how far catalogue curve `id` has come (0 to 1) `t` seconds after its
/// start, or the Reduce Motion fade (`Reduced`, linear 0.14 s) when `reduce`. Details use `CardDetailsOut`, the ring
/// hover `Float`, the picture `CardImage`.
pub fn tween(id: swiftly_motion::catalogue::Id, t: f64, reduce: bool) -> f64 {
    use swiftly_motion::catalogue::Id;
    let id = if reduce { Id::Reduced } else { id };
    id.curve().progress(t.max(0.0))
}

/// Critically damped spring from 0 to 1 after `t` seconds.
/// The three card springs are the catalogue's `CardAppear` (omega 9), `CardZoom` (10) and `CardDistance` (12); any other
/// omega is the same closed form.
pub fn critical(omega: f64, t: f64) -> f64 {
    use swiftly_motion::catalogue::Id;
    if t <= 0.0 {
        return 0.0;
    }
    let id = if omega == OMEGA_APPEAR {
        Some(Id::CardAppear)
    } else if omega == OMEGA_ZOOM {
        Some(Id::CardZoom)
    } else if omega == OMEGA_LEAVE {
        Some(Id::CardDistance)
    } else {
        None
    };
    match id {
        Some(id) => id.curve().progress(t),
        None => 1.0 - (1.0 + omega * t) * (-omega * t).exp(),
    }
}

/// What the view needs to draw the card at one moment.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CardLook {
    /// The card is drawn (appearing, there or leaving).
    pub shown: bool,
    /// 0...1.
    pub opacity: f32,
    /// Scale of the whole card.
    pub scale: f32,
    /// Offset to the right in points.
    pub dx: f32,
    /// 0 (resting size) ... 1 (zoomed).
    pub zoom: f32,
    /// Offset of the drag in points.
    pub drag: (f32, f32),
    /// 0...1: the ring, the lines and the close button (they fade after the card, `easeOut 0.15`).
    pub details: f32,
    /// Scale of the ring (1 ... [`RING_HOVER`]).
    pub ring: f32,
}

/// The start times that make the card's look.
#[derive(Clone, Copy, Debug, Default)]
pub struct CardMotion {
    wanted: bool,
    since: f64,
    /// Appear level (0...1) at `since`.
    level0: f64,
    zoomed: bool,
    zoom_since: f64,
    zoom0: f64,
    drag: (f32, f32),
    dragging: bool,
    released: f64,
    /// Details: the level at `details_since`, where it goes, and until when a swap keeps them away.
    details0: f64,
    details_on: bool,
    details_since: f64,
    swap_until: f64,
    hover: bool,
    hover0: f64,
    hover_since: f64,
}

impl CardMotion {
    fn level(&self, now: f64, reduce: bool) -> f64 {
        let t = now - self.since;
        if reduce {
            let k = tween(swiftly_motion::catalogue::Id::Reduced, t, true);
            return if self.wanted {
                self.level0 + (1.0 - self.level0) * k
            } else {
                self.level0 * (1.0 - k)
            };
        }
        if self.wanted {
            self.level0 + (1.0 - self.level0) * critical(OMEGA_APPEAR, t - DELAY_APPEAR)
        } else {
            self.level0 * (1.0 - critical(OMEGA_LEAVE, t))
        }
    }

    /// Tells whether the VM wants the card up; starts the matching spring on a change.
    pub fn update(&mut self, wanted: bool, now: f64, reduce: bool) {
        if wanted == self.wanted {
            return;
        }
        self.level0 = self.level(now, reduce);
        self.set_details(wanted, now, reduce);
        self.wanted = wanted;
        self.since = now;
        if !wanted {
            self.zoomed = false;
            self.zoom0 = 0.0;
            self.drag = (0.0, 0.0);
            self.dragging = false;
        }
    }

    fn fade(&self, t: f64, reduce: bool) -> f64 {
        tween(swiftly_motion::catalogue::Id::CardDetailsOut, t, reduce)
    }

    /// Details level at `now`: a tween from `details0` to the target; a swap first pulls them away, then back.
    fn details(&self, now: f64, reduce: bool) -> f64 {
        let k = |t0: f64, t: f64| t - t0;
        if self.swap_until > self.details_since && self.details_on {
            let gone = self.details0
                * (1.0 - self.fade(k(self.details_since, now.min(self.swap_until)), reduce));
            if now < self.swap_until {
                return gone;
            }
            return gone + (1.0 - gone) * self.fade(k(self.swap_until, now), reduce);
        }
        let to = if self.details_on { 1.0 } else { 0.0 };
        self.details0 + (to - self.details0) * self.fade(k(self.details_since, now), reduce)
    }

    /// Fades the details in or out (the ring, the lines and the close button).
    pub fn set_details(&mut self, on: bool, now: f64, reduce: bool) {
        self.details0 = self.details(now, reduce);
        self.details_on = on;
        self.details_since = now;
        self.swap_until = 0.0;
    }

    /// The card swaps to the next episode: the details go for [`SWAP_SECONDS`] and come back.
    pub fn begin_swap(&mut self, now: f64, reduce: bool) {
        self.details0 = self.details(now, reduce);
        self.details_on = true;
        self.details_since = now;
        self.swap_until = now + SWAP_SECONDS;
    }

    /// The pointer rests on the card (not while zoomed): the ring grows to [`RING_HOVER`].
    pub fn set_hover(&mut self, on: bool, now: f64, reduce: bool) {
        if on == self.hover {
            return;
        }
        self.hover0 = self.hover_level(now, reduce);
        self.hover = on;
        self.hover_since = now;
    }

    fn hover_level(&self, now: f64, reduce: bool) -> f64 {
        let to = if self.hover && !reduce { 1.0 } else { 0.0 };
        self.hover0
            + (to - self.hover0)
                * tween(
                    swiftly_motion::catalogue::Id::Float,
                    now - self.hover_since,
                    false,
                )
    }

    /// Zoom value 0...1 at `now`.
    fn zoom(&self, now: f64, reduce: bool) -> f64 {
        let to = if self.zoomed { 1.0 } else { 0.0 };
        if reduce {
            return to;
        }
        self.zoom0 + (to - self.zoom0) * critical(OMEGA_ZOOM, now - self.zoom_since)
    }

    /// A click on the card zooms it in, the next one out.
    pub fn toggle_zoom(&mut self, now: f64, reduce: bool) {
        self.zoom0 = self.zoom(now, reduce);
        self.zoomed = !self.zoomed;
        self.zoom_since = now;
    }

    /// Whether the card is zoomed in.
    pub fn zoomed(&self) -> bool {
        self.zoomed
    }

    /// The drag follows the pointer.
    pub fn drag_to(&mut self, dx: f32, dy: f32) {
        self.dragging = true;
        self.drag = (dx, dy);
    }

    /// The pointer lets go below the dismiss distance: the card springs back.
    pub fn release(&mut self, now: f64) {
        self.dragging = false;
        self.released = now;
    }

    /// Whether anything still moves (the screen keeps asking for frames).
    pub fn moving(&self, now: f64) -> bool {
        let t = now - self.since;
        let settling = if self.wanted {
            t < DELAY_APPEAR + 1.0
        } else {
            t < 1.0 && self.level0 > 0.0
        };
        settling
            || now - self.details_since < SWAP_SECONDS + 0.25
            || now < self.swap_until
            || now - self.hover_since < 0.15
            || now - self.zoom_since < 1.0
            || (!self.dragging && self.drag != (0.0, 0.0) && now - self.released < 1.0)
    }

    /// The look at `now`.
    pub fn look(&self, now: f64, reduce: bool) -> CardLook {
        let level = self.level(now, reduce).clamp(0.0, 1.0);
        let shown = self.wanted || level > 0.004;
        let k = if reduce { 0.0 } else { 1.0 - level as f32 };
        let drag = if self.dragging {
            self.drag
        } else {
            let back = 1.0 - critical(OMEGA_LEAVE, now - self.released) as f32;
            (self.drag.0 * back, self.drag.1 * back)
        };
        CardLook {
            shown,
            opacity: level as f32,
            scale: if reduce {
                1.0
            } else {
                START_SCALE + (1.0 - START_SCALE) * level as f32
            },
            dx: START_X * k,
            zoom: self.zoom(now, reduce) as f32,
            drag,
            details: self.details(now, reduce).clamp(0.0, 1.0) as f32,
            ring: 1.0 + (RING_HOVER - 1.0) * self.hover_level(now, reduce) as f32,
        }
    }
}

/// Fetches the picture of the next episode (raw image bytes); blocks, runs on a worker thread. `None` = placeholder stays.
pub type StillSource = Arc<dyn Fn() -> Option<Vec<u8>> + Send + Sync>;

enum Fetch {
    Idle,
    Loading,
    Failed,
    Ready(u32, u32, Vec<u8>),
}

/// The episode picture of the card, through the same path as the trickplay strip: fetched off-thread, decoded once, written
/// into one reserved region of the image page. It fades in over [`IMAGE_FADE`] after it has arrived; until then the card
/// shows its gradient.
pub struct CardStill {
    source: StillSource,
    fetch: Arc<Mutex<Fetch>>,
    slot: Option<ImageSlot>,
    arrived: Option<f64>,
}

impl CardStill {
    /// For a source; nothing is fetched before the first [`poll`](Self::poll).
    pub fn new(source: StillSource) -> CardStill {
        CardStill {
            source,
            fetch: Arc::new(Mutex::new(Fetch::Idle)),
            slot: None,
            arrived: None,
        }
    }

    /// The image and its opacity at `now` (seconds), once it has arrived.
    pub fn poll(&mut self, cx: &Cx, now: f64, reduce: bool) -> Option<(ImageId, f32)> {
        {
            let mut f = self.fetch.lock().unwrap_or_else(PoisonError::into_inner);
            if matches!(*f, Fetch::Idle) {
                *f = Fetch::Loading;
                let (state, source) = (Arc::clone(&self.fetch), Arc::clone(&self.source));
                std::thread::spawn(move || {
                    let done = source()
                        .and_then(|b| swiftly_images::decode::decode(&b, 0).ok())
                        .map_or(Fetch::Failed, |d| Fetch::Ready(d.width, d.height, d.rgba));
                    *state.lock().unwrap_or_else(PoisonError::into_inner) = done;
                });
            }
            if self.arrived.is_none()
                && let Fetch::Ready(w, h, px) = &*f
            {
                let mut images = cx.images.borrow_mut();
                self.slot = images.reserve(*w, *h);
                if let Some(s) = &self.slot
                    && images.rewrite(s, *w, *h, px)
                {
                    self.arrived = Some(now);
                }
            }
        }
        let at = self.arrived?;
        let k = tween(swiftly_motion::catalogue::Id::CardImage, now - at, reduce);
        self.slot.map(|s| (s.id, k as f32))
    }

    /// Whether the picture is still fading in or on its way.
    pub fn moving(&self, now: f64) -> bool {
        match self.arrived {
            Some(at) => now - at < IMAGE_FADE,
            None => matches!(
                *self.fetch.lock().unwrap_or_else(PoisonError::into_inner),
                Fetch::Loading
            ),
        }
    }
}

/// The card's rectangle in the window: bottom right, 16:9, at most 30 % of the width (`EC:22-205`); zoomed it grows to
/// the 30 %. `edge` is the right margin, `bottom` the distance from the bottom edge.
pub fn card_rect(win_w: f32, win_h: f32, edge: f32, bottom: f32, look: &CardLook) -> Rect {
    let rest = (win_w * 0.22).min(340.0);
    let big = (win_w * 0.30).min(440.0);
    let w = rest + (big - rest) * look.zoom;
    let h = w * 9.0 / 16.0;
    Rect::new(
        win_w - edge - w + look.dx + look.drag.0,
        win_h - bottom - h + look.drag.1,
        w,
        h,
    )
}

/// The close button's hit box inside the card (24 pt disc, 10 pt in from the top right corner, 32 pt to hit).
pub fn x_rect(card: Rect) -> Rect {
    let (cx, cy) = (
        card.x + card.w - 10.0 - X_SIZE / 2.0,
        card.y + 10.0 + X_SIZE / 2.0,
    );
    Rect::new(cx - X_HIT / 2.0, cy - X_HIT / 2.0, X_HIT, X_HIT)
}

/// Whether a point lies in a rectangle.
pub fn inside(r: Rect, x: f32, y: f32) -> bool {
    x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h
}

/// Scale of a skip glyph `t` seconds after a seek: a bounce that dips and returns, speed 1.7 (`PS:1826`).
pub fn bounce(t: f64) -> f32 {
    let d = 0.6 / 1.7;
    if !(0.0..d).contains(&t) {
        return 1.0;
    }
    1.0 - 0.15 * (std::f64::consts::PI * t / d).sin() as f32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spring_is_monotone_and_settles() {
        let mut last = 0.0;
        for i in 1..40 {
            let v = critical(9.0, f64::from(i) * 0.05);
            assert!(v >= last && v <= 1.0);
            last = v;
        }
        assert!(critical(9.0, 1.5) > 0.999);
        assert_eq!(critical(9.0, -1.0), 0.0);
    }

    #[test]
    fn appears_after_the_delay_and_leaves_from_where_it_is() {
        let mut m = CardMotion::default();
        m.update(true, 10.0, false);
        assert_eq!(m.look(10.1, false).opacity, 0.0);
        assert!(m.look(10.5, false).opacity > 0.3);
        let l = m.look(12.0, false);
        assert!(l.opacity > 0.999 && (l.scale - 1.0).abs() < 0.001 && l.dx < 0.1);
        m.update(false, 12.0, false);
        assert!(m.look(12.1, false).opacity < 1.0);
        assert!(!m.look(14.0, false).shown);
    }

    #[test]
    fn reduce_motion_fades_linear_without_scale() {
        let mut m = CardMotion::default();
        m.update(true, 0.0, true);
        let l = m.look(0.07, true);
        assert!((l.opacity - 0.5).abs() < 0.01 && l.scale == 1.0 && l.dx == 0.0);
    }

    #[test]
    fn zoom_and_geometry() {
        let mut m = CardMotion::default();
        m.update(true, 0.0, false);
        m.toggle_zoom(3.0, false);
        let z = m.look(5.0, false);
        assert!(z.zoom > 0.99);
        let r = card_rect(1280.0, 800.0, 28.0, 76.0, &z);
        assert!(r.w <= 1280.0 * 0.30 + 0.01 && (r.h - r.w * 9.0 / 16.0).abs() < 0.01);
        let r0 = card_rect(1280.0, 800.0, 28.0, 76.0, &CardLook::default());
        assert!(r0.w < r.w);
        let x = x_rect(r0);
        assert!(inside(r0, x.x + 1.0, x.y + 1.0));
    }

    #[test]
    fn bounce_dips_and_returns() {
        assert!(bounce(0.1) < 1.0);
        assert_eq!(bounce(1.0), 1.0);
        assert_eq!(bounce(-1.0), 1.0);
    }

    #[test]
    fn details_fade_after_the_card_and_hold_back_in_a_swap() {
        let mut m = CardMotion::default();
        m.update(true, 10.0, false);
        assert!(m.look(10.0, false).details < 0.01);
        let mid = m.look(10.07, false).details;
        assert!(mid > 0.3 && mid < 1.0, "easeOut 0.15 under way: {mid}");
        assert!(m.look(10.3, false).details > 0.999);
        m.begin_swap(11.0, false);
        assert!(m.look(11.3, false).details < 0.01, "gone while swapping");
        assert!(m.look(11.7, false).details > 0.3, "back after 0.6 s");
        assert!(m.look(12.5, false).details > 0.999);
    }

    #[test]
    fn ring_grows_on_hover_and_not_with_reduce_motion() {
        let mut m = CardMotion::default();
        m.update(true, 0.0, false);
        m.set_hover(true, 5.0, false);
        assert!(m.look(5.0, false).ring < 1.001);
        assert!((m.look(5.5, false).ring - RING_HOVER).abs() < 0.001);
        m.set_hover(false, 6.0, false);
        assert!(m.look(7.0, false).ring < 1.001);
        let mut r = CardMotion::default();
        r.set_hover(true, 0.0, true);
        assert!(r.look(1.0, true).ring < 1.001);
    }

    #[test]
    fn the_picture_curve_reaches_full_in_0_4_s() {
        use swiftly_motion::catalogue::Id;
        assert!(
            tween(Id::CardImage, 0.0, false) < 0.001
                && tween(Id::CardImage, 0.2, false) > 0.4
                && tween(Id::CardImage, IMAGE_FADE, false) > 0.999
        );
        assert!(
            tween(Id::CardImage, 0.1, false) < tween(Id::CardImage, 0.3, false),
            "easeInOut starts slowly"
        );
        assert!(
            tween(Id::CardImage, 0.07, true) > 0.45 && tween(Id::CardImage, 0.14, true) > 0.999,
            "Reduce Motion: linear 0.14"
        );
    }
}
