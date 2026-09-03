import Foundation
import Testing
@testable import JellyfinKit

/// Geprüft wird die **Aussage**, nicht der Wortlaut — die Tests laufen in der
/// Sprache des Rechners.
@Suite("AirPlay-Eignung")
struct AirPlayEignungTests {

    // MARK: - Hilfen

    private func strom(_ typ: String, _ codec: String, index: Int,
                       kanaele: Int? = nil, standard: Bool? = nil) -> MediaStream {
        MediaStream(codec: codec, type: typ, language: nil, displayTitle: nil,
                    channels: kanaele, isDefault: standard, index: index,
                    height: nil, width: nil)
    }

    /// `MediaSource` hat keinen öffentlichen Init — über JSON zusammensetzen,
    /// und zwar in derselben Form, die der Server schickt.
    private func quelle(_ stroeme: [MediaStream]) -> MediaSource {
        try! JSONDecoder().decode(MediaSource.self, from: bauen(stroeme))
    }

    private func bauen(_ stroeme: [MediaStream]) throws -> Data {
        var eintraege: [[String: Any]] = []
        for s in stroeme {
            var e: [String: Any] = ["Codec": s.codec ?? "", "Type": s.type ?? "",
                                    "Index": s.index ?? 0]
            if let k = s.channels { e["Channels"] = k }
            if let d = s.isDefault { e["IsDefault"] = d }
            eintraege.append(e)
        }
        let wurzel: [String: Any] = ["Id": "q1", "Container": "mkv",
                                     "MediaStreams": eintraege]
        return try JSONSerialization.data(withJSONObject: wurzel)
    }

    // MARK: - Der Normalfall

    @Test("H.264 mit AAC geht")
    func h264aac() {
        let e = AirPlayEignung.pruefen(quelle: quelle([
            strom("Video", "h264", index: 0),
            strom("Audio", "aac", index: 1, kanaele: 2, standard: true),
        ]))
        #expect(e.geeignet)
        #expect(e.tonspur == 1)
        #expect(e.meldung == nil)
    }

    @Test("HEVC mit E-AC-3 geht auch")
    func hevcEac3() {
        let e = AirPlayEignung.pruefen(quelle: quelle([
            strom("Video", "hevc", index: 0),
            strom("Audio", "eac3", index: 1, kanaele: 6, standard: true),
        ]))
        #expect(e.geeignet)
    }

    @Test("Container-Kennungen wie hvc1 gelten als HEVC")
    func hvc1() {
        let e = AirPlayEignung.pruefen(quelle: quelle([
            strom("Video", "hvc1", index: 0),
            strom("Audio", "ac3", index: 1),
        ]))
        #expect(e.geeignet)
    }

    // MARK: - Das Gerät am anderen Ende sagt nein

    @Test("DTS allein geht nicht — und die Meldung nennt den Ton")
    func dtsAllein() {
        let e = AirPlayEignung.pruefen(quelle: quelle([
            strom("Video", "h264", index: 0),
            strom("Audio", "dts", index: 1, kanaele: 6, standard: true),
        ]))
        #expect(!e.geeignet)
        #expect(e.tonspur == nil)
        #expect(e.hindernisse.count == 1)
        #expect(e.hindernisse.first?.art == .ton)
        #expect(e.hindernisse.first?.codec == "dts")
        #expect(e.meldung != nil)
    }

    @Test("TrueHD geht nicht")
    func truehd() {
        let e = AirPlayEignung.pruefen(quelle: quelle([
            strom("Video", "hevc", index: 0),
            strom("Audio", "truehd", index: 1, standard: true),
        ]))
        #expect(!e.geeignet)
        #expect(e.hindernisse.first?.art == .ton)
    }

    @Test("AV1 geht nicht — das Bild ist schuld, nicht der Ton")
    func av1() {
        let e = AirPlayEignung.pruefen(quelle: quelle([
            strom("Video", "av1", index: 0),
            strom("Audio", "aac", index: 1, standard: true),
        ]))
        #expect(!e.geeignet)
        #expect(e.hindernisse.count == 1)
        #expect(e.hindernisse.first?.art == .video)
        #expect(e.hindernisse.first?.codec == "av1")
    }

    @Test("Bild und Ton beide unmöglich — beides wird genannt")
    func beides() {
        let e = AirPlayEignung.pruefen(quelle: quelle([
            strom("Video", "vc1", index: 0),
            strom("Audio", "dts", index: 1, standard: true),
        ]))
        #expect(e.hindernisse.count == 2)
        #expect(e.hindernisse.map(\.art).contains(.video))
        #expect(e.hindernisse.map(\.art).contains(.ton))
    }

    // MARK: - Der Fall, der die halbe Sammlung rettet

    @Test("DTS neben AC-3: AirPlay geht über die AC-3-Spur")
    func dtsNebenAc3() {
        let e = AirPlayEignung.pruefen(quelle: quelle([
            strom("Video", "h264", index: 0),
            strom("Audio", "dts", index: 1, kanaele: 6, standard: true),
            strom("Audio", "ac3", index: 2, kanaele: 6),
        ]))
        #expect(e.geeignet)
        #expect(e.tonspur == 2, "Die untaugliche Standardspur darf nicht gewinnen")
    }

    @Test("Taugt die Standardspur, gewinnt sie — auch mit weniger Kanälen")
    func standardGewinnt() {
        let e = AirPlayEignung.pruefen(quelle: quelle([
            strom("Video", "h264", index: 0),
            strom("Audio", "aac", index: 1, kanaele: 2, standard: true),
            strom("Audio", "eac3", index: 2, kanaele: 6),
        ]))
        #expect(e.tonspur == 1)
    }

    @Test("Ohne Standardspur gewinnt die mit den meisten Kanälen")
    func meisteKanaele() {
        let e = AirPlayEignung.pruefen(quelle: quelle([
            strom("Video", "h264", index: 0),
            strom("Audio", "aac", index: 1, kanaele: 2),
            strom("Audio", "eac3", index: 2, kanaele: 6),
            strom("Audio", "ac3", index: 3, kanaele: 6),
        ]))
        #expect(e.tonspur == 2, "Bei Gleichstand bleibt die Reihenfolge des Servers")
    }

    // MARK: - Ränder

    @Test("Untertitel entscheiden nicht mit")
    func untertitelEgal() {
        let e = AirPlayEignung.pruefen(quelle: quelle([
            strom("Video", "h264", index: 0),
            strom("Audio", "aac", index: 1, standard: true),
            strom("Subtitle", "pgssub", index: 2),
        ]))
        #expect(e.geeignet)
    }

    @Test("Eine Datei ohne Ströme wird nicht abgelehnt")
    func ohneStroeme() {
        let e = AirPlayEignung.pruefen(quelle: quelle([]))
        #expect(e.geeignet)
        #expect(e.tonspur == nil)
    }
}
