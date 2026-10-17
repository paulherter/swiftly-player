import Foundation

// MARK: - What the platform attaches

/// **What the player provides for "Watch together".**
///
/// Each platform attaches its player here: VLCKit on Apple, libVLC on Linux and
/// Windows, and on Android the core, which passes the steps on to Kotlin. The
/// session always reads **the current state** (`title`, `ready`, `spot`)
/// instead of being handed it once: a closure that captures a SwiftUI view
/// reads its state from back then.
public protocol SyncPlayPlayer: AnyObject, Sendable {
    /// Which title is playing right now (Jellyfin ID).
    func title() async -> String
    /// Is the picture up, and is no title being switched right now?
    func ready() async -> Bool
    func spot() async -> Double
    func proceed() async
    func halt() async
    /// Seeks and updates timeline and button right away.
    func jump(_ target: Double) async
}

/// A short notice at the top of the player: who came, who left, why the film
/// stopped. The text comes from the package, the platform picks the icon.
public struct SyncPlayEvent: Sendable, Equatable, Identifiable {
    public enum Art: Sendable, Equatable {
        case present(String)
        case gone(String)
        case waitsOnAll
        case halted
        case goesNext
        case jumped
        case noAccess
        case notPlayable
    }

    public let id: UUID
    public let art: Art

    public init(_ art: Art) {
        self.id = UUID()
        self.art = art
    }

    public var text: String {
        switch art {
        case let .present(name): return translated("\(name) ist dabei")
        case let .gone(name): return translated("\(name) ist gegangen")
        case .waitsOnAll: return translated("Wartet auf alle")
        case .halted: return translated("Angehalten")
        case .goesNext: return translated("Geht weiter")
        case .jumped: return translated("Gesprungen")
        case .noAccess: return translated("Einem in der Gruppe fehlt dieser Titel.")
        case .notPlayable: return translated("Der Titel der Gruppe lässt sich hier nicht abspielen.")
        }
    }
}

/// What went wrong, as a message for the view.
public enum SyncPlayError: Error, Sendable {
    /// 403: the operator has not enabled it for this account.
    case notReleased
    /// Called, but nothing came back over the control channel.
    case noResponse
    case doesNotExist
    /// The connection dropped and rejoining failed.
    case connectionLost
    case other(any Error & Sendable)

    public var text: String {
        switch self {
        case .notReleased:
            return translated("Gemeinsam schauen ist für dein Konto auf dem Server nicht freigegeben.")
        case .noResponse:
            return translated("Die Gruppe kam nicht zustande: vom Server kam keine Antwort über die Verbindung. Versuch es gleich noch einmal.")
        case .doesNotExist:
            return translated("Diese Gruppe gibt es nicht mehr.")
        case .connectionLost:
            return translated("Die Verbindung zur Gruppe ist abgerissen und ließ sich nicht wiederherstellen. Tritt der Gruppe bitte erneut bei.")
        case let .other(error):
            return readableError(error)
        }
    }

    static func from(_ error: any Error) -> SyncPlayError {
        if case let JellyfinError.http(status, _) = error, status == 403 { return .notReleased }
        return .other(error as? JellyfinError ?? JellyfinError.transport(String(describing: error)))
    }
}

/// **Everything the UI shows of the group**, the same on every platform. After
/// every change a new one arrives via ``SyncPlayExecution/mitteilungen``.
public struct SyncPlayStatus: Sendable, Equatable {
    /// `nil` until the server has said something; then it decides itself at the
    /// call.
    public var rights: SyncPlayRight?
    /// Groups on the server that you are not in.
    public var offerings: [SyncPlayGroup] = []
    /// The group you are in.
    public var group: SyncPlayGroup?
    public var condition: SyncPlayGroup.Phase?
    /// For three seconds, then `nil` again.
    public var event: SyncPlayEvent?
    /// For the strip "... left · Rejoin", eight seconds long.
    public var lastLeave: SyncPlayGroup?
    /// Creating or joining is in progress.
    public var works = false
    /// What the group is currently watching (Jellyfin ID).
    public var queueTitle: String?

