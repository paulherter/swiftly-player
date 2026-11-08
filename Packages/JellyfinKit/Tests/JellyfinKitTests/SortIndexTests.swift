import Foundation
import Testing
@testable import JellyfinKit

/// The strip beside a grid follows its order: years for "Jahr", whole ratings for
/// "Bewertung", years added for "Zuletzt".
@Suite("Index nach Sortierung") struct SortIndexTests {

    private func item(_ id: String, premiere: String? = nil, year: Int? = nil,
                      rating: Double? = nil, added: String? = nil) -> Item {
        Item(id: id, name: id, productionYear: year, communityRating: rating,
             premiereDate: premiere, dateCreated: added)
    }

    @Test func yearsInTwoDigitsInListOrder() {
        let list = [item("a", premiere: "2026-03-01T00:00:00.0000000Z"),
                    item("b", premiere: "2026-01-01T00:00:00Z"),
                    item("c", year: 2009),
                    item("d", premiere: "2003-05-05T00:00:00Z"),
                    item("e")]
        let index = AlphabetIndex(items: list, sorting: .erscheinung)
        #expect(index.entries.map(\.label) == ["26", "09", "03", "—"])
        #expect(index.entries.map(\.first) == [0, 2, 3, 4])
    }

    @Test func ratingsByWholePart() {
        let list = [item("a", rating: 8.7), item("b", rating: 8.1), item("c", rating: 6.9),
                    item("d", rating: 10), item("e")]
        let index = AlphabetIndex(items: list, sorting: .rating)
        #expect(index.entries.map(\.label) == ["8", "6", "10", "—"])
    }

    @Test func yearsAddedForLatest() {
        let list = [item("a", added: "2026-10-30T10:00:00Z"),
                    item("b", added: "2026-02-01T10:00:00Z"),
                    item("c", added: "2025-12-01T10:00:00Z"),
                    item("d", added: "2025-04-01T10:00:00Z"),
                    item("e", added: "2024-07-01T10:00:00Z"),
                    item("f")]
        let index = AlphabetIndex(items: list, sorting: .latest)
        #expect(index.entries.map { ($0.gap ? "·" : "") + $0.label } == ["26", "·25", "·24", "·—"])
        #expect(index.entries.map(\.first) == [0, 2, 4, 5])
        #expect(index.target(for: "2025", in: list) == 2)
        #expect(index.target(for: "2023", in: list) == nil)
        #expect(index.label(of: "2025") == "25")
    }

    @Test func latestUsesMonthsWhenOneYear() {
        let list = [item("a", added: "2026-10-05T10:00:00Z"), item("b", added: "2026-10-01T10:00:00Z"),
                    item("c", added: "2026-03-01T10:00:00Z")]
        let index = AlphabetIndex(items: list, sorting: .latest)
        #expect(index.monthly)
        #expect(index.entries.map(\.letter) == ["2026-10", "2026-03"])
        #expect(index.entries.map(\.first) == [0, 2])
        #expect(index.key(of: list[2]) == "2026-03")
        #expect(index.isUseful)
    }

    @Test func dotsBetweenYearsAndDecades() {
        let years = AlphabetIndex(items: [item("a", year: 2021), item("b", year: 2020), item("c", year: 2019),
                                          item("d", year: 2009), item("e")],
                                  sorting: .erscheinung)
        #expect(years.entries.map { ($0.gap ? "·" : "") + $0.label } == ["21", "·20", "·19", "·09", "·—"])
        let ratings = AlphabetIndex(items: [item("a", rating: 8.2), item("b", rating: 7.1), item("c", rating: 5)],
                                    sorting: .rating)
        #expect(ratings.entries.map { ($0.gap ? "·" : "") + $0.label } == ["8", "·7", "·5"])
    }

    @Test func pointOnADotSelectsTheGroupItOpens() {
        let shown = [AlphabetIndex.Entry(letter: "a", first: 0),
                     AlphabetIndex.Entry(letter: "b", first: 1, gap: true)]
        // Rows: a = 0..40, dot = 40..60, b = 60..100 (height 100, 2.5 rows of 40).
        #expect(AlphabetIndex.rows(shown) == 2.5)
        #expect(AlphabetIndex.entry(at: 30, height: 100, in: shown)?.letter == "a")
        #expect(AlphabetIndex.entry(at: 45, height: 100, in: shown)?.letter == "b")
        #expect(AlphabetIndex.entry(at: 99, height: 100, in: shown)?.letter == "b")
    }

    @Test func manyYearsThinnedTowardsThePast() {
        let list = (1950...2026).reversed().map { item("\($0)", year: $0) }
        let index = AlphabetIndex(items: list, sorting: .erscheinung)
        let shown = index.condensed(fitting: 30)
        // 30 rows hold 20 years with a dot between each two.
        #expect(shown.count == 20)
        #expect(AlphabetIndex.rows(shown) <= 30)
        #expect(shown.first?.label == "26" && shown.first?.gap == false)
        #expect(shown.last?.label == "50")
        // Dense at the top, sparse further down.
        let years = shown.compactMap { Int($0.letter) }
        #expect(Array(years.prefix(4)) == [2026, 2025, 2024, 2023])
        #expect(years[years.count - 2] - years[years.count - 1] > years[0] - years[1])
    }

    @Test func byNameUnchanged() {
        let list = [item("Alpha"), item("Beta"), item("Борис")]
        let index = AlphabetIndex(items: list, sorting: .name)
        #expect(index.entries.map(\.label) == ["A", "B", "Б"])
        #expect(index.entries.map(\.letter) == index.entries.map(\.label))
    }
}
