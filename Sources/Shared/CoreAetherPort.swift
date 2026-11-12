import CoreGraphics
import Foundation
import JellyfinKit
import SwiftlyCore

/// **Aether as the core's engine** (`PlayerEnginePort`, driven by `PlayerEngineDriver`).
///
/// A thin translator: the core's commands go to ``AetherPlayerEngine`` (the same engine, the same
/// load options, tracks and subtitle drawing the screens always had); what the engine learns comes
/// back as `PlayerEngineEvent`s (``AetherPlayerEngine/events``). Nothing is decided here: the title's
/// tracks, resume position, reports and retries are the core's (`PlayerVm`).
///
/// PiP, AirPlay and Now Playing stay with the screen and `PlaybackHub`: PiP commands arrive here
/// (`pip`), the system's answers leave as `pipPossible` / `pipActive` / `pipRestoreUi`.
@MainActor
final class CoreAetherPort: PlayerEnginePort {
    private weak var host: VLCPlayerView?
    private var request: EngineRequest
    private var emit: (@MainActor (PlayerEngineEvent) -> Void)?
    private var engine: AetherPlayerEngine?
    private var openedURL: URL?

    // What the engine gets as soon as it exists (the core may send these before the first load).
    private var tempo: Float = 1
    private var volume: UInt8?
    private var fill = false
    private var audioDelay = Delay.null
    private var subtitleDelay = Delay.null

    /// `request`: the server's description of the file (its streams are the track lists) and the
    /// external subtitle files. For a downloaded file without a description, pass an empty source.
    init(host: VLCPlayerView, request: EngineRequest) {
        self.host = host
        self.request = request
    }

    /// The next title of the same screen: its description, before `PlayerModel.loadTitle`.
    func update(request: EngineRequest) { self.request = request }

    // MARK: PlayerEnginePort

    func attach(_ emit: @escaping @MainActor (PlayerEngineEvent) -> Void) { self.emit = emit }

    /// What the engine reports, also to the screen facade (`CorePlaybackBackend`): it feeds the old callbacks
    /// (`runsReported`, `startErrorReported`) from the same events the core gets.
    var tap: (@MainActor (PlayerEngineEvent) -> Void)?

    /// The engine while a title is loaded (`nil` before the first `load` ran): the screens read position, picture
    /// and tracks from it directly, as they always did.
    var current: AetherPlayerEngine? { engine }

    private func deliver(_ event: PlayerEngineEvent) {
        tap?(event)
        emit?(event)
    }

    func load(_ load: PlayerLoad) {
        guard let host, let url = URL(string: load.url) else {
            deliver(.loadFailed(attempt: 1, message: "Adresse ungültig", kind: nil))
            return
        }
        // The same address again (a retry) keeps the engine, so its attempt counter and the core's
        // stay level; a new title gets a new engine, as before.
        if engine == nil || openedURL != url {
            engine?.stop(resetDisplay: false)
            engine = nil
            let audio = load.audioServerIndex.map(Int.init)
                ?? request.source.defaultAudioStreamIndex
                ?? (request.source.mediaStreams ?? []).first(where: { $0.type == "Audio" })?.index
            do {
                let made = try AetherPlayerEngine(
                    host: host, request: request, url: url, audioIndex: audio,
                    subtitleIndex: Int(load.subtitleServerIndex))
                made.events = { [weak self] event in self?.deliver(event) }
                made.subtitleDelay = subtitleDelay
                made.audioDelay = audioDelay
                made.fill(fill)
                if let volume { made.volume(Int(volume)) }
                if tempo != 1 { made.tempo = tempo }
                engine = made
                openedURL = url
            } catch {
                deliver(.loadFailed(attempt: 1, message: "Aether: \(error.localizedDescription)", kind: nil))
                return
            }
        }
        engine?.load(start: load.start ?? 0)
    }

    func play() { engine?.resume() }
    func pause() { engine?.pause() }
    func seek(_ seconds: Double) { engine?.move(to: seconds) }

    func setRate(_ tempo: Float) {
        self.tempo = tempo
        engine?.tempo = tempo
    }

    func setVolume(_ percent: UInt8) {
        volume = percent
        engine?.volume(Int(percent))
    }

    /// The subtitle delay is an engine command now; the picture of the cues is drawn here.
    func setSubtitleDelay(milliseconds: Int32) {
        subtitleDelay = Delay(milliseconds: Int(milliseconds))
        engine?.subtitleDelay = subtitleDelay
    }

    func setAudioDelay(milliseconds: Int32) {
        audioDelay = Delay(milliseconds: Int(milliseconds))
        engine?.audioDelay = audioDelay
    }

    func selectAudio(_ serverIndex: Int32) { engine?.switchAudio(to: Int(serverIndex)) }

    func selectSubtitle(_ serverIndex: Int32) {
        // The driver answered already; an engine that cannot show the track keeps the subtitles off
        // and says which tracks play with the next `tracks` event.
        // An external subtitle file arrives under the core's own number (`CoreTrackIDs`); the engine takes the server's.
        let index = engine?.serverIndex(forCoreTrackID: Int(serverIndex)) ?? Int(serverIndex)
        if engine?.selectSubtitle(index) == false { engine?.emitTracks() }
    }

    func setFill(_ on: Bool) {
        fill = on
        engine?.fill(on)
    }

    func place(_ rect: PlayerRect) {
        engine?.place(in: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
    }

    func stop(resetDisplay: Bool) {
        engine?.stop(resetDisplay: resetDisplay)
        engine = nil
        openedURL = nil
    }

    func pip(_ command: PlayerPip) {
        #if os(iOS)
        switch command {
        case .start: engine?.startPiP()
        case .stop: engine?.stopPiP()
        case .refresh: engine?.refreshPiP()
        }
        #endif
    }
}
