import Foundation
import Testing
@testable import JellyfinKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// „Weiteres Konto hinzufügen": das neue Konto meldet sich an, ohne dem
/// angemeldeten Client das Merkmal wegzunehmen. Sonst ginge das Aufräumen
/// für das alte Konto (Gruppe verlassen) im Namen des neuen raus.
@Suite("Konto hinzufügen", .serialized)
struct KontoHinzufuegenTests {

    final class Ersatzserver: URLProtocol, @unchecked Sendable {
        struct Aufruf: Sendable { let pfad: String; let kopf: String }
        nonisolated(unsafe) static var aufrufe: [Aufruf] = []
        static let sperre = NSLock()

        static func zuruecksetzen() { sperre.withLock { aufrufe = [] } }
        static func kopf(_ pfad: String) -> [String] {
            sperre.withLock { aufrufe.filter { $0.pfad == pfad }.map(\.kopf) }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

        override func startLoading() {
            let pfad = String(request.url!.path.dropFirst())
            let kopf = request.value(forHTTPHeaderField: "Authorization") ?? ""
            Self.sperre.withLock { Self.aufrufe.append(.init(pfad: pfad, kopf: kopf)) }
            let body: Data
            let status: Int
            if pfad == "Users/AuthenticateByName" {
                status = 200
                body = Data(#"{"AccessToken":"merkmal-b","ServerId":"s1","User":{"Id":"konto-b","Name":"B"}}"#.utf8)
            } else {
                status = 204
                body = Data()
            }
            let antwort = HTTPURLResponse(url: request.url!, statusCode: status,
                                          httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: antwort, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private static let server = URL(string: "https://tv.example.de")!

    private static func angemeldet() -> JellyfinClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Ersatzserver.self]
        return JellyfinClient(baseURL: server, deviceID: "dev-1", deviceName: "Prueflauf",
                              session: .init(accessToken: "merkmal-a", userID: "konto-a",
                                             userName: "A", serverURL: server),
                              urlSession: URLSession(configuration: config))
    }

    @Test func neuesKontoLaesstDenAltenClientStehen() async throws {
        Ersatzserver.zuruecksetzen()
        let alt = Self.angemeldet()
        let neu = alt.ohneKonto()
        #expect(neu !== alt)
        #expect(await neu.currentSession() == nil)

        let s = try await neu.authenticate(username: "b", password: "x")
        #expect(s.userID == "konto-b")
        #expect(await neu.currentSession()?.accessToken == "merkmal-b")
        #expect(await alt.currentSession()?.accessToken == "merkmal-a")

        // Was danach noch über den alten Client geht (das Verlassen der
        // Gruppe), trägt dessen Merkmal.
        _ = await alt.sitzungGiltNoch()
        let koepfe = Ersatzserver.sperre.withLock { Ersatzserver.aufrufe }
            .filter { $0.pfad != "Users/AuthenticateByName" }.map(\.kopf)
        #expect(!koepfe.isEmpty)
        #expect(koepfe.allSatisfy { $0.contains("merkmal-a") })
    }

    @Test func gleicheGeraetekennungUndServer() async throws {
        Ersatzserver.zuruecksetzen()
        let neu = Self.angemeldet().ohneKonto()
        #expect(neu.baseURL == Self.server)
        _ = try await neu.authenticate(username: "b", password: "x")
        let kopf = Ersatzserver.kopf("Users/AuthenticateByName").first ?? ""
        #expect(kopf.contains("DeviceId=\"dev-1\""))
        #expect(!kopf.contains("merkmal-a"))
    }
}
