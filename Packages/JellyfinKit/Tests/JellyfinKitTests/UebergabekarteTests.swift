import Foundation
import Testing
@testable import JellyfinKit

@Suite("Übergabe als Karte (Entwurf B)")
struct UebergabekarteTests {
    typealias K = Uebergabekarte
    let schirm = (b: 390.0, h: 844.0)
    var voll: K.Lage { K.vollbild(breite: schirm.b, hoehe: schirm.h) }
    var ruhe: K.Lage { K.ruhelage(breite: schirm.b, hoehe: schirm.h, masse: K.iPhone) }
    let abzeichen = K.Lage(x: 350, y: 70, breite: 44)

    @Test("Hochkant ist das ganze Bild schirmbreit, quer und am Fernseher 16:9 eingepasst")
    func vollbild() {
        #expect(voll.breite == 390)
        #expect(abs(voll.hoehe - 219.375) < 0.001)
        #expect(abs(K.vollbild(breite: 844, hoehe: 390).breite - 390.0 * 16 / 9) < 1e-9)
        #expect(K.vollbild(breite: 1920, hoehe: 1080).breite == 1920)
    }

    @Test("Die Karte ruht mittig, über der Mitte, mit Platz für zwei Zeilen")
    func ruhelage() {
        #expect(ruhe.x == 195)
        #expect(ruhe.breite == 240)
        #expect(ruhe.y < 422)
        let unten = K.zeilenOben(ruhe, masse: K.iPhone) + 17 * 1.2 + 13 * 1.2
        // Karte und Zeilen zusammen etwa mittig.
        let oben = ruhe.y - ruhe.hoehe / 2
        #expect(abs((oben + unten) / 2 - 422) < 8)
        // Schmale Schirme: höchstens 70 % der Breite.
        #expect(K.ruhelage(breite: 300, hoehe: 600, masse: K.iPhone).breite == 210)
    }

    @Test("Die Karte startet am Abzeichen und steht nach gut einer Sekunde in Ruhe")
    func flug() {
        #expect(K.flug(0, von: abzeichen, nach: ruhe) == abzeichen)
        #expect(K.flug(K.kartenStart, von: abzeichen, nach: ruhe) == abzeichen)
        let spaet = K.flug(1.4, von: abzeichen, nach: ruhe)
        #expect(abs(spaet.x - ruhe.x) < 0.5)
        #expect(abs(spaet.y - ruhe.y) < 0.5)
        #expect(abs(spaet.breite - ruhe.breite) < 0.5)
        // Gerader Weg: kein Bogen, nur ein kleines Nachfedern (Dämpfung 0,86).
        var weitesten = 0.0
        for i in 0 ... 300 {
            let l = K.flug(Double(i) / 200, von: abzeichen, nach: ruhe)
            weitesten = max(weitesten, l.y - ruhe.y)
        }
        #expect(weitesten < (ruhe.y - abzeichen.y) * 0.03)
    }

    @Test("Schweben erst ab kurz vor 0,7 s, höchstens 1,8 Punkt")
    func schweben() {
        #expect(K.schwebeversatz(0.5) == 0)
        #expect(K.schwebeversatz(K.schweben - 0.15) == 0)
        for i in 0 ... 400 {
            #expect(abs(K.schwebeversatz(0.5 + Double(i) / 100)) <= K.schwebHub + 1e-9)
        }
    }

    @Test("Frühestens bei 0,7 s wird gezoomt, sonst beim ersten Bild")
    func zoomBeginn() {
        #expect(K.zoomBeginn(bereit: 0.3) == 0.7)
        #expect(K.zoomBeginn(bereit: 1.9) == 1.9)
    }

