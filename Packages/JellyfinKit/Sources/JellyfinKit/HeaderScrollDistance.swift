import Foundation

/// **How far the finger has pulled a list under a collapsing header.**
///
/// Library, watchlist and collections measure the same thing; the calculation used
/// to exist three times, two of them only pointing at the third.
///
/// **The sum of inset and raw offset is the scroll distance.** Measured:
///
///     inset 130.8  offset −130.3  ->  sum 0.5
///     inset 115.0  offset −114.7  ->  sum 0.3
///
/// In between, the chip row collapsed from 28 to 44 pt. The top inset drops by 15.8
/// and the raw offset rises by 15.6. They move together because the scroll view keeps
/// the content fixed when its inset changes. Adding the collapsed amount again counts
/// the distance twice, and the row collapses by itself; three attempts failed on that.
///
/// **An intermediate state is skipped.** While the view recomputes its geometry, it
/// reports offset zero once with the inset already set. That would compute the whole
/// header height, and the row would collapse and reopen for a frame or two. The pairing
/// can only occur for real if the user happens to have scrolled by exactly the inset
/// height, where skipping one frame costs nothing.
public enum HeaderScrollDistance {

    /// The distance, or `nil` if the report is the intermediate state.
    public static func distance(margin: Double, offset: Double) -> Double? {
        guard !(abs(offset) < 1 && margin > 1) else { return nil }
        return offset + margin
    }
}
