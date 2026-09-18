import Foundation
import Testing
@testable import JellyfinKit

/// Die Regeln, nach denen beide Player laufen.
///
/// Sie lagen lange in den Ansichten und damit ausserhalb jeder Pruefung —
/// zweimal geschrieben, einmal je Plattform. Genau dort sind sie
/// auseinandergelaufen: auf dem Fernseher stand bei Serien „0 Min.", weil
/// eine Pruefung fehlte, die das iPhone hatte. Deshalb stehen sie jetzt hier,
/// wo `swift test` sie bei jedem Durchlauf mitnimmt.
@MainActor
@Suite("Wiedergabetakt")
struct WiedergabetaktTests {

    private func messung(dauer: Double = 3600, position: Double = 0,
                         guteStelle: Double = 0, zeigtBild: Bool = true,
                         stelltEin: Bool = false, laeuft: Bool = true,
                         spuren: Bool = true) -> Wiedergabetakt.Messung {
        .init(dauer: dauer, position: position, guteStelle: guteStelle,
              zeigtBild: zeigtBild, stelltEin: stelltEin, laeuft: laeuft,
              hatTonspuren: spuren)
    }

    private func takt(_ stand: inout Wiedergabetakt.Stand,
                      _ m: Wiedergabetakt.Messung,
                      stelltWiederHer: Bool = false,
                      amSchieben: Bool = false,
                      seitStart: Date = Date(),
                      jetzt: Date = Date()) -> Wiedergabetakt.Auftrag {
        Wiedergabetakt.rechnen(&stand, messung: m, stelltWiederHer: stelltWiederHer,
                               amSchieben: amSchieben,
                               seitStart: seitStart, jetzt: jetzt)
    }

    // MARK: - Sprünge (Bug 17.09.2026)

    /// Ein laufender Titel, eine Minute nach dem Öffnen.
    private func laufend(bei stelle: Double) -> (Wiedergabetakt.Stand, Date) {
        var s = Wiedergabetakt.Stand()
        let start = Date().addingTimeInterval(-60)
        _ = takt(&s, messung(position: stelle), seitStart: start)
        return (s, start)
    }

    @Test("Ein Sprung setzt die Anzeige sofort aufs Ziel")
    func sprungSofort() {
        var (s, _) = laufend(bei: 300)
        Wiedergabetakt.gesprungen(&s, ziel: Wiedergabetakt.ziel(um: 30, stand: s))
        #expect(s.position == 330)
    }

    @Test("Solange VLC noch die alte Zeit meldet, bleibt die Anzeige auf dem Ziel")
    func sprungHaelt() {
        var (s, start) = laufend(bei: 300)
        let jetzt = Date()
        Wiedergabetakt.gesprungen(&s, ziel: 330, jetzt: jetzt)
        for i in 1...8 {
            _ = takt(&s, messung(position: 300 + Double(i) * 0.5), seitStart: start,
                     jetzt: jetzt.addingTimeInterval(Double(i) * 0.5))
            #expect(s.position == 330)
        }
    }

    @Test("VLC kommt an: ab da sofort VLCs Zeit, auch ein Schlüsselbild vor dem Ziel")
    func sprungUebergabe() {
        var (s, start) = laufend(bei: 300)
        let jetzt = Date()
        Wiedergabetakt.gesprungen(&s, ziel: 330, jetzt: jetzt)
        _ = takt(&s, messung(position: 329), seitStart: start, jetzt: jetzt.addingTimeInterval(0.5))
        #expect(s.position == 329)
        #expect(s.sprung == nil)
        _ = takt(&s, messung(position: 329.5), seitStart: start, jetzt: jetzt.addingTimeInterval(1))
        #expect(s.position == 329.5)
    }

