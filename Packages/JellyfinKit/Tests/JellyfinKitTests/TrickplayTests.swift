import Foundation
import Testing
@testable import JellyfinKit

@Suite("Trickplay")
struct TrickplayTests {

    /// The shape of `TrickplayInfoDto` on a title, per source and width.
    private let answer = """
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

    private var detail: Trickplay {
        Trickplay(width: 320, height: 180, tilesWide: 10, tilesUp: 10,
                  count: 250, interval: 10_000)
    }

    @Test("Einlesen: beide Breiten der Quelle, gewählt wird die passende")
    func inRead() throws {
        let a = try JSONDecoder().decode(TrickplayResponse.self, from: answer)
        #expect(a.sources["abc123"]?.count == 2)
        #expect(a.of(source: "abc123")?.width == 320)
        #expect(a.of(source: "abc123", target: 400)?.width == 640)
        #expect(a.of(source: "abc123", target: 1000)?.width == 640)
        // Without an ID the only source counts.
        #expect(a.of(source: nil)?.width == 320)
    }

    @Test("Ohne Trickplay am Server: nichts, kein Fehler")
    func without() throws {
        let d = #"{ "Id": "e1", "Name": "Folge" }"#.data(using: .utf8)!
        let a = try JSONDecoder().decode(TrickplayResponse.self, from: d)
        #expect(a.of(source: "abc123") == nil)
        #expect(a.of(source: nil) == nil)
    }

    @Test("Unbekannte Quelle bei mehreren: nichts raten")
    func foreignSource() throws {
        let d = """
        { "Trickplay": {
            "a": { "320": { "Width": 320, "Height": 180, "TileWidth": 10, "TileHeight": 10,
                            "ThumbnailCount": 5, "Interval": 1000 } },
            "b": { "320": { "Width": 320, "Height": 180, "TileWidth": 10, "TileHeight": 10,
                            "ThumbnailCount": 5, "Interval": 1000 } } } }
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(TrickplayResponse.self, from: d)
        #expect(a.of(source: "c") == nil)
        #expect(a.of(source: "b") != nil)
    }

    @Test("Kachel: Blatt und Platz im Raster")
    func tile() {
        // 0 s → first image, first sheet, top left.
        #expect(detail.tile(seconds: 0) == .init(sheet: 0, x: 0, y: 0, width: 320, height: 180))
        // 125 s → n = 12 → row 1, column 2.
        #expect(detail.tile(seconds: 125) == .init(sheet: 0, x: 640, y: 180, width: 320, height: 180))
        // 1000 s → n = 100 → second sheet, top left.
        #expect(detail.tile(seconds: 1000) == .init(sheet: 1, x: 0, y: 0, width: 320, height: 180))
        // 1999 s → n = 199 → second sheet, bottom right.
        #expect(detail.tile(seconds: 1999) == .init(sheet: 1, x: 2880, y: 1620, width: 320, height: 180))
    }

    @Test("Über das Ende hinaus bleibt das letzte Bild, davor das erste")
    func edges() {
        // n is capped at 249 → sheet 2, slot 49.
        #expect(detail.tile(seconds: 99_999) == .init(sheet: 2, x: 2880, y: 720, width: 320, height: 180))
        #expect(detail.tile(seconds: -5)?.sheet == 0)
        #expect(detail.tile(seconds: .nan) == nil)
    }

    @Test("Adresse: Breite, Blatt, Quelle und Ausweis")
    func address() async throws {
        let client = JellyfinClient(
            baseURL: URL(string: "https://jf.example")!, deviceID: "d", deviceName: "n",
            session: Session(accessToken: "t", userID: "u", userName: "n",
                             serverURL: URL(string: "https://jf.example")!))
        let url = try #require(await client.trickplayURL(itemID: "e1", mediaSourceID: "abc",
                                                         width: 320, sheet: 2))
        #expect(url.path == "/Videos/e1/Trickplay/320/2.jpg")
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(q.contains(.init(name: "MediaSourceId", value: "abc")))
        #expect(q.contains(.init(name: "ApiKey", value: "t")))
    }
}
