import Foundation

/// **Ein Faden, an dem das Paket nach draussen sprechen kann.**
///
/// Das Paket kennt `Protokoll` nicht — das liegt in der App, weil es in eine
/// Datei im App-Behaelter schreibt, und die gibt es auf Linux und Windows so
/// nicht. Trotzdem sind die stillsten Stellen der ganzen App ausgerechnet
/// hier drin: eine Steckverbindung, die nicht zustande kommt, ein Koerper,
/// den der Server nicht lesen kann, eine Antwort, die niemand ansieht.
///
/// Am 10.09.2026 hat genau das eine halbe Nacht gekostet. Die Uebernahme ging
/// nicht, und an drei Stellen hintereinander wurde ein Fehlschlag lautlos in
/// ein „nichts da" verwandelt. Was man nicht sieht, sucht man an der falschen
/// Stelle.
///
/// Die App haengt hier ihr Protokoll ein; wer nichts einhaengt, verliert
/// nichts — dann kostet es einen Test auf `nil`.
public enum Spur {

    /// **`nonisolated(unsafe)` und einmal beim Start gesetzt.**
    ///
    /// Es ist ein Einhaengepunkt, kein Zustand: die App setzt ihn, bevor
    /// irgendetwas laeuft, und danach liest ihn nur noch jemand. Eine Sperre
    /// dafuer waere teurer als das, was sie schuetzt.
    nonisolated(unsafe) public static var schreiben: (@Sendable (String) -> Void)?

    /// Der Text wird nur gebaut, wenn jemand zuhoert.
    public static func sag(_ text: @autoclosure () -> String) {
        guard let schreiben else { return }
        schreiben(text())
    }
}
