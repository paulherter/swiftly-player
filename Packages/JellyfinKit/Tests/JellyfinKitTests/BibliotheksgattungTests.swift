import Foundation
import Testing
@testable import JellyfinKit

@Suite("Bibliotheksgattung")
struct BibliotheksgattungTests {

    @Test("Filme und Serien bekommen ihre Gattung")
    func bekannt() {
        #expect(Bibliotheksgattung.typen(zu: "movies") == ["Movie"])
        #expect(Bibliotheksgattung.typen(zu: "tvshows") == ["Series"])
    }

    @Test("Und werden rekursiv gefragt")
    func rekursiv() {
        #expect(Bibliotheksgattung.rekursiv(zu: "movies"))
        #expect(Bibliotheksgattung.rekursiv(zu: "tvshows"))
    }

    @Test("Unbekanntes wird nicht eingeschränkt")
    func unbekannt() {
        // Lieber ein virtueller Ordner zu viel als eine leere Bibliothek.
        #expect(Bibliotheksgattung.typen(zu: "boxsets").isEmpty)
        #expect(Bibliotheksgattung.typen(zu: nil).isEmpty)
        #expect(!Bibliotheksgattung.rekursiv(zu: nil))
    }

    @Test("Grossschreibung ist egal")
    func schreibweise() {
        // Jellyfin liefert `CollectionType` kleingeschrieben; darauf würde
        // ich mich nicht verlassen wollen.
        #expect(Bibliotheksgattung.typen(zu: "TVShows") == ["Series"])
        #expect(Bibliotheksgattung.typen(zu: "Movies") == ["Movie"])
    }
}
