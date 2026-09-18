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
/// **`nonisolated(unsafe)` statt `@MainActor` — wie der Rest dieser Fassung.**
///
/// Auf den Apple-Fassungen ist alles, was die Oberflaeche beruehrt, an den
/// Hauptakteur gebunden. Hier nicht: GTKs Rueckrufe kommen aus C und tragen
/// keine Isolation mit, und `App` selbst steht aus demselben Grund als
/// `nonisolated(unsafe)` in `main.swift`. Ein `@MainActor` hier hat den Bau
/// an drei Stellen gebrochen, und zwar zu Recht.
///
/// Es ist trotzdem kein Freibrief: alle drei Aufrufer sitzen im Takt des
/// Spielers oder in einem Schalter, also im GTK-Faden. Es gibt keinen
/// zweiten, der hier hereinkaeme.
enum Discordstand {

    /// Eine **eigene** Anwendung, nicht die des Meldungs-Bots. Rich
    /// Presence braucht keine eigene, und eine zweite haette denselben Namen
    /// zweimal in der Liste.
    private static let bruecke = Discordbruecke(anwendung: "1547651294335078534")
    nonisolated(unsafe) private static var letzterStand = ""
    nonisolated(unsafe) private static var zuletzt: Discordanzeige?
    nonisolated(unsafe) private static var lief = false

    /// **Eine Kette, damit die Reihenfolge steht.**
    ///
    /// Am 10.09.2026 am Geraet gefunden, mit einer sehr genauen Beobachtung:
    /// eine Folge, die mittendrin anfaengt, zeigte **nichts** — ein Sprung
    /// innerhalb derselben Folge dagegen schon.
    ///
    /// Der Grund: beim Verlassen des Spielers wird abgeraeumt, beim Starten
    /// gemeldet, und beides lief als **eigene, unstrukturierte Aufgabe**. Die
    /// haben keine Reihenfolge untereinander. Kam das Abraeumen als zweites
    /// an, loeschte es die gerade gesetzte Anzeige wieder. Beim Sprung wird
    /// nichts abgeraeumt — deshalb war dort nichts zu sehen.
    ///
    /// Kein Wettlauf, den man „selten" nennen kann: Verlassen und Starten
    /// liegen im selben Zug, wenn jemand aus dem Player heraus die naechste
    /// Folge waehlt.
    nonisolated(unsafe) private static var kette: Task<Void, Never>?

    private static func einreihen(_ arbeit: @escaping @Sendable () async -> Void) {
        let vorher = kette
        kette = Task {
            await vorher?.value
            await arbeit()
        }
    }

    /// Ruft der Takt des Spielers auf, bei jeder Zustandsaenderung.
    static func melden(titel: String, unterzeile: String?, stelle: Double,
                       dauer: Double, laeuft: Bool, erlaubt: Bool) {
        // **Vorlaeufig: einmal je Sekunde sagen, womit wir hier stehen.**
        //
        // Am 10.09.2026 kam in Discord nichts an, und im Protokoll stand
        // nichts — **beide** Ausstiege aus dieser Funktion waren stumm.
        // Damit war „der Schalter ist aus", „die Laufzeit steht noch nicht"
        // und „es hat sich nichts geaendert" nicht zu unterscheiden. Genau
        // die Ununterscheidbarkeit, an der heute schon die Uebernahme
        // haengengeblieben ist — wieder selbst gebaut.
        //
        // Kommt raus, sobald es laeuft.
        // **Nur wenn sich etwas aendert, nicht jede Sekunde.**
        //
        // Zuerst ging die Zeile im Sekundentakt hinaus; bei einem pausierten
        // Film stand dann fuenfzigmal dasselbe untereinander und hat alles
        // andere aus dem Protokoll gedraengt — auch die Abrisse der
        // Fernsteuerung, denen ich gerade nachgehe. Ein Werkzeug, das die
        // Sicht verstellt, die es schaffen soll, ist keins.
        let stand = "erlaubt=\(erlaubt) dauer=\(Int(dauer)) laeuft=\(laeuft) titel=\(titel)"
        if stand != Self.letzterStand {
            Self.letzterStand = stand
            Spur.sag("[Discord] Stand: \(stand) stelle=\(Int(stelle))")
        }
        guard erlaubt else { abraeumen(); return }

        // Pausiert heisst: kein Balken, aber weiter sichtbar. Ein Balken, der
        // laeuft, waehrend das Bild steht, behauptet etwas Falsches.
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

        // Nur bei einer echten Aenderung senden — der Takt laeuft mehrmals je
        // Sekunde. `Discordanzeige` vergleicht die Zeitpunkte auf die
        // Sekunde, sonst waere jeder Vergleich verschieden.
        guard anzeige != zuletzt else { return }
        zuletzt = anzeige
        lief = true
        einreihen { await bruecke.zeigen(anzeige) }
    }

    /// Nichts mehr anzeigen — beim Ausschalten, beim Verlassen des Spielers.
    static func abraeumen() {
        guard lief else { return }
        lief = false
        zuletzt = nil
        einreihen { await bruecke.zeigen(nil) }
    }
}
