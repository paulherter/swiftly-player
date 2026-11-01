import Foundation
import Testing
@testable import JellyfinKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - A server that is not there

/// Answers requests from a table keyed by host, so tests running side by side do not
/// see each other's traffic.
final class PlexStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, String)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var seen: [String: [URLRequest]] = [:]

    static func register(_ handler: @escaping Handler) -> (host: String, session: URLSession) {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        lock.lock(); handlers[host] = handler; lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlexStub.self]
        return (host, URLSession(configuration: config))
    }
    static func requests(_ host: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return seen[host] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.lock.lock()
        Self.seen[host, default: []].append(request)
        let handler = Self.handlers[host]
        Self.lock.unlock()
        let (status, body) = handler?(request) ?? (404, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class PlexCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    @discardableResult func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private let testIdentity = PlexIdentity(clientID: "cid", platform: "macOS", device: "Mac",
                                        deviceName: "Test Mac")

private func decodeMetadata(_ json: String) throws -> PlexMetadata {
    let box = try JSONDecoder().decode(PlexEnvelope<PlexListing>.self, from: Data(json.utf8))
    return try #require(box.container.metadata.first)
}

// MARK: - Wire and mapping

@Suite("Plex: Antworten lesen und abbilden")
struct PlexMappingTests {

    @Test("Ein Film wird zum Item: Schlüssel, Zeiten, Bewertung, Kennungen")
    func movie() throws {
        let item = PlexMapper().item(try decodeMetadata(PlexFixtures.movie))
        #expect(item.id == "1")
        #expect(item.type == "Movie")
        #expect(item.productionYear == 2020)           // arrived as text
        #expect(item.officialRating == "12")           // "de/" dropped
        #expect(item.communityRating == 7.5)
        #expect(item.criticRating == 80)
        #expect(item.runTimeTicks == 900_230_000)
        #expect(item.userData?.playbackPositionTicks == 450_110_000)
        #expect(item.userData?.played == false)
        #expect(item.userData?.isFavorite == true)
        let percent = try #require(item.userData?.playedPercentage)
        #expect(abs(percent - 50) < 0.1)
        #expect(item.providerIds == ["Imdb": "tt0133093", "Tmdb": "603", "Tvdb": "78804"])
        #expect(item.premiereDate == "2020-01-25T00:00:00Z")
        #expect(item.imageTags?["Primary"] == "/library/metadata/1/thumb/17")
        #expect(item.imageTags?["Logo"] == "/library/metadata/1/clearLogo/17")
        #expect(item.backdropImageTags == ["/library/metadata/1/art/17"])
        #expect(item.genres == ["Action"])
        #expect(item.productionLocations == ["USA"])
        #expect(item.studios?.first?.name == "Bonobostudio")
        #expect(item.people?.map(\.type) == ["Actor", "Director", "Writer"])
        #expect(item.actors.first?.role == "Neo")
        #expect(item.direction == ["Bob Director"])
    }

    @Test("Versionen, Spuren: Stream-ID als Index, äußere Untertitel mit Pfad, Dolby Vision")
    func sources() throws {
        let item = PlexMapper().item(try decodeMetadata(PlexFixtures.movie))
        let sources = try #require(item.mediaSources)
        #expect(sources.map(\.id) == ["1", "2"])
        #expect(sources.allSatisfy { $0.deliveryMethod == .directPlay })
        let first = sources[0]
        #expect(first.name == "Testfilm.mkv")
        #expect(first.defaultAudioStreamIndex == 2)
        #expect(first.defaultSubtitleStreamIndex == 5)
        let streams = try #require(first.mediaStreams)
        #expect(streams.map(\.index) == [1, 2, 3, 4, 5])
        #expect(streams.map(\.type) == ["Video", "Audio", "Audio", "Subtitle", "Subtitle"])
        #expect(streams[0].codec == "hevc")
        #expect(streams[0].videoRangeType == .dolbyVisionHDR10)
        #expect(streams[0].dvProfile == 8)
        #expect(streams[1].language == "eng")
        #expect(streams[1].channels == 6)
        #expect(streams[3].isExternal == true)
        #expect(streams[3].isForced == true)               // arrived as "1"
        #expect(streams[3].deliveryUrl == "/library/streams/4")
        #expect(streams[4].isExternal == false)            // inside the container: no key
        #expect(streams[4].deliveryUrl == nil)
    }

    @Test("Eine Folge kennt Serie, Staffel und ist gesehen")
    func episode() throws {
        let item = PlexMapper().item(try decodeMetadata(PlexFixtures.episode))
        #expect(item.type == "Episode")
        #expect(item.seriesId == "3")
        #expect(item.seasonId == "4")
        #expect(item.seriesName == "Test Show")
        #expect(item.indexNumber == 2)
        #expect(item.parentIndexNumber == 1)
        #expect(item.userData?.played == true)
        #expect(item.parentBackdropItemId == "3")
        #expect(item.parentBackdropImageTags == ["/library/metadata/3/art/1"])
        #expect(item.seriesPrimaryImageTag == "/library/metadata/3/thumb/1")
    }

    @Test("Eine Serie zählt ungesehene Folgen und Staffeln")
    func show() throws {
        let item = PlexMapper().item(try decodeMetadata(PlexFixtures.show))
        #expect(item.type == "Series")
        #expect(item.childCount == 2)
        #expect(item.userData?.unplayedItemCount == 6)
        #expect(item.userData?.played == false)
    }

    @Test("Ein kaputter Eintrag reißt die Liste nicht mit")
    func lenientList() throws {
        let box = try JSONDecoder().decode(PlexEnvelope<PlexListing>.self,
                                           from: Data(PlexFixtures.page.utf8))
        #expect(box.container.metadata.map(\.ratingKey) == ["10", "11"])
        #expect(box.container.totalSize == 7)
        #expect(box.container.metadata[1].year == 2002)
    }

    @Test("Marker werden Sprungknöpfe, Kapitel bekommen Namen")
    func markersAndChapters() throws {
        let m = try decodeMetadata(PlexFixtures.movie)
        let mapper = PlexMapper()
        let segments = mapper.segments(m.markers, duration: m.duration)
        #expect(segments.map(\.art) == [.introSegment, .credits])      // "sponsor" dropped
        #expect(segments[0].from == 1 && segments[0].until == 61)
        #expect(abs(segments[1].until - 90.023) < 0.001)               // cut to the runtime
        let chapters = mapper.chapters(m.chapters)
        #expect(chapters.count == 2)
        #expect(chapters[0].name == "Start")
        #expect(chapters[1].from == 30)
        #expect(chapters[1].name.contains("2"))                        // "Kapitel 2"
    }

    @Test("Typen: Plex nach Jellyfin und zurück zur Zahl für /all")
    func types() {
        #expect(["movie", "show", "season", "episode", "collection"].map(PlexMapper.itemType)
                == ["Movie", "Series", "Season", "Episode", "BoxSet"])
        #expect(PlexMapper.plexTypeNumber(forItemType: "Episode") == 4)
        #expect(PlexMapper.plexTypeNumber(forItemType: "BoxSet") == nil)
    }

    @Test("Bibliotheken: Film und Serie als Ansicht")
    func views() throws {
        let box = try JSONDecoder().decode(PlexEnvelope<PlexListing>.self,
                                           from: Data(PlexFixtures.sections.utf8))
        let views = box.container.directories.map(PlexMapper().view)
        #expect(views.map(\.collectionType) == ["movies", "tvshows", "music"])
        #expect(views.map(\.id) == ["1", "2", "3"])
    }
}

// MARK: - Playback

@Suite("Plex: Abspielen, Adressen, Vorschau")
struct PlexPlaybackTests {

    private let playback = PlexPlayback(base: URL(string: "http://192.168.1.5:32400")!, token: "TOK")

    @Test("Die Datei liegt am Part-Schlüssel, das Token in der Adresse")
    func fileAddress() {
        #expect(playback.fileURL(partKey: "/library/parts/1/17/file.mkv")?.absoluteString
                == "http://192.168.1.5:32400/library/parts/1/17/file.mkv?X-Plex-Token=TOK")
        #expect(playback.fileURL(partKey: "/library/parts/1/17/file.mkv", download: true)?
            .absoluteString.contains("download=1") == true)
    }

    @Test("Bilder: ohne Größe direkt, mit Größe über den Bildumrechner (beide Seiten nötig), Personen absolut")
    func images() {
        #expect(playback.imageURL(path: "/library/metadata/1/thumb/17")?.absoluteString
                == "http://192.168.1.5:32400/library/metadata/1/thumb/17?X-Plex-Token=TOK")
        #expect(playback.imageURL(path: "/library/metadata/1/thumb/17", maxHeight: 480)?.absoluteString
                == "http://192.168.1.5:32400/photo/:/transcode?url=%2Flibrary%2Fmetadata%2F1%2Fthumb%2F17&upscale=0&width=4096&height=480&quality=90&X-Plex-Token=TOK")
        #expect(playback.imageURL(path: "https://metadata-static.plex.tv/a.jpg", maxHeight: 100)?
            .absoluteString == "https://metadata-static.plex.tv/a.jpg")
    }

    @Test("Der Plan ist immer Direct Play, ohne Umwandlung")
    func plan() throws {
        let m = try decodeMetadata(PlexFixtures.movie)
        let plan = try playback.plan(for: m, sessionID: "S1")
        #expect(plan.method == .directPlay)
        #expect(plan.reasons.isEmpty)
        #expect(plan.mediaSourceID == "1")
        #expect(plan.playSessionID == "S1")
        #expect(plan.container == "mkv")
        #expect(plan.url.absoluteString.hasSuffix("/library/parts/1/1793487178/file.mkv?X-Plex-Token=TOK"))
        #expect(!plan.url.absoluteString.contains("transcode"))

        let other = try playback.plan(for: m, mediaSourceID: "2", audioStreamID: 3, subtitleStreamID: 4)
        #expect(other.mediaSourceID == "2")
        #expect(other.url.absoluteString.contains("/library/parts/2/"))
        #expect(other.source?.defaultAudioStreamIndex == 3)
        #expect(other.source?.defaultSubtitleStreamIndex == 4)
    }

    @Test("Ohne Datei kein Plan")
    func noFile() throws {
        let m = try decodeMetadata(PlexFixtures.show)
        #expect(throws: PlexError.noFile) { try playback.plan(for: m) }
    }

    @Test("Äußerer Untertitel bekommt das Token, einer in der Datei keine Adresse")
    func subtitles() throws {
        let m = try decodeMetadata(PlexFixtures.movie)
        let streams = try #require(m.media.first?.parts.first?.streams)
        #expect(playback.subtitleURL(streams[3])?.absoluteString
                == "http://192.168.1.5:32400/library/streams/4?X-Plex-Token=TOK")
        #expect(playback.subtitleURL(streams[4]) == nil)
        #expect(playback.subtitleURL(streams[1]) == nil)
    }

    @Test("Fortschritt: Ticks werden Millisekunden")
    func timeline() {
        let query = PlexPlayback.timelineQuery(ratingKey: "7", state: .paused,
                                               positionTicks: 123_450_000, durationMilliseconds: 90_000)
        let map = Dictionary(uniqueKeysWithValues: query)
        #expect(map["time"] == "12345")
        #expect(map["state"] == "paused")
        #expect(map["key"] == "/library/metadata/7")
        #expect(map["duration"] == "90000")
    }

    // BIF

    private func bif(_ pictures: [(ms: Int, bytes: [UInt8])], multiplier: UInt32 = 0) -> Data {
        func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
        var out: [UInt8] = [0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]
        out += le(0) + le(UInt32(pictures.count)) + le(multiplier)
        out += [UInt8](repeating: 0, count: 44)
        var offset = UInt32(64 + (pictures.count + 1) * 8)
        var table: [UInt8] = []
        var body: [UInt8] = []
        for p in pictures {
            table += le(UInt32(p.ms) / (multiplier == 0 ? 1000 : multiplier)) + le(offset)
            body += p.bytes
            offset += UInt32(p.bytes.count)
        }
        table += le(0xFFFFFFFF) + le(offset)
        return Data(out + table + body)
    }

    @Test("BIF: das Bild zur Stelle, an den Rändern das erste und das letzte")
    func bifLookup() throws {
        let file = try #require(PlexBIF(data: bif([(0, [1, 1, 1]), (10_000, [2, 2]), (20_000, [3])])))
        #expect(file.frames.map(\.milliseconds) == [0, 10_000, 20_000])
        #expect(file.image(atSeconds: 0) == Data([1, 1, 1]))
        #expect(file.image(atSeconds: 9.9) == Data([1, 1, 1]))
        #expect(file.image(atSeconds: 10) == Data([2, 2]))
        #expect(file.image(atSeconds: 15) == Data([2, 2]))
        #expect(file.image(atSeconds: 9_999) == Data([3]))
        #expect(file.image(atSeconds: -4) == Data([1, 1, 1]))
        #expect(file.image(atSeconds: .nan) == nil)
    }

    @Test("BIF: Müll und abgeschnittene Dateien ergeben nichts statt eines Absturzes")
    func bifBad() {
        #expect(PlexBIF(data: Data()) == nil)
        #expect(PlexBIF(data: Data(repeating: 0, count: 100)) == nil)
        let good = bif([(0, [1, 1, 1]), (10_000, [2, 2])])
        #expect(PlexBIF(data: good.prefix(good.count - 2)) == nil)
        #expect(PlexBIF(data: good.prefix(70)) == nil)
    }
}

