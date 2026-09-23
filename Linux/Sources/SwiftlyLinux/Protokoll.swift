import Foundation
import JellyfinKit

/// **Eine Zeile Protokoll, mit Uhrzeit und mit Laufzeit.**
///
/// Bis zum 20.09.2026 schrieb jede Stelle selbst: ``Startstufe`` und
/// `Spur.schreiben` mit Uhrzeit, die Zeilen aus dem Spieler mit blossem
/// `print` ganz ohne. Im Protokoll eines Testers stand deshalb zwar, *was*
/// passiert ist, aber bei der Haelfte der Zeilen nicht, *wann* — und der
/// Abstand zwischen zwei Zeilen ist bei einem Fehler, der sich als Warten
/// zeigt, die ganze Auskunft.
///
/// **Warum zusaetzlich eine Laufzeit.** Dasselbe Protokoll trug zwei
/// Uhrzeiten: das Startprogramm schrieb 20:33, die App 18:33. Foundation
/// kommt unter Windows nicht auf jedem Rechner an die Zeitzone und faellt
/// dann auf UTC zurueck; in der hiesigen VM passiert das nicht, beim Tester
/// schon. Die Uhrzeit taugt damit nicht als gemeinsames Mass. Die Laufzeit
/// seit Programmstart schon: sie kommt aus einer Uhr, die keine Zeitzone
/// kennt, laeuft auf beiden Plattformen gleich und beantwortet die Frage,
/// auf die es ankommt — wie viele Sekunden lagen zwischen dem Oeffnen und
/// dem ersten Bild.
///
/// Die Uhrzeit bleibt trotzdem stehen: sie verbindet das Protokoll mit dem,
/// was ein Zuschauer erzaehlt („so gegen halb neun").
///
/// **Nie etwas Geheimes.** Keine Adresse mit Token, kein Servername, kein
/// Kontoname — die Datei schickt ein Nutzer im Zweifel weiter. Dieselbe
/// Regel wie bei ``Startstufe``.
enum Protokoll {

    /// Der Nullpunkt der Laufzeit. Wird beim ersten Zugriff gesetzt, und der
    /// liegt in `main.swift` vor allem anderen.
    private static let start = ContinuousClock.now

    /// Sekunden seit Programmstart, aus einer Uhr ohne Zeitzone.
    static var laufzeit: Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds)
             + Double(d.components.attoseconds) / 1e18
    }

    private static let uhr: DateFormatter = {
        let u = DateFormatter()
        u.dateFormat = "HH:mm:ss.SSS"
        return u
    }()

    /// `20:33:42.406 +1.5s [Spieler] …`
    static func schreib(_ text: String) {
        // **Punkt, nicht Komma.** Ohne festes Gebietsschema schreibt
        // Foundation die Laufzeit in der Sprache des Rechners, und ein
        // Protokoll, das mal „6,3" und mal „6.3" sagt, laesst sich nicht
        // auswerten. `max(0, …)` faengt die negative Null der allerersten
        // Zeile ab, die sonst als „+-0.0s" dasteht.
        print(String(format: "%@ +%.1fs %@", locale: Locale(identifier: "en_US_POSIX"),
                     uhr.string(from: Date()), max(0, laufzeit), text))
        // Dazu in den Ring fuer „Protokoll teilen" — geschwaerzt beim
        // Eintragen, nur im Speicher, wie auf den Apple-Fassungen.
        Protokollring.geteilt.anhaengen(text)
        // Sofort hinaus — `print` in eine umgeleitete Datei ist blockweise
        // gepuffert. Die Begruendung steht ausfuehrlich in `main.swift`.
        fflush(nil)
    }

    /// **Wie lange ein Abschnitt auf dem Hauptfaden gebraucht hat.**
    ///
    /// Schreibt nur, wenn es lange genug gedauert hat, um aufzufallen: alles
    /// ueber 100 ms haelt GTK vom Zeichnen ab, und ab etwa einer Viertelsekunde
    /// nennt ein Zuschauer das Fenster eingefroren. Genau so hat es ein Tester
    /// am 20.09.2026 beschrieben — „fenster war wie eingefroren fuer ueber 5
    /// sekunden" —, und ohne diese Zeilen ist nicht zu sagen, welcher Aufruf
    /// es war.
    ///
    /// Die Messung selbst kostet nichts und bleibt deshalb in jedem Bau.
    @discardableResult
    static func mitUhr<T>(_ was: String, _ block: () -> T) -> T {
        let begonnen = ContinuousClock.now
        let ergebnis = block()
        let d = ContinuousClock.now - begonnen
        let ms = Double(d.components.seconds) * 1000
              + Double(d.components.attoseconds) / 1e15
        if ms >= 100 {
            schreib(String(format: "[Hauptfaden] %@ hat %.0f ms gebraucht", was, ms))
        }
        return ergebnis
    }

    /// **Einmal beim Start: woher die Uhrzeit kommt.**
    ///
    /// Steht hier `UTC`, obwohl der Rechner woanders steht, sind die
    /// Uhrzeiten im Protokoll gegen die des Startprogramms verschoben — und
    /// dann ist die Laufzeit das Mass, nicht die Uhr.
    static func zeitzoneMelden() {
        let z = TimeZone.current
        schreib("[Protokoll] Zeitzone \(z.identifier), Versatz \(z.secondsFromGMT() / 3600) h")
    }
}

/// **„Protokoll teilen" — die letzte Stunde als Textdatei.**
///
/// Dieselbe Datei wie `Protokolldatei.schreiben()` in
/// `Sources/Shared/Protokollteilen.swift`: Fassung, System, Stand, dann die
/// Zeilen aus ``Protokollring``. Ein Teilen-Menue wie auf dem Mac gibt es
/// hier nicht; die Datei wird deshalb im Dateimanager gezeigt, von wo sie in
/// den Discord oder eine Mail gezogen wird.
enum Protokolldatei {
    static func schreiben() -> URL? {
        #if os(Windows)
        let system = "Windows"
        #else
        let system = "Linux"
        #endif
        var zeilen = [
            "\(Fassung.voll) · libVLC \(VLCFassung.text)",
            "\(system) \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Stand \(ISO8601DateFormatter().string(from: Date()))",
            "",
        ]
        let auszug = Protokollring.geteilt.auszug(sekunden: 3600)
        zeilen += auszug.isEmpty
            ? ["(no lines in the last hour — reproduce the problem first, then share without closing the app)"]
            : auszug
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Swiftly-Protokoll.txt")
        do {
            try Data(zeilen.joined(separator: "\n").utf8).write(to: url, options: .atomic)
        } catch {
            Protokoll.schreib("[Protokoll] Datei liess sich nicht schreiben: \(error.localizedDescription)")
            return nil
        }
        return url
    }
}
