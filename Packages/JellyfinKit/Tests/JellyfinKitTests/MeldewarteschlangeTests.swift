import Foundation
import Testing
@testable import JellyfinKit

/// Die Reihe gegen einen gespielten Server: langsam, tot oder fehlerhaft.
@Suite("Meldewarteschlange")
struct MeldewarteschlangeTests {

    typealias Reihe = Meldewarteschlange<Double>

    /// Was der „Server" in welcher Reihenfolge bekommen hat.
    final class Mitschrift: @unchecked Sendable {
        private let schloss = NSLock()
        private var _zeilen: [String] = []
        func schreiben(_ zeile: String) {
            schloss.lock(); _zeilen.append(zeile); schloss.unlock()
        }
        var zeilen: [String] { schloss.lock(); defer { schloss.unlock() }; return _zeilen }
    }

    static func zeile(_ m: Reihe.Meldung) -> String {
        switch m.art {
        case .start: return "start \(Int(m.nutzlast))"
        case let .fortschritt(pausiert): return "fortschritt \(Int(m.nutzlast))\(pausiert ? " pause" : "")"
        case .stopp: return "stopp \(Int(m.nutzlast))"
        }
    }

    static func meldung(_ art: Reihe.Art, _ sekunden: Double, sitzung: String = "a") -> Reihe.Meldung {
        .init(art: art, schluessel: Stoppsperre.schluessel(itemID: "t", playSessionID: sitzung),
              nutzlast: sekunden)
    }

    @Test("Start → Fortschritt → Stopp bleibt, auch wenn der Start langsam ist")
    func reihenfolgeBeiLangsamemStart() async {
        let mitschrift = Mitschrift()
        let reihe = Reihe { m in
            try? await Task.sleep(for: .milliseconds(m.art == .start ? 300 : 100))
            mitschrift.schreiben(Self.zeile(m))
        }
        // Stopp direkt hinter dem langsamen Start: erst danach.
        reihe.melden(Self.meldung(.start, 0))
        #expect(await reihe.meldenUndWarten(Self.meldung(.stopp, 1)) == .gesendet)
        // Fortschritt schon unterwegs, Stopp kommt hinterher.
        reihe.melden(Self.meldung(.start, 1))
        async let fortschritt = reihe.meldenUndWarten(Self.meldung(.fortschritt(pausiert: false), 10))
        try? await Task.sleep(for: .milliseconds(350))
        let ergebnis = await reihe.meldenUndWarten(Self.meldung(.stopp, 12))
        #expect(await fortschritt == .gesendet)
        #expect(ergebnis == .gesendet)
        #expect(mitschrift.zeilen == ["start 0", "stopp 1", "start 1", "fortschritt 10", "stopp 12"])
    }

    @Test("Stopp der alten Sitzung vor Start der neuen")
    func wechselReihenfolge() async {
        let mitschrift = Mitschrift()
        let reihe = Reihe { m in
            if m.art == .stopp { try? await Task.sleep(for: .milliseconds(200)) }
            mitschrift.schreiben(Self.zeile(m) + " " + m.schluessel)
        }
        reihe.melden(Self.meldung(.stopp, 1400, sitzung: "alt"))
        let ergebnis = await reihe.meldenUndWarten(Self.meldung(.start, 0, sitzung: "neu"))
        #expect(ergebnis == .gesendet)
        #expect(mitschrift.zeilen == ["stopp 1400 sitzung:alt", "start 0 sitzung:neu"])
    }

    @Test("Melden kehrt sofort zurück, auch wenn der Server hängt")
    func meldenBlockiertNicht() async {
        let reihe = Reihe(frist: .seconds(5)) { _ in
            try await Task.sleep(for: .seconds(60))
        }
        let uhr = ContinuousClock()
        let dauer = uhr.measure {
            reihe.melden(Self.meldung(.start, 0))
            for s in 1...20 { reihe.melden(Self.meldung(.fortschritt(pausiert: false), Double(s))) }
        }
        #expect(dauer < .milliseconds(50))
    }

    @Test("Fortschritt wird zusammengefasst, nicht gestapelt")
    func zusammenfassen() async {
        let mitschrift = Mitschrift()
        let reihe = Reihe { m in
            if m.art == .start { try? await Task.sleep(for: .milliseconds(200)) }
            mitschrift.schreiben(Self.zeile(m))
        }
        reihe.melden(Self.meldung(.start, 0))
        for s in [10.0, 20, 30, 40] {
            reihe.melden(Self.meldung(.fortschritt(pausiert: false), s))
        }
        let ergebnis = await reihe.meldenUndWarten(Self.meldung(.fortschritt(pausiert: true), 41))
        #expect(ergebnis == .gesendet)
        #expect(mitschrift.zeilen == ["start 0", "fortschritt 41 pause"])
    }

