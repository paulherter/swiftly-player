import Foundation
import Testing
@testable import JellyfinKit

/// **Fixed rows and libraries in one order**, without a third list that can disagree with
/// `startReihen` and `startBibliotheken`.
@Suite("Gemeinsame Reihenfolge der Startseite")
struct StartOrderTests {

    private let rails: [StartRail] = [.continueWatching, .nextEpisode, .newArrivals]
    private let anime = StartLibrary(id: "a", name: "Anime")
    private let marvel = StartLibrary(id: "m", name: "Marvel", collection: true)

    @Test("Ohne Muster: erst die festen Reihen, dann die Bibliotheken, wie bisher")
    func noPattern() {
        #expect(StartOrder.applicable(stored: [], rails: rails, libraries: [anime, marvel])
                == [.rail(.continueWatching), .rail(.nextEpisode), .rail(.newArrivals),
                    .library("a"), .library("m")])
    }

    @Test("Eine Bibliothek kann zwischen festen Reihen stehen")
    func mixed() {
        let stored = ["weiterschauen", "bibliothek:a", "naechsteFolge", "neuzugaenge", "bibliothek:m"]
        #expect(StartOrder.applicable(stored: stored, rails: rails, libraries: [anime, marvel])
                == [.rail(.continueWatching), .library("a"), .rail(.nextEpisode),
                    .rail(.newArrivals), .library("m")])
    }

    /// **The lists decide what, the pattern only where.** Rows reordered on another
    /// platform fill the row slots in their new order.
    @Test("Die Plätze werden in der Folge der beiden Listen gefüllt")
    func slotsFromLists() {
        let stored = ["weiterschauen", "bibliothek:a", "naechsteFolge", "neuzugaenge", "bibliothek:m"]
        let order = StartOrder.applicable(stored: stored, rails: [.newArrivals, .continueWatching, .nextEpisode],
                                          libraries: [marvel, anime])
        #expect(order == [.rail(.newArrivals), .library("m"), .rail(.continueWatching),
                          .rail(.nextEpisode), .library("a")])
    }

    @Test("Eine entfernte Bibliothek gibt ihren Platz frei, eine neue kommt ans Ende")
    func removedAndAdded() {
        let stored = ["bibliothek:x", "weiterschauen", "bibliothek:a", "naechsteFolge", "neuzugaenge"]
        #expect(StartOrder.applicable(stored: stored, rails: rails, libraries: [anime, marvel])
                == [.rail(.continueWatching), .library("a"), .rail(.nextEpisode),
                    .rail(.newArrivals), .library("m")])
    }

    @Test("Doppeltes und Unbekanntes im Muster zählt nicht")
    func duplicatesAndUnknown() {
        let stored = ["bibliothek:a", "bibliothek:a", "gibtsnicht", "bibliothek:", "weiterschauen"]
        #expect(StartOrder.applicable(stored: stored, rails: rails, libraries: [anime])
                == [.library("a"), .rail(.continueWatching), .rail(.nextEpisode), .rail(.newArrivals)])
    }

    @Test("Nach dem Verschieben: zurück in beide Listen und das Muster")
    func split() {
        let order: [StartEntry] = [.library("m"), .rail(.nextEpisode), .rail(.continueWatching), .library("a")]
        let result = StartOrder.split(order, hidden: [.newMovies, .newSeries], libraries: [anime, marvel])
        #expect(result.rails == [.nextEpisode, .continueWatching, .newMovies, .newSeries])
        #expect(result.libraries == [marvel, anime])
        #expect(result.stored == ["bibliothek:m", "naechsteFolge", "weiterschauen", "bibliothek:a",
                                  "neueFilme", "neueSerien"])
        // And back again: the same list.
        #expect(Array(StartOrder.applicable(stored: result.stored, rails: result.rails,
                                            libraries: result.libraries).prefix(4)) == order)
    }

    @Test("Ein Eintrag hat genau eine Ablageform")
    func storedForm() {
        #expect(StartEntry(stored: "bibliothek:42") == .library("42"))
        #expect(StartEntry(stored: "neuzugaenge") == .rail(.newArrivals))
        #expect(StartEntry.library("42").stored == "bibliothek:42")
        #expect(StartEntry(stored: "bibliothek:") == nil)
    }

    @Test("Die Liste zeigt nur passende Reihen, die Startseite auch keine abgeschalteten")
    func listedAndShown() {
        let order: [StartEntry] = [.rail(.newMovies), .library("a"), .rail(.newArrivals), .rail(.continueWatching)]
        #expect(StartOrder.listed(order, disconnected: false) == [.library("a"), .rail(.newArrivals), .rail(.continueWatching)])
        #expect(StartOrder.listed(order, disconnected: true) == [.rail(.newMovies), .library("a"), .rail(.continueWatching)])
        #expect(StartOrder.shown(order, out: [.continueWatching], disconnected: false) == [.library("a"), .rail(.newArrivals)])
    }

    @Test("Ein Schritt nach oben oder unten, an den Enden nichts")
    func shifted() {
        let listed: [StartEntry] = [.rail(.continueWatching), .library("a"), .rail(.nextEpisode)]
        #expect(StartOrder.shifted(.library("a"), by: -1, in: listed)
                == [.library("a"), .rail(.continueWatching), .rail(.nextEpisode)])
        #expect(StartOrder.shifted(.rail(.continueWatching), by: -1, in: listed) == nil)
        #expect(StartOrder.shifted(.rail(.nextEpisode), by: 1, in: listed) == nil)
        #expect(StartOrder.shifted(.library("x"), by: 1, in: listed) == nil)
    }
}
