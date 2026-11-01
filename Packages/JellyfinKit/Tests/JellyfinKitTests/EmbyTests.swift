import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

/// Emby as a server kind, **offline**: the path table, the token spelling, the capability set
/// and the decoding of sanitized real responses (`EmbyFixtures`). The same against a running
/// server is `EmbyLiveTests`.
@Suite("Emby", .serialized)
struct EmbyTests {

    /// Answers every request with a canned body and remembers the addresses asked for.
    final class Replay: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var asked: [URL] = []
        nonisolated(unsafe) static var answers: [String: String] = [:]

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            let url = request.url!
            Self.asked.append(url)
            let body = Self.answers.first { url.path.hasSuffix($0.key) }?.value ?? "{}"
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { try TimestampFormat.read(from: $0) }
        return d
    }()

    private let base = URL(string: "https://emby.example.de")!
    private let session = Session(accessToken: "TOKEN", userID: "u1", userName: "tester",
                                  serverURL: URL(string: "https://emby.example.de")!, kind: .emby)

    private func client(kind: ServerKind) -> JellyfinClient {
        Replay.asked = []
        Replay.answers = [:]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Replay.self]
        return JellyfinClient(baseURL: base, deviceID: "dev", deviceName: "Test",
                              session: Session(accessToken: "TOKEN", userID: "u1", userName: "tester",
                                               serverURL: base, kind: kind),
                              urlSession: URLSession(configuration: config), kind: kind)
    }

    // MARK: Paths

    @Test("Pfadtabelle: Jellyfin-Pfade werden zu Emby-Pfaden mit Nutzer")
    func pathTable() {
        let table: [(String, String)] = [
            ("UserViews", "Users/u1/Views"),
            ("Items", "Users/u1/Items"),
            ("Items/42", "Users/u1/Items/42"),
            ("Items/42/SpecialFeatures", "Users/u1/Items/42/SpecialFeatures"),
            ("Items/42/LocalTrailers", "Users/u1/Items/42/LocalTrailers"),
            ("UserItems/Resume", "Users/u1/Items/Resume"),
            ("UserItems/42/UserData", "Users/u1/Items/42/UserData"),
            ("UserFavoriteItems/42", "Users/u1/FavoriteItems/42"),
            ("UserPlayedItems/42", "Users/u1/PlayedItems/42"),
            // Paths Emby answers like Jellyfin stay as they are.
            ("Shows/NextUp", "Shows/NextUp"),
            ("Shows/7/Episodes", "Shows/7/Episodes"),
            ("Items/42/PlaybackInfo", "Items/42/PlaybackInfo"),
            ("Items/42/Similar", "Items/42/Similar"),
            ("Sessions/Playing", "Sessions/Playing"),
            ("Users/AuthenticateByName", "Users/AuthenticateByName"),
            ("System/Info/Public", "System/Info/Public"),
        ]
        for (jellyfin, emby) in table {
            #expect(EmbyPaths.rewrite(jellyfin, userID: "u1") == emby, "\(jellyfin)")
        }
        // Without a user there is nothing to build the path from.
        #expect(EmbyPaths.rewrite("UserViews", userID: nil) == "UserViews")
        #expect(EmbyPaths.rewrite("UserViews", userID: "") == "UserViews")
    }

    @Test("Emby fragt Bibliotheken und Eintrag unter dem Nutzerpfad, mit api_key")
    func embyRequests() async throws {
        let c = client(kind: .emby)
        Replay.answers = ["Views": EmbyFixtures.views, "Items/8": EmbyFixtures.movie]
        let views = try await c.userViews()
        #expect(Replay.asked.last?.path == "/Users/u1/Views")
        #expect(views.map(\.name).contains("Filme"))
        let movie = try await c.item(id: "8")
        #expect(Replay.asked.last?.path == "/Users/u1/Items/8")
        #expect(movie.name == "Testfilm")
        let query = await c.imageURL(for: movie)?.query
        #expect(query?.contains("api_key=TOKEN") == true)
        #expect(query?.contains("ApiKey=") == false)
    }

    @Test("Jellyfin bleibt wie es war: flache Pfade, ApiKey")
    func jellyfinUnchanged() async throws {
        let c = client(kind: .jellyfin)
        Replay.answers = ["UserViews": EmbyFixtures.views, "Items/8": EmbyFixtures.movie]
        _ = try await c.userViews()
        #expect(Replay.asked.last?.path == "/UserViews")
        let movie = try await c.item(id: "8")
        #expect(Replay.asked.last?.path == "/Items/8")
        #expect(await c.imageURL(for: movie)?.query?.contains("ApiKey=TOKEN") == true)
        #expect(c.serverKind == .jellyfin)
        // A kind other than Emby never turns a client into an Emby one by accident.
        let plex = JellyfinClient(baseURL: base, deviceID: "d", deviceName: "n", kind: .plex)
        #expect(plex.serverKind == .jellyfin)
    }

    @Test("Wiedergabe-Adresse und Bild-Adresse benutzen die Emby-Schreibweise des Tokens")
    func tokenSpelling() {
        #expect(EmbyPaths.tokenName(for: .emby) == "api_key")
        #expect(EmbyPaths.tokenName(for: .jellyfin) == "ApiKey")
        let emby = ImageAddress(base: base, token: "T", kind: .emby)
        let jelly = ImageAddress(base: base, token: "T")
        let a = emby.construct(itemID: "1", mark: "x", mass: .atMostHigh(300))
        let b = jelly.construct(itemID: "1", mark: "x", mass: .atMostHigh(300))
        #expect(a?.query?.contains("api_key=T") == true)
        #expect(b?.query?.contains("ApiKey=T") == true)
        #expect(b?.query?.contains("api_key") == false)
    }

    // MARK: Capabilities and factory

    @Test("Emby hat eine eigene Fähigkeitsmenge ohne die unbelegten Funktionen")
    func capabilities() {
        let emby = ServerKind.emby.capabilities
        for open: ServerCapability in [.quickConnect, .syncPlay, .settingsSync, .remoteControl,
                                       .playOnOtherDevice, .trickplay] {
            #expect(!emby.contains(open), "\(open)")
        }
        for measured: ServerCapability in [.publicUsers, .favorites, .markWatched, .playlists,
                                           .collections, .genres, .chapters, .downloads] {
            #expect(emby.contains(measured), "\(measured)")
        }
        // Jellyfin keeps everything it had.
        #expect(ServerKind.jellyfin.capabilities.contains(.quickConnect))
        #expect(ServerKind.jellyfin.capabilities.contains(.trickplay))
    }

    @Test("Fabrik liefert für Emby einen Client, für Jellyfin weiterhin einen")
    func factory() throws {
        let emby = try #require(MediaServerFactory.make(kind: .emby, baseURL: base,
                                                        deviceID: "d", deviceName: "n"))
        #expect(emby.kind == .emby)
        #expect(emby.capabilities == ServerKind.emby.capabilities)
        let jelly = try #require(MediaServerFactory.make(kind: .jellyfin, baseURL: base,
                                                         deviceID: "d", deviceName: "n"))
        #expect(jelly.kind == .jellyfin)
    }

    @Test("Eine Emby-Sitzung trägt ihre Art und einen eigenen Kontoschlüssel")
    func sessionKind() throws {
        #expect(session.kind == .emby)
        #expect(session.accountKey.hasPrefix("emby:"))
        let data = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(Session.self, from: data).kind == .emby)
        let old = Session(accessToken: "t", userID: "u", userName: "n", serverURL: base)
        #expect(!String(decoding: try JSONEncoder().encode(old), as: UTF8.self).contains("kind"))
    }

    // MARK: Real responses

    @Test("Anmeldeantwort von Emby lässt sich lesen")
    func decodeAuthentication() throws {
        let result = try JSONDecoder().decode(AuthenticationResult.self, from: Data(EmbyFixtures.authenticate.utf8))
        #expect(result.accessToken == "TOKEN")
        #expect(result.user.name == "tester")
    }

    @Test("Der Film ist ein Eintrag mit zwei Fassungen, Spuren und Direktadresse")
    func decodeMovie() throws {
        let movie = try Self.decoder.decode(Item.self, from: Data(EmbyFixtures.movie.utf8))
        #expect(movie.name == "Testfilm")
        let sources = try #require(movie.mediaSources)
        #expect(sources.count == 2)
        #expect(Set(sources.compactMap(\.name)) == ["1080p", "720p"])
        let first = try #require(sources.first)
        #expect(first.mediaStreams?.filter { $0.type == "Audio" }.count == 2)
        #expect(first.mediaStreams?.filter { $0.type == "Subtitle" }.count == 1)
    }

    @Test("PlaybackInfo von Emby: Direct Play ohne Umkodier-Adresse")
    func decodePlaybackInfo() throws {
        let info = try Self.decoder.decode(PlaybackInfoResponse.self,
                                                     from: Data(EmbyFixtures.playbackInfo.utf8))
        #expect(info.mediaSources.count == 2)
        let first = try #require(info.mediaSources.first)
        #expect(first.supportsDirectPlay == true)
        #expect(first.transcodingUrl == nil)
    }

    @Test("Aus der Emby-Antwort wird ein Direct-Play-Plan mit api_key")
    func playbackPlanFromInfo() async throws {
        let c = client(kind: .emby)
        Replay.answers = ["Items/8/PlaybackInfo": EmbyFixtures.playbackInfo]
        let plan = try #require(try await c.playbackPlan(for: "8"))
        #expect(plan.method == .directPlay)
        #expect(plan.url.absoluteString.hasPrefix("https://emby.example.de/Videos/8/stream"))
        #expect(plan.url.query?.contains("api_key=") == true)
    }

    @Test("Emby: keine Abschnitte, kein Trickplay, ohne Anfrage")
    func noSegments() async {
        let c = client(kind: .emby)
        #expect(await c.sections(for: "8").isEmpty)
        #expect(await c.trickplay(itemID: "8", mediaSourceID: nil) == nil)
        #expect(Replay.asked.isEmpty)
    }
}
