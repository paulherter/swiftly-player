import Foundation

/// From which second playback resumes, or not at all.
///
/// **The rule had only one half.** "Under a minute is not worth resuming" existed; that the
/// same holds at the *other* end did not. A position three seconds before the end is
/// useless for "continue watching".
///
/// **This is explicitly not a fix for the jump-to-next-episode bug.** The app twice jumped
/// to the next episode, and the resume position looked like the cause (3707 s, then 3721
/// s). The measurement says otherwise: `position 3721 s, runtime 6683 s`, just over half.
/// The cause lies with `:start-time` itself and is still open. This note is here so nobody
/// takes this rule for that fix and stops searching.
///
/// It lives in the package because it is a rule with two bounds, testable without a player,
/// and identical on all platforms.
public enum ResumePoint {

    /// Below this resuming is not worth it; someone who watched half a minute wants to
    /// start over.
    public static let atLeast: TimeInterval = 60

    /// Within this distance of the end the title counts as watched.
    ///
    /// Deliberately a fixed distance, not a fraction: at 90% that would be six minutes in
    /// an hour, and someone who stops in the credits wants to continue exactly there, not
    /// six minutes earlier and certainly not from the start.
    public static let endSpacing: TimeInterval = 60

    /// - Parameters:
    ///   - position: The remembered position in seconds.
    ///   - laufzeit: The runtime in seconds, or `nil` if the server gives none. Without a
    ///     runtime only the lower bound applies; guessing would be worse than doing
    ///     nothing.
    /// - Returns: The second to resume at, or `nil` for "from the start".
    public static func since(position: Double?, runtime: Double?) -> Double? {
        guard let position, position > atLeast else { return nil }
        if let runtime, runtime > 0, position >= runtime - endSpacing { return nil }
        return position
    }
}
