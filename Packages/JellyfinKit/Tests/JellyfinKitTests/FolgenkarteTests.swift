import Foundation
import Testing
@testable import JellyfinKit

@Suite struct FolgenkarteTests {
    @Test func federIstKritischGedaempft() {
        let f = Folgenkarte.feder(10)
        #expect(f.steifigkeit == 100 && f.daempfung == 20)
        #expect(Folgenkarte.federweg(0, omega: 10) == 0)
        // Zum Tausch deckt die Karte das Bild fast ganz.
        #expect(Folgenkarte.federweg(Folgenkarte.tausch, omega: Folgenkarte.zoomOmega) > 0.98)
        // Kein Überschwingen.
        #expect(Folgenkarte.federweg(3, omega: 10) <= 1)
    }

    @Test func blendeWartetAufDenTausch() {
        #expect(Folgenkarte.blendeAb(bildSeit: 0.2) == Folgenkarte.tausch)
        #expect(Folgenkarte.blendeAb(bildSeit: 1.5) == 1.5)
    }

    @Test func rahmenGehtVonDerKarteAufsBild() {
        let k = (x: 548.0, y: 171.0, b: 240.0, h: 135.0)
        let a = Folgenkarte.rahmen(karte: k, ganz: (844, 390), zoom: 0)
        #expect(a.x == 548 && a.b == 240)
        let e = Folgenkarte.rahmen(karte: k, ganz: (844, 390), zoom: 1)
        #expect(e.x == 0 && e.y == 0 && e.b == 844 && e.h == 390)
    }

    @Test func ohneAbspannInDenLetztenDreissigSekunden() {
        let weit = Abschnittslogik.karteFaellig(position: 1400, dauer: 1500, abschnitte: [],
                                                hatNaechsteFolge: true, restfenster: 30)
        let nah = Abschnittslogik.karteFaellig(position: 1471, dauer: 1500, abschnitte: [],
                                               hatNaechsteFolge: true, restfenster: 30)
        #expect(!weit && nah)
        // Ohne Fenster bleibt es beim alten Verhalten.
        #expect(!Abschnittslogik.karteFaellig(position: 1471, dauer: 1500, abschnitte: [],
                                              hatNaechsteFolge: true))
        // Der Countdown läuft dann bis ans Ende, nicht sieben Sekunden.
        #expect(Abschnittslogik.countdown(position: 1471, dauer: 1500, abschnitte: [],
                                          restfenster: 30) == 29)
        let abspann = Abschnitt(art: .abspann, von: 1320, bis: 1500)
        #expect(Abschnittslogik.countdown(position: 1400, dauer: 1500, abschnitte: [abspann],
                                          restfenster: 30) == 7)
    }

    @Test func mitAbspannGiltDerAbspann() {
        let abspann = Abschnitt(art: .abspann, von: 1320, bis: 1500)
        #expect(Abschnittslogik.karteFaellig(position: 1320, dauer: 1500, abschnitte: [abspann],
                                             hatNaechsteFolge: true, restfenster: 30))
        let mitSzene = Abschnitt(art: .abspann, von: 1300, bis: 1380)
        #expect(!Abschnittslogik.karteFaellig(position: 1480, dauer: 1500, abschnitte: [mitSzene],
                                              hatNaechsteFolge: true, restfenster: 30))
    }
}

@Suite struct KarteBeiSteuerungTests {
    private func ebene() -> Angebotsebene {
        var e = Angebotsebene()
        e.karteWartetBeiSteuerung = true
        return e
    }

    @Test func steuerungVerdecktUndHaeltAn() {
        var e = ebene()
        _ = e.takt(angebot: .naechsteFolge, karteFaellig: true, laeuft: true, vergangen: 2)
        e.steuerung(offen: true)
        #expect(e.anzeige == .nichts)
        // Offen läuft nichts weiter, auch nicht über die Länge hinaus.
        let sprang = e.takt(angebot: .naechsteFolge, karteFaellig: true, laeuft: true, vergangen: 60)
        #expect(!sprang && e.weiterAmEnde)
        e.steuerung(offen: false)
        guard case let .karte(anteil) = e.anzeige else { Issue.record("keine Karte"); return }
        #expect(abs(anteil - 2 / Angebotsebene.countdown) < 0.001)
    }

