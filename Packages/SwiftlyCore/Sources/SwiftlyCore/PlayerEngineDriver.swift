import Foundation
import Synchronization

/// What a platform engine (Aether, AVPlayer, VLC) does for the core. Every call runs on the main
/// actor, in the order the core gave the commands. The port never answers a command: what the engine
/// learns comes back through the `emit` closure given to ``attach(_:)`` as a `PlayerEngineEvent`.
///
/// Track numbers in both directions are the **server's** `Index` (the port maps its own ids, for
/// instance the ids of external subtitle files, before it emits and after it receives).
@MainActor
public protocol PlayerEnginePort: AnyObject {
    /// Called once, before the first command. `emit` may be called on the main actor at any time.
    func attach(_ emit: @escaping @MainActor (PlayerEngineEvent) -> Void)
    func load(_ request: PlayerLoad)
    func play()
    func pause()
    func seek(_ seconds: Double)
    func setRate(_ tempo: Float)
    func setVolume(_ percent: UInt8)
    func setAudioDelay(milliseconds: Int32)
    func setSubtitleDelay(milliseconds: Int32)
    func selectAudio(_ serverIndex: Int32)
    func selectSubtitle(_ serverIndex: Int32)
    func setFill(_ on: Bool)
    func place(_ rect: PlayerRect)
    func stop(resetDisplay: Bool)
    func pip(_ command: PlayerPip)
}

/// **The `PlayerEngine` the core talks to, as a thin driver.**
///
/// The core calls it from any thread (a screen intent on the main thread, the core's own clock on its
/// runtime). Nothing here waits for the main thread: a command is put into an ordered stream and a
/// single task on the main actor hands it to the ``PlayerEnginePort``. The two calls that have to
/// answer at once (`selectAudio`, `selectSubtitle`) answer from the track lists the engine reported
/// last (a snapshot under a short lock that is never held across another call) and queue the real
/// selection; if the engine turns out not to have the track, it says so with a `tracks` event.
///
/// After every `load` the driver also sends the state a fresh clock at the load's start position, for any
/// port (Aether now, whatever engine comes next), so a stale position never outlives a load.
///
/// Events go the other way: ``receive(_:)`` runs on the main actor, notes the track lists and forwards
/// the event to the sink (`PlayerModel.engineEvent`).
public final class PlayerEngineDriver: PlayerEngine, @unchecked Sendable {
    private enum Command: @unchecked Sendable {
        case load(PlayerLoad)
        case play, pause
        case seek(Double)
        case rate(Float)
        case volume(UInt8)
        case audioDelay(Int32)
        case subtitleDelay(Int32)
        case audio(Int32)
        case subtitle(Int32)
        case fill(Bool)
        case place(PlayerRect)
        case stop(Bool)
        case pip(PlayerPip)
    }

    /// What the engine reported last; read by the two answering commands.
    private struct Known {
        var audio: Set<Int64>? = nil
        var subtitles: Set<Int64>? = nil
    }

    private let commands: AsyncStream<Command>.Continuation
    private let known = Mutex(Known())
    /// Where the engine's events go. A class, so the pump can hold it without holding the driver.
    private final class Sink: Sendable {
        let receiver = Mutex<(@MainActor (PlayerEngineEvent) -> Void)?>(nil)
    }
    private let sink: Sink
    private let pump: Task<Void, Never>

