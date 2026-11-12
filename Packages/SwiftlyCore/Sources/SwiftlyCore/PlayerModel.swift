import Observation

/// The `@MainActor @Observable` adapter of `PlayerVm`. The engine (AetherDriver, AVPlayer, VLC)
/// implements `PlayerEngine` with commands that return at once and reports what happens through
/// `engineEvent(_:)`. The core ticks itself; the view only reads the four parts and sends intents.
@MainActor
@Observable
public final class PlayerModel {
    public private(set) var transport: PlayerTransport
    public private(set) var controls: PlayerControls
    public private(set) var tracks: PlayerTracks
    public private(set) var offer: PlayerOffer

    @ObservationIgnored private let vm: PlayerVm
    @ObservationIgnored private let seen: UInt64

    public init(vm: PlayerVm) {
        self.vm = vm
        self.seen = vm.version()
        self.transport = vm.transport()
        self.controls = vm.controls()
        self.tracks = vm.tracks()
        self.offer = vm.offer()
    }

    /// Loads the title at its start position.
    public func start() { vm.start() }
    /// The next episode's plan is here (after a `startEpisode` effect).
    public func loadTitle(_ start: PlayerStart) { vm.loadTitle(start: start) }
    /// This model replaces one that reloaded the title after a quality choice.
    public func afterQualitySwitch() { vm.afterQualitySwitch() }
    public func send(_ intent: PlayerIntent) { vm.send(intent: intent) }
    /// What the engine reported.
    public func engineEvent(_ event: PlayerEngineEvent) { vm.engineEvent(event: event) }
    public func setPrefs(_ prefs: PlayerPrefs) { vm.setPrefs(prefs: prefs) }
    public func setNext(_ next: PlayerNext?) { vm.setNext(next: next) }
    public func setSections(_ sections: [PlayerSection]) { vm.setSections(sections: sections) }
    public func setTrickplay(_ trickplay: PlayerTrickplay?) { vm.setTrickplay(trickplay: trickplay) }
    public func setChapters(_ chapters: [PlayerChapter]) { vm.setChapters(chapters: chapters) }
    /// Where the picture goes (this screen, the small window, AirPlay): a state machine in the core.
    public var surface: PlayerSurface { vm.surface() }
    /// The small window or AirPlay changed; returns the new surface.
    @discardableResult
    public func surfaceEvent(_ event: PlayerSurfaceEvent) -> PlayerSurface { vm.surfaceEvent(event: event) }
    /// The audio went to an AirPlay device: the core decides whether the TV may take the picture
    /// (`sourceJSON` is the playing plan's `MediaSource`).
    public func airplayStart(sourceJSON: String) -> AirPlayStartDecision { vm.airplayStart(sourceJson: sourceJSON) }
    /// Work for the host (close the screen, switch the episode, write a setting, prepare the next).
    public func takeEffects() -> [PlayerEffectOut] { vm.takeEffects() }
    /// The same work folded into what the screen runs (one place that reads the core's effects).
    public func takeCalls() -> PlayerCalls { PlayerCalls(vm.takeEffects()) }

    /// Returns when the calling Task is cancelled.
    public func observe() async {
        let bits = (partPlayerTransport(), partPlayerControls(), partPlayerTracks(), partPlayerOffer())
        let vm = vm
        await observeChanges(from: seen, changed: { try await vm.changed(seen: $0) }) { change in
            if change.parts & bits.0 != 0 { transport = vm.transport() }
            if change.parts & bits.1 != 0 { controls = vm.controls() }
            if change.parts & bits.2 != 0 { tracks = vm.tracks() }
            if change.parts & bits.3 != 0 { offer = vm.offer() }
        }
    }
}

/// **The host side of the core's effects**, folded from one `takeEffects()` look. The screens run these and nothing
/// else decides: `switchTo` (plan, `loadTitle`; the same id is the reload of a quality choice or of a subtitle on a
/// transcoded stream, the latter with `reloadSubtitle`: the plan is asked with that track), `quality` (file the
/// settings), `forgetPrepared`, `close` (leave the screen), `prepareNext` (warm the next plan), `nudge` (rating or
/// Discord prompt after the close), `handOver` (the engine cannot show a track: the facade reports tracks only, there
/// is no second engine) and `streamRebuilt` (the engine got its load already; log only).
public struct PlayerCalls: Equatable, Sendable {
    public var switchTo: (id: String, fromCard: Bool, since: Double)?
    /// Set with `switchTo` when a subtitle was picked on a transcoded stream: ask the plan with this server index
    /// (`-1` off) so the server burns it in (or drops it), then reload at `switchTo.since`.
    public var reloadSubtitle: Int64?
    public var quality: (directPlay: Bool, limit: Int64)?
    public var forgetPrepared = false
    public var close = false
    public var prepareNext: String?
    public var nudge: Bool?
    public var handOver: (subtitle: Int64, reason: String)?
    public var streamRebuilt: (position: Double, paused: Bool, reason: String)?

    public init() {}

    public init(_ effects: [PlayerEffectOut]) {
        for effect in effects {
            switch effect {
            case let .startEpisode(id, fromCard, since): switchTo = (id, fromCard, since)
            case let .reloadForSubtitle(id, subtitle, since):
                switchTo = (id, false, since)
                reloadSubtitle = subtitle
            case let .qualityChosen(directPlay, limit): quality = (directPlay, limit)
            case .forgetPrepared: forgetPrepared = true
            case .close: close = true
            case let .prepareNext(id): prepareNext = id
            case let .nudge(rating): nudge = rating
            case let .handOver(subtitle, reason): handOver = (subtitle, reason)
            case let .streamRebuilt(position, paused, reason): streamRebuilt = (position, paused, reason)
            }
        }
    }

    public var isEmpty: Bool { self == PlayerCalls() }

    public static func == (a: PlayerCalls, b: PlayerCalls) -> Bool {
        a.switchTo?.id == b.switchTo?.id && a.switchTo?.fromCard == b.switchTo?.fromCard
            && a.switchTo?.since == b.switchTo?.since
            && a.reloadSubtitle == b.reloadSubtitle
            && a.quality?.directPlay == b.quality?.directPlay && a.quality?.limit == b.quality?.limit
            && a.forgetPrepared == b.forgetPrepared && a.close == b.close && a.prepareNext == b.prepareNext
            && a.nudge == b.nudge && a.handOver?.subtitle == b.handOver?.subtitle
            && a.handOver?.reason == b.handOver?.reason && a.streamRebuilt?.position == b.streamRebuilt?.position
            && a.streamRebuilt?.paused == b.streamRebuilt?.paused && a.streamRebuilt?.reason == b.streamRebuilt?.reason
    }
}