    @Test("Der Zoom endet auf dem ganzen Bild, federt höchstens 3 % über")
    func zoom() {
        let start = K.warten(1.2, von: abzeichen, nach: ruhe)
        let v = K.schwung(1.2, von: abzeichen, nach: ruhe)
        #expect(K.zoom(0, von: start, schwung: v, nach: voll) == start)
        let blende = K.zoom(K.kartenAusVon, von: start, schwung: v, nach: voll)
        #expect(blende.breite > voll.breite * 0.9)
        let ruhig = K.zoom(1.5, von: start, schwung: v, nach: voll)
        #expect(abs(ruhig.breite - voll.breite) < 0.5)
        for i in 0 ... 150 {
            #expect(K.zoom(Double(i) / 100, von: start, schwung: v, nach: voll).breite <= voll.breite * 1.03)
        }
    }

    @Test("Drehung unterwegs: die Karte fliegt von ihrer Lage neu in die Querlage")
    func neuAusrichten() {
        let quer = K.ruhelage(breite: 844, hoehe: 390, masse: K.iPhone)
        let jetzt = K.flug(0.5, von: abzeichen, nach: ruhe)
        #expect(K.flug(0.5, von: jetzt, nach: quer, ab: 0.5) == jetzt)
        let spaet = K.flug(2.0, von: jetzt, nach: quer, ab: 0.5)
        #expect(abs(spaet.x - quer.x) < 0.5 && abs(spaet.y - quer.y) < 0.5)
    }

    @Test("Kein Halt zwischen Flug und Zoom: der Zoom übernimmt den Schwung")
    func schwungUebergabe() {
        // Frühes Bild: Zoom bei 0,7 s, die Karte fliegt da noch.
        let tz = K.zoomBeginn(bereit: 0.3)
        let start = K.warten(tz, von: abzeichen, nach: ruhe)
        let v = K.schwung(tz, von: abzeichen, nach: ruhe)
        #expect(abs(v.y) > 1)
        let h = 1.0 / 240
        let z = K.zoom(h, von: start, schwung: v, nach: voll)
        let vz = (z.y - start.y) / h
        #expect(abs(vz - v.y) < max(20, abs(v.y) * 0.2))
    }

    @Test("Ecke: in Ruhe 12, am ganzen Bild 0, klein nie eine Pille")
    func ecke() {
        #expect(K.ecke(ruhe, masse: K.iPhone, voll: voll) == 12)
        #expect(K.ecke(voll, masse: K.iPhone, voll: voll) == 0)
        #expect(K.ecke(abzeichen, masse: K.iPhone, voll: voll) <= 44 * 0.055)
    }

    @Test("Zeilen kommen nach dem Flug und gehen mit dem Zoom")
    func zeilen() {
        #expect(K.zeilendeckung(0.3, zoomAb: nil) == 0)
        #expect(K.zeilendeckung(0.8, zoomAb: nil) == 1)
        #expect(K.zeilendeckung(1.0, zoomAb: 0.8) == 0)
        #expect(K.buehnendeckung(nachZoom: 0.2) == 1)
        #expect(K.buehnendeckung(nachZoom: K.kartenAusBis) == 0)
    }

    @Test("Ladelinie nur, wenn das Bild bei 0,75 s noch fehlt")
    func ladelinie() {
        #expect(!K.ladelinie(bereit: 0.4))
        #expect(K.ladelinie(bereit: 1.5))
        #expect(K.ladelinie(bereit: nil))
    }

