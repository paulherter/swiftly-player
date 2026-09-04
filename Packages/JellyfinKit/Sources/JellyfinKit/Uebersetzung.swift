import Foundation

/// Kurzer Weg zu einem übersetzten Text aus dem Katalog dieses Pakets.
///
/// Ein Paket bringt seinen eigenen Bündel mit; ohne `bundle: .module` sucht
/// `String(localized:)` im Bündel der App und findet nichts.
///
/// **Auf Linux gibt es `String.LocalizationValue` nicht.** Die Foundation
/// dort kennt keine Textkataloge, nur die klassische `NSLocalizedString`. Der
/// Aufruf sieht auf beiden Seiten gleich aus, damit die Aufrufer nichts davon
/// merken; nur der Weg dahinter ist ein anderer.
///
/// Dass der Rückfall trägt, liegt an einer Entscheidung von ganz am Anfang:
/// **der deutsche Wortlaut ist zugleich der Schlüssel.** Findet die Suche
/// nichts, kommt also nicht `player.error.42` heraus, sondern der richtige
/// deutsche Satz. Ein fehlender Katalog kostet auf Linux die Übersetzung,
/// nicht die Lesbarkeit.
#if canImport(Darwin)
func uebersetzt(_ schluessel: String.LocalizationValue) -> String {
    String(localized: schluessel, bundle: .module)
}
#else
func uebersetzt(_ schluessel: String) -> String {
    NSLocalizedString(schluessel, bundle: .module, comment: "")
}
#endif
