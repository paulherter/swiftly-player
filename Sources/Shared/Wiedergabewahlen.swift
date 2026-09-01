import Foundation
import JellyfinKit

/// Die Werte, die in den Wiedergabe-Einstellungen zur Wahl stehen.
///
/// Standen vorher in `WiedergabeEinstellungenView` — also in einer Ansicht,
/// die nur das iPhone übersetzt. Es sind aber keine Ansichten, sondern die
/// Auswahl selbst: welche Bitraten es gibt, welche Sprungweiten, welche
/// Sprachen. Damit beide Plattformen dieselbe Auswahl anbieten, liegen sie
/// hier.

/// 0 heißt unbegrenzt.
struct Bitrate: Identifiable {
    let wert: Int
    var id: Int { wert }
    static let stufen = [0, 4, 8, 20, 40, 80].map(Bitrate.init)
    static func text(_ wert: Int) -> String {
        wert <= 0 ? String(localized: "Unbegrenzt") : String(localized: "\(wert) Mbit/s")
    }
}

struct Spanne: Identifiable {
    let wert: Int
    var id: Int { wert }
    static let stufen = [5, 10, 15, 30, 60].map(Spanne.init)
}

/// Leerer Wert heißt „nicht vorwählen".
struct Sprachwahl: Identifiable {
    let name: String
    let wert: String
    var id: String { wert }

    static var alle: [Sprachwahl] {
        [Sprachwahl(name: String(localized: "Wie die Datei"), wert: "")]
            + Sprache.alle.map { Sprachwahl(name: $0.name, wert: $0.name) }
    }

    static func alle(aus beschriftung: String) -> [Sprachwahl] {
        [Sprachwahl(name: beschriftung, wert: "")]
            + Sprache.alle.map { Sprachwahl(name: $0.name, wert: $0.name) }
    }
}
