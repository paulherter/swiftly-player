import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

/// Custom headers for servers behind a gateway proxy (issue #4).
///
/// **All values are made up**, and each test uses its own host
/// under `.test`: the table is shared, and tests of other suites running
/// in parallel must not notice any of it.
/// **The table of custom headers is shared process-wide.** `load` replaces
/// it entirely; when the storage test ran next to a forwarder test, that
/// test's entry was gone, the gateway answered 403, and the test failed,
/// regularly under load. The suites that touch it therefore run
/// one after the other.
@Suite("Geteilte Kopftafel", .serialized)
enum SharedHeaderPanel {}

extension SharedHeaderPanel {
@Suite("Eigene Köpfe", .serialized)
struct OwnHeadersTests {

    // MARK: The gate

    @Test("Leere, kaputte, gesperrte und doppelte Einträge fallen heraus")
    func cleaned() {
        let raw = [
            OwnHeader(name: " CF-Access-Client-Id ", value: " id.access "),
            OwnHeader(name: "", value: "ohne-namen"),
            OwnHeader(name: "Ohne-Wert", value: "   "),
            OwnHeader(name: "Mit Leerzeichen", value: "x"),
            OwnHeader(name: "Doppel:punkt", value: "x"),
            OwnHeader(name: "Authorization", value: "Bearer fremd"),
            OwnHeader(name: "x-emby-token", value: "fremd"),
            OwnHeader(name: "Cookie", value: "a=b"),
            OwnHeader(name: "X-Umbruch", value: "a\r\nX-Boese: 1"),
            OwnHeader(name: "cf-access-client-id", value: "zweiter"),
            OwnHeader(name: "P-Access-Token", value: "erfunden"),
        ]
        let clean = OwnHeaders.cleaned(raw)
        #expect(clean == [OwnHeader(name: "CF-Access-Client-Id", value: "id.access"),
                           OwnHeader(name: "P-Access-Token", value: "erfunden")])
    }

    @Test("Gesperrt ist unabhängig von der Schreibweise")
    func locked() {
        #expect(OwnHeaders.isLocked("AUTHORIZATION"))
        #expect(OwnHeaders.isLocked(" X-Emby-Authorization"))
        #expect(!OwnHeaders.isLocked("CF-Access-Client-Secret"))
        #expect(!OwnHeaders.isLocked("User-Agent"))
    }

    @Test("Das Protokoll bekommt Namen, nie Werte")
    func namesLog() {
        let z = OwnHeaders.names([OwnHeader(name: "CF-Access-Client-Secret", value: "streng-geheim")])
        #expect(z == "CF-Access-Client-Secret")
        #expect(!z.contains("streng-geheim"))
    }

    // MARK: Where they go

    @Test("Nur an den eigenen Server, nicht an TMDB")
    func onlyAnOwnServer() {
        let base = URL(string: "https://jf.eins.test")!
        OwnHeaders.setDown([OwnHeader(name: "X-Tor", value: "auf")], for: base)
        defer { OwnHeaders.setDown([], for: base) }

        #expect(OwnHeaders.of(URL(string: "https://jf.eins.test/Items/1/Images/Primary?tag=a")!).count == 1)
        #expect(OwnHeaders.of(URL(string: "https://JF.eins.test:443/System/Info")!).count == 1)
        #expect(OwnHeaders.of(URL(string: "https://image.tmdb.org/t/p/w342/a.jpg")!).isEmpty)
        #expect(OwnHeaders.of(URL(string: "http://jf.eins.test/System/Info")!).isEmpty,
                "anderes Schema, anderer Ursprung")
        #expect(OwnHeaders.of(URL(string: "https://jf.eins.test:8920/System/Info")!).isEmpty,
                "anderer Port")
        #expect(OwnHeaders.of(URL(string: "https://jf.eins.test.boese.test/")!).isEmpty)
    }

    @Test("Der Steuerkanal zählt zum Server: wss wie https")
    func websocketCountsWith() {
        let base = URL(string: "https://jf.zwei.test")!
        OwnHeaders.setDown([OwnHeader(name: "X-Tor", value: "auf")], for: base)
        defer { OwnHeaders.setDown([], for: base) }
        #expect(OwnHeaders.of(URL(string: "wss://jf.zwei.test/socket?api_key=x")!).count == 1)
    }

    @Test("Unter einem Pfad gilt nur der Pfad, und die längste Basis gewinnt")
    func basePath() {
        let jf = URL(string: "https://proxy.drei.test/jellyfin/")!
        let seerr = URL(string: "https://proxy.drei.test/jellyfin/seerr")!
        OwnHeaders.setDown([OwnHeader(name: "X-Wer", value: "jf")], for: jf)
        OwnHeaders.setDown([OwnHeader(name: "X-Wer", value: "seerr")], for: seerr)
        defer { OwnHeaders.setDown([], for: jf); OwnHeaders.setDown([], for: seerr) }

        #expect(OwnHeaders.fields(for: URL(string: "https://proxy.drei.test/jellyfin/Items")!) == ["X-Wer": "jf"])
        #expect(OwnHeaders.fields(for: URL(string: "https://proxy.drei.test/jellyfin/seerr/api")!) == ["X-Wer": "seerr"])
        #expect(OwnHeaders.of(URL(string: "https://proxy.drei.test/jellyfinx/Items")!).isEmpty)
        #expect(OwnHeaders.of(URL(string: "https://proxy.drei.test/anderes")!).isEmpty)
        #expect(OwnHeaders.of(URL(string: "https://proxy.drei.test/jellyfin/../anderes")!).isEmpty)
    }

    @Test("Eine leere Liste nimmt den Server heraus")
    func emptyTakesFromOut() {
        let base = URL(string: "https://jf.vier.test")!
        OwnHeaders.setDown([OwnHeader(name: "X-Tor", value: "auf")], for: base)
        OwnHeaders.setDown([], for: base)
        #expect(OwnHeaders.registered(for: base).isEmpty)
        var req = URLRequest(url: URL(string: "https://jf.vier.test/System/Info")!)
        req.ownHeadersSet()
        #expect(req.allHTTPHeaderFields?.isEmpty ?? true, "ohne Eintrag bleibt die Anfrage unberührt")
    }

    // MARK: Storage

    @Test("Die Tafel übersteht das Ablegen, Kaputtes nicht")
    func store() {
        let base = URL(string: "https://jf.fuenf.test/")!
        OwnHeaders.setDown([OwnHeader(name: "X-Tor", value: "auf")], for: base)
        let stored = OwnHeaders.store()
        OwnHeaders.setDown([], for: base)
        #expect(OwnHeaders.registered(for: base).isEmpty)

        OwnHeaders.load(stored)
        #expect(OwnHeaders.registered(for: base) == [OwnHeader(name: "X-Tor", value: "auf")])
        OwnHeaders.setDown([], for: base)

        OwnHeaders.load(Data("kein json".utf8))
        #expect(OwnHeaders.registered(for: base).isEmpty)
    }

    // MARK: The client

    final class Spy: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var withCut: URLRequest?
        nonisolated(unsafe) static var html = false

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            Self.withCut = request
            let art = Self.html ? "text/html" : "application/json"
            let shell = Self.html ? "<html>Sign in</html>" : #"{"ServerName":"Test","Version":"10.11.0","Id":"s"}"#
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": art])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(shell.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func clientApi(_ base: URL) -> JellyfinClient {
        let k = URLSessionConfiguration.ephemeral
        k.protocolClasses = [Spy.self]
        return JellyfinClient(baseURL: base, deviceID: "dev", deviceName: "Test",
                              urlSession: URLSession(configuration: k))
    }

    @Test("Jede Anfrage an Jellyfin trägt sie — und das eigene Merkmal bleibt")
    func clientSendsHeaders() async throws {
        let base = URL(string: "https://jf.sechs.test")!
        OwnHeaders.setDown([OwnHeader(name: "CF-Access-Client-Id", value: "erfunden.access"),
                            OwnHeader(name: "Authorization", value: "Bearer fremd")], for: base)
        defer { OwnHeaders.setDown([], for: base) }
        Spy.html = false
        _ = try await clientApi(base).publicSystemInfo()
        let req = try #require(Spy.withCut)
        #expect(req.value(forHTTPHeaderField: "CF-Access-Client-Id") == "erfunden.access")
        #expect(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("MediaBrowser ") == true)
    }

    @Test("HTML statt JSON heisst: ein Vorposten hat geantwortet")
    func loginPageClient() async {
        Spy.html = true
        defer { Spy.html = false }
        do {
            _ = try await clientApi(URL(string: "https://jf.sieben.test")!).publicSystemInfo()
            Issue.record("haette scheitern muessen")
        } catch {
            #expect(readableError(error) == OwnHeaders.loginPageText)
        }
    }
}
}
