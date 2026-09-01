import Foundation

/// Kurzer Weg zu einem übersetzten Text aus dem Katalog dieses Pakets.
///
/// Ein Paket bringt seinen eigenen Bündel mit; ohne `bundle: .module` sucht
/// `String(localized:)` im Bündel der App und findet nichts.
func uebersetzt(_ schluessel: String.LocalizationValue) -> String {
    String(localized: schluessel, bundle: .module)
}
