import Testing
import Foundation
@testable import JellyfinKit

/// Die Einblendung über dem Bild: Überspringen, Countdown, Pause, Steuerung.
struct AngebotsebeneTests {

    private let intro = Knopfangebot.ueberspringen(nach: 90, art: .vorspann)

    /// Takte zu je einer halben Sekunde, wie `Wiedergabetakt`.
    @discardableResult
    private func laufen(_ e: inout Angebotsebene, _ sekunden: Double, angebot: Knopfangebot,
                        karte: Bool = false, laeuft: Bool = true,
                        countdown: Double = Angebotsebene.countdown) -> Int {
        var ausgeloest = 0
        for _ in 0..<Int(sekunden * 2) {
            if e.takt(angebot: angebot, karteFaellig: karte, laeuft: laeuft,
                      vergangen: 0.5, countdown: countdown) { ausgeloest += 1 }
        }
        return ausgeloest
    }

    @Test("Überspringen steht ab Beginn sechs Sekunden über dem Bild und blendet dann aus")
    func ueberspringenBlendetAus() {
        var e = Angebotsebene()
        laufen(&e, 5.5, angebot: intro)
        #expect(e.anzeige == .knopf(intro))
        laufen(&e, 0.5, angebot: intro)
        #expect(e.anzeige == .nichts, "nach sechs Sekunden ohne Drücken weg")
        laufen(&e, 60, angebot: intro)
        #expect(e.anzeige == .nichts, "und kommt ohne Steuerung nicht wieder")
        let geschlossen = e.schliessen()
        #expect(!geschlossen, "Zurück gehört dann dem Player")
    }

    @Test("Nach Ablauf kommt der Knopf mit der Steuerung und geht mit ihr, jedes Mal")
    func ueberspringenMitSteuerung() {
        var e = Angebotsebene()
        laufen(&e, 8, angebot: intro)
        #expect(e.anzeige == .nichts)
        e.steuerung(offen: true)
        #expect(e.anzeige == .knopf(intro), "Steuerung auf: Knopf da")
        laufen(&e, 10, angebot: intro)
        #expect(e.anzeige == .knopf(intro), "solange sie offen ist")
        e.steuerung(offen: false)
        #expect(e.anzeige == .nichts, "Steuerung zu: Knopf weg")
        e.steuerung(offen: true, durch: .nebenbei)
        #expect(e.anzeige == .knopf(intro), "auch mit dem Zeiger geöffnet")
        e.steuerung(offen: false)
        #expect(e.anzeige == .nichts)
        e.steuerung(offen: true)
        laufen(&e, 1, angebot: .keiner)
        #expect(e.anzeige == .nichts, "der Abschnitt ist vorbei")
    }

    @Test("Die sechs Sekunden laufen auch bei offener Steuerung und stehen in der Pause")
    func knopfzeit() {
        var e = Angebotsebene()
        e.steuerung(offen: true)
        laufen(&e, 7, angebot: intro)
        #expect(e.anzeige == .knopf(intro))
        e.steuerung(offen: false)
        #expect(e.anzeige == .nichts, "Zu nach Ablauf nimmt ihn mit")

        var p = Angebotsebene()
        laufen(&p, 3, angebot: intro)
        laufen(&p, 30, angebot: intro, laeuft: false)
        #expect(p.anzeige == .knopf(intro), "Pause hält die Zeit an")
        laufen(&p, 3, angebot: intro)
        #expect(p.anzeige == .nichts)
    }

    @Test("Ein neuer Abschnitt fängt die sechs Sekunden neu an")
    func neuerAbschnitt() {
        var e = Angebotsebene()
        laufen(&e, 8, angebot: intro)
        #expect(e.anzeige == .nichts)
        laufen(&e, 1, angebot: .keiner)
        let rueckblick = Knopfangebot.ueberspringen(nach: 300, art: .rueckblick)
        laufen(&e, 1, angebot: rueckblick)
        #expect(e.anzeige == .knopf(rueckblick))
    }

    @Test("Nach einem Sprung erscheint und verschwindet der Knopf im selben Aufruf")
    func sofortNachSprung() {
        var e = Angebotsebene()
        laufen(&e, 2, angebot: .keiner)
        _ = e.takt(angebot: intro, karteFaellig: false, laeuft: true, vergangen: 0)
        #expect(e.anzeige == .knopf(intro))
        _ = e.takt(angebot: .keiner, karteFaellig: false, laeuft: true, vergangen: 0)
        #expect(e.anzeige == .nichts)
    }

    @Test("In den ersten sechs Sekunden ändern Auf und Zu der Steuerung nichts")
    func steuerungAufZu() {
        var e = Angebotsebene()
        laufen(&e, 1, angebot: intro)
        e.steuerung(offen: true)
        #expect(e.anzeige == .knopf(intro))
        laufen(&e, 1, angebot: intro)
        e.steuerung(offen: false)
        laufen(&e, 1, angebot: intro)
        #expect(e.anzeige == .knopf(intro))
        e.steuerung(offen: true)
        e.steuerung(offen: false)
        #expect(e.anzeige == .knopf(intro))
        laufen(&e, 1, angebot: .keiner)
        #expect(e.anzeige == .nichts, "erst das Ende des Abschnitts nimmt ihn weg")
    }

