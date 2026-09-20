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
/// Direct Play und Bitratengrenze eines Servers — Schlüssel `serverURL.absoluteString`.
/// Wie `AppModel.serverSchluessel` auf Apple: ein Server wandelt vielleicht um, der
/// andere nicht, also gehört die Wahl zum Server, nicht zum Gerät.
struct WiedergabeJeServer: Codable {
    var immerDirectPlay: Bool
    var bitratenGrenze: Int
}

struct Wahlen: Codable {
    /// Die geräteweite Wahl — solange kein Server eine eigene hat (Feld
    /// `wiedergabeJeServer`, unten). Neue Nutzer sehen weiterhin nur die
    /// einfachen zwei Felder; deshalb bleiben die Namen und Vorgaben stehen.
    private var immerDirectPlayGeraet = true
    private var bitratenGrenzeGeraet = 0
    /// Direct Play und Bitratengrenze je Server, wie auf Apple (`AppModel`)
    /// und Android. Nicht `CodingKeys`-geführt über die alten Feldnamen, damit
    /// eine Datei von vor dieser Änderung weiterhin liest.
    var wiedergabeJeServer: [String: WiedergabeJeServer] = [:]
    /// Welcher Server gerade gilt — kommt von der Sitzung (`App.bund`), nicht
    /// gesichert: bei jedem Start setzt `App` ihn frisch, bevor der Player
    /// oder die Einstellungsseite ihn braucht.
    var aktiverServer: String = ""

    /// **Je Server.** Ein Server wandelt vielleicht um, der andere nicht.
    var immerDirectPlay: Bool {
        get { wiedergabeJeServer[aktiverServer]?.immerDirectPlay ?? immerDirectPlayGeraet }
        set {
            guard !aktiverServer.isEmpty else { immerDirectPlayGeraet = newValue; return }
            var w = wiedergabeJeServer[aktiverServer]
                ?? WiedergabeJeServer(immerDirectPlay: immerDirectPlayGeraet, bitratenGrenze: bitratenGrenzeGeraet)
            w.immerDirectPlay = newValue
            wiedergabeJeServer[aktiverServer] = w
        }
    }
    /// **Je Server.** Greift nur, wenn Direct Play für diesen Server nicht erzwungen wird.
    var bitratenGrenze: Int {
        get { wiedergabeJeServer[aktiverServer]?.bitratenGrenze ?? bitratenGrenzeGeraet }
        set {
            guard !aktiverServer.isEmpty else { bitratenGrenzeGeraet = newValue; return }
            var w = wiedergabeJeServer[aktiverServer]
                ?? WiedergabeJeServer(immerDirectPlay: immerDirectPlayGeraet, bitratenGrenze: bitratenGrenzeGeraet)
            w.bitratenGrenze = newValue
            wiedergabeJeServer[aktiverServer] = w
        }
    }
    var tonSprache = ""
    var untertitelSprache = ""
    var untertitelAutomatisch = false
    /// **Neue Filme und neue Serien in eigenen Reihen** statt in einer.
    /// `Startseitenmodell` wertet es aus; die Zeile fehlte auf Linux ganz.
    var neuzugaengeGetrennt = true

    /// **Was dem Server als Grenze gemeldet wird** — die Rechnung liegt im
    /// Paket (``Bitratengrenze``). Sie stand hier und in `AppModel` wortgleich
    /// zweimal; an ihr haengt das Versprechen der App, und zwei Bauplaetze
    /// dafuer laufen garantiert auseinander.
    var profilBitrate: Int {
        Bitratengrenze.fuer(immerDirectPlay: immerDirectPlay, megabit: bitratenGrenze)
    }
    /// **Nur gesetzt, wenn jemand den Schalter „Nächste Folge automatisch"
    /// umgelegt hat** (T3 #15). Sonst gilt die Einstellung des Jellyfin-Kontos,
    /// Regel in `Weiterschalten`; gelesen wird ``App/naechsteAutomatisch``.
    ///
    /// Eigener Schlüssel, weil der alte `naechsteAutomatisch` bei **jedem**
    /// Sichern mitgeschrieben wurde — ein `true` darin sagt nicht, dass es
    /// jemand gewählt hat. Ein `false` schon, die Vorgabe war `true`.
    var naechsteAutomatischGewaehlt: Bool?
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

