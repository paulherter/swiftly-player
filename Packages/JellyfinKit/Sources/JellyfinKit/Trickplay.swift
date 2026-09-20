import Foundation

/// Vorschaubilder beim Spulen — Jellyfins **Trickplay** (ab 10.9).
///
/// Der Server legt beim Einlesen Kachelblätter ab: je Blatt ein Raster aus
/// `kachelnBreit × kachelnHoch` Bildern, eins alle `intervall` Millisekunden.
/// Geholt wird es vom Server, nicht aus dem Strom — das geht deshalb auch bei
/// Direct Play, und die Wiedergabe merkt davon nichts.
///
/// Die Angaben stehen am Titel unter `Trickplay`, aber nur mit
/// `Fields=Trickplay`: `{ mediaSourceId: { "320": { Width, Height, TileWidth,
/// TileHeight, ThumbnailCount, Interval, Bandwidth } } }`. Die Feldnamen
/// stammen aus `TrickplayInfoDto` der OpenAPI-Beschreibung.
///
/// **Hat der Server kein Trickplay, gibt es kein `Trickplay`** — und die
/// Oberfläche zeigt beim Spulen nur die Zeit, keinen leeren Kasten.
public struct Trickplay: Sendable, Equatable {
    /// Breite eines Vorschaubilds in Pixel — zugleich der Pfadteil der Adresse.
    public let breite: Int
    public let hoehe: Int
    public let kachelnBreit: Int
    public let kachelnHoch: Int
    public let anzahl: Int
    /// Millisekunden zwischen zwei Vorschaubildern.
    public let intervall: Int

    public init(breite: Int, hoehe: Int, kachelnBreit: Int, kachelnHoch: Int,
                anzahl: Int, intervall: Int) {
        self.breite = breite
        self.hoehe = hoehe
        self.kachelnBreit = kachelnBreit
        self.kachelnHoch = kachelnHoch
        self.anzahl = anzahl
        self.intervall = intervall
    }

    /// Wo das Vorschaubild zu einer Stelle liegt.
    public struct Kachel: Sendable, Equatable {
        /// Nummer des Blatts — `/Trickplay/{breite}/{blatt}.jpg`.
        public let blatt: Int
        /// Ausschnitt im Blatt, in Pixel.
        public let x: Int
        public let y: Int
        public let breite: Int
        public let hoehe: Int
    }

    /// n = ms / Intervall, Blatt = n / (Spalten × Zeilen), Platz im Raster =
    /// n mod (Spalten × Zeilen), zeilenweise von links oben.
    ///
    /// Hinter dem letzten Bild bleibt das letzte stehen, vor dem Anfang das
    /// erste — beim Spulen bis ganz ans Ende soll nichts leer werden.
    public func kachel(sekunden: Double) -> Kachel? {
        let jeBlatt = kachelnBreit * kachelnHoch
        guard intervall > 0, jeBlatt > 0, anzahl > 0, breite > 0, hoehe > 0,
              sekunden.isFinite else { return nil }
        let ms = max(sekunden, 0) * 1000
        let n = min(Int(ms) / intervall, anzahl - 1)
        let platz = n % jeBlatt
        return Kachel(blatt: n / jeBlatt,
                      x: (platz % kachelnBreit) * breite,
                      y: (platz / kachelnBreit) * hoehe,
                      breite: breite, hoehe: hoehe)
    }

    /// Aus allen angebotenen Breiten die, die einer Vorschau von `ziel`
    /// Pixeln am nächsten kommt — lieber etwas größer als zu klein.
    public static func waehle(aus angebot: [Trickplay], ziel: Int = 320) -> Trickplay? {
        let gueltig = angebot.filter { $0.intervall > 0 && $0.anzahl > 0 }
        return gueltig.filter { $0.breite >= ziel }.min { $0.breite < $1.breite }
            ?? gueltig.max { $0.breite < $1.breite }
    }
}

/// Der Teil einer Titelantwort, der Trickplay trägt.
public struct TrickplayAntwort: Sendable, Decodable {
    /// Je Quelle alle angebotenen Breiten.
    public let quellen: [String: [Trickplay]]

    enum CodingKeys: String, CodingKey { case trickplay = "Trickplay" }

    private struct Angabe: Decodable {
        let Width: Int?
        let Height: Int?
        let TileWidth: Int?
        let TileHeight: Int?
        let ThumbnailCount: Int?
        let Interval: Int?
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let roh = try c.decodeIfPresent([String: [String: Angabe]].self, forKey: .trickplay) ?? [:]
        var quellen: [String: [Trickplay]] = [:]
        for (quelle, breiten) in roh {
            quellen[quelle] = breiten.compactMap { schluessel, a in
                guard let breite = a.Width ?? Int(schluessel), let hoehe = a.Height,
                      let spalten = a.TileWidth, let zeilen = a.TileHeight,
                      let anzahl = a.ThumbnailCount, let intervall = a.Interval
                else { return nil }
                return Trickplay(breite: breite, hoehe: hoehe, kachelnBreit: spalten,
                                 kachelnHoch: zeilen, anzahl: anzahl, intervall: intervall)
            }
        }
        self.quellen = quellen
    }

    /// Die Angaben zur laufenden Quelle; ohne Kennung die einzige vorhandene.
    public func fuer(quelle: String?, ziel: Int = 320) -> Trickplay? {
        let angebot: [Trickplay]?
        if let quelle, let passend = quellen[quelle] ?? quellen[quelle.lowercased()] {
            angebot = passend
        } else if quellen.count == 1 {
            angebot = quellen.first?.value
        } else {
            angebot = nil
        }
        return angebot.flatMap { Trickplay.waehle(aus: $0, ziel: ziel) }
    }
}
