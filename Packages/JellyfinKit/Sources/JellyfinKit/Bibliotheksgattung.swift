import Foundation

/// Welche Gattung in einer Bibliothek dieser Art steht.
///
/// **Warum das nicht selbstverständlich ist.** Fragt man Jellyfin nach dem
/// Inhalt einer Serienbibliothek, ohne die Gattung zu nennen, bekommt man je
/// nach Servereinstellung nicht die Serien, sondern die virtuellen Ordner der
/// Bibliothek: „Weiterschauen", „Als Nächstes", „Neueste", „Serien",
/// „Lieblingsserien", „Lieblingsepisoden", „Genres". Die haben keine Plakate.
///
/// Genau so ist es einem Nutzer am 03.09.2026 aufgefallen — sieben leere
/// Kacheln mit diesen Namen statt seiner Serien. Auf Pauls Server und auf dem
/// Prüfserver trat es nicht auf, deshalb war es aus dem Bildschirmfoto
/// erkennbar und aus keiner Messung.
///
/// Jellyfins eigene Weboberfläche nennt die Gattung immer mit und fragt
/// rekursiv. Auf Servern ohne diese Ordner ändert das nichts — am Prüfserver
/// nachgemessen, dieselben Titel in derselben Reihenfolge.
public enum Bibliotheksgattung {

    /// - Parameter art: Jellyfins `CollectionType` der Bibliothek.
    /// - Returns: Die Werte für `IncludeItemTypes`, oder leer, wenn es für
    ///   diese Art keine sinnvolle Einschränkung gibt.
    public static func typen(zu art: String?) -> [String] {
        switch art?.lowercased() {
        case "movies":     ["Movie"]
        case "tvshows":    ["Series"]
        case "music":      ["MusicAlbum"]
        case "homevideos": ["Video", "Photo"]
        case "books":      ["Book"]
        // **Unbekannt heißt: nicht einschränken.** Eine gemischte Bibliothek
        // oder eine Gattung, die wir nicht kennen, soll alles zeigen statt
        // nichts. Lieber ein Ordner zu viel als eine leere Seite.
        default:           []
        }
    }

    /// Ob bei dieser Art rekursiv gefragt werden muss.
    ///
    /// Nur wenn die Gattung feststeht: sonst suchte der Server den ganzen
    /// Baum ab und lieferte auch, was in Unterordnern liegt, ohne dass
    /// jemand es einschränken könnte.
    public static func rekursiv(zu art: String?) -> Bool {
        !typen(zu: art).isEmpty
    }
}