    @Test("Die Anzeige ist VLCs Zeit: nach Abspielen, nach einem Sprung, nach Pause — nichts hochgerechnet")
    func zeitfolge() {
        var (s, start) = laufend(bei: 100)
        var jetzt = Date()
        func schritt(_ vlc: Double) -> Double {
            jetzt = jetzt.addingTimeInterval(0.25)
            Wiedergabetakt.zeitUebernehmen(&s, gemeldet: vlc, amSchieben: false,
                                           seitStart: start, jetzt: jetzt)
            return s.position
        }
        // Abspielen: jede Meldung erscheint so, wie sie kommt.
        let spielen = [100.0, 100.25, 100.5, 100.75, 101, 101.25]
        #expect(spielen.map(schritt) == spielen)
        // Sprung vor: Ziel, solange VLC noch die alte Zeit hat, dann VLC.
        Wiedergabetakt.gesprungen(&s, ziel: 131.25, jetzt: jetzt)
        let nachSprung = [101.25, 101.25, 130.9, 131.1, 131.35, 131.6].map(schritt)
        #expect(nachSprung == [131.25, 131.25, 130.9, 131.1, 131.35, 131.6])
        // Pause: VLC steht, die Anzeige auch.
        let pause = [131.7, 131.7, 131.7, 131.7].map(schritt)
        #expect(pause == [131.7, 131.7, 131.7, 131.7])
    }

    @Test("Mehrmals schnell vor: jeder Sprung zählt vom letzten Ziel")
    func sprungSerie() {
        var (s, start) = laufend(bei: 300)
        let jetzt = Date()
        Wiedergabetakt.gesprungen(&s, ziel: Wiedergabetakt.ziel(um: 30, stand: s), jetzt: jetzt)
        _ = takt(&s, messung(position: 300.5), seitStart: start, jetzt: jetzt.addingTimeInterval(0.5))
        Wiedergabetakt.gesprungen(&s, ziel: Wiedergabetakt.ziel(um: 30, stand: s), jetzt: jetzt)
        #expect(s.position == 360)
    }

    @Test("Überspringen, gleich danach 30 s vor: vom Ziel des Überspringens, ohne Rückfall")
    func sprungNachUeberspringen() {
        var (s, start) = laufend(bei: 60)
        let jetzt = Date()
        Wiedergabetakt.gesprungen(&s, ziel: 551, jetzt: jetzt)
        // VLC meldet noch die alte Stelle, dann schon gleich den zweiten Sprung.
        _ = takt(&s, messung(position: 60.2), seitStart: start, jetzt: jetzt.addingTimeInterval(0.25))
        Wiedergabetakt.gesprungen(&s, ziel: Wiedergabetakt.ziel(um: 30, stand: s),
                                  jetzt: jetzt.addingTimeInterval(0.3))
        #expect(s.position == 581)
        _ = takt(&s, messung(position: 60.4), seitStart: start, jetzt: jetzt.addingTimeInterval(0.5))
        #expect(s.position == 581, "nicht zurück auf das Ziel des Überspringens")
        _ = takt(&s, messung(position: 551.1), seitStart: start, jetzt: jetzt.addingTimeInterval(0.75))
        #expect(s.position == 581, "auch nicht, wenn VLC dort kurz vorbeikommt")
        _ = takt(&s, messung(position: 580.6), seitStart: start, jetzt: jetzt.addingTimeInterval(1))
        #expect(s.position == 580.6)
        #expect(s.sprung == nil)
    }

    @Test("Kommt VLC nie an, gilt nach dem Deckel wieder seine Zeit")
    func sprungDeckel() {
        var (s, start) = laufend(bei: 300)
        let jetzt = Date()
        Wiedergabetakt.gesprungen(&s, ziel: 900, jetzt: jetzt)
        _ = takt(&s, messung(position: 305), seitStart: start,
                 jetzt: jetzt.addingTimeInterval(Wiedergabetakt.sprungdeckel - 0.5))
        #expect(s.position == 900)
        _ = takt(&s, messung(position: 306), seitStart: start,
                 jetzt: jetzt.addingTimeInterval(Wiedergabetakt.sprungdeckel))
        #expect(s.position == 306)
    }

