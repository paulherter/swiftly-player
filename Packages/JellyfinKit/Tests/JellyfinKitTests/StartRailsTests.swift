import Foundation
import Testing
@testable import JellyfinKit

/// **The home page is configurable, and must not run empty while at it.**
///
/// Each check here pins down a case where a stored list
/// is out of date: a row was added, one is about to go, or the file
/// comes from a version that did not exist yet.
@Suite("Reihenfolge der Startseite")
struct StartRailsTests {

    private let all = StartRail.allCases.map(\.rawValue)

    @Test("Eine leere Ablage ergibt alle Reihen in ihrer Grundfolge")
    func emptyStore() {
        #expect(StartRailsEpisode.applicable(stored: []) == StartRail.allCases)
    }

    /// **A new row must not disappear silently.** The storage comes
    /// from a version that did not know `newSeries` yet; without
    /// appending, the row would be missing permanently without anyone noticing.
    @Test("Was in der Ablage fehlt, haengt hinten an")
    func newRailDives() {
        let alt = ["neuzugaenge", "weiterschauen"]
        let now = StartRailsEpisode.applicable(stored: alt)
        #expect(now.prefix(2).map(\.rawValue) == alt)
        #expect(Set(now) == Set(StartRail.allCases))
    }

    /// **The reported bug.** A storage in which
    /// "neueFilme" appears twice produced two "Recently added movies" rows
    /// one below the other, and because `applicable` only appended what is missing,
    /// the state survived every start and every reorder.
    @Test("Eine doppelt abgelegte Reihe kommt einmal zurueck")
    func doubleStore() {
        let broken = ["weiterschauen", "naechsteFolge", "neueFilme",
                      "neueFilme", "neueSerien", "neuzugaenge"]
        let now = StartRailsEpisode.applicable(stored: broken)
        #expect(now.count == StartRail.allCases.count)
        #expect(now.filter { $0 == .newMovies }.count == 1)
        // The first entry counts: the third place stays the third.
        #expect(now.map(\.rawValue) == ["weiterschauen", "naechsteFolge",
                                          "neueFilme", "neueSerien", "neuzugaenge"])
    }

    /// The visible list and reordering must not carry the state
    /// along either; otherwise the first touch of the settings would write the
    /// duplication back.
    @Test("Sichtbar und Verschieben tragen keine Doppelten weiter")
    func doubleOverStateNot() {
        let broken = ["neueFilme", "neueFilme", "weiterschauen"]
        #expect(StartRailsEpisode.visible(stored: broken, from: [], disconnected: true)
                    .filter { $0 == .newMovies }.count == 1)
        let new = StartRailsEpisode.shifted(.continueWatching, um: -1,
                                             stored: broken, disconnected: true)
        #expect(new.count == StartRail.allCases.count)
        #expect(Set(new) == Set(all))
    }

    @Test("Glattziehen ist auf sich selbst angewandt dasselbe")
    func cleanIsStable() {
        let inTimes = StartRailsEpisode.clean([.newMovies, .continueWatching, .newMovies])
        #expect(inTimes == [.newMovies, .continueWatching])
        #expect(StartRailsEpisode.clean(inTimes) == inTimes)
    }

    @Test("Unbekannte Namen in der Ablage werden verworfen, nicht uebernommen")
    func unknownOne() {
        let now = StartRailsEpisode.applicable(stored: ["gibtsnicht", "weiterschauen"])
        #expect(now.first == .continueWatching)
        #expect(now.count == StartRail.allCases.count)
    }

    /// Separate replaces the shared row, no extra one is added.
    @Test("Getrennt zeigt das Paar, sonst die gemeinsame")
    func disconnected() {
        let with = StartRailsEpisode.visible(stored: all, from: [], disconnected: true)
        #expect(with.contains(.newMovies) && with.contains(.newSeries))
        #expect(!with.contains(.newArrivals))

        let without = StartRailsEpisode.visible(stored: all, from: [], disconnected: false)
        #expect(without.contains(.newArrivals))
        #expect(!without.contains(.newMovies) && !without.contains(.newSeries))
    }

    @Test("Ausgeblendetes steht nicht auf der Seite")
    func hidden() {
        let visible = StartRailsEpisode.visible(stored: all,
                                                 from: ["weiterschauen"], disconnected: false)
        #expect(!visible.contains(.continueWatching))
        #expect(visible.contains(.nextEpisode))
    }

    @Test("Verschieben tauscht zwei Nachbarn")
    func move() {
        let new = StartRailsEpisode.shifted(.nextEpisode, um: -1,
                                              stored: all, disconnected: false)
        #expect(StartRailsEpisode.applicable(stored: new).first == .nextEpisode)
    }

    /// **Nothing happens past the edge.** Otherwise the first row
    /// falls to the end, and the user takes it for a bug.
    @Test("Am Rand bleibt die Reihenfolge, wie sie war")
    func atEdge() {
        #expect(StartRailsEpisode.shifted(.continueWatching, um: -1,
                                            stored: all, disconnected: false) == all)
    }

    /// What does not apply at the moment must not count when moving; otherwise
    /// a row would jump over a gap nobody sees.
    @Test("Unsichtbare Reihen zaehlen beim Verschieben nicht mit")
    func invisibleCountNot() {
        // Without "getrennt", neueFilme/neueSerien do not exist.
        let new = StartRailsEpisode.shifted(.newArrivals, um: -1,
                                              stored: all, disconnected: false)
        let visible = StartRailsEpisode.visible(stored: new, from: [], disconnected: false)
        #expect(visible.map(\.rawValue) == ["weiterschauen", "neuzugaenge", "naechsteFolge"])
        // And the pair survives: it stays in the storage.
        #expect(Set(StartRailsEpisode.applicable(stored: new)) == Set(StartRail.allCases))
    }

    /// The name in the settings list is **not** the heading on
    /// the page. This exact mix-up was in the code on Linux.
    @Test("Listenname und Reihentitel sind verschieden")
    func names() {
        #expect(StartRail.newMovies.listsName == "Neue Filme")
        #expect(StartRail.newMovies.railsTitle == "Zuletzt hinzugefügte Filme")
        #expect(StartRail.continueWatching.listsName == StartRail.continueWatching.railsTitle)
    }
}

