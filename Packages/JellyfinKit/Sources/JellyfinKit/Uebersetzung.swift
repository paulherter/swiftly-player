import Foundation

/// Kurzer Weg zu einem übersetzten Text aus dem Katalog dieses Pakets.
///
/// Ein Paket bringt seinen eigenen Bündel mit; ohne `bundle: .module` sucht
/// `String(localized:)` im Bündel der App und findet nichts.
///
/// **Auf Linux gibt es `String.LocalizationValue` nicht.** Die Foundation
/// dort kennt keine Textkataloge. Der Aufruf sieht auf beiden Seiten gleich
/// aus, damit die Aufrufer nichts davon merken; nur der Weg dahinter ist ein
/// anderer — auf Linux ``Textkatalog`` und ``Textschluessel``, die beide
/// Aufgaben von `String.LocalizationValue` von Hand erledigen: den Schlüssel
/// aus der Interpolation bauen und die richtige `.lproj` finden.
///
/// **Warum es das dort überhaupt braucht** steht ausführlich in
/// `Textkatalog.swift`; die Kurzfassung ist, dass `NSLocalizedString` auf
/// Linux die Entwicklungssprache des Bündels nimmt, nicht die des Nutzers,
/// und dass ein `String`-Schlüssel die Interpolation zu früh ausführt.
///
/// Dass der Rückfall trägt, liegt an einer Entscheidung von ganz am Anfang:
/// **der deutsche Wortlaut ist zugleich der Schlüssel.** Findet die Suche
/// nichts, kommt also nicht `player.error.42` heraus, sondern der richtige
/// deutsche Satz. Ein fehlender Katalog kostet die Übersetzung, nicht die
/// Lesbarkeit.
#if canImport(Darwin)
func uebersetzt(_ schluessel: String.LocalizationValue) -> String {
    String(localized: schluessel, bundle: .module)
}
#elseif os(Android)
/// **Auf Android gibt es `Bundle.module` nicht.**
///
/// Der von SwiftPM erzeugte Zugriff sucht das Ressourcenbuendel neben dem
/// Programm und ruft sonst `fatalError` — in einer `.so` gibt es kein
/// Programmverzeichnis. Jeder uebersetzte Text haette die App beendet, auch
/// jede Fehlermeldung (gefunden 15.09.2026, vor dem ersten Einsatz).
///
/// Die Android-App entpackt die `.lproj`-Ordner beim Start und nennt den
/// Ordner hier, bevor ein Text gebraucht wird. Fehlt er, stehen die Schluessel
/// da — deutsch, lesbar, und kein Absturz.
public enum Paketsprache {
    nonisolated(unsafe) public static var ordner: String?
    nonisolated(unsafe) public static var sprache: String?
}

let paketkatalog: Textkatalog = {
    guard let ordner = Paketsprache.ordner, let buendel = Bundle(path: ordner) else {
        return Textkatalog(leer: Paketsprache.sprache ?? "de")
    }
    return Textkatalog(bundle: buendel, sprache: Paketsprache.sprache)
}()

func uebersetzt(_ schluessel: Textschluessel) -> String {
    paketkatalog.text(schluessel)
}
#else
/// Einmal gelesen, für die Laufzeit des Programms. Die Sprache eines Nutzers
/// ändert sich nicht, während die App läuft.
let paketkatalog = Textkatalog(bundle: .module)

func uebersetzt(_ schluessel: Textschluessel) -> String {
    paketkatalog.text(schluessel)
}
#endif
