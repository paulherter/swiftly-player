import Foundation
import Testing
@testable import JellyfinKit

@Suite("Mehrere Konten auf demselben Server")
struct KontenbundTests {

    private let server = URL(string: "https://tv.paulherter.de")!

    private func konto(_ name: String, _ kennung: String) -> Session {
        Session(accessToken: "t-\(kennung)", userID: kennung,
                userName: name, serverURL: server)
    }

    @Test("Ein einzelnes Konto ist sofort das aktive")
    func einzeln() {
        let bund = Kontenbund(konto("paul", "1"))
        #expect(bund.konten.count == 1)
        #expect(bund.aktives.userName == "paul")
    }

    @Test("Ein zweites Konto wird aufgenommen und gilt sofort")
    func zweites() {
        var bund = Kontenbund(konto("paul", "1"))
        bund.aufnehmen(konto("eltern", "2"))
        #expect(bund.konten.count == 2)
        #expect(bund.aktives.userID == "2")
    }

    /// Meldet sich dasselbe Konto erneut an, darf es nicht zweimal im
    /// Streifen stehen — und es muss an seinem Platz bleiben, sonst springt
    /// die Reihe bei jeder abgelaufenen Sitzung durcheinander.
    @Test("Dieselbe Anmeldung ersetzt an Ort und Stelle, sie hängt nicht an")
    func ersetzen() {
        var bund = Kontenbund(konto("paul", "1"))
        bund.aufnehmen(konto("eltern", "2"))
        bund.aufnehmen(konto("oma", "3"))
        bund.aufnehmen(Session(accessToken: "neu", userID: "2",
                               userName: "eltern", serverURL: server))
        #expect(bund.konten.count == 3)
        #expect(bund.konten[1].userID == "2")
        #expect(bund.konten[1].accessToken == "neu")
        #expect(bund.aktives.userID == "2")
    }

    @Test("Umschalten geht nur auf Konten, die es gibt")
    func wechseln() {
        var bund = Kontenbund(konto("paul", "1"))
        bund.aufnehmen(konto("eltern", "2"))
        bund.wechseln(zu: "1")
        #expect(bund.aktives.userID == "1")
        bund.wechseln(zu: "gibtsnicht")
        #expect(bund.aktives.userID == "1")
    }

    /// Der Knopf heißt „Abmelden", nicht „Alle abmelden".
    @Test("Abmelden trifft nur das eine Konto")
    func entfernenLaesstDenRest() throws {
        var bund = Kontenbund(konto("paul", "1"))
        bund.aufnehmen(konto("eltern", "2"))
        let rest = try #require(bund.entfernt("2"))
        #expect(rest.konten.count == 1)
        #expect(rest.aktives.userID == "1")
    }

    @Test("War es das aktive, gilt danach das folgende")
    func nachfolgerRueckt() throws {
        var bund = Kontenbund(konto("paul", "1"))
        bund.aufnehmen(konto("eltern", "2"))
        bund.aufnehmen(konto("oma", "3"))
        bund.wechseln(zu: "2")
        let rest = try #require(bund.entfernt("2"))
        #expect(rest.aktives.userID == "3")
    }

    @Test("Fällt das letzte in der Reihe weg, rückt das davor nach")
    func letztesFaelltWeg() throws {
        var bund = Kontenbund(konto("paul", "1"))
        bund.aufnehmen(konto("eltern", "2"))
        let rest = try #require(bund.entfernt("2"))
        #expect(rest.aktives.userID == "1")
    }

    @Test("Das letzte Konto zu entfernen heißt abgemeldet")
    func letztes() {
        let bund = Kontenbund(konto("paul", "1"))
        #expect(bund.entfernt("1") == nil)
    }

    @Test("Ein unbekanntes Konto zu entfernen ändert nichts")
    func unbekannt() throws {
        var bund = Kontenbund(konto("paul", "1"))
        bund.aufnehmen(konto("eltern", "2"))
        let rest = try #require(bund.entfernt("99"))
        #expect(rest.konten.count == 2)
    }

    /// Zeigt die gespeicherte Kennung ins Leere — von Hand am Schlüsselbund
    /// gedreht, oder ein Bund aus einer älteren Fassung —, soll die App
    /// angemeldet bleiben und nicht ohne Sitzung dastehen.
    @Test("Eine ins Leere zeigende Kennung fällt auf das erste Konto zurück")
    func kaputteKennung() throws {
        let bund = try #require(Kontenbund(konten: [konto("paul", "1"),
                                                    konto("eltern", "2")],
                                           aktiv: "weg"))
        #expect(bund.aktives.userID == "1")
    }

    @Test("Ohne Konten gibt es keinen Bund")
    func leer() {
        #expect(Kontenbund(konten: [], aktiv: nil) == nil)
    }

    /// Beide Schreibweisen kommen vor: die eine aus der Eingabe des Nutzers,
    /// die andere aus unserer Normalisierung.
    @Test("Der Server mit und ohne Schrägstrich am Ende ist derselbe")
    func schraegstrich() {
        let bund = Kontenbund(konto("paul", "1"))
        let mitStrich = Session(accessToken: "t", userID: "2", userName: "eltern",
                                serverURL: URL(string: "https://tv.paulherter.de/")!)
        #expect(bund.passtZumServer(mitStrich))
    }

    @Test("Ein anderer Server passt nicht in denselben Bund")
    func andererServer() {
        let bund = Kontenbund(konto("paul", "1"))
        let fremd = Session(accessToken: "t", userID: "2", userName: "x",
                            serverURL: URL(string: "https://anders.example")!)
        #expect(!bund.passtZumServer(fremd))
    }

    @Test("Ein Bund übersteht Sichern und Zurücklesen")
    func codable() throws {
        var bund = Kontenbund(konto("paul", "1"))
        bund.aufnehmen(konto("eltern", "2"))
        bund.wechseln(zu: "1")
        let zurueck = try JSONDecoder().decode(
            Kontenbund.self, from: JSONEncoder().encode(bund))
        #expect(zurueck == bund)
        #expect(zurueck.aktives.userID == "1")
    }
}
