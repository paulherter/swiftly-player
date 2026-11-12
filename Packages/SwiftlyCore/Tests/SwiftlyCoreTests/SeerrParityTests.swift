import Foundation
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// Seerr: the core's `SeerrModel` against the old Swift parsers and rules (`JellyfinKit.Seerr`) on the
/// literal JSON of `SeerrTests`: equal tiles, equal details, equal request body, equal addresses.
@Suite(.serialized) struct SeerrParityTests {

    private static let search = Data("""
        {"page":1,"totalResults":4,"results":[
          {"id":1,"mediaType":"movie","title":"Lighthouse Live","releaseDate":"2014-03-01",
           "posterPath":"/abc.jpg","backdropPath":"/quer.jpg"},
          {"id":2,"mediaType":"tv","name":"The Lighthouse","firstAirDate":"2008-09-23",
           "posterPath":"/def.jpg","mediaInfo":{"status":5}},
          {"id":3,"mediaType":"tv","name":"The Lighthouse (UK)","firstAirDate":"2011-01-01",
           "mediaInfo":{"status":2}},
          {"id":4,"mediaType":"person","name":"Simon Baker","profilePath":"/ghi.jpg"}
        ]}
        """.utf8)

    private static let film = Data(
        #"""
        {"overview": "Ein Film.","runtime": 112,
         "genres":[{"name":"Krimi"},{"name":"Drama"},{"name":"Mystery"}],
         "mediaInfo":{"status":4},
         "credits": {"cast": [
           {"id": 1, "name": "Simon Baker", "character": "Patrick Jane","profilePath": "/a.jpg"},
           {"id": 2, "name": "Robin Tunney", "character": "", "profilePath": null},
           {"id": 3, "character": "Namenlos"}],
          "crew": [{"id": 9, "name": "Bruno Heller", "job": "Creator"}]}}
        """#.utf8)

    private static let series = Data(
        """
        {"overview":"Ein Berater der Polizei.","episodeRunTime":[45],"voteAverage":8.1,
         "genres":[{"name":"Krimi"},{"name":"Drama"},{"name":"Mystery"}],
         "seasons":[{"seasonNumber":0,"episodeCount":3},{"seasonNumber":1,"episodeCount":23},
                    {"seasonNumber":2,"episodeCount":22}],
         "mediaInfo":{"seasons":[{"seasonNumber":1,"status":5}]}}
        """.utf8)

    private static let recommendations = Data(
        #"""
        {"page": 1,"totalPages": 3,"results": [
          {"id": 42, "title": "Der Nachbar", "releaseDate": "2011-02-03","posterPath": "/p.jpg", "backdropPath": "/b.jpg"},
          {"id": 43, "title": "Schon da", "mediaInfo": {"status": 5}}]}
        """#.utf8)

    private static let credits = Data(
        """
        {"cast":[{"id":603,"mediaType":"movie","title":"Matrix","releaseDate":"1999-03-30","posterPath":"/m.jpg"},
                 {"id":7,"mediaType":"tv","name":"Serie","firstAirDate":"2008-09-23"}]}
        """.utf8)

    private func model(status: UInt16 = 200, http: inout ParityHttp?) -> SeerrModel {
        let h = ParityHttp { r in
            let url = r.url
            if r.method == .post { return (201, Data("{}".utf8)) }
            if url.contains("/auth/me") { return (status, Data("{}".utf8)) }
            if url.contains("/search") { return (200, Self.search) }
            if url.contains("/recommendations") { return (200, Self.recommendations) }
            if url.contains("/movie/") { return (200, Self.film) }
            if url.contains("/tv/") { return (200, Self.series) }
            if url.contains("/combined_credits") { return (200, Self.credits) }
            return (404, Data())
        }
        http = h
        let core = Core(platform: FakePlatform(), secrets: FakeSecrets(), store: MemoryKeyValue(), http: h)
        return core.seerrModel(
            connection: SeerrConnection(address: "http://seerr.test:5055", cookie: "connect.sid=abc", headers: []),
            jar: nil)
    }

    private func same(_ core: SwiftlyCore.SeerrHit, _ old: JellyfinKit.SeerrHit) {
        #expect(Int(core.id) == old.id)
        #expect(core.art == old.art)
        #expect(core.title == old.title)
        #expect(core.year.map(Int.init) == old.year)
        #expect(core.posterPath == old.posterPath)
        #expect(core.backdropPath == old.backdropPath)
        #expect(Int(stateNumber(core.state)) == old.state.rawValue)
    }

    private func stateNumber(_ s: SwiftlyCore.SeerrState) -> Int {
        switch s {
        case .opened: 1
        case .waitsSharing: 2
        case .loads: 3
        case .partWayPresent: 4
        case .present: 5
        case .deleted: 6
        }
    }

    @Test func searchGivesTheOldTiles() async throws {
        var http: ParityHttp?
        let hits = try await model(http: &http).search(term: "Lighthouse")
        let old = Seerr.hit(fromSearch: Self.search)
        #expect(hits.count == old.count && hits.count == 3)
        for (c, o) in zip(hits, old) { same(c, o) }
        let sent = try #require(http?.requests.first)
        #expect(sent.url == "http://seerr.test:5055/api/v1/search?query=Lighthouse")
        #expect(sent.headers.contains { $0.name.lowercased() == "cookie" && $0.value == "connect.sid=abc" })
    }

    @Test(arguments: [("movie", 42), ("tv", 7)]) func detailGivesTheOldPage(_ art: String, _ id: Int) async throws {
        var http: ParityHttp?
        let detail = try #require(try await model(http: &http).detail(art: art, id: Int64(id)))
        let main = art == "movie" ? Self.film : Self.series
        let old = try #require(Seerr.detail(from: main))
            .with(similarOne: Seerr.suggestions(from: Self.recommendations, art: art))
        #expect(detail.description == old.description)
        #expect(detail.genres == old.genres)
        #expect(detail.runtime.map(Int.init) == old.runtime)
        #expect(detail.rating == old.rating)
        #expect(detail.seasons.map { [Int($0.number), Int($0.episodes), stateNumber($0.state)] }
            == old.seasons.map { [$0.number, $0.episodes, $0.state.rawValue] })
        #expect(detail.cast.map { "\($0.id)|\($0.name)|\($0.role ?? "-")|\($0.imagePath ?? "-")" }
            == old.cast.map { "\($0.id)|\($0.name)|\($0.role ?? "-")|\($0.imagePath ?? "-")" })
        #expect(detail.state.map(stateNumber) == old.state?.rawValue)
        #expect(detail.similarOne.count == old.similarOne.count && detail.similarOne.count == 2)
        for (c, o) in zip(detail.similarOne, old.similarOne) { same(c, o) }
        let urls = Set((http?.requests ?? []).map(\.url))
        #expect(urls == ["http://seerr.test:5055/api/v1/\(art)/\(id)", "http://seerr.test:5055/api/v1/\(art)/\(id)/recommendations"])
    }

    @Test func aFilmographyGivesTheOldTiles() async throws {
        var http: ParityHttp?
        let hits = try await model(http: &http).filmography(personTmdb: 5)
        let old = Seerr.hit(fromFilmography: Self.credits)
        #expect(hits.count == old.count && !hits.isEmpty)
        for (c, o) in zip(hits, old) { same(c, o) }
    }

    @Test(arguments: [("movie", 42, nil), ("tv", 7, nil), ("tv", 7, []), ("tv", 7, [1, 3])] as [(String, Int, [Int]?)])
    func aRequestSendsTheOldBody(_ art: String, _ id: Int, _ seasons: [Int]?) async throws {
        var http: ParityHttp?
        try await model(http: &http).askFor(art: art, id: Int64(id), seasons: seasons?.map(Int64.init))
        let post = try #require(http?.requests.first { $0.method == .post })
        #expect(post.url == "http://seerr.test:5055/api/v1/request")
        let body = try #require(post.body); let sent = try #require(try JSONSerialization.jsonObject(with: body) as? NSDictionary)
        #expect(sent == Seerr.requestBody(art: art, id: id, seasons: seasons) as NSDictionary)
    }

    @Test(arguments: [(200, SwiftlyCore.SeerrSessionState.valid), (401, .invalid), (403, .invalid), (502, .unreachable)] as [(UInt16, SwiftlyCore.SeerrSessionState)])
    func theSessionCheckReadsTheStatusLikeTheOldOne(_ status: UInt16, _ state: SwiftlyCore.SeerrSessionState) async throws {
        var http: ParityHttp?
        #expect(try await model(status: status, http: &http).applies() == state)
        let old = JellyfinKit.SeerrSessionState(status: Int(status))
        #expect("\(old)" == "\(state)")
    }

    @Test func theAddressRuleIsTheOldOne() async throws {
        // The core tries these addresses in turn; the typed text is cleaned like `Seerr.addresses`.
        #expect(Seerr.addresses(from: "   ").isEmpty)
        #expect(Seerr.addresses(from: "192.168.1.5:5055").first?.absoluteString == "http://192.168.1.5:5055")
        #expect(Seerr.addresses(from: "seerr.example.org").first?.absoluteString == "https://seerr.example.org")
    }
}
