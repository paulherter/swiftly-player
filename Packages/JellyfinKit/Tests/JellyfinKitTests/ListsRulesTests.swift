import Testing
@testable import JellyfinKit

private func item(_ id: String, _ name: String = "x") -> Item {
    Item(id: id, name: name)
}

@Suite("Listenregeln")
struct ListsRulesTests {

    @Test("Doppelte fallen heraus, die erste bleibt stehen")
    func duplicatesDropOut() {
        let list = [item("a", "erste"), item("b"), item("a", "zweite"), item("c")]
        let clean = ListRules.withoutDouble(list)
        #expect(clean.map(\.id) == ["a", "b", "c"])
        #expect(clean.first?.name == "erste")
    }

    @Test("Ohne Doppelte bleibt alles, wie es war")
    func notDo() {
        let list = [item("a"), item("b"), item("c")]
        #expect(ListRules.withoutDouble(list).map(\.id) == ["a", "b", "c"])
    }

    @Test("Leere Liste bleibt leer")
    func empty() {
        #expect(ListRules.withoutDouble([]).isEmpty)
    }

    @Test("Anhaengen laesst nur wirklich Neues zu")
    func append() {
        let present = [item("a"), item("b")]
        let new = [item("b"), item("c"), item("c")]
        #expect(ListRules.append(new, an: present).map(\.id) == ["a", "b", "c"])
    }

    @Test("Volle Eintraege stehen in der Reihenfolge der schlanken, Verschwundene fallen heraus")
    func inRailsEpisode() {
        let slim = [item("c"), item("a"), item("b")]
        let full = [item("a", "voll a"), item("b", "voll b"), item("c", "voll c"), item("z")]
        let result = ListRules.inRailsEpisode(full, how: slim)
        #expect(result.map(\.id) == ["c", "a", "b"])
        #expect(result.first?.name == "voll c")
        #expect(ListRules.inRailsEpisode([item("a")], how: slim).map(\.id) == ["a"])
    }

    // MARK: Loading more

    @Test("Jede Kachel der letzten drei Reihen loest aus")
    func triggerThirdLastRail() {
        // 30 entries, 5 columns: three rows are 15, so from number 15.
        let list = (0..<30).map { item("i\($0)") }
        #expect(!ListRules.postLoadSection("i14", in: list, columns: 5))
        #expect(ListRules.postLoadSection("i15", in: list, columns: 5))
        #expect(ListRules.postLoadSection("i29", in: list, columns: 5))
    }

    @Test("Sind es weniger als drei Reihen, loest jede aus")
    func shorterThanThreeRails() {
        let list = (0..<7).map { item("i\($0)") }
        #expect(ListRules.postLoadSection("i0", in: list, columns: 5))
    }

    @Test("Eine leere Liste hat keinen Ausloeser")
    func emptyList() {
        #expect(!ListRules.postLoadSection("i0", in: [], columns: 5))
    }

    /// The Apple TV bug, reproduced: 2000 titles, pages of 60,
    /// seven columns. After coming back it reloads while the
    /// tiles at the end are already on screen. Before, that trimmed to 60, and
    /// the one trigger was used up.
    @Test("Neuladen kuerzt die Liste nicht, und am Ende loest es weiter aus")
    func largeLibraryPostBack() {
        let server = (0..<2000).map { item("i\($0)") }
        func page(since: Int) -> [Item] { Array(server[since ..< min(since + 60, server.count)]) }

        var list: [Item] = []
        // Paging up to 180, as when scrolling down.
        while list.count < 180 { list = ListRules.append(page(since: list.count), an: list) }
        #expect(list.count == 180)

        // Back from the detail page: first page fresh.
        list = ListRules.refresh(page(since: 0), in: list, totalBefore: 2000, totalNow: 2000)
        #expect(list.map(\.id) == server.prefix(180).map(\.id))

        // The tile currently on screen keeps triggering.
        #expect(ListRules.postLoadSection("i170", in: list, columns: 7))

        // And it runs through to the end without a gap.
        while list.count < server.count { list = ListRules.append(page(since: list.count), an: list) }
        #expect(list.map(\.id) == server.map(\.id))
    }

