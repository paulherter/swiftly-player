import Foundation
import Observation
import Synchronization

/// A `SyncPlayHost` over two closures (the player lives in the app, so the app says what to do).
public final class ClosureSyncPlayHost: SyncPlayHost {
    private let step: @Sendable (SyncPlayStep) -> Void
    private let load: @Sendable (String, Double) -> Void

    public init(
        step: @escaping @Sendable (SyncPlayStep) -> Void, loadTitle: @escaping @Sendable (String, Double) -> Void
    ) {
        self.step = step
        self.load = loadTitle
    }

    public func playerStep(step: SyncPlayStep) { self.step(step) }
    public func loadTitle(title: String, since: Double) { load(title, since) }
}

/// The `@MainActor @Observable` adapter of `SyncPlayModel`: `page` is what the sheet draws, the
/// intent helpers forward to the core. Run `observe()` from a `.task`; feed it the `syncPlay` events
/// of the `RemoteController` (`RemoteController.bind(syncPlay:)` does that).
@MainActor
@Observable
public final class SyncPlayController {
    public private(set) var page: SyncPlayPage

    @ObservationIgnored private let model: SyncPlayModel
    @ObservationIgnored private var seen: UInt64

    public init(model: SyncPlayModel) {
        self.model = model
        let first = model.page()
        self.page = first
        self.seen = first.version
    }

    public func refresh() { model.refresh() }
    /// The "continue here" tick: the groups on offer only.
    public func offeringsAsk() { model.offeringsAsk() }
    public func create(name: String, titleId: String) { model.create(name: name, titleId: titleId) }
    public func join(_ groupId: String) { model.join(groupId: groupId) }
    public func rejoin() { model.rejoin() }
    public func leave() { model.leave() }
    public func dismissError() { model.dismissError() }
    public func finish() { model.finish() }

    /// A raw `RemoteEvent.syncPlay` text.
    public func feed(_ text: String) { model.feed(text: text) }
    public func linkLost() { model.linkLost() }
    public func linkAgain() { model.linkAgain() }

    public func playerAttached(_ player: SyncPlayPlayer) { model.playerAttached(player: player) }
    public func playerUpdate(_ player: SyncPlayPlayer) { model.playerUpdate(player: player) }
    public func playerDetached() { model.playerDetached() }
    public func playerTick() { model.playerTick() }
    public func requestToggle(runningNow: Bool) { model.requestToggle(runningNow: runningNow) }
    public func requestJump(_ seconds: Double) { model.requestJump(seconds: seconds) }
    public func requestTitle(_ title: String, since: Double) { model.requestTitle(title: title, since: since) }
    public func titleLoadFailed() { model.titleLoadFailed() }

    public var offsetSeconds: Double { model.offsetSeconds() }
    public var pingMilliseconds: Int64 { model.pingMilliseconds() }

    /// Returns when the calling Task is cancelled (or the model is gone).
    public func observe() async {
        while !Task.isCancelled {
            do {
                seen = try await model.changed(seen: seen)
                page = model.page()
            } catch {
                return  // cancelled
            }
        }
    }
}

/// The host's WebSocket over `URLSessionWebSocketTask`. One object serves all reconnects: `connect` replaces
/// the socket behind it. Text frames come out of `receive`, binary frames come out as `nil` (skipped).
public final class URLSessionWebSocketLink: WebSocketLink {
    private let session: URLSession
    private let task = Mutex<URLSessionWebSocketTask?>(nil)

