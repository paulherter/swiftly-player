import Foundation

/// Was der Server von einer Person hat.
///
/// **Warum das im Paket steht und nicht in der Ansicht.** Die Regel steckt
/// nicht im Aufruf, sondern in seinen Parametern: Filme und Serien, die
/// neuesten zuerst, höchstens sechzig, ohne Doppelte. Solange sie in
/// `AppModel` stand, kam sie auf Linux und Windows nie an — die hängen
/// ausschließlich am Paket. Eine zweite Fassung dort wäre genau die kopierte
/// Funktion, gegen die CLAUDE.md steht, und sie liefe auseinander, sobald
/// jemand die Sortierung ändert.
public extension JellyfinClient {

    /// Filme und Serien, an denen diese Person mitgewirkt hat.
    ///
    /// **Nach Jahr, das neueste zuerst** — eine Filmografie liest man von
    /// hinten. `SortName` steht als zweiter Schlüssel dahinter, damit zwei
    /// Titel desselben Jahres eine feste Reihenfolge haben; ohne ihn
    /// entscheidet der Server, und die Liste stand zwischen zwei Abrufen
    /// anders da.
    ///
    /// **Nur Film und Serie.** Ohne `includeItemTypes` liefert Jellyfin auch
    /// die einzelnen Folgen, an denen jemand mitgewirkt hat — jede mit dem
    /// Plakat ihrer Serie, also dasselbe Bild zwanzigmal nebeneinander.
    /// Dieselbe Überlegung wie bei der Suche (A7).
    ///
    /// **Ein Fehlschlag ist eine leere Liste, keine Ausnahme.** Die Reihe
    /// fällt dann weg; die Seite steht trotzdem, weil Name und Bild vom
    /// Aufrufer kommen und auf nichts warten.
    func titel(person id: String, limit: Int = 60) async -> [Item] {
        let antwort = try? await items(limit: limit,
                                       sortBy: "ProductionYear,SortName",
                                       sortOrder: "Descending",
                                       recursive: true,
                                       includeItemTypes: ["Movie", "Series"],
                                       personIDs: [id])
        return Listenregeln.ohneDoppelte(antwort?.items ?? [])
    }
}

public extension JellyfinClient {

    /// Titel eines Genres, die **zuletzt hinzugefügten zuerst**.
    ///
    /// Wer ein Genre antippt, sucht meist, was neu ist — deshalb `DateCreated`
    /// und nicht der Name. Wie bei der Filmografie nur Film und Serie: ohne
    /// die Grenze kämen die einzelnen Folgen mit, jede mit dem Plakat ihrer
    /// Serie.
    ///
    /// `nil` heisst: der Server hat nicht geantwortet. Das ist etwas anderes
    /// als „hier liegt nichts" — eine Reihe bleibt dann stehen, wie sie war,
    /// statt sich zu leeren.
    func titel(gattung: String, limit: Int = 24) async -> [Item]? {
        guard let antwort = try? await items(limit: limit,
                                             sortBy: "DateCreated",
                                             sortOrder: "Descending",
                                             recursive: true,
                                             includeItemTypes: ["Movie", "Series"],
                                             gattungen: [gattung])
        else { return nil }
        return Listenregeln.ohneDoppelte(antwort.items)
    }
}
