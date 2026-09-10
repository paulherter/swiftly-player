import Foundation
import JellyfinKit

/// **Zwischen dem Spieler und Discord — und der Ort, an dem entschieden wird,
/// ob ueberhaupt etwas hinausgeht.**
///
/// Das Gegenstueck zu `Discordanzeiger` auf den Apple-Fassungen. Es ist kein
/// Nachbau: die Bruecke und die Anzeige selbst liegen im Paket und werden
/// hier nur bedient. Was sich unterscheidet, ist der Antrieb — dort meldet
/// die Wiedergabezentrale, hier der Takt des Spielers.
///
/// **Auf dem Mac kann das nicht funktionieren**, weil der Sandkasten die
/// Steckdose nicht hergibt; hier gibt es keinen Sandkasten. Die Begruendung
/// steht ausfuehrlich an ``Discordbruecke``.
@MainActor
enum Discordstand {

    /// Dieselbe Anwendung, unter der auch der Meldungs-Bot laeuft. Rich
    /// Presence braucht keine eigene, und eine zweite haette denselben Namen
    /// zweimal in der Liste.
    private static let bruecke = Discordbruecke(anwendung: "1544344805885214761")
    private static var zuletzt: Discordanzeige?
    private static var lief = false

    /// Ruft der Takt des Spielers auf, bei jeder Zustandsaenderung.
    static func melden(titel: String, unterzeile: String?, stelle: Double,
                       dauer: Double, laeuft: Bool, erlaubt: Bool) {
        guard erlaubt else { abraeumen(); return }

        // Pausiert heisst: kein Balken, aber weiter sichtbar. Ein Balken, der
        // laeuft, waehrend das Bild steht, behauptet etwas Falsches.
        let jetzt = Date()
        let anzeige = Discordanzeige(
            titel: titel,
            unterzeile: unterzeile,
            von: laeuft && dauer > 0 ? jetzt.addingTimeInterval(-stelle) : nil,
            bis: laeuft && dauer > 0 ? jetzt.addingTimeInterval(dauer - stelle) : nil)

        // Nur bei einer echten Aenderung senden — der Takt laeuft mehrmals je
        // Sekunde. `Discordanzeige` vergleicht die Zeitpunkte auf die
        // Sekunde, sonst waere jeder Vergleich verschieden.
        guard anzeige != zuletzt else { return }
        zuletzt = anzeige
        lief = true
        Task { await bruecke.zeigen(anzeige) }
    }

    /// Nichts mehr anzeigen — beim Ausschalten, beim Verlassen des Spielers.
    static func abraeumen() {
        guard lief else { return }
        lief = false
        zuletzt = nil
        Task { await bruecke.zeigen(nil) }
    }
}
