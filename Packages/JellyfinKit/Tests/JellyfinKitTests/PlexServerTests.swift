import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import JellyfinKit

private let identity = PlexIdentity(clientID: "cid", platform: "macOS", device: "Mac",
                                    deviceName: "Test Mac")

private func plexSession(machine: String = "MACHINE1", host: String = "plex.test",
                         user: String = "42") -> Session {
    Session(accessToken: "SERVERTOKEN", userID: user, userName: "Ann",
            serverURL: URL(string: "http://\(host):32400")!, kind: .plex,
            plex: PlexSessionDetails(machineIdentifier: machine, serverName: "Home",
                                     accountToken: "ACCOUNT", isLocal: true))
}

// MARK: - Plex as a MediaServer

@Suite("Plex: MediaServer")
struct PlexMediaServerTests {

    private func server(_ handler: @escaping PlexStub.Handler) -> (any MediaServer, String) {
        let (host, urlSession) = PlexStub.register(handler)
        let client = PlexClient(baseURL: URL(string: "http://\(host):32400")!, token: "TOK",
                                identity: identity, urlSession: urlSession)
        return (client, host)
    }

    private func libraryHandler(_ req: URLRequest) -> (Int, String) {
        switch req.url?.path ?? "" {
        case "/library/sections": (200, PlexFixtures.sections)
        case "/library/sections/1/all", "/library/sections/2/all": (200, PlexFixtures.page)
        case "/library/metadata/1": (200, PlexFixtures.movie)
        case "/:/timeline": (200, "")
        default: (404, "")
        }
    }

    @Test("Art, Fähigkeiten und fehlende Hilfsprotokolle: was Plex nicht kann, ist weg")
    func identityAndHelpers() {
        let (server, _) = server { _ in (200, "") }
        #expect(server.kind == .plex)
        #expect(server.capabilities == PlexFeatures.capabilities)
        for gone: ServerCapability in [.quickConnect, .syncPlay, .remoteControl,
                                       .playOnOtherDevice, .settingsSync] {
            #expect(!server.capabilities.contains(gone))
            #expect(PlexFeatures.missing.contains(gone))
        }
        #expect(PlexFeatures.capabilities.isDisjoint(with: PlexFeatures.missing))
        #expect(PlexFeatures.capabilities.union(PlexFeatures.missing) == Set(ServerCapability.allCases))
        // Absent means hidden: the app reaches these through `as?`.
        #expect((server as? any QuickSignIn) == nil)
        #expect((server as? any RemoteSessionServer) == nil)
        #expect((server as? any DisplayPreferencesServer) == nil)
    }

    @Test("Bibliotheken, Liste über alle Bibliotheken und Detail kommen als Item an")
    func libraries() async throws {
        let (server, _) = server(libraryHandler)
        let views = try await server.userViews()
        // The music library is not shown: the app plays films and series.
        #expect(views.map(\.id) == ["1", "2"])
        let page = try await server.items(limit: 5)
        #expect(!page.items.isEmpty)
        #expect(page.totalRecordCount >= page.items.count)
        let one = try await server.items(parentID: "1", limit: 5)
        #expect(one.items.map(\.id) == ["10", "11"])
        #expect(try await server.item(id: "1").name == "Testfilm")
    }

    @Test("Was Plex nicht hat, ist leer oder 'unsupported', nie ein Absturz")
    func unsupported() async throws {
        let (server, host) = server(libraryHandler)
        #expect(await server.libraryShares(views: []).isEmpty)
        await #expect(throws: PlexError.unsupported) { _ = try await server.userDataRaw(itemID: "1") }
        await #expect(throws: PlexError.unsupported) {
            try await server.userDataBackPut(itemID: "1", raw: Data())
        }
        #expect(await server.accountDefaults()?.convertAllowed == false)
        #expect(PlexStub.requests(host).isEmpty)
    }

    @Test("Wiedergabe: Plan ist Direct Play mit Token in der Adresse, Meldungen gehen an /:/timeline")
    func playback() async throws {
        let (server, host) = server(libraryHandler)
        let plan = try #require(try await server.playbackPlan(for: "1"))
        #expect(plan.method == .directPlay)
        #expect(plan.url.absoluteString.contains("X-Plex-Token=TOK"))
        try await server.reportStart(itemID: "1", plan: plan, ticks: 0)
        try await server.reportProgress(itemID: "1", plan: plan, positionTicks: 100_000_000, paused: false)
        try await server.reportStopped(itemID: "1", plan: plan, positionTicks: 200_000_000)
        let timeline = PlexStub.requests(host).filter { $0.url?.path == "/:/timeline" }
        #expect(timeline.count == 3)
        let states = timeline.compactMap { req in
            URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "state" }?.value
        }
        #expect(states == ["playing", "playing", "stopped"])
    }

    @Test("Nachmeldung: eine offene Position landet beim Server, die Meldung ist erledigt")
    func late() async throws {
        let (server, host) = server(libraryHandler)
        let report = PendingReport(itemID: "1", account: "plex-MACHINE1-42", ticks: 300_000_000,
                                   moment: Date(timeIntervalSinceNow: 60))
        let done = await server.reportLater([report], log: { _ in })
        #expect(done == [report.id])
        #expect(PlexStub.requests(host).contains { $0.url?.path == "/:/timeline" })
    }

    @Test("Ohne Konto bleibt die Sitzung leer; signOff vergisst das Konto")
    func accountState() async {
        let (host, urlSession) = PlexStub.register { _ in (200, "") }
        let client = PlexClient(session: plexSession(host: host), identity: identity,
                                urlSession: urlSession)
        #expect(await client.currentSession()?.userID == "42")
        await client.signOff()
        #expect(await client.currentSession() == nil)
        let bare = PlexClient(baseURL: URL(string: "http://\(host):32400")!, token: "T", identity: identity)
        #expect(await bare.currentSession() == nil)
    }
}

