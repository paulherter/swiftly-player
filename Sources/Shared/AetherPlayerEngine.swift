import AVFoundation
import AVKit
import Combine
import CoreMedia
import JellyfinKit
import SwiftlyAether
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
    private let engine: AetherEngine
    private let surface = AetherPlayerView()
    private weak var host: VLCPlayerView?
    private let url: URL
    private let headers: [String: String]
    private let runtime: Double

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

    var subtitleDelay = Delay.null { didSet { refreshSubtitle() } }
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
        (host.layer as CALayer?)?.addSublayer(overlay.layer)
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
        watchStart(mine)
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var options = LoadOptions()
            options.httpHeaders = self.headers
            options.applySwiftlyAudioPolicy()
            // The fonts of ASS subtitles are not used (the app draws its own look): do not read them.
            options.skipsContainerAttachments = true
            // **External subtitle files** (next to the film on the server) are not in the container:
            // the engine only knows them when they are handed over at load. Without this they
            // never showed (reported from the beta: "no subtitles in any language").
            let external = self.request.subtitleFiles.filter { file in
                (self.request.source.mediaStreams ?? []).contains { $0.index == file.index && $0.isExternal == true }
            }
            self.externalTrackIDs = Dictionary(uniqueKeysWithValues: external.enumerated().map {
                ($0.element.index, AetherEngine.externalSubtitleTrackIDBase + $0.offset)
            })
            options.externalSubtitles = external.map { file in
                let stream = (self.request.source.mediaStreams ?? []).first { $0.index == file.index }
                return ExternalSubtitleTrack(url: file.address, name: stream?.displayTitle,
                                             language: stream?.language, isForced: stream?.isForced ?? false,
                                             formatHint: file.address.pathExtension.isEmpty ? "srt" : nil)
            }
            // The wanted audio track goes in with the load: a selection afterwards reloads the session.
            var firstAudio: Int?
            if let want = self.audioIndex, (self.request.source.mediaStreams ?? [])
                .contains(where: { $0.type == "Audio" && $0.index == want }) {
                firstAudio = want
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
                self.engine.play()
                if self.tempoValue != 1 { self.engine.setRate(self.tempoValue) }
                self.engine.videoGravity = self.fillOn ? .resizeAspectFill : .resizeAspect
                self.seekTarget = nil
                AppLog.writeOut("[Aether] bereit · \(Int(self.durationSeconds)) s · "
                    + "\(self.engine.videoRoute.rawValue) · Ton \(self.engine.audioDelivery.rawValue)")
                self.checkTracks()
            } catch is CancellationError {
                // A newer load or a stop took over; that one reports.
            } catch {
                guard !self.stopped, self.attempt == mine else { return }
                let kind = self.engine.errorInfo.map { " (\($0.kind.rawValue))" } ?? ""
                self.failed("Laden: \(error.localizedDescription)\(kind)")
            }
        }
    }

    /// **No picture within 30 s counts as a failure**, like the AVPlayer path: the host then
    /// shows the start error.
    private func watchStart(_ mine: Int) {
        sentry?.cancel()
        sentry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.attempt == mine, !self.stopped,
                  !self.pictureShown else { return }
            self.failed("kein Bild nach 30 s")
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
                self.checkTracks()
            }
        }.store(in: &bag)
        engine.clock.$currentTime.sink { [weak self] seconds in
            guard let self, !self.stopped else { return }
            if seconds.isFinite, seconds >= 0, self.seekTarget == nil, !self.ended { self.lastPosition = seconds }
            self.refreshSubtitle()
        }.store(in: &bag)
        engine.$audioTracks.sink { [weak self] _ in self?.checkTracks() }.store(in: &bag)
        engine.$subtitleTracks.sink { [weak self] _ in self?.checkTracks() }.store(in: &bag)
        engine.$subtitleCues.sink { [weak self] _ in self?.refreshSubtitle() }.store(in: &bag)
        // The source has sound and none of it could be delivered: a picture without sound is
        // worse than an error message.
        engine.$audioDelivery.sink { [weak self] delivery in
            guard let self, !self.stopped, delivery == .droppedNoPipeline else { return }
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
        host?.avRunning(go)
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
        // A stream that died within the last seconds is the end of the film, not a failure.
        if durationSeconds > 0, position > durationSeconds - 3 { ended = true; return }
        failureReported = true
        AppLog.writeOut("[Aether] Fehler: \(reason)")
        host?.avFailed(reason)
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
        seekTarget = target
        lastPosition = target
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.engine.seek(to: target)
            guard self.seekTarget == target else { return }
            self.seekTarget = nil
            self.refreshSubtitle()
        }
        refreshSubtitle()
        #if os(iOS)
        pip?.invalidatePlaybackState()
        #endif
    }

    /// `.ended` is final for the engine: a replay is a new load of the same address.
    private func reload(at seconds: Double) {
        AppLog.writeOut("[Aether] neu laden ab \(Int(seconds)) s")
        load(start: seconds)
    }

    func pause() { engine.pause() }

    func resume() {
        if ended { reload(at: 0); return }
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
        engine.volume = Float(min(max(percent, 0), 100)) / 100
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
    private func adoptEngineTracks(audio: [TrackInfo], subtitles: [TrackInfo]) {
        guard request.itemID.isEmpty, (request.source.mediaStreams ?? []).isEmpty else { return }
        func entry(_ track: TrackInfo, _ type: String) -> [String: Any] {
            ["Index": track.id, "Type": type, "Codec": track.codec, "Language": track.language ?? "",
             "DisplayTitle": track.name, "Channels": track.channels, "IsDefault": track.isDefault,
             "IsForced": track.isForced]
        }
        let json: [String: Any] = ["MediaStreams": audio.map { entry($0, "Audio") } + subtitles.map { entry($0, "Subtitle") }]
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let source = try? JSONDecoder().decode(MediaSource.self, from: data) else { return }
        request = EngineRequest(itemID: request.itemID, source: source, subtitleFiles: request.subtitleFiles)
        if audioIndex == nil { audioIndex = engine.activeAudioTrackIndex ?? audio.first(where: \.isDefault)?.id ?? audio.first?.id }
        audioApplied = audioIndex
        host?.trackIndicesReport(TrackIndices(audio: audioIndex, subtitle: subtitleIndex))
        AppLog.writeOut("[Aether] Datei ohne Beschreibung: \(audio.count) Töne, \(subtitles.count) Untertitel aus der Engine")
    }

    /// Hands the wanted tracks to the engine once its own lists are there, and only if the engine
    /// has the track under that number. A mismatch is logged and the engine's own choice plays.
    private func checkTracks() {
        guard !stopped else { return }
        let audio = engine.audioTracks
        let subtitles = engine.subtitleTracks
        guard !audio.isEmpty || !subtitles.isEmpty else { return }
        adoptEngineTracks(audio: audio, subtitles: subtitles)
        if let want = audioIndex, audioApplied != want, !audio.isEmpty {
            audioApplied = want
            if audio.contains(where: { $0.id == want }) {
                if engine.activeAudioTrackIndex != want { engine.selectAudioTrack(index: want) }
            } else {
                AppLog.writeOut("[Aether] Tonspur \(want) nicht in der Liste der Engine")
            }
        }
        guard !subtitles.isEmpty || engine.state != .loading else { return }
        if subtitleIndex >= 0 {
            guard subtitleApplied != subtitleIndex else { return }
            subtitleApplied = subtitleIndex
            let wanted = externalTrackIDs[subtitleIndex] ?? subtitleIndex
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

    /// The text of the cues on screen now, flattened: the app's look (size, colour, outline)
    /// applies to all of it, as with the other engines.
    private func refreshSubtitle() {
        guard !stopped else { return }
        var line: String?
        var images: [(id: Int, cgImage: CGImage, position: CGRect, canvas: CGSize)] = []
        if subtitleIndex >= 0 {
            let time = engine.clock.sourceTime - Double(subtitleDelay.milliseconds) / 1000
            let lines = engine.subtitleCues.compactMap { cue -> String? in
                guard cue.startTime <= time, time < cue.endTime else { return nil }
                switch cue.body {
                case .text(let text): return text
                case .richText(let runs): return runs.map(\.text).joined()
                case .image: return nil
                }
            }
            if !lines.isEmpty {
                line = lines.joined(separator: "\n").replacingOccurrences(of: "\\N", with: "\n")
            }
            for cue in engine.subtitleCues where cue.startTime <= time && time < cue.endTime {
                if case .image(let image) = cue.body { images.append((cue.id, image.cgImage, image.position, image.canvasSize)) }
            }
        }
        overlay.show(images: images, in: surface.bounds, picture: pictureRect)
        overlay.show(line, in: surface.bounds, picture: pictureRect)
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
            Task { @MainActor [weak self] in self?.host?.onPiPAvailable?(possible) }
        }
    }

    var pipPossible: Bool { pip?.isPictureInPicturePossible ?? false }
    func startPiP() {
        // Before the system decides: the engine must keep the pipeline for the window.
        engine.pictureInPictureActive = true
        pip?.startPictureInPicture()
    }
    func stopPiP() { pip?.stopPictureInPicture() }
    func refreshPiP() { pip?.invalidatePlaybackState() }
    #endif

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
    }
}

#if os(iOS)
extension AetherPlayerEngine: @MainActor AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        // Keeps the engine's pipeline alive while the app is in the background.
        engine.pictureInPictureActive = true
        host?.onPiPStateChanged?(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        engine.pictureInPictureActive = false
        host?.onPiPStateChanged?(false)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: any Error) {
        engine.pictureInPictureActive = false
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
                                    done: @escaping (Bool) -> Void) {
        done(true)
    }
}
#endif
