import AVFoundation
import AVKit
import Combine
import CoreMedia
import JellyfinKit
import SwiftlyAether
import SwiftlyCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// **AetherEngine behind the player surface's facade**, the only engine.
///
/// FFmpeg takes the file apart and the system decoders show it (Dolby Vision, HDR, display
/// matching). It reads the unchanged file (Direct Play, never a transcode) with the address the
/// app already has (also a file on the device); the Jellyfin key is in that address, own headers go
/// along in the load options.
///
/// The screens and the controls talk to ``PlaybackBackend``; this class only translates. The
/// tracks are the server's streams (`request.source`); FFmpeg's stream index and the server's
/// `Index` are the same number for the file's own tracks, which is checked against the engine's
/// own list before a track is selected. Text and picture subtitles are drawn by the app
/// (``SubtitleOverlay``, the saved look).
///
/// Failures are not handled here: the host shows them (``VLCPlayerView/avFailed(_:)``).
@MainActor
final class AetherPlayerEngine: NSObject, PlaybackBackend {
    let label = "Aether"

    private(set) var request: EngineRequest
    let overlay = SubtitleOverlay()
    /// The engine was loaded with raw ASS event lines (the switch was on then); the switch can change while playing.
    private var markupPreserved = false
    private var styleSheetCache: (header: String, sheet: ASSStyleSheet?)?
    private let engine: AetherEngine
    private let surface = AetherPlayerView()
    #if !canImport(UIKit)
    private var overlayHost: SubtitleHostView?
    #endif
    private weak var host: VLCPlayerView?
    private let url: URL
    private let headers: [String: String]
    private let runtime: Double
    /// A built download (one audio track picked) has no duration in its header: the second try declares the stored runtime.
    private var declaresRuntime = false

    private(set) var audioIndex: Int?
    private(set) var subtitleIndex = -1
    /// What was last handed to the engine, so a track list that publishes again does not
    /// select the same track twice.
    private var audioApplied: Int?
    private var subtitleApplied: Int?
    /// The server's number of an external subtitle file -> the engine's track id for it
    /// (`externalSubtitleTrackIDBase` + position in the list handed over at load).
    private var externalTrackIDs: [Int: Int] = [:]
    private var tracksChecked = false

    /// **The core's engine events** (`CoreAetherPort` sets it). With a receiver the engine reports
    /// what it learns as `PlayerEngineEvent`s and does not call the old facade (`host.av...`); without
    /// one it behaves as before.
    var events: (@MainActor (SwiftlyCore.PlayerEngineEvent) -> Void)?
    private func emit(_ event: SwiftlyCore.PlayerEngineEvent) { events?(event) }
    private var lastClockEvent = Date.distantPast
    private var loadReported = 0

    private var bag = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var sentry: Task<Void, Never>?
    private var attempt = 0

    /// The start position or an outstanding seek; shown instead of the engine's clock until the
    /// seek has landed.
    private(set) var seekTarget: Double?
    private var lastPosition: Double = 0
    private var ended = false
    private(set) var pictureShown = false
    private var stopped = false
    private var running = false
    private var tempoValue: Float = 1
    private var fillOn = false

    var subtitleDelay = Delay.null {
        didSet {
            refreshSubtitle()
            // The Picture in Picture window draws the cues into the frames itself; it must use the same delay.
            engine.setSoftwareSubtitleDelay(Double(subtitleDelay.milliseconds) / 1000)
        }
    }
    var audioDelay = Delay.null {
        didSet { if audioDelay != oldValue { engine.setAudioDelay(Double(audioDelay.milliseconds) / 1000) } }
    }

    #if os(iOS)
    private var pip: AVPictureInPictureController?
    private var pipWatch: NSKeyValueObservation?
    /// Identity of the layer the controller was built for; a reload gives the engine a new one.
    private var pipSource: ObjectIdentifier?
    #endif

