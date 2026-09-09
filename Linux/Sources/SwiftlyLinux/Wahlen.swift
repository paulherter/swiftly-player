import Foundation
import JellyfinKit

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

    /// **H1 — aus, bis man es einschaltet.**
    ///
    /// Ohne diesen Schalter gibt es weder die Zeile in der Leiste noch den
    /// Knopf auf der Detailseite. Wie bei Seerr: wer es nicht will, sieht
    /// ausser der einen Zeile in den Einstellungen nichts davon. Wortgleich
    /// von `AppModel.downloadsAn`.
    var downloadsAn = false

    /// **Wie viel Vorrat der Player haelt** — die Stufe aus dem Paket.
    ///
    /// Von einem Nutzer angestossen, der ohne feste Leitung zusieht. Die
    /// Rechnung dahinter liegt in `JellyfinKit.Pufferstufe`; hier steht nur,
    /// welche Stufe gewaehlt ist — als `rawValue`, damit eine Datei von der
    /// Platte nichts von der Gattung wissen muss.
    ///
    /// **Und einmal weiter unten im Decoder.** Der steht hier von Hand, weil
    /// ein fehlender Schluessel sonst *alle* Einstellungen zuruecksetzt; wer
    /// hier ein Feld ergaenzt und es dort vergisst, bekommt eine Wahl, die
    /// sich nach jedem Neustart selbst vergisst.
    var pufferstufe = Pufferstufe.normal.rawValue

    var puffer: Pufferstufe { Pufferstufe(rawValue: pufferstufe) ?? .normal }

    // MARK: Lesen, das eine aeltere Datei ueberlebt

    /// **Ein fehlender Schluessel darf nicht alles zuruecksetzen.**
    ///
    /// Am 08.09.2026 nachgemessen: die Datei auf der Platte stammte von einer
    /// Fassung vor `bildfuellend` und `technikschild`. Swifts erzeugter
    /// Decoder verlangt jeden Schluessel; einer fehlte, `decode` warf, und
    /// `lesen()` gab kommentarlos frische Vorgaben zurueck — **alle**
    /// Einstellungen weg, nicht nur die neue. Qualitaet, Sprachen,
    /// Sprungweiten, Startseitenaufteilung: alles stand wieder auf Anfang,
    /// und niemand hat es gemerkt, weil eine App mit Vorgabewerten
    /// vollkommen normal aussieht.
    ///
    /// Der Fall tritt bei **jeder** neuen Einstellung wieder ein. Also wird
    /// jeder Wert einzeln gelesen und behaelt seine Vorgabe, wenn er fehlt.
    /// Das ist der Grund, warum hier von Hand steht, was Swift sonst selbst
    /// erzeugt.
    init(from decoder: Decoder) throws {
        let k = try decoder.container(keyedBy: CodingKeys.self)
        func w<T: Decodable>(_ s: CodingKeys, _ vorgabe: T) -> T {
            (try? k.decodeIfPresent(T.self, forKey: s)) .flatMap { $0 } ?? vorgabe
        }
        immerDirectPlay        = w(.immerDirectPlay, true)
        bitratenGrenze         = w(.bitratenGrenze, 0)
        tonSprache             = w(.tonSprache, "")
        untertitelSprache      = w(.untertitelSprache, "")
        untertitelAutomatisch  = w(.untertitelAutomatisch, false)
        neuzugaengeGetrennt    = w(.neuzugaengeGetrennt, false)
        naechsteAutomatisch    = w(.naechsteAutomatisch, true)
        zurueckSekunden        = w(.zurueckSekunden, 10)
        vorSekunden            = w(.vorSekunden, 30)
        fortschrittAufKacheln  = w(.fortschrittAufKacheln, true)
        bildfuellend           = w(.bildfuellend, false)
        technikschild          = w(.technikschild, false)
        downloadsAn            = w(.downloadsAn, false)
        pufferstufe            = w(.pufferstufe, Pufferstufe.normal.rawValue)
    }

    /// **Der leere Anfang.** Ohne Datei gilt, was oben an den Feldern steht.
    init() {}

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
enum Werteauswahl { case bitrate, puffer, ton, untertitel, zurueck, vor }

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
        // Nicht mehr `preferences-system` — das traegt jetzt der Knopf,
        // der die Tafel oeffnet, und ein Zeichen soll eine Sache meinen.
        case .tempo:      return "media-seek-forward-symbolic"
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
