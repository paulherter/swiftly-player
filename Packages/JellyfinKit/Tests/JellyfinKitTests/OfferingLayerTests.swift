import Testing
import Foundation
@testable import JellyfinKit

/// The overlay above the picture: skip, countdown, pause, controls.
struct OfferingLayerTests {

    private let intro = ButtonOffering.skip(to: 90, art: .introSegment)

    /// Ticks of half a second each, like `PlaybackTick`.
    @discardableResult
    private func runningCount(_ e: inout OfferingLayer, _ seconds: Double, offering: ButtonOffering,
                        card: Bool = false, running: Bool = true,
                        countdown: Double = OfferingLayer.countdown) -> Int {
        var triggered = 0
        for _ in 0..<Int(seconds * 2) {
            if e.tick(offering: offering, cardDue: card, running: running,
                      elapsed: 0.5, countdown: countdown) { triggered += 1 }
        }
        return triggered
    }

    @Test("Überspringen steht ab Beginn sechs Sekunden über dem Bild und blendet dann aus")
    func skipFadeOut() {
        var e = OfferingLayer()
        runningCount(&e, 5.5, offering: intro)
        #expect(e.display == .button(intro))
        runningCount(&e, 0.5, offering: intro)
        #expect(e.display == .nothing, "nach sechs Sekunden ohne Drücken weg")
        runningCount(&e, 60, offering: intro)
        #expect(e.display == .nothing, "und kommt ohne Steuerung nicht wieder")
        let closed = e.close()
        #expect(!closed, "Zurück gehört dann dem Player")
    }

    @Test("Nach Ablauf kommt der Knopf mit der Steuerung und geht mit ihr, jedes Mal")
    func skipWithControls() {
        var e = OfferingLayer()
        runningCount(&e, 8, offering: intro)
        #expect(e.display == .nothing)
        e.controls(opened: true)
        #expect(e.display == .button(intro), "Steuerung auf: Knopf da")
        runningCount(&e, 10, offering: intro)
        #expect(e.display == .button(intro), "solange sie offen ist")
        e.controls(opened: false)
        #expect(e.display == .nothing, "Steuerung zu: Knopf weg")
        e.controls(opened: true, through: .beside)
        #expect(e.display == .button(intro), "auch mit dem Zeiger geöffnet")
        e.controls(opened: false)
        #expect(e.display == .nothing)
        e.controls(opened: true)
        runningCount(&e, 1, offering: .nobody)
        #expect(e.display == .nothing, "der Abschnitt ist vorbei")
    }

    @Test("Die sechs Sekunden laufen auch bei offener Steuerung und stehen in der Pause")
    func buttonTime() {
        var e = OfferingLayer()
        e.controls(opened: true)
        runningCount(&e, 7, offering: intro)
        #expect(e.display == .button(intro))
        e.controls(opened: false)
        #expect(e.display == .nothing, "Zu nach Ablauf nimmt ihn mit")

        var p = OfferingLayer()
        runningCount(&p, 3, offering: intro)
        runningCount(&p, 30, offering: intro, running: false)
        #expect(p.display == .button(intro), "Pause hält die Zeit an")
        runningCount(&p, 3, offering: intro)
        #expect(p.display == .nothing)
    }

    @Test("Ein neuer Abschnitt fängt die sechs Sekunden neu an")
    func newSection() {
        var e = OfferingLayer()
        runningCount(&e, 8, offering: intro)
        #expect(e.display == .nothing)
        runningCount(&e, 1, offering: .nobody)
        let lookBack = ButtonOffering.skip(to: 300, art: .lookBack)
        runningCount(&e, 1, offering: lookBack)
        #expect(e.display == .button(lookBack))
    }

    @Test("Nach einem Sprung erscheint und verschwindet der Knopf im selben Aufruf")
    func immediatePostJump() {
        var e = OfferingLayer()
        runningCount(&e, 2, offering: .nobody)
        _ = e.tick(offering: intro, cardDue: false, running: true, elapsed: 0)
        #expect(e.display == .button(intro))
        _ = e.tick(offering: .nobody, cardDue: false, running: true, elapsed: 0)
        #expect(e.display == .nothing)
    }

    @Test("In den ersten sechs Sekunden ändern Auf und Zu der Steuerung nichts")
    func controlsOpenClose() {
        var e = OfferingLayer()
        runningCount(&e, 1, offering: intro)
        e.controls(opened: true)
        #expect(e.display == .button(intro))
        runningCount(&e, 1, offering: intro)
        e.controls(opened: false)
        runningCount(&e, 1, offering: intro)
        #expect(e.display == .button(intro))
        e.controls(opened: true)
        e.controls(opened: false)
        #expect(e.display == .button(intro))
        runningCount(&e, 1, offering: .nobody)
        #expect(e.display == .nothing, "erst das Ende des Abschnitts nimmt ihn weg")
    }

