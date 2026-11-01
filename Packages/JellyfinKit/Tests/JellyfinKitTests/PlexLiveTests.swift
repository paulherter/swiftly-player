import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import JellyfinKit

#if os(macOS)

// MARK: - Against the Plex Media Server on this Mac (opt in by being there)

/// Where the local server is and who may ask it.
///
/// **The token is read from the server's own settings and goes nowhere else:** not into the
/// log, not into a file, not into an expectation that could print it (the checks below
/// compare yes/no values, never addresses with a token in them).
enum PlexLocal {
    static let url = URL(string: "http://localhost:32400")!

    static let token: String? = {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.plexapp.plexmediaserver.plist")
        guard let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let token = (plist as? [String: Any])?["PlexOnlineToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }()

    /// Whether something answers on the port. Asked once, for two seconds at most.
    static let reachable: Bool = {
        var request = URLRequest(url: url.appendingPathComponent("identity"))
        request.timeoutInterval = 2
        let done = DispatchSemaphore(value: 0)
        let answered = PlexCounter()
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { answered.next() }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 3)
        return answered.count > 0
    }()

    static var available: Bool { token != nil && reachable }
}

/// Runs only when the local server is up and its settings hold a token. Needs the test
/// library of two films and a series (`Testserver/media`); changes nothing it does not
/// put back.
@Suite("Plex: gegen den lokalen Server", .serialized, .enabled(if: PlexLocal.available))
struct PlexLiveTests {

    private let identity = PlexIdentity(clientID: "swiftly-live-test", platform: "macOS",
                                        device: "Mac", deviceName: "Test Mac")

    private func client() throws -> PlexClient {
        PlexClient(baseURL: PlexLocal.url, token: try #require(PlexLocal.token), identity: identity)
    }

    /// A film of the test library with at least a minute of running time.
    private func movie(_ server: any MediaServer) async throws -> Item {
        let views = try await server.userViews()
        let movies = try #require(views.first { $0.collectionType == "movies" })
        let list = try await server.items(parentID: movies.id, limit: 1)
        return try #require(list.items.first)
    }

    @Test("Bibliotheken, Liste, Detail, Plan, Bilder, Suche")
    func tour() async throws {
        let c = try client()
        let info = try await c.info()
        #expect(info.claimed)
        #expect(try await c.tokenWorks())

        let views = try await c.views()
        #expect(views.count >= 2)
        let movies = try #require(views.first { $0.collectionType == "movies" })
        let shows = try #require(views.first { $0.collectionType == "tvshows" })

        let page = try await c.list(section: movies.id, size: 1)
        #expect(page.total >= 1 && page.items.count == 1)
        let movie = try #require(page.items.first)
        let detail = try await c.detail(movie.id)
        #expect(detail.item.mediaSources?.isEmpty == false)

        // The file itself, ranged, with the token in the address.
        let plan = try await c.plan(for: movie.id)
        var req = URLRequest(url: plan.url)
        req.setValue("bytes=0-99", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode
        #expect(status == 206)
        #expect(bytes.count == 100)

        // A scaled picture.
        let image = try #require(c.imageURL(for: movie, kind: .poster, maxHeight: 200))
        let (picture, pictureResponse) = try await URLSession.shared.data(from: image)
        let pictureOK = (pictureResponse as? HTTPURLResponse)?.statusCode == 200 && picture.count > 100
        #expect(pictureOK)

        // Series: seasons, episodes.
        let seriesPage = try await c.list(section: shows.id, size: 1)
        let series = try #require(seriesPage.items.first)
        let seasons = try await c.seasons(seriesID: series.id)
        #expect(!seasons.isEmpty)
        let episodes = try await c.episodes(seriesID: series.id, seasonID: seasons[0].id)
        #expect(!episodes.isEmpty)
        #expect(episodes[0].seriesId == series.id)

        // Search, shelves.
        #expect(try await c.search(String(movie.name.prefix(4))).contains { $0.id == movie.id })
        _ = try await c.continueWatching()
        _ = try await c.onDeck()
        #expect(!(try await c.recentlyAdded()).isEmpty)
        _ = try await c.genres(section: movies.id)
    }

    @Test("Über das Protokoll: Fabrik, Listen über alle Bibliotheken, Serie, Planung")
    func throughProtocol() async throws {
        let token = try #require(PlexLocal.token)
        let session = Session(accessToken: token, userID: "1", userName: "me",
                              serverURL: PlexLocal.url, kind: .plex,
                              plex: PlexSessionDetails(machineIdentifier: "local", serverName: "local",
                                                       accountToken: token, isLocal: true))
        let server = try #require(MediaServerFactory.make(
            kind: .plex, baseURL: PlexLocal.url, deviceID: "swiftly-live-test", deviceName: "Test Mac",
            session: session))
        #expect(server.kind == .plex)

        // All libraries in one list: the totals add up.
        let all = try await server.items(limit: 50)
        let views = try await server.userViews()
        var sum = 0
        for view in views { sum += try await server.items(parentID: view.id, limit: 1).totalRecordCount }
        #expect(all.totalRecordCount == sum && !all.items.isEmpty)
        #expect(!(try await server.genres()).isEmpty)
        #expect(!(try await server.lastAdded(in: nil, fetch: 20, showItem: 10, genres: "Movie,Episode") ?? []).isEmpty)

        let series = try #require(all.items.first { $0.type == "Series" })
        let seasons = try await server.seasons(seriesID: series.id)
        let episodes = try await server.episodes(seriesID: series.id, seasonID: nil)
        #expect(!seasons.isEmpty && episodes.count >= seasons.count)
        #expect(try await server.episodePost(itemID: episodes[0].id, seriesID: series.id)?.id == episodes[1].id)
        _ = try await server.stateInSeriesChecked(series.id)

        let film = try await movie(server)
        let plan = try #require(try await server.playbackPlan(for: film.id))
        #expect(plan.method == .directPlay)
        let hasToken = plan.url.absoluteString.contains("X-Plex-Token")
        #expect(hasToken)
        // The server has no extras for us; asking is harmless.
        _ = try await server.extras(itemID: film.id)
        // Preview pictures: a frame of the film as a picture.
        if let preview = await server.trickplay(itemID: film.id, mediaSourceID: nil) {
            let sheet = await server.trickplaySheet(itemID: film.id, mediaSourceID: nil,
                                                    width: preview.width, sheet: 0)
            #expect((sheet?.count ?? 0) > 100)
        }
    }

