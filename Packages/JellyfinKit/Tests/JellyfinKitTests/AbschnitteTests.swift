import Foundation
import Testing
@testable import JellyfinKit

@Suite("Abschnitte einlesen")
struct AbschnittEinlesenTests {

    /// Genau die Form, die `MediaSegmentDto` in der OpenAPI-Beschreibung des
    /// Servers hat — nicht nachgebaut, abgelesen.
    private let antwort = """
    { "Items": [
        { "Id": "a1", "ItemId": "e1", "Type": "Intro",
          "StartTicks": 0, "EndTicks": 900000000 },
        { "Id": "a2", "ItemId": "e1", "Type": "Outro",
          "StartTicks": 13200000000, "EndTicks": 13800000000 }
      ], "TotalRecordCount": 2, "StartIndex": 0 }
    """.data(using: .utf8)!

    @Test("Ticks werden zu Sekunden — Faktor zehn Millionen")
    func ticks() throws {
        let a = try JSONDecoder().decode(AbschnittsAntwort.self, from: antwort)
        #expect(a.items.count == 2)
        #expect(a.items[0].art == .vorspann)
        #expect(a.items[0].von == 0)
        #expect(a.items[0].bis == 90)          // 900.000.000 Ticks
        #expect(a.items[1].art == .abspann)
        #expect(a.items[1].von == 1320)
    }

    @Test("Eine leere Liste ist der Normalfall, kein Fehler")
    func leer() throws {
        let d = #"{ "Items": [], "TotalRecordCount": 0, "StartIndex": 0 }"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(AbschnittsAntwort.self, from: d).items.isEmpty)
    }

    @Test("Fehlt Items ganz, ist es auch leer")
    func ohneItems() throws {
        let d = #"{ "TotalRecordCount": 0 }"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(AbschnittsAntwort.self, from: d).items.isEmpty)
    }

    @Test("Eine unbekannte Art wirft nicht, sie heißt unbekannt")
    func unbekannteArt() throws {
        let d = #"{ "Items": [ { "Type": "Intro", "StartTicks": 0, "EndTicks": 10000000 } ] }"#
            .data(using: .utf8)!
        #expect(try JSONDecoder().decode(AbschnittsAntwort.self, from: d).items[0].bis == 1)
    }
}

@Suite("Welcher Knopf gilt")
struct AbschnittslogikTests {

    private let vorspann = Abschnitt(art: .vorspann, von: 12, bis: 90)
    private let abspann  = Abschnitt(art: .abspann,  von: 1320, bis: 1380)

    // MARK: - Ohne Abschnitte darf sich nichts ändern

