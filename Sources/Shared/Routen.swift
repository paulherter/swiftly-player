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

/// Eigenes Sprungziel: die Zeile trägt einen Pfeil nach rechts, also muss
/// auch eine Seite von rechts kommen — kein Blatt in fremder Gestalt.
struct QuickConnectRoute: Hashable {}

struct EinstellungenRoute: Hashable {}

struct WiedergabeRoute: Hashable {}
