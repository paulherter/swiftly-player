import Testing
@testable import JellyfinKit

/// Die Regel hinter „N Filme" bzw. „N Serien" unter einer Sammlungskachel —
/// einmal hier statt an drei Stellen (Apple, Mac, Android über den Kern).
///
/// **Ohne festen Wortlaut geprüft**, wie `neuzugangszeile` in
/// `AuthRequestTests`: welche Sprache der Katalog im Testlauf wählt, steht
/// nicht fest — nur die Zahl und der Unterschied zwischen den Gattungen.
@Suite("Sammlungsanzahl")
struct SammlungAnzahltextTests {

    @Test func serienBeiTvshows() {
        #expect(Sammlung.anzahltext(art: "tvshows", anzahl: 3).contains("3"))
    }

    @Test func filmeSonst() {
        #expect(Sammlung.anzahltext(art: "movies", anzahl: 3).contains("3"))
    }

    /// Filme und Serien dürfen nicht denselben Text tragen.
    @Test func filmeUndSerienUnterscheidenSich() {
        #expect(Sammlung.anzahltext(art: "movies", anzahl: 3) != Sammlung.anzahltext(art: "tvshows", anzahl: 3))
    }

    /// Gross-/Kleinschreibung von `art` darf nichts ändern — wie
    /// `Sammlung.anzahl(art:)` selbst auch `.lowercased()` vergleicht.
    @Test func artGrossKleinschreibungEgal() {
        #expect(Sammlung.anzahltext(art: "TVShows", anzahl: 1) == Sammlung.anzahltext(art: "tvshows", anzahl: 1))
    }

    /// Einzahl und Mehrzahl unterscheiden sich — die Sammlungskachel soll
    /// nicht „1 Filme" zeigen.
    @Test func einzahlUndMehrzahlUnterscheidenSich() {
        #expect(Sammlung.anzahltext(art: "movies", anzahl: 1) != Sammlung.anzahltext(art: "movies", anzahl: 2))
        #expect(Sammlung.anzahltext(art: "tvshows", anzahl: 1) != Sammlung.anzahltext(art: "tvshows", anzahl: 2))
    }
}
