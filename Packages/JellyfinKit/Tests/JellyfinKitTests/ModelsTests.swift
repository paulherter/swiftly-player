import Foundation
import Testing
@testable import JellyfinKit

@Suite("Vorläufige Serie aus einer Folge")
struct PreCommonSeriesTests {

    private func episode(series: String? = "s1", name: String? = "Young Sheldon") -> Item {
        Item(id: "f1", name: "Folge 1", type: "Episode",
             seriesName: name, seriesId: series)
    }

    @Test("Nimmt Kennung und Namen aus der Folge und gilt als Serie")
    func takesWasPresentIs() throws {
        let s = try #require(Item.preCommonSeries(toward: episode()))
        #expect(s.id == "s1")
        #expect(s.name == "Young Sheldon")
        #expect(s.type == "Series")
    }

    /// Without a series there is nothing to anticipate; the page should load
    /// instead of showing an entry that points to nothing.
    @Test("Ohne Serienkennung oder Serienname kommt nichts zurück")
    func withoutDetailsNot() {
        #expect(Item.preCommonSeries(toward: episode(series: nil)) == nil)
        #expect(Item.preCommonSeries(toward: episode(name: nil)) == nil)
    }

    @Test("Der Erzeuger füllt nur, was genannt wird")
    func onlyNamed() {
        let i = Item(id: "x", name: "Ein Film", type: "Movie")
        #expect(i.overview == nil)
        #expect(i.userData == nil)
        #expect(i.genres == nil)
    }
}

/// Used to be mixed: "F6, F7" on the tiles, "E7" on the play button,
/// the same value in two languages in one place. In German it is
/// "Folge"/"F" everywhere, in English "Episode"/"E", never the other way round.
@Suite("Folgenkürzel — ein Buchstabe, überall derselbe")
struct EpisodesAbbreviationTests {

    private func episode(season: Int? = 7, number: Int? = 3, series: String? = "21 Jump Street") -> Item {
        Item(id: "f1", name: "Eine Folge", type: "Episode",
             seriesName: series, indexNumber: number, parentIndexNumber: season)
    }

    /// Which letter precedes the episode number, "F" or "E", depending on the
    /// language of the test environment. Any other letter would be a bug in the
    /// catalog, not a valid translation.
    private func letterPreDigit(_ text: String, digit: String) -> Character? {
        guard let section = text.range(of: digit), section.lowerBound > text.startIndex else { return nil }
        return text[text.index(before: section.lowerBound)]
    }

    @Test("Kürzel nennt Staffel und Folge, mit demselben Buchstaben wie die Kontextzeile")
    func abbreviationAndContextRowSameLetter() {
        let abbreviation = try! #require(episode().episodeCode)
        let row = try! #require(episode().contextLine)
        #expect(abbreviation.contains("S7"))
        #expect(row.contains("21 Jump Street"))
        let bF = try! #require(letterPreDigit(abbreviation, digit: "3"))
        let bZ = try! #require(letterPreDigit(row, digit: "3"))
        // This was exactly the reported bug: the tile ("F6, F7") showed
        // a different letter than the play button ("E7"), in the same
        // language at the same time.
        #expect(bF == bZ)
        #expect(["F", "E"].contains(String(bF)))
    }

    @Test("Ohne Staffel oder ohne Folgennummer gibt es kein Kürzel")
    func withoutDetailsNoAbbreviation() {
        #expect(episode(season: nil).episodeCode == nil)
        #expect(episode(number: nil).episodeCode == nil)
    }

    @Test("Ohne Serie und ohne Staffel/Folge gibt die Kontextzeile nichts zurück")
    func contextRowWithoutDetailsNil() {
        let i = Item(id: "m1", name: "Ein Film", type: "Movie")
        #expect(i.contextLine == nil)
    }

    /// The catalog itself, independent of the language of the test environment: the
    /// abbreviation is "F" in German and "E" in English, never the other way round. Read
    /// the way ``TextCatalog`` does it on Linux/Android, directly via the
    /// `.lproj` file, because `String(localized:locale:)` does not reliably
    /// override the language of the test environment.
    @Test("Katalog: Deutsch F, Englisch E")
    func catalogLetterJeLanguage() throws {
        func value(_ language: String) throws -> String? {
            let url = try #require(Bundle.module.url(forResource: "Localizable", withExtension: "strings",
                                                       subdirectory: nil, localization: language))
            let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
            return table["S%lld • F%lld"]
        }
        #expect(try value("de") == "S%lld • F%lld")
        #expect(try value("en") == "S%lld • E%lld")
    }
}
