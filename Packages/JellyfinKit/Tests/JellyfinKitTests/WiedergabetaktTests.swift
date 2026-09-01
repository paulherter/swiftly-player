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
                      stelltWiederHer: Bool = false, sprungLaeuft: Bool = false,
                      amSchieben: Bool = false,
                      seitStart: Date = Date()) -> Wiedergabetakt.Auftrag {
        Wiedergabetakt.rechnen(&stand, messung: m, stelltWiederHer: stelltWiederHer,
                               sprungLaeuft: sprungLaeuft, amSchieben: amSchieben,
                               seitStart: seitStart)
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
        #expect(!Folgenende.weiterschalten(position: 3500, dauer: 3600))
        #expect(Folgenende.weiterschalten(position: 3599.5, dauer: 3600))
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
