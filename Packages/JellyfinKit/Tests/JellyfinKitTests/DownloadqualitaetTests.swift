import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

@Suite("Downloadqualitaet")
struct DownloadqualitaetTests {

    /// 45 Minuten in Ticks.
    let folge: Int64 = 45 * 60 * 10_000_000

    @Test("Nur mit beiden Rechten waehlbar; Schweigen sperrt nicht")
    func waehlbar() {
        #expect(Downloadqualitaet.waehlbar(videoUmwandeln: nil, tonUmwandeln: nil))
        #expect(Downloadqualitaet.waehlbar(videoUmwandeln: true, tonUmwandeln: true))
        #expect(!Downloadqualitaet.waehlbar(videoUmwandeln: false, tonUmwandeln: true))
        #expect(!Downloadqualitaet.waehlbar(videoUmwandeln: true, tonUmwandeln: false))
    }

    @Test("Ohne Recht nur das Original")
    func ohneRecht() {
        #expect(Downloadqualitaet.angeboten(waehlbar: false, quellBitrate: 50_000_000) == [.original])
    }

    @Test("Stufen, die nicht kleiner machen, fallen weg")
    func stufenFilter() {
        #expect(Downloadqualitaet.angeboten(waehlbar: true, quellBitrate: nil)
                == [.original, .hd1080, .hd720, .sd480])
        #expect(Downloadqualitaet.angeboten(waehlbar: true, quellBitrate: 30_000_000)
                == [.original, .hd1080, .hd720, .sd480])
        // Eine 720p-Folge mit 3 Mbit/s: nur 480p macht sie kleiner.
        #expect(Downloadqualitaet.angeboten(waehlbar: true, quellBitrate: 3_000_000)
                == [.original, .sd480])
    }

    @Test("Quellbitrate aus Groesse und Laufzeit, die beste zaehlt")
    func quellbitrate() {
        // 2,7 GB in 45 Minuten = 8 Mbit/s
        #expect(Downloadqualitaet.bitrate(bytes: 2_700_000_000, laufzeitTicks: folge) == 8_000_000)
        #expect(Downloadqualitaet.bitrate(bytes: 0, laufzeitTicks: folge) == nil)
        #expect(Downloadqualitaet.bitrate(bytes: 1, laufzeitTicks: nil) == nil)
        let q = Downloadqualitaet.quellBitrate([(1_350_000_000, folge), (2_700_000_000, folge), (5, nil)])
        #expect(q == 8_000_000)
    }

    @Test("Geschaetzte Groesse: Bitrate mal Laufzeit, nie ueber dem Original")
    func groesse() {
        let original: Int64 = 10_000_000_000
        #expect(Downloadqualitaet.original.geschaetzteBytes(original: original, laufzeitTicks: folge) == original)
        // 720p: 4,256 Mbit/s * 2700 s / 8 * 1,03 ≈ 1,48 GB
        let s720 = Downloadqualitaet.hd720.geschaetzteBytes(original: original, laufzeitTicks: folge)
        #expect(s720 > 1_400_000_000 && s720 < 1_550_000_000)
        #expect(Downloadqualitaet.sd480.geschaetzteBytes(original: original, laufzeitTicks: folge) < s720)
        // Quelle kleiner als die Stufe: nie teurer als das Original.
        #expect(Downloadqualitaet.hd1080.geschaetzteBytes(original: 500_000_000, laufzeitTicks: folge) == 500_000_000)
        // Ohne Laufzeit keine Zahl.
        #expect(Downloadqualitaet.hd720.geschaetzteBytes(original: original, laufzeitTicks: nil) == 0)
    }

    @Test("Posten in anderer Qualitaet: Matroska, Schaetzung, alte Listen bleiben lesbar")
    func posten() throws {
        let p = Downloadposten(id: "a", konto: "u", art: .film, titel: "T",
                               laufzeitTicks: folge, container: "mp4", quelle: "q",
                               bytes: 10_000_000_000)
        #expect(p.qualitaet == nil && !p.umgewandelt && p.guete == .original)
        let klein = p.inQualitaet(.hd720)
        #expect(klein.container == "mkv")
        #expect(klein.dateiname.hasSuffix(".mkv"))
        #expect(klein.umgewandelt && klein.guete == .hd720)
        #expect(klein.bytes < p.bytes)
        let gleich = p.inQualitaet(.original)
        #expect(gleich == p)

        // Eine Liste von vor 1.0.5 hat kein Feld `qualitaet`.
        let alt = try JSONEncoder().encode([p])
        var roh = try #require(String(data: alt, encoding: .utf8))
        roh = roh.replacingOccurrences(of: #","qualitaet":null"#, with: "")
        let gelesen = try JSONDecoder().decode([Downloadposten].self, from: Data(roh.utf8))
        #expect(gelesen.first?.guete == .original)

        // Und die neue Liste traegt die Wahl.
        let neu = try JSONDecoder().decode([Downloadposten].self,
                                           from: JSONEncoder().encode([klein]))
        #expect(neu.first?.qualitaet == .hd720)
    }

    @Test("Gruppe nennt die Stufe nur, wenn sie fuer alle gilt")
    func gemeinsam() {
        let a = Downloadposten(id: "a", konto: "u", art: .folge, titel: "A",
                               laufzeitTicks: folge, bytes: 1_000_000_000)
        let b = Downloadposten(id: "b", konto: "u", art: .folge, titel: "B",
                               laufzeitTicks: folge, bytes: 1_000_000_000)
        #expect(Downloadqualitaet.gemeinsam([a.inQualitaet(.sd480), b.inQualitaet(.sd480)]) == .sd480)
        #expect(Downloadqualitaet.gemeinsam([a.inQualitaet(.sd480), b]) == nil)
        #expect(Downloadqualitaet.gemeinsam([a, b]) == nil)
        #expect(Downloadqualitaet.gemeinsam([]) == nil)
    }

    @Test("Eine Schaetzung zeigt vor dem Ende nie voll")
    func anteil() {
        var p = Downloadposten(id: "a", konto: "u", art: .film, titel: "T",
                               laufzeitTicks: folge, bytes: 10_000_000_000).inQualitaet(.sd480)
        p.stand = .laedt
        p.geladen = p.bytes * 2
        #expect(p.anteil == 0.99)
        p.stand = .fertig
        #expect(p.anteil == 1)
    }

    @Test("Worte: Plakette und Bitrate sprachbewusst")
    func worte() {
        let de = Locale(identifier: "de_DE"), en = Locale(identifier: "en_US")
        #expect(Downloadqualitaet.sd480.zusatz(locale: de) == "1,5 Mbit/s")
        #expect(Downloadqualitaet.sd480.zusatz(locale: en) == "1.5 Mbit/s")
        #expect(Downloadqualitaet.hd720.plakette(locale: de) == "720p · 4 Mbit/s")
    }

    @Test("Umgewandelt: eingebettete Textuntertitel reisen mit, Bilduntertitel nicht")
    func untertitel() {
        func ut(_ i: Int, _ codec: String, extern: Bool = false) -> MediaStream {
            MediaStream(codec: codec, type: "Subtitle", language: "ger", displayTitle: nil,
                        channels: nil, isDefault: nil, index: i, height: nil, width: nil,
                        isExternal: extern,
                        deliveryUrl: extern ? "/Videos/x/q/Subtitles/\(i)/0/Stream.srt" : nil)
        }
        let stroeme = [ut(2, "subrip"), ut(3, "PGSSUB"), ut(4, "ass"), ut(5, "srt", extern: true)]
        let server = URL(string: "https://tv.example.de")!
        let original = Untertiteldatei.mitladen(stroeme: stroeme, itemID: "x", quelle: "q",
                                                server: server, schluessel: "k", umgewandelt: false)
        #expect(original.map(\.index) == [5])
        let klein = Untertiteldatei.mitladen(stroeme: stroeme, itemID: "x", quelle: "q",
                                             server: server, schluessel: "k", umgewandelt: true)
        #expect(klein.map(\.index) == [2, 4, 5])
        #expect(klein.first?.adresse.path == "/Videos/x/q/Subtitles/2/0/Stream.srt")
        #expect(klein[1].adresse.pathExtension == "ass")
        #expect(klein.first?.adresse.query?.contains("ApiKey=k") == true)
    }

    @Test("Adresse: Original unveraendert, Stufe wandelt um")
    func adresse() async throws {
        let c = JellyfinClient(baseURL: URL(string: "https://tv.example.de")!,
                               deviceID: "dev-42", deviceName: "Prueflauf",
                               session: .init(accessToken: "tok", userID: "u1", userName: "n",
                                              serverURL: URL(string: "https://tv.example.de")!))
        let orig = try await c.downloadURL(itemID: "abc", mediaSourceID: "q", qualitaet: .original)
        #expect(orig == (try await c.downloadURL(itemID: "abc", mediaSourceID: "q")))
        #expect(orig.query?.contains("static=true") == true)

        let klein = try await c.downloadURL(itemID: "abc", mediaSourceID: "q", qualitaet: .hd720)
        let teile = URLComponents(url: klein, resolvingAgainstBaseURL: false)!
        func wert(_ n: String) -> String? { teile.queryItems?.first { $0.name == n }?.value }
        #expect(klein.path == "/Videos/abc/stream.mkv")
        #expect(wert("static") == "false")
        #expect(wert("videoBitRate") == "4000000")
        #expect(wert("maxHeight") == "720")
        #expect(wert("videoCodec") == "h264")
        #expect(wert("mediaSourceId") == "q")
        #expect(wert("ApiKey") == "tok")
    }

    @Test("Tonrecht aus /Users/{id}")
    func tonrecht() throws {
        let v = try JSONDecoder().decode(Kontovorgaben.self, from: Data(
            #"{"Policy":{"EnableVideoPlaybackTranscoding":true,"EnableAudioPlaybackTranscoding":false}}"#.utf8))
        #expect(v.tonUmwandelnErlaubt == false)
        #expect(!v.downloadqualitaetWaehlbar)
        let leer = try JSONDecoder().decode(Kontovorgaben.self, from: Data(#"{"Id":"x"}"#.utf8))
        #expect(leer.downloadqualitaetWaehlbar)
    }
}