    @Test("Steuerung schon offen, als der Abschnitt begann: der Knopf steht trotzdem")
    func steuerungVorherOffen() {
        var e = Angebotsebene()
        e.steuerung(offen: true)
        laufen(&e, 1, angebot: intro)
        #expect(e.anzeige == .knopf(intro))
        e.steuerung(offen: false)
        #expect(e.anzeige == .knopf(intro))
    }

    @Test("Zurück schließt den Knopf, ein neues Angebot kommt wieder")
    func zurueck() {
        var e = Angebotsebene()
        laufen(&e, 1, angebot: intro)
        let erstes = e.schliessen()
        #expect(erstes)
        #expect(e.anzeige == .nichts)
        let zweites = e.schliessen()
        #expect(!zweites, "zweites Zurück verlässt den Player")
        laufen(&e, 1, angebot: .keiner)
        laufen(&e, 1, angebot: intro)
        #expect(e.anzeige == .knopf(intro))
    }

    @Test("Ohne Abspann-Abschnitt keine Karte und nie ein Wechsel")
    func naechsteNurMitKarte() {
        var e = Angebotsebene()
        #expect(laufen(&e, 60, angebot: .naechsteFolge, karte: false) == 0)
        #expect(e.anzeige == .nichts)
        #expect(!e.weiterAmEnde)
    }

