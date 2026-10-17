import Foundation
import Testing
@testable import JellyfinKit

@Suite("Anzeigeregeln")
struct DisplayRulesTests {

    /// The case that reached the TV: a series has no runtime of its
    /// own, the server reports 0, and the tile showed "0 Min." because
    /// the copied version lacked the check.
    @Test("Null Sekunden sind keine Laufzeit")
    func nullIsNot() {
        #expect(!DisplayRules.runtimeShow(seconds: 0))
        #expect(!DisplayRules.runtimeShow(seconds: nil))
        #expect(!DisplayRules.runtimeShow(seconds: -5))
    }

    @Test("Eine echte Laufzeit wird gezeigt")
    func realRuntime() {
        #expect(DisplayRules.runtimeShow(seconds: 1))
        #expect(DisplayRules.runtimeShow(seconds: 3600))
    }

    @Test("Ein einzelner Buchstabe ist keine Suche")
    func inLetter() {
        #expect(!DisplayRules.searchTermFits(""))
        #expect(!DisplayRules.searchTermFits("a"))
        #expect(!DisplayRules.searchTermFits("   "))
    }

    /// Typing "a " is typing one letter; the space does not turn it
    /// into a search.
    @Test("Leerzeichen zählen nicht mit")
    func emptyCharacterCountNot() {
        #expect(!DisplayRules.searchTermFits("a "))
        #expect(!DisplayRules.searchTermFits(" a"))
        #expect(DisplayRules.searchTermFits(" ab "))
    }

    @Test("Ab zwei Zeichen wird gesucht")
    func offTwo() {
        #expect(DisplayRules.searchTermFits("ab"))
        #expect(DisplayRules.searchTermFits("Mentalist"))
    }
}

@Suite("Kachelmarke")
struct TileMarkTests {

    /// Whoever has finished a series does not want to read how many seasons it
    /// had.
    @Test("Gesehen schlaegt alles")
    func watchedWins() {
        #expect(DisplayRules.tileMark(art: "Series", seasons: 7,
                                          watched: true, openEpisodes: 3) == .watched)
    }

    /// Once someone has started, "12 left" is more useful than
    /// "7 seasons".
    @Test("Offene Folgen schlagen die Staffelzahl")
    func openPreSeasons() {
        #expect(DisplayRules.tileMark(art: "Series", seasons: 7,
                                          watched: false, openEpisodes: 12) == .opened(12))
    }

    @Test("Ohne offene Folgen kommt die Staffelzahl")
    func seasonCount() {
        #expect(DisplayRules.tileMark(art: "Series", seasons: 7,
                                          watched: false, openEpisodes: 0) == .seasons(7))
        #expect(DisplayRules.tileMark(art: "Series", seasons: 7,
                                          watched: nil, openEpisodes: nil) == .seasons(7))
    }

    /// A number that would always be one is no information.
    @Test("Ein ungesehener Film bekommt nichts")
    func filmWithoutMark() {
        #expect(DisplayRules.tileMark(art: "Movie", seasons: nil,
                                          watched: false, openEpisodes: nil) == nil)
        #expect(DisplayRules.tileMark(art: "Movie", seasons: 1,
                                          watched: false, openEpisodes: 4) == nil)
    }

    @Test("Ein gesehener Film bekommt den Haken")
    func filmWatched() {
        #expect(DisplayRules.tileMark(art: "Movie", seasons: nil,
                                          watched: true, openEpisodes: nil) == .watched)
    }

    /// A server that reports zero or nothing must not produce a badge
    /// that looks like real information.
    @Test("Null und nichts ergeben keine Marke")
    func zerosDropOut() {
        #expect(DisplayRules.tileMark(art: "Series", seasons: 0,
                                          watched: false, openEpisodes: 0) == nil)
        #expect(DisplayRules.tileMark(art: nil, seasons: nil,
                                          watched: nil, openEpisodes: nil) == nil)
    }

    @Test("Serie und Folge tragen den Fernseher, alles andere den Filmstreifen")
    func tileCharacter() {
        #expect(Item(id: "s", name: "S", type: "Series").tileCharacter == "tv")
        #expect(Item(id: "e", name: "E", type: "Episode", seriesId: "s").tileCharacter == "tv")
        #expect(Item(id: "f", name: "F", type: "Movie").tileCharacter == "film")
        #expect(Item(id: "x", name: "X").tileCharacter == "film")
    }
}
