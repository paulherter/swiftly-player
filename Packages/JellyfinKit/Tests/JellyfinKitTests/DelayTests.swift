import Foundation
import Testing
@testable import JellyfinKit

@Suite("Verzoegerung")
struct DelayTests {

    @Test("Ein Schritt sind 50 ms, in beide Richtungen")
    func step() {
        #expect(Delay.null.shifted(1).milliseconds == 50)
        #expect(Delay.null.shifted(-1).milliseconds == -50)
        #expect(Delay(milliseconds: 200).shifted(1, steps: 5).milliseconds == 450)
    }

    @Test("Grenzen bei plus und minus zehn Sekunden")
    func limits() {
        let top = Delay(milliseconds: 9_950).shifted(1, steps: 5)
        #expect(top.milliseconds == 10_000)
        #expect(top.atEnd)
        #expect(top.shifted(1) == top)
        let bottom = Delay(milliseconds: -12_000)
        #expect(bottom.milliseconds == -10_000)
        #expect(bottom.atStart)
    }

    @Test("Immer ein Vielfaches des Schritts")
    func grid() {
        #expect(Delay(milliseconds: 74).milliseconds == 50)
        #expect(Delay(milliseconds: 75).milliseconds == 100)
        #expect(Delay(milliseconds: -75).milliseconds == -100)
    }

    @Test("Mikrosekunden hin und zurueck, auch mit Rundungsrest")
    func microseconds() {
        #expect(Delay(milliseconds: 250).microseconds == 250_000)
        #expect(Delay(microseconds: 199_999).milliseconds == 200)
        #expect(Delay(microseconds: -10_000_000).milliseconds == -10_000)
        #expect(!Delay(milliseconds: 200).softOff(fromMicroseconds: 199_999))
        #expect(Delay(milliseconds: 200).softOff(fromMicroseconds: 0))
    }

    @Test("Anzeige mit Vorzeichen, zwei Stellen und Komma nach Sprache")
    func text() {
        let de = Locale(identifier: "de_DE"), en = Locale(identifier: "en_US")
        // The unit comes from the catalog ("s", in Russian "с"), so the expectation asks
        // the catalog too instead of assuming the test machine's language.
        let unit = translated("\("") s")
        #expect(unit == " s" || unit == " с")
        #expect(Delay(milliseconds: 200).text(locale: de) == "+0,20" + unit)
        #expect(Delay(milliseconds: -1_550).text(locale: de) == "\u{2212}1,55" + unit)
        #expect(Delay(milliseconds: 50).text(locale: en) == "+0.05" + unit)
        #expect(Delay.null.text(locale: de) == "0,00" + unit)
        #expect(Delay(milliseconds: 10_000).text(locale: de) == "+10,00" + unit)
    }

    @Test("Gedrueckt halten wird schneller, nie langsamer")
    func hold() {
        #expect(Delay.steps(onRepetition: 0) == 1)
        var before = 0
        for n in 0..<60 {
            let s = Delay.steps(onRepetition: n)
            #expect(s >= before)
            before = s
        }
        #expect(before > 1)
    }

    @Test("Haltezaehler: dichte Druecke sind eine Reihe, eine Pause beginnt neu")
    func holdCounter() {
        var z = Delay.HoldCounter()
        let t0 = Date(timeIntervalSince1970: 0)
        var steps: [Int] = []
        for i in 0..<40 { steps.append(z.press(now: t0.addingTimeInterval(Double(i) * 0.1))) }
        #expect(steps.first == 1)
        #expect(steps.last == 5)
        #expect(z.press(now: t0.addingTimeInterval(10)) == 1)
    }

    @Test("Dieselbe Serie behaelt den Wert, alles andere beginnt bei null")
    func keep() {
        let value = Delay(milliseconds: 300)
        func new(_ a: String, _ sa: String?, _ b: String, _ sb: String?) -> Delay {
            Delay.forNewTitle(value, oldTitle: a, oldSeries: sa, newTitle: b, addedSeries: sb)
        }
        #expect(new("f1", "s", "f2", "s") == value)
        #expect(new("f1", "s", "f2", "t") == .null)
        #expect(new("film", nil, "anderer", nil) == .null)
        #expect(new("f1", "s", "film", nil) == .null)
        // The same film reloaded (different quality) keeps it.
        #expect(new("film", nil, "film", nil) == value)
    }
}
