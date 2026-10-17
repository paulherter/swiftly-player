import Foundation

/// What the server does not know yet, the second half of offline download support.
///
/// Someone who downloaded a title watches it on a plane. That produces exactly
/// the information the feature exists for: **where they stopped.** Without this
/// store it would be lost; the server would have the position from the start of
/// the flight, and on the TV at home the episode would start from the beginning.
///
/// **One entry per title, the newest wins.** Not a log of all jumps: the server
/// wants to know where you are, not how you got there. Sending ten reports for
/// the same title in a row would be not just traffic but wrong, since the
/// second to last would arrive last if two requests overtake each other.
public struct PendingReport: Codable, Sendable, Equatable, Identifiable {
    enum CodingKeys: String, CodingKey {
        case itemID
        case account = "konto"
        case ticks
        case moment = "wann"
    }
    public let itemID: String
    /// The account the position belongs to. A position that lands in someone
    /// else's account is worse than none.
    public let account: String
    public let ticks: Int64
    public let moment: Date

    public var id: String { account + "/" + itemID }

    public init(itemID: String, account: String, ticks: Int64, moment: Date = Date()) {
        self.itemID = itemID
        self.account = account
        self.ticks = ticks
        self.moment = moment
    }
}

public enum PostReportRules {

    /// Put a new report into the store; the old one for the same title is dropped.
    public static func record(_ new: PendingReport,
                                 in store: [PendingReport]) -> [PendingReport] {
        // **The older one never wins.** When restoring after a crash, an old report
        // can arrive late; it must not overwrite a newer position.
        if let alt = store.first(where: { $0.id == new.id }), alt.moment > new.moment {
            return store
        }
        return store.filter { $0.id != new.id } + [new]
    }

    /// What is to be sent for this account, oldest first.
    public static func due(_ store: [PendingReport], account: String) -> [PendingReport] {
        store.filter { $0.account == account }.sorted { $0.moment < $1.moment }
    }

    /// After sending successfully.
    public static func completed(_ ids: [String], in store: [PendingReport]) -> [PendingReport] {
        store.filter { !ids.contains($0.id) }
    }

    /// **The newer state wins** (`UserData.LastPlayedDate`).
    ///
    /// If someone continued the title elsewhere since the flight (on the TV, on
    /// the Mac), the server holds a newer timestamp. The position from the plane
    /// would then be a step back, and it lapses. Without a timestamp on the server
    /// (never played), it goes through.
    public static func dispatch(_ m: PendingReport, serverLast: Date?) -> Bool {
        guard let serverLast else { return true }
        return m.moment > serverLast
    }

    /// **A report did get through after all**: then the stored one for the same
    /// title of this account is outdated and must never go out. Otherwise the next
    /// reconnect would send an older position afterwards, a duplicate report with
    /// a step back.
    public static func overFetches(itemID: String, account: String,
                                 in store: [PendingReport]) -> [PendingReport] {
        store.filter { !($0.itemID == itemID && $0.account == account) }
    }
}

public extension JellyfinClient {

    /// What became of a late report.
    enum PostReportOutput: Sendable, Equatable {
        /// Arrived.
        case sent
        /// Not sent and settled: the server has a newer state, or the title no longer
        /// exists there.
        case discarded
    }

    /// **A leftover position to the server, if it still applies.**
    ///
    /// First read the state on the server, then decide
    /// (``Nachmelderegeln/senden(_:serverLast:)``), then report as the end of a
    /// playback. The end and not a bare setting of the position: that way the
    /// server applies its own thresholds and marks "watched" if the episode ended
    /// on the plane, the same rule as for playback with network.
    ///
    /// Throws on a network or server error; the report then stays.
    func reportLater(_ m: PendingReport) async throws -> PostReportOutput {
        let state: UserItemData
        do {
            state = try await userRecord(itemID: m.itemID)
        } catch JellyfinError.http(status: 404, _) {
            return .discarded
        }
        guard PostReportRules.dispatch(m, serverLast: state.lastPlay) else {
            return .discarded
        }
        // A plan from disk is enough: only the ids are reported, and there was no
        // session offline anyway.
        let plan = PlaybackPlan.fromSlab(URL(fileURLWithPath: "/"), container: nil)
        try await reportStopped(itemID: m.itemID, plan: plan, positionTicks: m.ticks)
        // **And when it was.** An end without a prior start sets no
        // `LastPlayedDate` on the server, so without this line the next decision based
        // on the timestamp would have nothing to go by. If only this fails, the
        // position has arrived anyway.
        try? await lastPlaySet(itemID: m.itemID, moment: m.moment)
        return .sent
    }

    /// **Everything left over for an account, oldest first.**
    ///
    /// Returns the ids that are settled (sent or discarded). Stops at the first
    /// error instead of trying on: if one fails, the server is gone again, and the
    /// rest would be lost afterwards.
    func reportLater(_ opened: [PendingReport],
                    log: @Sendable (String) -> Void = { _ in }) async -> [String] {
        var completed: [String] = []
        for m in opened {
            do {
                let output = try await reportLater(m)
                log("[Melden] Nachmeldung \(m.itemID) \(m.ticks / 10_000_000) s: \(output)")
                completed.append(m.id)
            } catch {
                log("[Melden] Nachmeldung \(m.itemID) gescheitert, bleibt liegen")
                break
            }
        }
        return completed
    }
}
