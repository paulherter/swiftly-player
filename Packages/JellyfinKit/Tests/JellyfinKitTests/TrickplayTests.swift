import Foundation
import Testing
@testable import JellyfinKit

@Suite("Trickplay")
struct TrickplayTests {

    /// Die Form von `TrickplayInfoDto` am Titel, je Quelle und Breite.
    private let antwort = """
    { "Id": "e1", "Name": "Folge",
      "Trickplay": {
        "abc123": {
          "320": { "Width": 320, "Height": 180, "TileWidth": 10, "TileHeight": 10,
                   "ThumbnailCount": 250, "Interval": 10000, "Bandwidth": 1000 },
          "640": { "Width": 640, "Height": 360, "TileWidth": 10, "TileHeight": 10,
                   "ThumbnailCount": 250, "Interval": 10000, "Bandwidth": 4000 }
        }
      } }
    """.data(using: .utf8)!

    private var angabe: Trickplay {
        Trickplay(breite: 320, hoehe: 180, kachelnBreit: 10, kachelnHoch: 10,
                  anzahl: 250, intervall: 10_000)
    }

    @Test("Einlesen: beide Breiten der Quelle, gewählt wird die passende")
    func einlesen() throws {
        let a = try JSONDecoder().decode(TrickplayAntwort.self, from: antwort)
        #expect(a.quellen["abc123"]?.count == 2)
        #expect(a.fuer(quelle: "abc123")?.breite == 320)
        #expect(a.fuer(quelle: "abc123", ziel: 400)?.breite == 640)
        #expect(a.fuer(quelle: "abc123", ziel: 1000)?.breite == 640)
        // Ohne Kennung zählt die einzige Quelle.
        #expect(a.fuer(quelle: nil)?.breite == 320)
    }

    @Test("Ohne Trickplay am Server: nichts, kein Fehler")
    func ohne() throws {
        let d = #"{ "Id": "e1", "Name": "Folge" }"#.data(using: .utf8)!
        let a = try JSONDecoder().decode(TrickplayAntwort.self, from: d)
        #expect(a.fuer(quelle: "abc123") == nil)
        #expect(a.fuer(quelle: nil) == nil)
    }

    @Test("Unbekannte Quelle bei mehreren: nichts raten")
    func fremdeQuelle() throws {
        let d = """
        { "Trickplay": {
            "a": { "320": { "Width": 320, "Height": 180, "TileWidth": 10, "TileHeight": 10,
                            "ThumbnailCount": 5, "Interval": 1000 } },
            "b": { "320": { "Width": 320, "Height": 180, "TileWidth": 10, "TileHeight": 10,
                            "ThumbnailCount": 5, "Interval": 1000 } } } }
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(TrickplayAntwort.self, from: d)
        #expect(a.fuer(quelle: "c") == nil)
        #expect(a.fuer(quelle: "b") != nil)
    }

    @Test("Kachel: Blatt und Platz im Raster")
    func kachel() {
        // 0 s → erstes Bild, erstes Blatt, links oben.
        #expect(angabe.kachel(sekunden: 0) == .init(blatt: 0, x: 0, y: 0, breite: 320, hoehe: 180))
        // 125 s → n = 12 → Zeile 1, Spalte 2.
        #expect(angabe.kachel(sekunden: 125) == .init(blatt: 0, x: 640, y: 180, breite: 320, hoehe: 180))
        // 1000 s → n = 100 → zweites Blatt, links oben.
        #expect(angabe.kachel(sekunden: 1000) == .init(blatt: 1, x: 0, y: 0, breite: 320, hoehe: 180))
        // 1999 s → n = 199 → zweites Blatt, rechts unten.
        #expect(angabe.kachel(sekunden: 1999) == .init(blatt: 1, x: 2880, y: 1620, breite: 320, hoehe: 180))
    }

    @Test("Über das Ende hinaus bleibt das letzte Bild, davor das erste")
    func raender() {
        // n wird auf 249 begrenzt → Blatt 2, Platz 49.
        #expect(angabe.kachel(sekunden: 99_999) == .init(blatt: 2, x: 2880, y: 720, breite: 320, hoehe: 180))
        #expect(angabe.kachel(sekunden: -5)?.blatt == 0)
        #expect(angabe.kachel(sekunden: .nan) == nil)
    }

    @Test("Adresse: Breite, Blatt, Quelle und Ausweis")
    func adresse() async throws {
        let client = JellyfinClient(
            baseURL: URL(string: "https://jf.example")!, deviceID: "d", deviceName: "n",
            session: Session(accessToken: "t", userID: "u", userName: "n",
                             serverURL: URL(string: "https://jf.example")!))
        let url = try #require(await client.trickplayURL(itemID: "e1", mediaSourceID: "abc",
                                                         breite: 320, blatt: 2))
        #expect(url.path == "/Videos/e1/Trickplay/320/2.jpg")
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(q.contains(.init(name: "MediaSourceId", value: "abc")))
        #expect(q.contains(.init(name: "ApiKey", value: "t")))
    }
}
