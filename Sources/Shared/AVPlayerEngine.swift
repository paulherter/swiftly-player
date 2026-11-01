import AVFoundation
import AVKit
import CoreMedia
import JellyfinKit
import VideoToolbox
import VLCKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - What the player surface lists

/// **One entry of the audio or subtitle list**, whichever engine plays.
///
/// The track panels only need the id and the names; the engines fill the rest. VLC tracks keep
/// their `VLCMediaPlayer.Track` so a choice can be passed back; AVPlayer tracks are the
/// server's streams (`stream`), because AVPlayer sees the one audio track it was given.
struct SurfaceTrack {
    let trackId: String
    let trackName: String
    let prettyName: String
    var vlc: VLCMediaPlayer.Track?
    var stream: MediaStream?
    var isSelected = false

    init(vlc: VLCMediaPlayer.Track) {
        trackId = vlc.trackId
        trackName = vlc.trackName
        prettyName = vlc.prettyName
        self.vlc = vlc
        isSelected = vlc.isSelected
    }

    init(stream: MediaStream, name: String, selected: Bool) {
        trackId = "av-\(stream.type ?? "")-\(stream.index ?? -1)"
        trackName = name
        prettyName = name
        self.stream = stream
        isSelected = selected
    }
}

// MARK: - The request a play brings along

/// **Everything the AVPlayer engine needs besides the address**, set with the track request
/// before `play`. `nil` on the request means "VLC", as before (downloads, other callers).
struct EngineRequest: Sendable {
    let itemID: String
    /// The unchanged file, as the server describes it.
    let source: MediaSource
    /// The text subtitles the app draws itself, one file per track.
    let subtitleFiles: [SubtitleFile]
    /// The copy-only address for an audio track (`nil` takes the source's default), or `nil` if
    /// the server has none.
    let plan: @Sendable (Int?) async -> PlaybackPlan?
}

// MARK: - What this device can show

enum EngineProbe {
    /// Read once: the display's HDR modes and the AV1 hardware decoder do not change while the
    /// app runs (a display can be plugged in later; the next launch sees it).
    static let device: EngineDevice = {
        let av1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        #if os(macOS)
        // `availableHDRModes` does not exist on the Mac. AVPlayer decodes Dolby Vision there and
        // maps it to what the screen can show, so the only question is the hardware AV1 decoder.
        return EngineDevice(dolbyVision: true, hdr: true, av1: av1)
        #else
        let modes = AVPlayer.availableHDRModes
        return EngineDevice(dolbyVision: modes.contains(.dolbyVision), hdr: !modes.isEmpty, av1: av1)
        #endif
    }()
}

// MARK: - Subtitle text drawn by the app

/// The text of the current cue, drawn with the saved ``SubtitleLook`` above the picture.
///
/// AVPlayer cannot show the server's SRT next to a stream it copies, and image subtitles are not
/// drawn at all (those titles go to VLC). The mapping of the look follows VLC's options in
/// ``SubtitleLook/vlcOptions(look:baseScale:outputHeight:engine:)``: size relative to the picture
/// height, outline in percent of the font height, shadow straight down, bottom margin 16 plus
/// the raised step.
@MainActor
final class SubtitleOverlay {
    let layer = CALayer()
    private let text = CATextLayer()
    private var shown: String?
    /// Read once per title: the look is chosen in the settings, not while a title plays (VLC
    /// takes it at the start of each title as well).
    private let look = SubtitleStyle.look

    init() {
        text.alignmentMode = .center
        text.isWrapped = true
        text.truncationMode = .none
        layer.addSublayer(text)
        layer.isHidden = false
        text.isHidden = true
    }

