import Foundation
import JellyfinKit
import Observation
import SwiftUI
import SwiftlyCore

/// The host side of the Seerr administration screens: the queue of requests, the problems, a request's
/// detail card, "Problem melden" and "Vom Server löschen". Every word, every right and every state comes from
/// the core's `SeerrAdminScreen`; these flows only keep its last answer and forward the taps.
extension SwiftlyCore.SeerrTabInfo: @retroactive Identifiable {
    public var id: String { "\(tab)" }
}
extension SwiftlyCore.SeerrIssueRow: @retroactive Identifiable {}
extension SwiftlyCore.SeerrIssueMessage: @retroactive Identifiable {}
extension SwiftlyCore.SeerrDeleteStep: @retroactive Identifiable {
    public var id: String { "\(kind)" }
}
extension SwiftlyCore.SeerrDeleteVersion: @retroactive Identifiable {
    public var id: Bool { is4k }
}
extension SwiftlyCore.SeerrDetailRow: @retroactive Identifiable {
    public var id: String { label }
}

/// **The administration of one Seerr connection**: "Verwaltung" (requests and problems), "Meine Meldungen",
/// and the request detail card all hold one of these. A different connection gives a new core screen and the
/// flow clears what it kept.
@MainActor
@Observable
final class SeerrAdminFlow {
    @ObservationIgnored private var hub: SwiftlyCore.SeerrHub?
    @ObservationIgnored private(set) var screen: SwiftlyCore.SeerrAdminScreen?

    /// The tabs this account may open, with their open counts.
    private(set) var tabs: [SwiftlyCore.SeerrTabInfo] = []
    /// The request queue; `nil` until the first answer (or without the right to manage requests).
    private(set) var queue: SwiftlyCore.SeerrRequestsInfo?
    /// The problems list (everyone's for an issue manager, else the account's own).
    private(set) var issues: SwiftlyCore.SeerrIssuesInfo?
    /// The problem that is open, with its thread.
    private(set) var issue: SwiftlyCore.SeerrIssueDetail?
    /// The first load has finished (answer or not), so a page can come in as a whole.
    private(set) var settled = false
    /// Seerr is connected and its session works.
    private(set) var connected = false

    /// Makes the core screen of the connection that is current. Reads nothing but the account.
    @discardableResult
    func attach(_ model: AppModel) async -> Bool {
        let current = connect(model)
        connected = await SeerrConnectionLists.ready(model, hub: current)
        return connected
    }

    /// The screen of the current connection (a different connection starts empty).
    private func connect(_ model: AppModel) -> SwiftlyCore.SeerrHub {
        let current = model.seerr.hub
        if hub !== current {
            hub = current
            screen = SwiftlyCore.SeerrAdminScreen(hub: current)
            tabs = []
            queue = nil
            issues = nil
            issue = nil
            settled = false
        }
        return current
    }

    /// Reads the counts, the queue and the problems the account may see: the page of the last visit first (the
    /// core's stash, no call), then one live read that fetches all three side by side.
    func load(_ model: AppModel) async {
        _ = connect(model)
        if !settled, queue == nil, issues == nil, model.seerr.connected, let screen,
           let stale = try? await screen.restoreAll(), screen === self.screen, !settled {
            tabs = stale.tabs
            queue = stale.queue
            issues = stale.issues
            connected = true
            settled = true
        }
        guard await attach(model), let screen else {
            settled = true
            return
        }
        let kinds = (try? await screen.loadAll()) ?? []
        guard screen === self.screen else { return }
        tabs = kinds
        let wanted = kinds.map(\.tab)
        if wanted.contains(.requests) { queue = screen.requests() }
        if wanted.contains(.issues) { issues = screen.issues() }
        settled = true
    }

    // MARK: Queue

    func selectPill(_ pill: SwiftlyCore.RequestPill) {
        guard let screen else { return }
        queue = screen.selectPill(pill: pill)
    }

    func approve(_ id: Int64) async { await verdict { try await $0.approve(id: id) } }
    func decline(_ id: Int64) async { await verdict { try await $0.decline(id: id) } }
    func retry(_ id: Int64) async { await verdict { try await $0.retry(id: id) } }
    func withdraw(_ id: Int64) async { await verdict { try await $0.withdraw(id: id) } }

    /// One verdict on a request. The row reads "Wird freigegeben…" (the core's word) while the call runs, so
    /// the list is read again every moment until the answer is there.
    private func verdict(_ call: @escaping @Sendable (SwiftlyCore.SeerrAdminScreen) async throws -> SwiftlyCore.SeerrRequestsInfo) async {
        guard let screen else { return }
        let work = Task { try? await call(screen) }
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                if self.queue != nil, screen === self.screen { self.queue = screen.requests() }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let next = await work.value
        ticker.cancel()
        guard screen === self.screen else { return }
        if let next { queue = next }
        tabs = screen.tabs()
    }

    /// The detail card of one request.
    func detail(_ id: Int64) async -> SwiftlyCore.SeerrRequestDetail? {
        guard let screen else { return nil }
        return (try? await screen.requestDetail(id: id)) ?? nil
    }

    // MARK: Problems

    func selectIssuePill(_ pill: SwiftlyCore.IssuePill) {
        guard let screen else { return }
        issues = screen.selectIssuePill(pill: pill)
    }

    func openIssue(_ id: Int64) async {
        guard let screen else { return }
        issue = (try? await screen.openIssue(id: id)) ?? nil
    }

    func closeIssue() {
        guard let screen else { return }
        screen.closeIssue()
        issue = nil
        issues = screen.issues()
    }

