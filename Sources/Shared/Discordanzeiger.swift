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

    /// **Eine eigene Anwendung, nicht die des Meldungs-Bots.**
    ///
    /// Technisch traegt ein Behaelter beides. Der Name der Anwendung ist aber
    /// genau das, was Discord als Ueberschrift der Anzeige zeigt — haengen
    /// Bot und Anzeige am selben, aendert wer eins aendert das andere mit.
    /// Zwei Dinge ohne Bezug an einer Schraube.
    private static let anwendung = "1547651294335078534"

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
        // **Ohne Laufzeit gar nichts senden.**
        //
        // Am 10.09.2026 gemeldet: die Zahl faengt immer bei null an und
        // laeuft weiter, auch pausiert. Der Grund liegt hier: solange VLC die
        // Laufzeit noch nicht kennt, ist `dauer` null — dann gingen Anfang
        // und Ende als `nil` hinaus, und Discord zeigt in diesem Fall seinen
        // **eigenen** Zaehler. Der beginnt beim Erscheinen der Anzeige bei
        // null und laeuft einfach weiter; er sieht aus wie unsere Zahl, ist
        // aber seine und weiss von der Folge nichts.
        //
        // Also erst melden, wenn die Laufzeit steht. Ein paar Takte spaeter
        // ist besser als sofort und falsch.
        guard dauer > 0 else { return }

        // **Pausiert: kein Balken, dafuer die Stelle im Text.**
        //
        // Discord kennt kein „angehalten". Laesst man Anfang und Ende weg,
        // erscheint sein eigener Zaehler und laeuft munter weiter — genau
        // das, was gemeldet wurde. Es bleibt also nur, den Balken
        // wegzulassen **und** zu sagen, wo es steht; dann behauptet nichts
        // etwas Falsches.
        let jetzt = Date()
        let zusatz = laeuft ? nil : "\(Spielzeit.text(stelle)) / \(Spielzeit.text(dauer))"
        let zeile = [unterzeile, zusatz].compactMap { $0 }.joined(separator: " · ")
        let anzeige = Discordanzeige(
            titel: titel,
            unterzeile: zeile.isEmpty ? nil : zeile,
            von: laeuft ? jetzt.addingTimeInterval(-stelle) : nil,
            bis: laeuft ? jetzt.addingTimeInterval(dauer - stelle) : nil)

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
