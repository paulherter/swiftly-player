import Foundation

/// **Misst, wann der Hauptlauf steht.**
///
/// Ein Zeitgeber, der alle 8 ms auf dem Hauptlauf feuern will. Läuft dort
/// etwas Langes, kann er nicht feuern — die Lücke bis zum nächsten Mal ist
/// genau die Zeit, in der auch kein Bild gezeichnet wurde.
///
/// Nur zum Nachmessen. Vor der Auslieferung fliegt der Aufruf wieder raus.
@MainActor
enum Ruckelwache {
    private static var zeitgeber: Timer?
    private static var zuletzt = Date()
    private static var groesste: Double = 0
    private static var anlass = ""

    /// Beobachtet den Hauptlauf für die angegebene Dauer.
    static func beobachte(_ was: String, sekunden: Double = 1.2) {
        zeitgeber?.invalidate()
        anlass = was
        groesste = 0
        zuletzt = Date()

        let neu = Timer(timeInterval: 0.008, repeats: true) { _ in
            MainActor.assumeIsolated {
                let jetzt = Date()
                let luecke = jetzt.timeIntervalSince(zuletzt) * 1000
                zuletzt = jetzt
                if luecke > 20 {
                    Protokoll.schreib("Ruckeln [\(anlass)] Hauptlauf stand \(Int(luecke)) ms")
                }
                groesste = max(groesste, luecke)
            }
        }
        RunLoop.main.add(neu, forMode: .common)
        zeitgeber = neu

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(sekunden))
            zeitgeber?.invalidate()
            zeitgeber = nil
            Protokoll.schreib("Ruckeln [\(anlass)] größte Lücke \(Int(groesste)) ms")
        }
    }
}
