import Foundation

/// Wann ein Routenwechsel den Tonausgang neu aufbauen darf.
///
/// **Die Regel gibt es, weil ihre erste Fassung die App umgebracht hat.**
/// Der Bluetooth-Fix vom 03.09.2026 behandelte vier Routen-Gründe. Zwei davon
/// — `categoryChange` und `routeConfigurationChange` — sind gar keine
/// Gerätewechsel: sie feuern, wenn die App **selbst** ihre Tonsitzung
/// einrichtet, also unmittelbar beim Start. Auf dem Apple TV lief daraus
/// folgende Kette, am Gerät im Protokoll gemessen:
///
/// ```
/// [Ton] Routenwechsel (8) — Ausgang neu aufbauen
/// Paused · Position 0 s        angehalten mitten im Start
/// Playing · Position 9 s       neun Sekunden später
/// picture is too late (missing 8366 ms)   × hunderte
/// ```
///
/// Zwei Schutzschichten sind daraus geblieben: nur echte Gerätewechsel, und
/// eine Schonfrist nach dem Öffnen.
///
/// **Die Schonfrist ist geraten, nicht gemessen.** Fünf Sekunden waren eine
/// plausible Zahl, kein Messwert — deshalb steht sie hier und nicht als
/// nackte Zahl in einem `guard`. Wer sie ändert, sollte sie vorher messen:
/// wie lange dauert es vom Öffnen bis zur letzten selbstverursachten
/// Routenmeldung? Solange das niemand getan hat, gehört sie in diese Tafel
/// und nicht in die der gemessenen Werte.
public enum Tonwacht {

    /// Nach dem Öffnen so lange keine Routenwechsel beachten.
    ///
    /// **Ungemessen.** Siehe oben.
    public static let anlaufruhe: TimeInterval = 5

    /// Ob dieser Routenwechsel den Ausgang neu aufbauen soll.
    ///
    /// - Parameters:
    ///   - echterGeraetewechsel: Ob der Grund `.newDeviceAvailable` oder
    ///     `.override` war — die einzigen zwei, bei denen wirklich jemand das
    ///     Ziel gewechselt hat. Die Unterscheidung bleibt beim Aufrufer, weil
    ///     `AVAudioSession` im Paket nicht verfügbar ist.
    ///   - spielt: Läuft überhaupt etwas? Ein angehaltener Player braucht
    ///     keinen neuen Ausgang.
    ///   - seitUebernahme: Wie lange der Player die Zentrale schon hat.
    public static func ausgangNeuAufbauen(echterGeraetewechsel: Bool,
                                          spielt: Bool,
                                          seitUebernahme: TimeInterval) -> Bool {
        guard echterGeraetewechsel, spielt else { return false }
        return seitUebernahme > anlaufruhe
    }
}
