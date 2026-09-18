import JellyfinKit
import Foundation

/// Die Sprungziele des Navigationsstapels — auf beiden Plattformen dieselben.
///
/// Lagen vorher verstreut in den Ansichtsdateien, in denen sie zufällig zuerst
/// gebraucht wurden. Für tvOS mussten sie heraus: dort gilt derselbe Stapel
/// mit denselben Zielen, aber keine einzige der iPhone-Ansichten.
///
/// `Item` selbst ist ebenfalls ein Ziel und steht in JellyfinKit.

/// Eigener Typ, damit sich der Sprung in eine Bibliothek vom Sprung in einen
/// Titel unterscheiden lässt — beides sind sonst schlicht `Item`.
struct LibraryRoute: Hashable {
    let item: Item
    static func == (a: LibraryRoute, b: LibraryRoute) -> Bool { a.item.id == b.item.id }
    func hash(into h: inout Hasher) { h.combine(item.id) }
}

/// Zielangabe für den Sprung in eine Staffel.
struct StaffelRoute: Hashable {
    let serie: Item
    let staffel: Item
}

/// Sprungziel für die Profilseite. Eigener Typ, damit sie über denselben
/// Stapel läuft wie alles andere — und damit der Wisch zurück greift.
struct ProfilRoute: Hashable {}

/// Die Merkliste. Kein eigener Bereich — der vierte Platz unten gehört den
/// Downloads —, sondern ein Sprungziel aus dem Kopf der Startseite.
struct MerklisteRoute: Hashable {}

/// Eigenes Sprungziel: die Zeile trägt einen Pfeil nach rechts, also muss
/// auch eine Seite von rechts kommen — kein Blatt in fremder Gestalt.
struct QuickConnectRoute: Hashable {}

struct EinstellungenRoute: Hashable {}

struct WiedergabeRoute: Hashable {}

/// **Seerr hing als eingebauter Verweis an seiner Zeile.**
///
/// Elf Sprungziele laufen ueber eine Route und `zielorte(model:)`, eines
/// nicht. Sichtbar war das nie — bis jemand von einer zweiten Stelle aus
/// dorthin springen will, denn ein eingebauter Verweis gehoert der Zeile, in
/// der er steht.
struct SeerrRoute: Hashable {}

/// Die Seite einer Person. `herkunft` ist der Titel, über den man kam — dort
/// steht „Patrick Jane in The Mentalist".
struct PersonRoute: Hashable {
    let person: Person
    let herkunft: String?
}

/// Alle Titel eines Genres — aus den Chips auf der Startseite.
struct GenreRoute: Hashable {
    let name: String
}

/// Profil → Darstellung: Startseite, Reihen, Genres.
struct DarstellungRoute: Hashable {}
