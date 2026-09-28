import Foundation

/// **Poster und Hintergründe auf der Platte** — die Regel für alle
/// Plattformen.
///
/// Stand bis 1.0.5 nur auf Apple (`Bildablage` in `Netzbild.swift`); Linux
/// und Windows hielten Bilder allein im Arbeitsspeicher und luden nach jedem
/// Kaltstart jedes Plakat neu vom Server. Weil beide nur das Paket
/// erreichen, liegt die Ablage jetzt hier, und Apple ruft sie von hier auf.
///
/// **Kein ETag nötig.** Welche Adresse auf die Platte darf, entscheidet
/// ``Bildablageschluessel``: nur mit Jellyfins `tag`, dem Fingerabdruck des
/// Bildes. Ändert sich das Bild am Server, ändert sich die Adresse, und der
/// alte Eintrag wird nie mehr getroffen — eine Nachfrage beim Server wäre
/// eine Anfrage je Kachel für eine Antwort, die schon feststeht.
///
/// **Aufgeräumt wird nach dem Alter des letzten Zugriffs**: ``lesen(_:)``
/// frischt das Datum auf, ``aufraeumen()`` wirft die ältesten weg, bis
/// drei Viertel der Grenze erreicht sind — damit nicht jeder Start räumt.
public struct Bildplatte: Sendable {
    public let ordner: URL
    public let grenze: Int

    public init(ordner: URL, grenze: Int) {
        self.ordner = ordner
        self.grenze = grenze
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
    }

    /// FNV-1a, 64 Bit, als Dateiname. Stabil über Programmstarts hinweg —
    /// `hashValue` ist es nicht.
    public static func dateiname(_ text: String) -> String {
        var wert: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            wert ^= UInt64(byte)
            wert &*= 0x100000001b3
        }
        return String(wert, radix: 16)
    }

    /// Der Dateiname zu einer Bildadresse, `nil` ohne `tag`.
    public static func name(_ url: URL) -> String? {
        Bildablageschluessel.fuer(url).map(dateiname)
    }

    /// Liest und frischt das Datum auf, damit ``aufraeumen()`` das zuletzt
    /// Gezeigte behält. Nicht auf dem Hauptfaden aufrufen.
    public func lesen(_ name: String) -> Data? {
        let datei = ordner.appendingPathComponent(name)
        guard let daten = try? Data(contentsOf: datei), !daten.isEmpty else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: datei.path)
        return daten
    }

    public func schreiben(_ daten: Data, _ name: String) {
        guard !daten.isEmpty else { return }
        try? daten.write(to: ordner.appendingPathComponent(name), options: .atomic)
    }

    /// Wirft die zuletzt am längsten nicht gezeigten Dateien weg, bis die
    /// Summe unter drei Viertel der Grenze liegt. Gibt zurück, wie viele
    /// gingen.
    @discardableResult
    public func aufraeumen() -> Int {
        let felder: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let dateien = try? FileManager.default.contentsOfDirectory(
            at: ordner, includingPropertiesForKeys: felder) else { return 0 }
        var liste = dateien.compactMap { datei -> (URL, Int, Date)? in
            guard let werte = try? datei.resourceValues(forKeys: Set(felder)) else { return nil }
            return (datei, werte.fileSize ?? 0, werte.contentModificationDate ?? .distantPast)
        }
        var summe = liste.reduce(0) { $0 + $1.1 }
        guard summe > grenze else { return 0 }
        liste.sort { $0.2 < $1.2 }
        var weg = 0
        for (datei, groesse, _) in liste where summe > grenze * 3 / 4 {
            try? FileManager.default.removeItem(at: datei)
            summe -= groesse
            weg += 1
        }
        return weg
    }
}
