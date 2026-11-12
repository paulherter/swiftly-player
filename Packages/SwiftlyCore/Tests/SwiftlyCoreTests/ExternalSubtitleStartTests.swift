import Foundation
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// **An external subtitle file ("Deutsch SRT") must be selected by the core when the app starts a title.**
///
/// The engine lists such a file under the core's number (`CoreTrackIDs`: 1000 + position). The core only knows
/// that number for a file it was handed in `PlayerStart.subtitleFiles`; the app's start (`CorePlaybackBackend`) once
/// passed an empty list, so the wanted server index never matched the engine's list and the subtitles stayed off
/// (Mac candidate, film with "Deutsch SRT"; series the same). `StartTracks.swift` is the app's file, linked here.
@Suite(.serialized) struct ExternalSubtitleStartTests {
    static let sourceJSON = """
        {"Id":"s","MediaStreams":[
         {"Index":0,"Type":"Video","Codec":"h264"},
         {"Index":1,"Type":"Audio","Codec":"eac3","Language":"ger","Channels":6,"IsDefault":true},
         {"Index":2,"Type":"Subtitle","Codec":"subrip","Language":"ger","Title":"Deutsch","IsExternal":true,
          "DeliveryUrl":"/Videos/x/s/Subtitles/2/0/Stream.srt"},
         {"Index":3,"Type":"Subtitle","Codec":"subrip","Language":"eng","IsHearingImpaired":true,"IsExternal":true,
          "DeliveryUrl":"/Videos/x/s/Subtitles/3/0/Stream.srt"}
        ]}
        """

    static func source() throws -> MediaSource {
        try JSONDecoder().decode(MediaSource.self, from: Data(sourceJSON.utf8))
    }

    static func files() -> [SubtitleFile] {
        [2, 3].map {
            SubtitleFile(index: $0, address: URL(string: "https://tv.example.test/Videos/x/s/Subtitles/\($0)/0/Stream.srt")!,
                         attribute: nil)
        }
    }

    /// The start the way the app builds it, then the engine's first track list (external files under 1000 + n).
    @MainActor static func selected(handing files: [SubtitleFile], wanting index: Int) async throws -> [String] {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let engine = ScriptedPlayerEngine()
        var start = playerStart()
        start.streams = StartTracks.rows(try source().mediaStreams ?? [])
        start.subtitleIndex = Int64(index)
        start.subtitleFiles = StartTracks.files(files)
        start.externalTrackIdBase = CoreTrackIDs.externalBase
        let vm = try makeCore().playerVm(
            account: account(server), locale: "de", start: start, prefs: playerPrefs, engine: engine)
        let model = PlayerModel(vm: vm)
        model.start()
        model.engineEvent(.loadFinished(attempt: 1))
        model.engineEvent(.tracks(
            audio: [PlayerTrack(id: 1, codec: "eac3", language: "ger", name: "Deutsch", channels: 6, isDefault: true, isForced: false)],
            subtitles: [
                PlayerTrack(id: CoreTrackIDs.external(position: 0), codec: "subrip", language: "ger", name: "Deutsch",
                            channels: 0, isDefault: false, isForced: false),
                PlayerTrack(id: CoreTrackIDs.external(position: 1), codec: "subrip", language: "eng", name: "English",
                            channels: 0, isDefault: false, isForced: false),
            ],
            activeAudio: 1, activeSubtitle: nil))
        model.engineEvent(.state(state: .playing))
        _ = await eventuallyOnMain { engine.all.contains { $0.hasPrefix("subtitle ") } }
        return engine.all.filter { $0.hasPrefix("subtitle ") }
    }

    @Test @MainActor func theAppsStartCarriesTheFilesAndTheCoreSelectsThem() async throws {
        let mapped = StartTracks.files(Self.files())
        #expect(mapped.map(\.index) == [2, 3])
        #expect(mapped.first?.address == "https://tv.example.test/Videos/x/s/Subtitles/2/0/Stream.srt")
        // The first file is the engine's track 1000, the second 1001.
        #expect(try await Self.selected(handing: Self.files(), wanting: 2) == ["subtitle 1000"])
        #expect(try await Self.selected(handing: Self.files(), wanting: 3) == ["subtitle 1001"])
    }

    @Test @MainActor func withoutTheFilesTheSubtitleStaysOff() async throws {
        // What the app did before: documented so the test above is known to bite.
        #expect(try await Self.selected(handing: [], wanting: 2).isEmpty)
    }
}
