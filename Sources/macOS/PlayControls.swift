import JellyfinKit
import Observation
import SwiftUI

/// Whoever opens the player.
///
/// On iPhone the player hangs off the page that started it as a `fullScreenCover`.
/// In a window that does not work: the player must take the **whole** window,
/// sidebar included. So the request lives one level up, in `MainView`, and pages
/// only report it.
///
/// `PlayRequest` itself is the shared type from `Sources/Shared` (title, plan and
/// start position together), for the same reason as there.
@MainActor
@Observable
final class PlayControls {
    var wish: PlayRequest?
    /// Set when the server refuses playback; shown in the main view's message strip.
    var error: String?

    /// True while a start is fetching the plan.
    private(set) var prepares = false

    private let model: AppModel

    init(model: AppModel) { self.model = model }

    /// Starts where the server says: begun items at their position, otherwise from the
    /// start. Exactly the iPhone rule.
    ///
    /// `sourceID`: the version the user picked when a title has several.
    func launch(_ item: Item, since: Double? = nil, sourceID: String? = nil) {
        // A second click while the plan is still in flight starts nothing that would
        // overwrite `wish`.
        guard !prepares else { return }
        prepares = true
        Task {
            defer { prepares = false }
            // **Fetch the position fresh when none is given.** The tile's value can be stale:
            // resumed on the phone, clicked on the Mac before home reloaded, and the film
            // started at the old spot. iOS and tvOS already fetch it this way; here it runs
            // alongside the plan so it takes no longer. Offline, do not ask: the request would
            // run into its timeout.
            let ask = since == nil && !model.downloads.noNetwork
            async let freshValue = ask ? model.item(id: item.id) : nil
            guard let plan = await model.plan(for: item.id, sourceID: sourceID) else {
                // The error names the server, not just "failed"; with several servers it would
                // otherwise be unclear which one is meant.
                let wo = model.serverName ?? String(localized: "dem Server")
                let text = String(localized: "Die Wiedergabe hat nicht geklappt. Von \(wo) kamen keine Daten zum Abspielen.")
                error = text
                // The strip at the bottom of the content shows it (`TileMessageStrip`).
                TileMessage.shared.text = text
                return
            }
            let fresher = await freshValue
            // Without a reply, the position a download remembered.
            let spot = since ?? fresher.map { $0.resumeFrom ?? 0 }
                ?? model.downloads.entries(for: item.id)?.resumeFrom
                ?? item.resumeFrom ?? 0
            wish = PlayRequest(item: item, plan: plan, startAt: spot)
        }
    }

    func close() { wish = nil }
}
