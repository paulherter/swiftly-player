import Foundation

/// Eine Jellyfin-Sammlung (`BoxSet`) mit den Kennungen ihrer Filme und
/// Serien.
public struct Sammlung: Sendable, Equatable, Identifiable {
    public let item: Item
    public let filme: Set<String>
    public let serien: Set<String>

    public var id: String { item.id }

    public init(item: Item, mitglieder: [Item]) {
        self.item = item
        filme = Set(mitglieder.filter { $0.type == "Movie" }.map(\.id))
        serien = Set(mitglieder.filter { $0.type == "Series" }.map(\.id))
    }

    /// - Parameter art: `movies` oder `tvshows`.
    public func anzahl(art: String) -> Int {
        switch art.lowercased() {
        case "movies":  filme.count
        case "tvshows": serien.count
        default:        0
        }
    }

    public func enthaelt(_ id: String) -> Bool {
        filme.contains(id) || serien.contains(id)
    }

    /// „3 Filme" bzw. „3 Serien" unter einer Sammlungskachel — einmal
    /// gefasst statt dreimal (Apple, Mac, Android über den Kern).
    ///
    /// - Parameter art: `movies` oder `tvshows`.
    public static func anzahltext(art: String, anzahl: Int) -> String {
        art.lowercased() == "tvshows" ? uebersetzt("\(anzahl) Serien") : uebersetzt("\(anzahl) Filme")
    }
}

/// **Alle Sammlungen eines Kontos, samt Mitgliedschaft.**
///
/// **Warum ein Verzeichnis und keine Abfrage je Titel.** Jellyfin 10 hat
/// kein Feld, das einem Film sagt, in welcher Sammlung er steht; Findroid
/// hat den Wunsch deshalb offen (Issue 1288). Jellyfin 12 bringt dafür
/// `GET /Items/{id}/Collections` — das beantwortet aber nur, wo *ein* Titel
/// steht, nicht, wie viele Filme eine Sammlung hat, und genau das braucht
/// das Menü (die Schwelle); Server mit 10.x kennen es gar nicht. Auch
/// `ChildCount` hilft nicht: er zählt alles, auch Serien in einer
/// Filmsammlung.
///
/// Die Sammlungen werden deshalb einmal je Konto geholt, mit ihren
/// Mitgliedern — eine Abfrage für die Liste, eine schlanke je Sammlung (nur
/// Kennung und Gattung, ohne Bilder). Daraus beantworten sich beide Fragen
/// ohne weiteren Netzweg: welche Sammlungen im Bereich Filme stehen, und zu
/// welcher ein Film gehört.
public struct Sammlungsverzeichnis: Sendable, Equatable {
    /// **Eine Sammlung zählt erst ab zwei Titeln im Bereich.** Eine Sammlung
    /// mit einem Film ist keine — Jellyfin legt solche automatisch an, wenn
    /// eine Bibliothek „Filme automatisch zu Sammlungen hinzufügen" hat und
    /// nur ein Teil der Reihe auf der Platte liegt.
    public static let schwelle = 2

    public let alle: [Sammlung]

    public init(_ alle: [Sammlung]) { self.alle = alle }

    public static let leer = Sammlungsverzeichnis([])

    /// Die Sammlungen, die im Bereich stehen, in der Reihenfolge des Servers.
    public func sammlungen(art: String) -> [Sammlung] {
        alle.filter { $0.anzahl(art: art) >= Self.schwelle }
    }

    /// Die Sammlungen, zu denen dieser Titel gehört — nur solche, die im
    /// Bereich des Titels auch stehen. Eine Filmsammlung mit diesem einen
    /// Film hätte keine *anderen* Titel zu zeigen.
    public func sammlungen(mit titel: Item) -> [Sammlung] {
        guard let art = Bibliotheksgattung.art(zuTyp: titel.type) else { return [] }
        return sammlungen(art: art).filter { $0.enthaelt(titel.id) }
    }

