import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import JellyfinKit

/// Teil 1 N3: zwei Fehlertext-Regeln, und `send` machte aus dem Netzfehler
/// Text. Geprüft wird die Aussage, nicht der Wortlaut (die Tests laufen in
/// der Sprache des Rechners).
@Suite struct FehlerartTests {

    @Test(arguments: [-1001, -1003, -1004, -1005, -1009])
    func netzfehlerBehaeltSeinenCode(code: Int) {
        let j = JellyfinError(anfrage: NSError(domain: NSURLErrorDomain, code: code))
        #expect(j == .netz(code: code))
        #expect(j.urlFehlercode?.rawValue == code)
    }

    @Test func fremderFehlerBleibtTransport() {
        struct Eigen: Error {}
        if case .transport = JellyfinError(anfrage: Eigen()) {} else {
            Issue.record("kein transport")
        }
    }

    /// Derselbe Satz, ob der Code roh kommt oder im Paketfehler steckt.
    @Test(arguments: [-1001, -1003, -1004, -1005, -1009])
    func netzfehlerGleichGelesen(code: Int) {
        let roh = lesbarerFehler(NSError(domain: NSURLErrorDomain, code: code))
        #expect(lesbarerFehler(JellyfinError.netz(code: code)) == roh)
    }

    @Test func zeitueberschreitungUndKeinServerSindVerschieden() {
        #expect(lesbarerFehler(JellyfinError.netz(code: URLError.Code.timedOut.rawValue))
                != lesbarerFehler(JellyfinError.netz(code: URLError.Code.cannotFindHost.rawValue)))
    }

    /// Eine Regel: `localizedDescription` zeigt dasselbe wie `lesbarerFehler`.
    @Test(arguments: [
        JellyfinError.netz(code: -1001), .http(status: 401, body: nil), .http(status: 502, body: "x"),
        .decoding("keyNotFound(CodingKeys(stringValue: \"Id\"))"), .invalidServerURL,
        .notAuthenticated, .noPlayableSource, .transport("Eigener Satz."),
    ])
    func eineRegel(fehler: JellyfinError) {
        #expect(fehler.localizedDescription == lesbarerFehler(fehler))
    }

    @Test func decoderTextErreichtDenNutzerNicht() {
        let text = lesbarerFehler(JellyfinError.decoding("keyNotFound(CodingKeys(stringValue: \"Id\"))"))
        #expect(!text.contains("keyNotFound"))
        #expect(!text.isEmpty)
    }

    @Test func antwortkoerperErreichtDenNutzerNicht() {
        let text = lesbarerFehler(JellyfinError.http(status: 500, body: "Stapel geheim"))
        #expect(!text.contains("geheim"))
    }
}

/// Teil 2 M9: ein Warte-Ablauf für alle. Kurze Zeiten statt fünf Minuten.
@Suite struct QuickconnectwartenTests {

    actor Antworten {
        var folge: [Quickconnectstand]
        var gefragt = 0
        init(_ folge: [Quickconnectstand]) { self.folge = folge }
        func naechste() -> Quickconnectstand {
            gefragt += 1
            return folge.isEmpty ? .offen : folge.removeFirst()
        }
    }

    static func ende(_ strom: AsyncStream<Quickconnectwarten.Ereignis>) async -> Quickconnectwarten.Ereignis? {
        var letztes: Quickconnectwarten.Ereignis?
        for await e in strom { if case .rest = e { continue }; letztes = e }
        return letztes
    }

    @Test func netzfehlerBeendetDasWartenNicht() async {
        let a = Antworten([.gescheitert, .gescheitert, .offen, .freigegeben])
        let strom = Quickconnectwarten.ablauf(frist: .seconds(5), takt: .milliseconds(20),
                                              tick: .milliseconds(10)) { await a.naechste() }
        #expect(await Self.ende(strom) == .freigegeben)
        #expect(await a.gefragt == 4)
    }

    @Test func abgelaufenerCodeEndetSofort() async {
        let a = Antworten([.abgelaufen, .freigegeben])
        let strom = Quickconnectwarten.ablauf(frist: .seconds(5), takt: .milliseconds(20),
                                              tick: .milliseconds(10)) { await a.naechste() }
        #expect(await Self.ende(strom) == .ende(letzte: .abgelaufen))
        #expect(await a.gefragt == 1)
    }

    /// Scheiterte die letzte Nachfrage, sagt das Ende „Netz“, nicht „abgelaufen“.
    @Test func fristendeNachNetzfehler() async {
        let strom = Quickconnectwarten.ablauf(frist: .milliseconds(120), takt: .milliseconds(20),
                                              tick: .milliseconds(10)) { .gescheitert }
        #expect(await Self.ende(strom) == .ende(letzte: .gescheitert))
    }

    @Test func fristendeOhneFreigabe() async {
        let strom = Quickconnectwarten.ablauf(frist: .milliseconds(120), takt: .milliseconds(20),
                                              tick: .milliseconds(10)) { .offen }
        #expect(await Self.ende(strom) == .ende(letzte: .abgelaufen))
    }

    /// Die Frist läuft an der Uhr: eine Nachfrage, die länger hängt als die
    /// Frist (App im Hintergrund), zählt die verpasste Zeit mit.
    @Test func fristLaeuftAnDerUhr() async {
        let strom = Quickconnectwarten.ablauf(frist: .milliseconds(100), takt: .milliseconds(10),
                                              tick: .milliseconds(10)) {
            try? await Task.sleep(for: .milliseconds(150))
            return .gescheitert
        }
        let beginn = ContinuousClock.now
        #expect(await Self.ende(strom) == .ende(letzte: .gescheitert))
        #expect(ContinuousClock.now - beginn < .milliseconds(400))
    }

    @Test func restZaehltHerunter() async {
        var reste: [Int] = []
        let strom = Quickconnectwarten.ablauf(frist: .seconds(3), takt: .seconds(10),
                                              tick: .seconds(1)) { .offen }
        for await e in strom { if case let .rest(r) = e { reste.append(r) } }
        #expect(reste == [3, 2, 1])
    }

    /// Wer aufhört zu lesen, fragt nicht mehr nach.
    @Test func abbrechenBeendetDieNachfragen() async throws {
        let a = Antworten([])
        let lesen = Task {
            for await _ in Quickconnectwarten.ablauf(frist: .seconds(30), takt: .milliseconds(10),
                                                     tick: .milliseconds(10)) { await a.naechste() } {}
        }
        try await Task.sleep(for: .milliseconds(80))
        lesen.cancel()
        try await Task.sleep(for: .milliseconds(30))
        let danach = await a.gefragt
        try await Task.sleep(for: .milliseconds(100))
        #expect(await a.gefragt == danach)
        #expect(danach > 0)
    }

    @Test func restSekundenRundetAuf() {
        #expect(Quickconnectwarten.restSekunden(.milliseconds(1)) == 1)
        #expect(Quickconnectwarten.restSekunden(.seconds(2)) == 2)
        #expect(Quickconnectwarten.restSekunden(.zero) == 0)
        #expect(Quickconnectwarten.restSekunden(.milliseconds(-5)) == 0)
    }
}