    @Test("Abgeber als Spiegelbild: schrumpft mit der Zoomfeder, fliegt mit der Flugfeder nach oben hinaus")
    func abgang() {
        let quer = K.vollbild(breite: 844, hoehe: 390)
        let karte = K.ruhelage(breite: 844, hoehe: 390, masse: K.iPhone)
        #expect(K.abgang(0.1, voll: quer, karte: karte) == quer)
        // Schrumpfen = Zoom rückwärts: nach derselben Zeit derselbe Anteil des Wegs.
        let u = 0.3
        let ab = K.abgang(K.abgangStart + u, voll: quer, karte: karte)
        let zu = K.zoom(u, von: karte, schwung: .init(x: 0, y: 0, breite: 0), nach: quer)
        let anteilAb = (quer.breite - ab.breite) / (quer.breite - karte.breite)
        let anteilZu = (zu.breite - karte.breite) / (quer.breite - karte.breite)
        #expect(abs(anteilAb - anteilZu) < 1e-9)
        // Vor dem Abflug ruht sie (bis aufs Schweben) in der Ruhelage.
        let ruhig = K.abgang(K.abflug, voll: quer, karte: karte)
        #expect(abs(ruhig.breite - karte.breite) < 1)
        #expect(abs(ruhig.y - karte.y) < K.schwebHub + 1)
        // Kein Sprung beim Abflug.
        let danach = K.abgang(K.abflug + 1.0 / 240, voll: quer, karte: karte)
        #expect(abs(danach.y - ruhig.y) < 3)
        // Dann ganz oben hinaus, und der Player schließt erst danach.
        let raus = K.abgangRaus(voll: quer, karte: karte)
        #expect(raus > K.abflug && raus < K.abflug + 1)
        let l = K.abgang(raus, voll: quer, karte: karte)
        #expect(l.y + l.hoehe / 2 < 0)
        #expect(K.abgangZeilendeckung(K.abflug - 0.01) == 1)
        #expect(K.abgangZeilendeckung(K.abflug + K.zeilenAus) == 0)
    }

    @Test("Abflugrichtung nach Gerätegröße: zum Größeren hoch, zum Kleineren runter")
    func abflugrichtung() {
        #expect(K.abflugNachOben(von: "iPhone", nach: "Apple TV"))
        #expect(!K.abflugNachOben(von: "Apple TV", nach: "iPhone"))
        #expect(!K.abflugNachOben(von: "Mac", nach: "iPad"))
        #expect(K.abflugNachOben(von: "iPad", nach: "Mac"))
        #expect(K.abflugNachOben(von: "iPhone", nach: "iPhone"))
        #expect(K.abflugNachOben(von: "Apple TV", nach: "Wohnzimmer"))
        // Ein Schreibtisch zählt wie der Mac.
        #expect(!K.abflugNachOben(von: "Linux", nach: "iPhone"))
        #expect(K.abflugNachOben(von: "Windows", nach: "Apple TV"))
        #expect(!K.abflugNachOben(von: "Apple TV", nach: "Linux"))
        #expect(K.abflugNachOben(von: "Linux", nach: "Mac"))
        #expect(K.abflugNachOben(von: "Android", nach: "Android TV"))
        #expect(!K.abflugNachOben(von: "Android TV", nach: "iPhone"))
        #expect(!K.abflugNachOben(von: "Mac", nach: "Android"))
        // Nach unten: ganz unten hinaus.
        let tv = K.vollbild(breite: 1920, hoehe: 1080)
        let karte = K.ruhelage(breite: 1920, hoehe: 1080, masse: K.fernseher)
        let raus = K.abgangRaus(voll: tv, karte: karte, richtung: .unten)
        #expect(raus > K.abflug && raus < K.abflug + 1)
        let l = K.abgang(raus, voll: tv, karte: karte, richtung: .unten)
        #expect(l.y - l.hoehe / 2 > 1080)
    }

