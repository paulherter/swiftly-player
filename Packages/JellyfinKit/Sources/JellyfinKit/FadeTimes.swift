import Foundation

/// **How long things fade in and out**: one place for Mac, Linux and Windows.
///
/// Previously a copy on each platform; the copies had drifted apart, and both
/// **cross-faded**.
///
/// Opacity only, no effects (no blur, no zoom).
public enum FadeTimes {

    // MARK: Page change: first away, then in

    /// **The old page goes first**, short and with `easeIn`: it picks up speed and
    /// is gone before you notice.
    ///
    /// The earlier version overlapped out (0.20 s) and in (0.26 s from 0.04 s), so
    /// in the middle both pages sat half transparent on top of each other. That is
    /// a cross-fade and looks unclean.
    public static let pageToOut = 0.12
    /// **Then the new one comes**, with `easeOut`. It starts exactly where the old
    /// one ends; never both at once.
    public static let pageFromIn = 0.22
    /// Out and in, one after the other.
    public static var pageTotal: Double { pageToOut + pageFromIn }

    /// Opacity of the old and the new page after `t` seconds.
    ///
    /// While the old one is still visible, the new one is not; that is the whole
    /// rule, and the test pins it.
    public static func pagesSwitch(_ t: Double) -> (alt: Double, new: Double) {
        let a = min(max(t / pageToOut, 0), 1)
        let b = min(max((t - pageToOut) / pageFromIn, 0), 1)
        return (1 - easeIn(a), easeOut(b))
    }

    // MARK: Individual things

    /// **The paging arrows of a row**, on hover and when there is nothing left to
    /// page to: soft, `easeInOut`. They used to appear abruptly on Linux and in
    /// 0.12 s on the Mac.
    public static let arrows = 0.18

    /// **Background image and image tone of a detail page**, when they arrive after
    /// opening: `easeOut`, as long as the image tone on iPhone (`MoodLoader`,
    /// `.smooth(duration: 0.55)`). Anything already known appears at once without
    /// fading.
    public static let headerImage = 0.55

    // MARK: Curves

    /// `easeIn` as in CSS and SwiftUI (`cubic-bezier(0.42, 0, 1, 1)`).
    public static func easeIn(_ t: Double) -> Double { bezier(t, 0.42, 0, 1, 1) }
    /// `easeOut` as in CSS and SwiftUI (`cubic-bezier(0, 0, 0.58, 1)`).
    public static func easeOut(_ t: Double) -> Double { bezier(t, 0, 0, 0.58, 1) }
    /// `easeInOut` as in CSS and SwiftUI (`cubic-bezier(0.42, 0, 0.58, 1)`).
    public static func easeInOut(_ t: Double) -> Double { bezier(t, 0.42, 0, 0.58, 1) }

    /// A cubic Bézier curve through (0, 0) and (1, 1): the value for `t` on the
    /// time axis, via Newton, eight steps are enough.
    public static func bezier(_ t: Double, _ x1: Double, _ y1: Double,
                              _ x2: Double, _ y2: Double) -> Double {
        let t = min(max(t, 0), 1)
        func b(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * p1 * (1 - s) * (1 - s) * s + 3 * p2 * (1 - s) * s * s + s * s * s
        }
        func db(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * p1 * (1 - s) * (1 - s) + 6 * (p2 - p1) * (1 - s) * s + 3 * (1 - p2) * s * s
        }
        var s = t
        for _ in 0..<8 {
            let d = db(s, x1, x2)
            guard abs(d) > 1e-6 else { break }
            s = min(max(s - (b(s, x1, x2) - t) / d, 0), 1)
        }
        return b(s, y1, y2)
    }
}
