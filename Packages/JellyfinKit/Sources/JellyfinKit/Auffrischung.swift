import Foundation

/// Wann die Startseite ihre Reihen neu holen muss.
///
/// **Der Anlass ist nicht das Erscheinen der Ansicht, sondern der Verdacht,
/// dass die Angaben nicht mehr stimmen.** Die iPhone-Fassung lud genau
/// einmal je App-Start: `geladen` wurde gesetzt und nie zurückgenommen.
/// Danach stand „Weiterschauen" still, bis jemand die Seite von Hand
/// herunterzog.
///
/// Wie sich das zeigte: eine Folge, auf einem anderen Gerät zu Ende gesehen,
/// stand weiter mit einem Balken bei sechzig Prozent in der Reihe. Beim
/// Antippen holt `HomeView` die Stelle absichtlich frisch nach — und frisch
/// war sie null. Der Player begann also am Anfang, richtig und unerwartet
/// zugleich, weil die Kachel daneben etwas anderes behauptete. Gesucht wurde
/// der Fehler danach im Player; er lag in der Liste.
///
/// Drei Anlässe, und der Unterschied zwischen ihnen ist wichtig:
///
/// - **Der Player geht zu.** Dann hat sich die Stelle mit Sicherheit
///   geändert — der Zuschauer kommt gerade daher. Ohne Frist.
/// - **Die App kommt in den Vordergrund.** Dann hat sich vielleicht etwas
///   geändert, auf einem anderen Gerät. Mit Frist, sonst fasst jedes
///   Umschalten den Server an.
/// - **Die Ansicht erscheint zum ersten Mal.** Dann ist noch nichts da.
///
/// Liegt im Paket und nicht in der Ansicht, weil alle drei Plattformen
/// dieselben Reihen zeigen und dieselbe Antwort brauchen. Genau so ist es
/// `Zeitannahme` und `Folgenende` ergangen: als Regel in der Ansicht lief
/// sie zwischen den Fassungen auseinander, ohne dass es jemand nachmaß.
public enum Auffrischung {

    /// Wie lange die Reihen nach dem Laden als frisch gelten.
    ///
    /// Dreißig Sekunden sind gewogen, nicht geraten. Kürzer heißt: wer
    /// zwischen Swiftly und einer Nachricht hin- und herspringt, löst jedes
    /// Mal drei Abfragen aus. Länger heißt: wer auf dem Fernseher zu Ende
    /// schaut und danach zum Handy greift, sieht die Folge dort noch stehen.
    /// Ein Gerätewechsel dauert selten unter einer halben Minute, ein
    /// Blick in eine Nachricht selten länger.
    public static let frist: TimeInterval = 30

    /// Ist ein Neuladen fällig, weil die App wieder in den Vordergrund kommt?
    ///
    /// - Parameters:
    ///   - zuletzt: Wann zuletzt geladen wurde, oder `nil`, wenn noch nie.
    ///   - jetzt: Für den Test einsetzbar.
    public static func faelligBeiRueckkehr(zuletzt: Date?,
                                           jetzt: Date = Date(),
                                           frist: TimeInterval = frist) -> Bool {
        guard let zuletzt else { return true }
        return jetzt.timeIntervalSince(zuletzt) >= frist
    }
}
