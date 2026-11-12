import CoreGraphics
import Foundation
import JellyfinKit
import SwiftlyCore

/// Which way a title is played. **Code and debug only, never a setting the user sees.** On the Rust beta line the
/// core's player state machine (`PlayerVm`) plays server titles; `-alterWiedergabeweg` as a launch argument goes
/// back to the old way (the screen facade drives the engine and `AppModel` sends the reports) for comparing.
enum PlayerWay {
    @MainActor static var core: Bool {
        !ProcessInfo.processInfo.arguments.contains("-alterWiedergabeweg")
    }
}

/// **The `PlaybackBackend` the screen facade gets when the core plays the title.**
///
/// The screens still talk to `VLCPlayerView` and read what they always read (position, picture, tracks); this
/// backend keeps those reads on the engine and sends every command through the core: pause, resume and seek as the
/// engine intents (`PlayerIntent.enginePause/enginePlay/engineSeek`, which report at once like the old
/// `runsReported` / `jumpReported` hooks), tempo, volume, fit, delays and the track choices as their intents. What
/// the engine reports goes to the core (`PlayerEngineDriver` over `CoreAetherPort`) and, as the old callbacks, to
/// the facade (`avRunning`, `avFailed`).
@MainActor
final class CorePlaybackBackend: PlaybackBackend {
    let label = "Aether·Kern"
    let request: EngineRequest

    private weak var host: VLCPlayerView?
    private let port: CoreAetherPort
    private let driver: PlayerEngineDriver
    private let model: PlayerModel
    private let app: AppModel
    private let ownedKey: String
    private let startAt: Double
    private let firstAudio: Int?
    private let firstSubtitle: Int
    private var observing: Task<Void, Never>?
    private var failureReported = false
    private var tempoValue: Float = 1
    private var subtitleDelayValue = Delay.null
    private var audioDelayValue = Delay.null

    /// - Throws: when the core cannot serve this account (no session): the caller plays the old way.
    init(
        host: VLCPlayerView, request: EngineRequest, url: URL, item: Item, plan: PlaybackPlan, app: AppModel,
        startAt: Double, audioIndex: Int?, subtitleIndex: Int, trackTitle: String?,
        fill: Bool, volume: Int32?, tempo: Float, subtitleDelay: Delay, audioDelay: Delay
    ) throws {
        guard let session = app.session, let reporter = app.reporterForCore() else {
            throw AppCore.Unavailable.account
        }
        self.host = host
        self.request = request
        self.app = app
        self.startAt = startAt
        self.firstAudio = audioIndex
        self.firstSubtitle = subtitleIndex
        self.ownedKey = StopLock.key(itemID: item.id, playSessionID: plan.playSessionID)

        let port = CoreAetherPort(host: host, request: request)
        let driver = PlayerEngineDriver(port: port)
        // What the screen asked for before the engine exists goes to the port, which hands it over at load.
        port.setFill(fill)
        if let volume { port.setVolume(UInt8(clamping: max(0, min(100, volume)))) }
        if tempo != 1 { port.setRate(tempo) }
        port.setSubtitleDelay(milliseconds: Int32(subtitleDelay.milliseconds))
        port.setAudioDelay(milliseconds: Int32(audioDelay.milliseconds))
        tempoValue = tempo
        subtitleDelayValue = subtitleDelay
        audioDelayValue = audioDelay

        let method: PlayerMethod
        switch plan.method {
        case .directPlay: method = .directPlay
        case .directStream: method = .directStream
        case .transcode: method = .transcode
        }
        let source = request.source
        let start = PlayerStart(
            itemId: item.id, title: item.name, playSessionId: plan.playSessionID, mediaSourceId: plan.mediaSourceID,
            method: method, url: url.absoluteString, headers: [], streams: StartTracks.rows(source.mediaStreams ?? [], transcoded: plan.method == .transcode),
            runtime: source.runtimeSeconds ?? 0, startAt: startAt, audioIndex: audioIndex.map(Int64.init),
            subtitleIndex: Int64(subtitleIndex), next: nil, seriesId: item.seriesId, trackTitle: trackTitle,
            downloaded: url.isFileURL, softwareDecode: plan.softwareDecoder, frameRateMatch: false, bufferLevel: .normal,
            subtitleFiles: StartTracks.files(request.subtitleFiles), externalTrackIdBase: CoreTrackIDs.externalBase)
        // The core decides auto skip and the next episode (card countdown, end of file); the screen only shows it.
        let prefs = Self.prefs(app, networkFavorable: networkFavorable)
        let vm = try AppCore.shared.playerShared(
            session: session, start: start, prefs: prefs, engine: driver, reporter: reporter)
        self.port = port
        self.driver = driver
        self.model = vm
        driver.connect { [weak vm] event in vm?.engineEvent(event) }
        port.tap = { [weak self] event in self?.tapped(event) }
        app.coreOwns(ownedKey)
        vm.start()
        // The core learns the delays too (its state is what it reports and persists).
        if subtitleDelay != .null { vm.send(.subtitleDelay(milliseconds: Int64(subtitleDelay.milliseconds))) }
        if audioDelay != .null { vm.send(.audioDelay(milliseconds: Int64(audioDelay.milliseconds))) }
        observing = Task { @MainActor [weak self] in
            guard let model = self?.model else { return }
            await model.observe()
        }
        watchFailure()
    }