    /// - Throws: if the engine cannot be created (the host shows the start error then).
    init(host: VLCPlayerView, request: EngineRequest, url: URL, audioIndex: Int?,
         subtitleIndex: Int) throws {
        self.host = host
        self.request = request
        self.url = url
        self.audioIndex = audioIndex
        self.subtitleIndex = subtitleIndex
        runtime = request.source.runtimeSeconds ?? 0
        headers = Dictionary(OwnHeaders.of(url).map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
        engine = try AetherEngine()
        // The engine's own lines (open, probe, route, errors) go into the app log: without them a
        // load that hangs shows nothing.
        EngineLog.handler = { line in AppLog.writeOut("[AetherEngine] \(line)") }
        super.init()
        #if canImport(UIKit)
        // iOS needs the category before the first sound; tvOS negotiates its route itself
        // (the engine documents that it must not activate the session there).
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        #endif
        host.insertSubview(surface, at: 0)
        #else
        host.addSubview(surface, positioned: .below, relativeTo: nil)
        #endif
        #if canImport(UIKit)
        (host.layer as CALayer?)?.addSublayer(overlay.layer)
        #else
        // **On the Mac the overlay is a subview above the surface, not a loose sublayer.** The surface is a layer-backed
        // `NSView` whose black backing layer AppKit appends to the host's sublayers when it syncs, which can be after
        // the overlay layer was added: then the surface covered every subtitle (reported: "no subtitles on the Mac, for
        // every title"). The order of subviews is the order AppKit keeps its layers in.
        let hosting = SubtitleHostView(hosting: overlay.layer)
        host.addSubview(hosting, positioned: .above, relativeTo: surface)
        overlayHost = hosting
        #endif
        place(in: host.bounds)
        engine.bind(view: surface)
        watch()
    }

    // MARK: Loading

    /// Opens the address and starts at `start`.
    func load(start: Double) {
        guard !stopped else { return }
        attempt += 1
        let mine = attempt
        ended = false
        pictureShown = false
        lastPosition = start
        tracksChecked = false
        audioApplied = nil
        subtitleApplied = nil
        failureReported = false
        seekTarget = start > 0.5 ? start : nil
        // A picture that would come out green is worse than a message (see the property). A transcode by the server
        // (the plan asked for one) has no Dolby Vision left, so it plays; the message stays for a server that cannot.
        #if !os(macOS)
        if request.source.isAV1DolbyVisionWithoutBaseLayer, !request.transcoded {
            failed(String(localized: "Dieses Video (Dolby Vision, Profil 10.0, AV1) zeigt dieses Gerät nicht richtig, und dein Server kann es nicht umrechnen. Wähle, wenn es sie gibt, eine andere Fassung."))
            return
        }
        #endif
        watchStart(mine)
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var options = LoadOptions()
            options.httpHeaders = self.headers
            options.applySwiftlyAudioPolicy()
            // The fonts of ASS subtitles are not used (the app draws its own look): do not read them.
            options.skipsContainerAttachments = true
            // "Use the file's subtitle style": the engine then hands ASS / SSA cues over as raw event lines
            // (tags intact) and the header with the styles, and the overlay draws what the file says.
            self.markupPreserved = self.overlay.keepsFileStyle
            options.preserveASSMarkup = self.markupPreserved
            if self.declaresRuntime, self.runtime > 0 { options.declaredDurationSeconds = self.runtime }
            #if os(iOS)
            // Picture in Picture on the native route: the window shows only the video, so the subtitles travel as the
            // engine's own WebVTT renditions (text tracks, bitmap tracks through its recognition) and are switched on
            // when the window opens (`pictureInPictureSubtitles`).
            options.prepareNativeSubtitles = true
            #endif
            // **External subtitle files** (next to the film on the server) are not in the container:
            // the engine only knows them when they are handed over at load. Without this they
            // never showed (reported from the beta: "no subtitles in any language").
            // On a server transcode (HLS) the container carries no text track at all: the server delivers it as a file
            // (`IsExternal` stays false), so every file handed over is loaded.
            let external = self.request.subtitleFiles.filter { file in
                (self.request.source.mediaStreams ?? []).contains {
                    $0.index == file.index && (self.request.transcoded ? $0.isDeliveredFile : $0.isExternal == true)
                }
            }
            self.externalTrackIDs = Dictionary(uniqueKeysWithValues: external.enumerated().map {
                ($0.element.index, AetherEngine.externalSubtitleTrackIDBase + $0.offset)
            })
            let tracks = external.map { file in
                let stream = (self.request.source.mediaStreams ?? []).first { $0.index == file.index }
                return ExternalSubtitleTrack(url: file.address, name: stream?.displayTitle,
                                             language: stream?.language, isForced: stream?.isForced ?? false,
                                             formatHint: file.address.pathExtension.isEmpty ? "srt" : nil)
            }
            // A file declared at load on a server transcode (HLS) becomes a WebVTT rendition of the server's stream, which
            // AVPlayer draws itself in the system's caption style (and our layer never shows). Registered after the load
            // the track is overlay-only: the engine decodes the file and the app draws the cues in its own look.
            let afterLoad = self.request.transcoded ? tracks : []
            options.externalSubtitles = self.request.transcoded ? [] : tracks
            // The wanted audio track goes in with the load: a selection afterwards reloads the session.
            var firstAudio: Int?
            if let want = self.audioIndex, (self.request.source.mediaStreams ?? [])
                .contains(where: { $0.type == "Audio" && $0.index == want }) {
                firstAudio = self.engineTrackID(forServerIndex: want)
                self.audioApplied = want
            }
            #if os(tvOS)
            // The Match Content switch of the box; the engine drives the display mode itself.
            let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow }
            if let window { options.matchContentEnabled = window.avDisplayManager.isDisplayCriteriaMatchingEnabled }
            #endif
            do {
                _ = try await self.engine.load(url: self.url, startPosition: start > 0.5 ? start : nil,
                                               options: options,
                                               audioSourceStreamIndex: firstAudio.map(Int32.init))
                guard !Task.isCancelled, !self.stopped, self.attempt == mine else { return }
                for track in afterLoad { self.engine.addExternalSubtitleTrack(track) }
                self.engine.play()
                if self.tempoValue != 1 { self.engine.setRate(self.tempoValue) }
                self.engine.videoGravity = self.fillOn ? .resizeAspectFill : .resizeAspect
                self.seekTarget = nil
                AppLog.writeOut("[Aether] bereit · \(Int(self.durationSeconds)) s · "
                    + "\(self.engine.videoRoute.rawValue) · Ton \(self.engine.audioDelivery.rawValue)")
                self.reportLoaded(mine)
                self.checkTracks()
            } catch is CancellationError {
                // A newer load or a stop took over; that one reports.
            } catch {
                guard !self.stopped, self.attempt == mine else { return }
                if self.runtimeRetryDue(error.localizedDescription) {
                    AppLog.writeOut("[Aether] Datei ohne Laufzeit im Kopf: zweiter Versuch mit \(Int(self.runtime)) s")
                    self.declaresRuntime = true
                    self.load(start: start)
                    return
                }
                let kind = self.engine.errorInfo.map { " (\($0.kind.rawValue))" } ?? ""
                if self.events != nil {
                    self.emit(.loadFailed(attempt: UInt32(mine), message: "Laden: \(error.localizedDescription)\(kind)",
                                          kind: self.engine.errorInfo?.kind.rawValue))
                } else {
                    self.failed("Laden: \(error.localizedDescription)\(kind)")
                }
            }
        }
    }

    /// **No picture within 30 s counts as a failure**, like the AVPlayer path: the host then
    /// shows the start error.
    private func watchStart(_ mine: Int) {
        sentry?.cancel()
        sentry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(PlayerStartTimeout.seconds))
            guard !Task.isCancelled, let self, self.attempt == mine, !self.stopped,
                  !self.pictureShown else { return }
            if self.events != nil { self.emit(.startWatchdog(attempt: UInt32(mine))); return }
            self.failed("kein Bild nach \(PlayerStartTimeout.seconds) s")
        }
    }

    private func watch() {
        engine.$state.sink { [weak self] state in
            self?.stateSwitched(state)
        }.store(in: &bag)
        engine.$hasFirstFrameReadyForDisplay.sink { [weak self] shown in
            guard let self, shown, !self.pictureShown, !self.stopped else { return }
            self.pictureShown = true
            self.sentry?.cancel()
            AppLog.writeOut("[Aether] erstes Bild")
            self.emit(.firstFrame)
            // **The first picture settles the start.** When the engine rebuilds itself for the
            // chosen audio track right after `load`, the original `load` call never reports back
            // (measured: no "bereit" line, the loading screen stayed until a seek). The picture is
            // proof enough that the start landed.
            if self.seekTarget != nil {
                self.seekTarget = nil
                self.engine.videoGravity = self.fillOn ? .resizeAspectFill : .resizeAspect
                if self.tempoValue != 1 { self.engine.setRate(self.tempoValue) }
                AppLog.writeOut("[Aether] Start gelandet · erstes Bild · \(Int(self.durationSeconds)) s · "
                    + "\(self.engine.videoRoute.rawValue) · Ton \(self.engine.audioDelivery.rawValue)")
                self.reportLoaded(self.attempt)
                self.checkTracks()
            }
        }.store(in: &bag)
        engine.clock.$currentTime.sink { [weak self] seconds in
            guard let self, !self.stopped else { return }
            if seconds.isFinite, seconds >= 0, self.seekTarget == nil, !self.ended { self.lastPosition = seconds }
            self.refreshSubtitle()
            // Four times a second is plenty: the core ticks on its own clock.
            if self.events != nil, Date().timeIntervalSince(self.lastClockEvent) >= 0.25 {
                self.lastClockEvent = Date()
                self.emit(.clock(position: self.position, sourceTime: self.engine.clock.sourceTime))
            }
        }.store(in: &bag)
        engine.$audioTracks.sink { [weak self] _ in self?.checkTracks() }.store(in: &bag)
        engine.$subtitleTracks.sink { [weak self] _ in self?.checkTracks() }.store(in: &bag)
        engine.$subtitleCues.sink { [weak self] _ in
            self?.refreshSubtitle()
            self?.emitCues()
        }.store(in: &bag)
        // The source has sound and none of it could be delivered: a picture without sound is
        // worse than an error message.
        engine.$audioDelivery.sink { [weak self] delivery in
            guard let self, !self.stopped, delivery == .droppedNoPipeline else { return }
            if self.events != nil { self.emit(.audioDelivery(dropped: true)); return }
            self.failed("Ton nicht lieferbar")
        }.store(in: &bag)
        #if os(iOS)
        engine.$videoRoute.sink { [weak self] _ in self?.rebuildPiP() }.store(in: &bag)
        engine.$softwarePiPSource.sink { [weak self] _ in self?.rebuildPiP() }.store(in: &bag)
        engine.$currentAVPlayer.sink { [weak self] _ in self?.rebuildPiP() }.store(in: &bag)
        #endif
    }

    // MARK: Events

    private func stateSwitched(_ state: PlaybackState) {
        guard !stopped else { return }
        // The internal play/pause of a paused-seek frame (`PausedSeekFrame`) is not the user's: the screen stays paused.
        if nudge != nil { return }
        emitState(state)
        switch state {
        case .playing:
            runChanged(true)
        case .paused:
            runChanged(false)
        case .ended:
            ended = true
            runChanged(false)
            AppLog.writeOut("[Aether] Ende")
        case .error(let message):
            let kind = engine.errorInfo.map { " (\($0.kind.rawValue))" } ?? ""
            failed("\(message)\(kind)")
        case .idle, .loading, .seeking:
            break
        }
    }

    private func runChanged(_ go: Bool) {
        guard go != running else { return }
        running = go
        if events == nil { host?.avRunning(go) }
        #if canImport(UIKit)
        if UIApplication.shared.isIdleTimerDisabled != go { UIApplication.shared.isIdleTimerDisabled = go }
        #endif
        #if os(iOS)
        pip?.invalidatePlaybackState()
        #endif
    }

    private var failureReported = false

    private func failed(_ reason: String) {
        guard !stopped, !failureReported else { return }
        // A built download without a header duration is tried once more with its stored runtime (`load`'s catch
        // does that); reporting this first failure would send the screen to the stream while the retry runs.
        if runtimeRetryDue(reason) { return }
        // A stream that died within the last seconds is the end of the film, not a failure.
        if durationSeconds > 0, position > durationSeconds - 3 { ended = true; return }
        failureReported = true
        AppLog.writeOut("[Aether] Fehler: \(reason)")
        if events != nil { emit(.state(state: .error(message: reason, kind: nil))) } else { host?.avFailed(reason) }
    }

    // MARK: Core events

    /// The load of attempt `mine` is through: duration and picture size, then `loadFinished` once.
    private func reportLoaded(_ mine: Int) {
        guard events != nil, loadReported != mine else { return }
        loadReported = mine
        emit(.duration(seconds: durationSeconds))
        let size = videoSize
        if size.width > 0, size.height > 0 { emit(.videoSize(width: size.width, height: size.height)) }
        emit(.loadFinished(attempt: UInt32(mine)))
    }

    /// The failure is the missing-duration one of a built download and the retry with the stored runtime is still due.
    private func runtimeRetryDue(_ reason: String) -> Bool {
        RuntimeRetry.isDue(isFileURL: url.isFileURL, storedRuntime: runtime, alreadyDeclared: declaresRuntime, reason: reason)
    }

    private func emitState(_ state: PlaybackState) {
        guard events != nil else { return }
        // The engine's first "error" of a built download is not final: the retry runs next. Telling the core (and the
        // screen behind it) now sent the screen to the stream while the file loaded a second time.
        if case .error(let message) = state, runtimeRetryDue(message) { return }
        switch state {
        case .idle: emit(.state(state: .idle))
        case .loading: emit(.state(state: .loading))
        case .playing: emit(.state(state: .playing))
        case .paused: emit(.state(state: .paused))
        case .seeking: emit(.state(state: .seeking))
        case .ended: emit(.state(state: .ended))
        case .error(let message):
            emit(.state(state: .error(message: message, kind: engine.errorInfo?.kind.rawValue)))
        }
    }

    /// The server's streams are the track lists (as the panels always showed them); the numbers are
    /// the server's `Index`.
    func emitTracks() {
        guard events != nil else { return }
        func list(_ type: String) -> [SwiftlyCore.PlayerTrack] {
            (request.source.mediaStreams ?? []).filter { $0.type == type }.compactMap { stream in
                guard let index = stream.index else { return nil }
                return SwiftlyCore.PlayerTrack(
                    id: coreTrackID(forServerIndex: index, type: type), codec: stream.codec ?? "", language: stream.language,
                    name: stream.displayTitle ?? "", channels: Int64(stream.channels ?? 0),
                    isDefault: stream.isDefault ?? false, isForced: stream.isForced ?? false)
            }
        }
        emit(.tracks(audio: list("Audio"), subtitles: list("Subtitle"),
                     activeAudio: audioIndex.map(Int64.init),
                     activeSubtitle: subtitleIndex >= 0 ? coreTrackID(forServerIndex: subtitleIndex, type: "Subtitle") : nil))
    }

    /// The core's number of a track: the server's `Index`, except an external subtitle file, which the core selects as
    /// `CoreTrackIDs.externalBase` + its place in the list handed over at load (see `CoreTrackIDs`).
    private func coreTrackID(forServerIndex index: Int, type: String) -> Int64 {
        guard type == "Subtitle", let engineID = externalTrackIDs[index] else { return Int64(index) }
        return CoreTrackIDs.external(position: engineID - AetherEngine.externalSubtitleTrackIDBase)
    }

    /// The server's `Index` for a number the core selected: an external file's core number maps back to its file.
    func serverIndex(forCoreTrackID id: Int) -> Int {
        guard let position = CoreTrackIDs.externalPosition(of: Int64(id)) else { return id }
        let engineID = AetherEngine.externalSubtitleTrackIDBase + position
        return externalTrackIDs.first { $0.value == engineID }?.key ?? id
    }

    private func emitCues() {
        guard events != nil else { return }
        emit(.cues(cues: engine.subtitleCues.map { cue in
            let body: SwiftlyCore.PlayerCueBody
            switch cue.body {
            case .text(let text): body = .text(text: text)
            case .richText(let runs): body = .rich(runs: runs.map(\.text))
            case .image(let image):
                body = .image(x: image.position.origin.x, y: image.position.origin.y,
                              width: image.position.width, height: image.position.height,
                              canvasWidth: image.canvasSize.width, canvasHeight: image.canvasSize.height)
            }
            return SwiftlyCore.PlayerCue(id: Int64(cue.id), start: cue.startTime, end: cue.endTime, body: body)
        }))
    }

    // MARK: Position

    var position: Double {
        if ended, durationSeconds > 0 { return durationSeconds }
        if let seekTarget { return seekTarget }
        let now = engine.clock.currentTime
        return now.isFinite && now >= 0 ? now : lastPosition
    }

    var durationSeconds: Double {
        let value = engine.duration
        return value.isFinite && value > 0 ? value : runtime
    }

    var isPlaying: Bool { running }
    var startSettled: Bool { seekTarget == nil }
    var lastGood: Double { lastPosition }

    var videoSize: CGSize {
        let width = Double(engine.sourceVideoWidth) * engine.sourceVideoPixelAspectRatio
        return CGSize(width: width, height: Double(engine.sourceVideoHeight))
    }

    func move(to seconds: Double) {
        let target = max(seconds, 0)
        if ended { reload(at: target); return }
        // A newer seek ends the frame step of the previous one (paused scrubbing never stacks plays).
        endNudge()
        seekTarget = target
        lastPosition = target
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.engine.seek(to: target)
            guard self.seekTarget == target else { return }
            self.seekTarget = nil
            self.refreshSubtitle()
            self.emit(.seekLanded(target: target))
            self.showFrameWhilePaused(at: target)
        }
        refreshSubtitle()
        #if os(iOS)
        pip?.invalidatePlaybackState()
        #endif
    }

    // MARK: Paused seek, frame step

    /// The software route (mkv, avi, AV1, VP9...) parks its decode loop while paused, so after a seek the picture
    /// stays on the old frame until Play (AetherEngine cannot be changed here). This steps ONE frame: it mutes,
    /// plays until the first frame at the target is handed to the display and the clock has reached it, then pauses
    /// again. The screen is not told (`stateSwitched` ignores it while `nudge` is set), the volume comes back, and
    /// the position ends within one frame of the target. A newer seek, a pause or a play ends it first.
    private struct Nudge {
        let task: Task<Void, Never>
        let volume: Float
    }
    private var nudge: Nudge?
    /// Set by the frame-time observer on the decode thread, read by the step.
    private let steppedFrame = FrameGate()

    private func showFrameWhilePaused(at target: Double) {
        #if DEBUG
        // Test seam of the running-app check: the same build shows the old behaviour (picture stays) for the red run.
        if ProcessInfo.processInfo.arguments.contains("-SwiftlyLiveNoFrameStep") { return }
        #endif
        guard !stopped, !running, nudge == nil, engine.state == .paused,
              engine.videoRoute == .software, !engine.isLive else { return }
        steppedFrame.arm(target: target)
        engine.setSoftwareVideoFrameTimeObserver { [steppedFrame] frame in
            steppedFrame.note(frame.presentation.seconds)
        }
        let saved = engine.volume
        engine.volume = 0
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.engine.play()
            let deadline = ContinuousClock.now + .seconds(1.5)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                if let pts = self.steppedFrame.frame, self.engine.clock.currentTime >= pts { break }
                try? await Task.sleep(for: .milliseconds(8))
            }
            guard !Task.isCancelled else { return }
            let drift = self.engine.clock.currentTime - target
            self.endNudge()
            AppLog.writeOut("[Aether] Einzelbild beim Pausen-Sprung \(String(format: "%.2f", target)) s, Drift \(String(format: "%.3f", drift)) s")
        }
        nudge = Nudge(task: task, volume: saved)
        AppLog.writeOut("[Aether] Einzelbild-Schritt ab \(String(format: "%.2f", target)) s")
    }

    /// Back to the paused transport: pause, volume, observer. Safe when no step runs.
    private func endNudge() {
        guard let step = nudge else { return }
        step.task.cancel()
        engine.pause()
        engine.volume = step.volume
        engine.setSoftwareVideoFrameTimeObserver(nil)
        nudge = nil
        // A step that ran into the end of the file left the engine somewhere else than paused: the screen hears that.
        if engine.state != .paused { stateSwitched(engine.state) }
    }

    /// The user pressed Play while a step runs: keep the engine playing, keep the volume, tell the screen.
    private func nudgeBecamePlay() {
        guard let step = nudge else { return }
        nudge = nil
        step.task.cancel()
        engine.volume = step.volume
        engine.setSoftwareVideoFrameTimeObserver(nil)
        stateSwitched(engine.state)
    }

    /// `.ended` is final for the engine: a replay is a new load of the same address.
    private func reload(at seconds: Double) {
        AppLog.writeOut("[Aether] neu laden ab \(Int(seconds)) s")
        load(start: seconds)
    }

    func pause() {
        endNudge()
        engine.pause()
    }

    func resume() {
        if ended { reload(at: 0); return }
        nudgeBecamePlay()
        engine.play()
    }

    // MARK: Speed, volume, fit

    var tempo: Float {
        get { tempoValue }
        set {
            tempoValue = newValue
            if running || engine.state == .paused { engine.setRate(newValue) }
        }
    }

    func volume(_ percent: Int) {
        let level = Float(min(max(percent, 0), 100)) / 100
        // During a frame step the engine is muted; the new level is what comes back.
        if let step = nudge { nudge = Nudge(task: step.task, volume: level); return }
        engine.volume = level
    }

    func fill(_ on: Bool) {
        fillOn = on
        engine.videoGravity = on ? .resizeAspectFill : .resizeAspect
        refreshSubtitle()
    }

    // MARK: Layout

    func place(in bounds: CGRect) {
        surface.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.layer.frame = bounds
        CATransaction.commit()
        refreshSubtitle()
    }

    // MARK: Tracks

    func switchAudio(to index: Int) {
        guard index != audioIndex else { return }
        audioIndex = index
        audioApplied = nil
        checkTracks()
    }

    /// **A file on the device has no server description**: the lists then come from the engine's
    /// own tracks (same numbers), so the panels, the memory and the selection work as for a server title.
    /// A kind the stored title already lists (the subtitles a download kept, see `DownloadedSubtitles`) stays as it is;
    /// only the missing kinds come from the engine.
    private func adoptEngineTracks(audio: [TrackInfo], subtitles: [TrackInfo]) {
        guard request.itemID.isEmpty else { return }
        let known = request.source.mediaStreams ?? []
        let wantAudio = !known.contains { $0.type == "Audio" }
        let wantSubtitles = !known.contains { $0.type == "Subtitle" }
        guard (wantAudio && !audio.isEmpty) || (wantSubtitles && !subtitles.isEmpty) else { return }
        func entry(_ track: TrackInfo, _ type: String) -> [String: Any] {
            ["Index": track.id, "Type": type, "Codec": track.codec, "Language": track.language ?? "",
             "DisplayTitle": track.name, "Channels": track.channels, "IsDefault": track.isDefault,
             "IsForced": track.isForced]
        }
        var json: [String: Any] = [:]
        if !known.isEmpty,
           let data = try? JSONEncoder().encode(request.source),
           let old = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { json = old }
        let kept = (json["MediaStreams"] as? [[String: Any]]) ?? []
        json["MediaStreams"] = kept + (wantAudio ? audio.map { entry($0, "Audio") } : [])
            + (wantSubtitles ? subtitles.map { entry($0, "Subtitle") } : [])
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let source = try? JSONDecoder().decode(MediaSource.self, from: data) else { return }
        request = EngineRequest(itemID: request.itemID, source: source, subtitleFiles: request.subtitleFiles,
                                transcoded: request.transcoded)
        if audioIndex == nil { audioIndex = engine.activeAudioTrackIndex ?? audio.first(where: \.isDefault)?.id ?? audio.first?.id }
        audioApplied = audioIndex
        host?.trackIndicesReport(TrackIndices(audio: audioIndex, subtitle: subtitleIndex))
        AppLog.writeOut("[Aether] Datei ohne Beschreibung: \(wantAudio ? audio.count : 0) Töne, "
            + "\(wantSubtitles ? subtitles.count : known.filter { $0.type == "Subtitle" }.count) Untertitel "
            + (wantSubtitles ? "aus der Engine" : "aus dem Download"))
    }

    /// Hands the wanted tracks to the engine once its own lists are there, and only if the engine
    /// has the track under that number. A mismatch is logged and the engine's own choice plays.
    private func checkTracks() {
        guard !stopped else { return }
        let audio = engine.audioTracks
        let subtitles = engine.subtitleTracks
        guard !audio.isEmpty || !subtitles.isEmpty else { return }
        adoptEngineTracks(audio: audio, subtitles: subtitles)
        emitTracks()
        if let want = audioIndex, audioApplied != want, !audio.isEmpty {
            audioApplied = want
            let wanted = engineTrackID(forServerIndex: want)
            if audio.contains(where: { $0.id == wanted }) {
                if engine.activeAudioTrackIndex != wanted { engine.selectAudioTrack(index: wanted) }
            } else {
                AppLog.writeOut("[Aether] Tonspur \(want) nicht in der Liste der Engine")
            }
        }
        guard !subtitles.isEmpty || engine.state != .loading else { return }
        if subtitleIndex >= 0 {
            guard subtitleApplied != subtitleIndex else { return }
            subtitleApplied = subtitleIndex
            let wanted = engineTrackID(forServerIndex: subtitleIndex)
            // The engine's own stream table next to the server number: a wrong place shows here (Plex counts by id).
            AppLog.writeOut("[Spuren] Untertitel Server \(subtitleIndex) -> Engine \(wanted); Engine kennt "
                + subtitles.map { "\($0.id):\($0.codec)\($0.isForced ? ":forced" : "")" }.joined(separator: " "))
            if subtitles.contains(where: { $0.id == wanted }) {
                engine.selectSubtitleTrack(index: wanted)
            } else {
                host?.avHandOver(audio: nil, subtitle: subtitleIndex, reason: "Untertitel \(subtitleIndex) nicht in der Engine")
            }
        } else if subtitleApplied != -1 {
            subtitleApplied = -1
            // The engine may switch a forced or default track on by itself; the app's own rule
            // decided already.
            if engine.activeSubtitleTrackIndex != nil { engine.clearSubtitle() }
        }
    }

    /// The number the engine knows a track under: an external file's engine id, else the stream's place in the file
    /// (Plex numbers its streams by id, the engine by position), else the server's own `Index` (Jellyfin, Emby).
    func engineTrackID(forServerIndex index: Int) -> Int {
        externalTrackIDs[index] ?? request.source.engineTrackIndex(forServerIndex: index)
    }

    @discardableResult
    func selectSubtitle(_ index: Int) -> Bool {
        if index < 0 {
            subtitleIndex = -1
            subtitleApplied = nil
            if engine.activeSubtitleTrackIndex != nil { engine.clearSubtitle() }
            subtitleApplied = -1
            refreshSubtitle()
            return true
        }
        guard (request.source.mediaStreams ?? []).contains(where: { $0.type == "Subtitle" && $0.index == index })
        else { return false }
        subtitleIndex = index
        subtitleApplied = nil
        checkTracks()
        return true
    }

    // MARK: Subtitle text drawn by the app

    /// The cues on screen now. With "use the file's subtitle style" off the text is flattened: the app's
    /// look (size, colour, outline) applies to all of it, as with the other engines. With it on, ASS / SSA
    /// cues keep the file's style (colours with opacity, outline, shadow, bold, italic, override tags) and
    /// SRT keeps its colour and italic tags; the saved look fills the rest.
    private func refreshSubtitle() {
        guard !stopped else { return }
        var line: String?
        var styled: [ASSRun] = []
        var images: [(id: Int, cgImage: CGImage, position: CGRect, canvas: CGSize)] = []
        if subtitleIndex >= 0 {
            let time = engine.clock.sourceTime - Double(subtitleDelay.milliseconds) / 1000
            let keep = overlay.keepsFileStyle
            let sheet = keep ? activeStyleSheet() : nil
            var pieces: [ASSRun] = []
            for cue in engine.subtitleCues where cue.startTime <= time && time < cue.endTime {
                var runs: [ASSRun]
                switch cue.body {
                case .text(let text):
                    if keep, sheet != nil || activeTrackIsASS {
                        runs = ASSCue.runs(eventLines: text, sheet: sheet)
                    } else if markupPreserved {
                        // The switch went off while playing: the cue is still a raw event line; its words only.
                        let words = ASSCue.runs(eventLines: text, sheet: nil).map(\.text).joined()
                        runs = [ASSRun(text: words)]
                    } else {
                        runs = [ASSRun(text: text.replacingOccurrences(of: "\\N", with: "\n"))]
                    }
                case .richText(let parts):
                    runs = keep
                        ? parts.map { ASSRun(text: $0.text, primary: $0.color.map { SubtitleColour(red: $0.r, green: $0.g, blue: $0.b) },
                                             bold: $0.isBold ? true : nil, italic: $0.isItalic ? true : nil) }
                        : [ASSRun(text: parts.map(\.text).joined())]
                case .image(let image):
                    images.append((cue.id, image.cgImage, image.position, image.canvasSize))
                    continue
                }
                guard !runs.isEmpty else { continue }
                if !pieces.isEmpty { pieces.append(ASSRun(text: "\n")) }
                pieces += runs
            }
            if !pieces.isEmpty {
                line = pieces.map(\.text).joined()
                if keep, pieces.contains(where: \.isStyled) { styled = pieces }
            }
        }
        overlay.displayScale = hostScale
        overlay.show(images: images, in: surface.bounds, picture: pictureRect)
        overlay.show(line, styled: styled, in: surface.bounds, picture: pictureRect)
        #if DEBUG
        overlayLine = line
        #endif
    }

    #if DEBUG
    /// For the running-app matrix (`LiveRun`): the text on screen and the engine's active subtitle track.
    private var overlayLine: String?
    var liveSubtitleState: [String: Any] {
        ["engineTrack": engine.activeSubtitleTrackIndex ?? -1, "line": overlayLine ?? "", "cues": engine.subtitleCues.count]
    }
    #endif

    /// The styles of the active ASS / SSA track: the header of an embedded track, or of the sidecar the
    /// engine decoded. Parsed once per header.
    private func activeStyleSheet() -> ASSStyleSheet? {
        let embedded = engine.activeSubtitleTrackIndex.flatMap { id in
            engine.subtitleTracks.first { $0.id == id }?.assHeader
        }
        guard let header = embedded ?? engine.sidecarASSHeader, !header.isEmpty else { return nil }
        if let cached = styleSheetCache, cached.header == header { return cached.sheet }
        // A header made by a converter (SRT turned into ASS) is no style of the file: the saved look applies.
        let parsed = ASSStyleSheet.parse(header)
        let sheet = parsed.isConverterDefault ? nil : parsed
        styleSheetCache = (header, sheet)
        return sheet
    }

    private var activeTrackIsASS: Bool {
        guard let id = engine.activeSubtitleTrackIndex else { return false }
        return engine.subtitleTracks.first { $0.id == id }?.codec.lowercased() == "ass"
    }

    /// The scale of the screen the player view is on, for the overlay (nil until the view has a screen).
    private var hostScale: CGFloat? {
        #if canImport(UIKit)
        let scale = host?.traitCollection.displayScale ?? 0
        #else
        let scale = host?.window?.backingScaleFactor ?? 0
        #endif
        return scale > 0 ? scale : nil
    }

    /// Where the video really is inside the surface, for the subtitle margin.
    private var pictureRect: CGRect {
        let size = videoSize
        guard !fillOn, size.width > 1, size.height > 1 else { return surface.bounds }
        return AVMakeRect(aspectRatio: size, insideRect: surface.bounds)
    }

    // MARK: Picture in picture

    #if os(iOS)
    /// PiP is built from whatever the engine shows now: its AVPlayer layer on the native route,
    /// the sample-buffer layer on the software route. A reload swaps both, so the controller is
    /// rebuilt when the source changed.
    private func rebuildPiP() {
        guard !stopped, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let controller: AVPictureInPictureController?
        let source: ObjectIdentifier?
        if let layer = engine.nativePlayerLayer {
            source = ObjectIdentifier(layer)
            guard source != pipSource else { return }
            controller = AVPictureInPictureController(playerLayer: layer)
            controller?.canStartPictureInPictureAutomaticallyFromInline = true
        } else if let software = engine.softwarePiPSource {
            source = ObjectIdentifier(software)
            guard source != pipSource else { return }
            controller = software.makePictureInPictureController()
        } else {
            return
        }
        pipSource = source
        pip?.delegate = nil
        controller?.delegate = self
        pip = controller
        pipWatch = controller?.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                self?.host?.onPiPAvailable?(possible)
                self?.emit(.pipPossible(on: possible))
            }
        }
    }

    var pipPossible: Bool { pip?.isPictureInPicturePossible ?? false }
    func startPiP() {
        // Before the system decides: the engine must keep the pipeline for the window.
        pictureInPictureSubtitles(true)
        pip?.startPictureInPicture()
    }
    func stopPiP() { pip?.stopPictureInPicture() }
    func refreshPiP() { pip?.invalidatePlaybackState() }
    #endif

    /// **Subtitles in the Picture in Picture window** (contract line 15). The window shows only the picture, never the
    /// app's overlay layer, so while it is open the engine puts the subtitles into the picture itself: on the software
    /// route it draws the active cue (text and bitmap) into every frame it hands over, on the native route it switches
    /// on the WebVTT rendition of the chosen track. Both follow a track change, a delay and a seek by themselves.
    /// Off again when the window closes: the overlay draws them then.
    func pictureInPictureSubtitles(_ on: Bool) {
        engine.pictureInPictureActive = on
        engine.setNativeSubtitleRendering(on)
    }

    /// The engine itself (test seam: the bench reads the frame it hands to the Picture in Picture window).
    var aether: AetherEngine { engine }

    // MARK: End

    /// `resetDisplay: false` keeps the panel in its mode across a hand-off to the next episode.
    func stop(resetDisplay: Bool = true) {
        guard !stopped else { return }
        stopped = true
        sentry?.cancel()
        loadTask?.cancel()
        bag.removeAll()
        #if os(iOS)
        pipWatch = nil
        pip?.delegate = nil
        pip = nil
        engine.pictureInPictureActive = false
        #endif
        engine.unbind(view: surface)
        engine.stop(resetDisplayCriteria: resetDisplay)
        #if canImport(UIKit)
        if UIApplication.shared.isIdleTimerDisabled { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
        surface.removeFromSuperview()
        overlay.layer.removeFromSuperlayer()
        #if !canImport(UIKit)
        overlayHost?.removeFromSuperview()
        #endif
    }
}

