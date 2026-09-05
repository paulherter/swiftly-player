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

@Suite("Aufnehmen und Ablage")
struct KontenbundAblageTests {

    private let server = URL(string: "https://tv.paulherter.de")!
    private func konto(_ name: String, _ kennung: String) -> Session {
        Session(accessToken: "t-\(kennung)", userID: kennung,
                userName: name, serverURL: server)
    }

    @Test("Ohne vorhandenen Bund ist es kein Wechsel")
    func ersteAnmeldung() {
        let (bund, wechsel) = Kontenbund.aufnehmen(konto("paul", "1"), in: nil)
        #expect(!wechsel)
        #expect(bund.konten.count == 1)
    }

    @Test("Ein zweites Konto auf demselben Server ist ein Wechsel")
    func zweitesKonto() {
        let erst = Kontenbund(konto("paul", "1"))
        let (bund, wechsel) = Kontenbund.aufnehmen(konto("eltern", "2"), in: erst)
        #expect(wechsel)
        #expect(bund.konten.count == 2)
        #expect(bund.aktives.userID == "2")
    }

    /// Ein Bund gehört zu genau einem Server. Wer den Server wechselt, fängt
    /// neu an — und das ist kein Kontowechsel, sondern ein Neuanfang.
    @Test("Ein anderer Server fängt neu an, statt zu wechseln")
    func andererServer() {
        let erst = Kontenbund(konto("paul", "1"))
        let fremd = Session(accessToken: "t", userID: "9", userName: "x",
                            serverURL: URL(string: "https://anders.example")!)
        let (bund, wechsel) = Kontenbund.aufnehmen(fremd, in: erst)
        #expect(!wechsel)
        #expect(bund.konten.count == 1)
        #expect(bund.aktives.userID == "9")
    }

    @Test("Dieselbe Anmeldung noch einmal gilt als Wechsel, nicht als Neuanfang")
    func nochmalDasselbe() {
        let erst = Kontenbund(konto("paul", "1"))
        let (bund, wechsel) = Kontenbund.aufnehmen(konto("paul", "1"), in: erst)
        #expect(wechsel)
        #expect(bund.konten.count == 1)
    }

    @Test("Aus der Ablage kommt der Bund, wenn einer da ist")
    func ablageBund() throws {
        var b = Kontenbund(konto("paul", "1"))
        b.aufnehmen(konto("eltern", "2"))
        b.wechseln(zu: "1")
        let daten = try JSONEncoder().encode(b)
        let einzeln = try JSONEncoder().encode(konto("wer", "9"))
        let zurueck = try #require(Kontenbund.ausAblage(bund: daten, einzelne: einzeln))
        #expect(zurueck == b)
    }

    /// Der Weg für alle, die vor den Mehrfachkonten angemeldet waren.
    @Test("Ohne Bund wird die einzelne Sitzung von früher übernommen")
    func ablageUebernahme() throws {
        let einzeln = try JSONEncoder().encode(konto("paul", "1"))
        let zurueck = try #require(Kontenbund.ausAblage(bund: nil, einzelne: einzeln))
        #expect(zurueck.konten.count == 1)
        #expect(zurueck.aktives.userID == "1")
    }

    @Test("Ist nichts da, kommt nichts zurück")
    func ablageLeer() {
        #expect(Kontenbund.ausAblage(bund: nil, einzelne: nil) == nil)
    }

    /// Ein unlesbarer Bund darf nicht die Anmeldung kosten, solange die alte
    /// Einzelsitzung noch daliegt.
    @Test("Ein kaputter Bund fällt auf die einzelne Sitzung zurück")
    func ablageKaputt() throws {
        let einzeln = try JSONEncoder().encode(konto("paul", "1"))
        let muell = Data("kein JSON".utf8)
        let zurueck = try #require(Kontenbund.ausAblage(bund: muell, einzelne: einzeln))
        #expect(zurueck.aktives.userID == "1")
    }
    /// **Der Fall, der Linux und Windows die Anmeldung gekostet hätte.**
    ///
    /// Dort wurde die alte Ablage roh weitergereicht, obwohl sie andere
    /// Schlüsselnamen trägt (`token`, `benutzerID`, `benutzername`); drei von
    /// vier passten nicht, `try?` verschluckte es, und jeder bestehende
    /// Nutzer stand nach dem Aktualisieren vor dem Anmeldeschirm.
    ///
    /// Auf der Apple-Seite kann das nicht passieren — dort schreibt dieselbe
    /// `Session` mit denselben Namen. Dieser Test hält genau das fest, mit
    /// **wörtlichem** JSON statt einer frischen Kodierung: sonst prüfte er
    /// nur, dass unser Kodierer zu unserem Dekodierer passt, und ginge bei
    /// einer Umbenennung stillschweigend mit.
    @Test("Die alte Apple-Ablage wird wörtlich übernommen")
    func alteAppleAblage() throws {
        let alt = Data("""
        {"accessToken":"t-1","userID":"1","userName":"paul",
         "serverURL":"https://tv.paulherter.de"}
        """.utf8)
        let bund = try #require(Kontenbund.ausAblage(bund: nil, einzelne: alt))
        #expect(bund.aktives.userID == "1")
        #expect(bund.aktives.userName == "paul")
        #expect(bund.aktives.accessToken == "t-1")
    }

    /// Und die Gegenprobe: heissen die Schlüssel anders, kommt nichts zurück
    /// — nicht etwa ein halb gefüllter Bund.
    @Test("Fremde Schlüsselnamen liefern nichts, nicht Halbfertiges")
    func fremdeSchluessel() {
        let fremd = Data("""
        {"token":"t-1","benutzerID":"1","benutzername":"paul",
         "serverURL":"https://tv.paulherter.de"}
        """.utf8)
        #expect(Kontenbund.ausAblage(bund: nil, einzelne: fremd) == nil)
    }
}