// MARK: - Capabilities

@Suite("Plex: Fähigkeiten")
struct PlexFeaturesTests {
    @Test("Kein SyncPlay, Quick Connect, Fernsteuerung, Einstellungsabgleich, Seerr")
    func list() {
        let can = PlexFeatures.capabilities
        for no in [ServerCapability.syncPlay, .quickConnect, .remoteControl, .settingsSync,
                   .playOnOtherDevice, .publicUsers, .seerr] {
            #expect(!can.contains(no))
        }
        for yes in [ServerCapability.introSegments, .chapters, .downloads, .favorites,
                    .markWatched, .collections, .playlists, .trickplay] {
            #expect(can.contains(yes))
        }
        #expect(can.union(PlexFeatures.missing) == Set(ServerCapability.allCases))
    }
}

// MARK: - plex.tv

@Suite("Plex: Anmeldung und Konto")
struct PlexAccountTests {

    private func service(_ host: String, _ session: URLSession) -> PlexAccountService {
        let base = URL(string: "http://\(host)")!
        return PlexAccountService(identity: testIdentity, urlSession: session, tvBase: base,
                                  clientsBase: base, appBase: URL(string: "https://app.plex.tv")!)
    }

    @Test("Die Stelle im Browser trägt Client, Code und App")
    func authURL() {
        let svc = PlexAccountService(identity: testIdentity)
        let pin = PlexPin(id: 1, code: "ABCD1234")
        #expect(svc.authURL(for: pin)?.absoluteString
                == "https://app.plex.tv/auth#?clientID=cid&code=ABCD1234&context%5Bdevice%5D%5Bproduct%5D=Swiftly%20Player")
    }

    @Test("Neue PIN: POST mit strong und den Plex-Kopfzeilen")
    func startPin() async throws {
        let (host, session) = PlexStub.register { _ in (201, PlexFixtures.pinFresh) }
        let pin = try await service(host, session).startPin()
        #expect(pin.id == 4711 && pin.code == "ABCD1234" && pin.authToken == nil)
        let req = try #require(PlexStub.requests(host).first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/api/v2/pins")
        #expect(req.url?.query == "strong=true")
        #expect(req.value(forHTTPHeaderField: "X-Plex-Client-Identifier") == "cid")
        #expect(req.value(forHTTPHeaderField: "X-Plex-Product") == "Swiftly Player")
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(req.value(forHTTPHeaderField: "X-Plex-Token") == nil)
    }

    @Test("Warten: zweimal noch nichts, dann das Token")
    func waitForToken() async throws {
        let calls = PlexCounter()
        let (host, session) = PlexStub.register { _ in
            calls.next() < 3 ? (200, PlexFixtures.pinFresh) : (200, PlexFixtures.pinDone)
        }
        let token = try await service(host, session).awaitToken(
            PlexPin(id: 4711, code: "ABCD1234"), pause: .milliseconds(5), limit: .seconds(5))
        #expect(token == "ACCOUNTTOKEN")
        #expect(calls.count == 3)
        #expect(PlexStub.requests(host).first?.url?.path == "/api/v2/pins/4711")
    }

    @Test("Abgelaufene PIN meldet sich als abgelaufen")
    func expired() async throws {
        let (host, session) = PlexStub.register { _ in (404, "") }
        await #expect(throws: PlexError.pinExpired) {
            _ = try await service(host, session).awaitToken(
                PlexPin(id: 1, code: "X"), pause: .milliseconds(5), limit: .seconds(5))
        }
        let (slowHost, slow) = PlexStub.register { _ in (200, PlexFixtures.pinFresh) }
        await #expect(throws: PlexError.pinExpired) {
            _ = try await service(slowHost, slow).awaitToken(
                PlexPin(id: 1, code: "X"), pause: .milliseconds(5), limit: .milliseconds(30))
        }
    }

    @Test("Token prüfen: 200 gilt, 401 gilt nicht, 500 ist ein Fehler und keine Abmeldung")
    func validate() async throws {
        let ok = PlexStub.register { _ in (200, #"{"id":7,"title":"Paul","uuid":"u"}"#) }
        if case .valid(let user) = try await service(ok.host, ok.session).validate(token: "t") {
            #expect(user.title == "Paul" && user.id == "7")
        } else { Issue.record("expected valid") }

        let no = PlexStub.register { _ in (401, "") }
        #expect(try await service(no.host, no.session).validate(token: "t") == .invalid)

        let down = PlexStub.register { _ in (500, "") }
        await #expect(throws: JellyfinError.self) {
            _ = try await service(down.host, down.session).validate(token: "t")
        }
    }

    @Test("Server: nur echte Server, mit eigenem Token und allen Adressen")
    func servers() async throws {
        let (host, session) = PlexStub.register { _ in (200, PlexFixtures.resources) }
        let list = try await service(host, session).servers(token: "acct")
        #expect(list.map(\.machineIdentifier) == ["MACHINE1", "MACHINE2"])
        #expect(list[0].accessToken == "SERVERTOKEN")
        #expect(list[0].owned && !list[1].owned)
        let c = list[0].connections
        #expect(c.count == 4)
        #expect(c[0].isLocal && !c[0].isHTTPS && !c[0].isRelay)
        #expect(c[1].isHTTPS && c[1].isLocal)
        #expect(!c[2].isLocal && !c[2].isRelay)
        #expect(c[3].isRelay)
        let req = try #require(PlexStub.requests(host).first)
        #expect(req.value(forHTTPHeaderField: "X-Plex-Token") == "acct")
        #expect(req.url?.query?.contains("includeRelay=1") == true)
    }

    @Test("Haushalt: Profile lesen, mit PIN wechseln, falsche PIN erkennen")
    func home() async throws {
        let (host, session) = PlexStub.register { req in
            if req.url?.path == "/api/v2/home/users" { return (200, PlexFixtures.homeUsers) }
            if req.url?.path == "/api/v2/home/users/uuid-kid/switch" {
                return req.url?.query == "pin=1234" ? (201, #"{"authToken":"KIDTOKEN"}"#) : (401, "")
            }
            return (404, "")
        }
        let svc = service(host, session)
        let users = try await svc.homeUsers(token: "acct")
        #expect(users.map(\.title) == ["Owner", "Kid"])
        #expect(users[1].isProtected && users[1].isRestricted && !users[1].isAdmin)
        #expect(try await svc.switchUser(users[1], pin: "1234", token: "acct") == "KIDTOKEN")
        await #expect(throws: PlexError.profilePinWrong) {
            _ = try await svc.switchUser(users[1], pin: "0000", token: "acct")
        }
        #expect(PlexStub.requests(host).last?.httpMethod == "POST")
    }

    @Test("Kopfzeilen: Zeilenumbrüche im Gerätenamen fallen weg, Umlaute bleiben")
    func headerSafe() {
        let id = PlexIdentity(clientID: "c", platform: "iOS", device: "iPhone",
                              deviceName: "Pauls\nGerät")
        #expect(id.headers()["X-Plex-Device-Name"] == "PaulsGerät")
        #expect(PlexIdentity.makeClientID() != PlexIdentity.makeClientID())
    }
}

