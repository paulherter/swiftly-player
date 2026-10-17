import Foundation

/// **Rating, Discord, reporting bugs: the addresses, and when the app points
/// to them by itself.**
///
/// The addresses live here and nowhere else: an invite typed into six
/// different screens will eventually expire in one of them.
///
/// The app has no account and sends no counts anywhere. The only count is
/// kept on the device: how many titles were watched to the end
/// (``RatingQuestion``).
public enum Community {

    /// The invite, same as on the website.
    public static let discord = URL(string: "https://discord.gg/MeGwfv3UwN")!

    /// For typing in by hand where there is no browser (TV).
    public static let discordShort = "discord.gg/MeGwfv3UwN"

    /// Opens the rating field directly in the App Store.
    public static let appStoreRating = URL(string: "https://apps.apple.com/app/id6806824067?action=write-review")!

    /// The Play Store listing; rating takes one more tap there.
    public static let playStore = URL(string: "https://play.google.com/store/apps/details?id=de.paulherter.swiftly")!

    public static let errorShort = "github.com/paulherter/swiftly-player/issues"

    /// A new GitHub issue, with version and platform already in the text.
    ///
    /// Only these two details: no server name, no address, nothing a person
    /// would not write into a public issue themselves.
    public static func errorReport(version: String, platform: String) -> URL {
        var parts = URLComponents(string: "https://github.com/paulherter/swiftly-player/issues/new")!
        parts.queryItems = [URLQueryItem(name: "body",
                                         value: "\n\n---\nSwiftly \(version) · \(platform)")]
        return parts.url!
    }

    /// From this many finished titles on, the Discord hint appears, after the
    /// rating question (3), not together with it.
    public static let discordThreshold = 5

    public enum Trigger: String, Sendable {
        case rating = "bewertung"
        case discord
    }

    /// What comes up after a finished title; at most one thing.
    ///
    /// The rating question goes first. If both are due (for example after an
    /// update, when ten titles are already counted), the Discord hint comes with
    /// the next title: two questions in a row would be exactly the annoyance
    /// this type exists to prevent.
    ///
    /// - Parameters:
    ///   - fertig: Titles watched to the end, **including this one**.
    ///   - bewertungZuletzt: Version in which a rating was last asked for.
    ///   - fassung: The running version.
    ///   - discordGezeigt: Whether the hint was already shown on this installation.
    ///   - ratingPossible: Whether the platform has a rating prompt.
    ///     Apple TV and Linux have none; there the never-asked question must
    ///     not block the Discord hint forever.
    public static func kickoff(done: Int, ratingLast: String?, version: String,
                               discordShown: Bool, ratingPossible: Bool) -> Trigger? {
        if ratingPossible,
           RatingQuestion.due(done: done, lastAsked: ratingLast, version: version) {
            return .rating
        }
        if done >= discordThreshold, !discordShown { return .discord }
        return nil
    }
}
