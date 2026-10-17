import Foundation

/// **A position in the title that can safely be converted to whole
/// milliseconds.**
///
/// The player converts jump targets with `Int(seconds * 1000)`, and that
/// conversion traps if the value is NaN, infinite or larger than `Int`: it does
/// not check, it crashes. Such a value arises easily: a fraction times a runtime
/// the server reports as zero, a progress divided by zero. So the value is
/// limited at the entry point and not at each place that converts later.
public enum JumpTarget {

    /// Roughly eleven days. No title is that long; the limit only exists so the
    /// conversion to milliseconds never overflows.
    public static let upperLimit: Double = 1_000_000

    /// The value between zero and ``obergrenze``, or `nil` if it is not a number.
    public static func seconds(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return min(max(0, value), upperLimit)
    }
}
