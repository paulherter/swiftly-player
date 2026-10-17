import Foundation

/// One tick of playback observation: the rules both players need.
///
/// The loop used to exist twice, once per platform, and was largely the same:
/// every half second check what the drawing surface reports, adopt the time or
/// not, remove the loading screen, set the tracks, tell the server.
///
/// **The state stays with the view.** This file only computes. It receives the
/// state, changes it and returns what is to be done afterwards: remove the
/// loading screen, apply tracks, report. What that means is known only to the
/// platform: the iPhone restarts the controls auto-hide, the TV does not.
///
/// Why not a class with its own state: the views keep their values in `@State`
/// and read them in over seventy places. Rewiring all of them would be a big
/// intervention in a shipped player, for nothing this file cannot do as it is.
@MainActor
public enum PlaybackTick {

    /// Every half second. Nobody needs finer: the display shows seconds.
    ///
    /// **`nonisolated`, because GTK does not start the tick on the main actor.**
    /// On Linux `g_timeout_add_full` creates it from a non-isolated method; without
    /// this, a copied 500 sat there, and there must be **one** source for the
    /// number. An immutable `Sendable` may leave the actor.
    public nonisolated static let tickLength: Duration = .milliseconds(500)
    /// How often the server learns the progress.
    public nonisolated static let reportSpacing: Double = 10

    /// What the view shows and the tick updates.
    public struct Snapshot: Sendable {
        public var position: Double = 0
        public var duration: Double = 0
        public var running = true
        public var firstImagePresent = false
        public var tracksSet = false
        /// The server has been told once that playback started.
        public var startReported = false
        /// Seconds since the last progress report.
        public var sinceMessage: Double = 0
        /// The title arrived through an episode switch in the running player; VLC's
        /// clock initially still belongs to the transition (`TimeAssumption.position`).
        public var afterChange = false
        /// A jump VLC has not reached yet: until then the display shows the target.
        /// Set through ``jumped(_:target:now:)``.
        public var leap: Jump?

        public init(position: Double = 0, duration: Double = 0, running: Bool = true,
                    firstImagePresent: Bool = false, tracksSet: Bool = false,
                    startReported: Bool = false, sinceMessage: Double = 0) {
            self.position = position
            self.duration = duration
            self.running = running
            self.firstImagePresent = firstImagePresent
            self.tracksSet = tracksSet
            self.startReported = startReported
            self.sinceMessage = sinceMessage
        }
    }

    /// **The target of a jump, until VLC is there.**
    ///
    /// After a double tap, the time at the bottom stayed on the old position for
    /// seconds, and "Skip intro" came and went correspondingly late. Measured in
    /// the iOS simulator: VLC reported the new time on the very next tick, but the
    /// display stayed put for 2.0 s. `scrub` did not set the display to the target,
    /// and the latch meant to protect it from VLC's old time kept the new one out
    /// until its deadline expired. On a device, where VLC waits for the next key
    /// frame after a jump, it took longer.
    ///
    /// So the rule lives here once and not per jump path: **every** jump sets the
    /// display to the target immediately, the tick holds it there and hands over to
    /// VLC as soon as VLC has arrived.
    public struct Jump: Sendable, Equatable {
        public let target: Double
        public let since: Date

        public init(target: Double, since: Date = Date()) {
            self.target = target
            self.since = since
        }
    }

    /// Jumped: the display stands on the target from now on.
    ///
    /// Limited to the duration once it is known; a jump past the end would show a
    /// time that does not exist.
    public nonisolated static func jumped(_ state: inout Snapshot, target: Double,
                                              now: Date = Date()) {
        var spot = max(target, 0)
        if state.duration > 0 { spot = min(spot, state.duration) }
        state.position = spot
        state.leap = Jump(target: spot, since: now)
    }

    /// Where a jump **by** `seconds` leads: from the target of a jump still in
    /// progress, otherwise from the displayed position. Three quick skips forward
    /// are then 90 seconds, even if VLC is still on its way.
    public nonisolated static func target(um seconds: Double, state: Snapshot) -> Double {
        (state.leap?.target ?? state.position) + seconds
    }

    /// The longest the display stays on a target VLC never reaches.
    /// `VLCPlayerView` tries the second jump path after 2.5 s and gives up after
    /// another 2.5 s; after that, what VLC says applies again.
    public nonisolated static let jumpCeiling: TimeInterval = 8

    /// What is to be done after this tick. The view decides how.
    public struct WorkItem: Sendable {
        public var loadingScreenGone = false
        public var tracksApply = false
        public var startReport = false
        public var progressReport = false

        public init() {}
    }

    /// What the drawing surface says in this tick.
    ///
    /// A type of its own and not `VLCPlayerView`, so the rules can be tested
    /// without a player.
    public struct Reading: Sendable {
        public let duration: Double
        public let position: Double
        public let goodPoint: Double
        public let showsImage: Bool
        public let seeksToStart: Bool
        public let running: Bool
        public let hasAudioTracks: Bool

        public init(duration: Double, position: Double, goodPoint: Double,
                    showsImage: Bool, seeksToStart: Bool, running: Bool,
                    hasAudioTracks: Bool) {
            self.duration = duration
            self.position = position
            self.goodPoint = goodPoint
            self.showsImage = showsImage
            self.seeksToStart = seeksToStart
            self.running = running
            self.hasAudioTracks = hasAudioTracks
        }
    }

