import Foundation

/// **After a long pause, a few seconds back, without anyone noticing.**
///
/// Someone who was away for a quarter of an hour has forgotten the last sentence.
/// Other players step back when resuming; here it happens before the first new frame:
/// the position is set while stopped, then playback starts. No button, no overlay, no
/// visible jump of the bar.
///
/// Not in a SyncPlay group: there the group decides the position, and a separate
/// jump back would run away from the others.
///
/// The rule lives in the package so all platforms use the same numbers.
public enum PauseJumpBack {

    /// From a pause this long the position is set back: ten minutes.
    public static let threshold: TimeInterval = 600

    /// By this much: five seconds. Enough for the last sentence, too little to be
    /// noticed as a repeat.
    public static let range: Double = 5

    /// Where to jump before playing on, or `nil` if not.
    ///
    /// - Parameters:
    ///   - position: the position where it stopped, in seconds.
    ///   - pausedSince: since when it has been stopped; `nil` means it was not
    ///     stopped.
    ///   - jetzt: the moment of resuming.
    ///   - inGroup: whether watching together right now.
    public static func target(position: Double, pausedSince: Date?, now: Date,
                            inGroup: Bool) -> Double? {
        guard !inGroup, let pausedSince else { return nil }
        guard position.isFinite, position > 0 else { return nil }
        guard now.timeIntervalSince(pausedSince) > threshold else { return nil }
        return max(position - range, 0)
    }
}
