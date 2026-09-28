import Foundation

/// **Wie weit der Finger eine Liste unter einem zuklappenden Kopf gezogen
/// hat.**
///
/// Bibliothek, Merkliste und Sammlungen messen dasselbe; die Rechnung stand
/// dreimal da, und in zweien davon nur mit einem Verweis auf die dritte.
///
/// **Die Summe aus Rand und rohem Versatz ist der Scrollweg.** Gemessen am
/// 22.09.2026:
///
///     rand 130,8  versatz −130,3  ->  Summe 0,5
///     rand 115,0  versatz −114,7  ->  Summe 0,3
///
/// Dazwischen ist die Wertreihe von 28 auf 44 Punkt zugeklappt. Der obere
/// Rand faellt dabei um 15,8 — und der rohe Versatz steigt um 15,6. Beide
/// wandern gemeinsam, weil die Scrollflaeche den Inhalt festhaelt, wenn
/// sich ihr Rand aendert. Wer das Eingeklappte noch einmal draufrechnet,
/// zaehlt den Weg doppelt, und die Reihe klappt von selbst zu — daran sind
/// drei Anlaeufe gescheitert.
///
/// **Ein Zwischenstand wird uebergangen.** Waehrend die Flaeche ihre
/// Geometrie neu rechnet, meldet sie einmal Versatz null bei schon gesetztem
/// Rand. Daraus wuerde rechnerisch die ganze Kopfhoehe, die Reihe klappte
/// fuer ein, zwei Bilder zu und wieder auf. Echt vorkommen kann die Paarung
/// nur, wenn man zufaellig um genau die Randhoehe gescrollt hat — dort
/// kostet ein uebersprungenes Bild nichts.
public enum Kopfscrollweg {

    /// Der Weg — oder `nil`, wenn die Meldung der Zwischenstand ist.
    public static func weg(rand: Double, versatz: Double) -> Double? {
        guard !(abs(versatz) < 1 && rand > 1) else { return nil }
        return versatz + rand
    }
}
