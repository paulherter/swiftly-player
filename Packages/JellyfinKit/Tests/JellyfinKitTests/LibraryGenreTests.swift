import Foundation
import Testing
@testable import JellyfinKit

@Suite("Bibliotheksgattung")
struct LibraryGenreTests {

    @Test("Filme und Serien bekommen ihre Gattung")
    func known() {
        #expect(LibraryGenre.types(toward: "movies") == ["Movie"])
        #expect(LibraryGenre.types(toward: "tvshows") == ["Series"])
    }

    @Test("Und werden rekursiv gefragt")
    func recursive() {
        #expect(LibraryGenre.recursive(toward: "movies"))
        #expect(LibraryGenre.recursive(toward: "tvshows"))
    }

    @Test("Unbekanntes wird nicht eingeschränkt")
    func unknown() {
        // Better one virtual folder too many than an empty library.
        #expect(LibraryGenre.types(toward: "boxsets").isEmpty)
        #expect(LibraryGenre.types(toward: nil).isEmpty)
        #expect(!LibraryGenre.recursive(toward: nil))
    }

    @Test("Grossschreibung ist egal")
    func writeWay() {
        // Jellyfin returns `CollectionType` in lower case; do not
        // rely on that.
        #expect(LibraryGenre.types(toward: "TVShows") == ["Series"])
        #expect(LibraryGenre.types(toward: "Movies") == ["Movie"])
    }
}
