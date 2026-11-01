import AVFoundation
import JellyfinKit
import VLCKit

/// What VLC needs to take a title over from AVPlayer: the unchanged address and its options.
struct AVOriginal {
    let url: URL
    let container: String?
    let subtitle: [SubtitleFile]
}

/// **The choice between the two engines, and the way back.**
///
/// `play` lands in ``startEngine(url:offSeconds:container:subtitle:softwareDecoder:)``. The
/// decision itself is the package's ``PlayerEngineChoice``; this file only gathers its inputs,
/// asks the server for the copy-only address and wires the result into the facade. Any
/// trouble hands the title to VLC at the position where AVPlayer stopped
/// (``avFailed(_:)``, ``avHandOver(audio:subtitle:reason:failed:)``).
extension VLCPlayerView {

    /// Titles AVPlayer could not play in this session: VLC takes them for good.
    static var avFailedItems: Set<String> = []

    func startEngine(url: URL, offSeconds: Double, container: String?,
                     subtitle: [SubtitleFile], softwareDecoder: Bool) {
        avCall += 1
        let call = avCall
        avEngine?.stop()
        avEngine = nil
        avOriginal = AVOriginal(url: url, container: container, subtitle: subtitle)
        let start = JumpTarget.seconds(offSeconds) ?? 0

        func vlc(_ reason: String) {
            AppLog.writeOut("[Engine] VLC: \(reason)")
            playVLC(url: url, offSeconds: start, container: container, subtitle: subtitle,
                    softwareDecoder: softwareDecoder)
        }

        // Own headers (a gateway in front of the server) reach VLC through the forwarder;
        // AVPlayer would not send them.
        if !url.isFileURL, !OwnHeaders.of(url).isEmpty {
            vlc("Eigene Header, nur VLC kann sie senden")
            return
        }
        guard let wish = trackRequest, let request = wish.engine, !url.isFileURL else {
            vlc(url.isFileURL ? "Datei auf dem Gerät" : "kein Weg für AVPlayer bei diesem Server")
            return
        }
        let streams = request.source.mediaStreams ?? []
        let memory = TrackMemory()
        let audio = TrackRule.audio(streams: streams,
                                    remembered: wish.title.flatMap { memory.audio(for: $0) },
                                    preferredLanguage: wish.audio,
                                    serverPreGift: request.source.defaultAudioStreamIndex,
                                    ordered: wish.ordered?.audio)
        let choice = TrackRule.subtitle(streams: streams,
                                        remembered: wish.title.flatMap { memory.subtitle(for: $0) },
                                        serverPreGift: request.source.defaultSubtitleStreamIndex,
                                        automatic: wish.automatic, audioIndex: audio,
                                        tonwunsch: wish.audio, preferredLanguage: wish.subtitle,
                                        ordered: wish.ordered?.subtitle)
        var subtitleIndex = -1
        if case .feed(let index) = choice { subtitleIndex = index }
        let setting = PlayerEngineSetting(stored: UserDefaults.standard.string(forKey: PlayerEngineSetting.storageKey))
        let decision = PlayerEngineChoice.decide(
            setting: setting, softwareDecoder: softwareDecoder,
            avFailed: Self.avFailedItems.contains(request.itemID), source: request.source,
            audioIndex: audio, subtitleIndex: subtitleIndex >= 0 ? subtitleIndex : nil,
            device: EngineProbe.device)
        AppLog.writeOut(decision.logLine)
        guard decision.engine == .avPlayer else {
            playVLC(url: url, offSeconds: start, container: container, subtitle: subtitle,
                    softwareDecoder: softwareDecoder)
            return
        }
        // A text track without a file the app can draw (Plex, inside the file) is VLC's.
        if subtitleIndex >= 0, !request.subtitleFiles.contains(where: { $0.index == subtitleIndex }) {
            vlc("Untertitel \(subtitleIndex) ohne Textdatei")
            return
        }

        // The previous title may still play in VLC while the address is fetched: stop it now.
        if player.media != nil {
            intentionalEnded = true
            watchdog?.invalidate()
            watchdog = nil
            startGuards?.invalidate()
            startGuards = nil
            startJump = nil
            holdBackAudio(false)
            player.stop()
        }
        pausedSince = nil
        trackSource = nil
        trackOriginal = nil
        subtitleFiles = []
        lastGoodPosition = start
        trackIndicesReport(TrackIndices())

        let effectiveAudio = audio ?? request.source.defaultAudioStreamIndex
            ?? streams.first(where: { $0.type == "Audio" })?.index
        Task { @MainActor [weak self] in
            let plan = await request.plan(audio)
            guard let self, self.avCall == call, !self.finallyStopped else { return }
            guard let plan else {
                // Let a just-stopped VLC finish its stop event before it is started again.
                try? await Task.sleep(for: .milliseconds(250))
                guard self.avCall == call, !self.finallyStopped else { return }
                vlc("Server liefert keinen Kopierstrom")
                return
            }
            let engine = AVPlayerEngine(host: self, request: request, audioIndex: effectiveAudio,
                                        subtitleIndex: -1)
            self.avEngine = engine
            engine.subtitleDelay = self.subtitleDelay
            engine.fill(self.fillWish)
            if let volume = self.requestVolume { engine.volume(Int(volume)) }
            if self.tempoWish != 1 { engine.tempo = self.tempoWish }
            engine.selectSubtitle(subtitleIndex)
            engine.load(plan, start: start)
            AppLog.writeOut("[Engine] AVPlayer: \(plan.method) \(plan.container ?? "?") ab \(Int(start)) s")
        }
    }

    // MARK: Events from the engine

