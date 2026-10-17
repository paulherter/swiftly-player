import Foundation

/// Reports to the server what is playing.
///
/// This is more than bookkeeping: Jellyfin uses it to remember the position,
/// show "Continue Watching" and keep other devices in sync. Without these
/// reports every movie starts at zero again on every device.
public extension JellyfinClient {

    /// Jellyfin counts in 100-nanosecond ticks.
    ///
    /// **No crash on NaN, infinity or nonsense.** `Int64(Double)` aborts the app
    /// when the value is not a number or does not fit. This is where the player's
    /// word is reported, and a player that is just opening or closing does not
    /// always say a number. Negative counts as the start, as with ``Sprungziel``.
    static func ticks(fromSeconds seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        // Just below Int64.max / 10^7, over 29,000 years.
        return Int64(min(seconds, 900_000_000_000) * 10_000_000)
    }

    static func seconds(fromTicks ticks: Int64) -> Double {
        Double(ticks) / 10_000_000
    }

    internal struct ProgressBody: Encodable {
        let ItemId: String
        let PlaySessionId: String?
        let PositionTicks: Int64
        let IsPaused: Bool
        let MediaSourceId: String?
        let PlayMethod: String
        /// Without this field Jellyfin does not remember the playback position;
        /// otherwise it considers the playback not seekable and discards the
        /// progress. The default is false.
        let CanSeek: Bool
        /// The running tracks as Jellyfin indices. If they are missing, they are left
        /// out; otherwise the server remembers "none".
        var AudioStreamIndex: Int? = nil
        var SubtitleStreamIndex: Int? = nil
    }

    /// Playback has started.
    func reportStart(itemID: String, plan: PlaybackPlan, ticks: Int64 = 0,
                     tracks: TrackIndices = .init()) async throws {
        try await postSession("Sessions/Playing", itemID: itemID, plan: plan,
                              positionTicks: ticks, paused: false, tracks: tracks)
    }

    /// Progress update. Sensible about every ten seconds and on every state
    /// change.
    func reportProgress(itemID: String, plan: PlaybackPlan,
                        positionTicks: Int64, paused: Bool,
                        tracks: TrackIndices = .init()) async throws {
        try await postSession("Sessions/Playing/Progress", itemID: itemID, plan: plan,
                              positionTicks: positionTicks, paused: paused, tracks: tracks)
    }

    /// Playback has ended. Must also be sent when leaving the view, otherwise the
    /// session stays stuck in the server dashboard.
    func reportStopped(itemID: String, plan: PlaybackPlan, positionTicks: Int64) async throws {
        try await postSession("Sessions/Playing/Stopped", itemID: itemID, plan: plan,
                              positionTicks: positionTicks, paused: false)
    }

    private func postSession(_ path: String, itemID: String, plan: PlaybackPlan,
                             positionTicks: Int64, paused: Bool,
                             tracks: TrackIndices = .init()) async throws {
        _ = try requireSessionForReporting()
        let body = Self.reportBody(itemID: itemID, plan: plan, positionTicks: positionTicks,
                                     paused: paused, tracks: tracks)
        let req = try requestForReporting(path, body: body)
        _ = try await sendIgnoringBody(req)
    }

    internal static func reportBody(itemID: String, plan: PlaybackPlan, positionTicks: Int64,
                             paused: Bool, tracks: TrackIndices) -> ProgressBody {
        ProgressBody(
            ItemId: itemID,
            PlaySessionId: plan.playSessionID,
            PositionTicks: positionTicks,
            IsPaused: paused,
            MediaSourceId: plan.mediaSourceID,
            PlayMethod: plan.method.wireName,
            CanSeek: true,
            AudioStreamIndex: tracks.audio,
            SubtitleStreamIndex: tracks.subtitle
        )
    }
}
