import Foundation
import Testing
@testable import JellyfinKit
#if os(macOS)
@Suite("Plex: gemerkte Adresse", .serialized, .enabled(if: PlexLocal.available))
struct PlexRouteTests {
    @Test("Schweigt die gemerkte Adresse, wechselt die erste Anfrage nach wenigen Sekunden")
    func staleRoute() async throws {
        let token = try #require(PlexLocal.token)
        let dead = URL(string: "http://10.255.255.1:32400")!
        let session = Session(accessToken: token, userID: "1", userName: "me", serverURL: dead, kind: .plex,
            plex: PlexSessionDetails(machineIdentifier: "local", serverName: "local", accountToken: token, isLocal: true))
        let identity = PlexIdentity(clientID: "t", platform: "macOS", device: "Mac", deviceName: "Mac")
        let resolver: PlexClient.Resolver = { _ in
            PlexResolvedRoute(connection: PlexChosenConnection(machineIdentifier: "local", uri: PlexLocal.url, isLocal: true, isRelay: false), token: token)
        }
        let c = PlexClient(session: session, identity: identity, resolver: resolver)
        let t = ContinuousClock.now
        _ = try await c.sections()
        #expect(ContinuousClock.now - t < .seconds(8))
    }
}
#endif
