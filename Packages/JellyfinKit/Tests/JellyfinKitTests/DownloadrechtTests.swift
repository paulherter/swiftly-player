import Foundation
import Testing
// Auf Linux liegt URLSession nicht in Foundation, sondern in einem eigenen
// Modul. Auf Apple-Plattformen gibt es das Modul nicht — der Import ist
// deshalb bedingt und dort wirkungslos.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

// .serialized, weil sich die drei Client-Tests den statischen Stand der
// Antwortstelle teilen — parallel ueberschreiben sie sich gegenseitig, und
// dann prueft der eine das Recht des anderen.
@Suite("Downloadrecht", .serialized)
struct DownloadrechtTests {

    @Test("Drei Faelle: nichts gesagt, erlaubt, verboten")
    func vomServer() {
        #expect(Downloadrecht.vomServer(nil) == .unbekannt)
        #expect(Downloadrecht.vomServer(true) == .erlaubt)
        #expect(Downloadrecht.vomServer(false) == .verboten)
    }

    /// **Ein Netzfehler darf nichts wegnehmen.** Nur ein ausdrueckliches
    /// `false` sperrt.
    @Test("Unbekannt gilt als erlaubt")
    func unbekanntErlaubt() {
        #expect(Downloadrecht.unbekannt.darfLaden)
        #expect(Downloadrecht.erlaubt.darfLaden)
        #expect(!Downloadrecht.verboten.darfLaden)
    }

    @Test("Knopf nur mit Schalter und Recht")
    func anbieten() {
        #expect(Downloadrecht.anbieten(recht: .erlaubt, funktionAn: true))
        #expect(Downloadrecht.anbieten(recht: .unbekannt, funktionAn: true))
        #expect(!Downloadrecht.anbieten(recht: .verboten, funktionAn: true))
        // Ohne den Schalter gibt es die Funktion ueberhaupt nicht — H1.
        #expect(!Downloadrecht.anbieten(recht: .erlaubt, funktionAn: false))
        #expect(!Downloadrecht.anbieten(recht: .unbekannt, funktionAn: false))
        #expect(!Downloadrecht.anbieten(recht: .verboten, funktionAn: false))
    }

    @Test("EnableContentDownloading aus /Users/{id}")
    func ausDerAntwort() throws {
        func lesen(_ json: String) throws -> Kontovorgaben {
            try JSONDecoder().decode(Kontovorgaben.self, from: Data(json.utf8))
        }
        let verboten = try lesen(#"{"Id":"x","Policy":{"EnableContentDownloading":false}}"#)
        #expect(verboten.downloadsErlaubt == false)
        #expect(verboten.downloadrecht == .verboten)

        let erlaubt = try lesen(#"{"Id":"x","Policy":{"EnableContentDownloading":true}}"#)
        #expect(erlaubt.downloadrecht == .erlaubt)

        // Aelterer Server, kein Policy-Block: nichts gesagt, also erlaubt.
        #expect(try lesen(#"{"Id":"x"}"#).downloadrecht == .unbekannt)

        // **Beide Bloecke unabhaengig.** Ohne Configuration darf Policy nicht
        // mitverloren gehen und umgekehrt.
        let nurRecht = try lesen(#"{"Id":"x","Policy":{"EnableContentDownloading":false}}"#)
        #expect(nurRecht.naechsteFolgeAutomatisch == nil)
        let nurWahl = try lesen(#"{"Id":"x","Configuration":{"EnableNextEpisodeAutoPlay":false}}"#)
        #expect(nurWahl.naechsteFolgeAutomatisch == false)
        #expect(nurWahl.downloadrecht == .unbekannt)
    }

    // MARK: - Der Riegel in der Adresse

    /// Antwortet auf jede Anfrage mit einem Konto, dessen Recht in
    /// ``Antwortstelle/recht`` steht. Kein Netz, kein Server.
    final class Antwortstelle: URLProtocol, @unchecked Sendable {
        /// `"true"`, `"false"` oder leer (kein `Policy`-Block).
        nonisolated(unsafe) static var recht = ""

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

        override func startLoading() {
            let politik = Self.recht.isEmpty ? ""
                : #","Policy":{"EnableContentDownloading":\#(Self.recht)}"#
            let body = Data(#"{"Id":"u1"\#(politik)}"#.utf8)
            let antwort = HTTPURLResponse(url: request.url!, statusCode: 200,
                                          httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: antwort, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func client(recht: String) -> JellyfinClient {
        Antwortstelle.recht = recht
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Antwortstelle.self]
        return JellyfinClient(baseURL: URL(string: "https://tv.example.de")!,
                              deviceID: "dev-42", deviceName: "Prueflauf",
                              session: .init(accessToken: "tok", userID: "u1",
                                             userName: "nutzer",
                                             serverURL: URL(string: "https://tv.example.de")!),
                              urlSession: URLSession(configuration: config))
    }

    /// **Der Riegel, nicht die Oberflaeche.** Ohne ihn kaeme jeder andere Weg
    /// zur Datei weiterhin durch — eine wieder aufgenommene Schlange etwa.
    @Test("Verboten: keine Adresse, sondern 403")
    func keineAdresseWennVerboten() async throws {
        let c = client(recht: "false")
        _ = await c.kontovorgaben()
        #expect(await c.downloadrecht() == .verboten)
        await #expect(throws: JellyfinError.http(status: 403, body: "EnableContentDownloading")) {
            _ = try await c.downloadURL(itemID: "abc", mediaSourceID: nil)
        }
    }

    @Test("Erlaubt und unbekannt geben eine Adresse")
    func adresseWennErlaubt() async throws {
        for (recht, erwartet) in [("true", Downloadrecht.erlaubt), ("", .unbekannt)] {
            let c = client(recht: recht)
            _ = await c.kontovorgaben()
            #expect(await c.downloadrecht() == erwartet)
            let adresse = try await c.downloadURL(itemID: "abc", mediaSourceID: nil)
            #expect(adresse.absoluteString.contains("abc"))
        }
    }

    /// Das Recht haengt am Konto: nach einem Wechsel gilt wieder
    /// „nichts gesagt", nicht die Sperre des vorigen Kontos.
    @Test("Kontowechsel setzt das Recht zurueck")
    func kontowechsel() async throws {
        let c = client(recht: "false")
        _ = await c.kontovorgaben()
        #expect(await c.downloadrecht() == .verboten)
        await c.setSession(.init(accessToken: "tok2", userID: "u2", userName: "Zweit",
                                 serverURL: URL(string: "https://tv.example.de")!))
        #expect(await c.downloadrecht() == .unbekannt)
    }
}