    /// **Welche Gattung die Merkliste zeigt** — „Filme & Serien", „Filme"
    /// oder „Serien". Sie war ein reiner Speicherwert und damit nach jedem
    /// Start wieder `alle`; auf dem Mac liegt sie in `UserDefaults`, mit der
    /// Begruendung „eine Sortierung ist eine Einstellung, keine Handlung"
    /// (`Sources/Shared/Merklistenmodell.swift:24-25,36-47`).
    var merkgattung = ""

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
        immerDirectPlayGeraet  = w(.immerDirectPlayGeraet, true)
        bitratenGrenzeGeraet   = w(.bitratenGrenzeGeraet, 0)
        wiedergabeJeServer     = w(.wiedergabeJeServer, [:])
        aktiverServer          = ""
        tonSprache             = w(.tonSprache, "")
        untertitelSprache      = w(.untertitelSprache, "")
        untertitelAutomatisch  = w(.untertitelAutomatisch, false)
        // `true` wie auf dem Mac seit dem 11.09.2026
        // (`Sources/Shared/AppModel.swift:265`) — hier stand weiter `false`,
        // und damit sah eine frische Installation anders aus als dort.
        neuzugaengeGetrennt    = w(.neuzugaengeGetrennt, true)
        let alt = (try? decoder.container(keyedBy: AlteSchluessel.self)
                       .decodeIfPresent(Bool.self, forKey: .naechsteAutomatisch)) ?? nil
        naechsteAutomatischGewaehlt = w(.naechsteAutomatischGewaehlt, Bool?.none)
            ?? (alt == false ? false : nil)
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
        merkgattung            = w(.merkgattung, "")
        startReihen            = w(.startReihen, [])
        startAus               = w(.startAus, [])
        startGenres            = w(.startGenres, [])
        genreChips             = w(.genreChips, false)
        sortierungJeOrt        = w(.sortierungJeOrt, [:])
        filterJeOrt            = w(.filterJeOrt, [:])
        bibliothekJeGattung    = w(.bibliothekJeGattung, [:])
    }

    /// Schluessel frueherer Fassungen, die nur noch gelesen werden.
    private enum AlteSchluessel: String, CodingKey { case naechsteAutomatisch }

    /// **Von Hand, wegen der beiden umbenannten Felder.** `immerDirectPlay` und
    /// `bitratenGrenze` heißen jetzt geräteweit `…Geraet` (echte Wahl je Server
    /// liegt in `wiedergabeJeServer`) — eine Datei von vor dieser Änderung soll
    /// trotzdem weiter unter den alten Schlüsseln lesen und schreiben.
    /// `aktiverServer` steht bewusst nicht hier: er kommt von der Sitzung, nicht
    /// von der Platte.
    enum CodingKeys: String, CodingKey {
        case immerDirectPlayGeraet = "immerDirectPlay"
        case bitratenGrenzeGeraet = "bitratenGrenze"
        case wiedergabeJeServer
        case tonSprache, untertitelSprache, untertitelAutomatisch, neuzugaengeGetrennt,
             naechsteAutomatischGewaehlt, zurueckSekunden, vorSekunden, fortschrittAufKacheln,
             bildfuellend, technikschild, downloadsAn, nurUeberWLAN, pufferstufe,
             discordAnzeigen, suchverlauf, merkgattung, startReihen, startAus, startGenres,
             genreChips, sortierungJeOrt, filterJeOrt, bibliothekJeGattung
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(immerDirectPlayGeraet, forKey: .immerDirectPlayGeraet)
        try c.encode(bitratenGrenzeGeraet, forKey: .bitratenGrenzeGeraet)
        try c.encode(wiedergabeJeServer, forKey: .wiedergabeJeServer)
        try c.encode(tonSprache, forKey: .tonSprache)
        try c.encode(untertitelSprache, forKey: .untertitelSprache)
        try c.encode(untertitelAutomatisch, forKey: .untertitelAutomatisch)
        try c.encode(neuzugaengeGetrennt, forKey: .neuzugaengeGetrennt)
        try c.encode(naechsteAutomatischGewaehlt, forKey: .naechsteAutomatischGewaehlt)
        try c.encode(zurueckSekunden, forKey: .zurueckSekunden)
        try c.encode(vorSekunden, forKey: .vorSekunden)
        try c.encode(fortschrittAufKacheln, forKey: .fortschrittAufKacheln)
        try c.encode(bildfuellend, forKey: .bildfuellend)
        try c.encode(technikschild, forKey: .technikschild)
        try c.encode(downloadsAn, forKey: .downloadsAn)
        try c.encode(nurUeberWLAN, forKey: .nurUeberWLAN)
        try c.encode(pufferstufe, forKey: .pufferstufe)
        try c.encode(discordAnzeigen, forKey: .discordAnzeigen)
        try c.encode(suchverlauf, forKey: .suchverlauf)
        try c.encode(merkgattung, forKey: .merkgattung)
        try c.encode(startReihen, forKey: .startReihen)
        try c.encode(startAus, forKey: .startAus)
        try c.encode(startGenres, forKey: .startGenres)
        try c.encode(genreChips, forKey: .genreChips)
        try c.encode(sortierungJeOrt, forKey: .sortierungJeOrt)
        try c.encode(filterJeOrt, forKey: .filterJeOrt)
        try c.encode(bibliothekJeGattung, forKey: .bibliothekJeGattung)
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

// `Spurbereich` (die Leiste-links/Auswahl-rechts-Tafel des Wiedergabemenüs)
// ist mit der neuen Player-Gestaltung entfallen — an ihre Stelle treten die
// drei Ebenen in `PlayerEbenen.swift` (Audio & Untertitel, Einstellungen,
// Folgen), wörtlich nach `Sources/macOS/PlayerEbenen.swift`. Tempo gibt es
// dort nicht mehr, wie auf dem Mac: „kein Tempo — stand im alten
// Wiedergabemenü und fällt mit ihm weg".

/// Die Fassung von libVLC, für die Fußzeile der Einstellungen.
///
/// Auf den Apple-Fassungen steht dort „VLCKit 4.0.0-a23". Hier liegt kein
/// VLCKit, sondern libVLC des Systems — der Text nennt deshalb, was wirklich
/// geladen ist, statt eine Fassung zu behaupten.
enum VLCFassung {
    nonisolated(unsafe) static var text: String = "3.x"
}