    @Test("Kein Sprung hinter das Ende oder vor den Anfang")
    func sprungGrenzen() {
        var (s, _) = laufend(bei: 3590)
        Wiedergabetakt.gesprungen(&s, ziel: 3620)
        #expect(s.position == 3600)
        Wiedergabetakt.gesprungen(&s, ziel: -10)
        #expect(s.position == 0)
    }

    @Test("Ein Folgenwechsel vergisst den offenen Sprung")
    func sprungWechsel() {
        var (s, _) = laufend(bei: 300)
        Wiedergabetakt.gesprungen(&s, ziel: 330)
        Wiedergabetakt.neuerTitel(&s, startGemeldet: true)
        #expect(s.sprung == nil)
    }

    @Test("Solange VLC einstellt, bleibt der Ladeschirm und nichts wird gemeldet")
    func stelltEin() {
        var s = Wiedergabetakt.Stand()
        let a = takt(&s, messung(position: 900, stelltEin: true))
        #expect(!s.erstesBildDa)
        #expect(s.position == 0)
        #expect(!a.startMelden)
    }

    @Test("Beim ersten Bild faellt der Ladeschirm, Spuren und Start folgen")
    func erstesBild() {
        var s = Wiedergabetakt.Stand()
        let a = takt(&s, messung(position: 900))
        #expect(a.ladeschirmWeg)
        #expect(s.erstesBildDa)
        #expect(a.spurenAnwenden)
        #expect(a.startMelden)
    }

    @Test("Start und Spurwechsel geschehen genau einmal")
    func nurEinmal() {
        var s = Wiedergabetakt.Stand()
        _ = takt(&s, messung(position: 900))
        let zweiter = takt(&s, messung(position: 901))
        #expect(!zweiter.startMelden)
        #expect(!zweiter.spurenAnwenden)
    }

    @Test("Zwanzig Sekunden ergeben zwei Fortschrittsmeldungen")
    func meldeabstand() {
        var s = Wiedergabetakt.Stand(erstesBildDa: true, spurenGesetzt: true,
                                     startGemeldet: true)
        var meldungen = 0
        for i in 1...40 where takt(&s, messung(position: Double(i))).fortschrittMelden {
            meldungen += 1
            _ = i
        }
        #expect(meldungen == 2)
    }

    @Test("Liegt der Finger am Regler, bleibt die Zeit stehen")
    func amRegler() {
        var s = Wiedergabetakt.Stand(position: 1200, erstesBildDa: true,
                                     spurenGesetzt: true, startGemeldet: true)
        _ = takt(&s, messung(position: 30), amSchieben: true)
        #expect(s.position == 1200)
    }

    /// Beim Wiederaufbau nach Netzwechsel steht VLCs Zeit auf dem Dateiende —
    /// der tote Strom sieht wie ein Ende aus.
    @Test("Beim Wiederaufbau gilt die letzte gute Stelle")
    func wiederaufbau() {
        var s = Wiedergabetakt.Stand(position: 1200, erstesBildDa: true,
                                     spurenGesetzt: true, startGemeldet: true)
        _ = takt(&s, messung(position: 3599, guteStelle: 1210), stelltWiederHer: true)
        #expect(s.position == 1210)
    }

    /// Der Startsprung geht als Medienoption mit; VLC meldet solange Werte des
    /// ungesprungenen Stroms.
    @Test("Ein Ruecksprung kurz nach dem Oeffnen ist Aufbauzucken")
    func aufbauzucken() {
        var s = Wiedergabetakt.Stand(position: 1200, erstesBildDa: true,
                                     spurenGesetzt: true, startGemeldet: true)
        _ = takt(&s, messung(position: 3))
        #expect(s.position == 1200)
    }

    // MARK: - Folgenwechsel in derselben Schleife