    @Test("Ohne Abschnitte gilt allein die Restzeitregel")
    func ohneAbschnitte() {
        // 1400 von 1500 s — nach Folgenende „gegen Ende".
        #expect(Abschnittslogik.angebot(position: 1400, dauer: 1500, abschnitte: [],
                                        hatNaechsteFolge: true) == .naechsteFolge)
        #expect(Abschnittslogik.angebot(position: 300, dauer: 1500, abschnitte: [],
                                        hatNaechsteFolge: true) == .keiner)
    }

    @Test("Ohne Abschnitte stimmen die Zeitpunkte auf die Sekunde mit Folgenende")
    func gleicheZeitpunkte() {
        for stelle in stride(from: 0.0, through: 1500.0, by: 5) {
            let alt = Folgenende.knopfZeigen(position: stelle, dauer: 1500)
            let neu = Abschnittslogik.angebot(position: stelle, dauer: 1500,
                                              abschnitte: [], hatNaechsteFolge: true)
            #expect((neu == .naechsteFolge) == alt, "bei \(stelle) s")
        }
    }

    @Test("Ohne nächste Folge kein Knopf")
    func keineNaechste() {
        #expect(Abschnittslogik.angebot(position: 1400, dauer: 1500, abschnitte: [abspann],
                                        hatNaechsteFolge: false) == .keiner)
    }

    // MARK: - Vorspann

    @Test("Im Vorspann wird das Überspringen angeboten")
    func imVorspann() {
        #expect(Abschnittslogik.angebot(position: 30, dauer: 1500, abschnitte: [vorspann, abspann],
                                        hatNaechsteFolge: true)
                == .ueberspringen(nach: 90, art: .vorspann))
    }

    @Test("Vor dem Vorspann und danach nicht")
    func nebenDemVorspann() {
        #expect(Abschnittslogik.angebot(position: 5, dauer: 1500, abschnitte: [vorspann],
                                        hatNaechsteFolge: false) == .keiner)
        #expect(Abschnittslogik.angebot(position: 95, dauer: 1500, abschnitte: [vorspann],
                                        hatNaechsteFolge: false) == .keiner)
    }

    @Test("Am Rand: die Anfangssekunde zählt dazu, die Endsekunde nicht")
    func raender() {
        #expect(Abschnittslogik.angebot(position: 12, dauer: 1500, abschnitte: [vorspann],
                                        hatNaechsteFolge: false)
                == .ueberspringen(nach: 90, art: .vorspann))
        #expect(Abschnittslogik.angebot(position: 90, dauer: 1500, abschnitte: [vorspann],
                                        hatNaechsteFolge: false) == .keiner)
    }

    @Test("Kurz vor Schluss des Vorspanns nicht mehr — der Knopf würde nur aufblitzen")
    func kurzVorSchluss() {
        #expect(Abschnittslogik.angebot(position: 89, dauer: 1500, abschnitte: [vorspann],
                                        hatNaechsteFolge: false) == .keiner)
    }

    @Test("Rückblick, Vorschau und Werbung werden auch angeboten")
    func andereArten() {
        for art in [Abschnitt.Art.rueckblick, .vorschau, .werbung] {
            let a = Abschnitt(art: art, von: 10, bis: 60)
            #expect(Abschnittslogik.angebot(position: 20, dauer: 1500, abschnitte: [a],
                                            hatNaechsteFolge: false)
                    == .ueberspringen(nach: 60, art: art))
        }
    }

    @Test("Ein unbekannter Abschnitt wird nicht angeboten")
    func unbekannt() {
        let a = Abschnitt(art: .unbekannt, von: 10, bis: 60)
        #expect(Abschnittslogik.angebot(position: 20, dauer: 1500, abschnitte: [a],
                                        hatNaechsteFolge: false) == .keiner)
    }

    // MARK: - Abspann

    @Test("Mit Abspannangabe bis zum Ende gilt sie und nicht die Restzeit")
    func abspannGilt() {
        let bisEnde = Abschnitt(art: .abspann, von: 1320, bis: 1499)
        // 1200 von 1500 wäre nach Restzeitregel noch nichts, nach Abspann auch nicht.
        #expect(Abschnittslogik.angebot(position: 1200, dauer: 1500, abschnitte: [bisEnde],
                                        hatNaechsteFolge: true) == .keiner)
        #expect(Abschnittslogik.angebot(position: 1320, dauer: 1500, abschnitte: [bisEnde],
                                        hatNaechsteFolge: true) == .naechsteFolge)
    }

    @Test("Abspann vor dem Dateiende wird übersprungen, danach kommt „Nächste Folge“")
    func abspannMitSzeneDanach() {
        // `abspann` endet 120 s vor Schluss: dahinter liegt noch eine Szene.
        #expect(Abschnittslogik.angebot(position: 1330, dauer: 1500, abschnitte: [abspann],
                                        hatNaechsteFolge: true)
                == .ueberspringen(nach: 1380, art: .abspann))
        #expect(Abschnittslogik.angebot(position: 1330, dauer: 1500, abschnitte: [abspann],
                                        hatNaechsteFolge: false)
                == .ueberspringen(nach: 1380, art: .abspann),
                "auch in der letzten Folge will man zur Szene danach")
        #expect(Abschnittslogik.angebot(position: 1400, dauer: 1500, abschnitte: [abspann],
                                        hatNaechsteFolge: true) == .naechsteFolge)
        #expect(!Abschnittslogik.karteFaellig(position: 1400, dauer: 1500, abschnitte: [abspann],
                                              hatNaechsteFolge: true),
                "die Szene nach dem Abspann bekommt keine Karte ins Bild")
        #expect(!Abschnittslogik.karteFaellig(position: 1491, dauer: 1500, abschnitte: [abspann],
                                              hatNaechsteFolge: true),
                "auch nicht kurz vor Schluss — sonst schnitte der Countdown sie ab")
    }

    @Test("Toleranz am Dateiende: zwei Sekunden davor zählt noch als bis zum Ende")
    func abspannToleranz() {
        let knapp = Abschnitt(art: .abspann, von: 1400, bis: 1498)
        let davor = Abschnitt(art: .abspann, von: 1400, bis: 1497)
        #expect(Abschnittslogik.angebot(position: 1410, dauer: 1500, abschnitte: [knapp],
                                        hatNaechsteFolge: true) == .naechsteFolge)
        #expect(Abschnittslogik.angebot(position: 1410, dauer: 1500, abschnitte: [davor],
                                        hatNaechsteFolge: true)
                == .ueberspringen(nach: 1497, art: .abspann))
    }

    @Test("Abspann bis zum Ende ohne nächste Folge: kein Knopf")
    func abspannBisEndeLetzteFolge() {
        let bisEnde = Abschnitt(art: .abspann, von: 1320, bis: 1500)
        #expect(Abschnittslogik.angebot(position: 1330, dauer: 1500, abschnitte: [bisEnde],
                                        hatNaechsteFolge: false) == .keiner)
    }

    // MARK: - Mindestlänge und Karte

    @Test("Abschnitte unter drei Sekunden bekommen keinen Knopf")
    func mindestlaenge() {
        let kurz = Abschnitt(art: .vorspann, von: 10, bis: 12.9)
        let genug = Abschnitt(art: .vorspann, von: 10, bis: 13)
        #expect(Abschnittslogik.angebot(position: 10, dauer: 1500, abschnitte: [kurz],
                                        hatNaechsteFolge: false) == .keiner)
        #expect(Abschnittslogik.angebot(position: 10, dauer: 1500, abschnitte: [genug],
                                        hatNaechsteFolge: false)
                == .ueberspringen(nach: 13, art: .vorspann))
    }

    @Test("Ein zu kurzer Abspann zählt nicht — dann gilt die Restzeitregel")
    func kurzerAbspann() {
        let kurz = Abschnitt(art: .abspann, von: 1498, bis: 1500)
        #expect(Abschnittslogik.angebot(position: 1400, dauer: 1500, abschnitte: [kurz],
                                        hatNaechsteFolge: true) == .naechsteFolge)
    }

    @Test("Ohne Abspann-Abschnitt nie eine Karte, nur der Knopf in der Steuerung")
    func karteOhneAbschnitte() {
        #expect(Abschnittslogik.angebot(position: 1400, dauer: 1500, abschnitte: [],
                                        hatNaechsteFolge: true) == .naechsteFolge)
        #expect(!Abschnittslogik.karteFaellig(position: 1400, dauer: 1500, abschnitte: [],
                                              hatNaechsteFolge: true))
        #expect(!Abschnittslogik.karteFaellig(position: 1499, dauer: 1500, abschnitte: [],
                                              hatNaechsteFolge: true))
        let intro = Abschnitt(art: .vorspann, von: 10, bis: 60)
        #expect(!Abschnittslogik.karteFaellig(position: 1499, dauer: 1500, abschnitte: [intro],
                                              hatNaechsteFolge: true))
    }

    @Test("Die Füllung dauert sieben Sekunden, aber nie über das Dateiende hinaus")
    func countdownLaenge() {
        #expect(Abschnittslogik.countdown(position: 1320, dauer: 1500) == 7)
        #expect(Abschnittslogik.countdown(position: 1496, dauer: 1500) == 4)
        #expect(Abschnittslogik.countdown(position: 1500, dauer: 1500) == 1)
    }

    @Test("Mit Abspann bis zum Ende kommt die Karte mit dem Abspann")
    func karteMitAbspann() {
        let bisEnde = Abschnitt(art: .abspann, von: 1320, bis: 1500)
        #expect(!Abschnittslogik.karteFaellig(position: 1319, dauer: 1500, abschnitte: [bisEnde],
                                              hatNaechsteFolge: true))
        #expect(Abschnittslogik.karteFaellig(position: 1320, dauer: 1500, abschnitte: [bisEnde],
                                             hatNaechsteFolge: true))
    }

    @Test("Ein früher Abspann zeigt den Knopf früher als die Restzeitregel")
    func frueherAbspann() {
        let frueh = Abschnitt(art: .abspann, von: 1100, bis: 1500)
        #expect(!Folgenende.knopfZeigen(position: 1100, dauer: 1500),
                "nach der alten Regel wäre hier noch nichts")
        #expect(Abschnittslogik.angebot(position: 1100, dauer: 1500, abschnitte: [frueh],
                                        hatNaechsteFolge: true) == .naechsteFolge)
    }

    @Test("Ein sehr späterer Abspann unterdrückt den Knopf, den die Restzeit gezeigt hätte")
    func spaeterAbspann() {
        let spaet = Abschnitt(art: .abspann, von: 1490, bis: 1500)
        #expect(Folgenende.knopfZeigen(position: 1400, dauer: 1500),
                "nach der alten Regel stünde er hier")
        #expect(Abschnittslogik.angebot(position: 1400, dauer: 1500, abschnitte: [spaet],
                                        hatNaechsteFolge: true) == .keiner,
                "die Angabe des Servers gilt allein — sonst erschiene er zweimal")
    }

    @Test("Der Vorspann gewinnt gegen den Abspann, wenn die Stelle in ihm liegt")
    func vorspannGewinnt() {
        // Konstruiert, aber es kostet nichts, die Reihenfolge festzuschreiben.
        let ueberall = Abschnitt(art: .abspann, von: 0, bis: 1500)
        #expect(Abschnittslogik.angebot(position: 30, dauer: 1500,
                                        abschnitte: [ueberall, vorspann],
                                        hatNaechsteFolge: true)
                == .ueberspringen(nach: 90, art: .vorspann))
    }
}
