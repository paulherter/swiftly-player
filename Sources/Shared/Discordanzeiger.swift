import Foundation
import JellyfinKit

/// **Zwischen dem Player und Discord — und der Ort, an dem entschieden wird,
/// ob ueberhaupt etwas hinausgeht.**
///
/// Die Bruecke im Paket kann senden; ob sie darf, steht hier. Beides zu
/// trennen ist Absicht: eine Klasse, die eine Steckverbindung bedient, soll
/// keine Einstellungen lesen, und eine Stelle, die eine Einstellung liest,
/// soll nicht wissen, wie ein Rahmen aussieht.
///
/// **Angetrieben von ``Wiedergabezentrale``**, nicht von je einem Aufruf in
/// jedem Player. Jede Fassung meldet dort ohnehin bei jeder Zustandsaenderung
/// Titel, Stelle und ob es laeuft — das ist genau, was hier gebraucht wird,
/// und es kostet die Plattformen keine Zeile. Dieselbe Ueberlegung wie bei
/// ``Spielstand``: eine gemeinsame Stelle statt eines Rueckrufs je Fassung,
/// den eine vergessen kann.
@MainActor
final class Discordanzeiger {

    static let geteilt = Discordanzeiger()

    /// Die Anwendung, unter der Discord die Anzeige fuehrt. Es ist dieselbe,
    /// unter der auch der Meldungs-Bot laeuft — Rich Presence braucht keine
    /// eigene, und eine zweite haette denselben Namen zweimal in der Liste.
    private static let anwendung = "1544344805885214761"

    private let bruecke = Discordbruecke(anwendung: anwendung)
    /// Was zuletzt hinausging. Discord will nicht bei jedem Takt dasselbe
    /// noch einmal — und der Player meldet mehrmals je Sekunde.
    private var zuletzt: Discordanzeige?
    private var lief = false

    private init() {}

    /// Ruft der Weg ueber ``Wiedergabezentrale`` auf.
    /// **Den Schalter liest diese Stelle selbst.**
    ///
    /// Er koennte auch durchgereicht werden — dann muesste ihn aber jede
    /// Fassung an `Wiedergabezentrale.melden` mitgeben, und das ist eine
    /// Signatur, die iPhone, iPad, Fernseher und Mac gemeinsam aufrufen. Fuer
    /// einen Wahrheitswert, der ohnehin in derselben Ablage liegt, waere das
    /// vier Aenderungen an fremden Dateien fuer nichts.
    func melden(titel: String, unterzeile: String?, stelle: Double, dauer: Double,
                laeuft: Bool) {
        guard UserDefaults.standard.bool(forKey: "discordAnzeigen") else {
            abraeumen()
            return
        }

        // **Pausiert heisst: kein Balken, aber weiter sichtbar.** Ein Balken,
        // der laeuft, waehrend das Bild steht, ist schlimmer als keiner — er
        // behauptet etwas, das nicht stimmt. Der Titel bleibt trotzdem
        // stehen; wer pausiert, schaut noch.
        let jetzt = Date()
        let anzeige = Discordanzeige(
            titel: titel,
            unterzeile: unterzeile,
            von: laeuft && dauer > 0 ? jetzt.addingTimeInterval(-stelle) : nil,
            bis: laeuft && dauer > 0 ? jetzt.addingTimeInterval(dauer - stelle) : nil)

        // **Nur bei einer echten Aenderung senden.**
        //
        // Ohne diesen Vergleich ginge bei jedem Takt ein Rahmen hinaus, also
        // mehrmals je Sekunde. Die Zeitpunkte wandern dabei um Bruchteile,
        // weil sie aus `Date()` und der Stelle entstehen — deshalb vergleicht
        // `Discordanzeige` sie auf die Sekunde genau, nicht auf den
        // Augenblick. Sonst waere jeder Vergleich verschieden und die
        // Sperre wirkungslos.
        guard anzeige != zuletzt else { return }
        zuletzt = anzeige
        lief = true
        Task { await bruecke.zeigen(anzeige) }
    }

    /// Nichts mehr anzeigen — beim Ausschalten, beim Verlassen des Players,
    /// beim Beenden.
    func abraeumen() {
        guard lief else { return }
        lief = false
        zuletzt = nil
        Task { await bruecke.zeigen(nil) }
    }
}
