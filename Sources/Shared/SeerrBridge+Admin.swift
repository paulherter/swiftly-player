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

// MARK: - Where a problem or a delete is about

/// The title a problem or a delete is about, in Seerr's terms: `art` (`movie` / `tv`), the TMDB id, and for an
/// episode the season, number and the player's position ("23:14").
struct SeerrPlace: Equatable {
    let art: String
    let tmdb: Int64
    let title: String
    var season: Int64 = 0
    var episode: Int64 = 0
    var at: String?

    /// The place of a library item: a film or series by its own TMDB id, an episode by its series' (read from
    /// the server when the item does not carry it). `nil` when the item has none (a title without a TMDB id).
    @MainActor
    static func of(_ item: Item, model: AppModel, seconds: Double? = nil) async -> SeerrPlace? {
        func tmdb(of item: Item) -> Int64? { item.providerIds?["Tmdb"].flatMap(Int64.init) }
        func fresh(_ id: String) async -> Item? { try? await model.client?.item(id: id) }
        /// The item's own TMDB id, or the one of a fresh read (lists often leave the provider ids out).
        func own(_ item: Item) async -> Int64? {
            if let id = tmdb(of: item) { return id }
            guard let again = await fresh(item.id) else { return nil }
            return tmdb(of: again)
        }
        switch item.type {
        case "Movie":
            guard let id = await own(item) else { return nil }
            return SeerrPlace(art: "movie", tmdb: id, title: item.name, at: seconds.map(Self.clock))
        case "Series":
            guard let id = await own(item) else { return nil }
            return SeerrPlace(art: "tv", tmdb: id, title: item.name)
        case "Episode":
            guard let seriesID = item.seriesId, let series = await fresh(seriesID), let id = tmdb(of: series) else {
                return nil
            }
            return SeerrPlace(art: "tv", tmdb: id, title: item.seriesName ?? series.name,
                              season: Int64(item.parentIndexNumber ?? 0), episode: Int64(item.indexNumber ?? 0),
                              at: seconds.map(Self.clock))
        default:
            return nil
        }
    }

    /// "23:14" (minutes can pass 59: the core reads `m:ss`).
    static func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// "Staffel 2 · Folge 3 · bei 23:14" for the sheet's quiet line (`nil` for a film without a position).
    var line: String? {
        var parts: [String] = []
        if season > 0 { parts.append(String(localized: "Staffel \(season)")) }
        if episode > 0 { parts.append(String(localized: "Folge \(episode)")) }
        if let at { parts.append(String(localized: "bei \(at)")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Report a problem

/// **"Problem melden"**: the kind, a few words, and where it happened. The core creates the issue and answers
/// with an error text or nothing.
@MainActor
@Observable
final class SeerrReportFlow {
    enum Phase: Equatable {
        case editing
        case sending
        case sent
        case failed(String)
    }

    private(set) var phase = Phase.editing
    var kind = SwiftlyCore.IssueKind.video
    var message = ""
    private(set) var place: SeerrPlace?

    /// Starts a fresh report for a place (the sheet opens on it).
    func start(_ place: SeerrPlace) {
        self.place = place
        phase = .editing
        kind = .video
        message = ""
    }

    func send(_ model: AppModel) async {
        guard let place, phase != .sending else { return }
        phase = .sending
        let screen = SwiftlyCore.SeerrAdminScreen(hub: model.seerr.hub)
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let failure = (try? await screen.reportIssue(art: place.art, tmdb: place.tmdb, kind: kind, message: text,
                                                    season: place.season, episode: place.episode, at: place.at)) ?? nil
        phase = failure.map(Phase.failed) ?? .sent
    }
}

// MARK: - Delete from the server

/// **"Vom Server löschen"** as the core's resumable step flow: confirm the versions, run the steps, retry at the
/// failed step. The sheet reads `info`; while a run is going the core's steps are read again every moment, so
/// each step shows when it starts and when it is done.
@MainActor
@Observable
final class SeerrDeleteFlow {
    private(set) var info: SwiftlyCore.SeerrDeleteInfo?
    /// The versions to delete (`true` = 4K); all of them until the person unticks one.
    private(set) var chosen: Set<Bool> = []
    @ObservationIgnored private var screen: SwiftlyCore.SeerrAdminScreen?

    var running: Bool { info?.phase == .running }

    /// Asks the core which versions Seerr knows. `false` when the account may not delete or Seerr has none.
    func prepare(_ place: SeerrPlace, standardSize: String?, model: AppModel) async -> Bool {
        let screen = SwiftlyCore.SeerrAdminScreen(hub: model.seerr.hub)
        guard let next = (try? await screen.deletePrepare(art: place.art, tmdb: place.tmdb, title: place.title,
                                                          standardSize: standardSize, fourKSize: nil)) ?? nil else {
            return false
        }
        self.screen = screen
        info = next
        chosen = Set(next.versions.map(\.is4k))
        return true
    }

    func toggle(_ lane: Bool) {
        if chosen.contains(lane) { chosen.remove(lane) } else { chosen.insert(lane) }
    }

    func run() async {
        guard let screen, !chosen.isEmpty else { return }
        let lanes = Array(chosen)
        await follow(screen) { try await $0.deleteRun(lanes: lanes) }
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

/// A file size as the delete sheet's version row shows it ("4,2 GB").
enum SeerrSize {
    static func text(_ bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
