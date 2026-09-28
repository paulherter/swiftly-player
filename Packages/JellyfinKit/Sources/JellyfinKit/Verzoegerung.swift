import Foundation

/// **Untertitel- oder Tonverzögerung im Player** — eine Regel für alle
/// Plattformen.
///
/// Laufen Untertitel oder Ton neben dem Bild her, schiebt man sie in
/// 50-ms-Schritten, bis sie sitzen. Positiv heißt später: der Untertitel
/// erscheint später, der Ton kommt später. So zählen es VLC 4
/// (`currentVideoSubTitleDelay`, `currentAudioPlaybackDelay`) und libVLC 3
/// (`setSpuDelay`, `setAudioDelay`) — beide in Mikrosekunden.
///
/// **Der Wert gehört der Wiedergabe, nicht der Einstellung.** Eine
/// verschobene Spur ist ein Fehler dieser einen Datei; die nächste Folge
/// derselben Serie stammt meist aus derselben Quelle und behält ihn
/// (`fuerNeuenTitel`), alles andere beginnt bei null.
///
/// **VLC vergisst ihn bei jedem neuen Medium.** Gemessen am 25.09.2026 mit
/// VLCKit 4.0.0a23 auf dem Mac: vor `play` gesetzt liest VLC danach 0, nach
/// einem Medienwechsel ebenfalls 0; nur ins laufende Medium gesetzt bleibt er
/// stehen (±10 s gelesen wie gesetzt). Die Plattform setzt ihn deshalb nach,
/// sobald VLC etwas anderes meldet als gewollt (`weichtAb`).
public struct Verzoegerung: Equatable, Hashable, Sendable {

    /// Ein Druck auf − oder +.
    public static let schritt = 50
    /// Weiter als zehn Sekunden liegt keine Spur daneben, die man noch
    /// schieben wollte; dahinter ist es die falsche Spur.
    public static let grenze = 10_000
    public static let null = Verzoegerung(millisekunden: 0)

    /// Immer ein Vielfaches von `schritt`, immer innerhalb von ±`grenze`.
    public let millisekunden: Int

    public init(millisekunden: Int) {
        let begrenzt = min(max(millisekunden, -Self.grenze), Self.grenze)
        // Auf den nächsten Schritt, halbe Schritte weg von null — so wird ein
        // von VLC gelesener Wert wie 199 999 µs wieder zu 200 ms.
        let schritte = (Double(begrenzt) / Double(Self.schritt)).rounded(.toNearestOrAwayFromZero)
        self.millisekunden = Int(schritte) * Self.schritt
    }

    /// Aus VLCs Mikrosekunden.
    public init(mikrosekunden: Int) {
        self.init(millisekunden: Int((Double(mikrosekunden) / 1000).rounded()))
    }

    /// Für VLC.
    public var mikrosekunden: Int { millisekunden * 1000 }

    public var istNull: Bool { millisekunden == 0 }
    public var amAnfang: Bool { millisekunden <= -Self.grenze }
    public var amEnde: Bool { millisekunden >= Self.grenze }

    /// Früher (−1) oder später (+1), um `schritte` Schritte.
    public func verschoben(_ richtung: Int, schritte: Int = 1) -> Verzoegerung {
        Verzoegerung(millisekunden: millisekunden + richtung.signum() * max(schritte, 1) * Self.schritt)
    }

    // MARK: Gedrückt halten

    /// **Lange drücken wird schneller.** Die ersten zehn Wiederholungen je ein
    /// Schritt, dann zwei, ab der dreißigsten fünf. Von null bis zehn
    /// Sekunden ist man so in wenigen Sekunden Halten statt in zwanzig — und
    /// wer nur ein Stück will, lässt vorher los.
    public static func schritte(beiWiederholung n: Int) -> Int {
        switch n {
        case ..<10: return 1
        case ..<30: return 2
        default: return 5
        }
    }

    /// Zählt die Wiederholungen eines gehaltenen Knopfes.
    ///
    /// Die Knöpfe wiederholen über das System (`buttonRepeatBehavior` auf
    /// Apple, Tastenwiederholung anderswo) — das liefert Drücke, aber keine
    /// Zählung. Folgt ein Druck dicht auf den vorigen, gehört er zur selben
    /// Reihe; nach einer Pause beginnt die Reihe von vorn.
    public struct Haltezaehler: Sendable {
        /// Länger als die Wiederholpause des Systems, kürzer als ein
        /// bewusstes zweites Tippen.
        public static let reihenabstand: TimeInterval = 0.3
        private var letzter: Date?
        private var reihe = 0

        public init() {}

        /// Wie viele Schritte dieser Druck zählt.
        public mutating func druck(jetzt: Date = Date()) -> Int {
            if let letzter, jetzt.timeIntervalSince(letzter) < Self.reihenabstand {
                reihe += 1
            } else {
                reihe = 0
            }
            letzter = jetzt
            return Verzoegerung.schritte(beiWiederholung: reihe)
        }
    }

    // MARK: Anzeige

    /// „+0,20 s", „−1,50 s", „0,00 s" — Dezimalzeichen nach `locale`, das
    /// Minus als echtes Minuszeichen, zwei Stellen, weil ein Schritt 0,05 ist.
    public func text(locale: Locale = .current) -> String {
        let betrag = abs(millisekunden)
        let komma = locale.decimalSeparator ?? "."
        let hundertstel = (betrag % 1000) / 10
        let zahl = "\(betrag / 1000)\(komma)\(hundertstel < 10 ? "0" : "")\(hundertstel)"
        let vorzeichen = millisekunden > 0 ? "+" : (millisekunden < 0 ? "\u{2212}" : "")
        return "\(vorzeichen)\(zahl) s"
    }

    // MARK: Behalten

    /// **Was beim Wechsel auf einen anderen Titel gilt.** Derselbe Titel
    /// (neu geladen, etwa mit anderer Qualität) und dieselbe Serie behalten
    /// den Wert; alles andere — ein Film, eine andere Serie — beginnt bei null.
    public static func fuerNeuenTitel(_ bisher: Verzoegerung,
                                      alterTitel: String, alteSerie: String?,
                                      neuerTitel: String, neueSerie: String?) -> Verzoegerung {
        if alterTitel == neuerTitel { return bisher }
        guard let alteSerie, let neueSerie, alteSerie == neueSerie else { return .null }
        return bisher
    }

    /// Meldet VLC einen anderen Wert als gewollt? Dann nachsetzen. Unter
    /// einer Millisekunde ist Rundung, keine Abweichung.
    public func weichtAb(vonMikrosekunden gelesen: Int) -> Bool {
        abs(gelesen - mikrosekunden) >= 1000
    }
}
