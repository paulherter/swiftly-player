import Foundation

/// Zwei Entscheidungen, die nach Oberfläche aussehen und keine sind.
///
/// **Warum sie hier stehen.** Beide sind Zahlen, die auf sechs Plattformen
/// gleich sein müssen und nirgends festgehalten waren — jede Fassung hatte
/// sie selbst getippt. Genau daraus wird die Kopie, die auseinanderläuft:
/// bei `sekunden > 0` ist es passiert, und der Fehler stand danach monatelang
/// auf dem Fernseher.
///
/// Der Wortlaut der Anzeige bleibt in den Ansichten — der hängt am Katalog
/// und an der Sprache. Hier steht nur, **ob** etwas angezeigt wird.
public enum Anzeigeregeln {

    /// Ob eine Laufzeit überhaupt angezeigt werden darf.
    ///
    /// **Der Fall, an dem es hing:** eine Serie hat keine eigene Laufzeit,
    /// der Server meldet dort `0`. Ohne diese Prüfung stand auf der Kachel
    /// „0 Min." — auf tvOS wochenlang, weil die iOS-Fassung die Prüfung hatte
    /// und die abgeschriebene nicht. `CLAUDE.md` führt genau das als das
    /// Beispiel für eine kopierte Funktion, die auseinandergelaufen ist.
    ///
    /// Auch `nil` und negative Werte fallen heraus: ein Server, der Unsinn
    /// meldet, soll keine Anzeige erzeugen, die wie eine Angabe aussieht.
    ///
    /// `Double`, weil `Item.runtimeSeconds` einer ist — der Server rechnet
    /// in Ticks, und daraus wird beim Umrechnen eine Kommazahl. Wer hier
    /// `Int` schreibt, zwingt jeden Aufrufer zu einer Umwandlung und
    /// verliert dabei die halbe Sekunde, um die es nie ging.
    public static func laufzeitZeigen(sekunden: Double?) -> Bool {
        guard let sekunden else { return false }
        return sekunden > 0
    }

    /// Ab wann eine Sucheingabe an den Server geht.
    ///
    /// **Ein einzelner Buchstabe ist keine Suche**, sondern eine Anfrage über
    /// die halbe Bibliothek — und sie kommt bei jedem Tastendruck erneut. Zwei
    /// Zeichen sind die Schwelle, ab der die Antwort etwas bedeutet.
    ///
    /// Leerzeichen zählen nicht mit: wer „a " tippt, hat einen Buchstaben
    /// getippt.
    public static func suchbegriffTaugt(_ begriff: String) -> Bool {
        begriff.trimmingCharacters(in: .whitespacesAndNewlines).count > 1
    }
}