    @Test func abbrechenSagtDasWeiterAb() {
        var e = ebene()
        _ = e.takt(angebot: .naechsteFolge, karteFaellig: true, laeuft: true, vergangen: 1)
        let zu = e.schliessen()
        #expect(zu)
        #expect(e.anzeige == .nichts && !e.weiterAmEnde && !e.karteZaehlt)
    }

    @Test func ohneSchalterWieBisher() {
        var e = Angebotsebene()
        _ = e.takt(angebot: .naechsteFolge, karteFaellig: true, laeuft: true, vergangen: 1)
        e.steuerung(offen: true)
        #expect(e.anzeige == .nichts && !e.weiterAmEnde)
    }
}

/// Gemeldet 26.09.2026: ganz nach hinten gespult → sofort die nächste Folge.
@Suite struct SprungAnsEndeTests {
    @Test func dasEndeSchaltetNichtAmCountdownVorbei() {
        var e = Angebotsebene()
        e.karteWartetBeiSteuerung = true
        _ = e.takt(angebot: .naechsteFolge, karteFaellig: true, laeuft: true, vergangen: 0)
        #expect(e.karteZaehlt)
        #expect(!Folgenende.weiterschalten(position: 1500, dauer: 1500, seitOeffnen: 600,
                                           karteZaehlt: e.karteZaehlt))
        // Ohne Karte (abgesagt oder keine) wie bisher.
        #expect(Folgenende.weiterschalten(position: 1500, dauer: 1500, seitOeffnen: 600))
    }

    @Test func amEndeZaehltDerCountdownWeiter() {
        var e = Angebotsebene()
        _ = e.takt(angebot: .naechsteFolge, karteFaellig: true, laeuft: false, vergangen: 0)
        var fertig = false
        for _ in 0..<40 where !fertig {
            fertig = e.takt(angebot: .naechsteFolge, karteFaellig: true, laeuft: false,
                            vergangen: 0.5, amEnde: true)
        }
        #expect(fertig)
    }

    @Test func sprungSetztDenCountdownZurueck() {
        var e = Angebotsebene()
        _ = e.takt(angebot: .naechsteFolge, karteFaellig: true, laeuft: true, vergangen: 5)
        e.gesprungen()
        guard case let .karte(anteil) = e.anzeige else { Issue.record("keine Karte"); return }
        #expect(anteil == 0)
    }

    @Test func amEndeGrenze() {
        #expect(Folgenende.amEnde(position: 1499, dauer: 1500))
        #expect(!Folgenende.amEnde(position: 1498, dauer: 1500))
    }
}

@Suite struct KartenlageTests {
    @Test func schmaleIPhonesBekommenEineKleinereKarte() {
        #expect(Folgenkarte.breite(Folgenkarte.iPhone, sichereBreite: 667, gross: false) == 200.1)
        #expect(Folgenkarte.breite(Folgenkarte.iPhone, sichereBreite: 814, gross: false) == 240)
        #expect(Folgenkarte.breite(Folgenkarte.iPhone, sichereBreite: 1366, gross: true) == 300)
    }

    @Test func wischen() {
        #expect(Folgenkarte.gezogen(-100, 50) == (-20, 50))
        #expect(Folgenkarte.weggewischt(x: 80, y: 0, schwungX: 80, schwungY: 0))
        #expect(Folgenkarte.weggewischt(x: 30, y: 0, schwungX: 200, schwungY: 0))
        #expect(!Folgenkarte.weggewischt(x: 30, y: 20, schwungX: 60, schwungY: 40))
    }
}
