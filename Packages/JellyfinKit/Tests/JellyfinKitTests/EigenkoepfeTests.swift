import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

/// Eigene Köpfe für Server hinter einem Vorposten (Issue #4).
///
/// **Alle Werte sind erfunden**, und jeder Test nimmt einen eigenen Rechner
/// unter `.test`: die Tafel ist geteilt, und parallel laufende Tests anderer
/// Suiten dürfen davon nichts merken.
@Suite("Eigene Köpfe", .serialized)
struct EigenkoepfeTests {

    // MARK: Die Schleuse

    @Test("Leere, kaputte, gesperrte und doppelte Einträge fallen heraus")
    func bereinigt() {
        let roh = [
            Eigenkopf(name: " CF-Access-Client-Id ", wert: " id.access "),
            Eigenkopf(name: "", wert: "ohne-namen"),
            Eigenkopf(name: "Ohne-Wert", wert: "   "),
            Eigenkopf(name: "Mit Leerzeichen", wert: "x"),
            Eigenkopf(name: "Doppel:punkt", wert: "x"),
            Eigenkopf(name: "Authorization", wert: "Bearer fremd"),
            Eigenkopf(name: "x-emby-token", wert: "fremd"),
            Eigenkopf(name: "Cookie", wert: "a=b"),
            Eigenkopf(name: "X-Umbruch", wert: "a\r\nX-Boese: 1"),
            Eigenkopf(name: "cf-access-client-id", wert: "zweiter"),
            Eigenkopf(name: "P-Access-Token", wert: "erfunden"),
        ]
        let sauber = Eigenkoepfe.bereinigt(roh)
        #expect(sauber == [Eigenkopf(name: "CF-Access-Client-Id", wert: "id.access"),
                           Eigenkopf(name: "P-Access-Token", wert: "erfunden")])
    }

    @Test("Gesperrt ist unabhängig von der Schreibweise")
    func gesperrt() {
        #expect(Eigenkoepfe.istGesperrt("AUTHORIZATION"))
        #expect(Eigenkoepfe.istGesperrt(" X-Emby-Authorization"))
        #expect(!Eigenkoepfe.istGesperrt("CF-Access-Client-Secret"))
        #expect(!Eigenkoepfe.istGesperrt("User-Agent"))
    }

    @Test("Das Protokoll bekommt Namen, nie Werte")
    func namenFuersProtokoll() {
        let z = Eigenkoepfe.namen([Eigenkopf(name: "CF-Access-Client-Secret", wert: "streng-geheim")])
        #expect(z == "CF-Access-Client-Secret")
        #expect(!z.contains("streng-geheim"))
    }

    // MARK: Wohin sie gehen

    @Test("Nur an den eigenen Server, nicht an TMDB")
    func nurAnDenEigenenServer() {
        let basis = URL(string: "https://jf.eins.test")!
        Eigenkoepfe.setzen([Eigenkopf(name: "X-Tor", wert: "auf")], fuer: basis)
        defer { Eigenkoepfe.setzen([], fuer: basis) }

        #expect(Eigenkoepfe.fuer(URL(string: "https://jf.eins.test/Items/1/Images/Primary?tag=a")!).count == 1)
        #expect(Eigenkoepfe.fuer(URL(string: "https://JF.eins.test:443/System/Info")!).count == 1)
        #expect(Eigenkoepfe.fuer(URL(string: "https://image.tmdb.org/t/p/w342/a.jpg")!).isEmpty)
        #expect(Eigenkoepfe.fuer(URL(string: "http://jf.eins.test/System/Info")!).isEmpty,
                "anderes Schema, anderer Ursprung")
        #expect(Eigenkoepfe.fuer(URL(string: "https://jf.eins.test:8920/System/Info")!).isEmpty,
                "anderer Port")
        #expect(Eigenkoepfe.fuer(URL(string: "https://jf.eins.test.boese.test/")!).isEmpty)
    }

    @Test("Der Steuerkanal zählt zum Server: wss wie https")
    func websocketZaehltMit() {
        let basis = URL(string: "https://jf.zwei.test")!
        Eigenkoepfe.setzen([Eigenkopf(name: "X-Tor", wert: "auf")], fuer: basis)
        defer { Eigenkoepfe.setzen([], fuer: basis) }
        #expect(Eigenkoepfe.fuer(URL(string: "wss://jf.zwei.test/socket?api_key=x")!).count == 1)
    }

    @Test("Unter einem Pfad gilt nur der Pfad, und die längste Basis gewinnt")
    func basispfad() {
        let jf = URL(string: "https://proxy.drei.test/jellyfin/")!
        let seerr = URL(string: "https://proxy.drei.test/jellyfin/seerr")!
        Eigenkoepfe.setzen([Eigenkopf(name: "X-Wer", wert: "jf")], fuer: jf)
        Eigenkoepfe.setzen([Eigenkopf(name: "X-Wer", wert: "seerr")], fuer: seerr)
        defer { Eigenkoepfe.setzen([], fuer: jf); Eigenkoepfe.setzen([], fuer: seerr) }

        #expect(Eigenkoepfe.felder(fuer: URL(string: "https://proxy.drei.test/jellyfin/Items")!) == ["X-Wer": "jf"])
        #expect(Eigenkoepfe.felder(fuer: URL(string: "https://proxy.drei.test/jellyfin/seerr/api")!) == ["X-Wer": "seerr"])
        #expect(Eigenkoepfe.fuer(URL(string: "https://proxy.drei.test/jellyfinx/Items")!).isEmpty)
        #expect(Eigenkoepfe.fuer(URL(string: "https://proxy.drei.test/anderes")!).isEmpty)
        #expect(Eigenkoepfe.fuer(URL(string: "https://proxy.drei.test/jellyfin/../anderes")!).isEmpty)
    }

    @Test("Eine leere Liste nimmt den Server heraus")
    func leerNimmtHeraus() {
        let basis = URL(string: "https://jf.vier.test")!
        Eigenkoepfe.setzen([Eigenkopf(name: "X-Tor", wert: "auf")], fuer: basis)
        Eigenkoepfe.setzen([], fuer: basis)
        #expect(Eigenkoepfe.eingetragen(fuer: basis).isEmpty)
        var req = URLRequest(url: URL(string: "https://jf.vier.test/System/Info")!)
        req.eigeneKoepfeSetzen()
        #expect(req.allHTTPHeaderFields?.isEmpty ?? true, "ohne Eintrag bleibt die Anfrage unberührt")
    }

    // MARK: Ablage

    @Test("Die Tafel übersteht das Ablegen, Kaputtes nicht")
    func ablage() {
        let basis = URL(string: "https://jf.fuenf.test/")!
        Eigenkoepfe.setzen([Eigenkopf(name: "X-Tor", wert: "auf")], fuer: basis)
        let abgelegt = Eigenkoepfe.ablage()
        Eigenkoepfe.setzen([], fuer: basis)
        #expect(Eigenkoepfe.eingetragen(fuer: basis).isEmpty)

        Eigenkoepfe.laden(abgelegt)
        #expect(Eigenkoepfe.eingetragen(fuer: basis) == [Eigenkopf(name: "X-Tor", wert: "auf")])
        Eigenkoepfe.setzen([], fuer: basis)

        Eigenkoepfe.laden(Data("kein json".utf8))
        #expect(Eigenkoepfe.eingetragen(fuer: basis).isEmpty)
    }

    // MARK: Der Klient

    final class Spy: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var mitgeschnitten: URLRequest?
        nonisolated(unsafe) static var html = false

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            Self.mitgeschnitten = request
            let art = Self.html ? "text/html" : "application/json"
            let rumpf = Self.html ? "<html>Sign in</html>" : #"{"ServerName":"Test","Version":"10.11.0","Id":"s"}"#
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": art])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(rumpf.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func klient(_ basis: URL) -> JellyfinClient {
        let k = URLSessionConfiguration.ephemeral
        k.protocolClasses = [Spy.self]
        return JellyfinClient(baseURL: basis, deviceID: "dev", deviceName: "Test",
                              urlSession: URLSession(configuration: k))
    }

    @Test("Jede Anfrage an Jellyfin trägt sie — und das eigene Merkmal bleibt")
    func klientSendetKoepfe() async throws {
        let basis = URL(string: "https://jf.sechs.test")!
        Eigenkoepfe.setzen([Eigenkopf(name: "CF-Access-Client-Id", wert: "erfunden.access"),
                            Eigenkopf(name: "Authorization", wert: "Bearer fremd")], fuer: basis)
        defer { Eigenkoepfe.setzen([], fuer: basis) }
        Spy.html = false
        _ = try await klient(basis).publicSystemInfo()
        let req = try #require(Spy.mitgeschnitten)
        #expect(req.value(forHTTPHeaderField: "CF-Access-Client-Id") == "erfunden.access")
        #expect(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("MediaBrowser ") == true)
    }

    @Test("HTML statt JSON heisst: ein Vorposten hat geantwortet")
    func anmeldeseiteBeimKlienten() async {
        Spy.html = true
        defer { Spy.html = false }
        do {
            _ = try await klient(URL(string: "https://jf.sieben.test")!).publicSystemInfo()
            Issue.record("haette scheitern muessen")
        } catch {
            #expect(lesbarerFehler(error) == Eigenkoepfe.anmeldeseiteText)
        }
    }
}