    /// A new title runs in the same loop.
    ///
    /// Whoever switches the episode in the running player must say so here;
    /// otherwise the state still considers `startReported` done, and the server
    /// learns only progress for the next title without a session ever having
    /// been opened. That is exactly what happened on the TV.
    ///
    /// The iPhone version reports the start itself on the switch and does not need
    /// this; it calls `startReported: true` instead. Both ways are right as long as
    /// one of them is taken, which is why the choice is documented here and not in
    /// the memory of whoever writes the switch.
    public nonisolated static func newTitle(_ state: inout Snapshot, startReported: Bool) {
        state.position = 0
        // **The picture too.** If it was not here, each platform added it itself, and
        // macOS had forgotten it: no loading screen, and the tick immediately adopted
        // the time of the old episode again.
        state.firstImagePresent = false
        state.tracksSet = false
        state.startReported = startReported
        state.sinceMessage = 0
        state.afterChange = true
        state.leap = nil
    }

    /// **The display shows VLC's time, exactly that, nothing extrapolated.**
    ///
    /// The only exception after a jump: the target, until VLC is within
    /// ``TimeAssumption/jumpArrived`` of it, then VLC's time again at once, even
    /// if it lies one key frame before the target. (An earlier version held the
    /// target until VLC passed it; on the iPhone the time then stood still after
    /// "30 s forward" and afterwards seemed to count faster.) If VLC never arrives,
    /// it ends after ``sprungdeckel``.
    ///
    /// A function of its own, so a platform can update the display more often than
    /// the whole tick (``anzeigetakt``), with the same guards.
    public nonisolated static func timeAdopt(_ state: inout Snapshot, reported: Double,
                                                   atPush: Bool, sinceStart: Date,
                                                   now: Date = Date()) {
        guard !atPush else { return }
        if let leap = state.leap {
            let arrived = abs(reported - leap.target) < TimeAssumption.jumpArrived
            if arrived || now.timeIntervalSince(leap.since) >= jumpCeiling {
                state.leap = nil
                state.position = reported
            } else {
                state.position = leap.target
            }
            return
        }
        // Before the first picture, adopt no time at all: VLC's value still belongs
        // to the stream before the jump.
        guard state.firstImagePresent else { return }
        if let adopted = TimeAssumption.position(reported: reported,
                                                  untilFrom: state.position,
                                                  sinceStart: sinceStart,
                                                  afterChange: state.afterChange) {
            state.position = adopted
            state.afterChange = false
        }
    }

    /// How often the display follows VLC's time when the platform does so between
    /// two ticks. Swiftfin and Streamyfin receive VLC's time about four times a
    /// second; with a half-second tick the display started noticeably late after
    /// playing.
    public nonisolated static let displayTick: Duration = .milliseconds(250)

    /// One tick.
    ///
    /// - Parameters:
    ///   - restoring: A rebuild after a network change is in progress.
    ///     Then the last good position applies, not VLC's time, which sits at the
    ///     end of the file on a dead stream.
    ///   - atPush: The finger is on the slider. Possible only on the iPhone;
    ///     the TV passes `false`.
    /// **`nonisolated` like `tickLength`:** the Android facade calls the tick via JNI
    /// from a non-isolated context, where nobody serves the main queue; a hop to the
    /// main actor would hang. The computation itself touches only the state passed in.
    public nonisolated static func compute(_ state: inout Snapshot, measurement: Reading,
                        restoring: Bool,
                        atPush: Bool, sinceStart: Date,
                        now: Date = Date()) -> WorkItem {
        var job = WorkItem()

        state.duration = measurement.duration

        // The loading screen may go.
        if !state.firstImagePresent,
           TimeAssumption.imagePresent(showsImage: measurement.showsImage,
                              seeksToStart: measurement.seeksToStart,
                              sinceStart: sinceStart) {
            state.firstImagePresent = true
            job.loadingScreenGone = true
        }

        // The time: VLC's, except right after a jump (see there).
        timeAdopt(&state, reported: restoring ? measurement.goodPoint : measurement.position,
                        atPush: atPush, sinceStart: sinceStart, now: now)

        // Tracks only once VLC knows them; before that the lists are empty.
        if !state.tracksSet, state.firstImagePresent, measurement.hasAudioTracks {
            state.tracksSet = true
            job.tracksApply = true
            // **After an episode switch the start has already gone out**, without track
            // indices, since VLC did not know the tracks then. The next report carries
            // them; it therefore comes right away, not only after `reportSpacing`. On
            // opening, the start itself goes out after the tracks and does not need this.
            if state.startReported { state.sinceMessage = reportSpacing }
        }

        if state.firstImagePresent { state.running = measurement.running }

        // From here on it is only about the server, which wants to hear nothing
        // while nothing is playing.
        guard state.firstImagePresent, state.duration > 0 else { return job }

        // **Report only once a picture is actually showing.**
        //
        // The iPhone version used to call this right on opening. Then the server
        // already holds a session while VLC is still starting up; on the TV that takes
        // noticeably longer, and it showed there. The more cautious version became the
        // shared one.
        if !state.startReported {
            state.startReported = true
            job.startReport = true
            return job
        }

        state.sinceMessage += tickLength / .seconds(1)
        if state.sinceMessage >= reportSpacing {
            state.sinceMessage = 0
            job.progressReport = true
        }
        return job
    }
}