    /// - Parameter port: the engine; it is attached here and gets every command on the main actor.
    @MainActor
    public init(port: some PlayerEnginePort) {
        let (stream, continuation) = AsyncStream<Command>.makeStream(bufferingPolicy: .unbounded)
        commands = continuation
        let sink = Sink()
        self.sink = sink
        pump = Task { @MainActor in
            for await command in stream {
                switch command {
                case .load(let r):
                    port.load(r)
                    // **A fresh engine clock after every load** (hardening F-prop-06): until the engine
                    // reports its own, the state would keep the position of the title before (or of the
                    // failed attempt) and the start watchdog would judge on it. The new load starts here.
                    let at = r.start ?? 0
                    sink.receiver.withLock { $0 }?(.clock(position: at, sourceTime: at))
                case .play: port.play()
                case .pause: port.pause()
                case .seek(let s): port.seek(s)
                case .rate(let t): port.setRate(t)
                case .volume(let v): port.setVolume(v)
                case .audioDelay(let d): port.setAudioDelay(milliseconds: d)
                case .subtitleDelay(let d): port.setSubtitleDelay(milliseconds: d)
                case .audio(let i): port.selectAudio(i)
                case .subtitle(let i): port.selectSubtitle(i)
                case .fill(let on): port.setFill(on)
                case .place(let r): port.place(r)
                case .stop(let reset): port.stop(resetDisplay: reset)
                case .pip(let c): port.pip(c)
                }
            }
        }
        port.attach { [weak self] event in self?.receive(event) }
    }

    deinit {
        commands.finish()
        pump.cancel()
    }

    /// Where the engine's events go: `PlayerModel.engineEvent` (set once the model exists).
    @MainActor
    public func connect(_ receiver: @escaping @MainActor (PlayerEngineEvent) -> Void) {
        sink.receiver.withLock { $0 = receiver }
    }

    /// An event from the port: remembers the track lists, then hands it on.
    @MainActor
    public func receive(_ event: PlayerEngineEvent) {
        if case .tracks(let audio, let subtitles, _, _) = event {
            known.withLock {
                $0.audio = Set(audio.map(\.id))
                $0.subtitles = Set(subtitles.map(\.id))
            }
        }
        let receiver = sink.receiver.withLock { $0 }
        receiver?(event)
    }

    /// Ends the driver after a `stop`: nothing more is delivered.
    public func finish() { commands.finish() }

    // MARK: PlayerEngine (any thread, return at once)

    public func load(request: PlayerLoad) {
        // A new title starts with no track lists.
        known.withLock { $0 = Known() }
        commands.yield(.load(request))
    }
    public func play() { commands.yield(.play) }
    public func pause() { commands.yield(.pause) }
    public func seek(seconds: Double) { commands.yield(.seek(seconds)) }
    public func setRate(tempo: Float) { commands.yield(.rate(tempo)) }
    public func setVolume(percent: UInt8) { commands.yield(.volume(percent)) }
    public func setAudioDelay(milliseconds: Int32) { commands.yield(.audioDelay(milliseconds)) }
    public func setSubtitleDelay(milliseconds: Int32) { commands.yield(.subtitleDelay(milliseconds)) }
    public func setFill(on: Bool) { commands.yield(.fill(on)) }
    public func place(rect: PlayerRect) { commands.yield(.place(rect)) }
    public func stop(resetDisplay: Bool) { commands.yield(.stop(resetDisplay)) }
    public func pip(command: PlayerPip) { commands.yield(.pip(command)) }

    /// `false` only if the engine already listed its audio tracks and this one is not among them
    /// (before the list is there the selection is queued and the engine checks it itself, as the
    /// old driver did).
    public func selectAudio(serverIndex: Int32) -> Bool {
        let present = known.withLock { $0.audio.map { $0.contains(Int64(serverIndex)) } ?? true }
        guard present else { return false }
        commands.yield(.audio(serverIndex))
        return true
    }

    /// `-1` is always possible (subtitles off). A track the engine listed is drawn from its cues by
    /// the app; one it did not list stays off (`unsupported`).
    public func selectSubtitle(serverIndex: Int32) -> PlayerSubtitleRoute {
        if serverIndex >= 0 {
            let present = known.withLock { $0.subtitles.map { $0.contains(Int64(serverIndex)) } ?? true }
            guard present else { return .unsupported }
        }
        commands.yield(.subtitle(serverIndex))
        return .cues
    }
}