    public init() {}

    public var mayCreate: Bool { rights?.mayCreate ?? true }
    public var mayJoin: Bool { rights?.mayJoin ?? true }

    /// Does this title belong to what the group is watching?
    public func belongsGroup(_ title: String) -> Bool {
        group != nil && queueTitle == title
    }
}

public enum SyncPlayMessage: Sendable {
    case status(SyncPlayStatus)
    case error(SyncPlayError)
}

// MARK: - The session

/// **Watch together, the same logic on every platform.**
///
/// The computation lives alongside (``SyncPlayExecution``, ``Zeitabgleich``,
/// ``Pufferwaechter``). Here is the flow: create a group, join, leave, measure
/// the clock, accept the queue, give commands to the player at the scheduled
/// time, report buffering and readiness.
///
/// It lives in the package so every platform does not rebuild it and
/// rediscover the loop (seek to correct drift, then buffering, then everyone
/// pauses) on its own.
///
/// **What the platform does:** pass in the control channel's messages
/// (``annehmen(_:)``), attach the player (``anschliessen(_:)``), give it the
/// tick (``spielertakt()``), forward requests, and load a title when the group
/// sets one (`titleLoad`: switch in the open player, otherwise open the player;
/// `false` if it cannot be played here). What it shows comes as
public actor SyncPlaySession {

    public typealias ClientSource = @Sendable () async -> JellyfinClient?
    public typealias NamesSource = @Sendable () async -> String?
    public typealias TitleLoader = @Sendable (_ title: String, _ since: Double) async -> Bool

    public nonisolated let withPart: AsyncStream<SyncPlayMessage>
    private let output: AsyncStream<SyncPlayMessage>.Continuation

    private let clientSource: ClientSource
    private let ichSource: NamesSource
    private let titleLoad: TitleLoader

    public private(set) var status = SyncPlayStatus() {
        didSet { if status != oldValue { output.yield(.status(status)) } }
    }

    private var clock: Task<Void, Never>?
    private var planned: Task<Void, Never>?
    private var load: Task<Void, Never>?
    private var eventClock: Task<Void, Never>?
    private var leaveClock: Task<Void, Never>?

    public private(set) var reconcile = TimeReconcile()
    private var queue: SyncPlayQueue?
    private var lastCommand: SyncPlayCommand?
    private var buffer = BufferGuard()
    /// Has the player reported "ready" for the current entry? Before that,
    /// commands are only remembered.
    private var loadedFor: String?
    private var loadedSince = Date.distantPast
    private var lastJumpTarget: Double?
    /// When you last asked for something yourself: no strip is needed then, you
    /// know why the film stopped.
    private var lastRequested = Date.distantPast

    private var player: (any SyncPlayPlayer)?
    private var commandNumber = 0
    /// The group the connection dropped us from, until rejoining worked or finally
    /// failed.
    private var lostOut: SyncPlayGroup?
    private var againEntry: Task<Void, Never>?
    private var lineDeadline: Task<Void, Never>?
    /// How long to wait for the reconnect after a drop, how often, and how long for
    /// the join. Shorter for tests.
    var patience = (conduit: 60.0, attempts: 3, answer: 5.0, pause: 2.0)
    func patienceSet(conduit: Double, attempts: Int, answer: Double, pause: Double) {
        patience = (conduit, attempts, answer, pause)
    }
    private let input: AsyncStream<SyncPlayPostDirection>.Continuation

    public init(client: @escaping ClientSource, ich: @escaping NamesSource,
                titleLoad: @escaping TitleLoader) {
        clientSource = client
        ichSource = ich
        self.titleLoad = titleLoad
        (withPart, output) = AsyncStream.makeStream(of: SyncPlayMessage.self)
        let (nachrichten, input) = AsyncStream.makeStream(of: SyncPlayPostDirection.self)
        self.input = input
        // **One queue, one order.** The control channel calls from its own thread; a
        // `Task` per message would arrive in arbitrary order, and "joined" after the
        // queue would mean the title never loads.
        Task { [weak self] in
            for await n in nachrichten { await self?.process(n) }
        }
    }

    deinit {
        input.finish()
        output.finish()
    }

    /// Is the player currently running in the group?
    public var inPlayer: Bool { status.group != nil && player != nil }

    private func sag(_ text: String) { TrackSupport.sag("[Gemeinsam] " + text) }

    private func fail(_ f: SyncPlayError) {
        sag("Fehler: \(f)")
        output.yield(.error(f))
    }

    // MARK: Start and end

    /// The account's right, once after login.
    public func rightFetch() async {
        guard let client = await clientSource() else { return }
        status.rights = await client.syncPlayRight()
    }

    /// Ask for groups once. On the platform's tick, and not while the player runs.
    public func offeringsAsk() async {
        guard status.mayJoin, let client = await clientSource() else { return }
        do {
            let all = try await client.syncPlayGroups()
            status.offerings = all.filter { $0.id != status.group?.id }
        } catch {
            // Quiet outwardly, as with the handover: asking happens on the tick.
            if !status.offerings.isEmpty { sag("Abfrage fehlgeschlagen: \(error)") }
            status.offerings = []
        }
    }

    /// On logout and account switch: leave the group, forget everything.
    ///
    /// `oldClient` is the client of the account being left. **Leaving uses it**,
    /// not the one `client` now returns; otherwise the `Leave` would go out in the
    /// new account's name and the old one would stay in the group.
    public func finish(oldClient: JellyfinClient? = nil) {
        if status.group != nil { leave(remember: false, with: oldClient) }
        // **The timers too.** `leave` only stops the group; the strip timer and the
        // event timer kept running, and the new account saw "Rejoin" for the old
        // account's group for up to eight seconds.
        clock?.cancel(); clock = nil
        leaveClock?.cancel(); leaveClock = nil
        eventClock?.cancel(); eventClock = nil
        status.lastLeave = nil
        status.event = nil
        status.offerings = []
        status.rights = nil
    }

    // MARK: Create, join, leave

    /// Open a group and set the title right away. Everyone, including yourself,
    /// then gets the queue and opens the player paused. An empty name becomes
    /// "Movie night". `accepted` fires as soon as the server said yes, so the
    /// sheet can close while the control channel is still awaited.
    @discardableResult
    public func create(name: String, title: String,
                        accepted: (@Sendable () async -> Void)? = nil) async -> Bool {
        guard let client = await clientSource(), !status.works else { return false }
        status.works = true
        defer { status.works = false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await client.syncPlayCreate(name: name.isEmpty ? translated("Filmabend") : name)
            try await client.syncPlayQueue([title], since: 0)
            await accepted?()
            sag("Gruppe angelegt fuer \(title)")
            await channelCheck()
            return true
        } catch {
            fail(.from(error))
            return false
        }
    }

    @discardableResult
    public func join(_ target: SyncPlayGroup,
                          accepted: (@Sendable () async -> Void)? = nil) async -> Bool {
        guard let client = await clientSource(), !status.works else { return false }
        status.works = true
        defer { status.works = false }
        do {
            try await client.syncPlayJoin(target.id)
            await accepted?()
            status.lastLeave = nil
            status.offerings.removeAll { $0.id == target.id }
            sag("beigetreten: \(target.id)")
            await channelCheck()
            return true
        } catch {
            fail(.from(error))
            return false
        }
    }

    /// **Does anything arrive over the channel?** Everything else (the join, the
    /// queue, every command) runs over the control channel. If it is down, you
    /// would be in a group on the server and nothing would happen here. Better to
    /// leave right away and say so.
    private func channelCheck() async {
        for _ in 0..<25 {
            if status.group != nil { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        sag("kein GroupJoined binnen 5 s — Kanal stumm?")
        try? await clientSource()?.syncPlayLeave()
        fail(.noResponse)
    }

    /// Closing the player means leaving the group. No confirmation: the strip and
    /// the badge let you back in at any time.
    public func leave(remember: Bool = true, with client: JellyfinClient? = nil) {
        guard let alt = status.group else { return }
        let source: ClientSource = if let client { { @Sendable in client } } else { clientSource }
        allBackSet()
        if remember {
            status.lastLeave = alt
            leaveClock?.cancel()
            leaveClock = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                await self?.leaveForget()
            }
        }
        Task {
            do { try await source()?.syncPlayLeave() }
            catch { TrackSupport.sag("[Gemeinsam] Verlassen fehlgeschlagen: \(error)") }
        }
    }

    private func leaveForget() { status.lastLeave = nil }

    public func againJoin() async {
        guard let alt = status.lastLeave else { return }
        status.lastLeave = nil
        await join(alt)
    }

    private func allBackSet() {
        lostOut = nil
        againEntry?.cancel(); againEntry = nil
        lineDeadline?.cancel(); lineDeadline = nil
        status.group = nil
        status.condition = nil
        status.queueTitle = nil
        queue = nil
        lastCommand = nil
        loadedFor = nil
        planned?.cancel(); planned = nil
        load?.cancel(); load = nil
        clock?.cancel(); clock = nil
        reconcile = TimeReconcile()
        buffer.reset()
    }

    // MARK: What comes from the server

    /// Every SyncPlay message from the control channel. From any thread; they are
    /// processed in the order they arrive here.
    public nonisolated func accept(_ postDirection: SyncPlayPostDirection) {
        input.yield(postDirection)
    }

    private func process(_ postDirection: SyncPlayPostDirection) async {
        switch postDirection {
        case let .joined(g):
            let new = status.group?.id != g.id
            status.group = g
            status.condition = g.condition
            status.offerings.removeAll { $0.id == g.id }
            if new { clockStart() }
            if lostOut?.id == g.id { lostOut = nil }
        case .leave, .notInGroup:
            if status.group != nil { allBackSet() }
        case .doesNotExist:
            allBackSet()
            fail(.doesNotExist)
        case .noAccess:
            report(.noAccess)
        case let .someoneJoined(name):
            guard let g = status.group else { return }
            status.group = SyncPlayGroup(id: g.id, name: g.name, condition: status.condition,
                                         participant: g.participant + [name], state: g.state)
            if name != (await ichSource()) { report(.present(name)) }
        case let .someoneLeft(name):
            guard let g = status.group else { return }
            var list = g.participant
            if let i = list.firstIndex(of: name) { list.remove(at: i) }
            status.group = SyncPlayGroup(id: g.id, name: g.name, condition: status.condition,
                                         participant: list, state: g.state)
            if name != (await ichSource()) { report(.gone(name)) }
        case .connectionLost:
            guard let g = status.group, lostOut == nil else { return }
            sag("Leitung verloren — merke Gruppe \(g.id)")
            lostOut = g
            // If the connection does not come back, do not stay silent forever.
            let deadline = patience.conduit
            lineDeadline?.cancel()
            lineDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(deadline))
                guard !Task.isCancelled else { return }
                await self?.againEntryFailed("Leitung kam nicht zurück")
            }
        case .connectionAgain:
            guard let target = lostOut else { return }
            lineDeadline?.cancel(); lineDeadline = nil
            againEntry?.cancel()
            againEntry = Task { [weak self] in
                await self?.reenter(target)
            }
        case let .condition(new, reason):
            let before = status.condition
            status.condition = new
            if new == .waits, before == .running, reason == "Buffer" { report(.waitsOnAll) }
        case let .queue(w):
            acceptQueue(w)
        case let .command(b):
            commandAccept(b)
        }
    }

    /// After reconnecting, back into the group: `Join`, wait for `GroupJoined`, then
    /// report state. The queue the server sends on joining reconciles title and
    /// position (see ``acceptQueue(_:)``).
    private func reenter(_ target: SyncPlayGroup) async {
        for attempt in 1...max(1, patience.attempts) {
            guard !Task.isCancelled, lostOut != nil else { return }
            guard let client = await clientSource() else { break }
            do {
                try await client.syncPlayJoin(target.id)
            } catch {
                sag("Wiedereintritt \(attempt) fehlgeschlagen: \(error)")
                try? await Task.sleep(for: .seconds(patience.pause))
                continue
            }
            let end = Date().addingTimeInterval(patience.answer)
            while Date() < end, lostOut != nil, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if Task.isCancelled { return }
            if lostOut == nil {
                sag("wieder in der Gruppe \(target.id)")
                if player != nil, loadedFor != nil {
                    await reportStatus(ready: true, running: status.condition == .running)
                }
                return
            }
        }
        if !Task.isCancelled { againEntryFailed("kein Wiedereintritt") }
    }

    private func againEntryFailed(_ reason: String) {
        guard lostOut != nil else { return }
        sag("Gruppe endgültig verloren: \(reason)")
        allBackSet()
        fail(.connectionLost)
    }

    private func report(_ art: SyncPlayEvent.Art) {
        status.event = SyncPlayEvent(art)
        eventClock?.cancel()
        eventClock = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.eventForget()
        }
    }

    private func eventForget() { status.event = nil }

    private func acceptQueue(_ w: SyncPlayQueue) {
        if let alt = queue?.state, let new = w.state, new < alt { return }
        let before = queue?.current
        queue = w
        status.queueTitle = w.current?.title
        guard w.switchesTitle, let current = w.current else { return }
        // The same entry, already loaded: nothing to do.
        if current == before, loadedFor == current.entryRecord { return }
        loadedFor = nil
        buffer.reset()

        // Where the group stands now: prefer the last command, which comes more often
        // than a new queue (as in jellyfin-web).
        var since = w.startPoint
        if let b = lastCommand, let spot = b.spot, b.entryRecord == current.entryRecord,
           (b.emitted ?? b.moment) >= (w.state ?? .distantPast) {
            since = b.art == .proceed
                ? SyncPlayExecution.estimatedPoint(spot: spot, validFrom: b.moment,
                                                       now: Date(), reconcile: reconcile)
                : spot
        } else if w.running, let state = w.state {
            since = SyncPlayExecution.estimatedPoint(spot: w.startPoint, validFrom: state,
                                                       now: Date(), reconcile: reconcile)
        }

        load?.cancel()
        let loader = titleLoad
        load = Task { [weak self] in
            guard let self else { return }
            await self.titleOpen(current, since: since, reason: w.reason, loader: loader)
        }
    }

    private func titleOpen(_ current: SyncPlayQueue.Record, since: Double, reason: String,
                              loader: TitleLoader) async {
        sag("Warteschlange \(reason): \(current.title) ab \(Int(since)) s")
        if let player, await player.title() == current.title {
            await player.jump(since)
        } else {
            // Switch in the open player or open it; the platform knows how. Until the
            // player catches up on the next tick, the old title counts as not ready; the
            // platform takes care of that itself.
            guard await loader(current.title, since) else {
                report(.notPlayable)
                return
            }
        }
        guard !Task.isCancelled else { return }
        await loadWait(entryRecord: current.entryRecord)
    }

    /// Until the player has the picture, then pause and report "ready". The server
    /// releases the resume as soon as everyone is ready.
    private func loadWait(entryRecord: String) async {
        for _ in 0..<600 {   // at most two minutes
            if Task.isCancelled { return }
            if let player, await player.ready() {
                await player.halt()
                loadedFor = entryRecord
                loadedSince = Date()
                await reportStatus(ready: true, running: false)
                // A command that already came while still loading.
                if let b = lastCommand, b.entryRecord == entryRecord { commandStart(b) }
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func commandAccept(_ b: SyncPlayCommand) {
        guard status.group != nil else { return }
        lastCommand = b
        guard player != nil, loadedFor != nil,
              b.entryRecord == nil || b.entryRecord == loadedFor || b.art == .stop else { return }
        commandStart(b)
    }

    /// **A command replaces the previous one**, even if that is still waiting for
    /// its time. The number catches the case where the next one arrives while this
    /// one is still asking the player for the position.
    private func commandStart(_ b: SyncPlayCommand) {
        commandNumber += 1
        let number = commandNumber
        planned?.cancel()
        planned = Task { [weak self] in await self?.execute(b, number: number) }
    }

    private func execute(_ b: SyncPlayCommand, number: Int) async {
        guard let player else { return }
        let localOnly = await player.spot()
        guard number == commandNumber, !Task.isCancelled else { return }
        let x = SyncPlayExecution.of(b, now: Date(), reconcile: reconcile, localPoint: localOnly)
        sag("\(b.art.rawValue) bei \(Int(b.spot ?? -1)) s · "
            + "in \(Int(x.wait * 1000)) ms · springen \(x.spot.map { String(Int($0)) } ?? "—")")
        if Date().timeIntervalSince(lastRequested) > 3, Date().timeIntervalSince(loadedSince) > 3 {
            switch b.art {
            case .pause: report(.halted)
            case .proceed: report(.goesNext)
            case .jump: report(.jumped)
            case .stop: break
            }
        }
        // The time is fixed before seeking, since the seek itself takes time.
        let until = Date().addingTimeInterval(x.wait)
        if x.step == .proceed, x.wait > 0, let s = x.spot { await player.jump(s) }
        let rest = until.timeIntervalSinceNow
        if x.wait > 0, rest > 0 { try? await Task.sleep(for: .seconds(rest)) }
        guard !Task.isCancelled else { return }
        await stepDo(x, player: player)
    }

    private func stepDo(_ x: SyncPlayExecution, player: any SyncPlayPlayer) async {
        let wasBuffering = buffer.buffers
        buffer.reset()
        switch x.step {
        case .proceed:
            if x.wait == 0, let s = x.spot { await player.jump(s) }
            await player.proceed()
        case .pause:
            await player.halt()
            if let s = x.spot { await player.jump(s) }
            // **If "buffering" was reported, "ready" must follow.** The server holds the
            // group until it arrives, but it was only measured at a position that is
            // running. A paused one does not run, and the group would wait forever.
            if wasBuffering {
                try? await Task.sleep(for: .milliseconds(500))
                await reportStatus(ready: true, running: false)
            }
        case .jump:
            // **Like jellyfin-web: seek, play briefly until the picture really runs, then
            // pause and only now report "ready".**
            //
            // Before: seek while paused and report "ready" after at most five seconds with
            // VLC's time. While paused VLC does not reliably update the time after a seek,
            // so the report often still carried the old position. The server checks it to
            // half a second (`WaitingGroupState`, "got lost in time"), sent the seek again,
            // and the group stuck in "Waiting": paused here, repeatedly stopping on the
            // other side.
            if let s = x.spot {
                await player.jump(s)
                await player.proceed()
                await untilEsRuns(at: s, player: player)
                await player.halt()
                // If the same seek arrives a second time, the server already rejected the
                // measured position once; then use the target, otherwise it would go in circles.
                let repeated = lastJumpTarget.map { abs($0 - s) < 0.01 } ?? false
                lastJumpTarget = s
                let message = repeated ? s
                    : SyncPlayExecution.readyPoint(target: s, actualValue: await player.spot())
                await reportStatus(ready: true, running: false, spot: message)
            } else {
                await player.halt()
                await reportStatus(ready: true, running: false)
            }
        case .stop:
            await player.halt()
        }
        // **One line per executed step, with the time to the millisecond.** Two
        // devices of the same group can then be laid side by side: same time, same
        // position, or not.
        let here = await player.spot()
        let t = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        sag("ausgefuehrt \(x.step) bei \(String(format: "%.2f", here)) s, t=\(t)")
    }

    // MARK: From the player

    /// The player is open and belongs to the group.
    public func plugIn(_ s: any SyncPlayPlayer) {
        player = s
    }

    /// The player closes. **That is leaving.**
    public func detach() {
        player = nil
        leave()
    }

    /// Pause and resume go to the server as requests. The button only flips when
    /// the command comes back, then for everyone at the same time.
    public func bitToggle(runningCurrently: Bool) async {
        guard let client = await clientSource() else { return }
        lastRequested = Date()
        do {
            if runningCurrently { try await client.syncPlayBitPause() }
            else { try await client.syncPlayBitNext() }
        } catch { fail(.from(error)) }
    }

    public func bitJump(on seconds: Double) async {
        guard let client = await clientSource() else { return }
        lastRequested = Date()
        do { try await client.syncPlayPleaseJump(on: seconds) }
        catch { fail(.from(error)) }
    }

    /// **A different episode, for everyone.** Nobody in the group switches alone;
    /// the episode choice in the player resets the queue and everyone loads it, as
    /// when creating.
    public func bitTitle(_ title: String, since seconds: Double = 0) async {
        guard let client = await clientSource() else { return }
        lastRequested = Date()
        do { try await client.syncPlayQueue([title], since: seconds) }
        catch { fail(.from(error)) }
    }

    /// Once per player tick: report buffering.
    public func playerTick() async {
        guard let player, loadedFor != nil, status.group != nil else { return }
        let spot = await player.spot()
        let now = Date()
        let should = lastCommand.map { $0.art == .proceed && reconcile.localOnly($0.moment) <= now } ?? false
        if let message = buffer.tick(spot: spot, shouldRun: should, now: now) {
            sag("\(message == .buffers ? "puffert" : "wieder bereit") bei \(Int(spot)) s")
            await reportStatus(ready: message == .ready, running: true)
        }
        // **No drift correction while running**, like jellyfin-web, which has it off by
        // default (`enableSyncCorrection`). It was here with a one-second threshold and
        // was the second half of a loop: the seek to correct made VLC buffer, that went
        // out as `Buffering`, the server paused everyone and released them again, and
        // the new estimate was off again. Sync happens on every pause, resume and seek
        // anyway.
    }

    /// Until VLC is really playing at the position: the time moves, close to the
    /// target. At most ten seconds.
    private func untilEsRuns(at target: Double, player: any SyncPlayPlayer) async {
        var before = await player.spot()
        for _ in 0..<100 {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
            let now = await player.spot()
            if now > before + 0.02, abs(now - target) < 3 { return }
            before = now
        }
        sag("nach dem Sprung auf \(Int(target)) s lief nach 10 s noch nichts")
    }

    private func reportStatus(ready: Bool, running: Bool, spot: Double? = nil) async {
        guard let client = await clientSource(), let player,
              let entryRecord = loadedFor ?? queue?.current?.entryRecord else { return }
        let here: Double
        if let spot { here = spot } else { here = await player.spot() }
        do {
            try await client.syncPlayState(ready: ready, moment: reconcile.server(Date()),
                                           spot: here, running: running, entryRecord: entryRecord)
        } catch {
            sag("\(ready ? "Ready" : "Buffering") fehlgeschlagen: \(error)")
        }
    }

    // MARK: Clock

    /// Measure three times at one-second intervals, then every minute, and report
    /// the runtime to the server each time. It needs it to schedule "resume" so
    /// that everyone can reach it.
    private func clockStart() {
        clock?.cancel()
        clock = Task { [weak self] in
            var count = 0
            while !Task.isCancelled {
                guard let self else { return }
                count = await self.inTimesMeasure(count)
                try? await Task.sleep(for: .seconds(TimeReconcile.pause(toMeasurements: count)))
            }
        }
    }

    private func inTimesMeasure(_ count: Int) async -> Int {
        guard let client = await clientSource() else { return count }
        do {
            let m = try await client.serverTimeMeasure()
            guard !Task.isCancelled else { return count }
            reconcile.record(m)
            let new = count + 1
            if new == 1 || new % 10 == 0 {
                sag("Uhr: Versatz \(Int(reconcile.offset * 1000)) ms, Ping \(reconcile.pingMilliseconds) ms")
            }
            try? await client.syncPlayPing(milliseconds: reconcile.pingMilliseconds)
            return new
        } catch {
            sag("Uhr nicht messbar: \(error)")
            return count
        }
    }
}