    @Test("Zustand: gesehen und Liebling schreiben und zurücknehmen")
    func state() async throws {
        let c = try client()
        let views = try await c.views()
        let moviesView = try #require(views.first { $0.collectionType == "movies" })
        let firstPage = try await c.list(section: moviesView.id, size: 1)
        let movie = try #require(firstPage.items.first)
        defer { Task { try? await c.setFavorite(movie.id, false); try? await c.setWatched(movie.id, false) } }

        try await c.setFavorite(movie.id, true)
        #expect(try await c.item(movie.id).userData?.isFavorite == true)
        try await c.setFavorite(movie.id, false)
        #expect(try await c.item(movie.id).userData?.isFavorite == false)

        try await c.setWatched(movie.id, true)
        #expect(try await c.item(movie.id).userData?.played == true)
        try await c.setWatched(movie.id, false)
        #expect(try await c.item(movie.id).userData?.played == false)
    }

    /// **Measured on the server (1.43), with a 15 minute clip and the 90 s test film:**
    /// the resume point (`viewOffset`) is kept only if the position is **over 60 s** and
    /// **at most 90 %** of the running time. Below a minute nothing is kept; past 90 % the
    /// point is deleted (and the title marked watched, but only if the server saw the
    /// session progress up to there, not after one report from the end). The tests use
    /// the film of 90 s: 80 s is 88.9 %, the only place that fits both rules.
    @Test("Wiedergabe melden und zurücklesen: Haltepunkt, Regeln des Servers, Weiterschauen-Reihe")
    func resumePoint() async throws {
        let c = try client()
        let server: any MediaServer = c
        let film = try await movie(server)
        let plan = try #require(try await server.playbackPlan(for: film.id))
        let duration = try #require(PlexClient.milliseconds(of: plan))
        try #require(duration > 70_000, "the test film is too short for a resume point")
        func ticks(_ ms: Int) -> Int64 { Int64(ms) * 10_000 }
        func stored() async throws -> Int64 {
            try await Task.sleep(for: .milliseconds(700))
            return try await server.item(id: film.id).userData?.playbackPositionTicks ?? 0
        }
        func shelf() async throws -> Bool {
            try await server.resumeItems(limit: 50).contains { $0.id == film.id }
        }
        defer { Task { try? await c.setWatched(film.id, false) } }
        try await c.setWatched(film.id, false)

        // Under a minute: the server keeps nothing.
        try await server.reportStart(itemID: film.id, plan: plan, ticks: 0)
        try await server.reportProgress(itemID: film.id, plan: plan, positionTicks: ticks(30_000), paused: false)
        try await server.reportStopped(itemID: film.id, plan: plan, positionTicks: ticks(30_000))
        #expect(try await stored() == 0)

        // Between a minute and 90 %: kept, to the millisecond.
        let at = min(80_000, duration * 9 / 10 - 1_000)
        try #require(at > 60_000)
        try await server.reportStart(itemID: film.id, plan: plan, ticks: 0)
        try await server.reportProgress(itemID: film.id, plan: plan, positionTicks: ticks(at), paused: false)
        try await server.reportStopped(itemID: film.id, plan: plan, positionTicks: ticks(at))
        #expect(try await stored() == ticks(at))
        #expect(try await shelf())

        // Taken out of "Continue watching": the shelf forgets it, the point stays.
        try await server.pointBackSet(itemID: film.id)
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await !shelf())
        #expect(try await stored() == ticks(at))

        // Past 90 %: the point is gone.
        try await server.reportProgress(itemID: film.id, plan: plan, positionTicks: ticks(at), paused: true)
        try await server.reportStopped(itemID: film.id, plan: plan, positionTicks: ticks(duration - 500))
        #expect(try await stored() == 0)

        // A position made offline arrives like a live one.
        let late = PendingReport(itemID: film.id, account: "plex-live-1", ticks: ticks(at),
                                 moment: Date(timeIntervalSinceNow: 60))
        let done = await server.reportLater([late], log: { _ in })
        #expect(done == [late.id])
        #expect(try await stored() == ticks(at))
        try await c.setWatched(film.id, true)
        try await c.setWatched(film.id, false)
        #expect(try await stored() == 0)
    }
}

#endif
