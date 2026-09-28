import Foundation
import Testing
@testable import JellyfinKit

/// Nutzermeldung zu 1.0.3: Adresse falsch, korrigiert und erneut abgeschickt —
/// die späte Antwort der ersten Prüfung warf einen aus der Anmeldung zurück
/// auf die Adressmaske.
@Suite struct AdresspruefungTests {

    @Test func veralteteAntwortWirdVerworfen() {
        var stand = Pruefstand()
        let alt = stand.beginnen("gibtsnicht.example")
        let neu = stand.beginnen("tv.example.de")
        #expect(!stand.gilt(alt))
        #expect(stand.gilt(neu))
        // Die alte Antwort kommt zuletzt an und darf nichts abschließen.
        let altWirkt = stand.abschliessen(alt)
        #expect(!altWirkt)
        #expect(stand.laufend == neu)
        let neuWirkt = stand.abschliessen(neu)
        #expect(neuWirkt)
        #expect(stand.laufend == nil)
    }

    @Test func geaenderteAdresseVerwirftDiePruefung() {
        var stand = Pruefstand()
        let marke = stand.beginnen("tv.example")
        stand.verwerfen()
        #expect(!stand.gilt(marke))
        let wirkt = stand.abschliessen(marke)
        #expect(!wirkt)
    }

    @Test func markenSindEindeutigAuchBeiGleicherAdresse() {
        var stand = Pruefstand()
        let erste = stand.beginnen("tv.example.de")
        let zweite = stand.beginnen("tv.example.de")
        #expect(erste != zweite)
        #expect(!stand.gilt(erste))
    }

    @Test(arguments: [-1003, -1006, -1001, -999, -1009])
    func keinAusweichenBeiNameFristAbbruch(code: Int) {
        #expect(!Adresspruefung.ausweichenLohnt(nach: JellyfinError.netz(code: code)))
        #expect(!Adresspruefung.ausweichenLohnt(nach: NSError(domain: NSURLErrorDomain, code: code)))
    }

    @Test func ausweichenBeiAbgewiesenerVerbindung() {
        #expect(Adresspruefung.ausweichenLohnt(nach: JellyfinError.netz(code: -1004)))
        #expect(Adresspruefung.ausweichenLohnt(nach: JellyfinError.zertifikat(.nichtVertraut)))
        #expect(!Adresspruefung.ausweichenLohnt(nach: CancellationError()))
    }

    @Test func heimnetzWartetDraussenNicht() {
        let heim = Adresspruefung.sitzung(fuer: URL(string: "http://192.168.1.5:8096")!)
        let draussen = Adresspruefung.sitzung(fuer: URL(string: "https://tv.example.de")!)
        #expect(heim !== draussen)
        #expect(draussen.configuration.timeoutIntervalForResource == Adresspruefung.frist)
        #if canImport(Darwin)
        #expect(heim.configuration.waitsForConnectivity)
        #expect(!draussen.configuration.waitsForConnectivity)
        #endif
    }

    /// Ein unbekannter Name kommt draußen sofort an, nicht nach der Frist.
    @Test func unbekannterNameScheitertSofort() async throws {
        let c = JellyfinClient(baseURL: URL(string: "https://gibtsnicht-swiftly-pruefung.invalid")!,
                               deviceID: "test", deviceName: "test", clientVersion: "0")
        let beginn = Date()
        await #expect(throws: (any Error).self) { _ = try await c.erreichbarkeitPruefen() }
        #expect(Date().timeIntervalSince(beginn) < 5)
    }
}