// MARK: - Which address

@Suite("Plex: Adresswahl")
struct PlexConnectionTests {

    private func conn(_ uri: String, local: Bool = false, relay: Bool = false,
                      https: Bool = true, v6: Bool = false) -> PlexConnectionInfo {
        PlexConnectionInfo(uri: uri, address: "", port: 32400, isHTTPS: https,
                           isLocal: local, isRelay: relay, isIPv6: v6)
    }

    private var set: [PlexConnectionInfo] {
        [conn("https://relay", relay: true),
         conn("https://remote"),
         conn("https://local-s", local: true),
         conn("http://local", local: true, https: false),
         conn("https://local-6", local: true, v6: true)]
    }

    @Test("Reihenfolge: nah vor fern vor Umweg, im Heimnetz ohne Zertifikat zuerst")
    func order() {
        #expect(PlexConnector.ranked(set).map(\.uri)
                == ["http://local", "https://local-s", "https://local-6", "https://remote", "https://relay"])
    }

    @Test("Verlangt der Server https, kommt http hinter die https-Adressen")
    func httpsRequired() {
        let order = PlexConnector.ranked(set, httpsRequired: true).map(\.uri)
        #expect(order.first == "https://local-s")
        #expect(order.firstIndex(of: "http://local")! > order.firstIndex(of: "https://local-6")!)
    }

    @Test("Die gemerkte Adresse geht vor")
    func remembered() {
        let order = PlexConnector.ranked(set, remembered: URL(string: "https://remote")!)
        #expect(order.first?.uri == "https://remote")
    }

    private func server(_ connections: [PlexConnectionInfo]) throws -> PlexServerResource {
        let data = try JSONSerialization.data(withJSONObject: [
            "clientIdentifier": "M", "name": "S", "provides": "server", "owned": true,
            "connections": try JSONSerialization.jsonObject(with: JSONEncoder().encode(connections)),
        ])
        return try JSONDecoder().decode(PlexServerResource.self, from: data)
    }

    @Test("Nimmt die beste Adresse, die antwortet, nicht die schnellste")
    func bestAnswering() async throws {
        let connector = PlexConnector { c in
            switch c.uri {
            case "http://local": return false
            case "https://local-s": return false
            case "https://local-6": return false
            case "https://remote":
                try? await Task.sleep(for: .milliseconds(60)); return true
            default: return true   // the relay answers at once
            }
        }
        let chosen = try await connector.choose(from: try server(set))
        #expect(chosen.uri.absoluteString == "https://remote")
        #expect(!chosen.isLocal && !chosen.isRelay)
    }

    @Test("Antwortet die nahe Adresse, wartet niemand auf die langsamen")
    func doesNotWait() async throws {
        let started = ContinuousClock.now
        let connector = PlexConnector { c in
            if c.uri == "http://local" { return true }
            try? await Task.sleep(for: .seconds(10))
            return true
        }
        let chosen = try await connector.choose(from: try server(set))
        #expect(chosen.uri.absoluteString == "http://local" && chosen.isLocal)
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test("Hängt die nahe Adresse, zählt nach der Gnadenfrist die, die geantwortet hat")
    func graceEnds() async throws {
        let started = ContinuousClock.now
        let connector = PlexConnector(grace: .milliseconds(200)) { c in
            switch c.uri {
            case "http://local", "https://local-s", "https://local-6":
                try? await Task.sleep(for: .seconds(10)); return false   // a dead LAN address
            default: return true
            }
        }
        let chosen = try await connector.choose(from: try server(set))
        #expect(chosen.uri.absoluteString == "https://remote")
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test("Antwortet keine, ist der Server nicht erreichbar")
    func none() async throws {
        let connector = PlexConnector { _ in false }
        await #expect(throws: PlexError.serverUnreachable) {
            _ = try await connector.choose(from: try server(set))
        }
        await #expect(throws: PlexError.serverUnreachable) {
            _ = try await connector.choose(from: try server([]))
        }
    }

    @Test("Die gemerkte Adresse wird zuerst allein gefragt")
    func rememberedFirst() async throws {
        let asked = PlexCounter()
        let connector = PlexConnector { _ in asked.next(); return true }
        let memory = PlexChosenConnection(machineIdentifier: "M",
                                          uri: URL(string: "https://remote")!,
                                          isLocal: false, isRelay: false)
        let chosen = try await connector.choose(from: try server(set), remembered: memory)
        #expect(chosen.uri == memory.uri)
        #expect(asked.count == 1)
    }

    @Test("Die Sonde prüft die Maschinenkennung: ein anderer Server zählt nicht")
    func probeChecksMachine() async throws {
        let (host, session) = PlexStub.register { _ in (200, PlexFixtures.identity) }
        let base = URL(string: "http://\(host):32400")!
        let right = await PlexConnector.identityMatches(base: base, identity: testIdentity, token: "t",
                                                        machineIdentifier: "MACHINE1", timeout: 2,
                                                        session: session)
        let wrong = await PlexConnector.identityMatches(base: base, identity: testIdentity, token: "t",
                                                        machineIdentifier: "OTHER", timeout: 2,
                                                        session: session)
        #expect(right && !wrong)
    }
}

