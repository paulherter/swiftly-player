import Foundation

/// Reports to the server: **dispatched, not awaited.**
///
/// The tick loop called `await reportProgress(…)` and waited for the answer.
/// While it waited, the timeline did not advance, the jump latch did not fall,
/// and the next episode did not switch. Without network that was up to 20
/// seconds (`Netzsitzung`), at the start with the capabilities before it up to
/// 40.
///
/// **What is guaranteed here:**
///
/// 1. `report` returns immediately. Nobody waits who does not explicitly say
///    `reportAndWait`; only the end does, because the pages reload after it.
/// 2. **One queue for all reports**, sent in the order they were enqueued.
///    Start → progress → stop stays that way even if the start is slow; so does
///    stop of the old episode → start of the new one.
/// 3. **Progress is coalesced.** If an unsent progress for the same session is
///    the last entry, it is dropped and the new one goes to the end. Without
///    network nothing piles up: at most one progress per session is waiting.
///    A stop takes the unsent progress of its session with it, since it carries
///    the position itself.
/// 4. **Every report has a deadline.** After it, the report is cancelled and the
///    next one goes. An error holds nothing up.
/// 5. **The stop guard sits here**, not next to it: stop exactly once per
///    PlaySession, progress after it discarded, start and failed stop release.
///    It is checked on enqueueing, so the guard already applies to a stop still
///    waiting in the queue.
///
/// **Not bound to `@MainActor`**, for the same reason as `EpisodeSwitch`:
/// Android calls via JNI without a main queue. The state sits behind a lock,
/// and sending happens on the global executor. The caller knows what is sent;
/// the queue knows only kind, session and a payload.
public final class ReportQueue<Payload: Sendable>: @unchecked Sendable {

    public enum Art: Sendable, Equatable {
        case start
        case progress(paused: Bool)
        case stop
    }

    public struct Message: Sendable {
        public let art: Art
        /// `StopLock.key(itemID:playSessionID:)`.
        public let key: String
        public let payload: Payload

        public init(art: Art, key: String, payload: Payload) {
            self.art = art
            self.key = key
            self.payload = payload
        }
    }

    public enum Outcome: Sendable, Equatable {
        case sent
        case failed
        case timeOverStep
        /// Never sent: progress after the stop, a double stop, or a progress that the
        /// stop of its session took with it.
        case discarded
    }

    /// Six seconds: a reachable server answers in a fraction of that. Whoever takes
    /// longer is unreachable for this report; the next one tries again, and the end
    /// goes into the late report.
    public static var preGiftDeadline: Duration { .seconds(6) }

    private final class Record {
        let message: Message
        var waitingOnes: [CheckedContinuation<Outcome, Never>]
        init(_ message: Message, waitingOnes: [CheckedContinuation<Outcome, Never>]) {
            self.message = message
            self.waitingOnes = waitingOnes
        }
    }

    private let lock = NSLock()
    private var opened: [Record] = []
    private var works = false
    private let barrier = StopLock()
    private let deadline: Duration
    private let dispatch: @Sendable (Message) async throws -> Void

    public init(deadline: Duration = preGiftDeadline,
                dispatch: @escaping @Sendable (Message) async throws -> Void) {
        self.deadline = deadline
        self.dispatch = dispatch
    }

    /// Enqueue and return at once. `false`: discarded (see `Outcome`).
    @discardableResult
    public func report(_ message: Message) -> Bool {
        inRails(message, waiting: nil)
    }

    /// Enqueue and wait until exactly this report is through, or its deadline has
    /// passed. If a waiting progress is replaced by a newer one, the result of the
    /// newer one applies.
    public func reportAndWait(_ message: Message) async -> Outcome {
        await withCheckedContinuation { continuation in
            if !inRails(message, waiting: continuation) {
                continuation.resume(returning: .discarded)
            }
        }
    }

    /// May progress still be reported for this session?
    public func progressAllowed(_ key: String) -> Bool {
        barrier.progressAllowed(key)
    }

    // MARK: Internals

    /// Returns `false` without having kept `waiting`.
    private func inRails(_ message: Message,
                           waiting: CheckedContinuation<Outcome, Never>?) -> Bool {
        var carried: [CheckedContinuation<Outcome, Never>] = []
        let (accepted, trigger) = withLock { () -> (Bool, Bool) in
            var waitingOnes = waiting.map { [$0] } ?? []
            let lastOne = opened.lastIndex { $0.message.key == message.key }
            let lastIsProgress = lastOne.map {
                if case .progress = opened[$0].message.art { return true }
                return false
            } ?? false

            switch message.art {
            case .start:
                barrier.started(message.key)
            case .progress:
                guard barrier.progressAllowed(message.key) else { return (false, false) }
                if lastIsProgress, let lastOne {
                    waitingOnes = opened[lastOne].waitingOnes + waitingOnes
                    opened.remove(at: lastOne)
                }
            case .stop:
                guard barrier.stopAccept(message.key) else { return (false, false) }
                if lastIsProgress, let lastOne {
                    carried = opened[lastOne].waitingOnes
                    opened.remove(at: lastOne)
                }
            }
            opened.append(Record(message, waitingOnes: waitingOnes))
            guard !works else { return (true, false) }
            works = true
            return (true, true)
        }
        for continuation in carried { continuation.resume(returning: .discarded) }
        if trigger {
            Task { await self.offWork() }
        }
        return accepted
    }

    private func offWork() async {
        while let entryRecord = nextOne() {
            let result = await withDeadline(entryRecord.message)
            if result != .sent, entryRecord.message.art == .stop {
                // Release, so that a later stop tries again.
                barrier.stopFailed(entryRecord.message.key)
            }
            for continuation in entryRecord.waitingOnes { continuation.resume(returning: result) }
        }
    }

    private func nextOne() -> Record? {
        withLock {
            guard !opened.isEmpty else {
                works = false
                return nil
            }
            return opened.removeFirst()
        }
    }

    /// Send against the deadline. **Unstructured on purpose:** a task group waits
    /// for all children at the end; if sending did not honor cancellation, the
    /// queue would stall anyway.
    private func withDeadline(_ message: Message) async -> Outcome {
        let inTimes = InTimes()
        let dispatch = self.dispatch
        let deadline = self.deadline
        let labor = Task {
            do {
                try await dispatch(message)
                inTimes.give(.sent)
            } catch {
                inTimes.give(.failed)
            }
        }
        let alarm = Task {
            do { try await Task.sleep(for: deadline) } catch { return }
            if inTimes.give(.timeOverStep) { labor.cancel() }
        }
        let result = await inTimes.wait()
        alarm.cancel()
        return result
    }

    private func withLock<T>(_ perform: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return perform()
    }

    /// The first result wins, answer or deadline.
    private final class InTimes: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Outcome?
        private var continuation: CheckedContinuation<Outcome, Never>?

        @discardableResult
        func give(_ new: Outcome) -> Bool {
            lock.lock()
            guard result == nil else { lock.unlock(); return false }
            result = new
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: new)
            return true
        }

        func wait() async -> Outcome {
            await withCheckedContinuation { new in
                lock.lock()
                if let result {
                    lock.unlock()
                    new.resume(returning: result)
                } else {
                    continuation = new
                    lock.unlock()
                }
            }
        }
    }
}
