import Foundation

/// **Gedrückt halten = doppelte Geschwindigkeit, wie bei YouTube.**
///
/// Solange der Finger auf dem Bild liegt, spielt es mit 2×; loslassen, und
/// es geht im gewählten Tempo weiter. Der Ton bleibt in seiner Tonhöhe (VLC
/// dehnt ihn mit `scaletempo`), die Untertitel laufen mit.
///
/// Hier steht, **wann** es gilt — gleich auf iPhone, iPad und Android.
public enum Festhaltetempo {

    /// So schnell, solange gehalten wird.
    public static let tempo: Float = 2
    /// So lange muss der Finger liegen, bevor es losgeht — kürzer als der
    /// Doppeltipp zum Spulen es je bräuchte, länger als ein Tipp.
    public static let druckdauer: Double = 0.3
    /// Wandert der Finger weiter, ist es kein Halten, sondern ein Wisch.
    public static let wegGrenze: Double = 14

    /// Ob ein langer Druck jetzt beschleunigt.
    ///
    /// Nicht in einer SyncPlay-Gruppe (die anderen liefen davon), nicht, wenn
    /// ein anderer Abspieler das Bild hat (AirPlay), nicht im Stehen, nicht
    /// beim Spulen, und nicht, wenn es in den Einstellungen aus ist.
    public static func erlaubt(eingeschaltet: Bool, inGruppe: Bool, fremderAbspieler: Bool,
                               laeuft: Bool, spult: Bool) -> Bool {
        eingeschaltet && !inGruppe && !fremderAbspieler && laeuft && !spult
    }

    /// Das Tempo nach dem Loslassen: das, was vorher galt.
    public static func danach(vorher: Float) -> Float {
        vorher > 0 ? vorher : 1
    }
}