// MARK: - Client against a stub server

@Suite("Plex: Client")
struct PlexClientTests {

    private func make(_ handler: @escaping PlexStub.Handler) -> (PlexClient, String) {
        let (host, session) = PlexStub.register(handler)
        let client = PlexClient(baseURL: URL(string: "http://\(host):32400")!, token: "TOK",
                                identity: testIdentity, urlSession: session)
        return (client, host)
    }

    @Test("Liste: Seite, Gesamtzahl, Sortierung und Blättern in Kopfzeilen")
    func list() async throws {
        let (client, host) = make { _ in (200, PlexFixtures.page) }
        let page = try await client.list(section: "1", type: "Series", sort: .latest,
                                         filter: .unwatched, start: 50, size: 25)
        #expect(page.items.map(\.id) == ["10", "11"])
        #expect(page.total == 7)
        let req = try #require(PlexStub.requests(host).first)
        #expect(req.url?.path == "/library/sections/1/all")
        let query = req.url?.query ?? ""
        #expect(query.contains("sort=addedAt%3Adesc"))
        #expect(query.contains("type=2"))
        #expect(query.contains("unwatched=1"))
        #expect(req.value(forHTTPHeaderField: "X-Plex-Container-Start") == "50")
        #expect(req.value(forHTTPHeaderField: "X-Plex-Container-Size") == "25")
        #expect(req.value(forHTTPHeaderField: "X-Plex-Token") == "TOK")
    }

