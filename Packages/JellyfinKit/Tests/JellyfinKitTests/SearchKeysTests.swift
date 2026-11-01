import Foundation
import Testing
@testable import JellyfinKit

@Suite("TV-Suche: Tastatur, Blöcke, Zustand")
struct SearchKeysTests {

    @Test("Jede Reihe füllt genau sechs Spalten")
    func rowsFill() {
        for speech in [true, false] {
            for row in SearchKeys.rows(speech: speech) {
                #expect(row.map(\.span).reduce(0, +) == SearchKeys.columns)
            }
        }
    }

    @Test("Alle Zeichen stehen einmal drauf, in der Reihenfolge der Skizze")
    func allCharacters() {
        let rows = SearchKeys.rows(speech: true)
        #expect(rows.count == 8)
        let chars = rows.flatMap { $0 }.filter { $0.kind == .letter }.map(\.character).joined()
        #expect(chars == "ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÜß1234567890-")
        #expect(rows[5].map(\.character).joined() == "123456")
        #expect(rows[6].last?.kind == .space)
        #expect(rows[6].count == 6)
    }

    @Test("Ohne Spracheingabe löscht die Taste über alle sechs Spalten")
    func noSpeech() {
        #expect(SearchKeys.rows(speech: false).last?.map(\.kind) == [.delete])
        #expect(SearchKeys.rows(speech: true).last?.map(\.kind) == [.delete, .speak])
    }

    @Test("Groß am Wortanfang, sonst klein")
    func capitals() {
        var term = ""
        for c in ["T", "A", "T", "O", "R", "T"] { term = SearchKeys.typed(c, into: term) }
        term = SearchKeys.withSpace(term)
        for c in ["M", "Ü", "N", "S", "T", "E", "R"] { term = SearchKeys.typed(c, into: term) }
        #expect(term == "Tatort Münster")
    }

    @Test("Nach einem Bindestrich beginnt ein neues Wort")
    func hyphen() {
        var term = ""
        for c in ["S", "P", "I", "D", "E", "R", "-", "M", "A", "N"] { term = SearchKeys.typed(c, into: term) }
        #expect(term == "Spider-Man")
    }

    @Test("Das scharfe s bleibt klein")
    func sharpS() {
        #expect(SearchKeys.typed("ß", into: "") == "ß")
        #expect(SearchKeys.typed("ß", into: "Stra") == "Straß")
    }

    @Test("Leerzeichen nur nach einem Zeichen, nie doppelt")
    func space() {
        #expect(!SearchKeys.spaceFits(""))
        #expect(SearchKeys.withSpace("") == "")
        #expect(SearchKeys.withSpace("Dune") == "Dune ")
        #expect(SearchKeys.withSpace("Dune ") == "Dune ")
    }

    @Test("Löschen nimmt ein Zeichen, auf leer bleibt leer")
    func delete() {
        #expect(SearchKeys.withoutLast("Dune") == "Dun")
        #expect(SearchKeys.withoutLast("") == "")
    }

    @Test("Hardware-Tastatur: Buchstaben wie die Tasten, Fremdes fällt weg")
    func hardware() {
        #expect(SearchKeys.hardware("dune part", into: "") == "Dune Part")
        #expect(SearchKeys.hardware("!?", into: "Dune") == "Dune")
    }

    @Test("Blocktitel stehen nur bei mehr als einem Block")
    func titles() {
        #expect(!SearchGroups.showsTitles(series: 3, films: 0, requests: 0))
        #expect(!SearchGroups.showsTitles(series: 0, films: 0, requests: 2))
        #expect(SearchGroups.showsTitles(series: 3, films: 1, requests: 0))
        #expect(SearchGroups.showsTitles(series: 0, films: 4, requests: 2))
    }

    @Test("Treffer teilen sich in Serien und Filme")
    func split() {
        let s = SearchGroups.split(["Series", "Movie", "Movie", "Episode"], type: { $0 })
        #expect(s.series.count == 1)
        #expect(s.films.count == 2)
    }

    @Test("Der Zustand der Trefferseite")
    func screen() {
        func st(_ term: String, hist: Int = 0, hits: Bool = false, answered: Bool = false,
                disrupted: Bool = false, waited: Bool = false) -> SearchScreen {
            SearchScreen.state(term: term, historyCount: hist, hasHits: hits, answered: answered,
                               disrupted: disrupted, waited: waited)
        }
        #expect(st("") == .start)
        #expect(st("N", hist: 2, hits: true) == .history)
        #expect(st("Na", hits: true) == .hits)
        #expect(st("Nacht") == .blank)
        #expect(st("Nacht", waited: true) == .loading)
        #expect(st("Nacht", answered: true) == .nothing)
        #expect(st("Nacht", hits: true, disrupted: true) == .disrupted)
    }

    @Test("Der Verlauf eines Kontos beginnt mit dem gemeinsamen von früher")
    func storeMigration() {
        let suite = UserDefaults(suiteName: "SearchKeysTests")!
        suite.removePersistentDomain(forName: "SearchKeysTests")
        suite.set("Dune", forKey: SearchHistory.key)
        #expect(SearchHistoryStore.load(account: "abc", store: suite) == "Dune")
        SearchHistoryStore.save("Alien", account: "abc", store: suite)
        #expect(SearchHistoryStore.load(account: "abc", store: suite) == "Alien")
        #expect(SearchHistoryStore.load(account: nil, store: suite) == "Dune")
        suite.removePersistentDomain(forName: "SearchKeysTests")
    }
}
