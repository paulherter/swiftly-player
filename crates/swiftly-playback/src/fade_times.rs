//! Port of `FadeTimes.swift` (JellyfinKit): how long things fade in and out, one place for
//! Mac, Linux and Windows. Opacity only, no effects. Page change: the old page goes first,
//! then the new one comes; never both at once.

/// The old page goes first, short and with `easeIn` (FadeTimes.swift:19).
pub const PAGE_TO_OUT: f64 = 0.12;
/// Then the new one comes, with `easeOut`; it starts exactly where the old one ends
/// (FadeTimes.swift:22).
pub const PAGE_FROM_IN: f64 = 0.22;
/// The paging arrows of a row, soft, `easeInOut` (FadeTimes.swift:41).
pub const ARROWS: f64 = 0.18;
/// Background image and image tone of a detail page, when they arrive after opening
/// (FadeTimes.swift:47).
pub const HEADER_IMAGE: f64 = 0.55;

/// Out and in, one after the other (FadeTimes.swift:24).
pub fn page_total() -> f64 {
    PAGE_TO_OUT + PAGE_FROM_IN
}

/// Opacity of the old and the new page (FadeTimes.swift:30, tuple `(alt, new)`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PageOpacity {
    /// Opacity of the old page.
    pub alt: f64,
    /// Opacity of the new page.
    pub new: f64,
}

/// Opacity of the old and the new page after `t` seconds. While the old one is still
/// visible, the new one is not (FadeTimes.swift:30).
pub fn pages_switch(t: f64) -> PageOpacity {
    let a = (t / PAGE_TO_OUT).clamp(0.0, 1.0);
    let b = ((t - PAGE_TO_OUT) / PAGE_FROM_IN).clamp(0.0, 1.0);
    PageOpacity {
        alt: 1.0 - ease_in(a),
        new: ease_out(b),
    }
}

/// `easeIn` as in CSS and SwiftUI, `cubic-bezier(0.42, 0, 1, 1)` (FadeTimes.swift:52).
pub fn ease_in(t: f64) -> f64 {
    bezier(t, 0.42, 0.0, 1.0, 1.0)
}

/// `easeOut` as in CSS and SwiftUI, `cubic-bezier(0, 0, 0.58, 1)` (FadeTimes.swift:54).
pub fn ease_out(t: f64) -> f64 {
    bezier(t, 0.0, 0.0, 0.58, 1.0)
}

/// `easeInOut` as in CSS and SwiftUI, `cubic-bezier(0.42, 0, 0.58, 1)` (FadeTimes.swift:56).
pub fn ease_in_out(t: f64) -> f64 {
    bezier(t, 0.42, 0.0, 0.58, 1.0)
}

/// A cubic Bezier curve through (0, 0) and (1, 1): the value for `t` on the time axis, via
/// Newton, eight steps (FadeTimes.swift:60).
pub fn bezier(t: f64, x1: f64, y1: f64, x2: f64, y2: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    fn b(s: f64, p1: f64, p2: f64) -> f64 {
        3.0 * p1 * (1.0 - s) * (1.0 - s) * s + 3.0 * p2 * (1.0 - s) * s * s + s * s * s
    }
    fn db(s: f64, p1: f64, p2: f64) -> f64 {
        3.0 * p1 * (1.0 - s) * (1.0 - s)
            + 6.0 * (p2 - p1) * (1.0 - s) * s
            + 3.0 * (1.0 - p2) * s * s
    }
    let mut s = t;
    for _ in 0..8 {
        let d = db(s, x1, x2);
        if d.abs() <= 1e-6 {
            break;
        }
        s = (s - (b(s, x1, x2) - t) / d).clamp(0.0, 1.0);
    }
    b(s, y1, y2)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Never both at once: as long as the old page has opacity, the new one has none.
    #[test]
    fn never_over_fade() {
        let mut t = 0.0;
        while t <= page_total() + 0.05 {
            let d = pages_switch(t);
            assert!(d.alt == 0.0 || d.new == 0.0, "bei {t}: {d:?}");
            t += 0.005;
        }
    }

    #[test]
    fn start_and_end() {
        let a = pages_switch(0.0);
        assert!(a.alt == 1.0 && a.new == 0.0);
        let center = pages_switch(PAGE_TO_OUT);
        assert!(center.alt == 0.0 && center.new == 0.0);
        let e = pages_switch(page_total());
        assert!(e.alt == 0.0 && e.new == 1.0);
    }

    /// Out shorter than in; the arrows in the range 150-200 ms.
    #[test]
    fn last_for() {
        const {
            assert!(PAGE_TO_OUT < PAGE_FROM_IN);
            assert!(ARROWS >= 0.15 && ARROWS <= 0.2);
        }
    }

    /// `easeIn` starts slowly, `easeOut` ends slowly, both hit 0 and 1.
    #[test]
    fn curves() {
        for k in [ease_in, ease_out, ease_in_out] {
            assert!(k(0.0).abs() < 1e-9 && (k(1.0) - 1.0).abs() < 1e-9);
        }
        assert!(ease_in(0.5) < 0.5);
        assert!(ease_out(0.5) > 0.5);
        assert!((ease_in_out(0.5) - 0.5).abs() < 0.01);
    }
}
