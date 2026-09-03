import Foundation
import Testing
@testable import JellyfinKit

@Suite("Stromwacht")
struct StromwachtTests {

    /// Der Normalfall: nichts los, Bild steht lange genug, kein Sprung,
    /// kein Puffer — das ist ein Abriss.
    private func rat(stillstand: TimeInterval, wechsel: TimeInterval? = nil,
                     sprungOffen: Bool = false, sprungVor: TimeInterval = 999,
                     pufferVor: TimeInterval = 999) -> Stromwacht.Rat {
        Stromwacht.rat(stillstandSeit: stillstand, netzwechselVor: wechsel,
                       sprungOffen: sprungOffen, letzterSprungVor: sprungVor,
                       pufferWuchsVor: pufferVor)
    }

    // MARK: - Wie lange gewartet wird

    @Test("Ohne Netzwechsel sechs Sekunden")
    func sechs() {
        #expect(rat(stillstand: 5.9) == .nochNicht)
        #expect(rat(stillstand: 6) == .neuVerbinden)
    }

    @Test("Nach einem Netzwechsel nur zwei")
    func zwei() {
        // Der Grund ist bekannt, Warten bringt nichts.
        #expect(rat(stillstand: 1.9, wechsel: 3) == .nochNicht)
        #expect(rat(stillstand: 2, wechsel: 3) == .neuVerbinden)
    }

    @Test("Ein alter Netzwechsel erklärt nichts mehr")
    func alterWechsel() {
        // 91 s her: gilt nicht mehr als frisch, also wieder sechs Sekunden.
        #expect(rat(stillstand: 3, wechsel: 91) == .nochNicht)
        #expect(rat(stillstand: 3, wechsel: 89) == .neuVerbinden)
    }

    // MARK: - Wer lebt, dem reißt man nichts ab

    @Test("Ein offener Sprung ist kein Abriss")
    func sprungOffen() {
        #expect(rat(stillstand: 30, sprungOffen: true) == .sprungLaeuft)
    }

    @Test("Und zwanzig Sekunden nach dem Befehl auch nicht")
    func sprungruhe() {
        #expect(rat(stillstand: 30, sprungVor: 19.9) == .sprungLaeuft)
        #expect(rat(stillstand: 30, sprungVor: 20) == .neuVerbinden)
    }

    @Test("Ein wachsender Puffer schlägt den Abriss")
    func puffer() {
        // Der Fall, an dem die Bremse einmal den Hänger erzeugt hat.
        #expect(rat(stillstand: 60, pufferVor: 3.9) == .pufferWaechst)
        #expect(rat(stillstand: 60, pufferVor: 4) == .neuVerbinden)
    }

    @Test("Der Sprung schlägt den Puffer")
    func reihenfolge() {
        // Beides zutreffend: die Meldung soll den Sprung nennen, weil der
        // die kürzere Erklärung ist.
        #expect(rat(stillstand: 60, sprungVor: 1, pufferVor: 1) == .sprungLaeuft)
    }

    // MARK: - Ränder

    @Test("Ohne Stillstand passiert nie etwas")
    func keinStillstand() {
        #expect(rat(stillstand: 0) == .nochNicht)
        #expect(rat(stillstand: 0, wechsel: 1) == .nochNicht)
    }
}
