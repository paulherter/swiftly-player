import Foundation
import Testing
@testable import JellyfinKit

/// The **statement** is checked, not the wording. The tests run in the
/// language of the machine.
@Suite("AirPlay-Eignung")
struct AirPlaySuitabilityTests {

    // MARK: - Helpers

    private func feed(_ type: String, _ codec: String, index: Int,
                       channels: Int? = nil, standard: Bool? = nil) -> MediaStream {
        MediaStream(codec: codec, type: type, language: nil, displayTitle: nil,
                    channels: channels, isDefault: standard, index: index,
                    height: nil, width: nil)
    }

    /// `MediaSource` has no public init, so build it from JSON,
    /// in the same shape the server sends.
    private func source(_ streams: [MediaStream]) -> MediaSource {
        try! JSONDecoder().decode(MediaSource.self, from: construct(streams))
    }

    private func construct(_ streams: [MediaStream]) throws -> Data {
        var entries: [[String: Any]] = []
        for s in streams {
            var e: [String: Any] = ["Codec": s.codec ?? "", "Type": s.type ?? "",
                                    "Index": s.index ?? 0]
            if let k = s.channels { e["Channels"] = k }
            if let d = s.isDefault { e["IsDefault"] = d }
            entries.append(e)
        }
        let root: [String: Any] = ["Id": "q1", "Container": "mkv",
                                     "MediaStreams": entries]
        return try JSONSerialization.data(withJSONObject: root)
    }

    // MARK: - The normal case

    @Test("H.264 mit AAC geht")
    func h264aac() {
        let e = AirPlaySuitability.check(source: source([
            feed("Video", "h264", index: 0),
            feed("Audio", "aac", index: 1, channels: 2, standard: true),
        ]))
        #expect(e.fitting)
        #expect(e.audioTrack == 1)
        #expect(e.message == nil)
    }

    @Test("HEVC mit E-AC-3 geht auch")
    func hevcEac3() {
        let e = AirPlaySuitability.check(source: source([
            feed("Video", "hevc", index: 0),
            feed("Audio", "eac3", index: 1, channels: 6, standard: true),
        ]))
        #expect(e.fitting)
    }

    @Test("Container-Kennungen wie hvc1 gelten als HEVC")
    func hvc1() {
        let e = AirPlaySuitability.check(source: source([
            feed("Video", "hvc1", index: 0),
            feed("Audio", "ac3", index: 1),
        ]))
        #expect(e.fitting)
    }

    // MARK: - The device at the other end says no

    @Test("DTS allein geht nicht — und die Meldung nennt den Ton")
    func dtsAll() {
        let e = AirPlaySuitability.check(source: source([
            feed("Video", "h264", index: 0),
            feed("Audio", "dts", index: 1, channels: 6, standard: true),
        ]))
        #expect(!e.fitting)
        #expect(e.audioTrack == nil)
        #expect(e.obstacles.count == 1)
        #expect(e.obstacles.first?.art == .audio)
        #expect(e.obstacles.first?.codec == "dts")
        #expect(e.message != nil)
    }

    @Test("TrueHD geht nicht")
    func truehd() {
        let e = AirPlaySuitability.check(source: source([
            feed("Video", "hevc", index: 0),
            feed("Audio", "truehd", index: 1, standard: true),
        ]))
        #expect(!e.fitting)
        #expect(e.obstacles.first?.art == .audio)
    }

    @Test("AV1 geht nicht — das Bild ist schuld, nicht der Ton")
    func av1() {
        let e = AirPlaySuitability.check(source: source([
            feed("Video", "av1", index: 0),
            feed("Audio", "aac", index: 1, standard: true),
        ]))
        #expect(!e.fitting)
        #expect(e.obstacles.count == 1)
        #expect(e.obstacles.first?.art == .video)
        #expect(e.obstacles.first?.codec == "av1")
    }

    @Test("Bild und Ton beide unmöglich — beides wird genannt")
    func beides() {
        let e = AirPlaySuitability.check(source: source([
            feed("Video", "vc1", index: 0),
            feed("Audio", "dts", index: 1, standard: true),
        ]))
        #expect(e.obstacles.count == 2)
        #expect(e.obstacles.map(\.art).contains(.video))
        #expect(e.obstacles.map(\.art).contains(.audio))
    }

    // MARK: - The case that saves half the collection

    @Test("DTS neben AC-3: AirPlay geht über die AC-3-Spur")
    func dtsBesideAc3() {
        let e = AirPlaySuitability.check(source: source([
            feed("Video", "h264", index: 0),
            feed("Audio", "dts", index: 1, channels: 6, standard: true),
            feed("Audio", "ac3", index: 2, channels: 6),
        ]))
        #expect(e.fitting)
        #expect(e.audioTrack == 2, "Die untaugliche Standardspur darf nicht gewinnen")
    }

    @Test("Taugt die Standardspur, gewinnt sie — auch mit weniger Kanälen")
    func standardWins() {
        let e = AirPlaySuitability.check(source: source([
            feed("Video", "h264", index: 0),
            feed("Audio", "aac", index: 1, channels: 2, standard: true),
            feed("Audio", "eac3", index: 2, channels: 6),
        ]))
        #expect(e.audioTrack == 1)
    }

    @Test("Ohne Standardspur gewinnt die mit den meisten Kanälen")
    func mostChannels() {
        let e = AirPlaySuitability.check(source: source([
            feed("Video", "h264", index: 0),
            feed("Audio", "aac", index: 1, channels: 2),
            feed("Audio", "eac3", index: 2, channels: 6),
            feed("Audio", "ac3", index: 3, channels: 6),
        ]))
        #expect(e.audioTrack == 2, "Bei Gleichstand bleibt die Reihenfolge des Servers")
    }

    // MARK: - Edges

    @Test("Untertitel entscheiden nicht mit")
    func subtitleIrrelevant() {
        let e = AirPlaySuitability.check(source: source([
            feed("Video", "h264", index: 0),
            feed("Audio", "aac", index: 1, standard: true),
            feed("Subtitle", "pgssub", index: 2),
        ]))
        #expect(e.fitting)
    }

    @Test("Kann der Server nicht umpacken, ist das ein Hindernis mit Namen")
    func umpacken() {
        let e = AirPlaySuitability(audioTrack: nil, obstacles: [
            .init(art: .umpacken, codec: "mkv")
        ])
        #expect(!e.fitting)
        #expect(e.audioTrack == nil)
        #expect(e.message != nil)
        // The container must appear in the message, otherwise nobody knows
        // which file is meant.
        #expect(e.message?.localizedCaseInsensitiveContains("mkv") == true)
    }

    @Test("Eine Datei ohne Ströme wird nicht abgelehnt")
    func withoutStreams() {
        let e = AirPlaySuitability.check(source: source([]))
        #expect(e.fitting)
        #expect(e.audioTrack == nil)
    }
}
