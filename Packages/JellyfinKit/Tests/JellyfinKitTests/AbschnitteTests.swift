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

    @Test("Mit Abspannangabe gilt sie und nicht die Restzeit")
    func abspannGilt() {
        // 1200 von 1500 wäre nach Restzeitregel noch nichts, nach Abspann auch nicht.
        #expect(Abschnittslogik.angebot(position: 1200, dauer: 1500, abschnitte: [abspann],
                                        hatNaechsteFolge: true) == .keiner)
        #expect(Abschnittslogik.angebot(position: 1320, dauer: 1500, abschnitte: [abspann],
                                        hatNaechsteFolge: true) == .naechsteFolge)
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
