import AVFoundation
import JellyfinKit
import SwiftlyCore

/// **Starting the Aether engine and what it reports back.**
///
/// `play` lands in ``startEngine(url:offSeconds:container:subtitle:)``. There is no second engine:
/// when Aether cannot create or load, the screen's start-error display shows the reason
/// (``avFailed(_:)``, log line `[Aether] Fehler: ...`).
extension VLCPlayerView {

    func startEngine(url: URL, offSeconds: Double, container: String?, subtitle: [SubtitleFile]) {
        avCall += 1
        avEngine?.stop(resetDisplay: false)
        avEngine = nil
        let start = JumpTarget.seconds(offSeconds) ?? 0
        let wish = trackRequest
        // A download has no server description: the engine plays the file with the tracks it finds.
        let request = wish?.engine ?? EngineRequest(itemID: "", source: Self.fileSource(url, wish?.coreStart),
                                                    subtitleFiles: subtitle)
        let streams = request.source.mediaStreams ?? []
        // The core's rule (`StartTracks`): remembered choice, order from another device, language wish, server default.
        let chosen = StartTracks.choose(
            streams: streams, defaultAudio: request.source.defaultAudioStreamIndex,
            defaultSubtitle: request.source.defaultSubtitleStreamIndex, audioLanguage: wish?.audio ?? "",
            subtitleLanguage: wish?.subtitle ?? "", automatic: wish?.automatic ?? false, title: wish?.title,
            ordered: wish?.ordered)
        let audio = chosen.audio
        let subtitleIndex = chosen.subtitle

        pausedSince = nil
        trackSource = nil
        trackOriginal = nil
        subtitleFiles = []
        lastGoodPosition = start
        trackIndicesReport(TrackIndices())

        let effectiveAudio = audio ?? request.source.defaultAudioStreamIndex
            ?? streams.first(where: { $0.type == "Audio" })?.index
        // **The core plays server titles** (``PlayerWay``): the same engine, but the commands, the state and the
        // reports go through `PlayerVm`, Plex included.
        if PlayerWay.core, let context = wish?.coreStart {
            do {
                avEngine = try CorePlaybackBackend(
                    host: self, request: request, url: url, item: context.item, plan: context.plan,
                    app: context.model, startAt: start, audioIndex: effectiveAudio, subtitleIndex: subtitleIndex,
                    trackTitle: wish?.title, fill: fillWish, volume: requestVolume, tempo: tempoWish,
                    subtitleDelay: subtitleDelay, audioDelay: audioDelay)
                if coreQualityWish {
                    coreQualityWish = false
                    (avEngine as? CorePlaybackBackend)?.afterQualitySwitch()
                }
                if let backend = avEngine as? CorePlaybackBackend {
                    if let corePendingChapters { backend.adopt(chapters: corePendingChapters) }
                    if let corePendingTrickplay { backend.adopt(trickplay: corePendingTrickplay) }
                }
                if corePendingNext != nil || corePendingSections != nil {
                    coreAdopt(next: corePendingNext, sections: corePendingSections)
                }
                AppLog.writeOut("[Engine] Aether (Kern): ab \(Int(start)) s")
                return
            } catch {
                AppLog.writeOut("[Engine] Kern nicht möglich (\(error)), alter Weg")
            }
        }
        do {
            let engine = try AetherPlayerEngine(host: self, request: request, url: url,
                                                audioIndex: effectiveAudio, subtitleIndex: subtitleIndex)
            avEngine = engine
            engine.subtitleDelay = subtitleDelay
            engine.audioDelay = audioDelay
            engine.fill(fillWish)
            if let volume = requestVolume { engine.volume(Int(volume)) }
            if tempoWish != 1 { engine.tempo = tempoWish }
            engine.load(start: start)
            AppLog.writeOut("[Engine] Aether: ab \(Int(start)) s\(url.isFileURL ? " · Datei auf dem Gerät" : "")")
        } catch {
            AppLog.writeOut("[Aether] Fehler: nicht startbar: \(error.localizedDescription)")
            startErrorReported?("Aether: \(error.localizedDescription)")
        }
    }

    /// A source without streams, for files on the device.
    static let emptySource: MediaSource = {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(MediaSource.self, from: Data("{}".utf8))
    }()

    /// The description of a file on the device: the stored runtime (a built download has no duration in its header, so the
    /// engine then cannot plan segments) and the subtitle streams the download stored (`info.json` and the files next to
    /// it, see ``DownloadedSubtitles``): the track list of a stored title. Audio comes from the engine's own tracks.
    static func fileSource(_ url: URL, _ start: CoreStart?) -> MediaSource {
        guard url.isFileURL, let start else { return emptySource }
        let ticks = start.model.downloads.entries(for: start.item.id)?.runtimeTicks ?? start.item.runTimeTicks
        return DownloadedSubtitles.source(runtimeTicks: ticks, folder: DownloadFiles.subtitleFolder(to: url)) ?? emptySource
    }

    // MARK: Events from the engine

    /// The engine's clock started or stopped; the play button follows it.
    func avRunning(_ go: Bool) {
        if go { pausedSince = nil } else if pausedSince == nil { pausedSince = Date() }
        runsReported?(go)
    }

    /// The engine cannot play this title. There is no other player to fall back on: the screen
    /// shows its start-error message while no picture has been shown.
    func avFailed(_ reason: String) {
        AppLog.writeOut("[Aether] Fehler gemeldet: \(reason)")
        // A downloaded file that does not open: the screen plays the stream instead (if it can).
        if fileFailed?(reason) == true { return }
        startErrorReported?(reason)
    }

