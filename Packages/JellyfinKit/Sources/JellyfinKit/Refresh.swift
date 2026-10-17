import Foundation

/// When the home page has to reload its rows.
///
/// **The trigger is not the view appearing but the suspicion that the data is
/// outdated.** The iPhone version loaded exactly once per app start: `loaded` was
/// set and never reset. After that “Continue Watching” stood still until someone
/// pulled the page down by hand.
///
/// How it showed: an episode finished on another device still sat in the row with a
/// bar at sixty percent. On tap `HomeView` deliberately fetches the position fresh,
/// and fresh it was zero. So the player started at the beginning, correct and
/// unexpected at once, because the tile next to it claimed something else. The bug was
/// then searched for in the player; it was in the list.
///
/// Three triggers, and the difference between them matters:
///
/// - **The player closes.** The position has certainly changed; the viewer is just
///   coming from there. No time limit.
/// - **The app comes to the foreground.** Something may have changed, on another
///   device. With a time limit, otherwise every switch hits the server.
/// - **The view appears for the first time.** Nothing is there yet.
///
/// Lives in the package and not in the view because all three platforms show the same
/// rows and need the same answer. The same happened to `TimeAssumption` and `EpisodeEnd`:
/// as a rule in the view it drifted apart between versions without anyone measuring it.
public enum Refresh {

    /// How long the rows count as fresh after loading.
    ///
    /// Thirty seconds is weighed, not guessed. Shorter means: someone switching back and
    /// forth between Swiftly and a message triggers three queries each time. Longer means:
    /// someone finishing on the TV and then picking up the phone still sees the episode
    /// there. A device switch rarely takes under half a minute, a glance at a message
    /// rarely longer.
    public static let deadline: TimeInterval = 30

    /// Is a reload due because the app returns to the foreground?
    ///
    /// - Parameters:
    ///   - zuletzt: When last loaded, or `nil` if never.
    ///   - jetzt: Injectable for tests.
    public static func dueReturn(recent: Date?,
                                           now: Date = Date(),
                                           deadline: TimeInterval = deadline) -> Bool {
        guard let recent else { return true }
        return now.timeIntervalSince(recent) >= deadline
    }
}
