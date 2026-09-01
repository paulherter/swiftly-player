import Foundation

/// Meldet dem Server, was gerade läuft.
///
/// Das ist mehr als Buchhaltung: Jellyfin merkt sich daran die Position, zeigt
/// „Weiterschauen" und hält andere Geräte auf demselben Stand. Ohne diese
/// Meldungen fängt jeder Film auf jedem Gerät wieder bei null an.
public extension JellyfinClient {

    /// Jellyfin rechnet in 100-Nanosekunden-Ticks.
    static func ticks(fromSeconds seconds: Double) -> Int64 {
        Int64(seconds * 10_000_000)
    }

    static func seconds(fromTicks ticks: Int64) -> Double {
        Double(ticks) / 10_000_000
    }

    private struct ProgressBody: Encodable {
        let ItemId: String
        let PlaySessionId: String?
        let PositionTicks: Int64
        let IsPaused: Bool
        let MediaSourceId: String?
        let PlayMethod: String
        /// Ohne dieses Feld merkt sich Jellyfin keine Wiedergabeposition —
        /// es hält die Wiedergabe sonst für nicht spulbar und verwirft den
        /// Fortschritt. Der Standardwert ist false.
        let CanSeek: Bool
    }

    /// Wiedergabe hat begonnen.
    func reportStart(itemID: String, plan: PlaybackPlan, ticks: Int64 = 0) async throws {
        try await postSession("Sessions/Playing", itemID: itemID, plan: plan,
                              positionTicks: ticks, paused: false)
    }

    /// Zwischenstand. Sinnvoll etwa alle zehn Sekunden und bei jeder
    /// Zustandsänderung.
    func reportProgress(itemID: String, plan: PlaybackPlan,
                        positionTicks: Int64, paused: Bool) async throws {
        try await postSession("Sessions/Playing/Progress", itemID: itemID, plan: plan,
                              positionTicks: positionTicks, paused: paused)
    }

    /// Wiedergabe beendet. Muss auch beim Verlassen der Ansicht kommen,
    /// sonst bleibt die Sitzung im Server-Dashboard hängen.
    func reportStopped(itemID: String, plan: PlaybackPlan, positionTicks: Int64) async throws {
        try await postSession("Sessions/Playing/Stopped", itemID: itemID, plan: plan,
                              positionTicks: positionTicks, paused: false)
    }

    private func postSession(_ path: String, itemID: String, plan: PlaybackPlan,
                             positionTicks: Int64, paused: Bool) async throws {
        _ = try requireSessionForReporting()
        let body = ProgressBody(
            ItemId: itemID,
            PlaySessionId: plan.playSessionID,
            PositionTicks: positionTicks,
            IsPaused: paused,
            MediaSourceId: plan.mediaSourceID,
            PlayMethod: plan.method.wireName,
            CanSeek: true
        )
        let req = try requestForReporting(path, body: body)
        _ = try await sendIgnoringBody(req)
    }
}
