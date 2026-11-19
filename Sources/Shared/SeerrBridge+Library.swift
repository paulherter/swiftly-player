import Foundation
import JellyfinKit
import SwiftlyCore

/// The Jellyfin side of the Seerr screens: which library item has a TMDB id, and "scan the libraries
/// again" (the delete flow's third step). The core calls it through ``SwiftlyCore/SeerrLibrary``; it runs
/// over the client the app already holds, so it signs in as the same account and needs nothing of its own.
///
/// Only Jellyfin and Emby have the two calls. A Plex account answers "not in the library" and refuses the
/// scan, which the delete flow shows as its failed step.
final class JellyfinSeerrLibrary: SwiftlyCore.SeerrLibrary, @unchecked Sendable {

    /// The client of the account that is signed in now (read when asked, so an account switch is followed).
    private let server: @MainActor @Sendable () -> (any MediaServer)?

    init(server: @escaping @MainActor @Sendable () -> (any MediaServer)?) {
        self.server = server
    }

    func find(art: String, tmdb: Int64) async throws -> String? {
        guard let client = await server() as? JellyfinClient else { return nil }
        do {
            return try await client.itemID(tmdb: Int(tmdb), series: art == "tv")
        } catch {
            throw Self.failure(error)
        }
    }

    func refresh() async throws {
        guard let client = await server() as? JellyfinClient else {
            throw SwiftlyCore.LibraryFailure.Other(message: "This media server has no library scan call")
        }
        do {
            try await client.scanLibraries()
        } catch {
            throw Self.failure(error)
        }
    }

    private static func failure(_ error: Error) -> SwiftlyCore.LibraryFailure {
        if error is CancellationError { return .Cancelled }
        return .Other(message: String(describing: error))
    }
}

/// The two arrival settings, in one place for the Home block and the settings page.
///
/// `seerrArrivalHint` follows the account through the settings sync (core key of the same name, on by
/// default); the dismissed arrivals stay on the device (`seerrArrivalDismissed`, request ids as text).
/// The Home block passes both to the core with every load (`SeerrListsScreen.loadHome`), and the core
/// does not look for arrivals at all while the hint is off.
enum SeerrArrival {
    static let hintKey = "seerrArrivalHint"
    static let dismissedKey = "seerrArrivalDismissed"
    /// Whether the stack of arrivals was left open (device setting; the core shows it open only with two or more cards).
    static let expandedKey = "seerrArrivalExpanded"
    /// The "Meine Anfragen" section of the Start page (core key of the same name, synced, off until switched on).
    static let requestsKey = "seerrRequestsRail"

    /// Is the "is here" banner switched on? On unless the person switched it off.
    static var hintOn: Bool {
        UserDefaults.standard.object(forKey: hintKey) as? Bool ?? true
    }

    /// Is the "Meine Anfragen" rail switched on for the Start page? Off unless the person switched it on.
    static var requestsOn: Bool {
        UserDefaults.standard.object(forKey: requestsKey) as? Bool ?? false
    }

    /// The request ids whose banner was closed.
    static var dismissed: [Int64] {
        (UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []).compactMap(Int64.init)
    }

    /// Was the stack left open?
    static var expanded: Bool {
        UserDefaults.standard.bool(forKey: expandedKey)
    }

    static func remember(expanded: Bool) {
        UserDefaults.standard.set(expanded, forKey: expandedKey)
    }

    /// Stores the dismissed ids the core returns from `dismissArrival`.
    static func remember(dismissed ids: [Int64]) {
        UserDefaults.standard.set(ids.map(String.init), forKey: dismissedKey)
    }
}

extension SeerrCore {

    /// The Seerr screens' shared connection (who the account is, what it may do, the counts, the titles
    /// read so far). One per stored connection: ``SeerrModel/hub``.
    typealias Hub = SwiftlyCore.SeerrHub

    /// The hub for a stored connection. Without one (`nil`) the hub is an empty one: `available()` is
    /// false and every screen draws nothing.
    @MainActor
    static func hub(access: JellyfinKit.SeerrAccess?, library: JellyfinSeerrLibrary) -> Hub {
        Hub(model: access.map(model), locale: AppCore.language, library: library)
    }
}

extension SwiftlyCore.SeerrListsScreen {
    /// The Home block with the stored arrival settings: banner off = no arrival search.
    func loadHomeForApp() async -> SwiftlyCore.SeerrHomeInfo? {
        // The stack comes back as it was left (open only counts with two or more cards: the core decides).
        _ = setArrivalsExpanded(expanded: SeerrArrival.expanded)
        return try? await loadHome(dismissed: SeerrArrival.dismissed, arrivalOn: SeerrArrival.hintOn,
                        requestsOn: SeerrArrival.requestsOn)
    }

    /// The Home block as the last start left it, from the core's stash and without a call to Seerr (`nil`: nothing stored).
    func restoreHomeForApp() async -> SwiftlyCore.SeerrHomeInfo? {
        try? await restoreHome(dismissed: SeerrArrival.dismissed, arrivalOn: SeerrArrival.hintOn,
                          requestsOn: SeerrArrival.requestsOn)
    }

    /// Closes the banner of a request for good (the core hands back all dismissed ids, the device keeps them).
    func dismissArrivalForApp(_ requestId: Int64) {
        SeerrArrival.remember(dismissed: dismissArrival(requestId: requestId))
    }
}