    /// Ohne Zuruecksetzen haelt der Stand `startGemeldet` fuer erledigt, und
    /// der Server erfaehrt vom naechsten Titel nur noch Fortschritt, ohne dass
    /// je eine Sitzung eroeffnet wurde. Genau so ist es auf zwei Plattformen
    /// passiert.
    @Test("Meldet die Schleife den Start, wird er nach dem Wechsel neu gemeldet")
    func wechselSchleifeMeldet() {
        var s = Wiedergabetakt.Stand(position: 1200, erstesBildDa: true,
                                     spurenGesetzt: true, startGemeldet: true,
                                     seitMeldung: 4)
        Wiedergabetakt.neuerTitel(&s, startGemeldet: false)
        #expect(s.position == 0)
        // Der Ladeschirm kommt zurück (Audit 16.09., T1-M3).
        #expect(!s.erstesBildDa)
        #expect(!s.spurenGesetzt)
        #expect(s.seitMeldung == 0)
        #expect(takt(&s, messung(position: 2)).startMelden)
    }

    @Test("Meldet der Wechsel selbst, meldet die Schleife nicht noch einmal")
    func wechselMeldetSelbst() {
        var s = Wiedergabetakt.Stand(position: 1200, erstesBildDa: true,
                                     spurenGesetzt: true, startGemeldet: true)
        Wiedergabetakt.neuerTitel(&s, startGemeldet: true)
        #expect(!takt(&s, messung(position: 2)).startMelden)
    }

    /// Gemessen 17.09., tvOS-Simulator: nach dem Wechsel von 75 s ging
    /// `Progress 76 s` für die neue Folge hinaus. VLC hielt Bildausgabe und
    /// Uhr der alten Folge, der Takt nahm beides für die neue.
    @Test("Nach dem Wechsel zählt die alte Bildausgabe nicht, die alte Zeit wird nie gemeldet")
    func wechselAlteUhr() {
        var s = Wiedergabetakt.Stand(position: 75, erstesBildDa: true,
                                     spurenGesetzt: true, startGemeldet: true, seitMeldung: 6)
        Wiedergabetakt.neuerTitel(&s, startGemeldet: true)
        let seitStart = Date()
        // VLC: alte Uhr, alte Bildausgabe, vom neuen Medium noch kein Bild.
        let alt = Zeitannahme.bildGehoertDemMedium(bildausgabe: true, gezeigteBilder: 0,
                                                    nachWechsel: true)
        #expect(!alt)
        for _ in 0..<8 {
            let a = takt(&s, messung(position: 75.4, zeigtBild: alt), seitStart: seitStart)
            #expect(!a.fortschrittMelden)
            #expect(!a.ladeschirmWeg)
        }
        #expect(s.position == 0)
        // Erstes Bild der neuen Folge: ihre Zeit gilt sofort.
        let neu = Zeitannahme.bildGehoertDemMedium(bildausgabe: true, gezeigteBilder: 3,
                                                    nachWechsel: true)
        _ = takt(&s, messung(position: 2, zeigtBild: neu), seitStart: seitStart)
        #expect(s.position == 2)
    }

    /// Gemessen 17.09.: mit dem ersten Bild der neuen Folge meldete VLC
    /// 6130 s, Sekunden später die echte Zeit.
    @Test("Nach dem Wechsel gilt keine Zeit, die noch nicht gespielt sein kann")
    func wechselUnsinnszeit() {
        var s = Wiedergabetakt.Stand(position: 75, erstesBildDa: true,
                                     spurenGesetzt: true, startGemeldet: true)
        Wiedergabetakt.neuerTitel(&s, startGemeldet: true)
        let seitStart = Date().addingTimeInterval(-2)
        let a = takt(&s, messung(position: 6130), seitStart: seitStart)
        #expect(s.position == 0)
        #expect(a.fortschrittMelden)   // Spuren nachmelden — mit 0, nicht 6130
        _ = takt(&s, messung(position: 76), seitStart: seitStart)
        #expect(s.position == 0)
        _ = takt(&s, messung(position: 2.5), seitStart: seitStart)
        #expect(s.position == 2.5)
        // Einmal angekommen, gilt wieder jeder Sprung.
        _ = takt(&s, messung(position: 900), seitStart: seitStart)
        #expect(s.position == 900)
    }