    public init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    public func connect(url: String) async throws {
        guard let address = URL(string: url) else { throw SocketFailure.Other(message: "bad address") }
        let next = session.webSocketTask(with: address)
        task.withLock { current in
            current?.cancel(with: .goingAway, reason: nil)
            current = next
        }
        next.resume()
        // A ping only comes back once the upgrade went through.
        do {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                // URLSession can call the pong handler twice when the task is cancelled meanwhile (a replaced or
                // closed socket); a second resume traps, so only the first answer counts.
                let answered = Mutex(false)
                next.sendPing { error in
                    let first = answered.withLock { was -> Bool in
                        defer { was = true }
                        return !was
                    }
                    guard first else { return }
                    if let error { done.resume(throwing: error) } else { done.resume() }
                }
            }
        } catch {
            let code = (next.response as? HTTPURLResponse)?.statusCode ?? 0
            next.cancel(with: .goingAway, reason: nil)
            throw SocketFailure.SetupFailed(code: Int32(code))
        }
    }

    public func receive() async throws -> String? {
        guard let current = task.withLock({ $0 }) else { throw SocketFailure.Other(message: "closed") }
        do {
            switch try await current.receive() {
            case .string(let text): return text
            case .data: return nil
            @unknown default: return nil
            }
        } catch {
            throw SocketFailure.Other(message: error.localizedDescription)
        }
    }

    public func send(text: String) async throws {
        guard let current = task.withLock({ $0 }) else { throw SocketFailure.Other(message: "closed") }
        do { try await current.send(.string(text)) } catch {
            throw SocketFailure.Other(message: error.localizedDescription)
        }
    }

    public func close() {
        task.withLock { current in
            current?.cancel(with: .goingAway, reason: nil)
            current = nil
        }
    }
}

/// Turns the listener callbacks into a stream of events (from the core's task, never blocking).
final class RemoteEventBridge: RemoteListener {
    let events: AsyncStream<RemoteEvent>
    private let continuation: AsyncStream<RemoteEvent>.Continuation
    private let up: @Sendable () -> Void

    init(connected: @escaping @Sendable () -> Void) {
        (events, continuation) = AsyncStream.makeStream(of: RemoteEvent.self, bufferingPolicy: .unbounded)
        up = connected
    }

    func event(event: RemoteEvent) { continuation.yield(event) }
    func connected() { up() }
    func finish() { continuation.finish() }
}

/// The `@MainActor @Observable` adapter of `RemoteChannel`: `start()` connects and reconnects, `events` carries
/// commands, play orders, takeover hints and SyncPlay messages. `isConnected` follows the link.
@MainActor
@Observable
public final class RemoteController {
    /// The link is up (after `connected`, until a loss or a stop).
    public private(set) var isConnected = false
    /// Everything the channel says. One consumer.
    @ObservationIgnored public let events: AsyncStream<RemoteEvent>

    @ObservationIgnored private let channel: RemoteChannel
    @ObservationIgnored private let bridge: RemoteEventBridge
    @ObservationIgnored private var pump: Task<Void, Never>?

    /// - Parameter onConnected: the link is up; the host sends `POST Sessions/Capabilities/Full` now.
    public init(
        core: Core, account: AccountRef, link: any WebSocketLink = URLSessionWebSocketLink(),
        onConnected: @escaping @Sendable () -> Void = {}
    ) throws {
        let bridge = RemoteEventBridge(connected: onConnected)
        self.bridge = bridge
        self.channel = try core.remoteChannel(account: account, link: link, listener: bridge)
        let (mine, continuation) = AsyncStream.makeStream(of: RemoteEvent.self, bufferingPolicy: .unbounded)
        self.events = mine
        let source = bridge.events
        pump = Task { @MainActor [weak self] in
            for await event in source {
                switch event {
                case .connectionLost, .givenUp: self?.isConnected = false
                case .connectionAgain: self?.isConnected = true
                default: break
                }
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    public func start() {
        channel.start()
        isConnected = true
    }

    public func stop() {
        channel.stop()
        isConnected = false
    }

    public var isRunning: Bool { channel.isRunning() }

    /// Forwards the SyncPlay messages and link changes of this channel to a SyncPlay controller; returns
    /// the pump Task (cancel it with the session).
    public static func bind(_ remote: RemoteController, syncPlay: SyncPlayController) -> Task<Void, Never> {
        let events = remote.events
        return Task { @MainActor in
            for await event in events {
                switch event {
                case .syncPlay(let text): syncPlay.feed(text)
                case .connectionLost: syncPlay.linkLost()
                case .connectionAgain: syncPlay.linkAgain()
                default: break
                }
            }
        }
    }

    deinit {
        pump?.cancel()
        bridge.finish()
    }
}
