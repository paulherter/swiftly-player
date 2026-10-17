import Foundation

/// **When the app asks for an App Store rating.**
///
/// After the third finished title, and at most once per version. Earlier would be
/// asking someone who does not know the app yet; more often would be annoying. Apple
/// itself shows the prompt at most three times a year anyway; this rule only decides
/// *when* it is offered.
public enum RatingQuestion {

    /// From this many finished titles.
    public static let threshold = 3

    /// From this fraction on a title counts as finished. The credits do not count: someone
    /// who skips them has still watched to the end.
    public static let readyShare = 0.9

    /// A trailer or a short clip is not a watched title.
    public static let minDuration: Double = 60

    public static func countsAsReady(position: Double, duration: Double) -> Bool {
        duration >= minDuration && position / duration >= readyShare
    }

    /// - Parameters:
    ///   - fertig: How many titles have been finished so far.
    ///   - zuletztGefragt: The version in which it was last asked.
    ///   - fassung: The running version.
    public static func due(done: Int, lastAsked: String?, version: String) -> Bool {
        done >= threshold && lastAsked != version
    }
}
