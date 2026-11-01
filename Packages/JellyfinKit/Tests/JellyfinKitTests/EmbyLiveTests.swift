import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import JellyfinKit

/// **Against a real Emby server**, but only when one answers: the suite looks at
/// `SWIFTLY_EMBY` (default `http://localhost:8096`) and skips itself otherwise, so the
/// normal run stays offline. The account is a throwaway one of the local test server
/// (`SWIFTLY_EMBY_USER` / `SWIFTLY_EMBY_PASSWORD`, default `tester` / `swiftlytest`) with the
/// libraries "Filme" (one title, two versions merged into one entry) and "Serien" (three
/// episodes), a playlist "Testliste" and a collection "Testsammlung".
enum EmbyLive {
    static let address = URL(string: ProcessInfo.processInfo.environment["SWIFTLY_EMBY"]
                             ?? "http://localhost:8096")!
    static let user = ProcessInfo.processInfo.environment["SWIFTLY_EMBY_USER"] ?? "tester"
    static let password = ProcessInfo.processInfo.environment["SWIFTLY_EMBY_PASSWORD"] ?? "swiftlytest"

    /// Whether an Emby server answers at the address (checked once, one second at most).
    static let reachable: Bool = {
        var request = URLRequest(url: address.appendingPathComponent("System/Info/Public"))
        request.timeoutInterval = 1
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var found = false
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data, let text = String(data: data, encoding: .utf8),
               text.contains("\"Version\":\"4.") { found = true }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 2)
        return found
    }()

    static func client(device: String = "emby-test") -> JellyfinClient {
        JellyfinClient(baseURL: address, deviceID: device, deviceName: "TestRunner", kind: .emby)
    }

    static func signedIn(device: String = "emby-test") async throws -> JellyfinClient {
        let c = client(device: device)
        _ = try await c.authenticate(username: user, password: password)
        return c
    }
}

@Suite("Emby live", .serialized, .enabled(if: EmbyLive.reachable))
struct EmbyLiveTests {

    @Test("Emby meldet sich mit Version 4 und ohne Anmeldung")
    func publicInfo() async throws {
        let info = try await EmbyLive.client().publicSystemInfo()
        #expect(info.version?.hasPrefix("4.") == true)
        #expect(info.id?.isEmpty == false)
    }

    @Test("Öffentliche Nutzerliste enthält das Testkonto")
    func publicUsers() async throws {
        let names = try await EmbyLive.client().publicUser().map(\.name)
        #expect(names.contains(EmbyLive.user))
    }