    @Test("Beim Öffnen an späterer Stelle gilt die Wechselsperre nicht")
    func oeffnenOhneWechselsperre() {
        var s = Wiedergabetakt.Stand(position: 1200)
        _ = takt(&s, messung(position: 1201))
        #expect(s.position == 1201)
    }

    @Test("Beim ersten Öffnen gilt die Bildausgabe ohne gezähltes Bild")
    func erstesOeffnenBildausgabe() {
        #expect(Zeitannahme.bildGehoertDemMedium(bildausgabe: true, gezeigteBilder: 0,
                                                 nachWechsel: false))
        #expect(!Zeitannahme.bildGehoertDemMedium(bildausgabe: false, gezeigteBilder: 9,
                                                  nachWechsel: true))
    }

    /// Der Start beim Wechsel geht vor der Spurwahl hinaus, ohne Indizes.
    /// Die erste Meldung danach trägt sie — und kommt gleich.
    @Test("Nach dem Wechsel meldet der Takt die Spuren sofort, nicht erst nach zehn Sekunden")
    func wechselSpurenSofort() {
        var s = Wiedergabetakt.Stand(position: 75, erstesBildDa: true,
                                     spurenGesetzt: true, startGemeldet: true)
        Wiedergabetakt.neuerTitel(&s, startGemeldet: true)
        let a = takt(&s, messung(position: 1))
        #expect(a.spurenAnwenden)
        #expect(a.fortschrittMelden)
        #expect(!a.startMelden)
        // Danach wieder im gewohnten Abstand.
        let b = takt(&s, messung(position: 1.5))
        #expect(!b.fortschrittMelden)
    }

    @Test("Beim Öffnen trägt der Start die Spuren, kein Fortschritt hinterher")
    func oeffnenKeinExtraFortschritt() {
        var s = Wiedergabetakt.Stand()
        let a = takt(&s, messung(position: 1))
        #expect(a.startMelden)
        #expect(!a.fortschrittMelden)
        #expect(!takt(&s, messung(position: 1.5)).fortschrittMelden)
    }
}

/// Wann der Ladeschirm weichen darf.
///
/// Die Fristen sind der Kern: zu kurz, und man sieht VLC beim Einsteuern zu;
/// zu lang, und ein klemmender Aufbau bleibt fuer immer verdeckt.
@Suite("Zeitannahme")
struct ZeitannahmeTests {

    private func vor(_ sekunden: TimeInterval) -> Date {
        Date().addingTimeInterval(-sekunden)
    }

    @Test("Steht das Bild und wird nicht eingesteuert, weicht der Ladeschirm sofort")
    func bildDa() {
        #expect(Zeitannahme.bildDa(zeigtBild: true, stelltEin: false, seitStart: vor(1)))
    }

    @Test("Ohne Bild bleibt er, bis die Notbremse greift")
    func notbremse() {
        #expect(!Zeitannahme.bildDa(zeigtBild: false, stelltEin: false, seitStart: vor(5)))
        #expect(Zeitannahme.bildDa(zeigtBild: false, stelltEin: false, seitStart: vor(13)))
    }

    /// Der Fall vom Fernseher: bei grossen Dateien dauert das Einsteuern
    /// laenger als zwoelf Sekunden. Wich der Ladeschirm dort, sah man den Film
    /// bei Sekunde null anlaufen, bis der Sprung sass.
    @Test("Waehrend des Einsteuerns greift die Notbremse nicht")
    func einsteuernUeberdauertNotbremse() {
        #expect(!Zeitannahme.bildDa(zeigtBild: true, stelltEin: true, seitStart: vor(15)))
    }

    /// VLC gibt das Einsteuern nach zwanzig Sekunden selbst auf; die Frist
    /// liegt dahinter, faengt aber den Fall ab, dass auch das klemmt.
    @Test("Irgendwann weicht er auch beim Einsteuern")
    func einsteuernHatEinEnde() {
        #expect(Zeitannahme.bildDa(zeigtBild: true, stelltEin: true, seitStart: vor(30)))
    }

