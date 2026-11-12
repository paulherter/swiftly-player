import AetherEngine
import AppKit
import Combine
import Foundation
import SwiftlyAether
import SwiftlyCore

/// **The headless engine port of the bench**: the same `PlayerEnginePort` the app's `CoreAetherPort` is, over the real
/// `AetherEngine`, without a screen (a bare `AetherPlayerView` that is never shown, volume 0). It mirrors the load of
/// `Sources/Shared/AetherPlayerEngine.swift` on purpose (same `LoadOptions`, the audio policy, external subtitles, the
/// "zero duration" second try with the stored runtime): change one, change the other (`BenchPortParityTests` guards it).
@MainActor
final class BenchPort: PlayerEnginePort {
    let engine: AetherEngine
    let view = AetherPlayerView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    private var emit: (@MainActor (PlayerEngineEvent) -> Void)?
    private var bag = Set<AnyCancellable>()
    private var task: Task<Void, Never>?
    private var attempt: UInt32 = 0
    private var declaresRuntime = false
    private var externalIDs: [Int: Int] = [:]
    private var lastClock = Date.distantPast
    private var openedURL: String?

    let start: PlayerStart
    /// The engine's track numbers come from the chosen version (the core's `source_json`) like in the app
    /// (`MediaSource.engineTrackIndex`; Plex's server number is a stream id, the engine counts by place in the file).
    private lazy var numbers = BenchTrackNumbers(sourceJson: start.sourceJson)
    private func engineID(_ server: Int) -> Int { numbers.engine(forServer: server) }
    private func serverID(forEngine id: Int, type: String) -> Int { numbers.server(forEngine: id, type: type) }
    /// Everything the engine told the core, in order (the bench reads what it needs).
    private(set) var events: [PlayerEngineEvent] = []
    private(set) var firstFrame = false
    private(set) var ended = false
    private(set) var loaded = false
    private(set) var failure: String?
    private(set) var loadAttempts = 0
    private(set) var retriedWithRuntime = false
    private(set) var latestCues: [SwiftlyCore.PlayerCue] = []
    private(set) var audioActive: Int?
    private(set) var subtitleActive: Int?
    var avStatus: String? {
        engine.currentAVPlayer.map { "\($0.timeControlStatus.rawValue)" }
    }

    init(start: PlayerStart) throws {
        self.start = start
        engine = try AetherEngine()
        engine.volume = 0
        engine.bind(view: view)
        watch()
    }

    // MARK: Observing

    private func deliver(_ event: PlayerEngineEvent) {
        events.append(event)
        emit?(event)
    }

    private func watch() {
        engine.$state.sink { [weak self] state in
            guard let self else { return }
            switch state {
            case .idle: deliver(.state(state: .idle))
            case .loading: deliver(.state(state: .loading))
            case .playing: deliver(.state(state: .playing))
            case .paused: deliver(.state(state: .paused))
            case .seeking: deliver(.state(state: .seeking))
            case .ended: ended = true; deliver(.state(state: .ended))
            case .error(let message):
                failure = message
                deliver(.state(state: .error(message: message, kind: engine.errorInfo?.kind.rawValue)))
            }
        }.store(in: &bag)
        engine.$hasFirstFrameReadyForDisplay.sink { [weak self] shown in
            guard let self, shown, !firstFrame else { return }
            firstFrame = true
            deliver(.firstFrame)
        }.store(in: &bag)
        engine.clock.$currentTime.sink { [weak self] seconds in
            guard let self, seconds.isFinite, Date().timeIntervalSince(lastClock) >= 0.25 else { return }
            lastClock = Date()
            deliver(.clock(position: seconds, sourceTime: engine.clock.sourceTime))
        }.store(in: &bag)
        engine.$audioTracks.sink { [weak self] _ in self?.emitTracks() }.store(in: &bag)
        engine.$subtitleTracks.sink { [weak self] _ in self?.emitTracks() }.store(in: &bag)
        engine.$subtitleCues.sink { [weak self] cues in
            guard let self else { return }
            let mapped = cues.map { cue -> SwiftlyCore.PlayerCue in
                let body: SwiftlyCore.PlayerCueBody
                switch cue.body {
                case .text(let text): body = .text(text: text)
                case .richText(let runs): body = .rich(runs: runs.map(\.text))
                case .image(let image):
                    body = .image(x: image.position.origin.x, y: image.position.origin.y, width: image.position.width,
                                  height: image.position.height, canvasWidth: image.canvasSize.width,
                                  canvasHeight: image.canvasSize.height)
                }
                return SwiftlyCore.PlayerCue(id: Int64(cue.id), start: cue.startTime, end: cue.endTime, body: body)
            }
            latestCues = mapped
            deliver(.cues(cues: mapped))
        }.store(in: &bag)
    }

    /// As the app does (`AetherPlayerEngine.emitTracks`): the server's streams are the track lists, numbered by the server's
    /// `Index`; the engine's own numbers (external files: `externalSubtitleTrackIDBase + n`) stay inside the port.
    /// Mirror of `AetherPlayerEngine.coreTrackID` (the shared rule is `CoreTrackIDs`).
    private func coreID(_ serverIndex: Int64) -> Int64 {
        guard let engineID = externalIDs[Int(serverIndex)] else { return serverIndex }
        return CoreTrackIDs.external(position: engineID - AetherEngine.externalSubtitleTrackIDBase)
    }