/// **Libraries as their own start rows.**
@Suite("Startbibliotheken")
struct StartLibrariesTests {
    private struct Source: HomePageSource {
        var je: [String: [Item]] = [:]
        struct Route: Error {}
        func resumeItems(limit: Int) async throws -> [Item] { [] }
        func nextUp(limit: Int) async throws -> [Item] { [] }
        func lastAdded(in library: String?, fetch: Int, showItem: Int) async -> [Item]? { [] }
        func title(genre: String, limit: Int) async -> [Item]? { [] }
        func libraries() async -> [Item]? { [] }
        func newArrivals(genre: String, fetch: Int, showItem: Int) async -> [Item]? { [] }
        func newSeries(in library: String?, showItem: Int) async -> [Item]? { [] }
        func latestTitle(in library: String, collection: Bool, showItem: Int) async -> [Item]? { je[library] }
    }
    private func t(_ id: String) -> Item { Item(id: id, name: id) }

    @Test("Eine alte Ablage ohne Wahl gibt keine Reihen")
    func errorEndStore() {
        #expect(StartLibraries.read(nil).isEmpty)
        #expect(StartLibraries.read(Data("kaputt".utf8)).isEmpty)
    }

    @Test("Ein Eintrag ohne Namen wirft die Wahl nicht weg")
    func entryWithoutName() {
        let d = Data(#"[{"id":"a"},{"name":"ohne Kennung"},{"id":"b","name":"B"},{"id":"a","name":"doppelt"}]"#.utf8)
        #expect(StartLibraries.read(d).map(\.id) == ["a", "b"])
    }

    @Test("Schreiben und Lesen gehen hin und zurück")
    func toAndBack() {
        let w = [StartLibrary(id: "x", name: "Filme"), StartLibrary(id: "y", name: "Marvel")]
        #expect(StartLibraries.read(StartLibraries.data(w)) == w)
    }

    @Test("Die Reihen kommen in der gewählten Folge; Verschwundene und Leere fallen still weg")
    func rails() async {
        let q = Source(je: ["a": [t("1"), t("1"), t("2")], "c": []])
        let w = [StartLibrary(id: "c", name: "leer"), StartLibrary(id: "a", name: "A"),
                 StartLibrary(id: "weg", name: "gelöscht")]
        let r = await HomeLoader.libraryRails(from: q, choice: w)
        #expect(r.map(\.id) == ["a"])
        #expect(r.first?.items.map(\.id) == ["1", "2"])
    }

    @Test("Die Auswahl lässt Gewähltes weg")
    func pick() {
        let a = StartLibraries.pick(libraries: [t("a"), t("b")], collections: [t("c"), t("a")],
                                          selected: [StartLibrary(id: "b", name: "B")])
        #expect(a.map(\.id) == ["a", "c"])
    }
}