    /// `picture` is where the video really is inside the layer (`AVPlayerLayer.videoRect`).
    func show(_ line: String?, in bounds: CGRect, picture: CGRect) {
        layer.frame = bounds
        guard let line, !line.isEmpty else {
            text.isHidden = true
            shown = nil
            return
        }
        let visible = (picture.isEmpty ? bounds : picture.intersection(bounds))
        guard visible.width > 1, visible.height > 1 else { return }
        let size = visible.height * 0.0625 * CGFloat(SubtitleStyle.size(for: look))
        let attributes = Self.attributes(look: look, size: size)
        let string = NSAttributedString(string: line, attributes: attributes)
        let room = CGSize(width: visible.width * 0.9, height: visible.height * 0.6)
        let box = string.boundingRect(with: room, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).integral
        let margin = 16 + (look.position == .raised ? visible.height * 0.07 : 0)
        let width = min(room.width, box.width + size)
        let frame: CGRect
        #if canImport(UIKit)
        frame = CGRect(x: visible.midX - width / 2, y: visible.maxY - margin - box.height,
                       width: width, height: box.height)
        #else
        // AppKit layers have their origin at the bottom.
        frame = CGRect(x: visible.midX - width / 2, y: visible.minY + margin,
                       width: width, height: box.height)
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        text.contentsScale = Self.scale
        text.frame = frame
        text.string = string
        text.shadowOpacity = look.shadow ? 0.63 : 0
        text.shadowRadius = 0
        #if canImport(UIKit)
        text.shadowOffset = CGSize(width: 0, height: size * 0.04)
        #else
        text.shadowOffset = CGSize(width: 0, height: -size * 0.04)
        #endif
        text.backgroundColor = look.background ? CGColor(gray: 0, alpha: 0.63) : nil
        text.isHidden = false
        CATransaction.commit()
        shown = line
    }

    private static var scale: CGFloat {
        #if canImport(UIKit)
        // No trait collection outside a layout pass: the main screen is what the host sits on.
        UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale
            : max(UIScreen.main.scale, 2)
        #else
        NSScreen.main?.backingScaleFactor ?? 2
        #endif
    }

    private static func attributes(look: SubtitleLook, size: CGFloat) -> [NSAttributedString.Key: Any] {
        let rgb = look.colour.rgb
        let colour = CGColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                             blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        #if canImport(UIKit)
        let font = UIFont(name: SubtitleStyle.fontName, size: size) ?? UIFont.systemFont(ofSize: size, weight: .semibold)
        let fill = UIColor(cgColor: colour)
        let stroke = UIColor(white: 0, alpha: 0.9)
        #else
        let font = NSFont(name: SubtitleStyle.fontName, size: size) ?? NSFont.systemFont(ofSize: size, weight: .semibold)
        let fill = NSColor(cgColor: colour) ?? .white
        let stroke = NSColor(white: 0, alpha: 0.9)
        #endif
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: fill, .paragraphStyle: style,
        ]
        if look.outline.thickness > 0 {
            // Negative: fill and outline. Percent of the font size, centred on the edge, so the
            // visible outline is about half of it.
            attributes[.strokeColor] = stroke
            attributes[.strokeWidth] = -Double(look.outline.thickness) * 2
        }
        return attributes
    }
}

// MARK: - The engine

/// **AVPlayer behind the player surface's facade.**
///
/// Plays what the server hands out as a copy (an HLS stream of fMP4 pieces, or the MP4 itself),
/// which is the only way AVPlayer reaches Dolby Vision and AV1 without a re-encode. The picture
/// layer sits in the `VLCPlayerView`'s own layer so the screens, PiP and fill/fit work on the
/// same view; the facade forwards to this class while it is active.
///
/// Failures are not handled here: the host decides (``VLCPlayerView/avFailed(_:)``) and starts
/// VLC at the position where this stopped.
@MainActor
final class AVPlayerEngine: NSObject {
    let player = AVPlayer()
    let layer: AVPlayerLayer
    let overlay = SubtitleOverlay()
    let request: EngineRequest
    private weak var host: VLCPlayerView?

    /// The server's audio track that plays (`Index`), `nil` = the source's default.
    private(set) var audioIndex: Int?
    /// The server's subtitle track that shows; `-1` = none.
    private(set) var subtitleIndex = -1
    private var cues: SubtitleCues?
    private var cuesFor: Int?
    private var cueTask: Task<Void, Never>?

    private var item: AVPlayerItem?
    private var statusWatch: NSKeyValueObservation?
    private var readyWatch: NSKeyValueObservation?
    private var controlWatch: NSKeyValueObservation?
    private var timeToken: Any?
    private var notes: [NSObjectProtocol] = []
    private var sentry: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    /// The start position or an outstanding seek; shown instead of the player's clock until the
    /// seek has landed.
    private(set) var seekTarget: Double?
    private var lastPosition: Double = 0
    private var ended = false
    private(set) var pictureShown = false
    private var stopped = false
    private var running = false
    /// The address is one file with all its tracks, not a stream built for one audio track.
    private var planIsFile = false
    /// A track switch keeps a paused title paused; every other load starts playing.
    private var resumeAfterLoad = true
    private let runtime: Double
    private var attempt = 0