    @Test("Aendert sich die Gesamtzahl, wird ersetzt")
    func refreshWithNewTitle() {
        let alt = (0..<120).map { item("i\($0)") }
        let new = [item("neu")] + (0..<59).map { item("i\($0)") }
        let result = ListRules.refresh(new, in: alt, totalBefore: 120, totalNow: 121)
        #expect(result.map(\.id) == new.map(\.id))
    }

    @Test("Nachschub gibt es, solange nicht alles dasteht")
    func stillMorePresent() {
        #expect(ListRules.stillMorePresent(loaded: 40, total: 120))
        #expect(!ListRules.stillMorePresent(loaded: 120, total: 120))
        // More loaded than reported: the server lowered the total
        // while paging. Loading more would then be wrong.
        #expect(!ListRules.stillMorePresent(loaded: 121, total: 120))
    }
}

/// "Recently added" across all libraries: the same title in two
/// libraries comes back with different IDs.
@Suite("Ein Titel, eine Zeile")
struct JeTitleInTimesTests {

    private func film(_ id: String, _ name: String, year: Int? = 2026, tmdb: String? = nil) -> Item {
        Item(id: id, name: name, type: "Movie", productionYear: year,
             providerIds: tmdb.map { ["Tmdb": $0] })
    }

    private func episode(_ id: String, series: String, seriesIdentifier: String) -> Item {
        Item(id: id, name: "Folge", type: "Episode", seriesName: series, seriesId: seriesIdentifier)
    }

    @Test("Derselbe Film aus zwei Bibliotheken steht einmal da, der erste bleibt")
    func filmTwoLibraries() {
        // As measured on the server: the same TMDb number, different IDs.
        let raw = [film("359b", "Toy Story 5", tmdb: "1084244"),
                   film("fa4a", "Toy Story 5", tmdb: "1084244")]
        #expect(ListRules.jeTitleInTimes(raw, showItem: 24).map(\.id) == ["359b"])
    }

    @Test("Ohne Anbieternummer zählen Name und Jahr")
    func filmWithoutNumber() {
        let raw = [film("a", "Obsession"), film("b", "obsession"), film("c", "Obsession", year: 1976)]
        #expect(ListRules.jeTitleInTimes(raw, showItem: 24).map(\.id) == ["a", "c"])
    }

    @Test("Dieselbe Serie mit zwei Serien-IDs steht einmal da, mit ihrer neuesten Folge")
    func seriesTwoLibraries() {
        let raw = [episode("67e2", series: "Adults", seriesIdentifier: "7870"),
                   episode("b6fe", series: "Beauty & The Nerd", seriesIdentifier: "0f0c"),
                   episode("fdcf", series: "Beauty & The Nerd", seriesIdentifier: "a323"),
                   episode("d419", series: "Adults", seriesIdentifier: "f131"),
                   episode("480c", series: "Adults", seriesIdentifier: "7870")]
        #expect(ListRules.jeTitleInTimes(raw, showItem: 24).map(\.id) == ["67e2", "b6fe"])
    }

    @Test("Film und Serie gleichen Namens bleiben beide")
    func filmAndSeries() {
        let raw = [film("f", "FROM"), episode("e", series: "FROM", seriesIdentifier: "s")]
        #expect(ListRules.jeTitleInTimes(raw, showItem: 24).count == 2)
    }

    @Test("Gezeigt wird höchstens die gewünschte Zahl")
    func upperLimit() {
        let raw = (0..<10).map { film("\($0)", "Film \($0)") }
        #expect(ListRules.jeTitleInTimes(raw, showItem: 3).map(\.id) == ["0", "1", "2"])
    }
}
