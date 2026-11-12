import Foundation
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// The Seerr detail page over `SeerrScreenController`: what the page shows equals what the old views
/// worked out from `JellyfinKit.SeerrDetail`, and the request flow sends the old request bodies.
@MainActor
@Suite(.serialized) struct SeerrScreenControllerTests {

    private nonisolated static let film = Data(
        #"{"overview":"Ein Film.","runtime":112,"genres":[{"name":"Krimi"},{"name":"Drama"}],"voteAverage":7.5}"#.utf8)
    private nonisolated static let series = Data(
        """
        {"overview":"Ein Berater.","voteAverage":8.1,"genres":[{"name":"Krimi"}],
         "seasons":[{"seasonNumber":1,"episodeCount":23},{"seasonNumber":2,"episodeCount":22}],
         "mediaInfo":{"seasons":[{"seasonNumber":1,"status":5}]}}
        """.utf8)

    private func make(_ http: inout ParityHttp?) -> SeerrScreenController {
        let h = ParityHttp { r in
            if r.method == .post { return (201, Data("{}".utf8)) }
            if r.url.contains("/recommendations") { return (200, Data(#"{"results":[]}"#.utf8)) }
            if r.url.contains("/movie/") { return (200, Self.film) }
            if r.url.contains("/tv/") { return (200, Self.series) }
            return (404, Data())
        }
        http = h
        let core = Core(platform: FakePlatform(), secrets: FakeSecrets(), store: MemoryKeyValue(), http: h)
        let model = core.seerrModel(
            connection: SeerrConnection(address: "http://seerr.test:5055", cookie: "connect.sid=abc", headers: []),
            jar: nil)
        return SeerrScreenController(model: model, locale: "de")
    }

    private func hit(_ art: String, _ id: Int64) -> SwiftlyCore.SeerrHit {
        SwiftlyCore.SeerrHit(id: id, art: art, title: "Titel", year: 2008, posterPath: nil, backdropPath: nil, state: .opened)
    }

    /// What `SeerrDetailView.secondaryLine` computed before the core did.
    private func oldLine(_ old: JellyfinKit.SeerrDetail, year: Int, isSeries: Bool) -> String {
        var parts = ["\(year)"]
        if isSeries {
            let n = old.seasons.count
            if n > 0 { parts.append(n == 1 ? "1 Staffel" : "\(n) Staffeln") }
        } else if let m = old.runtime, m > 0 { parts.append("\(m) Min.") }
        if !old.genres.isEmpty { parts.append(old.genres.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    @Test(arguments: [("movie", Int64(42)), ("tv", Int64(7))])
    func thePageShowsWhatTheOldViewsWorkedOut(_ art: String, _ id: Int64) async throws {
        var http: ParityHttp?
        let flow = make(&http)
        await flow.open(hit(art, id))
        let page = try #require(flow.page)
        let old = try #require(Seerr.detail(from: art == "movie" ? Self.film : Self.series))
        #expect(page.secondaryLine == oldLine(old, year: 2008, isSeries: art == "tv"))
        #expect(page.description == old.description)
        #expect(page.rating == old.rating)
        #expect(page.seasons.map { [Int($0.number), $0.requestable ? 1 : 0] }
            == old.seasons.map { [$0.number, $0.state.requestable ? 1 : 0] })
        #expect(page.seasons.allSatisfy { !$0.selected })   // nothing preselected
        #expect(!page.sheetOpen && page.canRequest && !page.disturbed)
    }

    @Test func aMovieAsksTwiceAndSendsNoSeasons() async throws {
        var http: ParityHttp?
        let flow = make(&http)
        await flow.open(hit("movie", 42))
        #expect(flow.page?.buttonText == "Anfragen" && flow.page?.buttonChecked == false)
        await flow.press()
        #expect(flow.page?.buttonChecked == true)
        #expect(http?.requests.contains { $0.method == .post } == false)
        await flow.press()
        let post = try #require(http?.requests.first { $0.method == .post })
        let body = try #require(post.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["mediaId"] as? Int == 42 && body["mediaType"] as? String == "movie" && body["seasons"] == nil)
        #expect(flow.page?.canRequest == false)
    }

    @Test func aSeriesOpensTheSheetAndNeverAsksWithNothingTicked() async throws {
        var http: ParityHttp?
        let flow = make(&http)
        await flow.open(hit("tv", 7))
        await flow.press()
        #expect(flow.page?.sheetOpen == true)
        #expect(flow.page?.sheetButtonEnabled == false)
        await flow.confirmSeasons()
        #expect(http?.requests.contains { $0.method == .post } == false)
        flow.toggleSeason(1)   // season 1 is already there: cannot be ticked
        #expect(flow.page?.seasons.first { $0.number == 1 }?.selected == false)
        flow.toggleSeason(2)
        #expect(flow.page?.sheetButtonEnabled == true)
        await flow.confirmSeasons()
        let post = try #require(http?.requests.first { $0.method == .post })
        let body = try #require(post.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["seasons"] as? [Int] == [2])
        #expect(flow.page?.sheetOpen == false)
    }
}