    /// The engine's clock started or stopped; the play button follows it.
    func avRunning(_ go: Bool) {
        if go { pausedSince = nil } else if pausedSince == nil { pausedSince = Date() }
        runsReported?(go)
    }

    /// AVPlayer cannot play this title: VLC takes it, here and for the rest of the session.
    func avFailed(_ reason: String) {
        guard let engine = avEngine else { return }
        Self.avFailedItems.insert(engine.request.itemID)
        avHandOver(audio: nil, subtitle: nil, reason: "AVPlayer gescheitert (\(reason))", failed: true)
    }

    /// Plays the title with VLC from where AVPlayer is, with the tracks now chosen.
    func avHandOver(audio: Int?, subtitle: Int?, reason: String, failed: Bool = false) {
        guard let engine = avEngine, let original = avOriginal else { return }
        let spot = max(engine.position, engine.lastGood)
        let engineAudio = engine.audioIndex
        let engineSubtitle = engine.subtitleIndex
        trackRequest?.ordered = TrackIndices(audio: audio ?? engine.audioIndex,
                                             subtitle: subtitle ?? engine.subtitleIndex)
        let kept = (trackTitle, trackSource, trackOriginal)
        avCall += 1
        engine.stop()
        avEngine = nil
        AppLog.writeOut("[Engine] VLC: \(reason) bei \(Int(spot)) s")
        playVLC(url: original.url, offSeconds: spot, container: original.container,
                subtitle: original.subtitle, softwareDecoder: false)
        // The screen has its tracks set already and will not ask again; VLC's start options pick
        // the right ones, the source is only needed to name and map them.
        (trackTitle, trackSource, trackOriginal) = kept
        // `playVLC` reported no tracks; the screen will not ask again, so say which ones play.
        trackIndicesReport(TrackIndices(audio: audio ?? engineAudio, subtitle: subtitle ?? engineSubtitle))
    }

    // MARK: Tracks

    func avAudioTracks(_ engine: AVPlayerEngine) -> [SurfaceTrack] {
        let streams = (engine.request.source.mediaStreams ?? []).filter { $0.type == "Audio" }
        return streams.map { stream in
            let name = TrackLabel.audio(language: stream.language,
                                        codec: TechDetails.codecNameValue(stream.codec),
                                        channels: stream.channels)
                ?? stream.displayTitle ?? String(localized: "Ton")
            return SurfaceTrack(stream: stream, name: name, selected: stream.index == engine.audioIndex)
        }
    }

    func avSubtitleTracks(_ engine: AVPlayerEngine) -> [SurfaceTrack] {
        let streams = (engine.request.source.mediaStreams ?? []).filter { $0.type == "Subtitle" }
        return streams.map { stream in
            SurfaceTrack(stream: stream, name: TrackLabel.subtitle(stream) ?? stream.displayTitle ?? "—",
                         selected: stream.index == engine.subtitleIndex)
        }
    }

    func avSubtitleNames(_ engine: AVPlayerEngine) -> [String: String] {
        let tracks = avSubtitleTracks(engine)
        return Dictionary(zip(tracks.map(\.trackId), TrackLabel.distinct(tracks.map(\.trackName))),
                          uniquingKeysWith: { first, _ in first })
    }

    /// The start choice of ``wendeLanguagesAn(audio:subtitle:automatic:source:title:originalLanguage:)``
    /// while AVPlayer plays: the rule's answer is applied once more, which matters only where
    /// it changed since `play` (a choice made on another device, the server's source).
    func avTracksApply(_ engine: AVPlayerEngine, audio: String, subtitle: String, automatic: Bool,
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
        AppLog.writeOut("[Spuren] AVPlayer: Ton \(audioIndex.map(String.init) ?? "Datei") · Untertitel \(choice)")
        if let audioIndex, audioIndex != engine.audioIndex {
            if PlayerEngineChoice.audioTrack(of: engine.request.source, index: audioIndex) != nil {
                engine.switchAudio(to: audioIndex)
            } else {
                avHandOver(audio: audioIndex, subtitle: wantedSubtitle, reason: "Tonspur \(audioIndex) nur mit VLC")
                return
            }
        }
        if wantedSubtitle != engine.subtitleIndex, !engine.selectSubtitle(wantedSubtitle) {
            avHandOver(audio: audioIndex, subtitle: wantedSubtitle, reason: "Untertitel \(wantedSubtitle) nur mit VLC")
            return
        }
        trackIndicesReport(TrackIndices(audio: audioIndex, subtitle: wantedSubtitle))
    }

    /// A hand choice in the panel: remembered for the series, like with VLC.
    func avAudioChosen(_ engine: AVPlayerEngine, _ surface: SurfaceTrack) {
        guard let stream = surface.stream, let index = stream.index else { return }
        if let trackTitle {
            let streams = engine.request.source.mediaStreams ?? []
            TrackMemory().rememberAudio(TrackImprint(feed: stream, in: streams, name: surface.trackName),
                                        for: trackTitle)
            AppLog.writeOut("[Spuren] Ton von Hand: \(index)")
        }
        if PlayerEngineChoice.audioTrack(of: engine.request.source, index: index) != nil {
            engine.switchAudio(to: index)
            trackIndicesReport(TrackIndices(audio: index, subtitle: reportedTracks.subtitle))
        } else {
            avHandOver(audio: index, subtitle: nil, reason: "Tonspur \(index) nur mit VLC")
        }
    }

    func avSubtitleChosen(_ engine: AVPlayerEngine, _ surface: SurfaceTrack?) {
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
            avHandOver(audio: nil, subtitle: index, reason: "Untertitel \(index) nur mit VLC")
        }
    }
}
