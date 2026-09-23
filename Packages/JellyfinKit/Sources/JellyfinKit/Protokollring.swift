import Foundation

/// **Was ein Nutzer uns schicken kann, wenn etwas nicht geht.**
///
/// Das Dateiprotokoll gibt es nur im Entwicklerbau. Meldet jemand draußen
/// „lädt endlos", fehlt genau die Zeile, die sagt, woran es hängt — der
/// Fehler lässt sich bei uns oft nicht nachstellen (eigenes VPN, eigenes
/// Netz). Deshalb halten alle Baue die letzten Zeilen im Speicher, und das
/// Profil gibt sie über das Teilen-Blatt heraus („Protokoll teilen").
///
/// Nur im Speicher: nichts landet in `Documents` oder in einer Sicherung, und
/// nach einem Neustart ist es weg. Wer teilt, muss den Fehler also in
/// derselben Sitzung nachgestellt haben — das sagt auch die Datei, wenn sie leer ist.
public final class Protokollring: @unchecked Sendable {

    public static let geteilt = Protokollring()

    private let sperre = NSLock()
    private var zeilen: [(zeit: Date, text: String)] = []
    private let grenze: Int

    public init(grenze: Int = 4000) {
        self.grenze = grenze
    }

    /// Geschwärzt wird **beim Eintragen**, nicht erst beim Teilen: dann liegt
    /// ein Zugangsmerkmal auch im Speicher nie im Klartext.
    public func anhaengen(_ text: String, jetzt: Date = Date()) {
        let sauber = Protokollschwaerzung.text(text)
        sperre.lock(); defer { sperre.unlock() }
        zeilen.append((jetzt, sauber))
        // In Schüben kürzen, nicht bei jeder Zeile um eins verschieben.
        if zeilen.count > grenze + grenze / 8 {
            zeilen.removeFirst(zeilen.count - grenze)
        }
    }

    /// Die Zeilen der letzten `sekunden`, älteste zuerst, mit Uhrzeit.
    public func auszug(sekunden: TimeInterval = 3600, jetzt: Date = Date()) -> [String] {
        let grenzzeit = jetzt.addingTimeInterval(-sekunden)
        sperre.lock()
        let auswahl = zeilen.filter { $0.zeit >= grenzzeit }
        sperre.unlock()
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "HH:mm:ss.SSS"
        return auswahl.map { "\(format.string(from: $0.zeit)) \($0.text)" }
    }
}

/// **Zugangsmerkmale aus freiem Text.**
///
/// ``Foundation/URL/ohneGeheimnis`` greift nur, wo eine Adresse als `URL`
/// vorliegt. VLC und das System schreiben Adressen aber in ihre eigenen
/// Meldungen, als Text — dort stand das Token bisher im Klartext. Dieselben
/// Namen wie dort, dazu der `Authorization`-Kopf und Zugangsdaten in der
/// Adresse (`http://name:passwort@…`).
public enum Protokollschwaerzung {

    private static let namen = "api_key|apikey|x-emby-token|x-mediabrowser-token|token|accesstoken|access_token|secret|pw|password"

    nonisolated(unsafe) private static let muster: [(NSRegularExpression, String)] = [
        // name="wert" — der Authorization-Kopf von Jellyfin
        (try! NSRegularExpression(pattern: "(?i)\\b(\(namen))(\\s*[=:]\\s*)\"[^\"]*\""), "$1$2\"…\""),
        // name=wert — Abfragewerte und Kopfzeilen
        (try! NSRegularExpression(pattern: "(?i)\\b(\(namen))(\\s*[=:]\\s*)[^&\\s\"',;)]+"), "$1$2…"),
        // scheme://name:passwort@
        (try! NSRegularExpression(pattern: "(?i)([a-z][a-z0-9+.-]*://)[^/\\s@:]+:[^/\\s@]+@"), "$1…@"),
    ]

    public static func text(_ roh: String) -> String {
        var text = roh
        for (regel, ersatz) in muster {
            let bereich = NSRange(text.startIndex..., in: text)
            text = regel.stringByReplacingMatches(in: text, range: bereich, withTemplate: ersatz)
        }
        return text
    }
}