    /// **Hat der Nutzer die Sammlungen in Jellyfin ausgeblendet?**
    ///
    /// Wer den Ordner „Sammlungen" (`CollectionType` `boxsets`) unter
    /// Profil › Startseite aus „Meine Medien" nimmt, bekommt ihn in
    /// `UserViews` nicht mehr, mit `includeHidden` aber doch — genau diese
    /// Wahl übernimmt Swiftly, ohne eigene Einstellung.
    ///
    /// **Fehlt der Ordner in beiden Listen, wird trotzdem gezeigt.** Die
    /// erste Fassung fragte nur, wenn der Ordner in `UserViews` stand. Am
    /// Testserver (Jellyfin 12) stand er dort nie, auch nicht mit
    /// `includeHidden`, obwohl es Sammlungen gab — sie blieben unsichtbar.
    /// Ob es welche gibt, sagt deshalb die Abfrage nach `BoxSet`, nicht die
    /// Ansichtenliste.
    public static func ausgeblendet(sichtbar: [Item], mitVerborgenen: [Item]) -> Bool {
        func ordner(_ liste: [Item]) -> Bool {
            liste.contains { $0.collectionType?.lowercased() == "boxsets" }
        }
        return ordner(mitVerborgenen) && !ordner(sichtbar)
    }
}

public extension JellyfinClient {

    /// Holt alle Sammlungen mit ihren Mitgliedern.
    ///
    /// Höchstens sechs Abfragen zugleich — mehr hält ein kleiner Server im
    /// Wohnzimmer nicht ohne Not aus, und bei zwanzig Sammlungen ist es so
    /// eine gute Sekunde. Scheitert eine, scheitert alles: ein halbes
    /// Verzeichnis sähe aus wie ein vollständiges, und niemand fragte nach.
    ///
    /// - Parameter ansichten: Die Ansichten samt verborgenen. Liefert die
    ///   rekursive Suche nichts, wird im Ordner „Sammlungen" nachgesehen,
    ///   falls er darunter ist — Jellyfin hängt Sammlungen nicht auf jedem
    ///   Server in den Baum, den die rekursive Suche abgeht.
    func sammlungsverzeichnis(ansichten: [Item] = []) async throws -> Sammlungsverzeichnis {
        var kisten = try await items(limit: 2000, recursive: true,
                                     includeItemTypes: ["BoxSet"]).items
        if kisten.isEmpty,
           let ordner = ansichten.first(where: { $0.collectionType?.lowercased() == "boxsets" }) {
            kisten = try await items(parentID: ordner.id, limit: 2000,
                                     includeItemTypes: ["BoxSet"]).items
        }
        var mitglieder: [String: [Item]] = [:]
        try await withThrowingTaskGroup(of: (String, [Item]).self) { gruppe in
            var rest = kisten.makeIterator()
            for _ in 0..<6 {
                guard let kiste = rest.next() else { break }
                gruppe.addTask { (kiste.id, try await self.sammlungsmitglieder(kiste.id)) }
            }
            while let (id, liste) = try await gruppe.next() {
                mitglieder[id] = liste
                if let kiste = rest.next() {
                    gruppe.addTask { (kiste.id, try await self.sammlungsmitglieder(kiste.id)) }
                }
            }
        }
        return Sammlungsverzeichnis(kisten.map {
            Sammlung(item: $0, mitglieder: mitglieder[$0.id] ?? [])
        })
    }

    /// Filme und Serien je Bibliothek, die beides enthalten kann.
    ///
    /// Zwei Zählabfragen je solcher Bibliothek; reine Film- und
    /// Serienbibliotheken kosten nichts. Was nicht antwortet, fehlt — die
    /// Bibliothek steht dann (noch) in keinem Bereich.
    func bibliotheksanteile(views: [Item]) async -> [String: Bibliotheksanteil] {
        let gemischt = views.filter { Bibliotheksgattung.kannGemischtSein($0.collectionType) }
        var ergebnis: [String: Bibliotheksanteil] = [:]
        await withTaskGroup(of: (String, Bibliotheksanteil?).self) { gruppe in
            for view in gemischt {
                gruppe.addTask {
                    async let filme = self.anzahl(parentID: view.id, typen: ["Movie"])
                    async let serien = self.anzahl(parentID: view.id, typen: ["Series"])
                    guard let f = try? await filme, let s = try? await serien
                    else { return (view.id, nil) }
                    return (view.id, Bibliotheksanteil(filme: f, serien: s))
                }
            }
            for await (id, anteil) in gruppe {
                if let anteil { ergebnis[id] = anteil }
            }
        }
        return ergebnis
    }
}