    @Test("Steuerung schon offen, als der Abschnitt begann: der Knopf steht trotzdem")
    func controlsBeforeOpen() {
        var e = OfferingLayer()
        e.controls(opened: true)
        runningCount(&e, 1, offering: intro)
        #expect(e.display == .button(intro))
        e.controls(opened: false)
        #expect(e.display == .button(intro))
    }

    @Test("Zurück schließt den Knopf, ein neues Angebot kommt wieder")
    func back() {
        var e = OfferingLayer()
        runningCount(&e, 1, offering: intro)
        let firstOne = e.close()
        #expect(firstOne)
        #expect(e.display == .nothing)
        let second = e.close()
        #expect(!second, "zweites Zurück verlässt den Player")
        runningCount(&e, 1, offering: .nobody)
        runningCount(&e, 1, offering: intro)
        #expect(e.display == .button(intro))
    }

    @Test("Ohne Abspann-Abschnitt keine Karte und nie ein Wechsel")
    func nextOnlyWithCard() {
        var e = OfferingLayer()
        #expect(runningCount(&e, 60, offering: .nextEpisode, card: false) == 0)
        #expect(e.display == .nothing)
        #expect(!e.nextAtEnd)
    }

    @Test("Mit Abspann: Karte bleibt stehen, füllt sich in sieben Sekunden und wechselt erst danach, genau einmal")
    func countdown() {
        var e = OfferingLayer()
        runningCount(&e, 6.5, offering: .nextEpisode, card: true)
        #expect(e.display == .card(share: 6.5 / 7))
        #expect(e.countdownRest == 1)
        #expect(e.nextAtEnd)
        #expect(runningCount(&e, 0.5, offering: .nextEpisode, card: true) == 0)
        #expect(e.display == .card(share: 1), "rechnerisch voll …")
        #expect(runningCount(&e, 0.5, offering: .nextEpisode, card: true) == 0,
                "… sichtbar voll erst nach dem Nachziehen, dann eine kurze Ruhe")
        #expect(runningCount(&e, 0.5, offering: .nextEpisode, card: true) == 1)
        #expect(runningCount(&e, 5, offering: .nextEpisode, card: true) == 0)
    }

    @Test("Kurz vor Dateiende: die Füllung ist so lang wie der Rest")
    func countdownShort() {
        var e = OfferingLayer()
        #expect(runningCount(&e, 4.5, offering: .nextEpisode, card: true, countdown: 4) == 0)
        #expect(runningCount(&e, 0.5, offering: .nextEpisode, card: true, countdown: 4) == 1)
    }

    @Test("Countdown hält in der Pause an und läuft danach weiter")
    func countdownPause() {
        var e = OfferingLayer()
        runningCount(&e, 5, offering: .nextEpisode, card: true)
        #expect(runningCount(&e, 30, offering: .nextEpisode, card: true, running: false) == 0)
        #expect(runningCount(&e, 5, offering: .nextEpisode, card: true) == 1)
    }

    @Test("Steuerung öffnen bricht die Karte ab und sagt das Weiterschalten ab")
    func countdownControls() {
        var e = OfferingLayer()
        runningCount(&e, 3, offering: .nextEpisode, card: true)
        e.controls(opened: true)
        #expect(e.display == .nothing, "bei offener Steuerung nur der normale Knopf")
        #expect(e.nextCancelled)
        #expect(!e.nextAtEnd)
        e.controls(opened: false)
        #expect(runningCount(&e, 30, offering: .nextEpisode, card: true) == 0)
        #expect(e.display == .nothing, "nach dem Schließen kommt sie nicht wieder")
    }

    @Test("Steuerung durch Zeigerbewegung: die Karte bleibt und schaltet weiter")
    func pointerDoesNotCancel() {
        var e = OfferingLayer()
        runningCount(&e, 3, offering: .nextEpisode, card: true)
        e.controls(opened: true, through: .beside)
        #expect(e.display == .card(share: 3.0 / OfferingLayer.countdown))
        #expect(!e.nextCancelled)
        // Further movement and a plain sync change nothing.
        e.controls(opened: true, through: .beside)
        e.controls(opened: false)
        e.controls(opened: true, through: .beside)
        #expect(runningCount(&e, 8, offering: .nextEpisode, card: true) == 1)
    }

    @Test("Zeiger öffnet, dann Klick oder Taste: erst das sagt die Karte ab")
    func pointerThenDeliberate() {
        var e = OfferingLayer()
        runningCount(&e, 2, offering: .nextEpisode, card: true)
        e.controls(opened: true, through: .beside)
        runningCount(&e, 1, offering: .nextEpisode, card: true)
        e.controls(opened: true, through: .deliberate)
        #expect(e.display == .nothing)
        #expect(e.nextCancelled)
        // A later sync does not turn the controls back into "incidental".
        e.controls(opened: true, through: .beside)
        #expect(e.display == .nothing)
        #expect(runningCount(&e, 30, offering: .nextEpisode, card: true) == 0)
    }

    @Test("War die Steuerung schon offen, zählt der Countdown erst ab dem Schließen")
    func countdownBehindControls() {
        var e = OfferingLayer()
        e.controls(opened: true)
        #expect(runningCount(&e, 30, offering: .nextEpisode, card: true) == 0)
        #expect(!e.nextCancelled)
        e.controls(opened: false)
        #expect(e.display == .card(share: 0))
        #expect(runningCount(&e, 8, offering: .nextEpisode, card: true) == 1)
    }

    @Test("Zurück bricht den Countdown ab und sagt das Weiterschalten der Folge ab")
    func countdownCancel() {
        var e = OfferingLayer()
        runningCount(&e, 3, offering: .nextEpisode, card: true)
        let toward = e.close()
        #expect(toward)
        #expect(e.nextCancelled)
        #expect(runningCount(&e, 30, offering: .nextEpisode, card: true) == 0)
        e.newEpisode()
        #expect(!e.nextCancelled)
    }

    @Test("Füllung: durchgehend aus der Zeit, hält in der Pause und läuft ohne Rücksprung weiter")
    func fillClock() {
        var u = FillClock()
        let t0 = Date()
        u.set(share: 0, running: true, length: 7, now: t0)
        #expect(u.share(now: t0) == 0)
        #expect(abs(u.share(now: t0.addingTimeInterval(0.1)) - 0.1 / 7) < 1e-6, "zwischen den Takten weiter")
        // The tick reports a smaller value than the clock: it stays with itself.
        u.set(share: 0.07, running: true, length: 7, now: t0.addingTimeInterval(0.6))
        #expect(abs(u.share(now: t0.addingTimeInterval(0.7)) - 0.1) < 1e-6)
        // Pause at 3.5 s: it stands exactly there.
        u.set(share: 0.43, running: false, length: 7, now: t0.addingTimeInterval(3.5))
        #expect(u.share(now: t0.addingTimeInterval(30)) == 0.5)
        // Continue: from there, not from the layer's smaller value.
        let t1 = t0.addingTimeInterval(40)
        u.set(share: 0.43, running: true, length: 7, now: t1)
        #expect(u.share(now: t1) == 0.5)
        #expect(u.share(now: t1.addingTimeInterval(3.5)) == 1)
        #expect(u.share(now: t1.addingTimeInterval(10)) == 1)
        u.set(share: nil, running: true, length: 7, now: t1)
        #expect(u.share(now: t1.addingTimeInterval(1)) == 0, "ohne Karte zurück auf null")
    }

    @Test("Gedrückt: Einblendung weg")
    func pressed() {
        var e = OfferingLayer()
        runningCount(&e, 1, offering: intro)
        e.pressed()
        #expect(e.display == .nothing)
    }

    @Test("Eigene Wahl vor Konto vor „an“")
    func advance() {
        #expect(Advance.applies(ownSelection: nil, account: nil))
        #expect(!Advance.applies(ownSelection: nil, account: false))
        #expect(Advance.applies(ownSelection: true, account: false))
        #expect(!Advance.applies(ownSelection: false, account: true))
    }

    @Test("Kontovorgaben aus /Users/{id}")
    func accountDefaults() throws {
        let json = #"{"Id":"x","Configuration":{"EnableNextEpisodeAutoPlay":false,"PlayDefaultAudioTrack":true}}"#
        let v = try JSONDecoder().decode(AccountPreGift.self, from: Data(json.utf8))
        #expect(v.nextEpisodeAutomatic == false)
        let without = try JSONDecoder().decode(AccountPreGift.self, from: Data(#"{"Id":"x"}"#.utf8))
        #expect(without.nextEpisodeAutomatic == nil)
    }
}
