import Foundation
import Testing
@testable import JellyfinKit

@Suite("Verzoegerung")
struct VerzoegerungTests {

    @Test("Ein Schritt sind 50 ms, in beide Richtungen")
    func schritt() {
        #expect(Verzoegerung.null.verschoben(1).millisekunden == 50)
        #expect(Verzoegerung.null.verschoben(-1).millisekunden == -50)
        #expect(Verzoegerung(millisekunden: 200).verschoben(1, schritte: 5).millisekunden == 450)
    }

    @Test("Grenzen bei plus und minus zehn Sekunden")
    func grenzen() {
        let oben = Verzoegerung(millisekunden: 9_950).verschoben(1, schritte: 5)
        #expect(oben.millisekunden == 10_000)
        #expect(oben.amEnde)
        #expect(oben.verschoben(1) == oben)
        let unten = Verzoegerung(millisekunden: -12_000)
        #expect(unten.millisekunden == -10_000)
        #expect(unten.amAnfang)
    }

    @Test("Immer ein Vielfaches des Schritts")
    func raster() {
        #expect(Verzoegerung(millisekunden: 74).millisekunden == 50)
        #expect(Verzoegerung(millisekunden: 75).millisekunden == 100)
        #expect(Verzoegerung(millisekunden: -75).millisekunden == -100)
    }

    @Test("Mikrosekunden hin und zurueck, auch mit Rundungsrest")
    func mikrosekunden() {
        #expect(Verzoegerung(millisekunden: 250).mikrosekunden == 250_000)
        #expect(Verzoegerung(mikrosekunden: 199_999).millisekunden == 200)
        #expect(Verzoegerung(mikrosekunden: -10_000_000).millisekunden == -10_000)
        #expect(!Verzoegerung(millisekunden: 200).weichtAb(vonMikrosekunden: 199_999))
        #expect(Verzoegerung(millisekunden: 200).weichtAb(vonMikrosekunden: 0))
    }

    @Test("Anzeige mit Vorzeichen, zwei Stellen und Komma nach Sprache")
    func text() {
        let de = Locale(identifier: "de_DE"), en = Locale(identifier: "en_US")
        #expect(Verzoegerung(millisekunden: 200).text(locale: de) == "+0,20 s")
        #expect(Verzoegerung(millisekunden: -1_550).text(locale: de) == "\u{2212}1,55 s")
        #expect(Verzoegerung(millisekunden: 50).text(locale: en) == "+0.05 s")
        #expect(Verzoegerung.null.text(locale: de) == "0,00 s")
        #expect(Verzoegerung(millisekunden: 10_000).text(locale: de) == "+10,00 s")
    }

    @Test("Gedrueckt halten wird schneller, nie langsamer")
    func halten() {
        #expect(Verzoegerung.schritte(beiWiederholung: 0) == 1)
        var vorher = 0
        for n in 0..<60 {
            let s = Verzoegerung.schritte(beiWiederholung: n)
            #expect(s >= vorher)
            vorher = s
        }
        #expect(vorher > 1)
    }

    @Test("Haltezaehler: dichte Druecke sind eine Reihe, eine Pause beginnt neu")
    func haltezaehler() {
        var z = Verzoegerung.Haltezaehler()
        let t0 = Date(timeIntervalSince1970: 0)
        var schritte: [Int] = []
        for i in 0..<40 { schritte.append(z.druck(jetzt: t0.addingTimeInterval(Double(i) * 0.1))) }
        #expect(schritte.first == 1)
        #expect(schritte.last == 5)
        #expect(z.druck(jetzt: t0.addingTimeInterval(10)) == 1)
    }

    @Test("Dieselbe Serie behaelt den Wert, alles andere beginnt bei null")
    func behalten() {
        let wert = Verzoegerung(millisekunden: 300)
        func neu(_ a: String, _ sa: String?, _ b: String, _ sb: String?) -> Verzoegerung {
            Verzoegerung.fuerNeuenTitel(wert, alterTitel: a, alteSerie: sa, neuerTitel: b, neueSerie: sb)
        }
        #expect(neu("f1", "s", "f2", "s") == wert)
        #expect(neu("f1", "s", "f2", "t") == .null)
        #expect(neu("film", nil, "anderer", nil) == .null)
        #expect(neu("f1", "s", "film", nil) == .null)
        // Derselbe Film neu geladen (andere Qualitaet) behaelt ihn.
        #expect(neu("film", nil, "film", nil) == wert)
    }
}