    @Test("Anmeldung gibt eine Emby-Sitzung, falsches Kennwort wird abgelehnt")
    func signIn() async throws {
        let c = EmbyLive.client()
        let session = try await c.authenticate(username: EmbyLive.user, password: EmbyLive.password)
        #expect(session.kind == .emby)
        #expect(!session.accessToken.isEmpty)
        #expect(await c.sessionAppliesStill())
        await #expect(throws: JellyfinError.self) {
            _ = try await EmbyLive.client().authenticate(username: EmbyLive.user, password: "falsch")
        }
    }

    @Test("Abmelden macht den Token ungültig")
    func signOut() async throws {
        let c = try await EmbyLive.signedIn(device: "emby-test-logout")
        let session = try #require(await c.currentSession())
        await c.signOff()
        let old = EmbyLive.client(device: "emby-test-logout")
        await old.setSession(session)
        #expect(await old.sessionAppliesStill() == false)
    }

    @Test("Fabrik baut einen Emby-Client mit eigener Fähigkeitsmenge")
    func factory() throws {
        let server = try #require(MediaServerFactory.make(
            kind: .emby, baseURL: EmbyLive.address, deviceID: "emby-test", deviceName: "TestRunner"))
        #expect(server.kind == .emby)
        #expect(server.capabilities == ServerKind.emby.capabilities)
        #expect(!server.capabilities.contains(.quickConnect))
        #expect(!server.capabilities.contains(.syncPlay))
    }

    @Test("Bibliotheken, Filme in einem Eintrag mit zwei Fassungen")
    func libraries() async throws {
        let c = try await EmbyLive.signedIn()
        let views = try await c.userViews()
        #expect(Set(views.map(\.name)).isSuperset(of: ["Filme", "Serien"]))
        let films = try #require(views.first { $0.name == "Filme" })
        let list = try await c.items(parentID: films.id, recursive: true, includeItemTypes: ["Movie"])
        #expect(list.items.map(\.name) == ["Testfilm"])
        let movie = try await c.item(id: try #require(list.items.first).id)
        #expect(movie.mediaSources?.count == 2)
        #expect(Set(movie.mediaSources?.compactMap(\.name) ?? []) == ["1080p", "720p"])
        #expect(try await c.count(parentID: films.id, types: ["Movie"]) == 1)
    }

    @Test("Serie, Staffeln, Folgen, Nächste Folge")
    func series() async throws {
        let c = try await EmbyLive.signedIn()
        let views = try await c.userViews()
        let shows = try #require(views.first { $0.name == "Serien" })
        let list = try await c.items(parentID: shows.id, recursive: true, includeItemTypes: ["Series"])
        let series = try #require(list.items.first)
        #expect(series.name == "Testserie")
        let seasons = try await c.seasons(seriesID: series.id)
        #expect(seasons.count == 1)
        // Three one-minute episodes and one nine-minute one (see `reports`).
        let episodes = try await c.episodes(seriesID: series.id)
        #expect(episodes.count == 4)
        #expect(try await c.episodes(seriesID: series.id, seasonID: seasons[0].id).count == 4)
        let first = try #require(try await c.firstEpisode(seriesID: series.id))
        #expect(first.indexNumber == 1)
        let after = try await c.episodePost(itemID: first.id, seriesID: series.id)
        #expect(after?.indexNumber == 2)
        // Nobody started the series: Emby's NextUp is empty, the client falls back to episode 1.
        #expect(try await c.nextEpisodeSeries(seriesID: series.id)?.indexNumber == 1)
        _ = try await c.nextUp()
    }

    @Test("Suche, Genres, Ähnliches, Extras, Trailer")
    func lookups() async throws {
        let c = try await EmbyLive.signedIn()
        #expect(try await c.search("Testf").map(\.name).contains("Testfilm"))
        _ = try await c.genres()
        let id = try #require(try await c.search("Testf").first?.id)
        _ = try await c.similar(itemID: id)
        _ = try await c.extras(itemID: id)
        _ = try await c.trailer(toward: id)
        _ = try await c.preTravel(from: id)
        #expect(try await c.identifiers(ids: [id]).count == 1)
        #expect(try await c.newlyJoined().isEmpty == false)
    }

    @Test("Gesehen, Merkliste, Fortsetzen und zurück")
    func userData() async throws {
        let c = try await EmbyLive.signedIn()
        let id = try #require(try await c.search("Testf").first?.id)
        try await c.setWatched(itemID: id, an: true)
        #expect(try await c.item(id: id).isWatched)
        #expect(try await c.userRecord(itemID: id).played == true)
        try await c.setWatched(itemID: id, an: false)
        #expect(try await c.item(id: id).isWatched == false)

        try await c.setWatchlist(itemID: id, an: true)
        #expect(try await c.rememberedIds(types: ["Movie"], sortBy: "SortName", sortOrder: "Ascending")
            .map(\.id).contains(id))
        try await c.setWatchlist(itemID: id, an: false)

        try await c.lastPlaySet(itemID: id, moment: Date())
        try await c.pointBackSet(itemID: id)
    }

    @Test("Wiedergabeliste und Sammlung")
    func listsAndCollections() async throws {
        let c = try await EmbyLive.signedIn()
        let lists = try await c.items(recursive: true, includeItemTypes: ["Playlist"])
        let list = try #require(lists.items.first { $0.name == "Testliste" })
        #expect(try await c.playlistEntries(list.id).map(\.name) == ["Testfilm"])
        let boxes = try await c.items(recursive: true, includeItemTypes: ["BoxSet"])
        let box = try #require(boxes.items.first { $0.name == "Testsammlung" })
        #expect(try await c.collectionMembers(box.id).map(\.name) == ["Testfilm"])
    }

    @Test("Direct Play: Adresse mit api_key spielt, beide Fassungen wählbar")
    func playback() async throws {
        let c = try await EmbyLive.signedIn()
        let id = try #require(try await c.search("Testf").first?.id)
        let movie = try await c.item(id: id)
        let plan = try #require(try await c.playbackPlan(for: id))
        #expect(plan.method == .directPlay)
        #expect(plan.url.query?.contains("api_key=") == true)
        #expect(plan.url.query?.contains("ApiKey=") == false)
        var request = URLRequest(url: plan.url)
        request.setValue("bytes=0-99", forHTTPHeaderField: "Range")
        let (data, answer) = try await URLSession.shared.data(for: request)
        #expect((answer as? HTTPURLResponse)?.statusCode == 206)
        #expect(data.count == 100)

        for source in try #require(movie.mediaSources) {
            let picked = try #require(try await c.playbackPlan(for: id, mediaSourceID: source.id))
            #expect(picked.mediaSourceID == source.id)
            #expect(picked.method == .directPlay)
        }
        // The track facts the player and the version dialog need.
        let first = try #require(plan.source)
        #expect(first.mediaStreams?.filter { $0.type == "Audio" }.count == 2)
        #expect(first.mediaStreams?.filter { $0.type == "Subtitle" }.count == 1)
    }

    /// Emby only keeps a resume position for titles of five minutes or more; shorter ones are
    /// marked as watched when playback ends. So this runs on the long episode (S01E04).
    @Test("Berichte: Start, Fortschritt, Ende; Fortsetzen zeigt die Folge")
    func reports() async throws {
        let c = try await EmbyLive.signedIn()
        let series = try #require(try await c.search("Testserie").first)
        let long = try #require(try await c.episodes(seriesID: series.id).last)
        let id = long.id
        try await c.pointBackSet(itemID: id)
        let plan = try #require(try await c.playbackPlan(for: id))
        try await c.reportStart(itemID: id, plan: plan, ticks: 0)
        try await c.reportProgress(itemID: id, plan: plan, positionTicks: 1_000_000_000, paused: false)
        try await c.reportStopped(itemID: id, plan: plan, positionTicks: 1_000_000_000)
        #expect(try await c.resumeItems().map(\.id).contains(id))
        #expect(try await c.userRecord(itemID: id).playbackPositionTicks == 1_000_000_000)
        #expect(try await c.nextEpisodeSeries(seriesID: series.id)?.id == id)
        try await c.pointBackSet(itemID: id)
        #expect(try await c.resumeItems().map(\.id).contains(id) == false)
        #expect(try await c.nextEpisodeSeries(seriesID: series.id)?.indexNumber == 1)
    }

    @Test("Kapitel und Abschnitte (Emby: keine Abschnitte, kein Trickplay-Blatt)")
    func chaptersAndSegments() async throws {
        let c = try await EmbyLive.signedIn()
        let id = try #require(try await c.search("Testf").first?.id)
        _ = await c.chapter(itemID: id, mediaSourceID: nil)
        #expect(await c.sections(for: id).isEmpty)
        #expect(await c.trickplay(itemID: id, mediaSourceID: nil) == nil)
    }

    @Test("Bild: Poster kommt mit api_key an")
    func poster() async throws {
        let c = try await EmbyLive.signedIn()
        let item = try #require(try await c.search("Testf").first)
        let url = try #require(await c.imageURL(for: item))
        #expect(url.query?.contains("api_key=") == true)
        let (data, answer) = try await URLSession.shared.data(from: url)
        #expect((answer as? HTTPURLResponse)?.statusCode == 200)
        #expect(data.count > 100)

        let session = try #require(await c.currentSession())
        let address = ImageAddress(base: session.serverURL, token: session.accessToken, kind: .emby)
        let built = try #require(address.construct(itemID: item.id, mark: item.imageTags?["Primary"],
                                                   mass: .atMostHigh(300)))
        let (_, again) = try await URLSession.shared.data(from: built)
        #expect((again as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test("Download-Adresse und Recht")
    func download() async throws {
        let c = try await EmbyLive.signedIn()
        let id = try #require(try await c.search("Testf").first?.id)
        let defaults = await c.accountDefaults()
        #expect(defaults != nil)
        #expect(await c.downloadPermission().mayLoad)
        let url = try await c.downloadURL(itemID: id, mediaSourceID: nil)
        var request = URLRequest(url: url)
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        let (_, answer) = try await URLSession.shared.data(for: request)
        #expect((answer as? HTTPURLResponse)?.statusCode == 206)
    }
}
