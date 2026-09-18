import Foundation
import Testing
@testable import JellyfinKit

/// Der Folgenwechsel als Zustandsmaschine — die Fälle aus dem Audit vom
/// 16.09.2026 (Teil 1 H1, H3, M4, M6; Teil 3 #13), ohne Player und ohne Server.
@MainActor
@Suite("Folgenwechsel")
struct FolgenwechselTests {

    /// Hält einen Abruf an, bis der Test ihn freigibt.
    actor Tor {
        private var offen = false
        private var wartende: [CheckedContinuation<Void, Never>] = []
        func warten() async {
            if offen { return }
            await withCheckedContinuation { wartende.append($0) }
        }
        func oeffnen() {
            offen = true
            wartende.forEach { $0.resume() }
            wartende = []
        }
    }

    /// Was an den „Server" ging, in Reihenfolge.
    actor Buch {
        private(set) var eintraege: [String] = []
        func schreib(_ s: String) { eintraege.append(s) }
        func anzahl(_ s: String) -> Int { eintraege.filter { $0 == s }.count }
    }

    @MainActor final class Ansicht {
        var angewandt: [String] = []
        var gescheitert = 0
    }

    private func schritte(buch: Buch, ansicht: Ansicht, plan: String? = "plan-2",
                          planTor: Tor? = nil, startTor: Tor? = nil)
        -> Folgenwechsel.Schritte<String> {
        .init(
            stoppen: { await buch.schreib("stopp-1") },
            planen: {
                await buch.schreib("plant")
                await planTor?.warten()
                return plan
            },
            anwenden: { ansicht.angewandt.append($0) },
            starten: { p in
                await buch.schreib("start-" + p)
                await startTor?.warten()
                await buch.schreib("gestartet")
            },
            gescheitert: { ansicht.gescheitert += 1 })
    }

    private func bis(_ bedingung: () async -> Bool) async {
        for _ in 0..<10_000 {
            if await bedingung() { return }
            await Task.yield()
        }
        Issue.record("Bedingung nie erreicht")
    }

    @Test("Zweiter Auslöser während des Wechsels wird gesperrt; ein Stopp, ein Start")
    func doppelterAusloeser() async {
        let w = Folgenwechsel(), buch = Buch(), ansicht = Ansicht(), tor = Tor()
        let erster = Task { await w.ausfuehren(schritte(buch: buch, ansicht: ansicht, planTor: tor)) }
        await bis { await buch.anzahl("plant") == 1 }
        #expect(w.laeuft)
        #expect(!w.meldungenErlaubt)

        let zweiter = await w.ausfuehren(schritte(buch: buch, ansicht: ansicht))
        #expect(zweiter == .gesperrt)

        await tor.oeffnen()
        #expect(await erster.value == .gewechselt)
        #expect(await buch.anzahl("stopp-1") == 1)
        #expect(await buch.anzahl("start-plan-2") == 1)
        #expect(ansicht.angewandt == ["plan-2"])
        #expect(!w.laeuft)
        #expect(w.meldungenErlaubt)
    }

    @Test("Schließen während des Planholens: nichts wird angewandt, nichts gestartet")
    func schliessenBeimPlanen() async {
        let w = Folgenwechsel(), buch = Buch(), ansicht = Ansicht(), tor = Tor()
        let lauf = Task { await w.ausfuehren(schritte(buch: buch, ansicht: ansicht, planTor: tor)) }
        await bis { await buch.anzahl("plant") == 1 }

        w.schliessen { await buch.schreib("stopp-schliessen") }
        await tor.oeffnen()

        #expect(await lauf.value == .abgebrochen)
        #expect(ansicht.angewandt.isEmpty)
        #expect(await buch.anzahl("start-plan-2") == 0)
        await bis { await buch.anzahl("stopp-schliessen") == 1 }
        #expect(w.phase == .geschlossen)
        // Nach dem Schließen startet kein neuer Wechsel.
        #expect(await w.ausfuehren(schritte(buch: buch, ansicht: ansicht)) == .gesperrt)
    }

