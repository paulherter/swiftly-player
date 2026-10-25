import Testing
@testable import JellyfinKit

@Suite("Bibliotheksfilter")
struct LibraryFilterTests {

    @Test("Ohne Merkliste fehlt nur ihr Filter, die Reihenfolge bleibt")
    func offeredWithoutWatchlist() {
        #expect(LibraryFilter.offered(LibraryFilter.allCases, watchlist: true) == LibraryFilter.allCases)
        #expect(LibraryFilter.offered([.all, .begun, .watchlist], watchlist: false) == [.all, .begun])
        #expect(LibraryFilter.offered([.all, .begun, .watchlist, .unwatched], watchlist: false)
                == [.all, .begun, .unwatched])
    }

    @Test("Ein Filter, den die Seite nicht mehr anbietet, wird zu Alle")
    func keptFallsBackToAll() {
        #expect(LibraryFilter.watchlist.kept(in: [.all, .begun]) == .all)
        #expect(LibraryFilter.begun.kept(in: [.all, .begun]) == .begun)
        #expect(LibraryFilter.watchlist.kept(in: LibraryFilter.allCases) == .watchlist)
    }
}
