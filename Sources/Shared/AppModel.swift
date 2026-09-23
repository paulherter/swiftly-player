import Foundation
import OSLog
import JellyfinKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class AppModel {

    enum Phase: Equatable {
        case disconnected
        case connecting
        case needsLogin(serverName: String, version: String)
        case ready
    }

    var phase: Phase = .disconnected
    var errorMessage: String?
    var views: [Item] = []
    /// Für die Kopfzeile im Profilmenü.
    var serverName: String?

    // MARK: Einstellungen

    /// Nie umwandeln lassen. Der Grund für diese App — deshalb Vorgabe an.
    /// **Je Server.** Ein Server wandelt vielleicht um, der andere nicht —
    /// die Wahl gehört zum Server, nicht zum Gerät (`serverSchluessel`).
    var immerDirectPlay: Bool { didSet { merken(immerDirectPlay, "immerDirectPlay" + serverSchluessel) } }
    /// Obergrenze in Mbit/s, 0 heißt unbegrenzt. Greift nur, wenn Direct Play
    /// nicht erzwungen wird.
    var bitratenGrenze: Int { didSet { merken(bitratenGrenze, "bitratenGrenze" + serverSchluessel) } }
    var querformatFest: Bool { didSet { merken(querformatFest, "querformatFest") } }
    var fortschrittAufKacheln: Bool { didSet { merken(fortschrittAufKacheln, "fortschritt") } }

    /// Leer heißt: nehmen, was der Server vorgibt.
    var tonSprache: String { didSet { merken(tonSprache, "tonSprache") } }
    var untertitelSprache: String { didSet { merken(untertitelSprache, "utSprache") } }
    /// Untertitel nur einschalten, wenn der Ton nicht in der gewünschten
    /// Sprache läuft.
    var untertitelAutomatisch: Bool { didSet { merken(untertitelAutomatisch, "utAuto") } }
    /// Ob am Ende von selbst weitergeschaltet wird. Regel in `Weiterschalten`:
    /// eigene Wahl vor Konto-Einstellung vor „an".
    var naechsteAutomatisch: Bool {
        get { Weiterschalten.gilt(eigeneWahl: naechsteAutomatischGewaehlt, konto: naechsteAutomatischKonto) }
        set { naechsteAutomatischGewaehlt = newValue }
    }
    /// Nur gesetzt, wenn jemand den Schalter in Swiftly umgelegt hat.
    private var naechsteAutomatischGewaehlt: Bool? {
        didSet { if let naechsteAutomatischGewaehlt { merken(naechsteAutomatischGewaehlt, "naechsteAuto") } }
    }
    /// `EnableNextEpisodeAutoPlay` des Kontos. Nicht gespeichert: sie kommt
    /// bei jedem Start frisch, und ein anderes Konto hat eine andere.
    private var naechsteAutomatischKonto: Bool?
    /// Steht auf `true`, sobald nach einem fertig geschauten Titel die Frage
    /// nach einer Bewertung dran ist. Die Wurzel fragt und setzt zurück.
    var bewertungFaellig = false
    /// Dasselbe für den einmaligen Hinweis auf den Discord (`Gemeinschaft`).
    var discordHinweisFaellig = false
    /// Ob gerade ein Player offen ist. **Beide Anstöße warten darauf**: der
    /// Wechsel zur nächsten Folge zählt einen Titel, während der Player
    /// weiterläuft — und eine Frage über dem Bild wäre das Schlechteste.
    var playerOffen = false

    /// „Zuletzt hinzugefügt" getrennt nach Filmen und Serien.
    ///
    /// **Vorgabe aus, damit sich für niemanden etwas ändert.** Eine Reihe mit
    /// allem ist der Stand seit der ersten Fassung; wer sie getrennt will,
    /// schaltet um. Ausdrücklich `false` beim ersten Start — `UserDefaults`
    /// gibt für einen unbekannten Schlüssel ohnehin `false`, aber das hier
    /// steht als Absicht da, nicht als Zufall.
    var neuzugangGetrennt: Bool { didSet { merken(neuzugangGetrennt, "neuGetrennt") } }

    // MARK: Startseite nach Wunsch

    /// Reihenfolge der festen Reihen. Wer eine ausblendet, behält ihren Platz.
    ///
    /// **Doppelte werden hier abgefangen, nicht in den drei Ansichten.**
    /// Umsortiert wird an drei Stellen — `DarstellungView` auf iOS, dieselbe
    /// Datei unter `macOS`, `ProfilView` auf tvOS — und jede schreibt die ganze
    /// Liste zurück. Eine Prüfung je Ansicht wäre dreimal dieselbe Zeile, und
    /// die vierte Ansicht hätte sie wieder nicht. Die Regel liegt im Paket
    /// (`Startreihenfolge.sauber`), die Stelle, die sie durchsetzt, hier.
    ///
    /// Die zweite Zuweisung lässt `didSet` noch einmal laufen; dann ist die
    /// Liste schon sauber und es wird gemerkt. Mehr als diesen einen Umlauf
    /// kann es nicht geben — `sauber` ist auf sich selbst angewandt dasselbe.
    var startReihen: [Startreihe] {
        didSet {
            let sauber = Startreihenfolge.sauber(startReihen)
            guard sauber == startReihen else {
                let vorher = startReihen.map(\.rawValue).joined(separator: ",")
                let nachher = sauber.map(\.rawValue).joined(separator: ",")
                Self.log.error("Startreihen doppelt — \(vorher, privacy: .public) wird zu \(nachher, privacy: .public)")
                startReihen = sauber
                return
            }
            merken(startReihen.map(\.rawValue), "startReihen")
        }
    }
    var startAus: Set<Startreihe> { didSet { merken(startAus.map(\.rawValue), "startAus") } }
    /// **Genres entweder als Chips oder als Reihen**, nie beides: an heißt
    /// eine Reihe Chips unter dem Kopf, aus heißt die gewählten Genres als
    /// eigene Reihen. Von Haus aus aus und ohne Genres — die Startseite
    /// bleibt, wie sie war, bis jemand etwas will.
    var genreChips: Bool { didSet { merken(genreChips, "genreChips") } }
    var startGenres: [String] { didSet { merken(startGenres, "startGenres") } }
    /// Wie viel Vorrat der Player haelt. Siehe ``Pufferstufe`` im Paket.
    var pufferstufe: Pufferstufe { didSet { merken(pufferstufe.rawValue, "pufferstufe") } }
    /// **Zeigt Discord, was gerade laeuft — und ist aus, bis man es
    /// einschaltet.**
    ///
    /// Es ist die einzige Einstellung dieser App, die etwas nach **draussen**
    /// gibt: wer sie anlegt, sagt jedem in seinen Discord-Servern, welchen
    /// Film er gerade sieht. Eine Vorgabe „an" waere hier kein Komfort,
    /// sondern eine Veroeffentlichung, um die niemand gebeten hat — genau
    /// dieselbe Ueberlegung wie bei H1 und bei Seerr, nur mit mehr Gewicht.
    var discordAnzeigen: Bool { didSet {
        merken(discordAnzeigen, "discordAnzeigen")
        // Wer ausschaltet, will sofort weg sein, nicht beim naechsten Wechsel.
        if !discordAnzeigen { Discordanzeiger.geteilt.abraeumen() }
    } }
    var zurueckSekunden: Int { didSet { merken(zurueckSekunden, "zurueckSek") } }
    var vorSekunden: Int { didSet { merken(vorSekunden, "vorSek") } }

    /// **H1 — aus, bis man es einschaltet.**
    ///
    /// Ohne diesen Schalter gibt es weder den Reiter unten noch das Feld auf
    /// der Detailseite noch die Ringe in der Folgenliste. Wie bei Seerr: wer
    /// es nicht will, sieht ausser der einen Zeile in den Einstellungen
    /// nichts davon.
    var downloadsAn: Bool {
        didSet {
            merken(downloadsAn, "downloadsAn")
            // Ein ausgeschalteter Download laedt nicht weiter. Was auf der
            // Platte liegt, bleibt liegen — H10 fragt beim Ausschalten, was
            // damit geschehen soll, und diese Zeile haelt nur an.
            if downloadsAn {
                downloads.netzBeobachten()
            } else {
                downloads.allesAnhalten()
                // Der Pfadbeobachter kostet nichts Nennenswertes, laeuft aber
                // auch fuer nichts, solange die Funktion aus ist.
                downloads.netzNichtMehrBeobachten()
            }
        }
    }
    /// `Policy.EnableContentDownloading` des Kontos, als ``Downloadrecht``.
    /// Nicht gespeichert: kommt bei jedem Start frisch, und ein anderes Konto
    /// hat ein anderes Recht.
    private(set) var downloadrecht: Downloadrecht = .unbekannt
    /// Darf der Server für dieses Konto Video umwandeln? Sonst bietet der
    /// Player keine Bitratengrenze an — sie bliebe ohne Wirkung.
    private(set) var umwandelnErlaubt = true

    /// **Ob ein Ladeknopf ueberhaupt erscheint** — der Schalter oben *und*
    /// das Recht am Konto, entschieden im Paket.
    ///
    /// Nicht `downloadsAn` an den Knopfstellen: der Reiter unten und die
    /// Zeile in den Einstellungen haengen weiter am Schalter allein, sonst
    /// kaeme jemand, der das Recht heute verliert, nicht mehr an die Dateien,
    /// die er gestern geladen hat — auch nicht, um sie zu loeschen.
    var downloadKnopfZeigen: Bool {
        Downloadrecht.anbieten(recht: downloadrecht, funktionAn: downloadsAn)
    }

    /// **H5.** An bei der ersten Aktivierung — bei Originaldateien ist alles
    /// andere unfreundlich.
    var nurUeberWLAN: Bool {
        didSet {
            merken(nurUeberWLAN, "nurUeberWLAN")
            downloads.nurUeberWLAN = nurUeberWLAN
        if downloadsAn { downloads.netzBeobachten() }
        }
    }


    /// Anhang für Einstellungen, die je Server gelten. Ohne Sitzung leer —
    /// dann gilt der alte, gerätweite Wert.
    private var serverSchluessel: String {
        session.map { "|" + $0.serverURL.absoluteString } ?? ""
    }

    /// Direct Play und Bitratengrenze des aktuellen Servers. Hat er noch
    /// keine eigenen, gilt die bisherige gerätweite Wahl.
    private func wiedergabeLaden() {
        let ablage = UserDefaults.standard
        let k = serverSchluessel
        immerDirectPlay = ablage.object(forKey: "immerDirectPlay" + k) as? Bool
            ?? ablage.object(forKey: "immerDirectPlay") as? Bool ?? true
        bitratenGrenze = ablage.object(forKey: "bitratenGrenze" + k) as? Int
            ?? ablage.integer(forKey: "bitratenGrenze")
    }

    private func merken(_ wert: Any, _ name: String) {
        UserDefaults.standard.set(wert, forKey: name)
    }

    // MARK: - Mehrere Bibliotheken derselben Gattung

    /// Alle Bibliotheken einer Gattung, in der Reihenfolge des Servers.
    ///
    /// **Ein Server kann mehrere Filmbibliotheken haben** — aus dem
    /// TestFlight: eine auf einer externen Platte, eine lokale. Der Reiter
    /// „Filme" nahm bis dahin `views.first` und zeigte damit nur die erste;
    /// die zweite war in der App nicht erreichbar. Aufgefallen ist es nie,
    /// weil unser Prüfserver genau eine hat.
    ///
    /// Suche, „Weiterschauen" und „Zuletzt hinzugefügt" gehen ohne
    /// `ParentId` an den Server und sahen deshalb immer alles — nur das
    /// Durchblättern war halbiert.
    func bibliotheken(art: String) -> [Item] {
        views.filter { $0.collectionType == art }
    }

    /// Welche Bibliothek zuletzt gewählt war — je Gattung gemerkt.
    ///
    /// Über die Kennung und nicht über den Platz in der Liste: der Server
    /// darf umsortieren, und dann zeigte „Filme" plötzlich die andere
    /// Sammlung. Ist die gemerkte Bibliothek verschwunden, fällt die Wahl
    /// still auf die erste zurück.
    func gewaehlteBibliothek(art: String) -> Item? {
        let vorhanden = bibliotheken(art: art)
        if let kennung = UserDefaults.standard.string(forKey: Self.bibliotheksname(art)),
           let treffer = vorhanden.first(where: { $0.id == kennung }) {
            return treffer
        }
        return vorhanden.first
    }

    func bibliothekWaehlen(_ bibliothek: Item, art: String) {
        merken(bibliothek.id, Self.bibliotheksname(art))
    }

    private static func bibliotheksname(_ art: String) -> String { "bibliothek-\(art)" }


    // MARK: - Titelmenü: Alle, Sammlungen, Bibliotheken

    /// Die Sammlungen des Kontos — `nil`, solange nicht gefragt.
    private(set) var sammlungsverzeichnis: Sammlungsverzeichnis?
    /// Filme und Serien je gemischter Bibliothek.
    private(set) var bibliotheksanteile: [String: Bibliotheksanteil] = [:]
    /// Für welches Konto und welche Bibliotheken beides gilt.
    private var angebotFuer: String?
    private var angebotLaeuft: String?

    private var angebotsschluessel: String {
        "\(kontowechsel)|" + views.map(\.id).joined(separator: ",")
    }

    /// Was der Titel dieses Bereichs zur Wahl anbietet — die Regel steht im
    /// Paket (``Bereichsangebot``).
    ///
    /// **Was einem anderen Konto gehört, zählt nicht.** Bis das neue
    /// geladen ist, steht nur da, was `views` allein hergibt.
    func bereichsangebot(art: String) -> Bereichsangebot {
        let gilt = angebotFuer == angebotsschluessel
        return Bereichsangebot.bilden(art: art, views: views,
                                      anteile: gilt ? bibliotheksanteile : [:],
                                      verzeichnis: gilt ? sammlungsverzeichnis : nil)
    }

    /// Holt Sammlungen und Anteile gemischter Bibliotheken.
    ///
    /// **Nur auf Zuruf**, nicht in `loadViews`: gefragt wird erst, wenn eine
    /// Seite es braucht.
    ///
    /// **Nicht nur einmal je Konto.** Die erste Fassung merkte sich das
    /// Ergebnis, bis sich Konto oder Bibliotheken änderten; wer auf dem
    /// Server eine Sammlung anlegte, sah sie erst nach einem Neustart der
    /// App. Jetzt gilt ein Stand eine Minute — öffnet man danach Filme oder
    /// Serien wieder, wird nachgesehen.
    func angebotLaden() async {
        guard let client, !views.isEmpty else { return }
        let fuer = angebotsschluessel
        let frisch = angebotZeit.map { Date().timeIntervalSince($0) < 60 } ?? false
        guard angebotFuer != fuer || !frisch, angebotLaeuft != fuer else { return }
        angebotLaeuft = fuer
        defer { if angebotLaeuft == fuer { angebotLaeuft = nil } }
        let stand = views
        async let anteile = client.bibliotheksanteile(views: stand)
        async let verzeichnis: Sammlungsverzeichnis? = {
            let mitVerborgenen = (try? await client.userViews(verborgene: true)) ?? stand
            if Sammlungsverzeichnis.ausgeblendet(sichtbar: stand, mitVerborgenen: mitVerborgenen) {
                return .leer
            }
            return try? await client.sammlungsverzeichnis(ansichten: mitVerborgenen)
        }()
        let neueAnteile = await anteile
        let neuesVerzeichnis = await verzeichnis
        // Inzwischen das Konto gewechselt: das Ergebnis gehört niemandem mehr.
        guard fuer == angebotsschluessel else { return }
        bibliotheksanteile = neueAnteile
        // **Gescheitert ist nicht leer.** Ohne Antwort bleibt der Stand
        // ungültig, und die nächste Seite fragt noch einmal.
        guard let neuesVerzeichnis else { return }
        sammlungsverzeichnis = neuesVerzeichnis
        angebotFuer = fuer
        angebotZeit = Date()
    }
    private var angebotZeit: Date?

    /// Die Kennungen der Bibliotheken, aus denen „Alle" liest — für das
    /// Sieb, mit denselben Filtern wie die Seite.
    func titelsieb(_ quelle: Regalquelle, filter: Bibliotheksfilter) async -> Titelsieb? {
        guard let client else { return nil }
        let typen = quelle.typen
        do {
            let listen = try await withThrowingTaskGroup(of: [Item].self) { gruppe in
                for id in quelle.nurAus {
                    gruppe.addTask {
                        try await client.titelkennungen(parentID: id, typen: typen,
                                                        filters: filter.jellyfinFilter,
                                                        istGesehen: filter.istGesehen)
                    }
                }
                var alle: [Item] = []
                for try await liste in gruppe { alle += liste }
                return alle
            }
            return Titelsieb(kennungen: listen)
        } catch {
            if !Task.isCancelled { errorMessage = lesbar(error) }
            return nil
        }
    }

    /// Die Sammlungen, zu denen ein Titel gehört — aus dem Verzeichnis, nur
    /// wenn es zu diesem Konto gehört.
    func sammlungen(mit titel: Item) -> [Sammlung] {
        guard angebotFuer == angebotsschluessel else { return [] }
        return sammlungsverzeichnis?.sammlungen(mit: titel) ?? []
    }

    /// Die Plakate der ersten Titel je Sammlung — einmal geholt, dann aus dem
    /// Speicher: das Mosaik fragt bei jedem Erscheinen neu, und jedes Mal
    /// dieselbe Abfrage wäre Verschwendung. Wie Android (`Mosaikspeicher` in
    /// `SammlungSeite.kt`). Geleert beim Kontowechsel, in `nachDemWechsel()`.
    private var sammlungstitelSpeicher: [String: [Item]] = [:]

    /// Die Titel einer Sammlung für die Reihe auf der Detailseite.
    ///
    /// **Still, ohne `errorMessage`.** Die Reihe ist eine Zugabe; scheitert
    /// sie, fehlt sie — eine Fehlermeldung über der ganzen Seite wäre für
    /// eine Reihe, nach der niemand gefragt hat, zu laut.
    func sammlungstitel(_ sammlung: Sammlung, art: String) async -> [Item]? {
        let schluessel = sammlung.id + "|" + art
        if let gespeichert = sammlungstitelSpeicher[schluessel] { return gespeichert }
        guard let client else { return nil }
        let quelle = Regalquelle(eltern: sammlung.id, art: art, sammlung: true)
        guard let gefunden = try? await client.items(parentID: quelle.eltern, limit: 100,
                                       sortBy: Sortierung.erscheinung.feld,
                                       sortOrder: quelle.richtung(.erscheinung),
                                       recursive: quelle.rekursiv,
                                       includeItemTypes: quelle.typen).items else { return nil }
        sammlungstitelSpeicher[schluessel] = gefunden
        return gefunden
    }

    /// Die gemerkte Wahl dieses Bereichs, geprüft gegen das Angebot.
    func bereichswahl(art: String) -> Bereichswahl {
        bereichsangebot(art: art)
            .wahl(gemerkt: UserDefaults.standard.string(forKey: Self.bibliotheksname(art)))
    }

    func bereichWaehlen(_ wahl: Bereichswahl, art: String) {
        merken(wahl.merkwert, Self.bibliotheksname(art))
    }

    /// Was dem Server als Grenze gemeldet wird — die Rechnung liegt im Paket
    /// (``Bitratengrenze``), weil Linux dieselbe Antwort geben muss und sie
    /// dort wortgleich ein zweites Mal stand.
    private var profilBitrate: Int {
        Bitratengrenze.fuer(immerDirectPlay: immerDirectPlay, megabit: bitratenGrenze)
    }
    var serverVersion: String?
    var isWorking = false

    /// **Ein Haken, und zwar hier.**
    ///
    /// `client` wird an fuenf Stellen gesetzt — beim Verbinden, beim
    /// Anmelden, beim Kontowechsel, beim Wiederherstellen und beim
    /// Abmelden —, und die Downloads muessen an allen fuenfen mitgehen.
    /// Fuenf Aufrufe an fuenf Stellen sind vier Gelegenheiten, einen zu
    /// vergessen; genau so ist die Fernsteuerung beim Kontowechsel
    /// haengengeblieben. `session` steht dabei schon richtig: `bund` wird
    /// auf jedem der fuenf Wege vor `client` gesetzt.
    private(set) var client: JellyfinClient? {
        didSet { downloads.anmelden(client: client, konto: session?.userID) }
    }
    private(set) var session: Session? { didSet { if session?.serverURL != oldValue?.serverURL { wiedergabeLaden() } } }

    /// Alle Konten auf diesem Server, in der Reihenfolge des Streifens über
    /// der Profilseite. Leer, solange niemand angemeldet ist.
    /// Die Anbindung an Seerr. **Liegt hier, weil sie eine Sitzung hält** —
    /// eine Ansicht, die sie besitzt, verliert sie beim Schliessen, und ein
    /// zweites Modell daneben hätte einen zweiten Zugang.
    let seerr = Seerrmodell()
    /// Trakt — liegt hier aus demselben Grund wie `seerr`, und weil die
    /// Meldungen an Trakt neben denen an Jellyfin entstehen (`reportStart`
    /// und folgende).
    let trakt = Traktkonto()

    /// Was auf dem Geraet liegt. **Liegt hier aus demselben Grund wie
    /// `seerr`:** sie haelt eine Hintergrundsitzung, und eine Ansicht, die
    /// sie besaesse, verloere sie beim Schliessen — mitten im Download.
    let downloads = Downloadverwaltung()

    private(set) var konten: [Session] = []

    /// Zählt jeden Kontowechsel. Ansichten hängen sich daran, um neu zu laden.
    ///
    /// **Warum ein Zähler und nicht `phase`.** Beim ersten Anmelden springt
    /// die Phase von `disconnected` auf `ready`, und daran hängt die
    /// Startseite. Beim Wechsel zwischen zwei Konten bleibt sie auf `ready`
    /// stehen — es passiert also nichts, und auf dem Schirm steht weiter das
    /// vorige Konto.
    private(set) var kontowechsel = 0

    /// **Zählt jede beendete Wiedergabe — erst, wenn der Server sie kennt.**
    ///
    /// Am 16.09.2026 gemeldet: aus einer Folge nach sechs, sieben Minuten
    /// raus, und die Serienseite zeigte sie weiter als ungesehen. Gemessen am
    /// Simulator gegen den Testserver: die Endmeldung kam an, der Server
    /// führte die Stelle auf die Sekunde (399 s gemeldet, 399 s gespeichert).
    /// Falsch war nur die Seite darunter — sie hatte ihren Stand **vor** der
    /// Wiedergabe geholt und nie wieder: der Player liegt auf tvOS und macOS
    /// als Ebene über der stehenbleibenden Seite, `.task` läuft nicht neu.
    ///
    /// Gezählt wird nach der Endmeldung und nicht beim Schließen des
    /// Players: wer beim Schließen neu lädt, fragt, bevor die Meldung
    /// angekommen ist, und bekommt den Stand des letzten Takts — bis zu zehn
    /// Sekunden zu früh. Seiten mit Fortschritt hängen ihr Auffrischen hier an.
    private(set) var wiedergabeBeendet = 0
    /// Ein Sehstand wurde von Hand geaendert (Folge, Staffel, Serie).
    private(set) var sehstandGeaendert = 0
    /// **Worauf Seiten mit Sehstand hoeren.** Beides aendert, was dort steht:
    /// eine zu Ende geschaute Folge und ein Haken von Hand. Vorher hoerten
    /// sie nur auf das Erste — wer eine ganze Serie abhakte, sah die Folgen
    /// darunter weiter offen, bis er die Seite neu oeffnete (Paul, 18.09.2026).
    var seitenAuffrischen: Int { wiedergabeBeendet + sehstandGeaendert }

    /// **Die Quelle der Wahrheit dafür, wer angemeldet ist.**
    ///
    /// `session` bleibt daneben stehen, weil die halbe App sie liest; sie
    /// wird von hier aus nachgezogen und nirgends sonst gesetzt. Zwei
    /// Stellen, die dasselbe behaupten dürfen, laufen sonst auseinander —
    /// bei `trefferauskunft` ist genau das passiert.
    private var bund: Kontenbund? {
        didSet {
            konten = bund?.konten ?? []
            session = bund?.aktives
            // Seerr hängt an einem Server — beim Wechsel auf einen anderen
            // gilt dessen Zugang. Innerhalb eines Servers ändert sich nichts.
            seerr.serverGewechselt(bund?.aktives.serverURL)
            // Trakt haengt am Konto, nicht am Server (`Traktkonto`).
            trakt.kontoGewechselt(bund?.aktives.kontoschluessel)
            profilbilderVorholen()
        }
    }

    /// **Die Bilder der anderen Konten, bevor jemand danach fragt.**
    ///
    /// Die Adresse steht sofort da — sie wird aus Serveradresse, Kennung und
    /// Zugang gebaut, ohne Netzweg. Das **Bild** dagegen wurde erst geholt,
    /// wenn das Profilzeichen zum ersten Mal auf dem Schirm stand: beim
    /// ersten Oeffnen des Profils sah man deshalb kurz den Buchstaben und
    /// danach das Bild. Paul am 22.09.: „beim ersten Oeffnen tauchen die
    /// anderen Profilbilder erst spaeter auf."
    ///
    /// Es sind hoechstens eine Handvoll kleiner Bilder, und sie stehen fest,
    /// sobald der Bund steht. Wer sie dann holt, hat sie, wenn sie gebraucht
    /// werden. Ohne Vorrang: das laufende Plakat geht vor.
    private func profilbilderVorholen() {
        let adressen = konten.compactMap { benutzerbildURL(fuer: $0) }
        guard !adressen.isEmpty else { return }
        Task.detached(priority: .background) {
            for adresse in adressen {
                _ = await Bildspeicher.geteilt.laden(adresse, aufGeraet: true)
            }
        }
    }

    /// Die Server im Bund, in der Reihenfolge ihres ersten Kontos.
    var server: [URL] { bund?.server ?? [] }
    func konten(auf server: URL) -> [Session] { bund?.konten(auf: server) ?? [] }

    private static let sessionKey = "session"
    /// Der Schlüssel für den ganzen Bund. Der alte oben bleibt liegen: wer
    /// noch einmal eine ältere Fassung startet, findet dort seine Sitzung.
    private static let kontenKey = "konten"
    static let log = Logger(subsystem: "de.paulherter.swiftly", category: "start")

    /// Stabile Geräte-ID. Jellyfin listet damit die Sitzung im Dashboard.
    /// **Nicht mehr `private`.** `Uebernahmemodell` muss die eigene Kennung
    /// kennen, sonst zeigt das Gerät sich selbst als „läuft woanders" an —
    /// und das fällt erst auf, wenn nur ein Gerät läuft.
    static var deviceID: String = {
        let key = "de.paulherter.swiftly.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    private static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        "Mac"
        #endif
    }

    init() {
        let ablage = UserDefaults.standard
        // `object(forKey:)` unterscheidet „nie gesetzt" von „aus" — mit
        // `bool(forKey:)` wäre die Vorgabe immer falsch.
        immerDirectPlay = ablage.object(forKey: "immerDirectPlay") as? Bool ?? true
        bitratenGrenze = ablage.integer(forKey: "bitratenGrenze")
        querformatFest = ablage.object(forKey: "querformatFest") as? Bool ?? true
        fortschrittAufKacheln = ablage.object(forKey: "fortschritt") as? Bool ?? true
        tonSprache = ablage.string(forKey: "tonSprache") ?? ""
        untertitelSprache = ablage.string(forKey: "utSprache") ?? ""
        untertitelAutomatisch = ablage.object(forKey: "utAuto") as? Bool ?? false
        // **Nie gesetzt heißt nicht „an".** Dann gilt die Einstellung des
        // Jellyfin-Kontos (T3 #15); wer den Schalter umgelegt hat, behält ihn.
        naechsteAutomatischGewaehlt = ablage.object(forKey: "naechsteAuto") as? Bool
        // **Getrennt ist die Vorgabe**, seit dem 11.09.2026. Wer es ausdrücklich
        // ausgeschaltet hat, behält das; wer es nie angefasst hat, bekommt die
        // beiden Reihen.
        neuzugangGetrennt = ablage.object(forKey: "neuGetrennt") as? Bool ?? true
        // **Die Rechnung liegt im Paket** (`Startreihenfolge.geltend`): eine
        // Reihe, die es beim Merken noch nicht gab, kommt hinten dazu, und was
        // doppelt in der Ablage steht, kommt einmal heraus. Hier stand eine
        // zweite Fassung derselben Rechnung — und die kannte nur die erste
        // Hälfte. Ein Gerät, auf dem „neueFilme" zweimal abgelegt war, trug den
        // Fehler damit über jeden Start hinweg.
        let abgelegteReihen = ablage.stringArray(forKey: "startReihen") ?? []
        let geltendeReihen = Startreihenfolge.geltend(abgelegt: abgelegteReihen)
        if !abgelegteReihen.isEmpty, geltendeReihen.map(\.rawValue) != abgelegteReihen {
            let vorher = abgelegteReihen.joined(separator: ",")
            let nachher = geltendeReihen.map(\.rawValue).joined(separator: ",")
            Self.log.info("Startreihen glattgezogen: abgelegt \(vorher, privacy: .public) → \(nachher, privacy: .public)")
        }
        startReihen = geltendeReihen
        startAus = Set((ablage.stringArray(forKey: "startAus") ?? []).compactMap(Startreihe.init(rawValue:)))
        genreChips = ablage.object(forKey: "genreChips") as? Bool ?? false
        startGenres = ablage.stringArray(forKey: "startGenres") ?? []
        pufferstufe = (ablage.string(forKey: "pufferstufe")
                       .flatMap(Pufferstufe.init(rawValue:))) ?? .normal
        discordAnzeigen = ablage.object(forKey: "discordAnzeigen") as? Bool ?? false
        zurueckSekunden = ablage.object(forKey: "zurueckSek") as? Int ?? 10
        vorSekunden = ablage.object(forKey: "vorSek") as? Int ?? 30
        downloadsAn = ablage.object(forKey: "downloadsAn") as? Bool ?? false
        nurUeberWLAN = ablage.object(forKey: "nurUeberWLAN") as? Bool ?? true

        // `didSet` laeuft waehrend `init` nicht — der Schalter muss einmal
        // von Hand durchgereicht werden, sonst laedt die Verwaltung beim
        // ersten Start ueber Mobilfunk, obwohl die Vorgabe das verbietet.
        downloads.nurUeberWLAN = nurUeberWLAN

        // **Das Paket bekommt einen Faden nach draussen.**
        //
        // `Protokoll` liegt hier in der App, weil es in eine Datei im
        // App-Behaelter schreibt; das Paket kennt es nicht. Die stillsten
        // Stellen der ganzen App stecken aber genau dort — eine
        // Steckverbindung, die nicht zustande kommt, eine Antwort, die
        // niemand ansieht. Am 10.09.2026 hat das eine halbe Nacht gekostet.
        Spur.schreiben = { Protokoll.schreib($0) }
        Stromweiterleiter.protokoll = { Protokoll.schreib($0) }

        Self.keychainSelbsttest()
        // **Vor der Sitzung.** Hinter einem Vorposten braucht schon der erste
        // Abruf die eigenen Header — und die ersten Plakate gleich danach.
        Self.eigeneKoepfeLaden()
        restoreSession()
    }

    /// Prüft, ob der Server antwortet, und zieht dabei Name und Fassung nach.
    func verbindungPruefen() async -> String {
        guard let client else { return String(localized: "Nicht angemeldet.") }
        do {
            let info = try await client.publicSystemInfo()
            serverName = info.serverName ?? serverName
            serverVersion = info.version ?? serverVersion
            // **Hier und nicht in einem eigenen Takt.** Das ist der eine
            // Punkt, an dem nachgewiesen ist, dass der Server antwortet —
            // und die Prüfung läuft ohnehin nach jedem Verbinden, Anmelden
            // und Kontowechsel. Ein zweiter Wecker daneben würde raten.
            await nachmeldungenAbschicken()
            return String(localized: "Erreichbar — Jellyfin \(info.version ?? "?")")
        } catch {
            return lesbar(error)
        }
    }

    /// Schreibt und liest beim Start einen Testwert. Schlägt das fehl, geht
    /// auch die Sitzung verloren — dann steht der Grund im Log statt dass man
    /// sich wundert, warum man sich ständig neu anmelden muss.
    private static func keychainSelbsttest() {
        // Bleibt bewusst liegen: so lässt sich messen, ob Einträge eine
        // Neuinstallation überleben — genau das ist die Frage.
        if let alt = Keychain.load(key: "dauertest"),
           let text = String(data: alt, encoding: .utf8) {
            Self.log.info("Keychain: Eintrag überlebt seit \(text, privacy: .public)")
        } else {
            let stempel = ISO8601DateFormatter().string(from: Date())
            do {
                try Keychain.save(Data(stempel.utf8), key: "dauertest")
                Self.log.info("Keychain: kein alter Eintrag, neu angelegt um \(stempel, privacy: .public)")
            } catch {
                Self.log.error("Keychain: Schreiben fehlgeschlagen — \(String(describing: error), privacy: .public)")
            }
        }
        Self.log.info("Keychain: Sitzung vorhanden = \(Keychain.load(key: sessionKey) != nil, privacy: .public)")
    }

    // MARK: - Verbinden

    /// `koepfe` kommen aus „Erweitert" auf der Anmeldeseite — leer für fast
    /// alle, und dann bleibt, was für diese Adresse schon eingetragen ist.
    func connect(to raw: String, koepfe: [Eigenkopf] = []) async {
        errorMessage = nil
        phase = .connecting

        guard let url = Self.normalizeServerURL(raw) else {
            errorMessage = String(localized: "Die Adresse konnte nicht gelesen werden.")
            phase = .disconnected
            return
        }

        // Erst wie geraten, dann andersherum.
        //
        // Ohne Schema wird für Adressen außerhalb des Heimnetzes `https`
        // angenommen. Läuft dort ein Server ohne Zertifikat, scheitert der
        // erste Versuch an der Verbindung — nicht an einer Antwort. Genau
        // dann, und nur dann, ist ein zweiter Versuch über `http` sinnvoll.
        // Bei einer Antwort mit Fehlercode wäre er falsch: der Server ist ja
        // da, er sagt nur etwas anderes.
        if await verbindeMit(url, koepfe: koepfe) { return }

        // Den Grund des **ersten** Versuchs festhalten.
        //
        // Sonst überschreibt der Ausweichversuch ihn mit seinem eigenen, und
        // der ist fast immer der falsche: scheitert `https` schon an der
        // Namensauflösung, scheitert `http` daran ebenso — es meldet nur
        // vorher, dass iOS unverschlüsselte Verbindungen sperrt. Der Nutzer
        // liest dann „richte https ein", obwohl der Server schlicht nicht zu
        // finden war.
        let echterGrund = errorMessage

        if raw.contains("://") == false,
           let ausweich = AppModelURLNormalizer.andersHerum(url),
           await verbindeMit(ausweich, koepfe: koepfe) { return }

        errorMessage = echterGrund
        phase = .disconnected
    }

    /// - Returns: `true`, wenn der Server geantwortet hat.
    private func verbindeMit(_ url: URL, koepfe: [Eigenkopf] = []) async -> Bool {
        let c = JellyfinClient(baseURL: url, deviceID: Self.deviceID, deviceName: Self.deviceName)
        let vorher = Eigenkoepfe.eingetragen(fuer: url)
        let neu = Eigenkoepfe.bereinigt(koepfe)
        if !neu.isEmpty { Eigenkoepfe.setzen(neu, fuer: url) }
        do {
            let info = try await c.publicSystemInfo()
            // Erst jetzt ablegen: fuer eine Adresse, unter der nichts
            // antwortet, bleibt nichts im Schluesselbund liegen.
            if !neu.isEmpty { eigeneKoepfeSichern(neu, fuer: url) }
            client = c
            serverName = info.serverName ?? url.host()
            serverVersion = info.version
            phase = .needsLogin(serverName: info.serverName ?? url.host() ?? "Server",
                                version: info.version ?? "?")
            serverMerken(adresse: url.host() ?? url.absoluteString,
                         name: info.serverName ?? url.host() ?? "Server",
                         version: info.version ?? "?")
            errorMessage = nil
            return true
        } catch {
            if !neu.isEmpty { Eigenkoepfe.setzen(vorher, fuer: url) }
            errorMessage = anschlussfehler(error, adresse: url)
            return false
        }
    }

    /// Verbindungsfehler so, dass die Ursache daraus hervorgeht.
    ///
    /// Der häufigste Fall bei selbst gehosteten Servern ist eine unver-
    /// schlüsselte Adresse außerhalb des Heimnetzes: die sperrt iOS von sich
    /// aus, und die Fehlermeldung des Systems sagt das nicht.
    /// Den Systemfehler um den Hinweis ergänzen, der ihn deutbar macht.
    ///
    /// **Der Fall, um den es hier geht, ist eine Falschmeldung des Systems.**
    /// Verweigert der Nutzer die Ortsnetz-Erlaubnis, meldet URLSession
    /// „Die Internetverbindung scheint offline zu sein" — obwohl das Netz
    /// einwandfrei läuft und nur diese eine Erlaubnis fehlt. Wer das liest,
    /// prüft sein WLAN und findet nichts. Also sagen wir es.
    ///
    /// Der frühere Hinweis („richte https ein") ist weg: seit
    /// `NSAllowsArbitraryLoads` sperrt iOS http nicht mehr, und ein Rat, der
    /// nicht mehr stimmt, ist schlechter als keiner.
    private func anschlussfehler(_ fehler: any Error, adresse: URL) -> String {
        let text = lesbar(fehler)
        let imHeimnetz = AppModelURLNormalizer.istImHeimnetz(adresse.host() ?? "")
        // Nur bei „offline", und nur im Heimnetz: draußen ist derselbe Fehler
        // schlicht ein fehlendes Netz, und dann wäre der Hinweis irreführend.
        if imHeimnetz, (fehler as? URLError)?.code == .notConnectedToInternet {
            return String(localized: "Der Server war nicht erreichbar. Hat Swiftly die Erlaubnis, Geräte im heimischen Netz zu suchen? Sie steht in den Systemeinstellungen unter „Swiftly · Lokales Netzwerk\".")
        }
        return text
    }

    /// Was nach jeder erfolgreichen Anmeldung gleich abläuft — egal ob über
    /// Passwort oder Quick Connect.
    /// Nimmt eine frische Sitzung an. Gibt zurück, ob es ein **Kontowechsel**
    /// war — dann hat diese Funktion bereits aufgeräumt und neu geladen, und
    /// der Aufrufer soll nicht noch einmal laden.
    @discardableResult
    func sitzungUebernehmen(_ s: Session) -> Bool {
        // **Die Regel steht im Paket**, nicht hier: derselbe Server heisst
        // dazunehmen und wechseln, ein anderer heisst von vorn. Beide
        // Fassungen — diese und die von GTK — hatten sie sich selbst
        // hergeleitet, und an dieser Antwort hängt das ganze Aufräumen.
        let (neuerBund, warAngemeldet) = Kontenbund.aufnehmen(s, in: bund)
        bund = neuerBund
        bundSichern()
        phase = .ready
        // **War die App schon angemeldet, ist das ein Kontowechsel.** Der
        // Client trägt nach dem Anmelden bereits das neue Merkmal; was fehlt,
        // ist alles andere. Ohne das Aufräumen bleiben Bibliotheken und
        // Startseite beim vorigen Konto stehen — und mit dem neuen Merkmal
        // abgefragt gibt der Server sie nicht heraus. Genau so kam
        // „Anmeldung abgelehnt", nachdem ein zweites Konto dazukam.
        if warAngemeldet { nachDemWechsel() }
        // Name und Fassung stehen sonst nur nach einer frischen Verbindung
        // bereit — in den Einstellungen stand danach „Server · ?".
        Task { _ = await verbindungPruefen() }
        return warAngemeldet
    }

    /// Was nach jedem Kontowechsel neu muss — außer dem Client selbst.
    private func nachDemWechsel() {
        // **Die Bibliotheken werden ersetzt, nicht erst geleert.**
        //
        // Hier stand `views = []`. Das ist derselbe Fehler, der schon die
        // Vorschaubilder gekostet hat, nur an einer anderen Stelle: zwischen
        // dem Leeren und der Antwort des Servers steht die Seitenleiste leer
        // da und baut sich danach neu auf — auf dem Schreibtisch als Zucken
        // der Bibliotheksliste, auf dem Telefon als Sprung.
        //
        // Was stehenbleibt, gehoert fuer den Bruchteil einer Sekunde noch dem
        // vorigen Konto. Das ist verschmerzbar: die Kennungen der Bibliotheken
        // gelten serverweit, und `loadViews` ersetzt sie in einem Zug, sobald
        // die Antwort da ist.
        //
        // **Der Anstoss muss von hier kommen.** `Startseitenmodell` holt die
        // Bibliotheken nur nach, wenn keine da sind — ohne das Leeren wuerde
        // es also nie nachladen, und die Liste des vorigen Kontos bliebe
        // stehen.
        Task { await loadViews() }
        errorMessage = nil
        sammlungstitelSpeicher.removeAll()
        kontowechsel += 1
        #if os(tvOS)
        Regal.leeren()
        #endif
        // **Die Fernsteuerung gehört dazu, und das sieht man ihr nicht an.**
        // Sie wird sonst nur beim Erscheinen der Hauptansicht gestartet — die
        // bleibt beim Wechsel aber stehen, und dann meldete sich das Gerät
        // weiter mit dem Merkmal des vorigen Kontos am Server.
        Task {
            await fernsteuerungBeenden()
            await fernsteuerungStarten()
        }
    }

    func login(username: String, password: String) async {
        guard let client else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            let s = try await client.authenticate(username: username, password: password)
            // **Nicht zusätzlich laden, wenn es ein Wechsel war** — gleiche
            // Begründung wie bei Quick Connect: `sitzungUebernehmen` räumt
            // dann selbst auf und stösst das Neuladen an, und ein zweiter
            // Lauf daneben liefert sich mit dem ersten ein Rennen.
            //
            // Hier fiel es länger nicht auf als dort: auf dem Fernseher, wo
            // der Profilwechsel zuerst gebaut wurde, führt „Weiteres Konto
            // hinzufügen" auf Quick Connect. Name und Passwort sind der Weg
            // auf iPhone, iPad und dem Schreibtisch — also genau dort, wo
            // gleich vier Plattformen darauf gestossen wären. Von der
            // Mac-Sitzung beim Nachlesen gefunden, nicht durch einen Fehler.
            if !sitzungUebernehmen(s) { await loadViews() }
        } catch {
            errorMessage = lesbar(error)
        }
    }

    /// Quick Connect: Code freigeben, der auf einem anderen Gerät steht.
    // MARK: - Weiterer Server

    /// Der Server, der gerade aufgenommen wird. **Die laufende Sitzung bleibt,
    /// wie sie ist**: `connect(to:)` stellt die ganze App auf den
    /// Anmeldebildschirm — wer mitten in ihr einen zweiten Server hinzufügt,
    /// soll dort nicht landen und bei einem Abbruch zurückfinden müssen. Erst
    /// wenn die Anmeldung klappt, kommt der Server in den Bund.
    @ObservationIgnored private var aufnahme: JellyfinClient?
    @ObservationIgnored private var aufnahmeName: String?

    /// Prüft eine Adresse und hält den Server bereit — Name und Fassung, oder
    /// `nil` mit dem Grund in `errorMessage`.
    func serverPruefen(_ roh: String, koepfe: [Eigenkopf] = []) async -> (name: String, fassung: String)? {
        errorMessage = nil
        guard let url = Self.normalizeServerURL(roh) else {
            errorMessage = String(localized: "Die Adresse konnte nicht gelesen werden.")
            return nil
        }
        var kandidaten = [url]
        if !roh.contains("://"), let anders = AppModelURLNormalizer.andersHerum(url) {
            kandidaten.append(anders)
        }
        let neu = Eigenkoepfe.bereinigt(koepfe)
        var letzter: (any Error)?
        for adresse in kandidaten {
            let c = JellyfinClient(baseURL: adresse, deviceID: Self.deviceID, deviceName: Self.deviceName)
            let vorher = Eigenkoepfe.eingetragen(fuer: adresse)
            if !neu.isEmpty { Eigenkoepfe.setzen(neu, fuer: adresse) }
            let info: PublicSystemInfo
            do { info = try await c.publicSystemInfo() } catch {
                letzter = error
                if !neu.isEmpty { Eigenkoepfe.setzen(vorher, fuer: adresse) }
                continue
            }
            do {
                if !neu.isEmpty { eigeneKoepfeSichern(neu, fuer: adresse) }
                aufnahme = c
                let name = info.serverName ?? adresse.host() ?? String(localized: "Server")
                aufnahmeName = name
                return (name, info.version ?? "?")
            }
        }
        // Eine Anmeldeseite davor ist kein fehlendes Jellyfin — der Satz
        // dazu sagt, was zu tun ist.
        if let j = letzter as? JellyfinError, case let .transport(text) = j,
           text == Eigenkoepfe.anmeldeseiteText {
            errorMessage = text
            return nil
        }
        errorMessage = String(localized: "Unter dieser Adresse antwortet kein Jellyfin.")
        return nil
    }

    /// Meldet am bereitgehaltenen Server an und nimmt ihn in den Bund. Die App
    /// wechselt dorthin — wie beim Wechsel auf ein anderes Konto.
    func anmeldenAmNeuenServer(benutzer: String, passwort: String) async -> Bool {
        guard let aufnahme else { return false }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            serverAufnehmen(try await aufnahme.authenticate(username: benutzer, password: passwort))
            return true
        } catch {
            errorMessage = lesbar(error)
            return false
        }
    }

    // **Quick Connect am neuen Server** — derselbe Ablauf wie beim ersten
    // Anmelden (`QuickConnectModell`), nur mit dem bereitgehaltenen Server
    // statt dem, mit dem die App gerade verbunden ist.

    func quickConnectStartenAmNeuenServer() async throws -> Anmeldecode {
        guard let aufnahme else { throw JellyfinError.notAuthenticated }
        return try await aufnahme.quickConnectStarten()
    }

    func quickConnectNachfragenAmNeuenServer(_ vorgang: Anmeldecode) async -> Quickconnectstand {
        guard let aufnahme else { return .gescheitert }
        return await aufnahme.quickConnectNachfragen(vorgang)
    }

    func anmeldenMitQuickConnectAmNeuenServer(_ vorgang: Anmeldecode) async -> Bool {
        guard let aufnahme else { return false }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            serverAufnehmen(try await aufnahme.anmeldenMitQuickConnect(vorgang))
            return true
        } catch {
            errorMessage = lesbar(error)
            return false
        }
    }

    /// Der eine Abschluss für beide Wege: in den Bund, sichern, hinwechseln.
    private func serverAufnehmen(_ s: Session) {
        bund = Kontenbund.aufnehmen(s, in: bund).bund
        bundSichern()
        aufnahme = nil
        neuVerbinden()
        if let aufnahmeName { serverName = aufnahmeName }
    }

    func serverAufnahmeAbbrechen() {
        aufnahme = nil
        aufnahmeName = nil
        errorMessage = nil
    }

    func quickConnectFreigeben(code: String) async throws {
        guard let client else { throw JellyfinError.notAuthenticated }
        try await client.quickConnectFreigeben(code: code)
    }

    // MARK: Fernsteuerung

    /// Die offene Socket-Verbindung, über die Befehle vom Server kommen.
    @ObservationIgnored private var fern: Fernsteuerung?
    /// Setzt der Player, solange er auf dem Schirm ist.
    @ObservationIgnored var fernbefehl: ((Fernbefehl) -> Void)?

    /// Fähigkeiten melden und zuhören.
    ///
    /// Beides ist nötig, damit das Dashboard die Sitzung bedienen kann: ohne
    /// die Meldung bleiben dort die Knöpfe grau, ohne den Socket kommen die
    /// Befehle nie an.
    func fernsteuerungStarten() async {
        guard let client, fern == nil else { return }
        do {
            try await client.faehigkeitenMelden()
        } catch {
            Protokoll.schreib("[Uebernahme] Faehigkeiten nicht gemeldet: \(error)")
            Self.log.warning("Fähigkeiten nicht gemeldet: \(error.localizedDescription)")
        }
        guard let steuerung = try? await client.fernsteuerung() else { return }
        fern = steuerung
        await steuerung.starten { [weak self] befehl in
            Task { @MainActor in
                // Gemeldet wird, was der Befehl ausloest: Pause und Weiter
                // ueber `laufzustandGemeldet`, Spruenge ueber
                // `sprungGemeldet`. Frueher stand hier eine eigene Meldung
                // nach 400 ms aus `Spielstand` — die ging nach einem
                // Folgenwechsel mit der neuen Stelle an die alte Folge (T1-M9).
                self?.fernbefehl?(befehl)
            }
        }
    }

    func fernsteuerungBeenden() async {
        await fern?.beenden()
        fern = nil
    }

    func loadViews() async {
        guard let client else { return }
        isWorking = true
        defer { isWorking = false }
        // Nebenher und ohne Fehlermeldung: kommt nichts, bleibt es wie es war.
        Task {
            let vorgaben = await client.kontovorgaben()
            naechsteAutomatischKonto = vorgaben?.naechsteFolgeAutomatisch
            // Ohne Antwort `.unbekannt`, also erlaubt: ein Netzfehler nimmt
            // niemandem etwas weg. Den harten Riegel haelt ohnehin
            // `JellyfinClient.downloadURL`, und der merkt sich den letzten
            // bekannten Stand.
            downloadrecht = vorgaben?.downloadrecht ?? .unbekannt
            // Ohne Antwort: erlaubt — dann bleibt die Qualitätswahl im Player.
            umwandelnErlaubt = vorgaben?.umwandelnErlaubt ?? true
            Protokoll.schreib("[Konto] Nächste Folge automatisch: \(String(describing: naechsteAutomatischKonto)), Downloads: \(downloadrecht.rawValue)")
        }
        do {
            views = try await client.userViews()
        } catch {
            errorMessage = lesbar(error)
        }
    }

    /// Einen Titel frisch holen — vor allem wegen der Wiedergabeposition.
    func item(id: String) async -> Item? {
        guard let client else { return nil }
        return try? await client.item(id: id)
    }

    /// Der erste Trailer, der als Datei auf dem Server liegt.
    func trailer(zu item: Item) async -> Item? {
        guard let client else { return nil }
        return (try? await client.trailer(zu: item.id))?.first
    }

    /// Stösst das Neueinlesen der Metadaten an. Der Server arbeitet danach im
    /// Hintergrund weiter — die Antwort heisst nur „angenommen".
    func metadatenAuffrischen(_ item: Item) async -> String {
        guard let client else { return String(localized: "Nicht angemeldet.") }
        do {
            try await client.metadatenAuffrischen(item.id)
            return String(localized: "Der Server liest die Metadaten neu ein.")
        } catch {
            return lesbar(error)
        }
    }

    /// **`nil` heisst gestoert, `[]` heisst wirklich nichts Ähnliches.**
    ///
    /// Hier stand `(try? …) ?? []`. Damit sah ein abgebrochener Abruf genauso
    /// aus wie eine Sammlung ohne Verwandtes — die Serienseite sagte „Nichts
    /// Ähnliches gefunden", obwohl sie den Server nie erreicht hatte. Das ist
    /// dieselbe Lüge, die bei der Suche schon einmal einzeln behoben wurde;
    /// seit dem 21.09.2026 ist sie hier an der Wurzel weg.
    func aehnliche(_ item: Item) async -> [Item]? {
        guard let client else { return nil }
        return try? await client.aehnliche(itemID: item.id, zu: item)
    }

    /// **`nil` heisst gestoert, `[]` heisst keine Extras.** Siehe `aehnliche`.
    func extras(_ item: Item) async -> [Item]? {
        guard let client else { return nil }
        return try? await client.extras(itemID: item.id)
    }

    /// **`nil` heisst gestoert, `[]` heisst nichts gefunden.**
    ///
    /// Hier stand `(try? …) ?? []`, und damit wurde aus jedem Netzfehler eine
    /// leere Trefferliste — die Suche sagte dann „Auf deinem Server steht dazu
    /// nichts", obwohl sie den Server gar nicht erreicht hatte. Eine App, die
    /// bei Netzproblemen behauptet, die Sammlung sei leer, verliert Vertrauen
    /// schneller, als sie es mit Politur gewinnt.
    func suche(_ begriff: String) async -> [Item]? {
        guard let client, begriff.count >= 2 else { return [] }
        return try? await client.suche(begriff)
    }

    // MARK: - Personen und Genres

    /// Was es von einer Person auf dem Server gibt — Filme und Serien, die
    /// neuesten zuerst.
    ///
    /// **Die Regel liegt im Paket** (`JellyfinClient.titel(person:)`), nicht
    /// hier. Sie stand bis zum 12.09.2026 an dieser Stelle und erreichte
    /// damit Linux und Windows nicht — die hängen ausschließlich am Paket.
    /// Dort hat sie jetzt auch Tests.
    /// **`nil` heisst gestoert, `[]` heisst: von dieser Person liegt nichts da.**
    func titel(person id: String) async -> [Item]? {
        guard let client else { return nil }
        return await client.titel(person: id)
    }

    /// Titel eines Genres, die zuletzt hinzugefügten zuerst. `nil`, wenn der
    /// Server nicht geantwortet hat — dann bleibt eine Reihe, wie sie war.
    /// **Die Regel liegt im Paket** (`JellyfinClient.titel(gattung:)`), damit
    /// Linux und Windows sie erreichen.
    func titel(gattung: String, limit: Int = 24) async -> [Item]? {
        guard let client else { return nil }
        return await client.titel(gattung: gattung, limit: limit)
    }

    /// **`nil` heisst gestoert, `[]` heisst: der Server kennt keine Genres.**
    ///
    /// Die Genre-Auswahl in den Einstellungen stand bei jedem Netzfehler leer
    /// da — als hätte der Server keine Genres, nicht als hätte er geschwiegen.
    func gattungen() async -> [String]? {
        guard let client else { return nil }
        return try? await client.gattungen()
    }

    // MARK: - Kopfbild

    /// Was der Kopf einer Seite zeigt, wenn es keinen Hintergrund gibt —
    /// einmal gesucht, dann gemerkt.
    private(set) var kopfbildErsatz: [String: URL] = [:]
    @ObservationIgnored private var kopfbildSucht: Set<String> = []

    /// **Für den Kopf einer Seite immer irgendein Bild.**
    ///
    /// Zuerst, was wirklich quer liegt (`Bildwahl.kopf`). Fehlt das, wird im
    /// Hintergrund weitergesucht: bei einer Serie das Standbild der Folge,
    /// die man als Nächstes schauen würde — sonst die erste, jede andere
    /// könnte vorwegnehmen, was man noch nicht gesehen hat —, bei allem
    /// anderen das Plakat. Das sieht quer beschnitten nicht perfekt aus, aber
    /// es ist etwas da. Vorher stand bei einer Serie ohne Hintergrund ein
    /// leerer Kopf.
    ///
    /// Antwortet sofort mit dem, was schon bekannt ist; kommt der Ersatz
    /// später, zeichnen die Seiten von selbst neu — das Modell ist
    /// beobachtbar.
    /// Dasselbe Kopfbild in einer bestimmten Breite (in Pixeln) — fuer den
    /// Download, der es in Bildschirmaufloesung auf das Geraet legt.
    func kopfbildURL(for item: Item, breite: Int) -> URL? {
        guard let bilder else { return nil }
        return Bildwahl.kopf(item, adressen: bilder, breite: breite)
    }

    func kopfbildURL(for item: Item) -> URL? {
        guard let bilder else { return nil }
        if let url = Bildwahl.kopf(item, adressen: bilder, breite: 1200) { return url }
        if let ersatz = kopfbildErsatz[item.id] { return ersatz }
        guard !kopfbildSucht.contains(item.id) else { return nil }
        kopfbildSucht.insert(item.id)
        Task { [weak self] in
            guard let self, let url = await self.kopfbildErsatzSuchen(for: item) else { return }
            self.kopfbildErsatz[item.id] = url
        }
        return nil
    }

    /// Nur, was wirklich quer liegt — ohne die Suche nach Ersatz. Für die
    /// Personenseite, deren Banner durch die Hintergründe ihrer Titel wechselt:
    /// ein Plakat quer beschnitten gehört dort nicht in den Wechsel.
    func querbildEcht(for item: Item) -> URL? {
        guard let bilder else { return nil }
        return Bildwahl.kopf(item, adressen: bilder, breite: 1200)
    }

    private func kopfbildErsatzSuchen(for item: Item) async -> URL? {
        guard let bilder else { return nil }
        var folge: Item?
        if item.type == "Series", let client {
            if let naechste = try? await client.naechsteFolgeDerSerie(seriesID: item.id) { folge = naechste }
            if folge == nil { folge = (try? await client.folgen(seriesID: item.id))?.first }
        }
        // Welches Bild gilt, steht im Paket — dieselbe Regel wie auf Android.
        return Bildwahl.kopfMitErsatz(item, folge: folge, adressen: bilder)
    }

    /// Der eine Ort, an dem Bildadressen entstehen.
    ///
    /// Vorher taten das fünf fast gleiche Blöcke, und zwei davon hängten das
    /// Zugangsmerkmal nicht an — was nur solange gutging, wie der Server
    /// Bilder auch unangemeldet herausgibt.
    /// Externe Untertiteldateien eines Plans, mit voller Adresse — der
    /// Player hängt sie beim Öffnen an (T1-H4). Von der Platte die, die beim
    /// Herunterladen mitgekommen sind.
    func untertiteldateien(_ plan: PlaybackPlan) -> [Untertiteldatei] {
        if plan.url.isFileURL {
            return Downloadverwaltung.untertitel(zur: plan.url, merkmal: VLCPlayerView.untertitelmerkmal)
        }
        guard let session else { return [] }
        return Untertiteldatei.aus(stroeme: plan.quelle?.mediaStreams ?? [],
                                   server: session.serverURL, schluessel: session.accessToken,
                                   merkmal: VLCPlayerView.untertitelmerkmal)
    }

    private var bilder: Bildadresse? {
        guard let session else { return nil }
        return Bildadresse(basis: session.serverURL, token: session.accessToken)
    }

    /// Das Plakat eines Titels. **Ohne Marke**, weil der Aufrufer sie nicht
    /// immer hat — Jellyfin gibt das Bild auch so heraus; die Marke ist nur
    /// fuer den Zwischenspeicher gut.
    /// 300 Punkt hoch: die Zeile zeigt 96, und ein Plakat, das mitgeladen
    /// wird, soll auch auf dem iPad taugen.
    func plakatURL(itemID: String, marke: String? = nil) -> URL? {
        bilder?.bauen(itemID: itemID, marke: marke, mass: .hoechstensHoch(300))
    }

    /// Porträt eines Mitwirkenden.
    func personBild(_ person: Person, maxHeight: Int = 220) -> URL? {
        bilder?.bauen(itemID: person.id, marke: person.primaryImageTag,
                      mass: .hoechstensHoch(maxHeight))
    }

    func setzeMerkliste(_ item: Item, an: Bool) async -> String? {
        guard let client else { return String(localized: "Nicht angemeldet.") }
        do { try await client.setzeMerkliste(itemID: item.id, an: an); return nil }
        catch { return lesbar(error) }
    }

    /// **H6 und H9 holen sich hier ihre Angabe.**
    ///
    /// Beide Regeln haengen an etwas, das nur der Server weiss: ob ein Titel
    /// gesehen ist, und ob es ihn ueberhaupt noch gibt. Was daraus folgt,
    /// steht bei ``Downloadverwaltung/nachziehen(vorhanden:gesehen:)``.
    ///
    /// **Ohne Antwort passiert nichts, und das ist der Normalfall.**
    /// Downloads sind fuer unterwegs gebaut; unterwegs antwortet kein
    /// Server. Wuerde ein Fehlschlag als Antwort gelten, stuende an jedem
    /// Titel „nicht mehr auf dem Server" — genau dort, wo die Funktion
    /// gebraucht wird. Bricht ein Teilstueck ab, bleibt alles, wie es war.
    func downloadsNachziehen() async {
        guard let client, !downloads.posten.isEmpty else { return }
        let ids = downloads.posten.map(\.id)
        var vorhanden: Set<String> = []
        var gesehen: Set<String> = []
        // Hundert Kennungen je Anfrage — dasselbe Mass, mit dem auch die
        // Bibliotheksseiten blaettern. Bei zehn Downloads ist es eine.
        for ab in stride(from: 0, to: ids.count, by: 100) {
            let stueck = Array(ids[ab ..< min(ab + 100, ids.count)])
            guard let antwort = try? await client.items(limit: stueck.count,
                                                        ids: stueck) else { return }
            for titel in antwort.items {
                vorhanden.insert(titel.id)
                if titel.istGesehen { gesehen.insert(titel.id) }
            }
        }
        downloads.nachziehen(vorhanden: vorhanden, gesehen: gesehen)
    }

    @discardableResult
    func setzeGesehen(_ item: Item, an: Bool) async -> String? {
        guard let client else { return String(localized: "Nicht angemeldet.") }
        do {
            try await client.setzeGesehen(itemID: item.id, an: an)
            // **Hier, nicht in den sechs Ansichten, die das rufen.**
            //
            // Der `Serienspeicher` hält die Folgen einer Serie samt Sehstand
            // und läuft nicht ab. Die Serienseite setzt sich daraus zusammen,
            // die Staffelansicht holte frisch und schrieb nicht zurück — wer
            // eine Staffel abhakte und zurückging, sah wieder lauter offene
            // Folgen. Jede Ansicht einzeln nachziehen zu lassen hätte
            // geheißen, dass die siebte es vergisst.
            //
            // Bei einer Folge und bei einer Staffel ist die Serie betroffen,
            // bei einer Serie sie selbst.
            Serienspeicher.geteilt.vergessen(item.seriesId ?? item.id)
            sehstandGeaendert += 1
            return nil
        } catch { return lesbar(error) }
    }

    /// **`nil` heisst gestoert, `[]` heisst: die Serie hat keine Staffeln.**
    ///
    /// Eine Serie ohne Staffeln gibt es wirklich (frisch angelegt, noch nichts
    /// eingelesen). Ein stummer Server ist etwas anderes, und die Serienseite
    /// muss beides auseinanderhalten können.
    func staffeln(_ serie: Item) async -> [Item]? {
        guard let client else { return nil }
        return try? await client.staffeln(seriesID: serie.id)
    }

    /// **`nil` heisst gestoert, `[]` heisst: die Staffel hat keine Folgen.**
    func folgen(serie: String, staffel: String?) async -> [Item]? {
        guard let client else { return nil }
        return try? await client.folgen(seriesID: serie, seasonID: staffel)
    }

    /// Wo man in dieser Serie steht — für den großen Knopf.
    /// **Die Regel liegt im Paket** (`JellyfinClient.standInSerie(_:)`) — sie
    /// gehört zu A10 und muss überall dieselbe Antwort geben.
    func standInSerie(_ serie: Item) async -> Item? {
        guard let client else { return nil }
        return await client.standInSerie(serie.id)
    }

    /// Das Profilbild aus Jellyfin. Fehlt es, antwortet der Server mit 404
    /// und die Ansicht faellt auf den Anfangsbuchstaben zurueck.
    /// **Immer dieselbe Kante, egal wie gross es gezeigt wird.**
    ///
    /// Hier stand eine Groesse als Argument, und die Aufrufer nutzten sie:
    /// 120 in der Kopfzeile, 200 auf der Profilseite, 240 im Kontenstreifen.
    /// Drei Groessen sind **drei Adressen** — und damit drei Eintraege im
    /// `Bildspeicher`, von denen jeder einzeln geholt werden will. Deshalb
    /// blendete das Profilbild beim Oeffnen der Profilseite jedes Mal neu
    /// ein, obwohl dasselbe Gesicht oben in der Leiste schon stand.
    ///
    /// 480 ist die groesste Stelle (240 Punkt im Kontenstreifen, doppelt fuer
    /// Retina). Ein Avatar in dieser Kante ist ein paar Kilobyte; einmal
    /// geholt traegt er jede Stelle, und `Bildspeicher` entschluesselt ihn
    /// ohnehin auf sein eigenes Mass herunter.
    static let benutzerbildKante = 480

    func benutzerbildURL() -> URL? {
        guard let session else { return nil }
        return bilder?.benutzer(session.userID, kante: Self.benutzerbildKante)
    }

    /// Dasselbe für ein bestimmtes Konto — für den Streifen, in dem mehrere
    /// nebeneinander stehen und nur eines das aktive ist.
    /// **Beim Server des Kontos, mit dessen Zugang** — nicht mit dem des
    /// gerade aktiven. Seit es mehrere Server gibt, fragte die App die Bilder
    /// der anderen beim falschen Server an, und sie verschwanden, bis man zu
    /// ihnen wechselte.
    func benutzerbildURL(fuer konto: Session) -> URL? {
        Bildadresse(basis: konto.serverURL, token: konto.accessToken)
            .benutzer(konto.userID, kante: Self.benutzerbildKante)
    }

    /// Waagerechtes Bild für die Reihe „Weiterschauen".
    ///
    /// Bewusst vom übergeordneten Titel, nicht von der Folge: ein Standbild
    /// aus der Folge sagt wenig und sieht neben den anderen Reihen beliebig
    /// aus. Gefragt war „eine Art Cover".
    func querbildURL(for item: Item, breite: Int = 600) -> URL? {
        querbild(for: item, breite: breite)?.url
    }

    /// **Die Kette liegt jetzt im Paket** — `JellyfinKit.Bildwahl.quer`.
    ///
    /// Sie stand hier, war damit aber an SwiftUI gebunden und fuer die
    /// Linux-Fassung unerreichbar. An ihr haengt nichts, was mit Oberflaeche
    /// oder Uebersetzung zu tun haette; die Begruendung zu jeder Stufe steht
    /// dort, samt der Messung, dass eine Folge nie einen eigenen Hintergrund
    /// hat.
    private func querbild(for item: Item, breite: Int) -> (url: URL, quelle: String)? {
        guard let bilder else { return nil }
        return Bildwahl.quer(item, adressen: bilder, breite: breite)
    }

    /// Das Bild fuer den Sperrbildschirm und das Kontrollzentrum.
    ///
    /// **Bei Folgen das Standbild der Folge, nicht das Plakat der Serie.**
    /// Das Plakat sagt nur, welche Serie laeuft — das steht daneben ohnehin
    /// als Text. Das Standbild zeigt, *wo* man ist, und das ist die Auskunft,
    /// die dort etwas traegt.
    ///
    /// Filme behalten ihr Plakat: dort gibt es kein Standbild, und das
    /// Plakat *ist* der Titel.
    func sperrbildURL(for item: Item, hoehe: Int = 600) -> URL? {
        if item.seriesId != nil, let marke = item.imageTags?["Primary"] {
            return bilder?.bauen(itemID: item.id, marke: marke,
                                 mass: .hoechstensHoch(hoehe))
        }
        return imageURL(for: item, maxHeight: hoehe, hochkant: true)
    }

    func backdropURL(for item: Item) -> URL? {
        guard let tag = item.backdropImageTags?.first else { return nil }
        return bilder?.bauen(itemID: item.id, art: .hintergrund, marke: tag,
                             mass: .hoechstensBreit(1200), guete: 85)
    }

    /// Die Folge nach dieser.
    func folgeNach(_ item: Item) async -> Item? {
        guard let client, let serie = item.seriesId else { return nil }
        return try? await client.folgeNach(itemID: item.id, seriesID: serie)
    }

    /// Angefangene Titel.
    /// `nil` heißt: die Anfrage ist fehlgeschlagen. Das ist etwas anderes als
    /// eine leere Liste — mit `try?` sah beides gleich aus, und ein einzelner
    /// Aussetzer hat die Startseite lautlos geleert.
    func weiterschauen() async -> [Item]? {
        guard let client else { return nil }
        return try? await client.resumeItems()
    }

    /// Nächste ungesehene Folgen laufender Serien.
    ///
    /// - Parameter ohne: Titel, die schon unter „Weiterschauen" stehen.
    ///   Jellyfin listet angefangene Folgen in beiden Abfragen; ohne das
    ///   Aussortieren stünde dieselbe Folge zweimal auf der Startseite.
    func naechsteFolge(ohne bereitsGezeigt: [Item] = []) async -> [Item]? {
        guard let client, let alle = try? await client.nextUp() else { return nil }
        let schonDa = Set(bereitsGezeigt.map(\.id))
        return alle.filter { !schonDa.contains($0.id) }
    }

    /// Zuletzt Hinzugefügtes über alle Bibliotheken.
    /// Neu dazugekommen — je Serie ein Eintrag, neueste zuerst.
    ///
    /// Jellyfins eigene Zusammenfassung nennt nur die Serie und die Zahl der
    /// neuen Folgen, nicht die Staffel. Deshalb ungruppiert holen und selbst
    /// zusammenfassen: die erste Folge je Serie ist die neueste, weil der
    /// Server bereits nach Datum sortiert.
    /// - Parameter in: Nur aus dieser Bibliothek. `nil` heißt: aus allen.
    /// **Die Regel liegt im Paket** (`JellyfinClient.zuletztHinzugefuegt`) —
    /// sie stand hier und erreichte Linux und Windows nicht.
    func zuletztHinzugefuegt(in bibliothek: String? = nil) async -> [Item]? {
        guard let client else { return nil }
        return await client.zuletztHinzugefuegt(in: bibliothek)
    }

    /// Eine Seite aus einer Bibliothek.
    ///
    /// Gibt neben den Titeln zurück, wie viele es insgesamt gibt — sonst weiß
    /// die Ansicht nicht, wann sie aufhören darf nachzuladen. Vorher wurden
    /// stur die ersten zweihundert geholt und der Rest war über die
    /// Oberfläche nicht erreichbar.
    func items(in parentID: String,
               art: String? = nil,
               sortierung: Sortierung = .name,
               filter: Bibliotheksfilter = .alle,
               ab startIndex: Int = 0,
               anzahl: Int = AppModel.seitengroesse) async -> (titel: [Item], gesamt: Int)? {
        await items(aus: Regalquelle(eltern: parentID, art: art), sortierung: sortierung,
                    filter: filter, ab: startIndex, anzahl: anzahl)
    }

    /// Eine Seite aus einer Bibliothek, aus allen oder aus einer Sammlung —
    /// die Unterschiede stehen in ``Regalquelle``.
    func items(aus quelle: Regalquelle,
               sortierung: Sortierung = .name,
               filter: Bibliotheksfilter = .alle,
               ab startIndex: Int = 0,
               anzahl: Int = AppModel.seitengroesse) async -> (titel: [Item], gesamt: Int)? {
        guard let client else { return nil }
        do {
            let antwort = try await client.items(parentID: quelle.eltern,
                                                 limit: anzahl,
                                                 startIndex: startIndex,
                                                 sortBy: sortierung.feld,
                                                 sortOrder: quelle.richtung(sortierung),
                                                 filters: filter.jellyfinFilter,
                                                 istGesehen: filter.istGesehen,
                                                 // Rekursiv, sobald die Gattung
                                                 // feststeht: sonst blieben die
                                                 // Titel unter den virtuellen
                                                 // Ordnern unerreichbar.
                                                 recursive: quelle.rekursiv,
                                                 includeItemTypes: quelle.typen)
            return (antwort.items, antwort.totalRecordCount)
        } catch {
            errorMessage = lesbar(error)
            return nil
        }
    }

    /// Alles Gemerkte — **quer über alle Bibliotheken**.
    ///
    /// Deshalb ohne `parentID`: die Merkliste ist keine Bibliothek, ihre
    /// Grenze ist der Haken und nicht ein Ordner auf der Platte. Und deshalb
    /// **rekursiv**: ohne das liefert Jellyfin nur, was ganz oben liegt, und
    /// das ist bei einem Server mit virtuellen Ordnern so gut wie nichts.
    ///
    /// `art` ist hier der Gattungsfilter der Seite: `nil` heisst Filme **und**
    /// Serien. Ohne die Aufzaehlung kaemen auch Staffeln, Folgen und
    /// Sammlungen mit — alles, woran je ein Haken hing.
    func gemerkte(art: String? = nil,
                  sortierung: Sortierung = .neueste,
                  ab startIndex: Int = 0,
                  anzahl: Int = AppModel.seitengroesse) async -> (titel: [Item], gesamt: Int)? {
        guard let client else { return nil }
        let gattungen = art.map { Bibliotheksgattung.typen(zu: $0) } ?? ["Movie", "Series"]
        do {
            let antwort = try await client.items(parentID: nil,
                                                 limit: anzahl,
                                                 startIndex: startIndex,
                                                 sortBy: sortierung.feld,
                                                 sortOrder: sortierung.richtung,
                                                 filters: ["IsFavorite"],
                                                 recursive: true,
                                                 includeItemTypes: gattungen)
            return (antwort.items, antwort.totalRecordCount)
        } catch {
            errorMessage = lesbar(error)
            return nil
        }
    }

    /// Groß genug, dass man beim ersten Wischen nicht ans Ende kommt, klein
    /// genug, dass die erste Seite schnell steht.
    static let seitengroesse = 60

    // MARK: - Dateien, deren Index nichts taugt





    /// Fragt den Server, wie er diesen Titel ausliefern würde.
    ///
    func plan(for itemID: String) async -> PlaybackPlan? {
        // **H8 — liegt die Datei hier, braucht es den Server nicht.**
        //
        // Und zwar vor dem `guard`: ohne Netz ist `client` zwar da, aber
        // `playbackPlan` liefe in seine Frist und käme mit nichts zurück.
        // Genau dafür ist heruntergeladen worden; ein Ladeschirm, der zwanzig
        // Sekunden auf einen Server wartet, den es im Flugzeug nicht gibt,
        // wäre die Funktion, die sich selbst aufhebt.
        //
        // Der Nutzer merkt davon nichts — kein zweiter Knopf, keine Wahl.
        if let datei = downloads.datei(fuer: itemID) {
            let p = downloads.posten(fuer: itemID)
            return .vonDerPlatte(datei, container: p?.container, mediaSourceID: p?.quelle)
        }
        guard let client else { return nil }
        do {
            let plan = try await client.playbackPlan(for: itemID,
                                                       profile: .vlc(maxBitrate: profilBitrate))
            if plan == nil {
                // Tritt bei Serien und Staffeln auf: die haben keine
                // Mediendatei, nur ihre Folgen haben eine.
                Self.log.error("Kein Plan für \(itemID, privacy: .public) — Server nannte keine MediaSource")
            }
            return plan
        } catch {
            Self.log.error("PlaybackInfo fehlgeschlagen für \(itemID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessage = lesbar(error)
            return nil
        }
    }

    /// Poster-URL. Wird hier gebaut statt im Client, damit die Ansichten
    /// nicht auf den Actor warten müssen.
    func imageURL(for item: Item, maxHeight: Int = 480, hochkant: Bool = false) -> URL? {
        guard let bilder else { return nil }
        // Hochkant heisst bei einer Folge: das Plakat der Serie. Warum, steht
        // in `Bildwahl.hochkant` — hier stand dieselbe Regel ein zweites Mal.
        if hochkant {
            return Bildwahl.hochkant(item, adressen: bilder, maxHoehe: maxHeight)
        }
        guard let marke = item.imageTags?["Primary"] else { return nil }
        return bilder.bauen(itemID: item.id, marke: marke,
                            mass: .hoechstensHoch(maxHeight))
    }

    /// Vorspann, Rückblick und Abspann einer Folge.
    ///
    /// Leer heißt: der Server weiß nichts davon — kein Plugin, keine Analyse,
    /// oder eine ältere Fassung. Dann bleibt alles wie vorher.
    func abschnitte(fuer itemID: String) async -> [JellyfinKit.Abschnitt] {
        guard let client else { return [] }
        return await client.abschnitte(fuer: itemID)
    }

    /// Vorschaubilder beim Spulen — `nil` ohne Trickplay am Server.
    func trickplay(fuer itemID: String, quelle: String?) async -> Trickplay? {
        guard let client else { return nil }
        return await client.trickplay(itemID: itemID, mediaSourceID: quelle)
    }

    func trickplayBlatt(_ itemID: String, quelle: String?, breite: Int, blatt: Int) async -> Data? {
        guard let client else { return nil }
        return await client.trickplayBlatt(itemID: itemID, mediaSourceID: quelle,
                                           breite: breite, blatt: blatt)
    }

    // MARK: - Wiedergabe melden
    //
    // Schlägt eine Meldung fehl, ist das kein Grund, die Wiedergabe zu stören —
    // deshalb wird der Fehler hier nur vermerkt, nicht angezeigt.

    /// Was eine Meldung an den Server braucht. Der Client wird beim Einreihen
    /// festgehalten: wechselt danach das Konto, gehoert die Meldung trotzdem
    /// dem, der geschaut hat.
    struct Meldeinhalt: Sendable {
        let client: JellyfinClient?
        let item: Item
        let plan: PlaybackPlan
        let sekunden: Double
        let spuren: Spurindizes
    }

    private enum Meldefehler: Error { case keinServer }

    /// **Abgesetzt, nicht abgewartet** (Audit 16.09., T1-H2). Die Reihe steht
    /// im Paket (`Meldewarteschlange`): Reihenfolge, Zusammenfassen, Frist
    /// und die Stoppsperre je PlaySession. Hier steht nur, was gesendet wird.
    @ObservationIgnored private let meldungen = Meldewarteschlange<Meldeinhalt> { meldung in
        let inhalt = meldung.nutzlast
        guard let client = inhalt.client else { throw Meldefehler.keinServer }
        #if DEBUG
        // Messlauf: ein Server, der nicht antwortet (tvOS `-messlauf`).
        if ProcessInfo.processInfo.arguments.contains("-meldungenHaengen") {
            try await Task.sleep(for: .seconds(30))
        }
        #endif
        let item = inhalt.item, plan = inhalt.plan
        let ticks = JellyfinClient.ticks(fromSeconds: inhalt.sekunden)
        switch meldung.art {
        case .start:
            try await AppModel.startSenden(client: client, item: item, plan: plan, ticks: ticks,
                                           spuren: inhalt.spuren)
            Protokoll.schreib("[Melden] Start \(Int(inhalt.sekunden)) s \(item.id) session \(plan.playSessionID ?? "nil")"
                + " Spuren \(inhalt.spuren.ton.map(String.init) ?? "—")/\(inhalt.spuren.untertitel.map(String.init) ?? "—")")
        case let .fortschritt(pausiert):
            try await client.reportProgress(itemID: item.id, plan: plan,
                                            positionTicks: ticks, paused: pausiert, spuren: inhalt.spuren)
            Protokoll.schreib("[Melden] Progress \(Int(inhalt.sekunden)) s pausiert \(pausiert) \(item.id)"
                + " Spuren \(inhalt.spuren.ton.map(String.init) ?? "—")/\(inhalt.spuren.untertitel.map(String.init) ?? "—")")
        case .stopp:
            try await client.reportStopped(itemID: item.id, plan: plan, positionTicks: ticks)
        }
    }

    private func meldung(_ art: Meldewarteschlange<Meldeinhalt>.Art, item: Item,
                         plan: PlaybackPlan, seconds: Double) -> Meldewarteschlange<Meldeinhalt>.Meldung {
        .init(art: art,
              schluessel: Stoppsperre.schluessel(itemID: item.id, playSessionID: plan.playSessionID),
              nutzlast: Meldeinhalt(client: client, item: item, plan: plan, sekunden: seconds,
                                    spuren: laufendeSpuren))
    }

    /// Die Spuren, die der Player zuletzt gemeldet hat, als Jellyfin-Index
    /// (T3 #8). Gehen mit Start und Fortschritt hinaus; der Player setzt sie
    /// bei jedem Öffnen zurück und nach jeder Wahl neu.
    @ObservationIgnored private var laufendeSpuren = Spurindizes()

    func spurenGewaehlt(_ spuren: Spurindizes) {
        laufendeSpuren = spuren
    }

    /// Kehrt sofort zurueck; gesendet wird in der Reihe.
    func reportStart(item: Item, plan: PlaybackPlan, seconds: Double) {
        // Auch ohne Server: ein Titel von der Platte laeuft wieder, und sein
        // naechstes Ende soll gemeldet werden duerfen — die Reihe gibt die
        // Sperre beim Einreihen frei.
        laufenderTitel = (item, plan)
        gemeldetPausiert = false
        meldungen.melden(meldung(.start, item: item, plan: plan, seconds: seconds))
        trakt.start(item: item, client: client, sekunden: seconds)
    }

    private nonisolated static func startSenden(client: JellyfinClient, item: Item,
                                                plan: PlaybackPlan, ticks: Int64,
                                                spuren: Spurindizes) async throws {
        // **Die Faehigkeiten vor jeder Wiedergabe erneut melden.**
        //
        // Sie wurden bisher **einmal** gemeldet, beim Erscheinen der
        // Hauptansicht. Das reicht nicht, und am 10.09.2026 ist es
        // aufgeschlagen: die Uebernahme ging auf beiden Geraeten
        // gleichzeitig nicht mehr, in beide Richtungen.
        //
        // Der Grund liegt darin, wie der Server sucht. `Sessions` wird mit
        // `controllableByUserId` gefragt — es kommen also nur Sitzungen
        // zurueck, die **Befehle annehmen**, und das weiss der Server nur
        // durch `Sessions/Capabilities/Full`. Eine Sitzung lebt dort aber
        // nicht ewig: Serverneustart, Zeitablauf, laengerer Hintergrund, und
        // sie ist weg. Die naechste Wiedergabe legt dann eine **neue** an —
        // und die hat die Faehigkeiten nie bekommen, weil das nur beim
        // Programmstart geschah. Beide Geraete sind dann fuereinander
        // unsichtbar, bis jemand die App neu startet. Das erklaert auch,
        // warum es „auf einmal" nicht mehr ging und nicht schleichend.
        //
        // Der Aufruf ist billig, geht an dieselbe Gegenstelle, an die gleich
        // die Startmeldung geht, und ist beliebig oft wiederholbar. Hier und
        // nicht anderswo, weil genau das der Zeitpunkt ist, an dem das andere
        // Geraet uns sehen koennen muss.
        //
        // Scheitert das, geht der Start trotzdem — ausser die Frist hat
        // abgebrochen; dann ist auch der Start nicht mehr dran.
        do {
            try await client.faehigkeitenMelden()
        } catch {
            try Task.checkCancellation()
            Protokoll.schreib("[Uebernahme] Faehigkeiten nicht gemeldet: \(error)")
        }
        try await client.reportStart(itemID: item.id, plan: plan, ticks: ticks, spuren: spuren)
    }

    /// Was gerade laeuft — gemerkt, damit ein Fernbefehl, eine Pause oder ein
    /// Sprung sofort gemeldet werden kann, ohne den Player danach zu fragen.
    ///
    /// **Folgt dem Lebenslauf der Wiedergabe** (T1-M9): gesetzt mit dem Start,
    /// geloescht mit dem Stopp. Frueher setzte ihn nur der Fortschritt, und nie
    /// zurueck — ein Fernbefehl kurz nach Wechsel oder Schliessen meldete die
    /// neue Stelle an die alte Folge.
    @ObservationIgnored private var laufenderTitel: (item: Item, plan: PlaybackPlan)?
    /// Was dem Server zuletzt als Laufzustand gesagt wurde — damit VLCs
    /// Meldung nur einmal je Wechsel hinausgeht.
    @ObservationIgnored private var gemeldetPausiert = false

    /// Kehrt sofort zurueck; gesendet wird in der Reihe. Nach dem Stopp
    /// dieser Sitzung verworfen.
    func reportProgress(item: Item, plan: PlaybackPlan, seconds: Double, paused: Bool) {
        guard meldungen.melden(meldung(.fortschritt(pausiert: paused), item: item,
                                       plan: plan, seconds: seconds)) else {
            Protokoll.schreib("[Melden] Fortschritt nach Stopp verworfen \(item.id)")
            return
        }
        laufenderTitel = (item, plan)
        gemeldetPausiert = paused
    }

    /// **VLC hat angehalten oder laeuft wieder — sofort melden** (T1-N1).
    ///
    /// Haengt an `VLCPlayerView.laeuftGemeldet`, nicht am Druck: der Knopf
    /// wartet auf VLC, und wer im Druck meldete, las den Zustand von davor
    /// (iOS meldete Pause als „laeuft"). Einmal hier fuer alle Fassungen;
    /// vor dem Start und nach dem Stopp gibt es keinen laufenden Titel.
    func laufzustandGemeldet(laeuft: Bool, sekunden: Double) {
        guard let laufenderTitel, gemeldetPausiert == laeuft else { return }
        Protokoll.schreib("[Melden] sofort: \(laeuft ? "weiter" : "Pause") bei \(Int(sekunden)) s")
        trakt.laufzustand(laeuft: laeuft, sekunden: sekunden)
        reportProgress(item: laufenderTitel.item, plan: laufenderTitel.plan,
                       seconds: sekunden, paused: !laeuft)
    }

    /// **Gesprungen — sofort melden**, mit der Zielstelle. Haengt an
    /// `VLCPlayerView.sprungGemeldet`, damit kein Sprungweg es vergisst.
    func sprungGemeldet(ziel: Double) {
        guard let laufenderTitel else { return }
        reportProgress(item: laufenderTitel.item, plan: laufenderTitel.plan,
                       seconds: max(0, ziel), paused: gemeldetPausiert)
        trakt.sprung(sekunden: max(0, ziel))
    }

    /// **Die App geht in den Hintergrund** (T3 #5): den Stand jetzt melden,
    /// nicht erst im naechsten Takt — eingefroren kaeme der nie.
    ///
    /// `beginBackgroundTask` haelt die App wach, bis die Meldung durch ist
    /// oder ihre Frist abgelaufen.
    func hintergrundMelden(item: Item, plan: PlaybackPlan, seconds: Double, paused: Bool) {
        let eintrag = meldung(.fortschritt(pausiert: paused), item: item, plan: plan, seconds: seconds)
        guard meldungen.fortschrittErlaubt(eintrag.schluessel) else { return }
        Protokoll.schreib("[Melden] Hintergrund: \(Int(seconds)) s pausiert \(paused)")
        #if os(iOS) || os(tvOS)
        let aufgabe = UIApplication.shared.beginBackgroundTask(withName: "Wiedergabe melden")
        Task {
            let ergebnis = await meldungen.meldenUndWarten(eintrag)
            Protokoll.schreib("[Melden] Hintergrund: \(ergebnis)")
            UIApplication.shared.endBackgroundTask(aufgabe)
        }
        #else
        meldungen.melden(eintrag)
        #endif
        laufenderTitel = (item, plan)
        gemeldetPausiert = paused
    }

    /// Zählt einen fertig geschauten Titel und meldet, ob danach die Frage
    /// nach einer Bewertung oder der Hinweis auf den Discord dran ist —
    /// höchstens eins davon (``Gemeinschaft/anstoss``).
    func fertigGeschaut(position: Double, dauer: Double) {
        guard Bewertungsfrage.zaehltAlsFertig(position: position, dauer: dauer) else { return }
        let ablage = UserDefaults.standard
        let fertig = ablage.integer(forKey: "bewertungFertig") + 1
        ablage.set(fertig, forKey: "bewertungFertig")
        let fassung = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        #if os(tvOS)
        // tvOS hat keine Bewertungsabfrage — `requestReview` gibt es dort nicht.
        let bewertungMoeglich = false
        #else
        let bewertungMoeglich = true
        #endif
        switch Gemeinschaft.anstoss(fertig: fertig,
                                    bewertungZuletzt: ablage.string(forKey: "bewertungFassung"),
                                    fassung: fassung,
                                    discordGezeigt: ablage.bool(forKey: "discordHinweisGezeigt"),
                                    bewertungMoeglich: bewertungMoeglich) {
        case .bewertung:
            ablage.set(fassung, forKey: "bewertungFassung")
            bewertungFaellig = true
        case .discord:
            // Gleich als gezeigt merken: stürzt die App vorher ab oder wird
            // sie geschlossen, kommt der Hinweis lieber nie als zweimal.
            ablage.set(true, forKey: "discordHinweisGezeigt")
            discordHinweisFaellig = true
        case nil:
            break
        }
    }

    /// Das Ende — **abgewartet**, weil danach die Seiten neu laden (d8492ca).
    /// Die Reihe schickt es hinter einem noch laufenden Start; doppelt kommt es
    /// nicht (Stoppsperre in der Reihe).
    func reportStopped(item: Item, plan: PlaybackPlan, seconds: Double) async {
        let ticks = JellyfinClient.ticks(fromSeconds: seconds)
        // Auch nach einer Nachmeldung: die Seite soll dann wenigstens den
        // Stand des letzten Takts zeigen, nicht den von vor dem Abspielen.
        defer { wiedergabeBeendet += 1 }
        let eintrag = meldung(.stopp, item: item, plan: plan, seconds: seconds)
        // Vor dem Abwarten: Trakt hat seine eigene Reihe und wartet auf
        // Jellyfin nicht — und Jellyfin nicht auf Trakt.
        trakt.stopp(item: item, sekunden: seconds)
        // Sofort, nicht nach der Antwort: ein Fernbefehl in der Zwischenzeit
        // gehoert keinem Titel mehr (T1-M9).
        if let laufenderTitel,
           Stoppsperre.schluessel(itemID: laufenderTitel.item.id,
                                  playSessionID: laufenderTitel.plan.playSessionID) == eintrag.schluessel {
            self.laufenderTitel = nil
        }
        let ergebnis = await meldungen.meldenUndWarten(eintrag)
        switch ergebnis {
        case .gesendet:
            Self.log.info("Wiedergabe gemeldet: Ende bei \(Int(seconds)) s")
            Protokoll.schreib("[Melden] Stopped \(Int(seconds)) s \(item.id) session \(plan.playSessionID ?? "nil")")
        case .verworfen:
            Protokoll.schreib("[Melden] Stopped doppelt verworfen \(item.id) session \(plan.playSessionID ?? "nil")")
        case .gescheitert, .zeitUeberschritten:
            // **Hier entsteht die Angabe, für die es Downloads gibt.**
            //
            // Wer einen Titel im Flugzeug sieht, erzeugt genau eine Auskunft,
            // die niemand sonst hat: wo er aufgehört hat. Ginge sie hier
            // verloren, hätte der Server den Stand vom Start des Flugs, und
            // zu Hause liefe die Folge von vorn los. H8, zweite Hälfte.
            Self.log.error("Ende-Meldung nicht durch (\(String(describing: ergebnis), privacy: .public)), wird nachgemeldet")
            Protokoll.schreib("[Melden] Stopped \(ergebnis) → Nachmeldung \(item.id)")
            nachmelden(item.id, ticks)
        }
    }

    // MARK: H8 — was der Server noch nicht weiss

    private static let nachmeldeschluessel = "nachmeldungen"

    private var nachmeldungen: [Nachmeldung] {
        get {
            guard let roh = UserDefaults.standard.data(forKey: Self.nachmeldeschluessel)
            else { return [] }
            return (try? JSONDecoder().decode([Nachmeldung].self, from: roh)) ?? []
        }
        set {
            guard let roh = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(roh, forKey: Self.nachmeldeschluessel)
        }
    }

    private func nachmelden(_ itemID: String, _ ticks: Int64) {
        guard let konto = session?.userID else { return }
        nachmeldungen = Nachmelderegeln.aufnehmen(
            Nachmeldung(itemID: itemID, konto: konto, ticks: ticks),
            in: nachmeldungen)
    }

    /// Alles Liegengebliebene abschicken. Läuft nach jeder erfolgreichen
    /// Verbindungsprüfung — also genau dann, wenn der Server nachweislich
    /// wieder da ist, statt in einem eigenen Takt zu raten.
    func nachmeldungenAbschicken() async {
        guard let client, let konto = session?.userID else { return }
        let offen = Nachmelderegeln.faellig(nachmeldungen, konto: konto)
        guard !offen.isEmpty else { return }
        var geschafft: [String] = []
        for m in offen {
            // Ein Plan von der Platte reicht: `reportStopped` braucht daraus
            // nur die Kennungen, und die Sitzung gab es offline ohnehin nicht.
            let plan = PlaybackPlan.vonDerPlatte(URL(fileURLWithPath: "/"), container: nil)
            do {
                try await client.reportStopped(itemID: m.itemID, plan: plan,
                                               positionTicks: m.ticks)
                geschafft.append(m.id)
            } catch {
                // **Abbrechen, nicht weiterprobieren.** Scheitert eine, ist
                // der Server wieder weg; die übrigen scheiterten auch und
                // stünden danach als verloren da.
                break
            }
        }
        guard !geschafft.isEmpty else { return }
        nachmeldungen = Nachmelderegeln.erledigt(geschafft, in: nachmeldungen)
        Self.log.info("\(geschafft.count) Stellen nachgemeldet")
    }

    /// Auf ein anderes Konto desselben Servers umschalten.
    ///
    /// **Kein neues Passwort.** Beide Merkmale liegen im Schlüsselbund; der
    /// Wechsel tauscht nur, welches gilt. Was danach neu aufgebaut werden
    /// muss, steht in ``neuVerbinden()`` — es ist mehr, als man denkt.
    func kontoWechseln(zu kennung: String) {
        // Über den Kontoschlüssel — dieselbe Benutzerkennung kann es auf zwei
        // Servern geben. Eine bloße Kennung von früher geht weiterhin.
        guard var neu = bund, let ziel = neu.konto(kennung),
              ziel.kontoschluessel != neu.aktives.kontoschluessel else { return }
        neu.wechseln(zu: kennung)
        bund = neu
        bundSichern()
        neuVerbinden()
    }

    /// Baut alles neu auf, was am angemeldeten Konto hängt.
    ///
    /// **Die Fernsteuerung gehört dazu, und das sieht man ihr nicht an.**
    /// Sie wird sonst nur beim Erscheinen der Hauptansicht gestartet — die
    /// bleibt beim Kontowechsel aber stehen, und dann meldete sich das Gerät
    /// weiter mit dem Merkmal des vorigen Kontos am Server. Auf dem iPhone
    /// wäre danach die falsche Wiedergabe zum Übernehmen angeboten worden.
    private func neuVerbinden() {
        guard let s = session else { return }
        // Anderer Server: bis seine Antwort da ist, steht die Adresse statt
        // des alten Namens da — nicht der Name des Servers von eben.
        if client?.baseURL.absoluteString.lowercased() != s.serverURL.absoluteString.lowercased() {
            serverName = s.serverURL.host()
            serverVersion = nil
        }
        // **Beim Wechsel wird nicht abgemeldet.** `abmelden()` schickt ein
        // `Sessions/Logout` an den Server und zieht das Merkmal ein — richtig
        // beim Abmelden, verheerend beim Umschalten: das Konto, von dem man
        // weggeht, waere danach unbrauchbar, und der Weg zurueck endet in
        // „Anmeldung abgelehnt". Der alte Client wird einfach fallen
        // gelassen; das Merkmal bleibt gueltig und liegt im Schluesselbund.
        let neuer = JellyfinClient(baseURL: s.serverURL, deviceID: Self.deviceID,
                                   deviceName: Self.deviceName, session: s)
        client = neuer
        phase = .ready
        nachDemWechsel()
        Task { _ = await verbindungPruefen() }
    }

    func signOut() {
        // Der Socket lief vorher weiter — mit einem Zugangsmerkmal, das der
        // Nutzer gerade loswerden wollte. Seit die Fernsteuerung sich nach
        // einem Abriss selbst wieder aufbaut, hätte sie das auch getan.
        let alter = client
        Task {
            await fernsteuerungBeenden()
            await alter?.abmelden()
        }
        // **Abmelden trifft nur das aktive Konto.** Sind noch andere da,
        // schaltet die App auf das nächste um, statt zur Serveranmeldung
        // zurückzufallen — wer den Server ganz verlassen will, meldet jedes
        // Konto einzeln ab. Ein Knopf, eine Bedeutung.
        if let rest = bund?.entfernt(bund?.aktiveKennung ?? "") {
            bund = rest
            bundSichern()
            neuVerbinden()
            return
        }

        Keychain.delete(key: Self.kontenKey)
        Keychain.delete(key: Self.sessionKey)
        // Sonst stehen im Top Shelf weiter die Titel des vorigen Kontos.
        //
        // **Nur auf dem Fernseher, und deshalb eingeklammert.** Ein Top Shelf
        // gibt es sonst nirgends: `Regalvorschau.swift` steht in der
        // tvOS-App und in ihrer Erweiterung, in keinem anderen Ziel. Ohne
        // die Klammer bricht macOS an dieser Zeile ab — dort sind die
        // geteilten Dateien einzeln aufgezaehlt, waehrend iOS `Sources/Shared`
        // als ganzen Ordner nimmt und die Datei versehentlich mitbekommt.
        // Der Bau auf iOS beweist hier also nichts.
        #if os(tvOS)
        Regal.leeren()
        #endif
        bund = nil
        client = nil
        views = []
        errorMessage = nil
        phase = .disconnected
    }

    // MARK: - Sitzung sichern

    func bundSichern() {
        guard let bund else { return }
        do {
            try Keychain.save(JSONEncoder().encode(bund), key: Self.kontenKey)
            // Sofort zurücklesen: ein Schreibfehler, der erst beim nächsten
            // Start auffällt, kostet unnötig eine Anmeldung.
            guard Keychain.load(key: Self.kontenKey) != nil else {
                Self.log.error("Keychain: Sitzung geschrieben, aber nicht lesbar")
                errorMessage = String(localized: "Deine Anmeldung ließ sich nicht speichern. Beim nächsten Start musst du dich neu anmelden.")
                return
            }
            Self.log.info("Keychain: Sitzung gesichert")
        } catch {
            errorMessage = String(localized: "Deine Anmeldung ließ sich nicht speichern.")
        }
    }

    /// Liest den Bund — und nimmt eine einzelne Sitzung aus der Zeit davor an.
    ///
    /// **Die Übernahme steht hier und nicht im Paket**, weil nur der
    /// Zustandshalter weiß, wo etwas liegt. Der alte Eintrag wird nicht
    /// gelöscht: wer noch einmal eine ältere Fassung startet, soll nicht
    /// plötzlich abgemeldet sein.
    private func bundLaden() -> Kontenbund? {
        // **Wo die Daten liegen, weiß nur der Zustandshalter; was sie
        // bedeuten, steht im Paket.** Genau diese Trennung hat gefehlt: die
        // Übernahme der Einzelsitzung stand hier und noch einmal in der
        // GTK-Fassung, in zwei Schreibweisen.
        Kontenbund.ausAblage(bund: Keychain.load(key: Self.kontenKey),
                             einzelne: Keychain.load(key: Self.sessionKey))
    }

    private func restoreSession() {
        guard let wieder = bundLaden() else { return }
        bund = wieder
        let s = wieder.aktives
        let neuer = JellyfinClient(baseURL: s.serverURL, deviceID: Self.deviceID,
                                   deviceName: Self.deviceName, session: s)
        client = neuer
        phase = .ready
        Task {
            // Name und Fassung stehen sonst nur nach einer frischen Verbindung
            // bereit — in den Einstellungen stand danach „Server · ?".
            _ = await verbindungPruefen()

            // Und prüfen, ob das Merkmal überhaupt noch gilt.
            //
            // Vorher genügte ein Eintrag im Keychain, um `ready` zu setzen.
            // Ein widerrufenes Merkmal führte damit nicht auf den
            // Anmeldebildschirm, sondern in „Kein Kontakt zum Server" — und
            // von dort gibt es keinen Weg zurück außer über das Profilmenü.
            guard await neuer.sitzungGiltNoch() else {
                let name = session?.userName
                signOut()
                // **Nach dem Abmelden kann noch ein Konto da sein.** Seit es
                // mehrere gibt, schaltet `signOut` auf das nächste um statt
                // zur Serveranmeldung zurückzufallen — und dann wäre „bitte
                // neu anmelden" schlicht falsch: der Nutzer ist angemeldet,
                // nur mit einem anderen Konto.
                if let weiter = session?.userName {
                    errorMessage = String(localized: "Die Anmeldung von \(name ?? "?") gilt nicht mehr. Jetzt angemeldet als \(weiter).")
                } else {
                    errorMessage = String(localized: "Die Anmeldung gilt nicht mehr. Bitte neu anmelden.")
                }
                return
            }
        }
    }

    /// Liegt in JellyfinKit, damit sie ohne Simulator testbar ist.
    static func normalizeServerURL(_ raw: String) -> URL? {
        AppModelURLNormalizer.normalize(raw)
    }
}