#if !canImport(UIKit)
/// Carries the subtitle overlay's layer on the Mac (a layer-hosting view): above the render surface in the subview
/// order, and never in the way of a click.
final class SubtitleHostView: NSView {
    init(hosting layer: CALayer) {
        super.init(frame: .zero)
        self.layer = layer      // before `wantsLayer`: that makes it a layer-hosting view
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif

#if os(iOS)
extension AetherPlayerEngine: @MainActor AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        // Keeps the engine's pipeline alive while the app is in the background.
        pictureInPictureSubtitles(true)
        host?.onPiPStateChanged?(true)
        emit(.pipActive(on: true))
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        pictureInPictureSubtitles(false)
        host?.onPiPStateChanged?(false)
        emit(.pipActive(on: false))
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: any Error) {
        pictureInPictureSubtitles(false)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
                                    done: @escaping (Bool) -> Void) {
        emit(.pipRestoreUi)
        done(true)
    }
}
#endif

/// The first frame at or after the target of a paused-seek frame step, as the decode thread reports it
/// (`setSoftwareVideoFrameTimeObserver`); read by the step on the main actor.
final class FrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var floor = 0.0
    private var first: Double?

    func arm(target: Double) {
        lock.lock(); floor = target - 0.02; first = nil; lock.unlock()
    }

    func note(_ pts: Double) {
        lock.lock(); if first == nil, pts.isFinite, pts >= floor { first = pts }; lock.unlock()
    }

    var frame: Double? { lock.lock(); defer { lock.unlock() }; return first }
}
