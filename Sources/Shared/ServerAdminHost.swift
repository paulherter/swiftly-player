import Foundation
import JellyfinKit
import Observation
import SwiftlyCore

/// **Who may open the server page.** A Jellyfin administrator (`Policy.IsAdministrator`, read by the core); everyone else
/// gets no row. The answer is kept per account for the run, so Profile has the row in its first frame on every visit
/// after the first (`warm` asks while the libraries load).
@MainActor
final class ServerAdminAccess {
    static let shared = ServerAdminAccess()

    private var known: [String: Bool] = [:]
    private var asking: Set<String> = []

    private init() {}

    /// The remembered answer, or `nil` before the first one.
    func cached(_ session: Session?) -> Bool? {
        guard let session else { return nil }
        return known[session.accountKey]
    }

    /// Asks once per account; a missing answer (offline) is not remembered.
    @discardableResult
    func resolve(_ session: Session?) async -> Bool {
        guard let session, session.kind == .jellyfin else { return false }
        let key = session.accountKey
        if let hit = known[key] { return hit }
        guard asking.insert(key).inserted else { return false }
        defer { asking.remove(key) }
        // Asked of the session's own account, like Android does (`Core.isAdministrator`): the saved-account list does not
        // hold a session that was not saved (the fixture runs), which answered "no answer" and hid the Server section.
        guard let account = AppCore.shared.account(session),
              let answer = try? await AppCore.shared.raw.isAdministrator(account: account) else { return false }
        known[key] = answer
        return answer
    }

    /// Forgets the answers (sign-out).
    func forget() { known = [:] }
}

/// **The one Profile entry for requests, reports and the server**, as the core decides it (`SeerrHub.profileEntry`):
/// "Verwaltung" for an administrator, "Meine Anfragen" for everyone else with Seerr, nothing without either. Keeps
/// the last answer so the row is there in the first frame on a later visit.
@MainActor
@Observable
final class ManagementEntryFlow {
    private(set) var entry: SwiftlyCore.ProfileEntry?

    func load(_ model: AppModel) async {
        let administrator = await ServerAdminAccess.shared.resolve(model.session)
            || (ServerAdminAccess.shared.cached(model.session) ?? false)
        guard let account = AppCore.shared.account(model.session) else {
            entry = nil
            return
        }
        let hub = model.seerr.hub
        if await SeerrConnectionLists.ready(model, hub: hub) { _ = try? await hub.refreshCounts() }
        let next = hub.profileEntry(serverKind: account.serverKind, isAdministrator: administrator)
        if next != entry { entry = next }
    }
}

/// What the page behind the entry needs, as a route value (the core's entry is not `Hashable`).
struct ManagementHubRoute: Hashable {
    struct Section: Hashable {
        /// "requests", "issues", "server".
        let kind: String
        let title: String
        let count: Int
        let manage: Bool
    }

    let title: String
    let sections: [Section]

    init(_ entry: SwiftlyCore.ProfileEntry) {
        title = entry.title
        sections = entry.sections.map {
            Section(kind: "\($0.kind)", title: $0.title, count: Int($0.count), manage: $0.manage)
        }
    }
}