extension AppModel {
    /// **Der Weg in die Wiedergabe einer Folge, einmal.**
    ///
    /// Stand zeichengleich in `Shared/SeriesView.swift` und
    /// `tvOS/SerienView.swift` — bis auf das Zuweisungsziel. Genau die Sorte,
    /// die auseinanderlaeuft: Es reicht, dass einer die Meldung aendert oder
    /// eine Pruefung ergaenzt, und die Plattformen antworten verschieden.
    ///
    /// Gibt `nil` zurueck, wenn der Server keinen Plan liefert. Die Meldung
    /// dazu steht in `folgeNichtGeladen`, damit sie ebenfalls nur einmal
    /// existiert.
    func folgenwunsch(_ folge: Item, ab: Double) async -> Abspielwunsch? {
        guard let plan = await plan(for: folge.id) else { return nil }
        return Abspielwunsch(item: folge, plan: plan, startAt: ab)
    }

    static var folgeNichtGeladen: String {
        String(localized: "Die Folge konnte nicht geladen werden.")
    }
}

/// Die festen Reihen der Startseite — ein- und ausschaltbar, umsortierbar.
///
/// **Neue Filme und neue Serien sind eigene Reihen**, damit man sie einzeln
/// schieben kann: wer Serien oben will und Filme unten, soll das können.
/// `neuzugaenge` ist die gemeinsame Reihe, wenn „Neuzugänge getrennt" aus ist.
// `Startreihe` liegt seit dem 13.09.2026 im Paket (`Startreihen.swift`) — die
// Frage, welche Reihe wann gilt, ist keine Anzeigefrage, und hier erreichte
// sie Linux und Windows nicht.

/// Name und Zeichen einer Reihe — **hier, nicht in einer Ansicht.**
///
/// Sie standen in `DarstellungView`, und die gibt es nur auf iOS. Die
/// Mac-Fassung braucht dieselben Wörter für dieselben Reihen; eine zweite
/// Liste wäre genau die kopierte Funktion, vor der CLAUDE.md warnt.
extension Startreihe {
    var name: LocalizedStringKey {
        switch self {
        case .weiterschauen: "Weiterschauen"
        case .naechsteFolge: "Nächste Folge"
        case .neueFilme:     "Neue Filme"
        case .neueSerien:    "Neue Serien"
        case .neuzugaenge:   "Neu hinzugefügt"
        }
    }

    var symbol: String {
        switch self {
        case .weiterschauen: "play.circle"
        case .naechsteFolge: "forward.end"
        case .neueFilme:     "film"
        case .neueSerien:    "tv"
        case .neuzugaenge:   "sparkles"
        }
    }
}
