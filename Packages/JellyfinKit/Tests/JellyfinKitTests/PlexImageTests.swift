import Foundation
import Testing
@testable import JellyfinKit

/// **Plex names a picture by the path the server wrote down**, and scales it at
/// `/photo/:/transcode`. These tests pin the shape that answered `200` on a live server:
/// both sides given, the token last, never part of the cache key.
@Suite("Plex-Bilder")
struct PlexImageTests {
    private let base = URL(string: "https://plex.example.de:32400")!
    private var address: ImageAddress { ImageAddress(base: base, token: "TOK", kind: .plex) }

    private func query(_ url: URL?) -> [String: String] {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    @Test("Ein Plakat wird ueber den Skalierer mit beiden Seiten und dem Plex-Token geholt")
    func poster() throws {
        let url = try #require(address.construct(itemID: "5", art: .poster,
                                                 mark: "/library/metadata/5/thumb/1700",
                                                 mass: .atMostHigh(450)))
        #expect(url.path == "/photo/:/transcode")
        let q = query(url)
        #expect(q["url"] == "/library/metadata/5/thumb/1700")
        #expect(q["height"] == "450")
        #expect(q["width"] != nil)
        #expect(q["upscale"] == "0")
        #expect(q["X-Plex-Token"] == "TOK")
    }

    @Test("Ein Hintergrund begrenzt die Breite")
    func background() throws {
        let q = query(address.construct(itemID: "5", art: .background, mark: "/library/metadata/5/art/9",
                                        mass: .atMostWide(1280)))
        #expect(q["width"] == "1280")
        #expect(q["height"] != nil)
    }

    @Test("Ohne Pfad greift das aktuelle Bild des Eintrags, ein Logo gibt es dann nicht")
    func fallback() {
        let thumb = query(address.construct(itemID: "5", art: .poster, mass: .atMostHigh(300)))
        #expect(thumb["url"] == "/library/metadata/5/thumb")
        let art = query(address.construct(itemID: "5", art: .background, mass: .atMostWide(300)))
        #expect(art["url"] == "/library/metadata/5/art")
        #expect(address.construct(itemID: "5", art: .logo, mass: .atMostWide(300)) == nil)
    }

    @Test("Eine volle Adresse (Darsteller) bleibt unveraendert")
    func absolute() {
        let full = "https://metadata-static.plex.tv/a.jpg"
        #expect(address.construct(itemID: "5", mark: full, mass: .atMostHigh(300))?.absoluteString == full)
    }

    @Test("Ein Profilbild gibt es nicht, der Token faellt aus dem Bildschluessel")
    func userAndKey() throws {
        #expect(address.user("x", border: 64) == nil)
        let a = try #require(address.construct(itemID: "5", mark: "/library/metadata/5/thumb/1", mass: .atMostHigh(300)))
        let b = try #require(ImageAddress(base: base, token: "OTHER", kind: .plex)
            .construct(itemID: "5", mark: "/library/metadata/5/thumb/1", mass: .atMostHigh(300)))
        #expect(!ImageKey.of(a).contains("TOK"))
        #expect(ImageKey.of(a) == ImageKey.of(b))
        #expect(!a.withoutSecret.contains("TOK"))
    }

    // MARK: - Continue watching tile: always landscape

    private func mapped(_ body: String) throws -> Item {
        let json = #"{"MediaContainer":{"size":1,"Metadata":[{"# + body + #"}]}}"#
        let box = try JSONDecoder().decode(PlexEnvelope<PlexListing>.self, from: Data(json.utf8))
        return PlexMapper().item(try #require(box.container.metadata.first))
    }

    private func pick(_ item: Item) throws -> (url: URL, source: String) {
        try #require(ImageSelection.landscape(item, addresses: address, width: 640))
    }

    @Test("Ein Querbild fragt den Skalierer nach einem 16:9-Kasten, der gefuellt wird")
    func landscapeBox() throws {
        let film = try mapped(#""ratingKey":"7","type":"movie","title":"F","thumb":"/library/metadata/7/thumb/1","art":"/library/metadata/7/art/2""#)
        let choice = try pick(film)
        let q = query(choice.url)
        #expect(q["url"] == "/library/metadata/7/art/2")
        #expect(q["width"] == "640")
        #expect(q["height"] == "360")
        #expect(q["minSize"] == "1")
    }

    @Test("Ein Film ohne Hintergrund zeigt sein Plakat, zugeschnitten und nie hochkant")
    func filmWithoutBackground() throws {
        let film = try mapped(#""ratingKey":"7","type":"movie","title":"F","thumb":"/library/metadata/7/thumb/1""#)
        let choice = try pick(film)
        let q = query(choice.url)
        #expect(q["url"] == "/library/metadata/7/thumb/1")
        #expect(q["height"] == "360" && q["width"] == "640" && q["minSize"] == "1")
    }

    @Test("Eine Folge ohne Standbild und ohne Hintergrund nimmt das Serienplakat, zugeschnitten")
    func episodeWithoutLandscape() throws {
        let folge = try mapped(#""ratingKey":"20","type":"episode","title":"E","grandparentRatingKey":"3","grandparentTitle":"S","grandparentThumb":"/library/metadata/3/thumb/5""#)
        let q = query(try pick(folge).url)
        #expect(q["url"] == "/library/metadata/3/thumb/5")
        #expect(q["height"] == "360" && q["minSize"] == "1")
    }

    @Test("Ganz ohne Pfade fragt es den Hintergrund der Serie, zugeschnitten")
    func nothingKnown() throws {
        let folge = try mapped(#""ratingKey":"20","type":"episode","title":"E","grandparentRatingKey":"3""#)
        let q = query(try pick(folge).url)
        #expect(q["url"] == "/library/metadata/3/art")
        #expect(q["height"] == "360" && q["minSize"] == "1")
    }

    @Test("Das Serienbild kommt vor dem Folgenstandbild, beide im 16:9-Kasten")
    func seriesArtFirst() throws {
        let folge = try mapped(#""ratingKey":"20","type":"episode","title":"E","thumb":"/library/metadata/20/thumb/1","grandparentRatingKey":"3","grandparentArt":"/library/metadata/3/art/9","grandparentThumb":"/library/metadata/3/thumb/5""#)
        let q = query(try pick(folge).url)
        #expect(q["url"] == "/library/metadata/3/art/9")
        #expect(q["minSize"] == "1")
    }

    @Test("Jellyfin bleibt unveraendert: Breite begrenzt, kein Kasten")
    func jellyfinUntouched() throws {
        let other = ImageAddress(base: base, token: "T", kind: .jellyfin)
        let item = Item(id: "1", name: "x", type: "Movie", productionYear: nil, overview: nil,
                        runTimeTicks: nil, seriesName: nil, indexNumber: nil, parentIndexNumber: nil,
                        seriesId: nil, seasonId: nil, genres: nil, officialRating: nil,
                        communityRating: nil, childCount: nil, backdropImageTags: ["b"],
                        seriesPrimaryImageTag: nil, people: nil, studios: nil, taglines: nil,
                        criticRating: nil, imageTags: nil, userData: nil, mediaSources: nil)
        let url = try #require(ImageSelection.landscape(item, addresses: other, width: 640)?.url)
        #expect(url.absoluteString.contains("maxWidth=640"))
        #expect(!url.absoluteString.contains("minSize"))
    }
}