    @Test("Mit Abspann: Karte bleibt stehen, füllt sich in sieben Sekunden und wechselt erst danach, genau einmal")
    func countdown() {
        var e = Angebotsebene()
        laufen(&e, 6.5, angebot: .naechsteFolge, karte: true)
        #expect(e.anzeige == .karte(anteil: 6.5 / 7))
        #expect(e.countdownRest == 1)
        #expect(e.weiterAmEnde)
        #expect(laufen(&e, 0.5, angebot: .naechsteFolge, karte: true) == 0)
        #expect(e.anzeige == .karte(anteil: 1), "rechnerisch voll …")
        #expect(laufen(&e, 0.5, angebot: .naechsteFolge, karte: true) == 0,
                "… sichtbar voll erst nach dem Nachziehen, dann eine kurze Ruhe")
        #expect(laufen(&e, 0.5, angebot: .naechsteFolge, karte: true) == 1)
        #expect(laufen(&e, 5, angebot: .naechsteFolge, karte: true) == 0)
    }

    @Test("Kurz vor Dateiende: die Füllung ist so lang wie der Rest")
    func countdownKurz() {
        var e = Angebotsebene()
        #expect(laufen(&e, 4.5, angebot: .naechsteFolge, karte: true, countdown: 4) == 0)
        #expect(laufen(&e, 0.5, angebot: .naechsteFolge, karte: true, countdown: 4) == 1)
    }

    @Test("Countdown hält in der Pause an und läuft danach weiter")
    func countdownPause() {
        var e = Angebotsebene()
        laufen(&e, 5, angebot: .naechsteFolge, karte: true)
        #expect(laufen(&e, 30, angebot: .naechsteFolge, karte: true, laeuft: false) == 0)
        #expect(laufen(&e, 5, angebot: .naechsteFolge, karte: true) == 1)
    }

    @Test("Steuerung öffnen bricht die Karte ab und sagt das Weiterschalten ab")
    func countdownSteuerung() {
        var e = Angebotsebene()
        laufen(&e, 3, angebot: .naechsteFolge, karte: true)
        e.steuerung(offen: true)
        #expect(e.anzeige == .nichts, "bei offener Steuerung nur der normale Knopf")
        #expect(e.weiterAbgesagt)
        #expect(!e.weiterAmEnde)
        e.steuerung(offen: false)
        #expect(laufen(&e, 30, angebot: .naechsteFolge, karte: true) == 0)
        #expect(e.anzeige == .nichts, "nach dem Schließen kommt sie nicht wieder")
    }

    @Test("Steuerung durch Zeigerbewegung: die Karte bleibt und schaltet weiter")
    func zeigerSagtNichtAb() {
        var e = Angebotsebene()
        laufen(&e, 3, angebot: .naechsteFolge, karte: true)
        e.steuerung(offen: true, durch: .nebenbei)
        #expect(e.anzeige == .karte(anteil: 3.0 / Angebotsebene.countdown))
        #expect(!e.weiterAbgesagt)
        // Weitere Bewegung und bloßer Abgleich ändern nichts.
        e.steuerung(offen: true, durch: .nebenbei)
        e.steuerung(offen: false)
        e.steuerung(offen: true, durch: .nebenbei)
        #expect(laufen(&e, 8, angebot: .naechsteFolge, karte: true) == 1)
    }

    @Test("Zeiger öffnet, dann Klick oder Taste: erst das sagt die Karte ab")
    func zeigerDannBewusst() {
        var e = Angebotsebene()
        laufen(&e, 2, angebot: .naechsteFolge, karte: true)
        e.steuerung(offen: true, durch: .nebenbei)
        laufen(&e, 1, angebot: .naechsteFolge, karte: true)
        e.steuerung(offen: true, durch: .bewusst)
        #expect(e.anzeige == .nichts)
        #expect(e.weiterAbgesagt)
        // Ein späterer Abgleich macht die Steuerung nicht wieder „nebenbei".
        e.steuerung(offen: true, durch: .nebenbei)
        #expect(e.anzeige == .nichts)
        #expect(laufen(&e, 30, angebot: .naechsteFolge, karte: true) == 0)
    }

    @Test("War die Steuerung schon offen, zählt der Countdown erst ab dem Schließen")
    func countdownHinterSteuerung() {
        var e = Angebotsebene()
        e.steuerung(offen: true)
        #expect(laufen(&e, 30, angebot: .naechsteFolge, karte: true) == 0)
        #expect(!e.weiterAbgesagt)
        e.steuerung(offen: false)
        #expect(e.anzeige == .karte(anteil: 0))
        #expect(laufen(&e, 8, angebot: .naechsteFolge, karte: true) == 1)
    }

    @Test("Zurück bricht den Countdown ab und sagt das Weiterschalten der Folge ab")
    func countdownAbbruch() {
        var e = Angebotsebene()
        laufen(&e, 3, angebot: .naechsteFolge, karte: true)
        let zu = e.schliessen()
        #expect(zu)
        #expect(e.weiterAbgesagt)
        #expect(laufen(&e, 30, angebot: .naechsteFolge, karte: true) == 0)
        e.neueFolge()
        #expect(!e.weiterAbgesagt)
    }

    @Test("Füllung: durchgehend aus der Zeit, hält in der Pause und läuft ohne Rücksprung weiter")
    func fuellungsuhr() {
        var u = Fuellungsuhr()
        let t0 = Date()
        u.stellen(anteil: 0, laeuft: true, laenge: 7, jetzt: t0)
        #expect(u.anteil(jetzt: t0) == 0)
        #expect(abs(u.anteil(jetzt: t0.addingTimeInterval(0.1)) - 0.1 / 7) < 1e-6, "zwischen den Takten weiter")
        // Takt meldet einen kleineren Wert als die Uhr: sie bleibt bei sich.
        u.stellen(anteil: 0.07, laeuft: true, laenge: 7, jetzt: t0.addingTimeInterval(0.6))
        #expect(abs(u.anteil(jetzt: t0.addingTimeInterval(0.7)) - 0.1) < 1e-6)
        // Pause bei 3,5 s: steht genau dort.
        u.stellen(anteil: 0.43, laeuft: false, laenge: 7, jetzt: t0.addingTimeInterval(3.5))
        #expect(u.anteil(jetzt: t0.addingTimeInterval(30)) == 0.5)
        // Weiter: von dort, nicht vom kleineren Wert der Ebene.
        let t1 = t0.addingTimeInterval(40)
        u.stellen(anteil: 0.43, laeuft: true, laenge: 7, jetzt: t1)
        #expect(u.anteil(jetzt: t1) == 0.5)
        #expect(u.anteil(jetzt: t1.addingTimeInterval(3.5)) == 1)
        #expect(u.anteil(jetzt: t1.addingTimeInterval(10)) == 1)
        u.stellen(anteil: nil, laeuft: true, laenge: 7, jetzt: t1)
        #expect(u.anteil(jetzt: t1.addingTimeInterval(1)) == 0, "ohne Karte zurück auf null")
    }

    @Test("Gedrückt: Einblendung weg")
    func gedrueckt() {
        var e = Angebotsebene()
        laufen(&e, 1, angebot: intro)
        e.gedrueckt()
        #expect(e.anzeige == .nichts)
    }

    @Test("Eigene Wahl vor Konto vor „an“")
    func weiterschalten() {
        #expect(Weiterschalten.gilt(eigeneWahl: nil, konto: nil))
        #expect(!Weiterschalten.gilt(eigeneWahl: nil, konto: false))
        #expect(Weiterschalten.gilt(eigeneWahl: true, konto: false))
        #expect(!Weiterschalten.gilt(eigeneWahl: false, konto: true))
    }

    @Test("Kontovorgaben aus /Users/{id}")
    func kontovorgaben() throws {
        let json = #"{"Id":"x","Configuration":{"EnableNextEpisodeAutoPlay":false,"PlayDefaultAudioTrack":true}}"#
        let v = try JSONDecoder().decode(Kontovorgaben.self, from: Data(json.utf8))
        #expect(v.naechsteFolgeAutomatisch == false)
        let ohne = try JSONDecoder().decode(Kontovorgaben.self, from: Data(#"{"Id":"x"}"#.utf8))
        #expect(ohne.naechsteFolgeAutomatisch == nil)
    }
}
