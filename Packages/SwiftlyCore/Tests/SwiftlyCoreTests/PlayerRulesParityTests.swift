import Foundation
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// **Old Swift rules and the core's rules on the same fixtures**, before the Swift side goes.
/// The streams are real `MediaStreams` JSON of the kind Jellyfin sends (Dolby Vision profile 5
/// video, TrueHD with Atmos, AC3, an embedded text subtitle, a picture subtitle and a sideloaded
/// file). A difference here is a core bug, fixed in the owning crate with a Rust test.
@Suite struct PlayerRulesParityTests {
    static let streamsJSON = """
        [
         {"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160,"VideoRangeType":"DOVI","DvProfile":5},
         {"Index":1,"Type":"Audio","Codec":"truehd","Language":"eng","Channels":8,"DisplayTitle":"English - TrueHD Atmos - 7.1","IsDefault":true},
         {"Index":2,"Type":"Audio","Codec":"ac3","Language":"ger","Channels":6,"DisplayTitle":"Deutsch - Dolby Digital - 5.1"},
         {"Index":3,"Type":"Audio","Codec":"aac","Language":"jpn","Channels":2,"IsOriginal":true},
         {"Index":4,"Type":"Subtitle","Codec":"subrip","Language":"eng"},
         {"Index":5,"Type":"Subtitle","Codec":"hdmv_pgs_subtitle","Language":"ger"},
         {"Index":6,"Type":"Subtitle","Codec":"srt","Language":"ger","IsExternal":true}
        ]
        """
    static let md5 = "0123456789abcdef0123456789abcdef"

    private func streams() throws -> [MediaStream] {
        try JSONDecoder().decode([MediaStream].self, from: Data(Self.streamsJSON.utf8))
    }

    private func codec(_ raw: String) -> String? { TechDetails.codecNameValue(raw) }

    private func tracks() -> (audio: [(String, String, String?, String?, Int?)], subtitle: [(String, String, String?, String?, Int?)]) {
        (
            audio: [
                ("audio/1", "Track 1", "eng", codec("truehd"), 8),
                ("audio/2", "Track 2", "ger", codec("ac3"), 6),
                ("audio/3", "Track 3", "jpn", codec("aac"), 2),
            ],
            subtitle: [
                ("spu/4", "Track 1", "eng", codec("subrip"), nil),
                ("spu/5", "Track 2", "ger", codec("hdmv_pgs_subtitle"), nil),
                ("\(Self.md5)/spu/0", "Track 3", "ger", codec("srt"), nil),
            ]
        )
    }

    private func old(_ files: [SubtitleFile]) throws -> TrackMapping {
        let t = tracks()
        func make(_ rows: [(String, String, String?, String?, Int?)]) -> [JellyfinKit.PlayerTrack] {
            rows.map { JellyfinKit.PlayerTrack(identifier: $0.0, name: $0.1, language: $0.2, codec: $0.3, channels: $0.4) }
        }
        return TrackMapping.compose(
            audio: make(t.audio), subtitle: make(t.subtitle), streams: try streams(), files: files)
    }

    private func new(_ files: [HostSubtitleFile]) throws -> HostTrackMapping {
        let t = tracks()
        func make(_ rows: [(String, String, String?, String?, Int?)]) -> [HostTrack] {
            rows.map { HostTrack(identifier: $0.0, name: $0.1, language: $0.2, codec: $0.3, channels: $0.4.map(Int64.init)) }
        }
        return try mapHostTracks(
            audio: make(t.audio), subtitle: make(t.subtitle), streamsJson: Self.streamsJSON, files: files)
    }

    @Test func hostTracksMapToTheSameServerIndices() throws {
        let address = try #require(URL(string: "https://tv.example.test/Videos/x/Subtitles/6/0/Stream.srt"))
        let theOld = try old([SubtitleFile(index: 6, address: address, attribute: Self.md5)])
        let theNew = try new([HostSubtitleFile(index: 6, address: address.absoluteString, attribute: Self.md5)])
        #expect(theNew.audio == theOld.audio.map { $0.map(Int64.init) })
        #expect(theNew.subtitle == theOld.subtitle.map { $0.map(Int64.init) })
        // Sanity: TrueHD/Atmos keeps its own number, the sideloaded file gets the server's index.
        #expect(theNew.audio == [1, 2, 3])
        #expect(theNew.subtitle == [4, 5, 6])
    }

    @Test func withoutTheFileAttributeOrderDecidesInBothAndTheyAgree() throws {
        let address = try #require(URL(string: "https://tv.example.test/Videos/x/Subtitles/6/0/Stream.srt"))
        let theOld = try old([SubtitleFile(index: 6, address: address, attribute: nil)])
        let theNew = try new([HostSubtitleFile(index: 6, address: address.absoluteString, attribute: nil)])
        #expect(theNew.audio == theOld.audio.map { $0.map(Int64.init) })
        #expect(theNew.subtitle == theOld.subtitle.map { $0.map(Int64.init) })
    }

    @Test func theOriginalTagFollowsTheSameRule() throws {
        let all = try streams()
        let languages: [String?] = ["eng", "ger", "jpn", "ja", "japanese", "de", nil, ""]
        let originals: [String?] = ["ja", "en", "de", "jpn", nil, "xx"]
        for stream in all where stream.type == "Audio" {
            for language in languages {
                for original in originals {
                    let flagged = stream.isOriginal == true
                    let theOld = OriginalAudio.isOriginal(language: language, stream: stream, originalLanguage: original)
                    let theNew = audioIsOriginal(
                        language: language, streamLanguage: stream.language, flaggedOriginal: flagged, originalLanguage: original)
                    #expect(theNew == theOld, "stream \(stream.index ?? -1) language \(language ?? "nil") original \(original ?? "nil")")
                }
            }
        }
        let label = audioLabelWithOriginal(
            base: "Japanisch", language: "jpn", streamLanguage: nil, flaggedOriginal: false, originalLanguage: "ja", suffix: OriginalAudio.suffix)
        #expect(label == OriginalAudio.label("Japanisch", language: "jpn", stream: nil, originalLanguage: "ja"))
    }
}