    @Test("Merkliste ist die Bewertung ab 9, Angefangen ist inProgress")
    func filters() async throws {
        let (client, host) = make { _ in (200, PlexFixtures.page) }
        _ = try await client.list(section: "1", filter: .watchlist)
        _ = try await client.list(section: "1", filter: .begun)
        let queries = PlexStub.requests(host).compactMap { $0.url?.query }
        #expect(queries[0].contains("userRating%3E%3E=9"))
        #expect(queries[1].contains("inProgress=1"))
    }

    @Test("Detail holt Marker und Kapitel mit")
    func detail() async throws {
        let (client, host) = make { _ in (200, PlexFixtures.movie) }
        let detail = try await client.detail("1")
        #expect(detail.item.id == "1")
        #expect(detail.segments.count == 2 && detail.chapters.count == 2)
        let query = PlexStub.requests(host).first?.url?.query ?? ""
        #expect(query.contains("includeMarkers=1") && query.contains("includeChapters=1"))
    }

    @Test("Gesehen, Liebling und Fortschritt gehen an die richtigen Stellen")
    func writes() async throws {
        let (client, host) = make { _ in (200, "") }
        try await client.setWatched("7", true)
        try await client.setWatched("7", false)
        try await client.setFavorite("7", true)
        try await client.setFavorite("7", false)
        try await client.reportTimeline("7", state: .playing, positionTicks: 50_000_000,
                                        durationMilliseconds: 90_000)
        let seen = PlexStub.requests(host)
        func line(_ i: Int) -> String { "\(seen[i].httpMethod ?? "") \(seen[i].url?.path ?? "")" }
        #expect(line(0) == "PUT /:/scrobble")
        #expect(line(1) == "PUT /:/unscrobble")
        #expect(line(2) == "PUT /:/rate" && seen[2].url?.query?.contains("rating=10") == true)
        #expect(seen[3].url?.query?.contains("rating=-1") == true)
        #expect(line(4) == "POST /:/timeline")
        #expect(seen[4].url?.query?.contains("time=5000") == true)
        #expect(seen[4].value(forHTTPHeaderField: "X-Plex-Session-Identifier") == client.sessionID)
    }

