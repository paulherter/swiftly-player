import Foundation

/// Welche Fassung hier läuft — **an einer Stelle, nicht an dreien.**
///
/// **Warum das eine eigene Datei wert ist.** Im Profil stand „Swiftly 1.0",
/// von Hand getippt, und in den Einstellungen noch einmal dasselbe. Auf iOS
/// war genau das Zeile 31 der Änderungsliste: die Angabe war seit der ersten
/// Abgabe falsch, weil sie niemand mitgezogen hat. Sie ist das, was ein
/// Tester in einen Fehlerbericht schreibt — eine falsche Zahl dort kostet
/// später eine Stunde Suche in der falschen Fassung.
///
/// **Auf Apple kommt sie aus dem Bündel** (`CFBundleShortVersionString` und
/// `CFBundleVersion`); Linux hat kein Info.plist, also steht sie hier. Die
/// beiden Zahlen stehen damit an genau **zwei** Orten: hier und in
/// `Linux/Installieren/PKGBUILD` (`pkgver`), das der Bau ohnehin anfasst.
/// Wer eine ändert, ändert die andere mit.
enum Fassung {
    static let nummer = "1.0.0"
    static let bau = "10"

    /// „Swiftly for Jellyfin 1.0.0 (Build 10)" — der volle Name, wie ihn die
    /// anderen Plattformen im Profil zeigen.
    static var voll: String { "Swiftly for Jellyfin \(nummer) (Build \(bau))" }
}
