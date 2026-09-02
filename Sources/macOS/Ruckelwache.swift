import Foundation
import SwiftUI

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

    /// Ob überhaupt gemessen wird. Nur mit `SWIFTLY_MESSFAHRT=1` — sonst
    /// schreibt jede Navigation ins Protokoll.
    nonisolated static let an = {
        let u = ProcessInfo.processInfo.environment
        return u["SWIFTLY_MESSFAHRT"] == "1" || u["SWIFTLY_MESSEN"] == "1"
    }()

    /// Beobachtet den Hauptlauf für die angegebene Dauer.
    static func beobachte(_ was: String, sekunden: Double = 1.2) {
        guard an else { return }
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

/// **Schreibt mit, wie eine Bewegung tatsächlich verläuft.**
///
/// `animatableData` wird bei jedem Einzelbild mit dem Zwischenwert gesetzt.
/// Wer den mitschreibt, sieht schwarz auf weiß, ob eine Anweisung überhaupt
/// interpoliert oder ob der Wert springt — und wie lange sie dafür braucht.
///
/// Nur zum Nachmessen, fliegt vor der Auslieferung raus.
struct Fahrtmesser: ViewModifier, @preconcurrency Animatable {
    var wert: CGFloat

    var animatableData: CGFloat {
        get { wert }
        set {
            wert = newValue
            Fahrtschreiber.merke(newValue)
        }
    }

    func body(content: Content) -> some View { content }
}

/// Sammelt die Zwischenwerte und gibt sie als eine Zeile aus, sobald eine
/// Viertelsekunde nichts mehr kam.
enum Fahrtschreiber {
    nonisolated(unsafe) private static var werte: [(Double, CGFloat)] = []
    nonisolated(unsafe) private static var schluss: Task<Void, Never>?

    static func merke(_ wert: CGFloat) {
        guard Ruckelwache.an else { return }
        MainActor.assumeIsolated {
            werte.append((Date().timeIntervalSince1970, wert))
            schluss?.cancel()
            schluss = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let erste = werte.first, let letzte = werte.last else { return }
                let dauer = (letzte.0 - erste.0) * 1000
                // Der grösste Zeitsprung zwischen zwei Bildern — das ist die
                // Stelle, an der der Hauptlauf stand.
                var groessteLuecke = 0.0
                var beiWert: CGFloat = 0
                for (vorher, nachher) in zip(werte, werte.dropFirst()) {
                    let luecke = (nachher.0 - vorher.0) * 1000
                    if luecke > groessteLuecke { groessteLuecke = luecke; beiWert = vorher.1 }
                }
                let schritte = werte.map { String(Int($0.1)) }.joined(separator: " ")
                Protokoll.schreib("Fahrt: \(werte.count) Bilder in \(Int(dauer)) ms, "
                    + "grösster Zeitsprung \(Int(groessteLuecke)) ms bei Versatz \(Int(beiWert)) — \(schritte)")
                werte.removeAll()
            }
        }
    }
}
