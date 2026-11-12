//! The thin overlay scroll bar of vertical scroll views (Mac style): it shows while the view scrolls or while the
//! pointer is near the right edge, fades out a second after the last movement, and its thumb can be dragged with the
//! mouse, a touchpad or a finger. A click in the track pages. Colours come from the design tokens.

use swiftly_design::tokens::colour;
use swiftly_layout::Rect;
use swiftly_motion::ScrollMetrics;
use swiftly_render::{Color, DrawList};

/// Thumb width at rest, points.
pub const WIDTH: f32 = 5.0;
/// Thumb and track width under the pointer or a drag.
pub const WIDTH_HOT: f32 = 9.0;
/// Gap between the bar and the right edge of the view.
pub const INSET: f32 = 2.0;
/// Width of the strip along the right edge where the pointer wakes the bar and a press grabs it.
pub const ZONE: f32 = 18.0;
/// Shortest thumb.
pub const MIN_THUMB: f32 = 28.0;
/// The bar stays this long after the last movement, ms.
pub const LINGER_MS: f64 = 1000.0;
/// Then it fades out over this long, ms.
pub const FADE_MS: f64 = 240.0;

/// Per scroll view bar state (lives in the node state).
#[derive(Clone, Copy, Debug)]
pub(crate) struct Bar {
    /// Offset at the last tick (a change means the view moved).
    pub seen: f64,
    /// When the view last moved, or the pointer last left.
    pub active_at: f64,
    /// The pointer is in the edge strip.
    pub hot: bool,
    /// The thumb is held.
    pub dragging: bool,
    /// Opacity of this frame, 0 to 1.
    pub alpha: f32,
}

impl Default for Bar {
    fn default() -> Bar {
        Bar {
            seen: 0.0,
            active_at: f64::NEG_INFINITY,
            hot: false,
            dragging: false,
            alpha: 0.0,
        }
    }
}

impl Bar {
    /// Opacity at `now`: full while held, near, or within the linger time; then a linear fade.
    pub fn alpha_at(&self, now: f64, reduce_motion: bool) -> f32 {
        if self.hot || self.dragging {
            return 1.0;
        }
        let age = now - self.active_at;
        if age < LINGER_MS {
            1.0
        } else if reduce_motion || age >= LINGER_MS + FADE_MS {
            0.0
        } else {
            (1.0 - (age - LINGER_MS) / FADE_MS) as f32
        }
    }

    /// Whether frames are still needed for the fade.
    pub fn pending(&self, now: f64) -> bool {
        !self.hot && !self.dragging && now - self.active_at < LINGER_MS + FADE_MS
    }
}

/// The track inside the view `v`, at the width `w`.
pub fn track(v: Rect, w: f32) -> Rect {
    Rect::new(
        v.x + v.w - INSET - w,
        v.y + INSET,
        w,
        (v.h - 2.0 * INSET).max(0.0),
    )
}

/// The thumb for offset `pos` in the track `t`; `None` when the content fits.
pub fn thumb(t: Rect, pos: f64, m: ScrollMetrics) -> Option<Rect> {
    if !m.scrollable() {
        return None;
    }
    let range = m.max - m.min;
    let frac = (m.viewport / (m.viewport + range)) as f32;
    let h = (t.h * frac).clamp(MIN_THUMB.min(t.h), t.h);
    let k = ((pos - m.min) / range).clamp(0.0, 1.0) as f32;
    Some(Rect::new(t.x, t.y + (t.h - h) * k, t.w, h))
}

/// The offset a thumb whose top is at `thumb_y` stands for (drag).
pub fn offset_for(t: Rect, thumb_h: f32, thumb_y: f32, m: ScrollMetrics) -> f64 {
    let free = (t.h - thumb_h).max(1.0);
    let k = f64::from(((thumb_y - t.y) / free).clamp(0.0, 1.0));
    m.min + k * (m.max - m.min)
}

/// Draws the bar of the view `v` (screen points) with `scale` applied to the widths.
pub(crate) fn paint(
    list: &mut DrawList,
    v: Rect,
    pos: f64,
    m: ScrollMetrics,
    bar: &Bar,
    scale: f32,
) {
    if bar.alpha <= 0.0 || v.h < 2.0 * MIN_THUMB {
        return;
    }
    let hot = bar.hot || bar.dragging;
    let w = if hot { WIDTH_HOT } else { WIDTH } * scale;
    let t = track(v, w);
    let Some(th) = thumb(t, pos, m) else { return };
    let opaque = |c: swiftly_design::Colour| Color::new(c.r, c.g, c.b, c.a);
    let rr = |r: Rect| swiftly_render::Rect::new(r.x, r.y, r.w, r.h);
    list.push_opacity(bar.alpha);
    if hot {
        list.fill(rr(t), opaque(colour::HOVER_AREA), w / 2.0);
    }
    let c = if hot {
        colour::FONT_VERY_QUIET
    } else {
        colour::RING_TRACK
    };
    list.fill(rr(th), opaque(c), w / 2.0);
    list.pop_opacity();
}
