import Foundation

/// Darf dieses Konto Titel aufs Geraet laden? Das Recht heisst am Server
/// `Policy.EnableContentDownloading`, im Dashboard „Allow media downloading".
///
/// **Gemessen am 17.09.2026** gegen `tv.paulherter.de`, Jellyfin 12.0.0: von
/// 409 Operationen im OpenAPI-Dokument des Servers traegt genau **eine** die
/// Berechtigung `Download` — `GET /Items/{itemId}/Download`, mit einer 403
/// unter den Antworten. `GET /Videos/{itemId}/stream` traegt **keine**. Und
/// genau das ist Swiftlys Downloadadresse
/// (``JellyfinClient/downloadURL(itemID:mediaSourceID:)``), im Kommentar
/// sogar damit begruendet, dass dieser Weg das Recht nicht braucht. Er
/// brauchte es wirklich nicht: der Haken war weg, der Knopf war da, die
/// Datei kam trotzdem. Kein Code hat das Recht gelesen.
///
/// **Die Entscheidung liegt hier und nur hier.** Sechs Oberflaechen fragen
/// ``anbieten(recht:funktionAn:)``, damit nicht eine davon anders antwortet —
/// eine zweite Liste in Kotlin oder ein Nachbau in GTK waere genau der
/// Fehler, den `nachladen()` schon einmal gemacht hat.
public enum Downloadrecht: String, Sendable, Equatable, CaseIterable {

    /// Der Server hat nichts gesagt: altes Jellyfin, kein `Policy`-Block,
    /// oder die Anfrage kam nicht durch.
    case unbekannt
    /// `EnableContentDownloading: true`.
    case erlaubt
    /// `EnableContentDownloading: false`.
    case verboten

    /// Aus dem Feld, wie es `GET /Users/{id}` liefert — `nil` heisst „stand
    /// nicht drin".
    public static func vomServer(_ wert: Bool?) -> Downloadrecht {
        guard let wert else { return .unbekannt }
        return wert ? .erlaubt : .verboten
    }

    /// **`unbekannt` gilt als erlaubt**, und das ist Absicht.
    ///
    /// Ein Netzfehler, ein aelterer Server oder ein fehlendes Feld darf
    /// niemandem etwas wegnehmen, was er darf. Sperren tut nur ein
    /// ausdrueckliches `false` — dieselbe Richtung wie bei
    /// ``Weiterschalten``, wo ein schweigender Server die Vorgabe der App
    /// stehen laesst.
    public var darfLaden: Bool { self != .verboten }

    /// Ob eine Oberflaeche einen Ladeknopf zeigt.
    ///
    /// Zwei Bedingungen, eine Antwort: der Schalter in den Einstellungen (H1
    /// — ohne ihn gibt es die Funktion ueberhaupt nicht) **und** das Recht am
    /// Konto. Faellt eine weg, ist der Knopf **nicht da** — nicht da und
    /// wirft einen Fehler. Ein Knopf, der nur zum Scheitern gedrueckt wird,
    /// ist schlechter als keiner.
    ///
    /// Was schon auf der Platte liegt, haengt nicht daran: der Reiter
    /// „Downloads" und die Zeile in den Einstellungen bleiben am Schalter,
    /// sonst kaeme niemand mehr an seine geladenen Dateien, um sie zu
    /// loeschen.
    public static func anbieten(recht: Downloadrecht, funktionAn: Bool) -> Bool {
        funktionAn && recht.darfLaden
    }
}
