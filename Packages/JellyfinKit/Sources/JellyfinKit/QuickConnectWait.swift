import Foundation

/// **Waiting for a Quick Connect approval, once for all platforms.**
///
/// Used to differ three ways: Apple gave up at the first network error, Linux
/// counted every error as "not yet approved" and kept running after leaving,
/// Android had the rule right, but in Kotlin. The rule is Android's:
///
/// - **Deadline on the clock**, not counted rounds. While typing in the browser
///   the app is in the background; back in the app the remaining time is right.
/// - **Ask immediately after returning.** The clock ticks every second; if a
///   beat has passed since the last request, it asks, so right at the first
///   tick after waking.
/// - **A network error does not end the wait** (``Quickconnectstand/gescheitert``).
///   Only approval, an expired code (404) or the deadline do.
/// - **Cancelling ends everything.** Whoever no longer reads the stream (view
///   closed, task cancelled) also stops asking; otherwise a late approval logs
///   someone in unexpectedly.
public enum QuickConnectWait {

    public enum AppEvent: Sendable, Equatable {
        /// Seconds until the deadline, once per second.
        case rest(Int)
        /// The code is approved; now `signInWithQuickConnect`.
        case released
        /// The wait is over without approval. The sentence comes from
        /// ``Quickconnectfrist/schlusstext(letzte:)``.
        case end(last: QuickConnectState)
    }

    /// - Parameters:
    ///   - deadline, pollInterval, tick: different from ``Quickconnectfrist`` only for tests.
    ///   - nachfragen: one request that never throws; in the app
    ///     ``JellyfinClient/quickConnectAskAgain(_:)``.
    public static func flow(
        deadline: Duration = .seconds(QuickConnectDeadline.seconds),
        pollInterval: Duration = .seconds(QuickConnectDeadline.tick),
        tick: Duration = .seconds(1),
        again: @escaping @Sendable () async -> QuickConnectState
    ) -> AsyncStream<AppEvent> {
        AsyncStream { feed in
            let task = Task {
                let clock = ContinuousClock()
                let end = clock.now + deadline
                var lastQuery = clock.now
                var last = QuickConnectState.opened
                feed.yield(.rest(remainingSecondsOf(end - clock.now)))
                while !Task.isCancelled {
                    try? await Task.sleep(for: tick, clock: clock)
                    if Task.isCancelled { break }
                    let now = clock.now
                    let rest = remainingSecondsOf(end - now)
                    guard rest > 0 else {
                        feed.yield(.end(last: last == .failed ? .failed : .expired))
                        break
                    }
                    feed.yield(.rest(rest))
                    guard now - lastQuery >= pollInterval else { continue }
                    lastQuery = now
                    last = await again()
                    if Task.isCancelled { break }
                    if last == .released { feed.yield(.released); break }
                    if last == .expired { feed.yield(.end(last: .expired)); break }
                }
                feed.finish()
            }
            feed.onTermination = { _ in task.cancel() }
        }
    }

    /// Rounded up: "0:01" shows until the deadline has really passed.
    static func remainingSecondsOf(_ d: Duration) -> Int {
        let (s, atto) = d.components
        guard s >= 0, s > 0 || atto > 0 else { return 0 }
        return Int(s) + (atto > 0 ? 1 : 0)
    }
}

extension JellyfinClient {
    /// Waits for the approval of `preGait` per ``Quickconnectwarten``.
    public nonisolated func quickConnectWait(_ preGait: LoginCode) -> AsyncStream<QuickConnectWait.AppEvent> {
        QuickConnectWait.flow { await self.quickConnectAskAgain(preGait) }
    }
}
