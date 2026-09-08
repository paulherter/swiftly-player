import Foundation

/// Die Einstellungen des Nutzers, wie sie auf den Apple-Fassungen in
/// `AppModel` liegen — dort in `@AppStorage`, hier als JSON neben der
/// Sitzung.
///
/// **Die Vorgaben stehen so auf dem Mac** und sind nicht neu gewählt: Direct
/// Play erzwungen (der Grund für diese App), Bitrate unbegrenzt, nächste
/// Folge selbsttätig, 10 s zurück und 30 s vor. Welche Werte überhaupt zur
/// Wahl stehen, steht in `JellyfinKit.Bitrate`, `.Spanne` und `.Sprachwahl` —
/// nicht hier, sonst böten die Plattformen verschiedene Listen an.
struct Wahlen: Codable {
    var immerDirectPlay = true
    var bitratenGrenze = 0
    var tonSprache = ""
    var untertitelSprache = ""
    var untertitelAutomatisch = false
    /// **Neue Filme und neue Serien in eigenen Reihen** statt in einer.
    /// `Startseitenmodell` wertet es aus; die Zeile fehlte auf Linux ganz.
    var neuzugaengeGetrennt = false

    /// **Was dem Server als Grenze gemeldet wird.**
    ///
    /// Eine Milliarde heisst praktisch unbegrenzt — ein Limit löst
    /// Transkodierung aus, auch wenn Container und Codec passen. Wörtlich
    /// `AppModel.profilBitrate` vom Mac; die beiden Einstellungen darüber
    /// waren auf Linux gesetzt, gesichert und ohne jede Wirkung, weil sie
    /// niemand las.
    var profilBitrate: Int {
        immerDirectPlay || bitratenGrenze <= 0 ? 1_000_000_000 : bitratenGrenze * 1_000_000
    }
    var naechsteAutomatisch = true
    var zurueckSekunden = 10
    var vorSekunden = 30
    var fortschrittAufKacheln = true
    /// **Bild formatfuellend statt vollstaendig.**
    ///
    /// Dieselbe Wahl wie die Zusammenziehgeste auf iPhone und iPad und die
    /// Zeile im Wiedergabemenue auf Mac und Fernseher — zwei Zustaende, kein
    /// dritter, weil der nur eine Streckung waere. Auf den Apple-Fassungen
    /// steht sie in `@AppStorage("bildfuellend")`; hier liegt sie in
    /// derselben Datei wie die uebrigen Wahlen.
    var bildfuellend = false
    /// **Das Technikschild — die Auskunft, die stehenbleibt.**
    ///
    /// Wer ein Ruckeln sieht, sieht es *waehrend* er zusieht. Der Schalter
    /// gehoert deshalb in den Player, nicht in die Einstellungen; genau so
    /// steht es auf den Apple-Fassungen.
    var technikschild = false

    private static var datei: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/swiftly/wahlen.json")
    }

    static func lesen() -> Wahlen {
        guard let daten = try? Data(contentsOf: datei),
              let w = try? JSONDecoder().decode(Wahlen.self, from: daten)
        else { return Wahlen() }
        return w
    }

    func sichern() {
        let ordner = Self.datei.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        guard let daten = try? JSONEncoder().encode(self) else { return }
        try? daten.write(to: Self.datei, options: .atomic)
    }
}

/// Welche Werteliste gerade aufgeklappt ist.
enum Werteauswahl { case bitrate, ton, untertitel, zurueck, vor }

/// **Welcher Bereich im Wiedergabemenue links gewaehlt ist.**
///
/// Die Reihenfolge ist die der Mac-Fassung: erst die Spuren, dann Bild und
/// Tempo, zuletzt die Schlafzeit. `Technikschild` fehlt hier noch — es gibt
/// das Schild auf Linux und Windows bisher nicht.
enum Spurbereich: CaseIterable {
    case ton, untertitel, bildformat, tempo, schlafzeit, technik

    var titel: String {
        switch self {
        case .ton:        return uebersetzt("Ton")
        case .untertitel: return uebersetzt("Untertitel")
        case .bildformat: return uebersetzt("Bildformat")
        case .tempo:      return uebersetzt("Tempo")
        case .schlafzeit: return uebersetzt("Schlafzeit")
        case .technik:    return uebersetzt("Technikschild")
        }
    }

    var symbol: String {
        switch self {
        case .ton:        return "audio-volume-high-symbolic"
        case .untertitel: return "media-view-subtitles-symbolic"
        case .bildformat: return "view-fullscreen-symbolic"
        case .tempo:      return "preferences-system-symbolic"
        case .schlafzeit: return "weather-clear-night-symbolic"
        case .technik:    return "utilities-system-monitor-symbolic"
        }
    }
}

/// Die Fassung von libVLC, für die Fußzeile der Einstellungen.
///
/// Auf den Apple-Fassungen steht dort „VLCKit 4.0.0-a23". Hier liegt kein
/// VLCKit, sondern libVLC des Systems — der Text nennt deshalb, was wirklich
/// geladen ist, statt eine Fassung zu behaupten.
enum VLCFassung {
    nonisolated(unsafe) static var text: String = "3.x"
}
