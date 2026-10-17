import Foundation

/// **While scrubbing, the slider snaps to section boundaries.**
///
/// The notches on the bar show where intro and outro start and end. With a
/// thumb you hit the spot only to within a few points; in a 45-minute episode
/// that is ten or twenty seconds off. When the finger gets close enough to a
/// notch, the slider sits exactly on it, and a light tick says it is there.
///
/// Measured in points, not seconds: the hand aims on the screen, and a long
/// runtime should not make the snapping wider.
public enum NotchesSnap {

    /// How close the finger must be to the notch, in points.
    public static let snapRange: Double = 8

    /// The notch the slider should rest on, or `nil` if none is close enough.
    /// With two, the nearer one.
    ///
    /// - Parameters:
    ///   - wert: the position under the finger, in seconds.
    ///   - bis: the runtime, in seconds.
    ///   - marken: the section boundaries, in seconds.
    ///   - breite: the width of the bar, in points.
    public static func notch(value: Double, until: Double, marks: [Double],
                             width: Double) -> Double? {
        guard until > 0, width > 0, value.isFinite else { return nil }
        let proPoint = until / width
        let range = snapRange * proPoint
        return marks
            .filter { $0 > 0 && $0 < until }
            .map { ($0, abs($0 - value)) }
            .filter { $0.1 <= range }
            .min { $0.1 < $1.1 }?.0
    }
}
