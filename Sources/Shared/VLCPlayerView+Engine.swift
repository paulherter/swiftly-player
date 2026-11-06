import AVFoundation
import JellyfinKit

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
        let request = wish?.engine ?? EngineRequest(itemID: "", source: Self.emptySource,
                                                    subtitleFiles: subtitle)
        let streams = request.source.mediaStreams ?? []
        let memory = TrackMemory()
        let audio = TrackRule.audio(streams: streams,
                                    remembered: wish?.title.flatMap { memory.audio(for: $0) },
                                    preferredLanguage: wish?.audio ?? "",
                                    serverPreGift: request.source.defaultAudioStreamIndex,
                                    ordered: wish?.ordered?.audio)
        let choice = TrackRule.subtitle(streams: streams,
                                        remembered: wish?.title.flatMap { memory.subtitle(for: $0) },
                                        serverPreGift: request.source.defaultSubtitleStreamIndex,
                                        automatic: wish?.automatic ?? false, audioIndex: audio,
                                        tonwunsch: wish?.audio ?? "", preferredLanguage: wish?.subtitle ?? "",
                                        ordered: wish?.ordered?.subtitle)
        var subtitleIndex = -1
        if case .feed(let index) = choice { subtitleIndex = index }

        pausedSince = nil
        trackSource = nil
        trackOriginal = nil
        subtitleFiles = []
        lastGoodPosition = start
        trackIndicesReport(TrackIndices())

        let effectiveAudio = audio ?? request.source.defaultAudioStreamIndex
            ?? streams.first(where: { $0.type == "Audio" })?.index
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
        let memory = TrackMemory()
        let audioIndex = TrackRule.audio(streams: streams,
                                         remembered: title.flatMap { memory.audio(for: $0) },
                                         preferredLanguage: audio,
                                         serverPreGift: source?.defaultAudioStreamIndex,
                                         ordered: trackRequest?.ordered?.audio) ?? engine.audioIndex
        let choice = TrackRule.subtitle(streams: streams,
                                        remembered: title.flatMap { memory.subtitle(for: $0) },
                                        serverPreGift: source?.defaultSubtitleStreamIndex,
                                        automatic: automatic, audioIndex: audioIndex,
                                        tonwunsch: audio, preferredLanguage: subtitle,
                                        ordered: trackRequest?.ordered?.subtitle)
        var wantedSubtitle = -1
        if case .feed(let index) = choice { wantedSubtitle = index }
        AppLog.writeOut("[Spuren] \(engine.label): Ton \(audioIndex.map(String.init) ?? "Datei") · Untertitel \(choice)")
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
            TrackMemory().rememberAudio(TrackImprint(feed: stream, in: streams, name: surface.trackName),
                                        for: trackTitle)
            AppLog.writeOut("[Spuren] Ton von Hand: \(index)")
        }
        engine.switchAudio(to: index)
        trackIndicesReport(TrackIndices(audio: index, subtitle: reportedTracks.subtitle))
    }

    func avSubtitleChosen(_ engine: any PlaybackBackend, _ surface: SurfaceTrack?) {
        guard let stream = surface?.stream, let index = stream.index else {
            if let trackTitle { TrackMemory().rememberSubtitle(.off, for: trackTitle) }
            engine.selectSubtitle(-1)
            AppLog.writeOut("[Spuren] Untertitel von Hand: aus")
            trackIndicesReport(TrackIndices(audio: reportedTracks.audio, subtitle: -1))
            return
        }
        if let trackTitle {
            let streams = engine.request.source.mediaStreams ?? []
            TrackMemory().rememberSubtitle(
                .track(TrackImprint(feed: stream, in: streams, name: surface?.trackName)), for: trackTitle)
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
