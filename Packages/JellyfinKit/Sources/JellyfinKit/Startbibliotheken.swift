import Foundation

/// **Eine Bibliothek oder Sammlung, die der Nutzer als eigene Reihe auf die
/// Startseite geholt hat.**
///
/// Gemerkt werden Kennung **und Name**: Sammlungen stehen nicht in der
/// Bibliotheksliste des Servers, und die Einstellungsseite soll die Reihe
/// auch benennen können, wenn der Server gerade nicht antwortet.
public struct Startbibliothek: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Eine Sammlung (`BoxSet`) statt einer Bibliothek. Sie wird nicht
    /// rekursiv gefragt (`Regalquelle`) und öffnet auf ihre eigene Seite.
    public let sammlung: Bool
    public init(id: String, name: String, sammlung: Bool = false) {
        self.id = id
        self.name = name
        self.sammlung = sammlung
    }

    /// Aus dem, was die Auswahl zeigt.
    public init(_ item: Item) {
        self.init(id: item.id, name: item.name, sammlung: item.type == "BoxSet")
    }

    /// Der Eintrag als Item — für die Seite, die der Kopf der Reihe öffnet.
    public var item: Item {
        Item(id: id, name: name, type: sammlung ? "BoxSet" : "CollectionFolder")
    }
}

/// **Wie die gewählten Bibliotheksreihen gelesen, ergänzt und gesichert werden.**
///
/// Die Wahl gehört zu einem Server (die Kennungen sind es), nicht zum Gerät.
/// Eine Kennung, die es dort nicht mehr gibt oder die dem Profil nicht
/// zugänglich ist, bleibt in der Wahl stehen und liefert nur keine Reihe
/// (`Startseitenlader.bibliotheksreihen`): kommt die Bibliothek zurück, ist
/// auch die Reihe wieder da.
public enum Startbibliotheken {

    /// Jede Kennung einmal, in der Reihenfolge des ersten Auftretens.
    public static func sauber(_ wahl: [Startbibliothek]) -> [Startbibliothek] {
        var gesehen = Set<String>()
        return wahl.filter { !$0.id.isEmpty && gesehen.insert($0.id).inserted }
    }

    /// Liest eine abgelegte Wahl. **Nie werfen:** fehlt etwas oder ist die
    /// Ablage beschädigt, gilt „keine Reihen" — die Startseite bleibt, wie sie war.
    /// Jeder Eintrag wird einzeln gelesen, damit ein kaputter nicht die ganze
    /// Wahl mitnimmt.
    public static func lesen(_ daten: Data?) -> [Startbibliothek] {
        guard let daten,
              let roh = try? JSONDecoder().decode([Eintrag].self, from: daten) else { return [] }
        return sauber(roh.compactMap { e in
            guard let id = e.id else { return nil }
            return Startbibliothek(id: id, name: e.name ?? "", sammlung: e.sammlung ?? false)
        })
    }

    public static func daten(_ wahl: [Startbibliothek]) -> Data? {
        try? JSONEncoder().encode(sauber(wahl))
    }

    private struct Eintrag: Decodable {
        let id: String?
        let name: String?
        let sammlung: Bool?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Schluessel.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            sammlung = try c.decodeIfPresent(Bool.self, forKey: .sammlung)
        }
        enum Schluessel: String, CodingKey { case id, name, sammlung }
    }

    /// Ob eine Bibliothek Titel zum Zeigen hat — Musik, Wiedergabelisten und
    /// Live-Fernsehen tragen keine Plakatreihe.
    public static func waehlbar(_ bibliothek: Item) -> Bool {
        switch bibliothek.collectionType?.lowercased() {
        case "music", "playlists", "livetv", "books": false
        default: true
        }
    }

    /// Was zur Auswahl steht: die Bibliotheken des Servers und die Sammlungen,
    /// ohne das, was schon gewählt ist.
    public static func auswahl(bibliotheken: [Item], sammlungen: [Item],
                               gewaehlt: [Startbibliothek]) -> [Item] {
        let schon = Set(gewaehlt.map(\.id))
        return Listenregeln.ohneDoppelte(bibliotheken + sammlungen).filter { !schon.contains($0.id) }
    }
}