    @Test("Schließen während der Start unterwegs ist: Stopp erst nach dem Start")
    func schliessenBeimStarten() async {
        let w = Folgenwechsel(), buch = Buch(), ansicht = Ansicht(), tor = Tor()
        let lauf = Task { await w.ausfuehren(schritte(buch: buch, ansicht: ansicht, startTor: tor)) }
        await bis { await buch.anzahl("start-plan-2") == 1 }

        w.schliessen { await buch.schreib("stopp-2") }
        // Noch nicht: der Start ist nicht zurück.
        for _ in 0..<50 { await Task.yield() }
        #expect(await buch.anzahl("stopp-2") == 0)

        await tor.oeffnen()
        #expect(await lauf.value == .abgebrochen)
        // Stopp der alten Folge und Planholen laufen nebeneinander; ihre
        // Reihenfolge ist offen, der Rest nicht.
        let eintraege = await buch.eintraege
        #expect(Array(eintraege.suffix(3)) == ["start-plan-2", "gestartet", "stopp-2"])
        #expect(Set(eintraege.prefix(2)) == ["stopp-1", "plant"])
    }

    @Test("Kein Plan: Hinweis, Riegel fällt, der nächste Versuch geht")
    func planFehlt() async {
        let w = Folgenwechsel(), buch = Buch(), ansicht = Ansicht()
        #expect(await w.ausfuehren(schritte(buch: buch, ansicht: ansicht, plan: nil)) == .gescheitert)
        #expect(ansicht.gescheitert == 1)
        #expect(ansicht.angewandt.isEmpty)
        #expect(await buch.anzahl("start-plan-2") == 0)
        #expect(!w.laeuft)
        #expect(await w.ausfuehren(schritte(buch: buch, ansicht: ansicht)) == .gewechselt)
    }

    @Test("Zweites Schließen tut nichts")
    func zweimalSchliessen() async {
        let w = Folgenwechsel(), buch = Buch()
        w.schliessen { await buch.schreib("stopp") }
        w.schliessen { await buch.schreib("stopp") }
        await bis { await buch.anzahl("stopp") == 1 }
        for _ in 0..<50 { await Task.yield() }
        #expect(await buch.anzahl("stopp") == 1)
    }

    @Test("Nachschlag nach einem neuen Wechsel oder nach dem Schließen wird verworfen")
    func nachschlag() async {
        let w = Folgenwechsel(), buch = Buch(), ansicht = Ansicht(), tor = Tor()
        var uebernommen: [String] = []

        await w.nachschlagen(holen: { "folge-3" }, uebernehmen: { uebernommen.append($0) })
        #expect(uebernommen == ["folge-3"])

        let alt = Task { @MainActor in
            await w.nachschlagen(holen: { await tor.warten(); return "alt" },
                                 uebernehmen: { uebernommen.append($0) })
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(await w.ausfuehren(schritte(buch: buch, ansicht: ansicht)) == .gewechselt)
        await tor.oeffnen()
        await alt.value
        #expect(uebernommen == ["folge-3"])

        w.schliessen {}
        await w.nachschlagen(holen: { "zu" }, uebernehmen: { uebernommen.append($0) })
        #expect(uebernommen == ["folge-3"])
    }
}

@Suite("Stoppsperre")
struct StoppsperreTests {

    @Test("Stopp genau einmal je Sitzung, Fortschritt danach verworfen")
    func einmal() {
        let s = Stoppsperre()
        let k = Stoppsperre.schluessel(itemID: "a", playSessionID: "p1")
        #expect(s.fortschrittErlaubt(k))
        #expect(s.stoppAnnehmen(k))
        #expect(!s.stoppAnnehmen(k))
        #expect(!s.fortschrittErlaubt(k))
        // Andere Sitzung desselben Titels ist frei.
        #expect(s.stoppAnnehmen(Stoppsperre.schluessel(itemID: "a", playSessionID: "p2")))
    }

    @Test("Gescheiterter Stopp und neuer Start geben frei")
    func freigeben() {
        let s = Stoppsperre()
        let k = Stoppsperre.schluessel(itemID: "a", playSessionID: nil)
        #expect(s.stoppAnnehmen(k))
        s.stoppGescheitert(k)
        #expect(s.stoppAnnehmen(k))
        s.gestartet(k)
        #expect(s.fortschrittErlaubt(k))
        #expect(s.stoppAnnehmen(k))
    }
}