    @Test("Ein Ruecksprung kurz nach dem Oeffnen wird verworfen, spaeter nicht")
    func ruecksprung() {
        #expect(Zeitannahme.position(gemeldet: 5, bisher: 1200, seitStart: vor(2)) == nil)
        #expect(Zeitannahme.position(gemeldet: 5, bisher: 1200, seitStart: vor(20)) == 5)
    }
}

@Suite("Folgenende")
struct FolgenendeTests {

    @Test("Der Knopf erscheint gegen Ende, aber nicht in der Mitte")
    func knopf() {
        #expect(Folgenende.knopfZeigen(position: 3500, dauer: 3600))
        #expect(!Folgenende.knopfZeigen(position: 1800, dauer: 3600))
    }

    /// Sonst stuende er bei einem Vorspann oder kurzen Extra praktisch immer
    /// im Bild.
    @Test("Bei kurzen Titeln erscheint er nie")
    func kurz() {
        #expect(!Folgenende.knopfZeigen(position: 200, dauer: 240))
    }

    /// Das Angebot ist grosszuegig, die Handlung nicht: hier wird gehandelt,
    /// ohne dass jemand darum gebeten hat.
    @Test("Weitergeschaltet wird erst am Ende, nicht schon beim Angebot")
    func weiterschalten() {
        #expect(!Folgenende.weiterschalten(position: 3500, dauer: 3600, seitOeffnen: 600))
        #expect(Folgenende.weiterschalten(position: 3599.5, dauer: 3600, seitOeffnen: 600))

        // **Der Fall vom 04.09.2026.** Mit `:start-time` meldet VLC die
        // Position sofort, die Laenge in denselben Millisekunden noch nicht.
        // Ohne Anlaufruhe schaltete die App 629 ms nach dem Oeffnen weiter.
        #expect(!Folgenende.weiterschalten(position: 3721, dauer: 3721, seitOeffnen: 0.6))
        #expect(Folgenende.weiterschalten(position: 3721, dauer: 3721, seitOeffnen: 6))
    }
}

@Suite("Wiedergabestufen")
struct WiedergabestufenTests {

    @Test("Die Stufen stehen fest und beginnen unter dem Normaltempo")
    func stufen() {
        #expect(Tempostufen.werte == [0.75, 1.0, 1.25, 1.5, 2.0])
        #expect(Schlafzeiten.werte == [15, 30, 45, 60, 90])
    }

    /// Vorher stand dort `String(format: "%g", …)` mit fest ausgetauschtem
    /// Punkt. Auf Englisch las sich das als „1,25×".
    @Test("Normaltempo heisst 1x, nicht 1,0x")
    func ganzeZahl() {
        #expect(Tempostufen.beschriftung(1.0) == "1×")
        #expect(Tempostufen.beschriftung(2.0) == "2×")
    }

    @Test("Das Trennzeichen folgt der Sprache")
    func trennzeichen() {
        let text = Tempostufen.beschriftung(1.25)
        #expect(text.hasSuffix("×"))
        #expect(text.contains("125") == false)
        #expect(text.dropLast().contains(",") || text.dropLast().contains("."))
    }
}

@Suite("Spielzeit")
struct SpielzeitTests {

    @Test("Unter einer Stunde ohne Stundenteil")
    func kurz() {
        #expect(Spielzeit.text(0) == "0:00")
        #expect(Spielzeit.text(65) == "1:05")
        #expect(Spielzeit.text(3599) == "59:59")
    }

    @Test("Ab einer Stunde mit Stundenteil")
    func lang() {
        #expect(Spielzeit.text(3600) == "1:00:00")
        #expect(Spielzeit.text(5025) == "1:23:45")
    }

    /// VLC meldet beim Aufbau auch schon einmal Unsinn.
    @Test("Unsinn ergibt null, keinen Absturz")
    func unsinn() {
        #expect(Spielzeit.text(-5) == "0:00")
        #expect(Spielzeit.text(.nan) == "0:00")
        #expect(Spielzeit.text(.infinity) == "0:00")
    }
}
