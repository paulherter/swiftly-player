import Foundation
// Auf Linux liegt URLSession nicht in Foundation, sondern in einem
// eigenen Modul. Auf Apple-Plattformen gibt es das Modul nicht — der
// Import ist deshalb bedingt und dort wirkungslos.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// **Eine laufende Prüfung einer eingetippten Serveradresse.**
///
/// Trägt eine fortlaufende Nummer und die Adresse, für die sie gestartet
/// wurde. Wer die Antwort auswertet, fragt vorher ``Pruefstand/gilt(_:)`` —
/// eine Antwort zu einer älteren Eingabe wird verworfen.
public struct Pruefmarke: Sendable, Equatable {
    public let nummer: Int
    public let adresse: String
}

/// **Nur die jüngste Adressprüfung darf wirken.**
///
/// Eine Adresse, unter der niemand antwortet, braucht bis zur Fehlermeldung
/// ihre Frist. Wer in der Zeit die Adresse korrigiert und erneut abschickt,
/// startet eine zweite Prüfung — und die erste kam früher trotzdem noch an:
/// ihr Fehler setzte die App auf die Adressmaske zurück, während man schon
/// Name und Passwort für den richtigen Server eintrug.
///
/// Jede Prüfung holt sich hier eine ``Pruefmarke``; eine neue Prüfung oder
/// ein Verwerfen (Adresse geändert) macht die vorige ungültig. Der Wert
/// gehört dem, der die Oberfläche führt, und wird nur von dort geändert.
public struct Pruefstand: Sendable {
    public private(set) var laufend: Pruefmarke?
    private var zaehler = 0

    public init() {}

    /// Startet eine Prüfung; die bisherige gilt ab jetzt nicht mehr.
    public mutating func beginnen(_ adresse: String) -> Pruefmarke {
        zaehler += 1
        let marke = Pruefmarke(nummer: zaehler, adresse: adresse)
        laufend = marke
        return marke
    }

    /// Darf die Antwort zu `marke` noch etwas ändern?
    public func gilt(_ marke: Pruefmarke) -> Bool { laufend == marke }

    /// Beendet die Prüfung zu `marke`. `false`, wenn sie schon überholt war —
    /// dann hat der Aufrufer nichts mehr anzufassen.
    @discardableResult
    public mutating func abschliessen(_ marke: Pruefmarke) -> Bool {
        guard gilt(marke) else { return false }
        laufend = nil
        return true
    }

    /// Die Adresse wurde geändert: was noch läuft, gilt nicht mehr.
    public mutating func verwerfen() { laufend = nil }
}

/// **Wie lange eine eingetippte Adresse geprüft wird, und über welche
/// Sitzung.**
///
/// Die gewöhnliche Sitzung (``Foundation/URLSession/ortsnetzfaehig``) wartet
/// mit `waitsForConnectivity` auf eine Verbindung — auch dann, wenn es den
/// Namen gar nicht gibt. Gemessen am Mac: ein unbekannter Name scheiterte
/// dort erst nach 20,8 Sekunden an der Frist, ohne das Warten sofort mit
/// „Name nicht gefunden". Die App versuchte danach noch `http` — zusammen
/// gut 40 Sekunden bis zur Meldung.
public enum Adresspruefung {

    /// **Acht Sekunden für die ganze Prüfung.** `System/Info/Public` ist
    /// eine winzige Antwort; ein Server, der in acht Sekunden nicht
    /// antwortet, ist für die Anmeldung nicht brauchbar.
    public static let frist: TimeInterval = 8

    /// **Im Heimnetz wird weiter auf die Verbindung gewartet**, nur kürzer:
    /// dort fragt iOS beim ersten Mal nach der Ortsnetz-Erlaubnis, und die
    /// Anfrage soll nach dem Erlauben weiterlaufen statt zu scheitern.
    /// Draußen gibt es diese Abfrage nicht — ein unbekannter Name kommt
    /// dann sofort als Fehler an.
    public static func sitzung(fuer adresse: URL) -> URLSession {
        AppModelURLNormalizer.istImHeimnetz(adresse.host() ?? "") ? heimnetz : draussen
    }

    /// **Lohnt nach diesem Fehler der Versuch mit `http`?**
    ///
    /// Nicht, wenn es den Namen nicht gibt — daran ändert das Schema nichts.
    /// Nicht nach Ablauf der Frist — sonst wartet man sie zweimal ab. Nicht
    /// ohne Netz und nicht bei einer abgebrochenen Prüfung. Alles andere
    /// (Zertifikat, abgewiesen, eine fremde Seite) kommt schnell und kann am
    /// Schema liegen.
    public static func ausweichenLohnt(nach fehler: any Error) -> Bool {
        if fehler is CancellationError { return false }
        let code: Int
        if let j = fehler as? JellyfinError {
            guard case let .netz(c) = j else { return true }
            code = c
        } else {
            let ns = fehler as NSError
            guard ns.domain == NSURLErrorDomain else { return true }
            code = ns.code
        }
        switch URLError.Code(rawValue: code) {
        case .cannotFindHost, .dnsLookupFailed, .timedOut, .cancelled,
             .notConnectedToInternet:
            return false
        default:
            return true
        }
    }

    private static func konfiguration(warten: Bool) -> URLSessionConfiguration {
        let k = URLSessionConfiguration.default
        #if canImport(Darwin)
        k.waitsForConnectivity = warten
        #endif
        k.timeoutIntervalForRequest = frist
        k.timeoutIntervalForResource = frist
        return k
    }

    private static let heimnetz = URLSession(configuration: konfiguration(warten: true))
    private static let draussen = URLSession(configuration: konfiguration(warten: false))
}