    @Test("401 heißt nicht angemeldet; das Token gilt dann nicht mehr")
    func unauthorized() async throws {
        let (client, _) = make { _ in (401, "") }
        await #expect(throws: JellyfinError.notAuthenticated) { _ = try await client.sections() }
        #expect(try await client.tokenWorks() == false)
    }

    @Test("Vorschau: 404 ist kein Fehler, sondern keine Vorschau")
    func previewsMissing() async throws {
        let (client, _) = make { req in
            req.url?.path.hasPrefix("/library/parts/") == true ? (404, "") : (200, PlexFixtures.movie)
        }
        #expect(try await client.previews("1") == nil)
    }

    @Test("Plan und Download über den Client")
    func plan() async throws {
        let (client, host) = make { _ in (200, PlexFixtures.movie) }
        let plan = try await client.plan(for: "1")
        #expect(plan.method == .directPlay && plan.playSessionID == client.sessionID)
        let download = try await client.downloadURL("1", mediaSourceID: "2")
        #expect(download.absoluteString.contains("/library/parts/2/"))
        #expect(download.absoluteString.contains("download=1"))
        #expect(download.host == host)
    }

    @Test("Suche: leere Eingabe fragt nicht, Treffer ohne Film/Serie/Folge fallen weg")
    func search() async throws {
        let (client, host) = make { _ in (200, #"""
        {"MediaContainer":{"size":2,"Hub":[
          {"hubIdentifier":"movie","title":"Movies","type":"movie","Metadata":[{"ratingKey":"1","type":"movie","title":"A"}]},
          {"hubIdentifier":"actor","title":"Actors","type":"actor","Metadata":[{"ratingKey":"9","type":"person","title":"B"}]}]}}
        """#) }
        #expect(try await client.search("  ").isEmpty)
        #expect(PlexStub.requests(host).isEmpty)
        #expect(try await client.search("a b+c").map(\.id) == ["1"])
        #expect(PlexStub.requests(host).first?.url?.query?.contains("query=a%20b%2Bc") == true)
    }
}

