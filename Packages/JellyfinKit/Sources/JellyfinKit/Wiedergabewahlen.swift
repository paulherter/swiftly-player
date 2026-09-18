import Foundation

/// Die Werte, die in den Wiedergabe-Einstellungen zur Wahl stehen.
///
/// Standen zuerst in `WiedergabeEinstellungenView` — also in einer Ansicht,
/// die nur das iPhone übersetzt —, dann in `Sources/Shared`. Es sind aber
/// keine Ansichten, sondern die Auswahl selbst: welche Bitraten es gibt,
/// welche Sprungweiten, welche Sprachen.
///
/// **Jetzt im Paket**, aus demselben Grund wie ``Bildwahl`` und die
/// ``nebenzeile``: `Sources/Shared` ist SwiftUI und für die Linux-Fassung
/// unerreichbar. Eine zweite Liste dort wäre die Sorte Abschrift, an der die
/// Plattformen auseinanderlaufen.

/// 0 heißt unbegrenzt.
public struct Bitrate: Identifiable, Sendable {
    public let wert: Int
    public init(_ wert: Int) { self.wert = wert }
    public var id: Int { wert }
    public static let stufen = [0, 4, 8, 20, 40, 80].map(Bitrate.init)
    public static func text(_ wert: Int) -> String {
        wert <= 0 ? uebersetzt("Unbegrenzt") : uebersetzt("\(wert) Mbit/s")
    }
}

public struct Spanne: Identifiable, Sendable {
    public let wert: Int
    public init(_ wert: Int) { self.wert = wert }
    public var id: Int { wert }
    public static let stufen = [5, 10, 15, 30, 60].map(Spanne.init)
}

/// Leerer Wert heißt „nicht vorwählen".
public struct Sprachwahl: Identifiable, Sendable {
    public let name: String
    public let wert: String
    public var id: String { wert }

    public static var alle: [Sprachwahl] {
        [Sprachwahl(name: uebersetzt("Wie die Datei"), wert: "")]
            + Sprache.alle.map { Sprachwahl(name: $0.name, wert: $0.name) }
    }

    public static func alle(aus beschriftung: String) -> [Sprachwahl] {
        [Sprachwahl(name: beschriftung, wert: "")]
            + Sprache.alle.map { Sprachwahl(name: $0.name, wert: $0.name) }
    }
}