// MARK: - The session and what hangs on it

@Suite("Plex: Sitzung und Schlüssel")
struct PlexSessionTests {

    @Test("Eine Plex-Sitzung übersteht Schreiben und Lesen, Jellyfin schreibt weiter nichts dazu")
    func roundTrip() throws {
        let session = plexSession()
        let data = try JSONEncoder().encode(session)
        let back = try JSONDecoder().decode(Session.self, from: data)
        #expect(back == session)
        #expect(back.plex?.machineIdentifier == "MACHINE1" && back.kind == .plex)

        let jelly = Session(accessToken: "t", userID: "1", userName: "p",
                            serverURL: URL(string: "https://j.example.com")!)
        let text = String(decoding: try JSONEncoder().encode(jelly), as: UTF8.self)
        #expect(!text.contains("plex") && !text.contains("kind"))
    }

    @Test("Ein Plex-Block mit nur den Pflichtfeldern liest sich, Fehlendes bekommt Vorgaben")
    func lean() throws {
        let json = #"""
        {"accessToken":"t","userID":"1","userName":"p","serverURL":"http://h:32400","kind":"plex",
         "plex":{"machineIdentifier":"M","accountToken":"A"}}
        """#
        let back = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        #expect(back.plex == PlexSessionDetails(machineIdentifier: "M", serverName: "",
                                                accountToken: "A"))
    }

    @Test("accountKey: Plex hängt an der Maschine, nicht an der Adresse")
    func accountKey() {
        let home = plexSession(host: "192.168.1.5")
        let away = plexSession(host: "84-1-2-3.abc.plex.direct")
        #expect(home.accountKey == "plex:MACHINE1|42")
        #expect(away.accountKey == home.accountKey)
        #expect(plexSession(machine: "MACHINE2").accountKey != home.accountKey)
        // Jellyfin as ever.
        let jelly = Session(accessToken: "t", userID: "7", userName: "p",
                            serverURL: URL(string: "https://Server.example.com/")!)
        #expect(jelly.accountKey == "https://server.example.com|7")
    }

    @Test("Schlüssel je Server: Jellyfin byte-gleich, Plex je Maschine, nie zwei Server in einem")
    func perServerKeys() {
        let jelly = Session(accessToken: "t", userID: "7", userName: "p",
                            serverURL: URL(string: "https://Server.example.com/")!)
        #expect(jelly.serverSuffix == "|https://Server.example.com/")
        #expect(jelly.storageAccount == "7")
        #expect(jelly.serverIdentity == "https://server.example.com")

        let one = plexSession(machine: "A", user: "42")
        let two = plexSession(machine: "B", user: "42")
        #expect(one.serverSuffix == "|plex:A")
        #expect(one.storageAccount == "plex-A-42")
        #expect(one.storageAccount != two.storageAccount)
        #expect(one.serverIdentity != two.serverIdentity)
    }

    @Test("Ein Bündel hält ein Plex-Konto auch nach dem Wechsel der Adresse beisammen")
    func bundle() {
        let home = plexSession(host: "192.168.1.5")
        let away = plexSession(host: "relay.example.com")
        let bundle = AccountBundle(home)
        #expect(bundle.fitsServer(away))
        #expect(bundle.server.count == 1)
        #expect(!bundle.fitsServer(plexSession(machine: "OTHER")))
    }
}

// MARK: - Another address

@Suite("Plex: Verbindung wechseln")
struct PlexReconnectTests {

    private func route(_ host: String, local: Bool = false, relay: Bool = false) -> PlexResolvedRoute {
        PlexResolvedRoute(connection: PlexChosenConnection(
            machineIdentifier: "MACHINE1", uri: URL(string: "http://\(host):32400")!,
            isLocal: local, isRelay: relay), token: "NEWTOKEN")
    }

    @Test("Geht die Adresse nicht mehr, wählt der Client eine neue, wiederholt einmal und meldet sie")
    func switchesOnError() async throws {
        let (dead, urlSession) = PlexStub.register { _ in (503, "") }
        // A second stub on the same session class answers for the new address.
        let (alive, _) = PlexStub.register { _ in (200, PlexFixtures.sections) }
        let calls = PlexCounter()
        let resolver: PlexClient.Resolver = { details in
            calls.next()
            #expect(details.machineIdentifier == "MACHINE1")
            return route(alive, local: false, relay: true)
        }
        let client = PlexClient(session: plexSession(host: dead), identity: identity,
                                urlSession: urlSession, resolver: resolver)
        let told = PlexCounter()
        let seen = SessionBox()
        await client.onSessionChange { session in told.next(); seen.set(session) }

        let views = try await client.userViews()
        #expect(views.count == 2)
        #expect(calls.count == 1 && told.count == 1)
        #expect(client.baseURL.host == alive)
        let moved = try #require(seen.value)
        #expect(moved.serverURL.host == alive && moved.accessToken == "NEWTOKEN")
        #expect(moved.plex?.isRelay == true && moved.plex?.isLocal == false)
        #expect(moved.accountKey == plexSession().accountKey)
        // The old address was asked once, the new one answered.
        #expect(PlexStub.requests(dead).count == 1)
        #expect(PlexStub.requests(alive).count == 1)
    }

    @Test("Gleichzeitige Aufrufe teilen sich eine Suche")
    func singleFlight() async throws {
        let (dead, urlSession) = PlexStub.register { _ in (503, "") }
        let (alive, _) = PlexStub.register { _ in (200, PlexFixtures.sections) }
        let calls = PlexCounter()
        let resolver: PlexClient.Resolver = { _ in
            calls.next()
            try? await Task.sleep(for: .milliseconds(150))
            return route(alive)
        }
        let client = PlexClient(session: plexSession(host: dead), identity: identity,
                                urlSession: urlSession, resolver: resolver)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<4 { group.addTask { try await client.userViews().count } }
            for try await count in group { #expect(count == 2) }
        }
        #expect(calls.count == 1)
    }

    @Test("401 und 404 sind kein Wegproblem: kein Wechsel")
    func noSwitchForAnswers() async throws {
        let (host, urlSession) = PlexStub.register { _ in (401, "") }
        let calls = PlexCounter()
        let client = PlexClient(session: plexSession(host: host), identity: identity,
                                urlSession: urlSession,
                                resolver: { _ in calls.next(); return route("elsewhere.test") })
        await #expect(throws: JellyfinError.notAuthenticated) { _ = try await client.userViews() }
        #expect(calls.count == 0)
        #expect(!PlexClient.isRouteProblem(JellyfinError.http(status: 404, body: nil)))
        #expect(PlexClient.isRouteProblem(JellyfinError.http(status: 502, body: nil)))
    }

    @Test("Ohne Konto gibt es nichts zu suchen: der Fehler bleibt")
    func withoutAccount() async {
        let (host, urlSession) = PlexStub.register { _ in (503, "") }
        let client = PlexClient(baseURL: URL(string: "http://\(host):32400")!, token: "T",
                                identity: identity, urlSession: urlSession)
        await #expect(throws: (any Error).self) { _ = try await client.userViews() }
        #expect(PlexStub.requests(host).count == 1)
    }

    @Test("Findet die Suche nichts, kommt der Fehler 'Server nicht erreichbar'")
    func nothingFound() async {
        let (host, urlSession) = PlexStub.register { _ in (503, "") }
        let client = PlexClient(session: plexSession(host: host), identity: identity,
                                urlSession: urlSession,
                                resolver: { _ in throw PlexError.serverUnreachable })
        await #expect(throws: PlexError.serverUnreachable) { _ = try await client.userViews() }
    }

    @Test("Der beste Weg wird auch ohne Fehler gewählt, die Meldung sagt, ob er wechselte")
    func chooseBest() async throws {
        let (host, urlSession) = PlexStub.register { _ in (200, "") }
        let target = route("home.test", local: true)
        let client = PlexClient(session: plexSession(host: host), identity: identity,
                                urlSession: urlSession, resolver: { _ in target })
        #expect(try await client.chooseBestConnection())
        #expect(client.baseURL.host == "home.test")
        #expect(try await client.chooseBestConnection() == false)
    }
}

final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Session?
    var value: Session? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ s: Session) { lock.lock(); stored = s; lock.unlock() }
}
