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
    /// **Über Mobilfunk warten Downloads** (H5). Steht auch auf dem
    /// Schreibtisch zur Wahl: ein Laptop hängt durchaus mal an einem
    /// getakteten Anschluss.
    var nurUeberWLAN = true

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
    /// **Zeigt Discord, was gerade laeuft — aus, bis man es einschaltet.**
    ///
    /// Die einzige Einstellung dieser App, die etwas nach **draussen** gibt:
    /// wer sie anlegt, sagt jedem in seinen Discord-Servern, welchen Film er
    /// sieht. Eine Vorgabe „an" waere keine Bequemlichkeit, sondern eine
    /// Veroeffentlichung, um die niemand gebeten hat.
    var discordAnzeigen = false

    var pufferstufe = Pufferstufe.normal.rawValue

    /// **„Zuletzt gesucht", roh wie auf der Platte.** Die Liste selbst rechnet
    /// ``Suchverlauf`` im Paket aus — hoechstens acht, das Juengste zuerst,
    /// ohne Doppelte. Hier liegt nur die Zeichenkette, damit das Format an
    /// einer Stelle steht und nicht in drei Ansichten.
    var suchverlauf = ""

    // MARK: Startseite

    /// Die Reihenfolge der Startseitenreihen, als `rawValue` von
    /// ``Startreihe``. Leer heisst: die Grundfolge des Pakets.
    var startReihen: [String] = []
    /// Welche Reihen ausgeblendet sind.
    var startAus: [String] = []
    /// Die gewählten Genres — als eigene Reihen unten oder als Chips oben.
    var startGenres: [String] = []
    /// **Zwei Formen derselben Auswahl, nicht zwei Mengen.** Der Schalter
    /// wechselt, *wie* die gewählten Genres erscheinen, nicht *welche* — ein
    /// früherer Anlauf auf Apple zeigte als Chips plötzlich alle Genres des
    /// Servers, und niemand verstand, warum.
    var genreChips = false

    // MARK: Was je Ort gemerkt wird

    /// **Sortierung und Filter überleben den Neustart** (D9).
    ///
    /// Ein Nutzer am 07.09.2026: „ich sortiere nach zuletzt, weil es
    /// praktisch ist. Verlasse ich die App und komme wieder, bin ich zurück
    /// beim Standard." Er hat recht, und es ist keine Kleinigkeit: eine
    /// Sortierung ist keine Handlung, sondern eine Einstellung — man trifft
    /// sie einmal und erwartet sie danach vorzufinden.
    ///
    /// **Je Ort, nicht global.** Filme nach Jahr und Serien nach zuletzt
    /// hinzugefügt ist eine sinnvolle Kombination; ein gemeinsamer Wert
    /// spielte sie gegeneinander aus. Der Schlüssel ist die Bereichskennung.
    var sortierungJeOrt: [String: String] = [:]
    var filterJeOrt: [String: String] = [:]
    /// Welche Bibliothek ein Bereich zeigt, wenn es mehrere gibt (D9).
    var bibliothekJeGattung: [String: String] = [:]

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
        nurUeberWLAN           = w(.nurUeberWLAN, true)
        pufferstufe            = w(.pufferstufe, Pufferstufe.normal.rawValue)
        discordAnzeigen        = w(.discordAnzeigen, false)
        suchverlauf            = w(.suchverlauf, "")
        startReihen            = w(.startReihen, [])
        startAus               = w(.startAus, [])
        startGenres            = w(.startGenres, [])
        genreChips             = w(.genreChips, false)
        sortierungJeOrt        = w(.sortierungJeOrt, [:])
        filterJeOrt            = w(.filterJeOrt, [:])
        bibliothekJeGattung    = w(.bibliothekJeGattung, [:])
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
        // **Der Zeichensatz auf diesem Rechner ist Breeze, nicht Adwaita.**
        //
        // Am 13.09.2026 nachgemessen: `gsettings get
        // org.gnome.desktop.interface icon-theme` sagt `breeze-dark`. Hier
        // standen nacheinander `utilities-system-monitor-symbolic` und
        // `preferences-system-details-symbolic` — beide kennt Breeze nicht,
        // und Adwaitas `legacy`-Ordner faengt GTK4 nicht ab. Zu sehen war das
        // Ersatzbild „fehlendes Bild" mit rotem Verbotszeichen.
        //
        // Der Mac nimmt `waveform.badge.magnifyingglass`. Was Breeze **hat**
        // und dasselbe meint, ist das Zahnrad der Systemeinstellungen; es
        // steht in den Einstellungen an derselben Zeile.
        case .technik:    return "preferences-system-symbolic"
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