    private func emitTracks() {
        guard !engine.audioTracks.isEmpty || !engine.subtitleTracks.isEmpty else { return }
        func list(_ kind: String) -> [SwiftlyCore.PlayerTrack] {
            start.streams.filter { $0.kind.lowercased() == kind }.map {
                SwiftlyCore.PlayerTrack(id: kind == "subtitle" ? coreID($0.index) : $0.index, codec: $0.codec ?? "", language: $0.language, name: $0.title ?? "",
                                        channels: $0.channels ?? 0, isDefault: $0.isDefault, isForced: $0.isForced)
            }
        }
        audioActive = engine.activeAudioTrackIndex.map { serverID(forEngine: $0, type: "Audio") }
        subtitleActive = engine.activeSubtitleTrackIndex.map { $0 >= AetherEngine.externalSubtitleTrackIDBase ? $0 : serverID(forEngine: $0, type: "Subtitle") }
        deliver(.tracks(audio: list("audio"), subtitles: list("subtitle"),
                        activeAudio: audioActive.map(Int64.init), activeSubtitle: subtitleActive.map { $0 >= AetherEngine.externalSubtitleTrackIDBase ? CoreTrackIDs.external(position: $0 - AetherEngine.externalSubtitleTrackIDBase) : Int64($0) }))
    }

    var duration: Double { engine.duration }
    var position: Double { engine.clock.currentTime }
    var audioTracks: [TrackInfo] { engine.audioTracks }
    var subtitleTracks: [TrackInfo] { engine.subtitleTracks }
    var subtitleCues: [SubtitleCue] { engine.subtitleCues }
    var state: PlaybackState { engine.state }

    // MARK: PlayerEnginePort

    func attach(_ emit: @escaping @MainActor (PlayerEngineEvent) -> Void) { self.emit = emit }

    func load(_ load: PlayerLoad) {
        lastLoad = load
        attempt += 1
        loadAttempts += 1
        let mine = attempt
        ended = false
        firstFrame = false
        guard let url = URL(string: load.url) else {
            deliver(.loadFailed(attempt: mine, message: "Adresse ungültig", kind: nil)); return
        }
        openedURL = load.url
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var options = LoadOptions()
            options.httpHeaders = Dictionary(load.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
            options.applySwiftlyAudioPolicy()
            options.skipsContainerAttachments = true
            if declaresRuntime, start.runtime > 0 { options.declaredDurationSeconds = start.runtime }
            externalIDs = [:]
            let files = start.subtitleFiles
            for (offset, file) in load.externalSubtitles.enumerated() where offset < files.count {
                externalIDs[Int(files[offset].index)] = AetherEngine.externalSubtitleTrackIDBase + offset
            }
            options.externalSubtitles = load.externalSubtitles.map {
                ExternalSubtitleTrack(url: URL(string: $0.url)!, name: $0.name, language: $0.language, isForced: $0.isForced,
                                      formatHint: $0.formatHint)
            }
            do {
                _ = try await engine.load(url: url, startPosition: (load.start ?? 0) > 0.5 ? load.start : nil, options: options,
                                          audioSourceStreamIndex: load.audioServerIndex.map { Int32(engineID(Int($0))) })
                guard !Task.isCancelled, attempt == mine else { return }
                engine.play()
                loaded = true
                deliver(.duration(seconds: engine.duration > 0 ? engine.duration : start.runtime))
                deliver(.loadFinished(attempt: mine))
                emitTracks()
                if load.subtitleServerIndex >= 0 { selectSubtitle(Int32(load.subtitleServerIndex)) }
            } catch is CancellationError {
            } catch {
                guard attempt == mine else { return }
                if url.isFileURL, start.runtime > 0, !declaresRuntime, error.localizedDescription.contains("zero duration") {
                    declaresRuntime = true
                    retriedWithRuntime = true
                    self.load(load)
                    return
                }
                failure = "Laden: \(error.localizedDescription)"
                deliver(.loadFailed(attempt: mine, message: failure ?? "", kind: engine.errorInfo?.kind.rawValue))
            }
        }
    }

    func play() { engine.play() }
    func pause() { engine.pause() }
    func seek(_ seconds: Double) {
        if ended, let load = lastLoad { var again = load; again.start = seconds; self.load(again); return }
        Task { @MainActor [weak self] in
            await self?.engine.seek(to: max(seconds, 0))
            self?.deliver(.seekLanded(target: seconds))
        }
    }
    private var lastLoad: PlayerLoad?
    func setRate(_ tempo: Float) { engine.setRate(tempo) }
    func setVolume(_ percent: UInt8) {}
    func setAudioDelay(milliseconds: Int32) { engine.setAudioDelay(Double(milliseconds) / 1000) }
    func setSubtitleDelay(milliseconds: Int32) {}
    func selectAudio(_ serverIndex: Int32) {
        let wanted = engineID(Int(serverIndex))
        if engine.audioTracks.contains(where: { $0.id == wanted }) { engine.selectAudioTrack(index: wanted) }
        audioActive = Int(serverIndex)
        emitTracks()
    }
    func selectSubtitle(_ serverIndex: Int32) {
        if serverIndex < 0 { engine.clearSubtitle(); subtitleActive = nil; emitTracks(); return }
        let server = CoreTrackIDs.externalPosition(of: Int64(serverIndex)).flatMap { position in
            externalIDs.first { $0.value == AetherEngine.externalSubtitleTrackIDBase + position }?.key
        } ?? Int(serverIndex)
        let wanted = externalIDs[server] ?? engineID(server)
        if engine.subtitleTracks.contains(where: { $0.id == wanted }) { engine.selectSubtitleTrack(index: wanted) }
        emitTracks()
    }
    func setFill(_ on: Bool) {}
    func place(_ rect: PlayerRect) {}
    func stop(resetDisplay: Bool) { task?.cancel(); engine.stop(resetDisplayCriteria: resetDisplay) }
    func pip(_ command: PlayerPip) {}
}