    /// The settings the core decides by: "skip intro and outro automatically" and "next episode automatically".
    static func prefs(_ app: AppModel, networkFavorable: Bool = false) -> PlayerPrefs {
        PlayerPrefs(
            backSeconds: Int64(app.backSeconds), forwardSeconds: Int64(app.forwardSeconds),
            autoSkip: UserDefaults.standard.bool(forKey: "introAbspannAuto"),
            nextAutomatic: app.nextAutomatic, networkFavorable: networkFavorable, directPlay: app.alwaysDirectPlay,
            bitrateLimit: Int64(app.bitratesLimit), convertAllowed: app.convertAllowed)
    }

    /// The next episode and the sections of the running title (the lookup after the open or a switch).
    func adopt(next: Item?, sections: [JellyfinKit.Segment]?) {
        if let next { model.setNext(PlayerNext(id: next.id, title: next.name)) } else if sections == nil { model.setNext(nil) }
        if let sections {
            model.setSections(sections.map {
                PlayerSection(kind: Self.kind($0.art), from: $0.from, until: $0.until)
            })
        }
        model.setPrefs(Self.prefs(app, networkFavorable: networkFavorable))
    }

    /// Chapters and the trickplay offer of the running title (the core names the chapter and cuts the preview tile).
    func adopt(chapters: [Chapter]) {
        model.setChapters(chapters.map { PlayerChapter(name: $0.name, from: $0.from) })
    }

    func adopt(trickplay: Trickplay?) {
        model.setTrickplay(trickplay.map {
            PlayerTrickplay(
                width: Int64($0.width), height: Int64($0.height), tilesWide: Int64($0.tilesWide),
                tilesUp: Int64($0.tilesUp), count: Int64($0.count), interval: Int64($0.interval))
        })
    }

    /// The preview tile the core cut for the scrub position.
    var previewNow: PlayerPreview? { model.controls.preview }

    private static func kind(_ art: JellyfinKit.Segment.Art) -> PlayerSectionKind {
        switch art {
        case .unknown: .unknown
        case .ads: .ads
        case .preview: .preview
        case .lookBack: .lookBack
        case .credits: .credits
        case .introSegment: .intro
        }
    }

    /// Wi-Fi or cable without data saver (the screen's network monitor). The core prepares the next episode only on a good network.
    private var networkFavorable = false
    func networkChanged(_ favorable: Bool) {
        guard favorable != networkFavorable else { return }
        networkFavorable = favorable
        model.setPrefs(Self.prefs(app, networkFavorable: favorable))
    }

    /// What the core called for since the last look (`PlayerCalls`: the screens run these, nothing else decides).
    typealias Calls = PlayerCalls
    func takeCalls() -> Calls {
        let calls = model.takeCalls()
        // A subtitle on a transcoded stream: the screen reloads the title like after a quality choice, and the
        // plan it asks for next carries this track (`AppModel.plan` takes the wish).
        if let subtitle = calls.reloadSubtitle, let id = calls.switchTo?.id { app.subtitleWish[id] = subtitle }
        return calls
    }

    /// The quality choice as an intent: the core compares with its choice, closes the layer, reloads at the position.
    func chooseQuality(_ limit: Int?) {
        model.setPrefs(Self.prefs(app, networkFavorable: networkFavorable))
        model.send(.quality(limit: limit.map(Int64.init)))
    }