    /// Subtitle shift against the picture, from the delay row.
    var subtitleDelay = Delay.null { didSet { refreshSubtitle() } }

    #if os(iOS)
    private var pip: AVPictureInPictureController?
    private var pipWatch: NSKeyValueObservation?
    #endif
    #if os(tvOS)
    private var criteriaSet = false
    #endif

    init(host: VLCPlayerView, request: EngineRequest, audioIndex: Int?, subtitleIndex: Int) {
        self.host = host
        self.request = request
        self.audioIndex = audioIndex
        self.subtitleIndex = subtitleIndex
        runtime = request.source.runtimeSeconds ?? 0
        layer = AVPlayerLayer(player: player)
        super.init()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = true
        #if canImport(UIKit)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        #endif
        (host.layer as CALayer?)?.insertSublayer(layer, at: 0)
        (host.layer as CALayer?)?.addSublayer(overlay.layer)
        place(in: host.bounds)
        controlWatch = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.controlSwitched() }
        }
        readyWatch = layer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.pictureCheck() }
        }
        // `queue: .main` makes the block run on the main thread, which is the main actor's.
        timeToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        #if os(iOS)
        setUpPiP()
        #endif
    }

    // MARK: Loading

    /// Opens an address and starts at `start`.
    func load(_ plan: PlaybackPlan, start: Double) {
        guard !stopped else { return }
        attempt += 1
        removeItemWatch()
        planIsFile = plan.url.pathExtension.lowercased() != "m3u8" && !plan.url.path.lowercased().contains(".m3u8")
        let piece = AVPlayerItem(asset: AVURLAsset(url: plan.url))
        piece.preferredForwardBufferDuration = 0
        item = piece
        ended = false
        pictureShown = false
        lastPosition = start
        statusWatch = piece.observe(\.status, options: [.new]) { [weak self] piece, _ in
            let failed = piece.status == .failed
            let text = piece.error?.localizedDescription ?? ""
            Task { @MainActor [weak self] in
                if failed { self?.failed("Status failed \(text)") } else { self?.statusSwitched() }
            }
        }
        let center = NotificationCenter.default
        notes.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: piece,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd() }
        })
        notes.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: piece,
                                        queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "?"
            MainActor.assumeIsolated { self?.failed("Wiedergabe abgebrochen: \(reason)") }
        })
        notes.append(center.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: piece,
                                        queue: .main) { note in
            let entry = (note.object as? AVPlayerItem)?.errorLog()?.events.last
            let line = "[AVPlayer] Fehlereintrag \(entry?.errorStatusCode ?? 0) \(entry?.errorComment ?? "")"
            MainActor.assumeIsolated { AppLog.writeOut(line) }
        })
        player.replaceCurrentItem(with: piece)
        // The early seek is queued by AVPlayer until the stream is ready.
        if start > 0.5 {
            seekTarget = start
            move(to: start)
        } else {
            seekTarget = nil
        }
        if resumeAfterLoad { player.play() }
        resumeAfterLoad = true
        watchStart()
        #if os(tvOS)
        displayCriteria(of: piece)
        #endif
    }

    /// Another audio track of the same file: a new address, the same position.
    func switchAudio(to index: Int) {
        guard index != audioIndex else { return }
        let spot = position
        audioIndex = index
        resumeAfterLoad = running
        player.pause()
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let plan = await self.request.plan(index)
            guard !Task.isCancelled, !self.stopped else { return }
            guard let plan else {
                self.host?.avFailed("Kein Strom für Tonspur \(index)")
                return
            }
            AppLog.writeOut("[AVPlayer] Tonspur \(index) bei \(Int(spot)) s")
            self.load(plan, start: spot)
        }
    }

    private func removeItemWatch() {
        statusWatch = nil
        notes.forEach(NotificationCenter.default.removeObserver)
        notes = []
        sentry?.cancel()
    }

    /// **No picture within 25 s counts as a failure.** AVPlayer waits for a stream without a
    /// deadline (as with AirPlay); the host then plays the title with VLC.
    private func watchStart() {
        sentry?.cancel()
        let mine = attempt
        sentry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, let self, self.attempt == mine, !self.stopped,
                  !self.pictureShown else { return }
            self.failed("kein Bild nach 25 s")
        }
    }

    // MARK: Events

    private func statusSwitched() {
        guard let item, item.status == .readyToPlay else { return }
        AppLog.writeOut("[AVPlayer] bereit · \(Int(durationSeconds)) s · \(Int(item.presentationSize.width))x\(Int(item.presentationSize.height))")
        if planIsFile { selectFileAudio(in: item) }
        pictureCheck()
    }

    /// **A plain file (Plex, direct play) holds every audio track, and the address is the same
    /// for each.** The track is picked from the file's own list instead, by its place among the
    /// audio tracks. A stream built per track needs none of this.
    private func selectFileAudio(in item: AVPlayerItem) {
        guard let audioIndex else { return }
        let tracks = (request.source.mediaStreams ?? []).filter { $0.type == "Audio" }
        guard tracks.count > 1, let place = tracks.firstIndex(where: { $0.index == audioIndex }) else { return }
        let piece = item
        Task { @MainActor [weak self] in
            guard let group = try? await piece.asset.loadMediaSelectionGroup(for: .audible),
                  group.options.indices.contains(place) else { return }
            guard let self, self.item === piece else { return }
            piece.select(group.options[place], in: group)
            AppLog.writeOut("[AVPlayer] Tonspur \(audioIndex) aus der Datei (Platz \(place))")
        }
    }

    private func pictureCheck() {
        guard !stopped, layer.isReadyForDisplay, !pictureShown else { return }
        pictureShown = true
        sentry?.cancel()
        AppLog.writeOut("[AVPlayer] erstes Bild")
    }

    private func controlSwitched() {
        guard !stopped else { return }
        let now = player.timeControlStatus
        if now == .waitingToPlayAtSpecifiedRate { return }
        let go = now == .playing
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

    private func reachedEnd() {
        guard !stopped else { return }
        ended = true
        AppLog.writeOut("[AVPlayer] Ende")
    }

    private func failed(_ reason: String) {
        guard !stopped else { return }
        // A stream that died within the last seconds is the end of the film, not a failure.
        if duration > 0, position > duration - 3 { reachedEnd(); return }
        AppLog.writeOut("[AVPlayer] Fehler: \(reason)")
        host?.avFailed(reason)
    }

    private func tick() {
        guard !stopped else { return }
        if let seconds = Self.seconds(player.currentTime()), seekTarget == nil, !ended {
            lastPosition = seconds
        }
        refreshSubtitle()
    }

    // MARK: Position

    private static func seconds(_ time: CMTime) -> Double? {
        let value = time.seconds
        return value.isFinite && value >= 0 ? value : nil
    }

    var position: Double {
        if ended, duration > 0 { return duration }
        if let seekTarget { return seekTarget }
        return Self.seconds(player.currentTime()) ?? lastPosition
    }

    var duration: Double { durationSeconds }

    var durationSeconds: Double {
        if let value = item.flatMap({ Self.seconds($0.duration) }), value > 0 { return value }
        return runtime
    }

    var isPlaying: Bool { running }

    /// The start seek has landed (or there was none).
    var startSettled: Bool { seekTarget == nil }

    var videoSize: CGSize { item?.presentationSize ?? .zero }

    var lastGood: Double { lastPosition }

    func move(to seconds: Double) {
        let target = max(seconds, 0)
        seekTarget = target
        ended = false
        lastPosition = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, finished, self.seekTarget == target else { return }
                self.seekTarget = nil
                self.refreshSubtitle()
            }
        }
        refreshSubtitle()
        #if os(iOS)
        pip?.invalidatePlaybackState()
        #endif
    }

    func jump(seconds: Int32) { move(to: position + Double(seconds)) }

    func pause() {
        player.pause()
    }

    func resume() {
        if ended { move(to: 0) }
        player.play()
        if tempoValue != 1 { player.rate = tempoValue }
    }

    // MARK: Speed, volume, fit

    private var tempoValue: Float = 1

    var tempo: Float {
        get { tempoValue }
        set {
            tempoValue = newValue
            player.defaultRate = newValue
            if running { player.rate = newValue }
        }
    }

    func volume(_ percent: Int) {
        player.volume = Float(min(max(percent, 0), 100)) / 100
    }

    func fill(_ on: Bool) {
        layer.videoGravity = on ? .resizeAspectFill : .resizeAspect
        refreshSubtitle()
    }

    // MARK: Layout

    func place(in bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        overlay.layer.frame = bounds
        CATransaction.commit()
        refreshSubtitle()
    }

    // MARK: Subtitles

    /// Chooses the subtitle track. `-1` turns them off. Returns `false` if the track has no file
    /// the app can draw (the host hands the title to VLC then).
    @discardableResult
    func selectSubtitle(_ index: Int) -> Bool {
        if index < 0 {
            subtitleIndex = -1
            cues = nil
            cuesFor = nil
            cueTask?.cancel()
            refreshSubtitle()
            return true
        }
        guard let file = request.subtitleFiles.first(where: { $0.index == index }) else { return false }
        subtitleIndex = index
        guard cuesFor != index else { refreshSubtitle(); return true }
        cues = nil
        cuesFor = index
        cueTask?.cancel()
        cueTask = Task { @MainActor [weak self] in
            let read = await Self.read(file.address)
            guard !Task.isCancelled, let self, self.cuesFor == index else { return }
            self.cues = read
            AppLog.writeOut("[AVPlayer] Untertitel \(index): \(read?.cues.count ?? 0) Zeilen")
            if read == nil {
                // No lines to draw: VLC reads the track itself rather than showing none.
                self.cuesFor = nil
                self.host?.avHandOver(audio: nil, subtitle: index, reason: "Untertitel \(index) nicht lesbar")
                return
            }
            self.refreshSubtitle()
        }
        return true
    }

    private static func read(_ address: URL) async -> SubtitleCues? {
        guard let (data, _) = try? await URLSession.shared.data(from: address) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let parsed = SubtitleCues.parse(text)
        return parsed.isEmpty ? nil : parsed
    }

    private func refreshSubtitle() {
        guard !stopped else { return }
        let line: String?
        if subtitleIndex >= 0, let cues {
            line = cues.text(at: position - Double(subtitleDelay.milliseconds) / 1000)
        } else {
            line = nil
        }
        overlay.show(line, in: layer.bounds, picture: layer.videoRect)
    }

    // MARK: tvOS display criteria

    #if os(tvOS)
    /// **Hand the TV the stream's own mode** (Dolby Vision, HDR10, frame rate) before the first
    /// picture. The system does not switch by itself for a layer inside our own view.
    private func displayCriteria(of piece: AVPlayerItem) {
        let mine = attempt
        Task { @MainActor [weak self] in
            guard let criteria = try? await piece.asset.load(.preferredDisplayCriteria) else { return }
            guard let self, self.attempt == mine, !self.stopped else { return }
            let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow }
            window?.avDisplayManager.preferredDisplayCriteria = criteria
            self.criteriaSet = window != nil
            AppLog.writeOut("[AVPlayer] Anzeigemodus gesetzt")
        }
    }
    #endif

    // MARK: Picture in picture

    #if os(iOS)
    private func setUpPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let controller = AVPictureInPictureController(playerLayer: layer)
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        controller?.delegate = self
        pip = controller
        pipWatch = controller?.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor [weak self] in self?.host?.onPiPAvailable?(possible) }
        }
    }

    var pipPossible: Bool { pip?.isPictureInPicturePossible ?? false }
    func startPiP() { pip?.startPictureInPicture() }
    func stopPiP() { pip?.stopPictureInPicture() }
    func refreshPiP() { pip?.invalidatePlaybackState() }
    #endif

    // MARK: End

    func stop() {
        guard !stopped else { return }
        stopped = true
        sentry?.cancel()
        loadTask?.cancel()
        cueTask?.cancel()
        removeItemWatch()
        statusWatch = nil
        readyWatch = nil
        controlWatch = nil
        if let timeToken { player.removeTimeObserver(timeToken) }
        timeToken = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        item = nil
        #if os(iOS)
        pipWatch = nil
        pip?.delegate = nil
        pip = nil
        #endif
        #if os(tvOS)
        if criteriaSet {
            let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow }
            window?.avDisplayManager.preferredDisplayCriteria = nil
            criteriaSet = false
        }
        #endif
        #if canImport(UIKit)
        if UIApplication.shared.isIdleTimerDisabled { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
        layer.removeFromSuperlayer()
        overlay.layer.removeFromSuperlayer()
    }
}

#if os(iOS)
extension AVPlayerEngine: @MainActor AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        host?.onPiPStateChanged?(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        host?.onPiPStateChanged?(false)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
                                    done: @escaping (Bool) -> Void) {
        done(true)
    }
}
#endif
