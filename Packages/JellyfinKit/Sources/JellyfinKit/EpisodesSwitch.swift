import Foundation

/// The switch to the next episode in the running player: **one** flow for all
/// platforms.
///
/// It used to be written by hand three times in the Apple players (iOS, tvOS,
/// macOS) and drifted apart: on the TV without a latch, so a second press
/// started a second switch and two sessions stayed open on the server;
/// everywhere without cancellation, so after closing, the next episode started
/// invisibly with sound.
///
/// **What is here is the order of steps, not the presentation.**
///
/// 1. Latch: one switch at a time. A second trigger returns `.locked` and
///    does nothing.
/// 2. Stop the old session and fetch the new plan, **side by side**; on a dead
///    network that is the longer of the two timeouts, not their sum.
///    From here on `messagesAllowed == false`: the tick loop is silent,
///    otherwise progress for the old episode would still go out after the stop.
/// 3. No plan: `failed`. The platform shows a notice, the old episode
///    keeps running and is reported as started again.
/// 4. Closed while step 2 ran: `.cancelled`, and **nothing** is applied. The
///    surface has already been torn down; a `play` on it produced sound
///    without picture.
/// 5. `anwenden` resets all episode state of the platform and starts the
///    stream, then the start is reported.
/// 6. Closed while the start was in flight: the stop for the new episode is
///    sent **after** the start, not before. Otherwise the late start would
///    reopen the session, and it would stay open.
///
/// Then the latch falls. Next episode and sections come through `lookUp`,
/// without the latch, so no key press waits for them.
///
/// **Isolation from the caller.** `ausfuehren` runs on the actor it is called
/// from (`#isolation`): on Apple the main actor, so `anwenden` and `close`
/// never interleave. Android calls through JNI without a main queue; therefore
/// the type is **not** bound to `@MainActor`, and the state sits behind a lock.
public final class EpisodeSwitch: @unchecked Sendable {

    public enum Phase: Equatable, Sendable {
        case rests
        /// The old session is being stopped, the new plan fetched.
        case stopAndPlant
        /// The new episode is applied, its start in flight.
        case starts
        /// The player is closed. Final.
        case closed
    }

    public enum Outcome: Equatable, Sendable {
        case switched
        /// A switch was already running.
        case locked
        /// The player was closed.
        case cancelled
        /// No plan for the new episode.
        case failed
    }

    /// What the platform contributes.
    ///
    /// The calls are `@Sendable`: they run side by side. `anwenden` and
    /// `failed` run on the caller's actor and may touch its state.
    public struct Steps<Plan: Sendable> {
        /// End the old session. The stop guard sits behind it (`StopLock`); a
        /// second stop of the same session is dropped there.
        public var stopNow: @Sendable () async -> Void
        public var planOut: @Sendable () async -> Plan?
        /// Set title and plan, reset episode state, play.
        public var apply: (Plan) -> Void
        public var start: @Sendable (Plan) async -> Void
        public var failed: () -> Void

        public init(stopNow: @escaping @Sendable () async -> Void,
                    planOut: @escaping @Sendable () async -> Plan?,
                    apply: @escaping (Plan) -> Void,
                    start: @escaping @Sendable (Plan) async -> Void,
                    failed: @escaping () -> Void) {
            self.stopNow = stopNow
            self.planOut = planOut
            self.apply = apply
            self.start = start
            self.failed = failed
        }
    }

    private let lock = NSLock()
    private var _phase: Phase = .rests
    /// Counts every switch begun; a lookup applies only to the switch after
    /// which it was fetched.
    private var _counter = 0
    private var deferredStop: (@Sendable () async -> Void)?

    public init() {}

    private func withLock<T>(_ perform: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return perform()
    }

    public var phase: Phase { withLock { _phase } }

    /// The latch is held.
    public var running: Bool {
        withLock { _phase == .stopAndPlant || _phase == .starts }
    }

    /// May the tick loop report start and progress? Only when idle.
    public var messagesAllowed: Bool { withLock { _phase == .rests } }

    /// The switch.
    public func execute<Plan: Sendable>(
        _ steps: Steps<Plan>,
        isolation: isolated (any Actor)? = #isolation
    ) async -> Outcome {
        let begun = withLock { () -> Bool in
            guard _phase == .rests else { return false }
            _phase = .stopAndPlant
            _counter += 1
            return true
        }
        guard begun else { return .locked }

        let stopNow = steps.stopNow
        let planOut = steps.planOut
        async let stopped: Void = stopNow()
        async let planned = planOut()
        // Stop before start is preserved: the start happens only below.
        await stopped
        let plan = await planned

        let proceed = withLock { () -> Bool? in
            guard _phase == .stopAndPlant else { return nil }
            _phase = plan == nil ? .rests : .starts
            return plan != nil
        }
        guard let proceed else { return .cancelled }
        guard proceed, let plan else {
            steps.failed()
            return .failed
        }

        steps.apply(plan)
        await steps.start(plan)

        let caughtUp = withLock { () -> (@Sendable () async -> Void)? in
            if _phase == .starts { _phase = .rests }
            defer { deferredStop = nil }
            return deferredStop
        }
        if let caughtUp {
            await caughtUp()
            return .cancelled
        }
        return .switched
    }

    /// The player closes. `stopNow` reports the end of what is running **now**;
    /// if its start is still in flight, only after that.
    ///
    /// Only the first call counts; a second one (for example from `onDisappear`
    /// after a close button of its own) does nothing.
    public func close(stopNow: @escaping @Sendable () async -> Void) {
        let immediate = withLock { () -> Bool? in
            let before = _phase
            guard before != .closed else { return nil }
            _phase = .closed
            if before == .starts {
                deferredStop = stopNow
                return false
            }
            return true
        }
        if immediate == true { Task { await stopNow() } }
    }

    /// Fetches something for the running episode afterwards (next episode,
    /// sections) and applies it only if no switch has begun since and the player
    /// is open. Otherwise "Next episode" would briefly point to the episode that
    /// is currently playing.
    public func lookUp<Amount: Sendable>(
        fetch: @Sendable () async -> Amount,
        adopt: (Amount) -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async {
        let mark = withLock { _counter }
        let value = await fetch()
        let applies = withLock { _counter == mark && _phase != .closed }
        guard applies else { return }
        adopt(value)
    }
}

/// Stop guard per PlaySession: `Sessions/Playing/Stopped` exactly once.
///
/// On the switch and on close, two places report the same end; without the
/// guard it arrived twice, and progress after it reopened the session on the
/// server.
///
/// - A start releases the session again.
/// - A failed stop releases it, so that a later one can try again.
/// - After the stop, progress is discarded.
public final class StopLock: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped: Set<String> = []

    public init() {}

    /// Without a PlaySession (from disk), the title stands in for the session.
    public static func key(itemID: String, playSessionID: String?) -> String {
        if let playSessionID { return "sitzung:" + playSessionID }
        return "titel:" + itemID
    }

    public func started(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        stopped.remove(key)
    }

    /// `true`: this call reports the stop. `false`: already reported or in
    /// flight; send nothing.
    public func stopAccept(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped.insert(key).inserted
    }

    public func stopFailed(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        stopped.remove(key)
    }

    public func progressAllowed(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped.contains(key)
    }
}