    /// The engine could not apply a track after the start: say which tracks play.
    func avHandOver(audio: Int?, subtitle: Int?, reason: String, failed: Bool = false) {
        guard let engine = avEngine else { return }
        AppLog.writeOut("[Spuren] \(reason)")
        trackIndicesReport(TrackIndices(audio: audio ?? engine.audioIndex, subtitle: -1))
    }

    // MARK: Tracks

    func avAudioTracks(_ engine: any PlaybackBackend) -> [SurfaceTrack] {
        let streams = (engine.request.source.mediaStreams ?? []).filter { $0.type == "Audio" }
        return streams.map { stream in
            let name = TrackLabel.audio(language: stream.language,
                                        codec: TechDetails.codecNameValue(stream.codec),
                                        channels: stream.channels)
                ?? stream.displayTitle ?? String(localized: "Ton")
            return SurfaceTrack(stream: stream, name: name, selected: stream.index == engine.audioIndex)
        }
    }

    func avSubtitleTracks(_ engine: any PlaybackBackend) -> [SurfaceTrack] {
        let streams = (engine.request.source.mediaStreams ?? []).filter { $0.type == "Subtitle" }
        return streams.map { stream in
            SurfaceTrack(stream: stream, name: TrackLabel.subtitle(stream) ?? stream.displayTitle ?? "—",
                         selected: stream.index == engine.subtitleIndex)
        }
    }

    func avSubtitleNames(_ engine: any PlaybackBackend) -> [String: String] {
        let tracks = avSubtitleTracks(engine)
        return Dictionary(zip(tracks.map(\.trackId), TrackLabel.distinct(tracks.map(\.trackName))),
                          uniquingKeysWith: { first, _ in first })
    }

    /// The start choice of ``wendeLanguagesAn(audio:subtitle:automatic:source:title:originalLanguage:)``
    /// while AVPlayer plays: the rule's answer is applied once more, which matters only where
    /// it changed since `play` (a choice made on another device, the server's source).
    func avTracksApply(_ engine: any PlaybackBackend, audio: String, subtitle: String, automatic: Bool,
                       source: MediaSource?, title: String?, originalLanguage: String?) {
        trackTitle = title
        trackSource = source
        trackOriginal = originalLanguage
        let streams = source?.mediaStreams ?? engine.request.source.mediaStreams ?? []
        let chosen = StartTracks.choose(
            streams: streams, defaultAudio: source?.defaultAudioStreamIndex,
            defaultSubtitle: source?.defaultSubtitleStreamIndex, audioLanguage: audio, subtitleLanguage: subtitle,
            automatic: automatic, title: title, ordered: trackRequest?.ordered, audioFallback: engine.audioIndex)
        let audioIndex = chosen.audio
        let wantedSubtitle = chosen.subtitle
        AppLog.writeOut("[Spuren] \(engine.label): Ton \(audioIndex.map(String.init) ?? "Datei") · Untertitel "
            + (wantedSubtitle < 0 ? "off" : "feed(\(wantedSubtitle))"))
        if let audioIndex, audioIndex != engine.audioIndex { engine.switchAudio(to: audioIndex) }
        var shownSubtitle = wantedSubtitle
        if wantedSubtitle != engine.subtitleIndex, !engine.selectSubtitle(wantedSubtitle) {
            AppLog.writeOut("[Spuren] Untertitel \(wantedSubtitle) nicht darstellbar, bleibt aus")
            shownSubtitle = -1
        }
        trackIndicesReport(TrackIndices(audio: audioIndex, subtitle: shownSubtitle))
    }

    /// A hand choice in the panel: remembered for the series.
    func avAudioChosen(_ engine: any PlaybackBackend, _ surface: SurfaceTrack) {
        guard let stream = surface.stream, let index = stream.index else { return }
        if let trackTitle {
            let streams = engine.request.source.mediaStreams ?? []
            StartTracks.remember(.audio, streams: streams, index: index, name: surface.trackName, title: trackTitle)
            AppLog.writeOut("[Spuren] Ton von Hand: \(index)")
        }
        engine.switchAudio(to: index)
        trackIndicesReport(TrackIndices(audio: index, subtitle: reportedTracks.subtitle))
    }

    func avSubtitleChosen(_ engine: any PlaybackBackend, _ surface: SurfaceTrack?) {
        guard let stream = surface?.stream, let index = stream.index else {
            if let trackTitle {
                StartTracks.remember(.subtitle, streams: engine.request.source.mediaStreams ?? [], index: nil, name: nil,
                                     title: trackTitle)
            }
            engine.selectSubtitle(-1)
            AppLog.writeOut("[Spuren] Untertitel von Hand: aus")
            trackIndicesReport(TrackIndices(audio: reportedTracks.audio, subtitle: -1))
            return
        }
        if let trackTitle {
            let streams = engine.request.source.mediaStreams ?? []
            StartTracks.remember(.subtitle, streams: streams, index: index, name: surface?.trackName, title: trackTitle)
            AppLog.writeOut("[Spuren] Untertitel von Hand: \(index)")
        }
        if engine.selectSubtitle(index) {
            trackIndicesReport(TrackIndices(audio: reportedTracks.audio, subtitle: index))
        } else {
            AppLog.writeOut("[Spuren] Untertitel \(index) nicht darstellbar, bleibt aus")
            trackIndicesReport(TrackIndices(audio: reportedTracks.audio, subtitle: -1))
        }
    }
}