    @Test("Ein ersetzter Fortschritt, auf den jemand wartet, bekommt das Ergebnis des neuen")
    func ersetzterWartender() async {
        let reihe = Reihe { m in
            if m.art == .start { try? await Task.sleep(for: .milliseconds(200)) }
        }
        reihe.melden(Self.meldung(.start, 0))
        async let erster = reihe.meldenUndWarten(Self.meldung(.fortschritt(pausiert: false), 10))
        try? await Task.sleep(for: .milliseconds(50))
        reihe.melden(Self.meldung(.fortschritt(pausiert: false), 20))
        #expect(await erster == .gesendet)
    }

    @Test("Frist: ein toter Server hält die nächste Meldung nicht auf")
    func fristOhneBlockade() async {
        let mitschrift = Mitschrift()
        let reihe = Reihe(frist: .milliseconds(150)) { m in
            if m.art == .start { try await Task.sleep(for: .seconds(60)) }
            mitschrift.schreiben(Self.zeile(m))
        }
        let uhr = ContinuousClock()
        let beginn = uhr.now
        async let start = reihe.meldenUndWarten(Self.meldung(.start, 0))
        let fortschritt = await reihe.meldenUndWarten(Self.meldung(.fortschritt(pausiert: false), 10))
        let verstrichen = uhr.now - beginn
        #expect(await start == .zeitUeberschritten)
        #expect(fortschritt == .gesendet)
        #expect(verstrichen < .seconds(2))
        #expect(mitschrift.zeilen == ["fortschritt 10"])
    }

    @Test("Ein Fehler blockiert nichts")
    func fehlerBlockiertNicht() async {
        struct Kaputt: Error {}
        let mitschrift = Mitschrift()
        let reihe = Reihe { m in
            if m.art == .start { throw Kaputt() }
            mitschrift.schreiben(Self.zeile(m))
        }
        async let start = reihe.meldenUndWarten(Self.meldung(.start, 0))
        let fortschritt = await reihe.meldenUndWarten(Self.meldung(.fortschritt(pausiert: false), 10))
        #expect(await start == .gescheitert)
        #expect(fortschritt == .gesendet)
    }

    @Test("Stoppsperre: doppelter Stopp und Fortschritt danach verworfen, Start gibt frei")
    func sperre() async {
        let mitschrift = Mitschrift()
        let reihe = Reihe { m in mitschrift.schreiben(Self.zeile(m)) }
        reihe.melden(Self.meldung(.start, 0))
        #expect(await reihe.meldenUndWarten(Self.meldung(.stopp, 5)) == .gesendet)
        #expect(await reihe.meldenUndWarten(Self.meldung(.stopp, 5)) == .verworfen)
        #expect(reihe.melden(Self.meldung(.fortschritt(pausiert: true), 6)) == false)
        #expect(reihe.fortschrittErlaubt(Stoppsperre.schluessel(itemID: "t", playSessionID: "a")) == false)
        reihe.melden(Self.meldung(.start, 5))
        #expect(await reihe.meldenUndWarten(Self.meldung(.fortschritt(pausiert: false), 7)) == .gesendet)
        #expect(mitschrift.zeilen == ["start 0", "stopp 5", "start 5", "fortschritt 7"])
    }

    @Test("Ein gescheiterter Stopp gibt frei, der nächste geht")
    func gescheiterterStopp() async {
        struct Kaputt: Error {}
        let versuche = Mitschrift()
        let reihe = Reihe { m in
            versuche.schreiben(Self.zeile(m))
            if versuche.zeilen.count == 1 { throw Kaputt() }
        }
        #expect(await reihe.meldenUndWarten(Self.meldung(.stopp, 5)) == .gescheitert)
        #expect(await reihe.meldenUndWarten(Self.meldung(.stopp, 5)) == .gesendet)
        #expect(versuche.zeilen == ["stopp 5", "stopp 5"])
    }

    @Test("Der Stopp nimmt den ungesendeten Fortschritt seiner Sitzung mit")
    func stoppNimmtFortschrittMit() async {
        let mitschrift = Mitschrift()
        let reihe = Reihe { m in
            if m.art == .start { try? await Task.sleep(for: .milliseconds(200)) }
            mitschrift.schreiben(Self.zeile(m))
        }
        reihe.melden(Self.meldung(.start, 0))
        async let fortschritt = reihe.meldenUndWarten(Self.meldung(.fortschritt(pausiert: false), 10))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await reihe.meldenUndWarten(Self.meldung(.stopp, 11)) == .gesendet)
        #expect(await fortschritt == .verworfen)
        #expect(mitschrift.zeilen == ["start 0", "stopp 11"])
    }
}
