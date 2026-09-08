import Testing
@testable import JellyfinKit

@Suite("Hintergrundregel")
struct HintergrundregelTests {

    @Test func normalerFallWirdAngehalten() {
        #expect(Hintergrundregel.anhalten(imKleinenFenster: false,
                                          aufAnderemGeraet: false, laeuft: true))
    }

    /// Bild-im-Bild laeuft sichtbar weiter — anhalten waere genau der Fehler,
    /// den es verhindern soll.
    @Test func bildImBildLaeuftWeiter() {
        #expect(!Hintergrundregel.anhalten(imKleinenFenster: true,
                                           aufAnderemGeraet: false, laeuft: true))
    }

    /// Wer auf den Fernseher wirft, legt das Telefon absichtlich weg.
    @Test func andereAusgabeLaeuftWeiter() {
        #expect(!Hintergrundregel.anhalten(imKleinenFenster: false,
                                           aufAnderemGeraet: true, laeuft: true))
    }

    /// Schon angehalten: kein zweiter Befehl, sonst meldet der Player einen
    /// Zustandswechsel, den es nicht gab.
    @Test func pausiertBleibtPausiert() {
        #expect(!Hintergrundregel.anhalten(imKleinenFenster: false,
                                           aufAnderemGeraet: false, laeuft: false))
    }

    @Test func beidesGleichzeitig() {
        #expect(!Hintergrundregel.anhalten(imKleinenFenster: true,
                                           aufAnderemGeraet: true, laeuft: true))
    }
}

// MARK: - Gnadenfrist

@Test("Die Frist ist lang genug fuer einen Blick in die Mitteilungszentrale")
func fristDecktMitteilungszentrale() {
    // Am Geraet gemessen: 1788864150.458 in den Hintergrund,
    // 1788864152.946 wieder heraus. Zweieinhalb Sekunden.
    #expect(Hintergrundregel.gnadenfrist > 2.5)
}

@Test("Die Frist bleibt kurz genug, dass nichts durchlaeuft")
func fristBleibtKurz() {
    // Wovor die Regel schuetzt, ist eine Folge, die im Hintergrund zu Ende
    // laeuft. Ein paar Sekunden Ton nach dem Wischen sind das nicht.
    #expect(Hintergrundregel.gnadenfrist <= 10)
}
