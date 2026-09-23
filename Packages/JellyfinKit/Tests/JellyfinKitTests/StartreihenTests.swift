import Foundation
import Testing
@testable import JellyfinKit

/// **Die Startseite laesst sich einstellen — und darf dabei nicht leerlaufen.**
///
/// Jede Pruefung hier haelt einen Fall fest, in dem eine abgelegte Liste
/// veraltet ist: eine Reihe kam dazu, eine faellt gerade weg, oder die Datei
/// stammt aus einer Fassung, die es noch nicht gab.
@Suite("Reihenfolge der Startseite")
struct StartreihenTests {

    private let alle = Startreihe.allCases.map(\.rawValue)

    @Test("Eine leere Ablage ergibt alle Reihen in ihrer Grundfolge")
    func leereAblage() {
        #expect(Startreihenfolge.geltend(abgelegt: []) == Startreihe.allCases)
    }

    /// **Eine neue Reihe darf nicht still verschwinden.** Die Ablage stammt
    /// von einer Fassung, die `neueSerien` noch nicht kannte; ohne das
    /// Anhaengen fehlte die Reihe dauerhaft, ohne dass es jemand merkt.
    @Test("Was in der Ablage fehlt, haengt hinten an")
    func neueReiheTauchtAuf() {
        let alt = ["neuzugaenge", "weiterschauen"]
        let jetzt = Startreihenfolge.geltend(abgelegt: alt)
        #expect(jetzt.prefix(2).map(\.rawValue) == alt)
        #expect(Set(jetzt) == Set(Startreihe.allCases))
    }

    /// **Der gemeldete Fehler vom 21.09.2026.** Eine Ablage, in der
    /// „neueFilme" zweimal steht, ergab zwei Reihen „Zuletzt hinzugefuegte
    /// Filme" untereinander — und weil `geltend` nur anhaengte, was fehlt,
    /// ueberlebte der Zustand jeden Start und jedes Umsortieren.
    @Test("Eine doppelt abgelegte Reihe kommt einmal zurueck")
    func doppelteAblage() {
        let kaputt = ["weiterschauen", "naechsteFolge", "neueFilme",
                      "neueFilme", "neueSerien", "neuzugaenge"]
        let jetzt = Startreihenfolge.geltend(abgelegt: kaputt)
        #expect(jetzt.count == Startreihe.allCases.count)
        #expect(jetzt.filter { $0 == .neueFilme }.count == 1)
        // Der erste Eintrag gilt: die dritte Stelle bleibt die dritte.
        #expect(jetzt.map(\.rawValue) == ["weiterschauen", "naechsteFolge",
                                          "neueFilme", "neueSerien", "neuzugaenge"])
    }

    /// Auch die sichtbare Liste und das Umsortieren duerfen den Zustand nicht
    /// weitertragen — sonst schriebe der erste Griff an die Einstellungen die
    /// Doppelung wieder zurueck.
    @Test("Sichtbar und Verschieben tragen keine Doppelten weiter")
    func doppelteUeberstehenNichts() {
        let kaputt = ["neueFilme", "neueFilme", "weiterschauen"]
        #expect(Startreihenfolge.sichtbar(abgelegt: kaputt, aus: [], getrennt: true)
                    .filter { $0 == .neueFilme }.count == 1)
        let neu = Startreihenfolge.verschoben(.weiterschauen, um: -1,
                                             abgelegt: kaputt, getrennt: true)
        #expect(neu.count == Startreihe.allCases.count)
        #expect(Set(neu) == Set(alle))
    }

    @Test("Glattziehen ist auf sich selbst angewandt dasselbe")
    func sauberIstStabil() {
        let einmal = Startreihenfolge.sauber([.neueFilme, .weiterschauen, .neueFilme])
        #expect(einmal == [.neueFilme, .weiterschauen])
        #expect(Startreihenfolge.sauber(einmal) == einmal)
    }

    @Test("Unbekannte Namen in der Ablage werden verworfen, nicht uebernommen")
    func unbekanntes() {
        let jetzt = Startreihenfolge.geltend(abgelegt: ["gibtsnicht", "weiterschauen"])
        #expect(jetzt.first == .weiterschauen)
        #expect(jetzt.count == Startreihe.allCases.count)
    }

    /// Getrennt ersetzt die gemeinsame Reihe, es kommt keine dazu.
    @Test("Getrennt zeigt das Paar, sonst die gemeinsame")
    func getrennt() {
        let mit = Startreihenfolge.sichtbar(abgelegt: alle, aus: [], getrennt: true)
        #expect(mit.contains(.neueFilme) && mit.contains(.neueSerien))
        #expect(!mit.contains(.neuzugaenge))

        let ohne = Startreihenfolge.sichtbar(abgelegt: alle, aus: [], getrennt: false)
        #expect(ohne.contains(.neuzugaenge))
        #expect(!ohne.contains(.neueFilme) && !ohne.contains(.neueSerien))
    }

    @Test("Ausgeblendetes steht nicht auf der Seite")
    func ausgeblendet() {
        let sichtbar = Startreihenfolge.sichtbar(abgelegt: alle,
                                                 aus: ["weiterschauen"], getrennt: false)
        #expect(!sichtbar.contains(.weiterschauen))
        #expect(sichtbar.contains(.naechsteFolge))
    }

    @Test("Verschieben tauscht zwei Nachbarn")
    func verschieben() {
        let neu = Startreihenfolge.verschoben(.naechsteFolge, um: -1,
                                              abgelegt: alle, getrennt: false)
        #expect(Startreihenfolge.geltend(abgelegt: neu).first == .naechsteFolge)
    }

    /// **Ueber die Kante hinaus passiert nichts.** Sonst faellt die erste
    /// Reihe ans Ende, und der Nutzer haelt es fuer einen Fehler.
    @Test("Am Rand bleibt die Reihenfolge, wie sie war")
    func amRand() {
        #expect(Startreihenfolge.verschoben(.weiterschauen, um: -1,
                                            abgelegt: alle, getrennt: false) == alle)
    }

    /// Was gerade nicht gilt, darf beim Verschieben nicht mitzaehlen — sonst
    /// spraenge eine Reihe ueber eine Luecke, die niemand sieht.
    @Test("Unsichtbare Reihen zaehlen beim Verschieben nicht mit")
    func unsichtbareZaehlenNicht() {
        // Ohne "getrennt" gibt es neueFilme/neueSerien nicht.
        let neu = Startreihenfolge.verschoben(.neuzugaenge, um: -1,
                                              abgelegt: alle, getrennt: false)
        let sichtbar = Startreihenfolge.sichtbar(abgelegt: neu, aus: [], getrennt: false)
        #expect(sichtbar.map(\.rawValue) == ["weiterschauen", "neuzugaenge", "naechsteFolge"])
        // Und das Paar ueberlebt: es steht weiter in der Ablage.
        #expect(Set(Startreihenfolge.geltend(abgelegt: neu)) == Set(Startreihe.allCases))
    }

    /// Der Name in der Einstellungsliste ist **nicht** die Ueberschrift auf
    /// der Seite. Genau diese Verwechslung stand auf Linux im Code.
    @Test("Listenname und Reihentitel sind verschieden")
    func namen() {
        #expect(Startreihe.neueFilme.listenname == "Neue Filme")
        #expect(Startreihe.neueFilme.reihentitel == "Zuletzt hinzugefügte Filme")
        #expect(Startreihe.weiterschauen.listenname == Startreihe.weiterschauen.reihentitel)
    }
}