    /// The model of a title reloaded after a quality choice says when the original plays.
    func afterQualitySwitch() { model.afterQualitySwitch() }

    /// The press on the offer and the dismissal (Back on the card/button) as core intents, so its countdown stops too.
    func pressOffer() { model.send(.pressOffering) }
    func dismissOffer() { model.send(.dismiss) }

    /// Lock screen, Control Center and headphone buttons: every play/pause command is the opposite of what the
    /// core's transport says now (the system's own word for it is only a suggestion).
    func remoteToggle() { model.send(.togglePlay) }

    /// Where the picture goes, and the AirPlay start decision (live title, picture on this screen, file fits).
    var surface: PlayerSurface { model.surface }
    func surfaceEvent(_ event: PlayerSurfaceEvent) { model.surfaceEvent(event) }
    func airplayStart(source: MediaSource) -> AirPlayStartDecision? {
        guard let data = try? JSONEncoder().encode(source), let json = String(data: data, encoding: .utf8) else { return nil }
        return model.airplayStart(sourceJSON: json)
    }

    // MARK: Old callbacks, fed from the engine's events

    private func tapped(_ event: PlayerEngineEvent) {
        switch event {
        case .state(let state):
            switch state {
            case .playing: host?.avRunning(true)
            case .paused, .ended: host?.avRunning(false)
            case .error(let message, _): failed(message)
            default: break
            }
        case .loadFailed(_, let message, _):
            failed(message)
        default:
            break
        }
    }

    private func failed(_ reason: String) {
        guard !failureReported else { return }
        failureReported = true
        host?.avFailed(reason)
    }

