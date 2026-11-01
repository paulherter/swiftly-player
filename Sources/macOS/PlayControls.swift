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

    /// **A title with several versions, waiting for the pick** ("Fassung wählen", shown by
    /// the main view). Set instead of starting the server's default version.
    var versionChoice: VersionChoice?

    private let model: AppModel

    init(model: AppModel) { self.model = model }

    /// Starts where the server says: begun items at their position, otherwise from the
    /// start. Exactly the iPhone rule.
    ///
    /// `sourceID`: the version the user picked when a title has several. Without it a title
    /// with several versions asks which one first (``MediaVersions/start(_:downloaded:)``);
    /// the full title is fetched when the entry has no `MediaSources`, and a failed load is
    /// reported instead of starting the default.
    func launch(_ item: Item, since: Double? = nil, sourceID: String? = nil) {
        // A second click while the plan is still in flight starts nothing that would
        // overwrite `wish`.
        guard !prepares else { return }
        prepares = true
        Task {
            defer { prepares = false }
            _ = await start(item, since: since, sourceID: sourceID, still: false, asking: sourceID == nil)
        }
    }

    /// The pick from the dialog: starts exactly this version.
    func launch(_ choice: VersionChoice, picking version: MediaSource) {
        launch(choice.item, since: choice.since, sourceID: version.id)
    }

    /// Tries the trailers in the order ``TrailerChoice`` gives and opens the first one the
    /// server can describe (as `TrailerStart` does on iPhone, iPad and Apple TV). A file whose
    /// plan fails is skipped while another candidate is left; only the last failure is
    /// reported. `onWeb` opens a link candidate. Returns false when nothing could be started.
    @discardableResult
    func launchTrailer(_ candidates: [TrailerCandidate], onWeb: (URL) -> Void) async -> Bool {
        guard !prepares else { return true }
        prepares = true
        defer { prepares = false }
        let lastIndex = candidates.indices.last
        for (index, candidate) in candidates.enumerated() {
            switch candidate {
            case .file(let film):
                if await start(film, since: 0, sourceID: nil, still: index != lastIndex) { return true }
            case .web(let target):
                onWeb(target)
                return true
            }
        }
        return false
    }

    /// Fetches the plan and opens the player. False when the server gave no plan.
    private func start(_ item: Item, since: Double?, sourceID: String?, still: Bool,
                       asking: Bool = false) async -> Bool {
        var item = item
        if asking {
            let downloaded = model.downloads.file(for: item.id) != nil
            var sources = item.mediaSources
            if sources == nil, !downloaded {
                // The list entry has no `MediaSources`: "not loaded" must never pass for
                // "one version".
                guard let full = await model.item(id: item.id) else {
                    let text = String(localized: "Die Fassungen konnten nicht geladen werden. Probier es gleich nochmal.")
                    error = text
                    TileMessage.shared.text = text
                    return false
                }
                item = full
                sources = full.mediaSources ?? []
            }
            if case .choose(let versions) = MediaVersions.start(sources, downloaded: downloaded) {
                versionChoice = VersionChoice(item: item, versions: versions, since: since)
                return false
            }
        }
        // **Fetch the position fresh when none is given.** The tile's value can be stale:
        // resumed on the phone, clicked on the Mac before home reloaded, and the film
        // started at the old spot. iOS and tvOS already fetch it this way; here it runs
        // alongside the plan so it takes no longer. Offline, do not ask: the request would
        // run into its timeout.
        let ask = since == nil && !model.downloads.noNetwork
        let itemID = item.id
        async let freshValue = ask ? model.item(id: itemID) : nil
        guard let plan = await model.plan(for: itemID, still: still, sourceID: sourceID) else {
            if !still {
                // The error names the server, not just "failed"; with several servers it would
                // otherwise be unclear which one is meant.
                let wo = model.serverName ?? String(localized: "dem Server")
                let text = String(localized: "Die Wiedergabe hat nicht geklappt. Von \(wo) kamen keine Daten zum Abspielen.")
                error = text
                // The strip at the bottom of the content shows it (`TileMessageStrip`).
                TileMessage.shared.text = text
            }
            return false
        }
        let fresher = await freshValue
        // Without a reply, the position a download remembered.
        let spot = since ?? fresher.map { $0.resumeFrom ?? 0 }
            ?? model.downloads.entries(for: item.id)?.resumeFrom
            ?? item.resumeFrom ?? 0
        wish = PlayRequest(item: item, plan: plan, startAt: spot)
        return true
    }

    func close() { wish = nil }
}
