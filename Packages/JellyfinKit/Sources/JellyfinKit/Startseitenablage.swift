import Foundation

/// **Die Startseite vom letzten Mal — damit beim Start sofort etwas dasteht.**
///
/// Beim Kaltstart stand die Startseite leer, bis Bibliotheken und Reihen vom
/// Server zurück waren: am 25.09.2026 im tvOS-Simulator gemessen rund eine
/// halbe Sekunde nach dem Erscheinen der Seite, auf einer langsamen Leitung
/// entsprechend mehr. Infuse zeigt an dieser Stelle den letzten Stand und
/// frischt ihn auf; genau das tut die App jetzt auch.
///
/// **Nur eine Vorschau, nie die Wahrheit.** Der Stand wird gezeigt, bis die
/// Antwort des Servers da ist, und dann ersetzt — dieselbe Regel wie beim
/// Auffrischen (`Startseitenmodell.uebernehmen`). Eine Ablage gehört zu
/// genau einem Konto (``dateiname(konto:)``).
///
/// Hier steht nur, **was** abgelegt wird und wie es gelesen wird; **wo** es
/// liegt, weiß die App.
public struct Startseitenablage: Codable, Sendable, Equatable {
    /// Steigt, wenn sich die Gestalt ändert — eine ältere Ablage wird dann
    /// verworfen statt falsch gelesen.
    public static let aktuelleFassung = 1

    public struct Reihe: Codable, Sendable, Equatable {
        public let name: String
        public let items: [Item]
        public init(name: String, items: [Item]) {
            self.name = name
            self.items = items
        }
    }

    public var fassung: Int
    public var bibliotheken: [Item]
    public var weiterschauen: [Item]
    public var naechsteFolge: [Item]
    public var zuletzt: [Item]
    public var neueFilme: [Item]
    public var neueSerien: [Item]
    public var gattungsreihen: [Reihe]

    public init(bibliotheken: [Item], weiterschauen: [Item], naechsteFolge: [Item],
                zuletzt: [Item], neueFilme: [Item], neueSerien: [Item],
                gattungsreihen: [Reihe]) {
        fassung = Self.aktuelleFassung
        self.bibliotheken = bibliotheken
        self.weiterschauen = weiterschauen
        self.naechsteFolge = naechsteFolge
        self.zuletzt = zuletzt
        self.neueFilme = neueFilme
        self.neueSerien = neueSerien
        self.gattungsreihen = gattungsreihen
    }

    /// Nichts, was sich zu zeigen lohnt.
    public var leer: Bool {
        weiterschauen.isEmpty && naechsteFolge.isEmpty && zuletzt.isEmpty
            && neueFilme.isEmpty && neueSerien.isEmpty
            && gattungsreihen.allSatisfy { $0.items.isEmpty }
    }

    public func daten() throws -> Data { try JSONEncoder().encode(self) }

    /// `nil` bei allem, was nicht genau diese Fassung ist — auch bei einer
    /// halb geschriebenen Datei. Eine Vorschau, die nicht passt, wird nicht
    /// gezeigt.
    public static func lesen(_ daten: Data) -> Startseitenablage? {
        guard let ablage = try? JSONDecoder().decode(Startseitenablage.self, from: daten),
              ablage.fassung == aktuelleFassung, !ablage.leer else { return nil }
        return ablage
    }

    /// Ein stabiler Dateiname je Konto (FNV-1a, 64 Bit). Der
    /// Kontoschlüssel selbst trägt Serveradresse und Benutzerkennung und
    /// gehört nicht in einen Dateinamen.
    public static func dateiname(konto: String) -> String {
        var wert: UInt64 = 0xcbf29ce484222325
        for byte in konto.utf8 {
            wert ^= UInt64(byte)
            wert &*= 0x100000001b3
        }
        return "startseite-" + String(wert, radix: 16) + ".json"
    }
}