    @Test("Physisch oben aus der Schwerkraft, in Koordinaten der Oberfläche")
    func physischOben() {
        func nah(_ a: K.Richtung, _ b: K.Richtung) -> Bool { abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 }
        // Hochkant gehalten, Oberfläche hochkant: oben ist oben.
        #expect(nah(K.abflugrichtung(schwerkraftX: 0, schwerkraftY: -1, oberflaeche: .hoch, nachOben: true), .oben))
        // Hochkant gehalten, Player noch quer (Home rechts): oben ist die linke Seite.
        #expect(nah(K.abflugrichtung(schwerkraftX: 0, schwerkraftY: -1, oberflaeche: .querHomeRechts, nachOben: true),
                    .init(x: -1, y: 0)))
        #expect(nah(K.abflugrichtung(schwerkraftX: 0, schwerkraftY: -1, oberflaeche: .querHomeLinks, nachOben: true),
                    .init(x: 1, y: 0)))
        // Quer gehalten (Home rechts, Oberkante links): Schwerkraft zeigt zur
        // linken Seite des Geräts (−x) — oben ist oben.
        #expect(nah(K.abflugrichtung(schwerkraftX: -1, schwerkraftY: 0, oberflaeche: .querHomeRechts, nachOben: true), .oben))
        #expect(nah(K.abflugrichtung(schwerkraftX: 1, schwerkraftY: 0, oberflaeche: .querHomeLinks, nachOben: true), .oben))
        // Zum kleineren Gerät: physisch unten.
        #expect(nah(K.abflugrichtung(schwerkraftX: 0, schwerkraftY: -1, oberflaeche: .hoch, nachOben: false), .unten))
        // Schräg bleibt schräg (Einheitsvektor).
        let s = K.abflugrichtung(schwerkraftX: -0.5, schwerkraftY: -0.5, oberflaeche: .hoch, nachOben: true)
        #expect(abs(s.x * s.x + s.y * s.y - 1) < 1e-9 && s.x > 0 && s.y < 0)
        // Flach auf dem Tisch: das Oben der Oberfläche.
        #expect(K.abflugrichtung(schwerkraftX: 0.1, schwerkraftY: 0.1, oberflaeche: .querHomeRechts, nachOben: true) == .oben)
        #expect(K.abflugrichtung(schwerkraftX: 0.1, schwerkraftY: 0.1, oberflaeche: .hoch, nachOben: false) == .unten)
        // Seitlich hinaus ist sie auch ganz draußen.
        let quer = K.vollbild(breite: 844, hoehe: 390)
        let karte = K.ruhelage(breite: 844, hoehe: 390, masse: K.iPhone)
        let links = K.Richtung(x: -1, y: 0)
        let l = K.abgang(K.abgangRaus(voll: quer, karte: karte, richtung: links), voll: quer, karte: karte, richtung: links)
        #expect(l.x + l.breite / 2 < 0)
    }

    @Test("Stützpunkte: gleich verteilt, erster und letzter Wert auf den Grenzen")
    func stuetzpunkte() {
        let w = K.stuetzpunkte(von: 0, bis: 1) { $0 }
        #expect(w.count == 121)
        #expect(w.first == 0 && w.last == 1)
    }

    @Test("Übernahme-Hinweis: nur Swiftly Player, nur frisch")
    func hinweis() {
        func s(_ p: String?) -> Fremdsitzung {
            Fremdsitzung(id: "s", geraeteID: "g", geraetename: "Wohnzimmer", programm: p,
                         nimmtBefehle: true, laeuft: nil, stand: nil)
        }
        #expect(Uebernahme.nimmtHinweis(s("Swiftly Player")))
        #expect(Uebernahme.nimmtHinweis(s("Swiftly")))
        #expect(!Uebernahme.nimmtHinweis(s("Swiftly Music")))
        #expect(!Uebernahme.nimmtHinweis(s("Jellyfin Web")))
        #expect(!Uebernahme.nimmtHinweis(s(nil)))
        #expect(Uebernahme.istUebergabe(hinweisVor: 0.2))
        #expect(!Uebernahme.istUebergabe(hinweisVor: nil))
        #expect(!Uebernahme.istUebergabe(hinweisVor: 5))
        #expect(!Uebernahme.istUebergabe(hinweisVor: -1))
    }

    @Test("Der Hinweis wird gelesen — nur mit unserem Kopf")
    func hinweisLesen() throws {
        func roh(_ s: String) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
        }
        let unser = try roh(#"{"MessageType":"GeneralCommand","Data":{"Name":"DisplayMessage","Arguments":{"Header":"Swiftly-Uebernahme","Text":"iPhone"}}}"#)
        #expect(Fernsteuerung.uebergabeHinweis(unser) == "iPhone")
        let fremd = try roh(#"{"MessageType":"GeneralCommand","Data":{"Name":"DisplayMessage","Arguments":{"Header":"Hallo","Text":"x"}}}"#)
        #expect(Fernsteuerung.uebergabeHinweis(fremd) == nil)
    }
}
