import Foundation
import Testing
@testable import JellyfinKit

@Suite("Neutrale Server-Schicht")
struct MediaServerTests {

    private let url = URL(string: "https://jellyfin.example.com")!

    private func make(kind: ServerKind = .jellyfin, session: Session? = nil) -> (any MediaServer)? {
        MediaServerFactory.make(kind: kind, baseURL: url, deviceID: "d", deviceName: "n", session: session)
    }

    // MARK: Session.kind

    @Test("Eine alte Sitzung ohne kind ist Jellyfin")
    func oldSession() throws {
        let old = #"{"accessToken":"t","userID":"1","userName":"paul","serverURL":"https://jellyfin.example.com"}"#
        let session = try JSONDecoder().decode(Session.self, from: Data(old.utf8))
        #expect(session.kind == .jellyfin)
        #expect(session.userName == "paul")
    }

    @Test("Eine Jellyfin-Sitzung schreibt kein kind, sie bleibt so, wie ältere Fassungen sie schrieben")
    func jellyfinWritesNoKind() throws {
        let session = Session(accessToken: "t", userID: "1", userName: "paul", serverURL: url)
        let text = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        #expect(!text.contains("kind"))
    }

    @Test("Eine andere Art übersteht Schreiben und Lesen")
    func otherKindRoundTrip() throws {
        let session = Session(accessToken: "t", userID: "1", userName: "paul", serverURL: url, kind: .plex)
        let back = try JSONDecoder().decode(Session.self, from: try JSONEncoder().encode(session))
        #expect(back == session)
        #expect(back.kind == .plex)
    }

    @Test("accountKey: Jellyfin unverändert, andere mit Vorsatz")
    func accountKeys() {
        func key(_ kind: ServerKind) -> String {
            Session(accessToken: "t", userID: "7", userName: "p",
                    serverURL: URL(string: "https://Server.example.com/")!, kind: kind).accountKey
        }
        #expect(key(.jellyfin) == "https://server.example.com|7")
        #expect(key(.emby) == "emby:https://server.example.com|7")
        #expect(key(.plex) == "plex:https://server.example.com|7")
    }

    // MARK: Factory

    @Test("Die Fabrik baut für Jellyfin einen Client mit kind und allen Fähigkeiten")
    func factoryJellyfin() throws {
        let server = try #require(make())
        #expect(server.kind == .jellyfin)
        #expect(server.baseURL == url)
        #expect(server.capabilities == Set(ServerCapability.allCases))
        #expect(server is JellyfinClient)
    }

    @Test("Für Emby baut die Fabrik einen Client der Art Emby")
    func factoryEmby() throws {
        let server = try #require(make(kind: .emby))
        #expect(server.kind == .emby)
        #expect(server is JellyfinClient)
    }

    @Test("Für Plex baut die Fabrik einen Plex-Client mit eigener Fähigkeitenmenge")
    func factoryPlex() throws {
        let server = try #require(make(kind: .plex))
        #expect(server.kind == .plex)
        #expect(server is PlexClient)
        #expect(server.capabilities == PlexFeatures.capabilities)
    }

    @Test("Aus einer Sitzung nimmt die Fabrik Art und Adresse")
    func factoryFromSession() async throws {
        let session = Session(accessToken: "t", userID: "1", userName: "p", serverURL: url)
        let server = try #require(MediaServerFactory.make(session: session, deviceID: "d", deviceName: "n"))
        #expect(server.kind == .jellyfin)
        #expect(await server.currentSession() == session)
        #expect(await server.signedOutCopy().currentSession() == nil)
    }

    @Test("Die Jellyfin-Zusätze sind über as? erreichbar")
    func helperProtocols() throws {
        let server = try #require(make())
        #expect(server is any QuickSignIn)
        #expect(server is any RemoteSessionServer)
        #expect(server is any DisplayPreferencesServer)
    }

    @Test("Parameter-Vorgaben gelten auch über any MediaServer")
    func defaultsThroughExistential() async throws {
        let server = try #require(make())
        // Without a session the call fails before any request goes out; it must compile
        // with the short form and reach the client's own method.
        await #expect(throws: (any Error).self) { _ = try await server.items(parentID: "x") }
        await #expect(throws: (any Error).self) { _ = try await server.resumeItems() }
    }

