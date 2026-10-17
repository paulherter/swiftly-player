import Foundation

/// **The bitrate limit reported to the server.**
///
/// The calculation is two lines long, so it used to exist twice (app model and
/// Linux). It belongs here because the app's whole promise hangs on it: a limit
/// triggers transcoding even when container and codec fit. If the number changes
/// in one place only, one platform converts and the other does not, which is
/// the kind of bug you only notice in the server log.
public enum BitratesLimit {

    /// **One billion effectively means unlimited.** Sending no limit is the
    /// alternative, but Jellyfin treats a missing value differently depending on
    /// the version; a number no file reaches is the more reliable answer.
    public static let opened = 1_000_000_000

    /// - Parameters:
    ///   - immerDirectPlay: The "Always Direct Play" setting. When on, there is
    ///     no limit; that is its whole purpose.
    ///   - megabit: The configured limit in Mbit/s. `0` or less means "none".
    public static func of(alwaysDirectPlay: Bool, megabit: Int) -> Int {
        alwaysDirectPlay || megabit <= 0 ? opened : megabit * 1_000_000
    }
}
