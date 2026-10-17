import Foundation

/// **Between playback and Trakt, built so that Trakt never holds up playback.**
///
/// Platforms call ``report(_:)`` at exactly the points where they also tell Jellyfin:
/// start, pause and resume, seek, end. The call returns at once; sending happens in a queue
/// of its own.
///
/// **A queue, not individual tasks.** Dispatching each report as its own `Task` would let
/// "pause" arrive before "start", since task order is not guaranteed. An `AsyncStream`
/// keeps the order, and a single consumer works through it in sequence.
///
/// **Errors stay here.** No throw leaves this type: a report to Trakt that does not get
/// through is logged and forgotten. Jellyfin holds the user's state; Trakt is the extra.
///
/// What Trakt makes of it is Trakt's decision: a stop at 80% or more counts as watched,
/// below that as paused. So there is no 80% rule here and no `/sync/history`; both would
/// record the same title a second time.
public final class TraktReporter: Sendable {

    public enum AppEvent: Sendable {
        /// A title begins. `target` is only resolved in the queue; that costs two requests to
        /// the user's own server, which must hold up neither the player nor the main flow.
        case start(titleID: String, target: @Sendable () async -> TraktTarget?,
                   spot: Double, duration: Double)
        case runState(running: Bool, spot: Double)
        case leap(spot: Double)
        case stop(titleID: String, spot: Double)
    }

    private enum Record: Sendable {
        case event(AppEvent)
        case token(TraktToken?, identifier: String?)
        case mark(@Sendable () -> Void)
    }

    private let input: AsyncStream<Record>.Continuation

    /// - Parameters:
    ///   - geaendert: a token was renewed (new value) or is dead (`nil`). Comes with the ID
    ///     given when it was set, so a renewed token does not end up on the wrong account
    ///     after an account switch.
    ///   - protokoll: a line for the log, without the token in it.
    ///   - jetzt: for tests only.
    public init(client: TraktClient,
                changed: @escaping @Sendable (TraktToken?, String?) -> Void,
                log: @escaping @Sendable (String) -> Void,
                now: @escaping @Sendable () -> Date = { Date() }) {
        let (feed, input) = AsyncStream.makeStream(of: Record.self)
        self.input = input
        let worker = Worker(client: client, changed: changed,
                                log: log, now: now)
        Task {
            for await entryRecord in feed {
                switch entryRecord {
                case let .event(e):         await worker.process(e)
                case let .token(t, identifier):   await worker.setDown(t, identifier: identifier)
                case let .mark(done):       done()
                }
            }
        }
    }

    deinit { input.finish() }

    public func report(_ event: AppEvent) {
        input.yield(.event(event))
    }

    /// The token of the currently signed-in account, or `nil`. Goes through the same queue:
    /// a report that came before the switch still goes out with the old token.
    public func tokenSet(_ token: TraktToken?, identifier: String?) {
        input.yield(.token(token, identifier: identifier))
    }

    /// Returns when everything before it has been processed. For tests.
    public func processed() async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            input.yield(.mark { k.resume() })
        }
    }

    // MARK: - The consumer

    private actor Worker {
        let client: TraktClient
        let changed: @Sendable (TraktToken?, String?) -> Void
        let log: @Sendable (String) -> Void
        let now: @Sendable () -> Date

        var token: TraktToken?
        var identifier: String?
        /// What is currently playing, only if it could be matched to Trakt.
        var current: (titleID: String, target: TraktTarget, duration: Double)?
        var running = false
        var lastSent = Date.distantPast
        /// After a 429, stay quiet until then.
        var lockedUntil = Date.distantPast

        /// **A seek reports at most every 30 seconds.** Dragging the slider produces dozens
        /// of seeks, and Trakt answers a flood for the same title with 409 or 429.
        static let jumpSpacing: TimeInterval = 30

        init(client: TraktClient, changed: @escaping @Sendable (TraktToken?, String?) -> Void,
             log: @escaping @Sendable (String) -> Void, now: @escaping @Sendable () -> Date) {
            self.client = client
            self.changed = changed
            self.log = log
            self.now = now
        }

        func setDown(_ new: TraktToken?, identifier: String?) {
            token = new
            self.identifier = identifier
            if new == nil { current = nil }
        }

        func process(_ e: AppEvent) async {
            switch e {
            case let .start(titleID, resolve, spot, duration):
                current = nil
                // Not connected: resolve nothing, ask nothing.
                guard token != nil else { return }
                guard duration > 0 else {
                    log("ohne Laufzeit, nicht gemeldet \(titleID)")
                    return
                }
                guard let target = await resolve() else {
                    log("keine IMDb/TMDB/TVDB-Kennung, nicht gemeldet \(titleID)")
                    return
                }
                current = (titleID, target, duration)
                running = true
                await dispatch(.start, spot: spot)
            case let .runState(new, spot):
                guard current != nil, new != running else { return }
                running = new
                await dispatch(new ? .start : .pause, spot: spot)
            case let .leap(spot):
                guard current != nil,
                      now().timeIntervalSince(lastSent) >= Self.jumpSpacing else { return }
                await dispatch(running ? .start : .pause, spot: spot)
            case let .stop(titleID, spot):
                // Only end the title that is running here; on an episode change a late stop
                // must not hit the new episode.
                guard let a = current, a.titleID == titleID else { return }
                await dispatch(.stop, spot: spot)
                current = nil
                running = false
            }
        }

        private func dispatch(_ step: TraktClient.Step, spot: Double) async {
            guard let current, var t = token else { return }
            let now = now()
            guard now >= lockedUntil else {
                log("\(step.rawValue) übergangen, Trakt bremst noch")
                return
            }
            lastSent = now
            if t.renewDue(now: now) {
                guard let new = await renew(t) else {
                    if token == nil { return }
                    // Failed temporarily: carry on with the old one, which is valid for up
                    // to an hour.
                    return await attemptTo(step, current, spot, t, anotherTime: true)
                }
                t = new
            }
            await attemptTo(step, current, spot, t, anotherTime: true)
        }

        private func attemptTo(_ step: TraktClient.Step,
                               _ a: (titleID: String, target: TraktTarget, duration: Double),
                               _ spot: Double, _ t: TraktToken, anotherTime: Bool) async {
            let progress = spot / a.duration * 100
            do {
                try await client.report(step, target: a.target, progress: progress, token: t.access)
                log("\(step.rawValue) \(Int(progress)) % \(a.titleID)")
            } catch TraktError.status(401) where anotherTime {
                // Expired although the clock thought otherwise: renew once and resend.
                guard let new = await renew(t) else { return }
                await attemptTo(step, a, spot, new, anotherTime: false)
            } catch let TraktError.rateLimit(to) {
                lockedUntil = now().addingTimeInterval(to ?? 60)
                log("\(step.rawValue): Trakt bremst (429), \(Int(to ?? 60)) s Pause")
            } catch {
                log("\(step.rawValue) nicht durch: \(error)")
            }
        }

        /// `nil` means not renewed. If access is dead, ``token`` is `nil` afterwards too,
        /// and the app learns of it through `geaendert`.
        private func renew(_ t: TraktToken) async -> TraktToken? {
            do {
                let new = try await client.renew(t)
                token = new
                changed(new, identifier)
                log("Token erneuert")
                return new
            } catch TraktError.signedOut {
                token = nil
                current = nil
                changed(nil, identifier)
                log("Zugang abgelaufen, getrennt")
                return nil
            } catch {
                log("Erneuern nicht durch: \(error)")
                return nil
            }
        }
    }
}
