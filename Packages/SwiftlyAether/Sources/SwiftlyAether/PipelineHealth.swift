// Whether the engine's pipeline can still be trusted, as ONE state.
//
// The engine feeds AVPlayer from a local HTTP producer inside the app. While the app is suspended (a paused title in the
// background, also one held by a Picture in Picture window that is paused) iOS closes that listening socket. The engine
// does not know: it reports "playing", `needsForegroundVideoRestore` false, and its own reload reopens the same dead address
// (-1004). Three rules keep the title alive, all in the host glue:
//   1. A long stay in the background with nothing running there leaves the pipeline STALE: it is rebuilt on the return
//      (or at the first Play press when a window still holds the picture).
//   2. A failure after the title was loaded is rebuilt ONCE (a new producer at the current position) before the user sees it.
//   3. Play on a stale or failed pipeline rebuilds first; it is never a no-op.
import Foundation

public struct PipelineHealth: Equatable, Sendable {
    /// The engine's own grace window for a paused title in the background.
    public static let grace: TimeInterval = 15

    public private(set) var stale = false
    /// Automatic rebuilds spent since the pipeline last proved itself (position moved on after a rebuild).
    public private(set) var autoRebuilds = 0
    private var entered: Date?
    private var carried = false
    private var anchor: Double?

    public init() {}

    /// The app entered the background. `carried`: the title PLAYS and a window or route (Picture in Picture, AirPlay) keeps it
    /// running there, so the app is not suspended and the producer lives on.
    public mutating func enteredBackground(at date: Date, playing: Bool, pictureInPicture: Bool, externalPlayback: Bool) {
        entered = date
        carried = playing && (pictureInPicture || externalPlayback)
    }

    /// The app is active again. Returns whether the pipeline is stale now.
    @discardableResult
    public mutating func returned(at date: Date) -> Bool {
        defer { entered = nil }
        if let entered, !carried, date.timeIntervalSince(entered) >= Self.grace { stale = true }
        return stale
    }

    /// Something outside the glue knows the pipeline is dead (a forced teardown in a live run).
    public mutating func markStale() { stale = true }

    /// Whether a pipeline must be rebuilt before it can be played: the engine says so, a long background left it stale, or it failed.
    public static func needsRebuild(engineFlag: Bool, stale: Bool, errored: Bool) -> Bool { engineFlag || stale || errored }

    /// A rebuild began at `position`: the pipeline is fresh; it must move on from there to count as healthy.
    public mutating func rebuilt(at position: Double) {
        stale = false
        anchor = position
    }

    /// An error arrived after the title was loaded. Returns whether to rebuild automatically (once until the title proves itself).
    public mutating func errorArrived() -> Bool {
        guard autoRebuilds < 1 else { return false }
        autoRebuilds += 1
        return true
    }

    /// The playhead moved: two seconds past the rebuild's start the pipeline proved itself.
    public mutating func progressed(to position: Double) {
        guard let anchor, position > anchor + 2 else { return }
        self.anchor = nil
        autoRebuilds = 0
    }
}
