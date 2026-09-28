import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// **Die nächste Folge vorbereiten, bevor sie gebraucht wird.**
///
/// Beim Wechsel wartete der Player bisher auf zwei Dinge nacheinander: den
/// Plan vom Server (`PlaybackInfo`) und den Anfang der neuen Datei. Beides
/// lässt sich in den letzten Minuten der laufenden Folge erledigen, wenn das
/// Netz ohnehin frei ist — dann steht beim Wechsel der Plan schon da, und der
/// Anfang der Datei liegt beim Server im Speicher statt auf der Platte.
///
/// **Sparsam:** nur gegen Ende, nur einmal je Folge, nur über ein Netz, das
/// nichts kostet (kein Mobilfunk, kein Datensparmodus), und nicht für
/// heruntergeladene Folgen — die liegen schon auf dem Gerät.
public enum Vorpuffer {

    /// Ab so viel Restzeit wird vorbereitet: drei Minuten.
    public static let restsekunden: Double = 180

    /// So viel vom Anfang der Datei wird vorgeladen: 4 MiB. Genug für Kopf
    /// und erste Sekunden einer Folge, klein genug, um nicht aufzufallen.
    public static let anfangsbytes: Int = 4 * 1024 * 1024

    /// Wie lange ein vorbereiteter Plan gilt. Wer im Abspann eine
    /// Viertelstunde anhält, bekommt beim Wechsel einen frischen.
    public static let haltbarkeit: TimeInterval = 600

    /// Ob jetzt vorbereitet werden soll.
    ///
    /// - Parameters:
    ///   - abspannVon: wo der Abspann-Abschnitt beginnt, falls der Server
    ///     einen kennt — ab dort gilt die Folge ebenfalls als fast durch.
    ///   - netzGuenstig: WLAN oder Kabel, ohne Datensparmodus.
    public static func jetzt(position: Double, dauer: Double, abspannVon: Double?,
                             netzGuenstig: Bool) -> Bool {
        guard netzGuenstig else { return false }
        guard dauer > Folgenende.mindestlaufzeit, position.isFinite, position > 0 else { return false }
        if dauer - position <= restsekunden { return true }
        if let abspannVon, abspannVon > 0, position >= abspannVon { return true }
        return false
    }

    /// Ob ein vorbereiteter Plan beim Wechsel noch genommen wird.
    public static func frisch(vorbereitet: Date, jetzt: Date) -> Bool {
        jetzt.timeIntervalSince(vorbereitet) < haltbarkeit
    }

    /// Ob der Anfang der Datei vorgeladen wird — nur übers Netz, nicht bei
    /// einer Datei auf dem Gerät, und nicht bei einer Umwandlung: deren
    /// Adresse würde am Server eine Umwandlung anstoßen, die vielleicht nie
    /// gebraucht wird.
    public static func anfangLaden(adresse: URL, methode: DeliveryMethod) -> Bool {
        guard !adresse.isFileURL, let schema = adresse.scheme?.lowercased(),
              schema == "http" || schema == "https" else { return false }
        return methode == .directPlay
    }

    /// **Den Anfang der Datei einmal anfordern** — ``anfangsbytes`` per
    /// `Range`, mit den eigenen Köpfen des Servers, ohne Zwischenspeicher: die
    /// Bytes sollen beim Server im Speicher liegen, nicht ein zweites Mal auf
    /// dem Gerät. Gibt zurück, wie viele Bytes kamen. Für iPhone und Android.
    @discardableResult
    public static func anfangAnfordern(_ adresse: URL) async throws -> Int {
        var anfrage = URLRequest.mitEigenenKoepfen(adresse)
        anfrage.setValue("bytes=0-\(anfangsbytes - 1)", forHTTPHeaderField: "Range")
        anfrage.cachePolicy = .reloadIgnoringLocalCacheData
        let (daten, _) = try await sitzung.data(for: anfrage)
        return daten.count
    }

    private static let sitzung: URLSession = {
        let einstellung = URLSessionConfiguration.ephemeral
        einstellung.urlCache = nil
        einstellung.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: einstellung)
    }()
}