    /// The core's own verdict (no picture within 30 s): the screen shows its start error like before.
    private func watchFailure() {
        Task { @MainActor [weak self] in
            while let self, self.host != nil, !Task.isCancelled {
                if self.model.transport.phase == .failed, let failure = self.model.transport.failure {
                    self.failed(failure.text.isEmpty ? failure.header : failure.text)
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// The core's transport (the tick rules run in the core: restoring, since-start, push, leap).
    var transportNow: PlayerTransport { model.transport }

    // MARK: Reads (the engine, as before)

    private var engine: AetherPlayerEngine? { port.current }
    /// The running engine (test seam for the playback bench).
    var runningEngine: AetherPlayerEngine? { engine }

    #if DEBUG
    /// For the running-app matrix (`LiveRun`).
    var liveSubtitleState: [String: Any]? { engine?.liveSubtitleState }
    #endif

    var audioIndex: Int? { engine?.audioIndex ?? firstAudio }
    var subtitleIndex: Int { engine?.subtitleIndex ?? firstSubtitle }
    var position: Double { engine?.position ?? startAt }
    var durationSeconds: Double { engine?.durationSeconds ?? 0 }
    var isPlaying: Bool { engine?.isPlaying ?? false }
    var startSettled: Bool { engine?.startSettled ?? false }
    var pictureShown: Bool { engine?.pictureShown ?? false }
    var videoSize: CGSize { engine?.videoSize ?? .zero }
    var lastGood: Double { engine?.lastGood ?? startAt }

    // MARK: Commands (through the core)

    var tempo: Float {
        get { tempoValue }
        set { tempoValue = newValue; model.send(.tempo(tempo: newValue)) }
    }

    var subtitleDelay: Delay {
        get { subtitleDelayValue }
        set { subtitleDelayValue = newValue; model.send(.subtitleDelay(milliseconds: Int64(newValue.milliseconds))) }
    }

    var audioDelay: Delay {
        get { audioDelayValue }
        set { audioDelayValue = newValue; model.send(.audioDelay(milliseconds: Int64(newValue.milliseconds))) }
    }

    func move(to seconds: Double) { model.send(.engineSeek(seconds: seconds)) }

    /// The slider as intents, so the core's own state (`atPush`, preview, hide timer) follows the finger. `scrubEnd`
    /// is the seek itself (same path as `move`), so the screen sends it instead of, not after, a seek.
    func scrubStart() { model.send(.scrubStart) }
    func scrubMove(_ seconds: Double) { model.send(.scrubMove(seconds: seconds)) }
    func scrubEnd(_ seconds: Double) { model.send(.scrubEnd(seconds: seconds)) }
    func pause() { model.send(.enginePause) }
    func resume() { model.send(.enginePlay) }
    func volume(_ percent: Int) { model.send(.volume(percent: Int32(percent))) }
    func fill(_ on: Bool) { model.send(.fill(on: on)) }
    func place(in bounds: CGRect) {
        port.place(PlayerRect(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height))
    }
    func switchAudio(to index: Int) { model.send(.selectAudio(index: Int64(index))) }

    /// The engine answers through the next `tracks` event if it cannot show the track (the port says so), so the
    /// answer here is optimistic; the core keeps the track lists and the reports right.
    @discardableResult func selectSubtitle(_ index: Int) -> Bool {
        model.send(.selectSubtitle(index: Int64(index)))
        return true
    }

    func stop(resetDisplay: Bool) {
        observing?.cancel()
        port.tap = nil
        port.stop(resetDisplay: resetDisplay)
        driver.finish()
        app.coreReleased(ownedKey)
    }

    #if os(iOS)
    var pipPossible: Bool { engine?.pipPossible ?? false }
    func startPiP() { port.pip(.start) }
    func stopPiP() { port.pip(.stop) }
    func refreshPiP() { port.pip(.refresh) }
    #endif
}

extension VLCPlayerView {
    /// What the core shows for the running title (position, leap, picture, running), with the identity of the
    /// backend so the screen can ignore the old title's model while an episode switch is in flight.
    /// `nil` when the old way plays (`-alterWiedergabeweg`).
    var coreTransport: (id: ObjectIdentifier, value: PlayerTransport)? {
        guard let core = avEngine as? CorePlaybackBackend else { return nil }
        return (ObjectIdentifier(core), core.transportNow)
    }
}

extension VLCPlayerView {
    /// `true` when the core decides auto skip and the next episode for this title (so the screen must not).
    var coreDecides: Bool { avEngine is CorePlaybackBackend }
    func coreAdopt(next: Item?, sections: [JellyfinKit.Segment]?) {
        if let next { corePendingNext = next }
        if let sections { corePendingSections = sections }
        (avEngine as? CorePlaybackBackend)?.adopt(next: next, sections: sections)
    }
    /// A new episode starts: what was found for the old one is void.
    func coreForgetLookup() { corePendingNext = nil; corePendingSections = nil; corePendingChapters = nil; corePendingTrickplay = nil }
    func coreNetworkChanged(_ favorable: Bool) { (avEngine as? CorePlaybackBackend)?.networkChanged(favorable) }
    func coreTakeCalls() -> CorePlaybackBackend.Calls? { (avEngine as? CorePlaybackBackend)?.takeCalls() }
    func coreChooseQuality(_ limit: Int?) { (avEngine as? CorePlaybackBackend)?.chooseQuality(limit) }
    func coreAdopt(chapters: [Chapter]) {
        corePendingChapters = chapters
        (avEngine as? CorePlaybackBackend)?.adopt(chapters: chapters)
    }
    func coreAdopt(trickplay: Trickplay?) {
        corePendingTrickplay = trickplay
        (avEngine as? CorePlaybackBackend)?.adopt(trickplay: trickplay)
    }
    /// The core's scrub preview tile: `nil` when the old way plays (the screen then computes it), `.some(nil)` for none.
    var corePreview: PlayerPreview?? { (avEngine as? CorePlaybackBackend).map { $0.previewNow } }
    func corePressOffer() { (avEngine as? CorePlaybackBackend)?.pressOffer() }
    func coreDismissOffer() { (avEngine as? CorePlaybackBackend)?.dismissOffer() }
    func coreRemoteToggle() { (avEngine as? CorePlaybackBackend)?.remoteToggle() }
    func coreSurfaceEvent(_ event: PlayerSurfaceEvent) { (avEngine as? CorePlaybackBackend)?.surfaceEvent(event) }
    func coreAirplayStart(source: MediaSource) -> AirPlayStartDecision? { (avEngine as? CorePlaybackBackend)?.airplayStart(source: source) }
}

/// **The one start timeout**: no picture after this many seconds is a failed start, for the engine watchdog and the
/// screen's start veil alike. The core's `START_WATCHDOG_SECONDS` (swiftly-playback) is pinned to the same number by a test.
enum PlayerStartTimeout {
    static let seconds = 30
}
