import Testing
@testable import JellyfinKit

@Suite("Suchverlauf")
struct SearchHistoryTests {

    @Test("Der juengste Begriff steht vorn")
    func youngestFirst() {
        var raw = ""
        raw = SearchHistory.remember("Dune", in: raw)
        raw = SearchHistory.remember("Severance", in: raw)
        #expect(SearchHistory.list(raw) == ["Severance", "Dune"])
    }

    @Test("Derselbe Begriff in anderer Schreibung steht nur einmal da")
    func noDouble() {
        var raw = SearchHistory.remember("dune", in: "")
        raw = SearchHistory.remember("Severance", in: raw)
        raw = SearchHistory.remember("Dune", in: raw)
        #expect(SearchHistory.list(raw) == ["Dune", "Severance"])
    }

    @Test("Unter zwei Zeichen wird nichts gemerkt")
    func tooShort() {
        #expect(SearchHistory.remember(" a ", in: "Dune") == "Dune")
    }

    @Test("Leerraum am Rand wird abgeschnitten")
    func clean() {
        #expect(SearchHistory.list(SearchHistory.remember("  Dune \n", in: "")) == ["Dune"])
    }

    @Test("Es bleiben hoechstens acht, die aeltesten fallen heraus")
    func atMostEight() {
        var raw = ""
        for i in 1...12 { raw = SearchHistory.remember("Titel \(i)", in: raw) }
        let list = SearchHistory.list(raw)
        #expect(list.count == SearchHistory.atMost)
        #expect(list.first == "Titel 12")
        #expect(list.last == "Titel 5")
    }

    /// This is how the iPhone search stored it so far. Whoever updates should
    /// keep their list.
    @Test("Der bisherige Stand liest sich unveraendert")
    func previousState() {
        #expect(SearchHistory.list("Dune\nSeverance") == ["Dune", "Severance"])
        #expect(SearchHistory.list("").isEmpty)
    }
}
