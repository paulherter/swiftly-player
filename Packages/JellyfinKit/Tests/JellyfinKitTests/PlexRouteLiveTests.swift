import Foundation
import Testing
@testable import JellyfinKit

@Suite("Plex: Adresse und Token folgen dem Client")
struct PlexRouteLiveTests {
    @Test("Nach dem Wechsel liefert der Client neue Adresse und neues Token, die gespeicherte Sitzung bleibt alt")
    func clientFollowsMove() async throws {
        let old = URL(string: "http://10.0.0.5:32400")!
        let new = URL(string: "https://relay.example:443")!
        let session = Session(accessToken: "old", userID: "1", userName: "me", serverURL: old, kind: .plex,
            plex: PlexSessionDetails(machineIdentifier: "m", serverName: "s", accountToken: "acc", isLocal: true))
        let identity = PlexIdentity(clientID: "t", platform: "macOS", device: "Mac", deviceName: "Mac")
        let resolver: PlexClient.Resolver = { _ in
            PlexResolvedRoute(connection: PlexChosenConnection(machineIdentifier: "m", uri: new, isLocal: false, isRelay: true), token: "fresh")
        }
        let client = PlexClient(session: session, identity: identity, resolver: resolver)
        #expect(client.baseURL == old)
        #expect(client.accessToken == "old")
        #expect(try await client.chooseBestConnection())
        #expect(client.baseURL == new)
        #expect(client.accessToken == "fresh")
        let picture = client.imageURL(path: "/library/metadata/1/thumb/2", maxHeight: 100)
        #expect(picture?.host == "relay.example")
        #expect(picture?.absoluteString.contains("fresh") == true)
        #expect(session.serverURL == old)
    }
}