    // MARK: Capabilities

    @Test("Die Tabelle je Art deckt sich mit dem Client")
    func capabilityTable() throws {
        let server = try #require(make())
        #expect(server.capabilities == ServerKind.jellyfin.capabilities)
        #expect(ServerKind.emby.capabilities == ServerKind.embyCapabilities)
        #expect(ServerKind.plex.capabilities == PlexFeatures.capabilities)
    }

    // MARK: ItemKind

    @Test("ItemKind liest die Serverwörter")
    func itemKinds() {
        #expect(ItemKind(type: "Movie") == .movie)
        #expect(ItemKind(type: "Series") == .series)
        #expect(ItemKind(type: "Season") == .season)
        #expect(ItemKind(type: "Episode") == .episode)
        #expect(ItemKind(type: "BoxSet") == .collection)
        #expect(ItemKind(type: "Playlist") == .playlist)
        #expect(ItemKind(type: "CollectionFolder") == .folder)
        #expect(ItemKind(type: nil) == .other)
        #expect(ItemKind(type: "Audio") == .other)
    }

    // MARK: ServerBundles

    private func bundle(_ kind: ServerKind, _ id: String) -> AccountBundle {
        AccountBundle(Session(accessToken: "t\(id)", userID: id, userName: "u\(id)", serverURL: url, kind: kind))
    }

    @Test("Der Jellyfin-Speicherplatz bleibt konten, die anderen tragen die Art im Namen")
    func storageKeys() {
        #expect(ServerKind.jellyfin.bundleStorageKey == "konten")
        #expect(ServerKind.emby.bundleStorageKey == "konten.emby")
        #expect(ServerKind.plex.bundleStorageKey == "konten.plex")
    }

    @Test("Das Jellyfin-Bündel hat dieselben Schlüssel und Werte wie ein einzelnes AccountBundle")
    func jellyfinBundleByteEqual() throws {
        let single = bundle(.jellyfin, "1")
        var written: [String: Data] = [:]
        try ServerBundles(bundles: [.jellyfin: single]).save { key, data in written[key] = data }
        // Key order is not fixed by JSONEncoder, so compare what the bytes say.
        let mine = try JSONSerialization.jsonObject(with: try #require(written["konten"])) as? NSDictionary
        let plain = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(single)) as? NSDictionary
        #expect(mine != nil && mine == plain)
        #expect(Set(mine?.allKeys as? [String] ?? []) == ["konten", "aktiveKennung"])
        #expect(written["konten.emby"] == nil)
        #expect(written["aktiveArt"] == Data("jellyfin".utf8))
    }

    @Test("Mehrere Arten übersteht Speichern und Laden samt Zeiger")
    func roundTrip() throws {
        var all = ServerBundles(bundles: [.jellyfin: bundle(.jellyfin, "1"), .plex: bundle(.plex, "2")],
                                activeKind: .plex)
        #expect(all.activeKind == .plex)
        var store: [String: Data] = [:]
        try all.save { key, data in store[key] = data }
        let back = ServerBundles.load { store[$0] }
        #expect(back == all)
        #expect(back.active?.activeOne.kind == .plex)
        all.switchTo(.emby) // no bundle of that kind: ignored
        #expect(all.activeKind == .plex)
        all.set(nil, for: .plex)
        #expect(all.activeKind == .jellyfin)
        #expect(all.kinds == [.jellyfin])
    }

    @Test("Ohne Zeiger, mit beschädigtem Eintrag: Jellyfin gilt, Kaputtes zählt als fehlend")
    func loadTolerant() throws {
        let good = try JSONEncoder().encode(bundle(.jellyfin, "1"))
        let loaded = ServerBundles.load { key in
            key == "konten" ? good : key == "konten.plex" ? Data("kaputt".utf8) : nil
        }
        #expect(loaded.kinds == [.jellyfin])
        #expect(loaded.activeKind == .jellyfin)
    }
}