    func reply(_ text: String) async {
        guard let screen else { return }
        if let next = (try? await screen.reply(text: text)) ?? nil { issue = next }
    }

    func resolve() async {
        guard let screen else { return }
        if let next = (try? await screen.resolveIssue()) ?? nil { issue = next }
        counted(screen)
    }

    func reopen() async {
        guard let screen else { return }
        if let next = (try? await screen.reopenIssue()) ?? nil { issue = next }
        counted(screen)
    }

    private func counted(_ screen: SwiftlyCore.SeerrAdminScreen) {
        tabs = screen.tabs()
        issues = screen.issues()
    }
}

// MARK: - Report a problem

/// **"Problem melden"** as the core's report flow (`ReportIssueFlow`): the kind, a few words, and where it
/// happened. The core owns all of it: the place (a film, a series, or an episode by its series' TMDB id, with the
/// player's position), the phase (editing, sending, sent, failed in Seerr's own words), the kind, the words and
/// every text the sheet draws. This object only holds the flow and mirrors `info` after each call.
@MainActor
@Observable
final class SeerrReportFlow {
    /// What the sheet draws, as the core last answered. Kept after `dismiss()` so the sheet slides out showing
    /// what it showed; the next `prepare` replaces it.
    private(set) var info: SwiftlyCore.ReportIssueInfo?
    @ObservationIgnored private var flow: SwiftlyCore.ReportIssueFlow?

    /// Starts a fresh report for a library item: the core reads the item, finds the TMDB id and fills the place.
    /// `false` when the title has no TMDB id (the sheet stays shut).
    func prepare(itemID: String, seconds: Double?, model: AppModel) async -> Bool {
        guard let account = AppCore.shared.account(model.session) else { return false }
        let next = SwiftlyCore.SeerrAdminScreen(hub: model.seerr.hub).reportFlow()
        let started = (try? await AppCore.shared.raw.reportStartItem(
            flow: next, account: account, locale: AppCore.language, itemId: itemID, seconds: seconds)) ?? false
        guard started else { return false }
        flow = next
        info = next.info()
        return true
    }

    func setKind(_ kind: SwiftlyCore.IssueKind) {
        guard let flow else { return }
        flow.setKind(kind: kind)
        info = flow.info()
    }

    func setMessage(_ text: String) {
        guard let flow else { return }
        flow.setMessage(text: text)
        info = flow.info()
    }

    /// Sends the report. While the core is on its way to Seerr its phase is read again every moment, so the
    /// sheet shows "Wird gemeldet …" and then the outcome from the core.
    func send() async {
        guard let flow else { return }
        let work = Task { try? await flow.send() }
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                self.mirror(flow)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        _ = await work.value
        ticker.cancel()
        mirror(flow)
    }

    /// The sheet went away: the core closes the report, a send still running no longer shows.
    func dismiss() {
        guard let flow else { return }
        flow.dismiss()
        self.flow = nil
    }

    /// Reads the core's info, unless the report was dismissed meanwhile (a closed flow answers an empty form).
    private func mirror(_ asked: SwiftlyCore.ReportIssueFlow) {
        guard flow === asked else { return }
        info = asked.info()
    }
}

// MARK: - Delete from the server

/// **"Vom Server löschen"** as the core's resumable step flow: confirm the versions, run the steps, retry at the
/// failed step. The core owns the whole flow: which versions it knows, which are ticked (`versions[].chosen`),
/// the steps, and what happens when it is done (the account's lists are marked stale, Home reloads). The sheet
/// reads `info`; while a run is going the core's steps are read again every moment, so each step shows when it
/// starts and when it is done.
@MainActor
@Observable
final class SeerrDeleteFlow {
    private(set) var info: SwiftlyCore.SeerrDeleteInfo?
    @ObservationIgnored private var screen: SwiftlyCore.SeerrAdminScreen?

    var running: Bool { info?.phase == .running }
    /// The versions the person ticked (the core keeps the selection).
    var anyChosen: Bool { info?.versions.contains(where: \.chosen) ?? false }

    /// Asks the core to prepare the delete of a library item (a film, a series, or an episode's series): it finds
    /// the TMDB id and the file size itself. `false` when the account may not delete, the title has no TMDB id
    /// or Seerr does not know it.
    func prepare(itemID: String, model: AppModel) async -> Bool {
        guard let account = AppCore.shared.account(model.session) else { return false }
        let screen = SwiftlyCore.SeerrAdminScreen(hub: model.seerr.hub)
        guard let next = (try? await AppCore.shared.raw.deletePrepareItem(
            screen: screen, account: account, locale: AppCore.language, itemId: itemID)) ?? nil else {
            return false
        }
        self.screen = screen
        info = next
        return true
    }

    func toggle(_ lane: Bool) {
        guard let screen else { return }
        info = screen.deleteToggle(is4k: lane)
    }

    func run() async {
        guard let screen, anyChosen else { return }
        await follow(screen) { try await $0.deleteRunChosen() }
    }

    func retry() async {
        guard let screen else { return }
        await follow(screen) { try await $0.deleteRetry() }
    }

    private func follow(_ screen: SwiftlyCore.SeerrAdminScreen,
                        _ call: @escaping @Sendable (SwiftlyCore.SeerrAdminScreen) async throws -> SwiftlyCore.SeerrDeleteInfo) async {
        let work = Task { try? await call(screen) }
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                self.info = screen.deleteInfo()
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        let next = await work.value
        ticker.cancel()
        info = next ?? screen.deleteInfo()
    }
}
