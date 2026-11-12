import AetherEngine
import Foundation
import SwiftlyCore
import Testing

private func fail(_ id: String, _ column: String, _ detail: String) {
    Record.note(id, column, false, detail)
}

/// Audio switch, subtitles, resume, next episode.
@Suite(.serialized) @MainActor struct FeatureTests {
    /// Server numbers of `bm-multi-mkv`: video 0, audio 1 (eng aac) 2 (deu ac3) 3 (fra eac3), subtitles 4 (srt) 5 (ass).
    @Test func audioTracksAreListedAndSwitchWithoutStopping() async throws {
        let id = "bm-multi-mkv"
        let opened = try await Opened(id: id)
        defer { opened.close() }
        guard await opened.playing(within: 25) != nil else { fail(id, "audio-switch", "never played"); #expect(Bool(false)); return }
        let listed = await until(10) { opened.port.audioTracks.count == 3 && opened.port.subtitleTracks.count >= 2 }
        let coreRows = opened.model.tracks.audio.count
        var ok = listed != nil
        var detail = "engine audio \(opened.port.audioTracks.map(\.id)) subs \(opened.port.subtitleTracks.map(\.id)), core rows \(coreRows)"
        opened.model.send(.selectAudio(index: 3))
        let switched = await until(10) { opened.port.engine.activeAudioTrackIndex == 3 }
        let moving = await opened.advances(by: 0.5)
        ok = ok && switched != nil && moving && coreRows == 3
        detail += "; active \(String(describing: opened.port.engine.activeAudioTrackIndex)), moving \(moving)"
        Record.note(id, "audio-switch", ok, detail)
        #expect(ok, "\(detail)")
    }

    /// External ASS and VTT next to the film (contract line 2): the core hands them to the engine (the old AVPlayer rule dropped
    /// ASS, because AVPlayer cannot draw it; the Apple engine reads it), and picking them delivers the cue text.
    @Test(arguments: [("bm-ext-subs", 3, "ass external file"), ("bm-ext-vtt", 2, "vtt external file")] as [(String, Int64, String)])
    func externalAssAndVttFilesAreHandedOverAndShow(_ id: String, _ index: Int64, _ label: String) async throws {
        let opened = try await Opened(id: id)
        defer { opened.close() }
        let column = "subs: \(label)"
        let handed = opened.ready.start.subtitleFiles.map(\.index)
        guard handed.contains(index) else { fail(id, column, "files handed to the engine: \(handed)"); #expect(handed.contains(index)); return }
        guard await opened.playing(within: 25) != nil else { fail(id, column, "never played"); #expect(Bool(false)); return }
        _ = await until(10) { !opened.port.subtitleTracks.isEmpty }
        opened.model.send(.selectSubtitle(index: index))
        let cues = await until(10) { opened.port.subtitleCues.contains { cue in
            if case .text(let t) = cue.body { return t.contains("Bench") }
            if case .richText(let runs) = cue.body { return runs.map(\.text).joined().contains("Bench") }
            return false
        } }
        let detail = "handed \(handed), tracks \(opened.port.subtitleTracks.map { "\($0.id):\($0.codec)" }), cues \(opened.port.subtitleCues.count)"
        Record.note(id, column, cues != nil, detail)
        #expect(cues != nil, "\(detail)")
    }

    @Test(arguments: [("bm-multi-mkv", 4, "srt embedded"), ("bm-multi-mkv", 5, "ass embedded"),
                      ("bm-ext-subs", 2, "srt external file")])
    func subtitleCuesAreDelivered(_ id: String, _ index: Int64, _ label: String) async throws {
        let opened = try await Opened(id: id)
        defer { opened.close() }
        let column = "subs: \(label)"
        guard await opened.playing(within: 25) != nil else { fail(id, column, "never played"); #expect(Bool(false)); return }
        _ = await until(10) { !opened.port.subtitleTracks.isEmpty }
        opened.model.send(.selectSubtitle(index: index))
        let cues = await until(10) { opened.port.subtitleCues.contains { cue in
            if case .text(let t) = cue.body { return t.contains("Bench") }
            if case .richText(let runs) = cue.body { return runs.map(\.text).joined().contains("Bench") }
            return false
        } }
        let detail = "tracks \(opened.port.subtitleTracks.map { "\($0.id):\($0.codec)" }), cues \(opened.port.subtitleCues.count), active \(String(describing: opened.port.engine.activeSubtitleTrackIndex)), listed in core: \(opened.model.tracks.subtitles.map(\.index))"
        Record.note(id, column, cues != nil, detail)
        #expect(cues != nil, "\(detail)")
    }

    /// Bitmap (PGS) subtitles of a resumed mkv, the Blu-ray rip shape: `bm-pgs-mkv` has video 0, audio 1, PGS 2 (forced, a cue every
    /// 60 s from 124 s) and 3 (full, every 10 s), SRT 4, and resumes at 120 s. Picking a PGS track must publish a picture cue within 25 s.
    @Test(arguments: [(2, "pgs forced"), (3, "pgs full")] as [(Int64, String)])
    func pgsCuesAreDeliveredAfterAResume(_ index: Int64, _ label: String) async throws {
        let id = "bm-pgs-mkv"
        let opened = try await Opened(id: id)
        defer { opened.close() }
        let column = "subs: \(label)"
        guard await opened.playing(within: 25) != nil else { fail(id, column, "never played"); #expect(Bool(false)); return }
        _ = await until(10) { opened.port.subtitleTracks.count >= 3 }
        opened.model.send(.selectSubtitle(index: index))
        let cues = await until(25) { opened.port.subtitleCues.contains { cue in
            if case .image = cue.body { return true }
            return false
        } }
        let detail = "tracks \(opened.port.subtitleTracks.map { "\($0.id):\($0.codec)" }), cues \(opened.port.subtitleCues.count), active \(String(describing: opened.port.engine.activeSubtitleTrackIndex)), plan startAt \(opened.ready.start.startAt), engine at \(String(format: "%.1f", opened.port.position)) s"
        Record.note(id, column, cues != nil, detail)
        #expect(cues != nil, "\(detail)")
    }

    @Test func resumeStartsAtTheRememberedPositionAndAnExplicitOneWins() async throws {
        let id = "bm-resume"
        let (remembered, _) = try await Opened.plan(id)
        let (explicit, _) = try await Opened.plan(id, since: 7)
        let planOk = remembered?.start.startAt == 80 && explicit?.start.startAt == 7
        let opened = try await Opened(id: id)
        defer { opened.close() }
        let played = await opened.playing(within: 25)
        let landed = played != nil && opened.port.position >= 79
        let detail = "plan startAt \(remembered?.start.startAt ?? -1) / explicit \(explicit?.start.startAt ?? -1); engine at \(String(format: "%.1f", opened.port.position)) s"
        Record.note(id, "resume", planOk && landed, detail)
        #expect(planOk && landed, "\(detail)")
    }

    @Test func nextEpisodeIsNamedByTheCore() async throws {
        let (first, _) = try await Opened.plan("bm-ep1")
        let (last, _) = try await Opened.plan("bm-ep2")
        let detail = "ep1 next \(first?.start.next?.id ?? "nil"), ep2 next \(last?.start.next?.id ?? "nil")"
        let ok = first?.start.next?.id == "bm-ep2"
        Record.note("bm-ep1", "next-episode", ok, detail)
        #expect(ok, "\(detail)")
    }
}

/// **Column "download"**: the file the app would store (the server's original, or the remux to one audio track that has no
/// duration in its header) plays offline, with the right length, and seeks.
@Suite(.serialized) @MainActor struct DownloadTests {
    static func store(_ path: String, name: String) async throws -> URL {
        let (data, response) = try await BenchServer.shared.data(path)
        #expect(response.statusCode == 200)
        let dir = FileManager.default.temporaryDirectory.appending(path: "pbench-downloads")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: name)
        try data.write(to: file)
        return file
    }

    static func check(_ id: String, column: String, file: URL, container: String, source: String, codec: String) async throws {
        let downloaded = PlayDownloaded(file: file.path, container: container, source: source, videoCodec: codec, sections: nil, subtitleFiles: [])
        let opened = try await Opened(id: id, downloaded: downloaded)
        defer { opened.close() }
        let played = await opened.playing(within: 25)
        guard played != nil else {
            Record.note(id, column, false, "never played: \(opened.port.failure ?? "-"), tries \(opened.port.loadAttempts)")
            #expect(Bool(false), "\(id) offline file did not play"); return
        }
        _ = await until(6) { opened.port.duration > 0 }
        let duration = opened.port.duration
        let moving = await opened.advances()
        opened.model.send(.seekTo(seconds: 6))
        let landed = await until(8) { opened.port.position > 5.5 } != nil
        let ok = abs(duration - 10) < 0.7 && moving && landed
        let detail = "duration \(String(format: "%.2f", duration)) s, retried with stored runtime: \(opened.port.retriedWithRuntime)"
        Record.note(id, column, ok, detail)
        #expect(ok, "\(detail)")
    }

    @Test(arguments: benchTitles)
    func originalFilePlaysOffline(_ id: String) async throws {
        let (info, _) = try await BenchServer.shared.data("/Items/\(id)/PlaybackInfo")
        let source = ((try JSONSerialization.jsonObject(with: info) as? [String: Any])?["MediaSources"] as? [[String: Any]])?.first
        let container = (source?["Container"] as? String) ?? "mkv"
        let file = try await Self.store("/Videos/\(id)/stream?static=true", name: "\(id).\(container)")
        let codec = ((source?["MediaStreams"] as? [[String: Any]])?.first { $0["Type"] as? String == "Video" }?["Codec"] as? String) ?? "h264"
        try await Self.check(id, column: "download", file: file, container: container, source: "src-\(id)", codec: codec)
    }

    /// The reported beta bug: a download rebuilt to one audio track has no duration in its header.
    @Test func rebuiltSingleAudioDownloadWithoutHeaderDurationPlays() async throws {
        let file = try await Self.store("/Videos/bm-multi-mkv/stream.mkv?static=false&container=mkv&audioStreamIndex=2", name: "bm-multi-mkv.single.mkv")
        try await Self.check("bm-multi-mkv", column: "download: rebuilt single audio", file: file, container: "mkv", source: "src-bm-multi-mkv", codec: "h264")
    }

    @Test func serverAnswersRangesTheWayPlayersAskThem() async throws {
        let (part, response) = try await BenchServer.shared.data("/Videos/bm-h264-aac-mp4/stream?static=true", range: "bytes=100-199")
        let ok = response.statusCode == 206 && part.count == 100
        Record.note("fixture", "range", ok, "status \(response.statusCode), \(part.count) bytes")
        #expect(ok)
    }
}
