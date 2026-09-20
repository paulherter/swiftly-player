import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JellyfinKit

/// **Die Fassade, die Android sieht.**
///
/// Haelt, was auf Apple `AppModel` haelt: den Client und die Sitzung. Kotlin
/// haelt nur Oberflaechenzustand. Antworten gehen als JSON ueber die Bruecke —
/// fertig zusammengesetzt, damit keine Regel in Kotlin ein zweites Mal entsteht
/// (Notizen/Android/PLAN.md, „Regeln fuer die Fassade").
///
/// **Eine Klasse mit Sperre, kein Actor:** jextract wickelt Klassen, und die
/// Aufrufe kommen aus Coroutinen auf beliebigen Faeden.
public final class Kern: @unchecked Sendable {
    private let geraeteID: String
    private let programm: String
    private let geraeteName: String
    private let fassung: String
    private let sperre = NSLock()
    private var _client: JellyfinClient?
    private var _adressen: Bildadresse?
    private var _sitzung: Session?
    private var _wiedergabe: Wiedergabe?
    /// Der Folgenwechsel des offenen Players — je Oeffnen neu, `schliessen` ist endgueltig.
    private var _folgenwechsel = Folgenwechsel()
    /// Was dem Server zuletzt als Laufzustand gesagt wurde — VLCs Meldung geht einmal je Wechsel hinaus.
    private var _gemeldetPausiert = false
    /// Der Client eines Servers, der gerade aufgenommen wird — `AppModel.aufnahme`. Die laufende
    /// Sitzung bleibt dabei unberuehrt; bricht die Aufnahme ab, ist nichts passiert.
    private var _aufnahme: JellyfinClient?
    /// Der laufende Quick-Connect-Vorgang. Der geheime Teil verlaesst Swift nie.
    private var _quickconnect: Anmeldecode?
    /// Das laufende Warten auf die Freigabe — der Code, fuer den es gilt, und wie es abgebrochen wird.
    private var _quickconnectWarten: (code: String, aufgabe: @Sendable () -> Void)?
    private var _quickconnectRest = 0
    /// Der Zaehlstand des Technikschilds — je Titel neu.
    private var _zaehlwerk: Zaehlwerk?
    /// Seerr — ein Bonus: ohne Zugang gibt es keinen Client, und nichts auf den Seiten deutet darauf hin.
    private var _seerr: SeerrClient?
    /// Der Socket, ueber den Jellyfin Befehle schickt — ohne ihn keine Knoepfe im Dashboard.
    private var _fern: Fernsteuerung?
    private let fernablage = Befehlsablage()
    private var _immerDirectPlay = true
    private var _megabit = 0

    /// Was dem Server als Grenze gemeldet wird — `AppModel.profilBitrate`, die Rechnung im Paket.
    private var profilBitrate: Int {
        sperre.lock(); defer { sperre.unlock() }
        return Bitratengrenze.fuer(immerDirectPlay: _immerDirectPlay, megabit: _megabit)
    }

    /// Aus den Einstellungen — beim Start und bei jeder Aenderung.
    public func wiedergabeWahlen(immerDirectPlay: Bool, megabit: Int) {
        sperre.lock(); _immerDirectPlay = immerDirectPlay; _megabit = megabit; sperre.unlock()
    }

    /// Die laufende Wiedergabe — was `PlayerScreen` auf iOS haelt: Plan, Abschnitte, die
    /// naechste Folge und den Stand des Takts. Kotlin haelt nur Bild und Finger.
    private struct Wiedergabe: Sendable {
        let item: Item
        let plan: PlaybackPlan
        var abschnitte: [Abschnitt]
        var naechste: Item?
        var stand = Wiedergabetakt.Stand()
        let start = Date()
        /// „Intro ueberspringen" / „Naechste Folge" ueber dem Bild — je Folge neu, weil jeder Wechsel
        /// eine neue `Wiedergabe` setzt (`Angebotsebene.neueFolge` braucht es deshalb nicht).
        var ebene = Angebotsebene()
        /// Stufe 4: externe Untertitel des Plans (Merkmal setzt Kotlin), die laufenden Spuren als
        /// Jellyfin-Index fuer die Meldungen, und eine gewaehlte Datei, deren Spur VLC noch nicht meldet.
        /// Je Folge neu, wie auf Apple bei jedem `play(url:)`.
        var dateien: [Untertiteldatei] = []
        var spuren = Spurindizes()
        var offenerUntertitel: Int?
    }

    public init(geraeteID: String, geraeteName: String, fassung: String, programm: String) {
        self.geraeteID = geraeteID
        self.programm = programm
        self.geraeteName = geraeteName
        self.fassung = fassung
        meldungen = Self.meldereihe(zeilen: protokollzeilen, probe: meldeprobe)
    }

    private var client: JellyfinClient? {
        get { sperre.lock(); defer { sperre.unlock() }; return _client }
    }
    private var adressen: Bildadresse? {
        get { sperre.lock(); defer { sperre.unlock() }; return _adressen }
    }
    private func setzen(_ c: JellyfinClient?, _ a: Bildadresse?, _ s: Session? = nil) {
        sperre.lock(); _client = c; _adressen = a; _sitzung = s; sperre.unlock()
    }

    /// Das Profilbild des angemeldeten Kontos — dieselbe Adresse wie
    /// `AppModel.benutzerbildURL()` auf Apple. `nil` ohne Sitzung.
    public func benutzerbild(kante: Int) -> String? {
        sperre.lock(); defer { sperre.unlock() }
        guard let s = _sitzung, let a = _adressen else { return nil }
        return a.benutzer(s.userID, kante: kante)?.absoluteString
    }

    private func neuerClient(_ url: URL, _ sitzung: Session? = nil) -> JellyfinClient {
        JellyfinClient(baseURL: url, deviceID: geraeteID, deviceName: geraeteName,
                       clientVersion: fassung, programm: programm, session: sitzung)
    }

    // MARK: Sprache

    /// **Vor dem ersten Text aufrufen** — beim Start der App. `ordner` enthaelt
    /// die `.lproj`-Ordner des Pakets (aus den Assets entpackt), `sprache` ist
    /// die Geraetesprache. Siehe `Paketsprache` im Paket.
    public static func paketspracheSetzen(ordner: String, sprache: String) {
        #if os(Android)
        Paketsprache.ordner = ordner
        Paketsprache.sprache = sprache
        #endif
    }

    // MARK: Verbinden und Anmelden

    /// Wie `AppModel.connect(to:)`: Adresse normalisieren, bei `https` ohne
    /// Antwort einmal `http` versuchen. Antwort: `{"name","version","adresse"}`.
    public func verbinden(adresse: String) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let url = AppModelURLNormalizer.normalize(adresse) else { throw Kernfehler.adresse(adresse) }
            var kandidaten = [url]
            if let anders = AppModelURLNormalizer.andersHerum(url) { kandidaten.append(anders) }
            var letzter: Error = Kernfehler.adresse(adresse)
            for kandidat in kandidaten {
                let c = neuerClient(kandidat)
                do {
                    let info = try await c.publicSystemInfo()
                    setzen(c, Bildadresse(basis: kandidat, token: nil))
                    return try json(Serverantwort(name: info.serverName ?? kandidat.host() ?? "",
                                                  version: info.version ?? "",
                                                  adresse: kandidat.absoluteString))
                } catch { letzter = error }
            }
            throw letzter
        }
    }

    /// Antwort: die Sitzung als JSON — Kotlin legt sie verschluesselt ab und gibt
    /// sie beim naechsten Start an ``sitzungSetzen(json:)`` zurueck.
    public func anmelden(benutzer: String, passwort: String) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let c = client else { throw Kernfehler.nichtVerbunden }
            let s = try await c.authenticate(username: benutzer, password: passwort)
            let neu = neuerClient(s.serverURL, s)
            setzen(neu, Bildadresse(basis: s.serverURL, token: s.accessToken), s)
            return try json(s)
        }
    }

    /// Wie `AppModel` nach dem Wiederherstellen: gilt das Merkmal noch? `false` **nur** bei 401/403
    /// (`sitzungGiltNoch`) — ohne Netz heisst es „weiss nicht", und dann wird niemand abgemeldet.
    public func sitzungGilt() async -> Bool {
        guard let c = client else { return true }
        return await c.sitzungGiltNoch()
    }

    public func sitzungSetzen(json text: String) throws {
        let s = try JSONDecoder().decode(Session.self, from: Data(text.utf8))
        setzen(neuerClient(s.serverURL, s), Bildadresse(basis: s.serverURL, token: s.accessToken), s)
    }

    // MARK: Quick Connect und weitere Server

    private func anmeldeclient(_ neuerServer: Bool) -> JellyfinClient? {
        sperre.lock(); defer { sperre.unlock() }
        return neuerServer ? _aufnahme : _client
    }

    /// Prueft einen weiteren Server, ohne die laufende Sitzung anzufassen. Antwort wie ``verbinden(adresse:)``.
    public func aufnahmeVerbinden(adresse: String) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let url = AppModelURLNormalizer.normalize(adresse) else { throw Kernfehler.adresse(adresse) }
            var kandidaten = [url]
            if let anders = AppModelURLNormalizer.andersHerum(url) { kandidaten.append(anders) }
            var letzter: Error = Kernfehler.adresse(adresse)
            for kandidat in kandidaten {
                let c = neuerClient(kandidat)
                do {
                    let info = try await c.publicSystemInfo()
                    sperre.lock(); _aufnahme = c; sperre.unlock()
                    return try json(Serverantwort(name: info.serverName ?? kandidat.host() ?? "", version: info.version ?? "",
                                                  adresse: kandidat.absoluteString))
                } catch { letzter = error }
            }
            throw letzter
        }
    }

    public func aufnahmeAbbrechen() {
        sperre.lock(); _aufnahme = nil; _quickconnect = nil; sperre.unlock()
    }

    /// Anmelden am aufgenommenen Server. Die Sitzung kommt zurueck; aktiv wird sie erst ueber `sitzungSetzen`.
    public func aufnahmeAnmelden(benutzer: String, passwort: String) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let c = anmeldeclient(true) else { throw Kernfehler.nichtVerbunden }
            return try json(try await c.authenticate(username: benutzer, password: passwort))
        }
    }

    /// Holt einen Code — am verbundenen oder am aufgenommenen Server. Antwort: der Code.
    public func quickConnectStarten(neuerServer: Bool) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let c = anmeldeclient(neuerServer) else { throw Kernfehler.nichtVerbunden }
            do {
                let vorgang = try await c.quickConnectStarten()
                sperre.lock(); _quickconnect = vorgang; sperre.unlock()
                return vorgang.code
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // swift-java macht aus dem Fehler `String(describing:)` — bei einem
                // Netzfehler also `Error Domain=NSURLErrorDomain …`. Kotlin zeigt die
                // Nachricht an; sie muss deshalb schon hier lesbar sein.
                throw Kerntext(kernFehlertext(error))
            }
        }
    }

    /// **Wartet auf die Freigabe — `Quickconnectwarten` aus dem Paket, nicht mehr in Kotlin.** Frist an
    /// der Uhr, Nachfrage im Takt und nach der Rueckkehr in die App sofort; ein Netzfehler beendet das
    /// Warten nicht (88f7808). Die Restzeit steht derweil in ``quickConnectRest()``.
    ///
    /// Antwort: `freigegeben` (dann ``quickConnectAnmelden(neuerServer:)``), leer, wenn abgebrochen,
    /// sonst der Satz fuer den Nutzer (`Quickconnectfrist.schlusstext`).
    public func quickConnectWarten(neuerServer: Bool) async -> String {
        sperre.lock(); let vorgang = _quickconnect; sperre.unlock()
        guard let c = anmeldeclient(neuerServer), let vorgang else {
            return Quickconnectfrist.schlusstext(letzte: .abgelaufen)
        }
        let aufgabe = Task { [self] () -> String in
            for await ereignis in c.quickConnectWarten(vorgang) {
                switch ereignis {
                case let .rest(sekunden):
                    sperre.lock(); _quickconnectRest = sekunden; sperre.unlock()
                case .freigegeben:
                    return "freigegeben"
                case let .ende(letzte):
                    sperre.lock(); _quickconnectRest = 0; sperre.unlock()
                    return Quickconnectfrist.schlusstext(letzte: letzte)
                }
            }
            return ""
        }
        sperre.lock()
        _quickconnectRest = Quickconnectfrist.sekunden
        _quickconnectWarten?.aufgabe()
        _quickconnectWarten = (vorgang.code, { aufgabe.cancel() })
        sperre.unlock()
        return await aufgabe.value
    }

    /// Sekunden bis zum Fristende, fuer die Anzeige — gesetzt von ``quickConnectWarten(neuerServer:)``.
    public func quickConnectRest() -> Int {
        sperre.lock(); defer { sperre.unlock() }
        return _quickconnectRest
    }

    /// Die Seite ist zu: nicht weiter nachfragen, sonst meldet eine spaete Freigabe einen ploetzlich an.
    /// Nur, wenn noch das Warten auf `code` laeuft — ein neuer Code hat seine eigene Abfrage.
    public func quickConnectWartenBeenden(code: String) {
        sperre.lock(); defer { sperre.unlock() }
        guard let w = _quickconnectWarten, w.code == code else { return }
        w.aufgabe()
        _quickconnectWarten = nil
    }

    /// Der freigegebene Code wird zur Sitzung. Am verbundenen Server gilt sie sofort, wie nach ``anmelden(benutzer:passwort:)``.
    public func quickConnectAnmelden(neuerServer: Bool) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            sperre.lock(); let vorgang = _quickconnect; sperre.unlock()
            guard let c = anmeldeclient(neuerServer), let vorgang else { throw Kernfehler.nichtVerbunden }
            let s: Session
            do { s = try await c.anmeldenMitQuickConnect(vorgang) } catch { throw Kerntext(kernFehlertext(error)) }
            sperre.lock(); _quickconnect = nil; sperre.unlock()
            if !neuerServer { setzen(neuerClient(s.serverURL, s), Bildadresse(basis: s.serverURL, token: s.accessToken), s) }
            return try json(s)
        }
    }

    /// `[sekunden, takt]` — `Quickconnectfrist`, eine Quelle fuer alle Plattformen.
    public static func quickConnectFrist() -> String {
        kodiert([Quickconnectfrist.sekunden, Quickconnectfrist.takt])
    }

    // MARK: Konten — die Regeln stehen in `Kontenbund`

    private static func bundLesen(_ roh: String) -> Kontenbund? {
        try? JSONDecoder().decode(Kontenbund.self, from: Data(roh.utf8))
    }
    private static func sitzungLesen(_ roh: String) -> Session? {
        try? JSONDecoder().decode(Session.self, from: Data(roh.utf8))
    }

    /// Nimmt eine Sitzung ins Buendel auf: dasselbe Konto ersetzt, ein neues kommt dazu und gilt.
    public static func bundAufnehmen(sitzung: String, bund: String) -> String {
        guard let s = sitzungLesen(sitzung) else { return bund }
        return kodiert(Kontenbund.aufnehmen(s, in: bundLesen(bund)).bund)
    }

    public static func bundWechseln(bund: String, kennung: String) -> String {
        guard var b = bundLesen(bund) else { return bund }
        b.wechseln(zu: kennung)
        return kodiert(b)
    }

    /// Ohne das Konto — leer, wenn es das letzte war.
    public static func bundEntfernt(bund: String, kennung: String) -> String {
        guard let neu = bundLesen(bund)?.entfernt(kennung) else { return "" }
        return kodiert(neu)
    }

    /// Die geltende Sitzung als JSON; leer, wenn das Buendel nicht lesbar ist.
    public static func bundAktives(bund: String) -> String {
        bundLesen(bund).map { kodiert($0.aktives) } ?? ""
    }

    public static func bundAktiveKennung(bund: String) -> String {
        bundLesen(bund)?.aktives.kontoschluessel ?? ""
    }

    /// Umzug: die einzelne Sitzung von frueher als Buendel.
    public static func bundAusSitzung(sitzung: String) -> String {
        sitzungLesen(sitzung).map { kodiert(Kontenbund($0)) } ?? ""
    }

    /// Fuer die Kontokarten: je Server seine Konten, das geltende markiert, mit Bild.
    public static func bundUebersicht(bund: String) -> String {
        guard let b = bundLesen(bund) else { return "[]" }
        let aktiv = b.aktives.kontoschluessel
        return kodiert(b.server.map { url in
            let konten = b.konten(auf: url)
            return Serverkartenantwort(
                adresse: url.absoluteString, host: url.host() ?? url.absoluteString,
                aktiv: konten.contains { $0.kontoschluessel == aktiv },
                konten: konten.map { s in
                    Kontoantwort(kennung: s.kontoschluessel, name: s.userName, aktiv: s.kontoschluessel == aktiv,
                                 bild: Bildadresse(basis: s.serverURL, token: s.accessToken).benutzer(s.userID, kante: 120)?.absoluteString)
                })
        })
    }

    // MARK: Startseite

    /// Fertige Reihen in der eingestellten Folge. `abgelegt`/`aus` sind die
    /// Namen aus den Einstellungen (wie `startReihen`/`startAus` auf Apple).
    public func startseite(getrennt: Bool, abgelegt: [String], aus: [String],
                           filmBibliothek: String, serienBibliothek: String,
                           gattungen: [String], alsChips: Bool) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let c = client, let a = adressen else { throw Kernfehler.nichtVerbunden }
            // Ohne gemerkte Wahl die erste Sammlung ihrer Art — wie
            // `AppModel.gewaehlteBibliothek(art:)` auf Apple.
            var filme = filmBibliothek.isEmpty ? nil : filmBibliothek
            var serien = serienBibliothek.isEmpty ? nil : serienBibliothek
            if getrennt, filme == nil || serien == nil, let sammlungen = try? await c.userViews() {
                filme = filme ?? sammlungen.first { $0.collectionType == "movies" }?.id
                serien = serien ?? sammlungen.first { $0.collectionType == "tvshows" }?.id
            }
            let stand = await Startseitenlader.laden(von: c, .init(
                getrennt: getrennt, filmBibliothek: filme, serienBibliothek: serien,
                gattungen: alsChips ? nil : gattungen))
            // **Die Marke nur auf den Reihen, die tvOS mit ihr zeigt.** `HomeView.Streifen`
            // (weiterschauen, naechsteFolge) kennt sie nicht — nur der Reihenbau aus
            // `Titelreihen.swift` (`Reihe`), fuer Neuzugaenge, neue Filme/Serien und die
            // Genre-Reihen. Sonst haette Kotlin diese Ausnahme selbst nachbilden muessen.
            let inhalt: [Startreihe: (quer: Bool, neu: Bool, marke: Bool, items: [Item])] = [
                .weiterschauen: (true, false, false, stand.weiterschauen ?? []),
                .naechsteFolge: (false, false, false, stand.naechsteFolge ?? []),
                .neuzugaenge: (false, true, true, stand.zuletzt ?? []),
                .neueFilme: (false, true, true, stand.neueFilme ?? []),
                .neueSerien: (false, true, true, stand.neueSerien ?? []),
            ]
            var reihen: [Reihenantwort] = Startreihenfolge
                .sichtbar(abgelegt: abgelegt, aus: Set(aus), getrennt: getrennt)
                .compactMap { r in
                    guard let (quer, neu, marke, items) = inhalt[r], !items.isEmpty else { return nil }
                    return Reihenantwort(titelSchluessel: r.reihentitel, name: nil, quer: quer,
                                         kacheln: items.map { kachel($0, neuzugang: neu, mitMarke: marke, a) })
                }
            reihen += stand.gattungsreihen.map {
                Reihenantwort(titelSchluessel: nil, name: $0.name, quer: false,
                              kacheln: $0.items.map { kachel($0, neuzugang: false, mitMarke: true, a) })
            }
            return try json(Startseitenantwort(reihen: reihen, gestoert: stand.gestoert))
        }
    }

    /// Dieselben Zeilen wie `HomeView.Kachel` auf dem iPhone: `neuzugangszeile`
    /// in den Neuzugangsreihen, sonst `folgenkuerzel` — beide aus dem Paket. Die Marke
    /// kommt aus derselben `Anzeigeregeln.kachelmarke` wie `rasterkachel(_:_:)`.
    ///
    /// **`angabenzeile`/`restzeit`/`gesehen` fuer die Kopfzone der Startseite** —
    /// dieselben Angaben wie `Kopfauskunft.angabenzeile`/`Restzeitmarke` auf tvOS. Sie
    /// stehen fertig in jeder Kachel, statt dass Kotlin bei jedem Fokuswechsel eine
    /// zweite Anfrage stellen muesste (die Fassade spricht in fertigen Antworten).
    private func kachel(_ i: Item, neuzugang: Bool, mitMarke: Bool, _ a: Bildadresse) -> Kachelantwort {
        let (marke, zahl): (String?, Int) = mitMarke ? {
            switch Anzeigeregeln.kachelmarke(art: i.type, staffeln: i.childCount,
                                             gesehen: i.userData?.played,
                                             offeneFolgen: i.userData?.unplayedItemCount) {
            case .gesehen?: return ("gesehen", 0)
            case .offen(let n)?: return ("offen", n)
            case .staffeln(let n)?: return ("staffeln", n)
            case .none: return (nil, 0)
            }
        }() : (nil, 0)
        var angaben: [String] = []
        if i.type == "Episode", let kuerzel = i.folgenkuerzel { angaben.append(kuerzel) }
        if let jahr = i.productionYear { angaben.append(String(jahr)) }
        if let sekunden = i.runtimeSeconds, sekunden > 0 { angaben.append(laufzeit(sekunden)) }
        return Kachelantwort(
            id: i.id, name: i.seriesName ?? i.name, typ: i.type ?? "",
            unterzeile: neuzugang ? i.neuzugangszeile : i.folgenkuerzel,
            plakat: Bildwahl.hochkant(i, adressen: a)?.absoluteString,
            quer: Bildwahl.quer(i, adressen: a)?.url.absoluteString,
            fortschritt: i.gesehenerAnteil, marke: marke, markenzahl: zahl,
            angabenzeile: angaben.isEmpty ? nil : angaben.joined(separator: " · "),
            restzeit: i.restzeitText, gesehen: i.istGesehen,
            folgenname: i.type == "Episode" ? i.name : nil,
            // **Nur fuer Android TV** (`TvWeiterschauenRegal.kt`, Watch-Next-Reihe): die
            // Fortschrittsanzeige dort will echte Millisekunden, nicht nur den Anteil, sonst
            // zeigt der Systemstarter eine erfundene Restzeit an. tvOS braucht das nicht — sein
            // Top Shelf (`RegalAnbieter.swift`) kennt nur `playbackProgress`, einen Anteil.
            laufzeitSekunden: i.runtimeSeconds, positionSekunden: i.fortsetzenAb,
            // **Nur fuer Android TVs Kopfzone** — `Kopfauskunft` auf tvOS zeigt Bewertung und
            // Freigabe auf der Startseite genauso wie auf der Detailseite (sie liest direkt vom
            // `Item`), und die Beschreibung stand hier bisher gar nicht in der Antwort.
            bewertung: i.communityRating, freigabe: i.officialRating, beschreibung: i.beschreibung,
            kulisse: Kern.kulisse(i, folge: nil, adressen: a))
    }

    // MARK: Bibliothek

    /// Die Sammlungen einer Art (`movies`, `tvshows`) — `AppModel.bibliotheken(art:)`.
    /// Antwort: `[{"id","name"}]`.
    public func bibliotheken(art: String) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let c = client else { throw Kernfehler.nichtVerbunden }
            let sammlungen = try await c.userViews().filter { $0.collectionType == art }
            return try json(sammlungen.map { Sammlungsantwort(id: $0.id, name: $0.name) })
        }
    }

    /// Der Name des Servers fuer die Zeile unter dem Titel — leer, wenn er keinen nennt.
    public func servername() async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let c = client else { throw Kernfehler.nichtVerbunden }
            return try await c.publicSystemInfo().serverName ?? ""
        }
    }

    /// Eine Seite einer Bibliothek — dieselbe Abfrage wie `AppModel.items(in:art:sortierung:filter:ab:)`.
    /// `sortierung`/`filter` sind die `rawValue`s aus dem Paket; Unbekanntes faellt auf die Vorgabe.
    public func bibliothekSeite(bibliothek: String, art: String, sortierung: String, filter: String,
                                ab: Int, anzahl: Int) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let c = client, let a = adressen else { throw Kernfehler.nichtVerbunden }
            let s = Sortierung(rawValue: sortierung) ?? .name
            let f = Bibliotheksfilter(rawValue: filter) ?? .alle
            let antwort = try await c.items(parentID: bibliothek, limit: anzahl, startIndex: ab,
                                            sortBy: s.feld, sortOrder: s.richtung,
                                            filters: f.jellyfinFilter, istGesehen: f.istGesehen,
                                            recursive: Bibliotheksgattung.rekursiv(zu: art),
                                            includeItemTypes: Bibliotheksgattung.typen(zu: art))
            return try json(Rasterseitenantwort(titel: antwort.items.map { rasterkachel($0, a) },
                                                gesamt: antwort.totalRecordCount))
        }
    }

    // MARK: Titel

    /// Alles fuer die Titelseite in einem Zug — `ItemDetailView.task`: Titel und Abspielplan
    /// parallel. Aehnliches und Extras kommen getrennt (``titelUmfeld(id:)``), damit die Seite
    /// nicht auf sie wartet.
    public func titel(id: String) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let c = client, let a = adressen else { throw Kernfehler.nichtVerbunden }
            let grenze = profilBitrate
            async let frisch = c.item(id: id)
            async let geplant = try? c.playbackPlan(for: id, profile: .vlc(maxBitrate: grenze))
            let i = try await frisch
            let p = await geplant
            let datei = p?.quelle.map { q -> Dateiantwort in
                let spuren = Dateiangaben.untertitelspuren(q)
                return Dateiantwort(
                    container: Dateiangaben.container(q),
                    video: Dateiangaben.videospur(q).map { Dateiangaben.video($0, q) },
                    ton: Array((q.mediaStreams ?? []).filter { $0.type == "Audio" }.prefix(2).map(\.kurz)),
                    untertitel: Dateiangaben.untertitel(spuren), hatUntertitel: !spuren.isEmpty)
            }
            func personenbild(_ person: Person) -> String? {
                let u: URL? = a.bauen(itemID: person.id, marke: person.primaryImageTag, mass: .hoechstensHoch(220))
                return u?.absoluteString
            }
            let ab = i.fortsetzenAb
            // **Jahr und Laufzeit ohne Gattung** — der Fernseher zeigt die Gattung
            // in dieser Zeile nicht (`Detailkopf.angabenzeile` auf tvOS), anders
            // als `nebenzeile` fuers Telefon. Dieselben Teile wie dort, nur ohne
            // den dritten.
            let jahrLaufzeit = [i.productionYear.map { String($0) },
                                i.runtimeSeconds.flatMap { $0 > 0 ? laufzeit($0) : nil }]
                .compactMap { $0 }.joined(separator: " · ")
            return try json(Titelantwort(
                id: i.id, name: i.name, typ: i.type ?? "", nebenzeile: i.nebenzeile,
                jahrLaufzeit: jahrLaufzeit,
                kopfbild: Bildwahl.kopfMitErsatz(i, folge: nil, adressen: a)?.absoluteString,
                bewertung: i.communityRating, freigabe: i.officialRating,
                planDa: p != nil, lossless: p?.isLossless ?? false, methode: p.map { $0.method.rawValue },
                fortsetzenAb: ab, fortsetzenText: ab.map { zeitText($0) },
                beschreibung: i.beschreibung, regie: i.regie,
                darsteller: Array(i.darsteller.prefix(12)).map {
                    Personantwort(id: $0.id, name: $0.name, rolle: $0.role, bild: personenbild($0))
                },
                gemerkt: i.userData?.isFavorite ?? false, gesehen: i.userData?.played ?? false,
                trailer: i.remoteTrailers?.first?.url.map { "\($0)" }, datei: datei,
                kulisse: Kern.kulisse(i, folge: nil, adressen: a)))
        }
    }

    // MARK: Serie

    /// Die Serienseite — `SeriesDetailView.laden()` samt `StaffelZiel`. Ist `id` eine **Folge**,
    /// wird sie frisch geholt (eine Kachel kann eine veraltete `seasonId` tragen), ihre Serie
    /// geladen und ihre Staffel vorgewaehlt.
    ///
    /// Vorwahl ueber `Staffelwahlregel.waehle` wie auf Apple: Staffel der Folge → Nummer der Folge →
    /// Staffel des Stands → Nummer des Stands → erste. **Die Nummer zaehlt mit**: der Server laesst
    /// `SeasonId` manchmal weg, und ein Vergleich nur ueber die ID fiel still auf die erste Staffel.
    public func serie(id: String) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let c = client, let a = adressen else { throw Kernfehler.nichtVerbunden }
            let erstes = try await c.item(id: id)
            var hinweisID: String?
            var hinweisNummer: Int?
            let serie: Item
            if erstes.type == "Episode", let serienID = erstes.seriesId {
                hinweisID = erstes.seasonId
                hinweisNummer = erstes.parentIndexNumber
                serie = try await c.item(id: serienID)
            } else {
                serie = erstes
            }
            async let offen = c.standInSerie(serie.id)
            async let geholt = try? c.staffeln(seriesID: serie.id)
            let stand = await offen
            let staffeln = await geholt ?? []
            // A10 aus dem Paket: erst der Hinweis (Kennung, dann Nummer), dann der Stand. Die eigene
            // Kette hier pruefte die Kennung des Stands vor der Nummer des Hinweises — kam eine Folge
            // ohne `SeasonId`, stand die laufende Staffel da statt ihrer (Audit T2-M4).
            let gewaehlt = Staffelwahlregel.waehle(aus: staffeln, hinweisID: hinweisID,
                                                   hinweisNummer: hinweisNummer, stand: stand)
            // **Der Plan kommt getrennt** (`plan(id:)`), wie auf iOS nach dem Stand: `PlaybackInfo`
            // braucht bei Dateien, die der Server noch nicht vermessen hat, Sekunden — und die
            // ganze Seite wartete darauf. Deshalb waren manche Serien sofort da, andere nicht.
            // Die Besetzung der Folge, die als Naechstes laeuft — sonst die der Serie.
            let leute = (stand?.darsteller.isEmpty == false ? stand?.darsteller : nil) ?? serie.darsteller
            return try json(Serienantwort(
                id: serie.id, name: serie.name,
                jahr: serie.productionYear.map { String($0) },
                // Eine Staffel mit ihrem Namen; sonst die Zahl — `childCount` nur, solange die Liste fehlt.
                staffelzeile: staffeln.count == 1 ? staffeln.first?.name : nil,
                staffelzahl: staffeln.count == 1 ? nil : (staffeln.isEmpty ? serie.childCount : staffeln.count),
                gattungen: serie.genres.flatMap { $0.isEmpty ? nil : $0.prefix(2).joined(separator: ", ") },
                // `stand` ist die naechste oder erste Folge — dieselbe, die iOS fuer den Ersatz sucht.
                kopfbild: Bildwahl.kopfMitErsatz(serie, folge: stand, adressen: a)?.absoluteString,
                bewertung: serie.communityRating, freigabe: serie.officialRating, beschreibung: serie.beschreibung,
                gemerkt: serie.userData?.isFavorite ?? false, gesehen: serie.userData?.played ?? false,
                trailer: serie.remoteTrailers?.first?.url.map { "\($0)" },
                planDa: false, lossless: false, methode: nil,
                stand: stand.map { f in
                    Standantwort(id: f.id, fortsetzen: (f.userData?.playbackPositionTicks ?? 0) > 0,
                                 restzeit: f.restzeitText, fortschritt: f.userData?.playedPercentage.map { $0 / 100 },
                                 staffel: f.parentIndexNumber, folge: f.indexNumber, ab: f.fortsetzenAb)
                },
                knopftext: Item.serienknopf(folge: stand, laedt: false),
                staffeln: staffeln.map { Staffelantwort(id: $0.id, name: $0.name) },
                gewaehlt: gewaehlt?.id,
                darsteller: leute.map { p in
                    let u: URL? = a.bauen(itemID: p.id, marke: p.primaryImageTag, mass: .hoechstensHoch(220))
                    return Personantwort(id: p.id, name: p.name, rolle: p.role, bild: u?.absoluteString)
                },
                kulisse: Kern.kulisse(serie, folge: stand, adressen: a)))
        }
    }

    /// **Die Kulisse fuer Android TV — eine Adresse fuer Startseite, Film- und Serienseite.**
    ///
    /// Vorlage: `HomeView.kulissenURL` und `DetailView`/`SerienView` auf tvOS, dort
    /// `querbildURL(for:breite: 1600) ?? kopfbildURL(for:)` auf **jeder** der drei Seiten.
    /// Vorher las die Startseite `quer` (600 breit, fuer die Kachel) und die Detailseite
    /// `kopfbild` (1200 breit, andere Kette) — zwei Adressen fuer dasselbe Bild: auf Start
    /// pixelig, beim Oeffnen kein Treffer im Bildspeicher, und `TvBildgrund` rechnete fuer die
    /// zweite Adresse einen eigenen, manchmal anderen Farbton. 1600 passt zur Kulisse auf einem
    /// 1080p-Fernseher (590 dp ≈ 1180 px).
    static func kulisse(_ item: Item, folge: Item?, adressen a: Bildadresse) -> String? {
        (Bildwahl.quer(item, adressen: a, breite: 1600)?.url
            ?? Bildwahl.kopfMitErsatz(item, folge: folge, adressen: a))?.absoluteString
    }

    /// Die Folgen einer Staffel — Zeilen wie `Folgenzeile`: „3. Name", Restzeit oder Laufzeit,
    /// der Balken nur, solange nicht gesehen.
    public func folgen(serie: String, staffel: String) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let c = client else { throw Kernfehler.nichtVerbunden }
            let liste = try await c.folgen(seriesID: serie, seasonID: staffel.isEmpty ? nil : staffel)
            var zeilen: [Folgenantwort] = []
            for f in liste {
                let gesehen = f.userData?.played ?? false
                let zeit: String? = Anzeigeregeln.laufzeitZeigen(sekunden: f.runtimeSeconds)
                    ? (f.restzeitText ?? "\(Int((f.runtimeSeconds ?? 0) / 60)) min") : nil
                let bild = await c.imageURL(for: f, maxHeight: 220)
                zeilen.append(Folgenantwort(
                    id: f.id, titel: f.indexNumber.map { "\($0). \(f.name)" } ?? f.name, unterzeile: zeit,
                    bild: bild?.absoluteString,
                    fortschritt: gesehen ? nil : f.userData?.playedPercentage.map { $0 / 100 }, gesehen: gesehen,
                    ab: f.fortsetzenAb,
                    // **Rohe Teile fuer den Fernseher.** Die Kachel dort traegt das
                    // Katalogformat „F2 · Titel" (`Folgenstreifen.kopfzeile` auf
                    // tvOS), das Telefon bleibt bei „2. Titel" — deshalb hier
                    // zusaetzlich, statt `titel`/`unterzeile` zu aendern und beide
                    // Plattformen zu verstellen.
                    name: f.name, nummer: f.indexNumber,
                    laufzeitMin: (f.runtimeSeconds ?? 0) > 0 ? Int((f.runtimeSeconds ?? 0) / 60) : nil,
                    restzeit: f.restzeitText))
            }
            return try json(zeilen)
        }
    }

    /// Die Folgen der laufenden Staffel, aus dem Player heraus — `Folgenblatt` auf tvOS. Serie
    /// und Staffel kommen vom geladenen Titel selbst; Kotlin muss dafuer keine eigenen Kennungen
    /// mitfuehren. Leer ohne laufende Wiedergabe oder bei einem Film (keine `seriesId`).
    public func wiedergabeFolgen() async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            sperre.lock(); let item = _wiedergabe?.item; sperre.unlock()
            guard let item, let serie = item.seriesId else { return "[]" }
            return try await folgen(serie: serie, staffel: item.seasonId ?? "")
        }
    }

    /// Nur der Abspielplan — fuer die Belegzeile, nachgereicht. Leer, wenn es keinen gibt.
    public func plan(id: String) async -> String {
        guard let c = client else { return "{}" }
        let geplant = (try? await c.playbackPlan(for: id, profile: .vlc(maxBitrate: profilBitrate))) ?? nil
        guard let p = geplant else { return "{}" }
        return Self.kodiert(Planantwort(lossless: p.isLossless, methode: p.method.rawValue))
    }

    /// **Trickplay-Vorschau beim Spulen** — Vorlage `Trickplaybilder`/`Trickplay` (Paket). Anders als
    /// dort holt Kotlin die Kachelblaetter selbst per Coil (ganz normale Bilder); hier steht nur die
    /// Rechnung: ob es welche gibt, ihr Raster, und die Adresse eines Blatts. Leer ohne laufende
    /// Wiedergabe oder ohne Trickplay am Server.
    public func trickplayAngabe() async -> String {
        guard let c = client, let w = sperreLesen({ _wiedergabe }),
              let t = await c.trickplay(itemID: w.item.id, mediaSourceID: w.plan.mediaSourceID)
        else { return "{}" }
        return Self.kodiert(Trickplayantwort(breite: t.breite, hoehe: t.hoehe, kachelnBreit: t.kachelnBreit,
                                             kachelnHoch: t.kachelnHoch, anzahl: t.anzahl, intervall: t.intervall))
    }

    /// Die Adresse eines Kachelblatts — leer ohne laufende Wiedergabe.
    public func trickplayAdresse(breite: Int, blatt: Int) async -> String {
        guard let c = client, let w = sperreLesen({ _wiedergabe }) else { return "" }
        return await c.trickplayURL(itemID: w.item.id, mediaSourceID: w.plan.mediaSourceID,
                                    breite: breite, blatt: blatt)?.absoluteString ?? ""
    }

    // MARK: Konto und Server

    /// Name und Fassung des Servers — fuer Profil und Einstellungen.
    public func serverauskunft() async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let c = client else { throw Kernfehler.nichtVerbunden }
            let info = try await c.publicSystemInfo()
            return try json(Serverantwort(name: info.serverName ?? "", version: info.version ?? "", adresse: ""))
        }
    }

    /// Meldet beim Server ab und vergisst die Sitzung. Die Ablage leert Kotlin.
    public func abmelden() async {
        if let c = client { await c.abmelden() }
        setzen(nil, nil, nil)
    }

    /// Den Code eines anderen Geraets freigeben — `QuickConnectView`. Leer heisst: erledigt.
    /// „Wer schaut?" — die oeffentlichen Benutzer, ohne Anmeldung. Hat der Server die Liste
    /// abgeschaltet, ist sie leer; dann wird eben getippt.
    public func oeffentlicheBenutzer(neuerServer: Bool) async -> String {
        sperre.lock(); let c = neuerServer ? _aufnahme : _client; sperre.unlock()
        guard let c, let liste = try? await c.oeffentlicheBenutzer() else { return "[]" }
        var antwort: [Kontoantwort] = []
        for b in liste {
            let bild = await c.benutzerbild(b, kante: 180)
            antwort.append(Kontoantwort(kennung: b.id, name: b.name, aktiv: false, bild: bild?.absoluteString))
        }
        return Self.kodiert(antwort)
    }

    public func quickConnectFreigeben(code: String) async -> String {
        await erledigen { try await $0.quickConnectFreigeben(code: code) }
    }

    /// Die Genres des Servers — fuer „Genre hinzufuegen".
    public func gattungen() async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let c = client else { throw Kernfehler.nichtVerbunden }
            return try json(try await c.gattungen())
        }
    }

    // MARK: Einstellungen — die Werte stehen im Paket

    public static func bitratenstufen() -> String {
        kodiert(Bitrate.stufen.map { Wahlantwort(wert: String($0.wert), text: Bitrate.text($0.wert)) })
    }

    public static func spannen() -> String { kodiert(Spanne.stufen.map(\.wert)) }

    /// Mit leerer Beschriftung „Wie die Datei" (Ton), sonst diese als erster Eintrag (Untertitel: „Aus").
    public static func sprachen(aus: String) -> String {
        kodiert((aus.isEmpty ? Sprachwahl.alle : Sprachwahl.alle(aus: aus)).map { Wahlantwort(wert: $0.wert, text: $0.name) })
    }

    public static func pufferstufen() -> String {
        kodiert(Pufferstufe.allCases.map { Pufferantwort(wert: $0.rawValue, text: $0.name, netz: $0.netzvorlaufMillisekunden) })
    }


    /// Die Reihen der Startseite in der geltenden Folge, nur die zur Neuzugangs-Einstellung passenden.
    /// `text` ist der deutsche Listenname — Kotlin uebersetzt ihn.
    public static func startreihen(abgelegt: [String], getrennt: Bool) -> String {
        kodiert(Startreihenfolge.geltend(abgelegt: abgelegt).filter { $0.passt(getrennt: getrennt) }
            .map { Wahlantwort(wert: $0.rawValue, text: $0.listenname) })
    }

    public static func startreiheVerschoben(was: String, um: Int, abgelegt: [String], getrennt: Bool) -> String {
        guard let reihe = Startreihe(rawValue: was) else { return kodiert(abgelegt) }
        return kodiert(Startreihenfolge.verschoben(reihe, um: um, abgelegt: abgelegt, getrennt: getrennt))
    }

    /// Mit sortierten Schluesseln — so ist dasselbe Buendel immer dieselbe Zeichenkette.
    private static func kodiert<T: Encodable>(_ wert: T) -> String {
        let kodierer = JSONEncoder()
        kodierer.outputFormatting = [.sortedKeys]
        return (try? kodierer.encode(wert)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    // MARK: Genre

    /// Die Titel eines Genres — `GenreView`: bis zu 200, das neueste zuerst, Filme und Serien.
    public func genre(name: String) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let c = client, let a = adressen else { throw Kernfehler.nichtVerbunden }
            guard let titel = await c.titel(gattung: name, limit: 200) else { throw URLError(.cannotLoadFromNetwork) }
            return try json(titel.map { rasterkachel($0, a) })
        }
    }

    // MARK: Merkliste

    /// Eine Seite der Merkliste — `AppModel.gemerkte`: Favoriten ueber alle Bibliotheken
    /// (rekursiv, **immer mit Gattungen** — ohne sie kamen leere virtuelle Ordner als Titel),
    /// dieselben Kacheln wie die Bibliothek. `gattung` ist `Merkgattung.art`, leer heisst beides.
    public func merkliste(gattung: String, sortierung: String, ab: Int, anzahl: Int) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let c = client, let a = adressen else { throw Kernfehler.nichtVerbunden }
            let art = Merkgattung.zu(art: gattung.isEmpty ? nil : gattung)
            let s = Sortierung(rawValue: sortierung) ?? .neueste
            let antwort = try await c.items(limit: anzahl, startIndex: ab, sortBy: s.feld, sortOrder: s.richtung,
                                            filters: ["IsFavorite"], recursive: true, includeItemTypes: art.typen)
            let titel = ab == 0 ? Listenregeln.ohneDoppelte(antwort.items) : antwort.items
            return try json(Rasterseitenantwort(titel: titel.map { rasterkachel($0, a) }, gesamt: antwort.totalRecordCount))
        }
    }

    /// „Filme & Serien", „Filme", „Serien" — `wert` ist die Art, leer fuer beides.
    public static func merkgattungen() -> String {
        kodiert(Merkgattung.allCases.map { Wahlantwort(wert: $0.art ?? "", text: $0.beschriftung) })
    }

    // MARK: Suche

    /// `SucheView.suchen` ohne Seerr: `JellyfinClient.suche` (nur Filme und Serien), ohne doppelte
    /// Kennungen, die Zeile unter dem Plakat aus `trefferauskunft`. Unter der Mindestlaenge leer.
    public func suche(begriff: String) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let c = client, let a = adressen else { throw Kernfehler.nichtVerbunden }
            let sauber = begriff.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Anzeigeregeln.suchbegriffTaugt(sauber) else { return "[]" }
            let treffer = Listenregeln.ohneDoppelte(try await c.suche(sauber))
            return try json(treffer.map { i in
                let k = rasterkachel(i, a)
                return Rasterkachelantwort(id: k.id, titel: k.titel, typ: k.typ, unterzeile: i.trefferauskunft,
                                           plakat: k.plakat, fortschritt: k.fortschritt, marke: k.marke, markenzahl: k.markenzahl)
            })
        }
    }

    /// Ab wann gesucht wird — dieselbe Regel auf allen Plattformen.
    public static func suchbegriffTaugt(begriff: String) -> Bool { Anzeigeregeln.suchbegriffTaugt(begriff) }

    /// Der Verlauf liegt als eine Zeichenkette in der Ablage; Regeln (acht, ohne Doppelte, neu vorn) im Paket.
    public static func suchverlaufSchluessel() -> String { Suchverlauf.schluessel }
    public static func suchverlaufMerken(wort: String, roh: String) -> String { Suchverlauf.merken(wort, in: roh) }
    public static func suchverlaufListe(roh: String) -> String {
        (try? JSONEncoder().encode(Suchverlauf.liste(roh))).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    // MARK: Wiedergabe

    /// Oeffnet einen Titel zum Abspielen — `AppModel.plan(for:)`, die Abschnitte und die
    /// naechste Folge in einem Zug. **Die Faehigkeiten werden vor jedem Start neu gemeldet:**
    /// nach einem Neustart des Servers brach die Uebernahme sonst still.
    ///
    /// Jeder geoeffnete Player bekommt einen eigenen `Folgenwechsel` — dessen `geschlossen` ist endgueltig.
    public func wiedergabeOeffnen(id: String) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            let w = try await wiedergabeHolen(id: id)
            sperre.lock(); _wiedergabe = w; _folgenwechsel = Folgenwechsel(); sperre.unlock()
            return try spielplanantwort(w)
        }
    }

    /// Nur holen, nichts setzen — damit ein Folgenwechsel die alte Wiedergabe stehen lassen kann,
    /// bis die neue sicher da ist (Audit T2-M2).
    private func wiedergabeHolen(id: String) async throws -> Wiedergabe {
        guard let c = client else { throw Kernfehler.nichtVerbunden }
        // Die Faehigkeiten gehen mit der Startmeldung (`meldereihe`) — hier warteten sie vor dem Plan.
        let item = try await c.item(id: id)
        let grenze = profilBitrate
        async let geplant = c.playbackPlan(for: id, profile: .vlc(maxBitrate: grenze))
        async let teile = c.abschnitte(fuer: id)
        async let danach = naechsteFolge(nach: item, c)
        guard let plan = try await geplant else { throw URLError(.resourceUnavailable) }
        var w = Wiedergabe(item: item, plan: plan, abschnitte: await teile, naechste: await danach)
        // Externe Untertitel (T1-H4) — `AppModel.untertiteldateien`. Von der Platte keine.
        if let s = sperreLesen({ _sitzung }), !plan.url.isFileURL {
            w.dateien = Untertiteldatei.aus(stroeme: plan.quelle?.mediaStreams ?? [], server: s.serverURL,
                                            schluessel: s.accessToken)
        }
        return w
    }

    private func spielplanantwort(_ w: Wiedergabe) throws -> String {
        let a = adressen
        let item = w.item, plan = w.plan
        let istFolge = item.type == "Episode"
        // **`kopfzeile`/`staffelNr`/`folgeNr`/`nebenzeile` fuer den Kopf des Players** — Vorlage
        // `titelzeile`/`metatext` in `Sources/iOS/PlayerScreen.swift`. Uebersetzt wird erst in Kotlin
        // (`uebersetzt(...)`), hier gehen nur die Rohwerte hinueber — wie ueberall in dieser Fassade.
        let kopfzeile = (istFolge && !(item.seriesName ?? "").isEmpty) ? item.seriesName! : item.name
        return try json(Spielplanantwort(
            url: plan.url.absoluteString, lossless: plan.isLossless, methode: plan.method.rawValue,
            titel: item.name,
            // **`item.kontextzeile` aus dem Paket, keine eigene Zeile.** Stand hier einmal selbst
            // zusammengesetzt (Serienname zuerst, Trennzeichen „·") und lief prompt auseinander:
            // tvOS zeigt „S20 • E2 • Die Höhle der Löwen" (`PlayerScreen.fuss`, `item.kontextzeile`).
            untertitel: item.kontextzeile ?? "",
            naechste: w.naechste != nil,
            dateizeile: dateizeile(plan),
            // Fuer die Mediensteuerung: bei einer Folge ihr Standbild — es zeigt, wo man ist —, sonst das Plakat.
            serie: item.seriesName, kuerzel: item.folgenkuerzel,
            bild: { () -> String? in
                let u: URL? = a?.bauen(itemID: item.id, marke: item.imageTags?["Primary"], mass: .hoechstensHoch(600))
                return u?.absoluteString
            }(),
            itemId: item.id, episode: istFolge, serieId: item.seriesId, staffelId: item.seasonId,
            kopfzeile: kopfzeile, staffelNr: istFolge ? item.parentIndexNumber : nil,
            folgeNr: istFolge ? item.indexNumber : nil,
            nebenzeile: istFolge ? nil : (item.nebenzeile.isEmpty ? nil : item.nebenzeile)))
    }
    /// „MKV · 1080p · H.264 · German · AAC · Stereo" — Vorlage: `dateizeile` in
    /// `Sources/tvOS/Wiedergabeblatt.swift`. Einmal hier, damit Kotlin sie nicht selbst aus
    /// `Dateiangaben` zusammensetzen muss.
    private func dateizeile(_ plan: PlaybackPlan) -> String? {
        guard let quelle = plan.quelle else { return nil }
        var teile: [String] = []
        if let behaelter = quelle.container { teile.append(behaelter.uppercased()) }
        if let video = Dateiangaben.videospur(quelle) { teile.append(Dateiangaben.video(video, quelle)) }
        if let ton = Dateiangaben.tonspuren(quelle).first { teile.append(ton.kurz) }
        return teile.isEmpty ? nil : teile.joined(separator: " · ")
    }

    /// **Die Startstelle, bevor VLC sie meldet.** Sonst stand die Zeitleiste auf 0:00 und sprang
    /// dann an die richtige Stelle — auf iOS steht sie von Anfang an dort (`position = startAt`).
    /// `Zeitannahme` haelt sie, bis VLC sie bestaetigt: kein Ruecksprung kurz nach dem Oeffnen.
    public func wiedergabeStelle(ab: Double) {
        sperre.lock(); _wiedergabe?.stand.position = ab; sperre.unlock()
    }

    private func naechsteFolge(nach item: Item, _ c: JellyfinClient) async -> Item? {
        guard item.type == "Episode", let serie = item.seriesId else { return nil }
        return try? await c.folgeNach(itemID: item.id, seriesID: serie)
    }

    /// Ein Takt alle 500 ms — `Wiedergabetakt.rechnen` wie auf iOS. Start und Fortschritt gehen
    /// von hier an den Server; zurueck kommt, was die Oberflaeche tun soll.
    ///
    /// **Kein Sprungriegel mehr und keine Einstellung** (Bug 17.09.2026): die Zielstelle eines Sprungs
    /// haelt der Stand selbst (`sprungGemeldet` → `Wiedergabetakt.gesprungen`), bis VLC dort ist; ob
    /// am Ende weitergeschaltet wird, entscheidet allein die Karte (`Angebotsebene.weiterAmEnde`).
    public func wiedergabeTakt(dauer: Double, position: Double, zeigtBild: Bool, laeuft: Bool,
                               hatTonspuren: Bool, amSchieben: Bool) -> String {
        sperre.lock()
        // Waehrend eines Folgenwechsels schweigt der Takt: keine Meldung fuer die alte Folge nach
        // ihrem Stopp, kein Angebotsknopf, kein zweites Weiterschalten (Audit T2-M1).
        guard _folgenwechsel.meldungenErlaubt else { sperre.unlock(); return "{}" }
        guard var w = _wiedergabe, _client != nil else { sperre.unlock(); return "{}" }
        let messung = Wiedergabetakt.Messung(dauer: dauer, position: position, guteStelle: position,
                                             zeigtBild: zeigtBild, stelltEin: false, laeuft: laeuft,
                                             hatTonspuren: hatTonspuren)
        let auftrag = Wiedergabetakt.rechnen(&w.stand, messung: messung, stelltWiederHer: false,
                                             amSchieben: amSchieben, seitStart: w.start)
        let stelle = w.stand.position
        // **Die Einblendung** (Countdown) — im Stehen, beim Schieben und vor dem ersten Bild haelt er
        // an. `taktlaenge` ist der Abstand, in dem Kotlin fragt.
        let countdownFertig = Self.angebotNachziehen(&w, laeuft: laeuft && zeigtBild && !amSchieben,
                                                     vergangen: Wiedergabetakt.taktlaenge / .seconds(1))
        _wiedergabe = w
        sperre.unlock()

        // Eingereiht, nicht abgewartet: der Takt kehrt sofort zurueck, auch wenn der Server haengt.
        if auftrag.startMelden {
            startMelden(w, sekunden: stelle)
        } else if auftrag.fortschrittMelden {
            fortschrittMelden(w, sekunden: stelle, pausiert: !w.stand.laeuft)
        }

        if countdownFertig { protokoll("Angebot: Countdown abgelaufen") }
        // Am Ende von selbst weiter — nur mit Karte, nicht, wenn sie abgesagt wurde (Paul, 17.09.).
        let weiter = w.naechste != nil
            && (countdownFertig || (w.ebene.weiterAmEnde
                && Folgenende.weiterschalten(position: stelle, dauer: w.stand.dauer,
                                             seitOeffnen: Date().timeIntervalSince(w.start))))
        let lage = Self.angebotslage(w)
        return (try? json(Taktantwort(ladeschirmWeg: auftrag.ladeschirmWeg, spurenAnwenden: auftrag.spurenAnwenden,
                                      position: stelle, angebot: lage.art, nach: lage.nach,
                                      angebotstext: lage.text, einblendung: lage.einblendung,
                                      countdown: lage.anteil, countdownRest: w.ebene.countdownRest,
                                      countdownLaenge: w.ebene.countdownLaenge,
                                      weiterschalten: weiter))) ?? "{}"
    }

    /// Angebot und Einblendung an die Stelle des Stands anpassen — im Takt, und mit `vergangen: 0`
    /// direkt nach einem Sprung. `true`, wenn der Countdown jetzt abgelaufen ist.
    private static func angebotNachziehen(_ w: inout Wiedergabe, laeuft: Bool, vergangen: Double) -> Bool {
        let stelle = w.stand.position, dauer = w.stand.dauer
        let angebot = Abschnittslogik.angebot(position: stelle, dauer: dauer,
                                              abschnitte: w.abschnitte, hatNaechsteFolge: w.naechste != nil)
        let faellig = Abschnittslogik.karteFaellig(position: stelle, dauer: dauer,
                                                   abschnitte: w.abschnitte, hatNaechsteFolge: w.naechste != nil)
        return w.ebene.takt(angebot: angebot, karteFaellig: faellig, laeuft: laeuft, vergangen: vergangen,
                            countdown: Abschnittslogik.countdown(position: stelle, dauer: dauer))
    }

    private static func angebotslage(_ w: Wiedergabe)
        -> (art: String, nach: Double?, text: String, einblendung: String, anteil: Double) {
        let angebot = Abschnittslogik.angebot(position: w.stand.position, dauer: w.stand.dauer,
                                              abschnitte: w.abschnitte, hatNaechsteFolge: w.naechste != nil)
        var art = "keiner"
        var nach: Double?
        switch angebot {
        case .keiner: break
        case let .ueberspringen(ziel, _): art = "ueberspringen"; nach = ziel
        case .naechsteFolge: art = "naechste"
        }
        var einblendung = "nichts"
        var anteil = 0.0
        switch w.ebene.anzeige {
        case .nichts: break
        case .knopf: einblendung = "knopf"
        case let .karte(a): einblendung = "karte"; anteil = a
        }
        return (art, nach, angebot.beschriftung, einblendung, anteil)
    }

    /// **Nur die Zeit, zwischen zwei Takten** (`Wiedergabetakt.zeitUebernehmen`, Paul 17.09.2026): Kotlin
    /// fragt alle 250 ms, der ganze Takt bleibt bei 500 ms. VLCs Zeit, nach einem Sprung das Ziel, bis VLC
    /// dort ist. `-1`, wenn nichts laeuft oder gerade gewechselt wird — dann bleibt die Anzeige, wie sie ist.
    public func anzeigeZeit(position: Double, amSchieben: Bool) -> Double {
        sperre.lock(); defer { sperre.unlock() }
        guard _folgenwechsel.meldungenErlaubt, var w = _wiedergabe else { return -1 }
        Wiedergabetakt.zeitUebernehmen(&w.stand, gemeldet: position, amSchieben: amSchieben, seitStart: w.start)
        _wiedergabe = w
        return w.stand.position
    }

    /// **Die Steuerung geht auf oder zu** (`Angebotsebene.steuerung`): Oeffnen sagt die Karte „Naechste
    /// Folge" ab; Auf und Zu schickt den Ueberspringen-Knopf in die Steuerung. Kotlin ruft das mit der
    /// gewollten Sichtbarkeit, sofort beim Wechsel.
    public func steuerungGeaendert(offen: Bool) {
        sperre.lock(); _wiedergabe?.ebene.steuerung(offen: offen); sperre.unlock()
    }

    /// **Zurueck, oder eine Richtungstaste am Fernseher:** die Einblendung geht, ein laufender
    /// Countdown ist abgesagt (dann schaltet auch das Dateiende nicht weiter). `true`, wenn etwas zu
    /// schliessen war — dann darf Zurueck den Player nicht verlassen.
    public func angebotSchliessen() -> Bool {
        sperre.lock(); defer { sperre.unlock() }
        guard var w = _wiedergabe else { return false }
        let zu = w.ebene.schliessen()
        _wiedergabe = w
        if zu { protokoll("Angebot: geschlossen") }
        return zu
    }

    /// Der Knopf wurde gedrueckt — die Einblendung geht, Kotlin fuehrt aus.
    public func angebotGedrueckt() {
        sperre.lock(); _wiedergabe?.ebene.gedrueckt(); sperre.unlock()
    }

    /// „Naechste Folge automatisch": eigene Wahl vor `EnableNextEpisodeAutoPlay` des Kontos vor „an"
    /// (`Weiterschalten.gilt`). Beide als `"1"`, `"0"` oder leer (nie gewaehlt / unbekannt).
    public static func naechsteAutomatischGilt(wahl: String, konto: String) -> Bool {
        func lesen(_ t: String) -> Bool? { t.isEmpty ? nil : t == "1" }
        return Weiterschalten.gilt(eigeneWahl: lesen(wahl), konto: lesen(konto))
    }

    /// Was das geltende Konto vorgibt, **aus einer Anfrage**: `"<naechste>|<download>|<umwandeln>"`
    /// — `EnableNextEpisodeAutoPlay`, `EnableContentDownloading` und
    /// `EnableVideoPlaybackTranscoding`, je `"1"`, `"0"` oder leer, wenn der Server nichts sagt.
    /// Wirft nie; ohne Antwort kommt `"||"`, und dann bleibt es bei der eigenen Wahl bzw. „an"
    /// und beim Recht `unbekannt`, also erlaubt.
    public func kontovorgaben() async -> String {
        func text(_ wert: Bool?) -> String { wert.map { $0 ? "1" : "0" } ?? "" }
        guard let c = client, let v = await c.kontovorgaben() else { return "||" }
        protokoll("Konto: Naechste Folge automatisch \(text(v.naechsteFolgeAutomatisch)), Downloads \(v.downloadrecht.rawValue)")
        return "\(text(v.naechsteFolgeAutomatisch))|\(text(v.downloadsErlaubt))|\(text(v.umwandelnErlaubt))"
    }

    /// **Ob ein Ladeknopf erscheint** — der Schalter H1 *und* das Recht am Konto. Die Entscheidung
    /// liegt im Paket (`Downloadrecht.anbieten`), damit Kotlin keine zweite Liste fuehrt.
    /// `recht` ist `"1"`, `"0"` oder leer, wie ``kontovorgaben()`` es liefert.
    public static func downloadKnopfZeigen(recht: String, funktionAn: Bool) -> Bool {
        Downloadrecht.anbieten(recht: .vomServer(recht.isEmpty ? nil : recht == "1"),
                               funktionAn: funktionAn)
    }

    /// **VLC hat angehalten oder laeuft wieder — sofort melden** (Audit T1-N1), wie
    /// `AppModel.laufzustandGemeldet`. Kotlin ruft das aus libVLCs `Playing`/`Paused`, nicht im
    /// Knopfdruck: dort stand noch der Zustand von davor. Einmal je Wechsel; vor dem Start, nach
    /// dem Stopp und waehrend eines Folgenwechsels nichts.
    public func laufzustandGemeldet(laeuft: Bool, position: Double) {
        guard let w = meldbar(), sperreLesen({ _gemeldetPausiert }) == laeuft else { return }
        protokoll("sofort: \(laeuft ? "weiter" : "Pause") bei \(Int(position)) s")
        fortschrittMelden(w, sekunden: position, pausiert: !laeuft)
    }

    /// **Gesprungen — sofort melden**, mit der Zielstelle (`AppModel.sprungGemeldet`). Jeder
    /// Sprungweg in Kotlin laeuft ueber `Spielwerk.springe`, auch „Springen auf" vom Dashboard.
    ///
    /// **Und sofort anzeigen** (Bug 17.09.2026): der Stand haelt die Zielstelle, bis VLC dort ist, und
    /// das Angebot folgt ihr im selben Aufruf. Zurueck kommt dieselbe Form wie aus dem Takt, ohne die
    /// Auftraege.
    public func sprungGemeldet(ziel: Double) -> String {
        sperre.lock()
        guard var w = _wiedergabe else { sperre.unlock(); return "{}" }
        Wiedergabetakt.gesprungen(&w.stand, ziel: ziel)
        _ = Self.angebotNachziehen(&w, laeuft: false, vergangen: 0)
        _wiedergabe = w
        sperre.unlock()
        if let m = meldbar() {
            fortschrittMelden(m, sekunden: max(0, w.stand.position), pausiert: sperreLesen { _gemeldetPausiert })
        }
        let lage = Self.angebotslage(w)
        return (try? json(Taktantwort(ladeschirmWeg: false, spurenAnwenden: false,
                                      position: w.stand.position, angebot: lage.art, nach: lage.nach,
                                      angebotstext: lage.text, einblendung: lage.einblendung,
                                      countdown: lage.anteil, countdownRest: w.ebene.countdownRest,
                                      countdownLaenge: w.ebene.countdownLaenge,
                                      weiterschalten: false))) ?? "{}"
    }

    /// **Die Activity geht in den Hintergrund** (Audit T3 #5): den Stand jetzt melden, nicht erst im
    /// naechsten Takt. Der Wiedergabedienst haelt den Prozess am Leben; gewartet wird nicht.
    public func hintergrundMelden(position: Double, pausiert: Bool) {
        guard let w = meldbar() else { return }
        protokoll("Hintergrund: \(Int(position)) s pausiert \(pausiert)")
        fortschrittMelden(w, sekunden: position, pausiert: pausiert)
    }

    // MARK: Meldungen ueber die Reihe

    /// Was eine Meldung braucht. Der Client wird beim Einreihen festgehalten: wechselt danach das
    /// Konto, gehoert die Meldung trotzdem dem, der geschaut hat.
    private struct Meldeinhalt: Sendable {
        let client: JellyfinClient?
        let item: Item
        let plan: PlaybackPlan
        let sekunden: Double
        let spuren: Spurindizes
    }

    private enum Meldefehler: Error { case keinServer }

    /// Nur im Debug-Bau von Kotlin gesetzt (`Spielwerk`, Datei `meldungen-haengen`): jede Meldung
    /// haengt 60 s, wie `meldungen:haengen` auf Linux — ein Server, der nicht antwortet.
    private final class Meldeprobe: @unchecked Sendable {
        private let schloss = NSLock()
        private var _haengen = false
        var haengen: Bool {
            get { schloss.lock(); defer { schloss.unlock() }; return _haengen }
            set { schloss.lock(); _haengen = newValue; schloss.unlock() }
        }
    }
    private let meldeprobe = Meldeprobe()

    /// Nur fuer den Debug-Bau — Kotlin ruft es sonst nie.
    public func meldungenHaengen(_ an: Bool) {
        guard meldeprobe.haengen != an else { return }
        meldeprobe.haengen = an
        protokoll("Probe: Meldungen haengen \(an)")
    }

    /// **Abgesetzt, nicht abgewartet** (Audit 16.09., T1-H2) — `Meldewarteschlange` aus dem Paket:
    /// eine Reihe fuer Start, Fortschritt und Stopp, Fortschritt zusammengefasst, 6 s Frist, und die
    /// Stoppsperre je PlaySession steckt darin. Hier steht nur, was gesendet wird.
    private let meldungen: Meldewarteschlange<Meldeinhalt>

    private static func meldereihe(zeilen: Protokollzeilen, probe: Meldeprobe) -> Meldewarteschlange<Meldeinhalt> {
        Meldewarteschlange<Meldeinhalt> { meldung in
            let inhalt = meldung.nutzlast
            if probe.haengen { try await Task.sleep(nanoseconds: 60_000_000_000) }
            guard let client = inhalt.client else { throw Meldefehler.keinServer }
            let item = inhalt.item, plan = inhalt.plan
            let ticks = JellyfinClient.ticks(fromSeconds: inhalt.sekunden)
            switch meldung.art {
            case .start:
                // **Die Faehigkeiten vor jedem Start**, in derselben Meldung und Frist: nach einem
                // Neustart des Servers brach die Uebernahme sonst still. Scheitert es, geht der
                // Start trotzdem — ausser die Frist hat abgebrochen.
                do { try await client.faehigkeitenMelden() } catch {
                    try Task.checkCancellation()
                    zeilen.schreiben("Faehigkeiten nicht gemeldet")
                }
                try await client.reportStart(itemID: item.id, plan: plan, ticks: ticks, spuren: inhalt.spuren)
                zeilen.schreiben("Start \(Int(inhalt.sekunden)) s \(item.id) session \(plan.playSessionID ?? "nil")"
                    + " Spuren \(spurtext(inhalt.spuren))")
            case let .fortschritt(pausiert):
                try await client.reportProgress(itemID: item.id, plan: plan, positionTicks: ticks, paused: pausiert,
                                                spuren: inhalt.spuren)
                zeilen.schreiben("Progress \(Int(inhalt.sekunden)) s pausiert \(pausiert) \(item.id)"
                    + " Spuren \(spurtext(inhalt.spuren))")
            case .stopp:
                try await client.reportStopped(itemID: item.id, plan: plan, positionTicks: ticks)
            }
        }
    }

    private static func schluessel(_ w: Wiedergabe) -> String {
        Stoppsperre.schluessel(itemID: w.item.id, playSessionID: w.plan.playSessionID)
    }

    private func meldung(_ art: Meldewarteschlange<Meldeinhalt>.Art, _ w: Wiedergabe,
                         sekunden: Double) -> Meldewarteschlange<Meldeinhalt>.Meldung {
        .init(art: art, schluessel: Self.schluessel(w),
              nutzlast: Meldeinhalt(client: client, item: w.item, plan: w.plan, sekunden: sekunden, spuren: w.spuren))
    }

    private static func spurtext(_ s: Spurindizes) -> String {
        "\(s.ton.map(String.init) ?? "—")/\(s.untertitel.map(String.init) ?? "—")"
    }

    private func sperreLesen<T>(_ lesen: () -> T) -> T {
        sperre.lock(); defer { sperre.unlock() }
        return lesen()
    }

    /// Die laufende Wiedergabe, wenn ausser der Reihe gemeldet werden darf.
    private func meldbar() -> Wiedergabe? {
        sperreLesen {
            guard let w = _wiedergabe, _folgenwechsel.meldungenErlaubt, w.stand.startGemeldet else { return nil }
            return w
        }
    }

    /// Kehrt sofort zurueck. Die Reihe gibt die Stoppsperre beim Einreihen frei.
    private func startMelden(_ w: Wiedergabe, sekunden: Double) {
        sperre.lock(); _gemeldetPausiert = false; sperre.unlock()
        meldungen.melden(meldung(.start, w, sekunden: sekunden))
    }

    /// Kehrt sofort zurueck; nach dem Stopp dieser Sitzung verworfen.
    private func fortschrittMelden(_ w: Wiedergabe, sekunden: Double, pausiert: Bool) {
        guard meldungen.melden(meldung(.fortschritt(pausiert: pausiert), w, sekunden: sekunden)) else {
            protokoll("Fortschritt nach Stopp verworfen \(w.item.id)")
            return
        }
        sperre.lock(); _gemeldetPausiert = pausiert; sperre.unlock()
    }

    /// **Abgewartet**, weil danach die Seiten neu laden (e91002a) — die Reihe schickt es hinter einem
    /// noch laufenden Start. Leer heisst: gemeldet oder schon gemeldet. Sonst die Nachmeldung als JSON.
    private func stoppMelden(_ w: Wiedergabe, stelle: Double) async -> String {
        let s = sperreLesen { _sitzung }
        let ticks = JellyfinClient.ticks(fromSeconds: stelle)
        let ergebnis = await meldungen.meldenUndWarten(meldung(.stopp, w, sekunden: stelle))
        switch ergebnis {
        case .gesendet:
            protokoll("Stopped \(Int(stelle)) s \(w.item.id) session \(w.plan.playSessionID ?? "nil")")
            return ""
        case .verworfen:
            protokoll("Stopped doppelt verworfen \(w.item.id) session \(w.plan.playSessionID ?? "nil")")
            return ""
        case .gescheitert, .zeitUeberschritten:
            protokoll("Stopped \(ergebnis) → Nachmeldung \(w.item.id)")
            guard let konto = s?.userID else { return "" }
            return Self.kodiert(Nachmeldung(itemID: w.item.id, konto: konto, ticks: ticks))
        }
    }

    /// Meldezeilen fuer logcat — eigenes Schloss, damit die Reihe schreiben kann, ohne den Kern zu kennen.
    private final class Protokollzeilen: @unchecked Sendable {
        private let schloss = NSLock()
        private var zeilen: [String] = []
        func schreiben(_ zeile: String) {
            schloss.lock(); defer { schloss.unlock() }
            zeilen.append(zeile)
            if zeilen.count > 50 { zeilen.removeFirst(zeilen.count - 50) }
        }
        func abholen() -> [String] {
            schloss.lock(); defer { schloss.unlock() }
            let alle = zeilen; zeilen = []
            return alle
        }
    }
    private let protokollzeilen = Protokollzeilen()

    private func protokoll(_ zeile: String) {
        protokollzeilen.schreiben(zeile)
    }

    /// Die Meldezeilen seit dem letzten Abholen — Kotlin schreibt sie unter „Swiftly" ins logcat.
    /// Swift selbst kommt an `liblog` nicht heran.
    public func protokollAbholen() -> String {
        protokollzeilen.abholen().joined(separator: "\n")
    }

    /// Beendet — muss auch beim Schliessen kommen, sonst haengt die Sitzung im Dashboard. Ob der
    /// Titel als gesehen gilt, entscheidet der Server aus der gemeldeten Stelle.
    /// Leer heisst: gemeldet. Sonst die Nachmeldung als JSON — **hier entsteht die Angabe, fuer die
    /// es Downloads gibt**: wo jemand im Flugzeug aufgehoert hat. Kotlin legt sie ab (H8).
    ///
    /// **Ueber `Folgenwechsel.schliessen`** (Audit T2-M1): laeuft gerade ein Wechsel, wendet er
    /// nichts mehr an; ist der Start der neuen Folge unterwegs, geht der Stopp erst danach. Gemeldet
    /// wird, was beim Stoppen laeuft — war das schon die neue Folge, mit ihrer eigenen Stelle.
    /// Ein zweiter Aufruf fuer denselben Player tut nichts.
    public func wiedergabeBeenden(position: Double) async -> String {
        await withCheckedContinuation { (fertig: CheckedContinuation<String, Never>) in
            sperre.lock()
            let wechsel = _folgenwechsel
            let damals = _wiedergabe.map(Self.schluessel)
            let offen = wechsel.phase != .geschlossen
            if offen {
                wechsel.schliessen { [self] in
                    sperre.lock(); let w = _wiedergabe; _wiedergabe = nil; sperre.unlock()
                    guard let w else { fertig.resume(returning: ""); return }
                    let stelle = Self.schluessel(w) == damals ? position : w.stand.position
                    fertig.resume(returning: await stoppMelden(w, stelle: stelle))
                }
            }
            sperre.unlock()
            if !offen { fertig.resume(returning: "") }
        }
    }

    /// Zu einer anderen Folge wechseln — `Folgenwechsel.ausfuehren` aus dem Paket, wie iOS, tvOS und
    /// macOS. `id` leer: die vorgemerkte naechste Folge; sonst eine frei gewaehlte (`Folgenblatt`).
    ///
    /// Stopp der alten und Plan der neuen laufen nebeneinander; **die alte Wiedergabe bleibt stehen,
    /// bis der Plan da ist** — scheitert er, laeuft sie weiter und der Takt meldet sie neu an (T2-M2).
    /// Ein zweiter Ausloeser waehrend des Wechsels kommt als `gesperrt` zurueck (T2-M1).
    ///
    /// Antwort: `ergebnis` (`gewechselt`, `gesperrt`, `abgebrochen`, `gescheitert`), bei `gewechselt`
    /// der `spielplan`, bei `gescheitert` der lesbare `fehler`, und eine `nachmeldung`, wenn der Stopp
    /// der alten Folge nicht ankam.
    /// **Qualität gewechselt — derselbe Titel, neu geplant, an derselben Stelle.** Vorlage: die
    /// Qualitätswahl im Player auf iOS/tvOS/macOS (`PlayerScreen.qualitaetswahl`). Anders als
    /// ``folgeWechseln(id:position:)`` bleibt es beim **laufenden** Titel — nur der Plan ist neu,
    /// weil `wiedergabeWahlen` vorher die Bitratengrenze gesetzt hat — und die Stelle ist die
    /// Fortsetzstelle, nicht null. Antwort wie dort.
    public func qualitaetWechseln(position: Double) async -> String {
        sperre.lock(); let wechsel = _folgenwechsel; let alt = _wiedergabe; sperre.unlock()
        guard let alt else { return Self.kodiert(Wechselantwort(ergebnis: "gescheitert")) }
        let ablage = Wechselablage()
        let ergebnis = await wechsel.ausfuehren(Folgenwechsel.Schritte<Wiedergabe>(
            stoppen: { [self] in ablage.setzen(nachmeldung: await stoppMelden(alt, stelle: position)) },
            planen: { [self] in
                do { return try await wiedergabeHolen(id: alt.item.id) } catch {
                    ablage.setzen(fehler: kernFehlertext(error))
                    return nil
                }
            },
            anwenden: { [self] neu in
                var neu = neu
                Wiedergabetakt.neuerTitel(&neu.stand, startGemeldet: true)
                if position > 0 { Wiedergabetakt.gesprungen(&neu.stand, ziel: position) }
                sperre.lock(); _wiedergabe = neu; sperre.unlock()
                ablage.setzen(spielplan: try? spielplanantwort(neu))
            },
            starten: { [self] neu in startMelden(neu, sekunden: position) },
            gescheitert: { [self] in
                sperre.lock()
                if let w = _wiedergabe, Self.schluessel(w) == Self.schluessel(alt) { _wiedergabe?.stand.startGemeldet = false }
                sperre.unlock()
            }))
        protokoll("Qualität \(ergebnis) → \(alt.item.id) bei \(Int(position)) s")
        var antwort = Wechselantwort(ergebnis: "\(ergebnis)")
        antwort.nachmeldung = ablage.nachmeldung
        switch ergebnis {
        case .gewechselt:
            antwort.spielplan = ablage.spielplan
        case .gescheitert:
            antwort.fehler = ablage.fehler ?? kernFehlertext(URLError(.resourceUnavailable))
        case .gesperrt, .abgebrochen: break
        }
        return Self.kodiert(antwort)
    }

    public func folgeWechseln(id: String, position: Double) async -> String {
        sperre.lock(); let wechsel = _folgenwechsel; let alt = _wiedergabe; sperre.unlock()
        guard let alt else { return Self.kodiert(Wechselantwort(ergebnis: "gescheitert")) }
        guard let ziel = id.isEmpty ? alt.naechste?.id : id else {
            return Self.kodiert(Wechselantwort(ergebnis: "gescheitert"))
        }
        let ablage = Wechselablage()
        let ergebnis = await wechsel.ausfuehren(Folgenwechsel.Schritte<Wiedergabe>(
            stoppen: { [self] in ablage.setzen(nachmeldung: await stoppMelden(alt, stelle: position)) },
            planen: { [self] in
                do { return try await wiedergabeHolen(id: ziel) } catch {
                    ablage.setzen(fehler: kernFehlertext(error))
                    return nil
                }
            },
            anwenden: { [self] neu in
                var neu = neu
                Wiedergabetakt.neuerTitel(&neu.stand, startGemeldet: true)
                sperre.lock(); _wiedergabe = neu; sperre.unlock()
                ablage.setzen(spielplan: try? spielplanantwort(neu))
            },
            starten: { [self] neu in startMelden(neu, sekunden: 0) },
            gescheitert: { [self] in
                // Die alte Folge laeuft weiter, der Server kennt sie aber schon als beendet.
                sperre.lock()
                if let w = _wiedergabe, Self.schluessel(w) == Self.schluessel(alt) { _wiedergabe?.stand.startGemeldet = false }
                sperre.unlock()
            }))
        protokoll("Wechsel \(ergebnis) → \(ziel)")
        var antwort = Wechselantwort(ergebnis: "\(ergebnis)")
        antwort.nachmeldung = ablage.nachmeldung
        switch ergebnis {
        case .gewechselt:
            antwort.spielplan = ablage.spielplan
        case .gescheitert:
            antwort.fehler = ablage.fehler ?? kernFehlertext(URLError(.resourceUnavailable))
        case .gesperrt, .abgebrochen: break
        }
        return Self.kodiert(antwort)
    }
    // MARK: Spuren (Stufe 4)
    //
    // Vorlage: `VLCPlayerView` in `Sources/Shared/VLCPlayer.swift` (e198e37). Entschieden wird ueber
    // `Spurregel`/`Spurzuordnung` im Paket; Kotlin reicht die Spuren aus libVLC als JSON herein
    // (`id`, `kennung`, `name`, `sprache`, `fourcc`, `kanaele`) und bekommt VLC-Spur-ids zurueck.
    //
    // **Das Gedaechtnis liegt in Kotlin** (SharedPreferences, Schluessel `tonJeTitel`/`utJeTitel`),
    // im selben Format wie `Spurgedaechtnis` — das Paket legt es in `UserDefaults`, und das ist auf
    // Android nicht belegt. Kotlin gibt die Ablage herein und legt zurueck, was hier herauskommt.

    /// Die externen Untertitel der laufenden Folge: `[{index, adresse}]`. Kotlin bildet den MD5 der
    /// Adresse (``untertitelmerkmalSetzen(index:merkmal:)``) und haengt sie als Slave an.
    public func untertiteldateien() -> String {
        Self.kodiert(sperreLesen { _wiedergabe?.dateien ?? [] }.map {
            Untertiteldateiantwort(index: $0.index, adresse: $0.adresse.absoluteString)
        })
    }

    public func untertitelmerkmalSetzen(index: Int, merkmal: String) {
        sperre.lock(); defer { sperre.unlock() }
        guard let i = _wiedergabe?.dateien.firstIndex(where: { $0.index == index }),
              let datei = _wiedergabe?.dateien[i] else { return }
        _wiedergabe?.dateien[i] = Untertiteldatei(index: index, adresse: datei.adresse, merkmal: merkmal)
    }

    /// Ton und Untertitel nach `Spurregel`, sobald VLC die Spuren kennt. `tonJetzt`: die laufende
    /// Tonspur (VLC-id), falls nichts zuzuordnen ist. Antwort: `ton` (VLC-id, fehlt: Datei lassen),
    /// `untertitel` (VLC-id, -1: aus).
    public func spurenWaehlen(ton: String, untertitel: String, tonJetzt: Int, tonwunsch: String,
                              untertitelwunsch: String, automatisch: Bool,
                              tonGedaechtnis: String, untertitelGedaechtnis: String) -> String {
        let tonspuren = Self.spuren(ton), utspuren = Self.spuren(untertitel)
        guard let w = sperreLesen({ _wiedergabe }) else { return "{}" }
        let quelle = w.plan.quelle
        let stroeme = quelle?.mediaStreams ?? []
        let z = Spurzuordnung.bilden(ton: tonspuren.map(\.spur), untertitel: utspuren.map(\.spur),
                                     stroeme: stroeme, dateien: w.dateien)
        let titel = Spurgedaechtnis.titel(fuer: w.item)
        var gemerkterTon: Spurabdruck?
        if case .spur(let abdruck)? = Self.gedaechtnisLesen(tonGedaechtnis, titel) { gemerkterTon = abdruck }

        var tonIndex = Spurregel.ton(stroeme: stroeme, gemerkt: gemerkterTon, wunschsprache: tonwunsch,
                                     serverVorgabe: quelle?.defaultAudioStreamIndex)
        var tonId: Int?
        if let gesucht = tonIndex, let position = z.tonposition(index: gesucht) {
            tonId = tonspuren[position].id
        } else {
            // Nicht zuzuordnen: der alte Weg ueber den Namen, sonst die Datei.
            if !tonwunsch.isEmpty, let treffer = tonspuren.first(where: { Sprache.passt($0.name, zu: tonwunsch) }) {
                tonId = treffer.id
            }
            let laufend = tonId ?? tonJetzt
            tonIndex = tonspuren.firstIndex { $0.id == laufend }.flatMap { z.ton[$0] }
        }

        let wahl = Spurregel.untertitel(stroeme: stroeme, gemerkt: Self.gedaechtnisLesen(untertitelGedaechtnis, titel),
                                        serverVorgabe: quelle?.defaultSubtitleStreamIndex, automatisch: automatisch,
                                        tonindex: tonIndex, tonwunsch: tonwunsch, wunschsprache: untertitelwunsch)
        var utId = -1
        var offen: Int?
        var utIndex = -1
        if case .strom(let index) = wahl {
            utIndex = index
            if let position = z.untertitelposition(index: index) {
                utId = utspuren[position].id
            } else if w.dateien.contains(where: { $0.index == index }) {
                // Die Datei haengt noch nicht oder ist noch nicht gelesen.
                offen = index
                protokoll("Spuren: Untertiteldatei \(index) noch nicht da, wartet")
            } else {
                protokoll("Spuren: Untertitel \(index) nicht zuzuordnen, bleibt aus")
            }
        }
        sperre.lock()
        if let jetzt = _wiedergabe, Self.schluessel(jetzt) == Self.schluessel(w) {
            _wiedergabe?.spuren = Spurindizes(ton: tonIndex, untertitel: utIndex)
            _wiedergabe?.offenerUntertitel = offen
        }
        sperre.unlock()
        protokoll("Spuren: Ton \(tonIndex.map(String.init) ?? "Datei") · Untertitel \(wahl)"
            + " · Vorgaben \(quelle?.defaultAudioStreamIndex.map(String.init) ?? "—")/"
            + "\(quelle?.defaultSubtitleStreamIndex.map(String.init) ?? "—")"
            + " · Zuordnung Ton \(z.ton) Untertitel \(z.untertitel)"
            + " · Kennungen \(utspuren.map(\.kennung))")
        return Self.kodiert(Spurwahlantwort(ton: tonId, untertitel: utId))
    }

    /// VLC meldet eine neue Untertitelspur — vielleicht die gewaehlte Datei. VLC-id oder -1.
    public func offenenUntertitel(untertitel: String) -> Int {
        guard let w = sperreLesen({ _wiedergabe }), let index = w.offenerUntertitel else { return -1 }
        let utspuren = Self.spuren(untertitel)
        let z = Spurzuordnung.bilden(ton: [], untertitel: utspuren.map(\.spur),
                                     stroeme: w.plan.quelle?.mediaStreams ?? [], dateien: w.dateien)
        guard let position = z.untertitelposition(index: index) else { return -1 }
        sperre.lock()
        let gilt = _wiedergabe?.offenerUntertitel == index && _wiedergabe.map(Self.schluessel) == Self.schluessel(w)
        if gilt { _wiedergabe?.offenerUntertitel = nil; _wiedergabe?.spuren.untertitel = index }
        sperre.unlock()
        guard gilt else { return -1 }
        protokoll("Spuren: Untertiteldatei \(index) nachgereicht")
        return utspuren[position].id
    }

    /// Tonspur von Hand: gilt fuer die ganze Serie (T1-M1). Zurueck kommt die neue Ablage.
    public func tonVonHand(ton: String, id: Int, gedaechtnis: String) -> String {
        let spuren = Self.spuren(ton)
        guard let w = sperreLesen({ _wiedergabe }), let position = spuren.firstIndex(where: { $0.id == id })
        else { return gedaechtnis }
        let stroeme = w.plan.quelle?.mediaStreams ?? []
        let z = Spurzuordnung.bilden(ton: spuren.map(\.spur), untertitel: [], stroeme: stroeme, dateien: [])
        let index = z.ton[position]
        let abdruck = index.flatMap { i in stroeme.first { $0.type == "Audio" && $0.index == i } }
            .map { Spurabdruck(strom: $0, in: stroeme, name: spuren[position].name) }
            ?? Spurabdruck(spur: spuren[position].spur)
        sperre.lock()
        if _wiedergabe.map(Self.schluessel) == Self.schluessel(w) { _wiedergabe?.spuren.ton = index }
        sperre.unlock()
        protokoll("Spuren: Ton von Hand \(index.map(String.init) ?? "?")")
        return Self.gedaechtnisSchreiben(gedaechtnis, Spurgedaechtnis.titel(fuer: w.item), .spur(abdruck))
    }

    /// Untertitel von Hand, `id` -1 heisst aus — auch das gilt fuer die ganze Serie.
    public func untertitelVonHand(untertitel: String, id: Int, gedaechtnis: String) -> String {
        guard let w = sperreLesen({ _wiedergabe }) else { return gedaechtnis }
        let titel = Spurgedaechtnis.titel(fuer: w.item)
        let spuren = Self.spuren(untertitel)
        guard id >= 0, let position = spuren.firstIndex(where: { $0.id == id }) else {
            sperre.lock()
            if _wiedergabe.map(Self.schluessel) == Self.schluessel(w) {
                _wiedergabe?.offenerUntertitel = nil; _wiedergabe?.spuren.untertitel = -1
            }
            sperre.unlock()
            protokoll("Spuren: Untertitel von Hand aus")
            return Self.gedaechtnisSchreiben(gedaechtnis, titel, .aus)
        }
        let stroeme = w.plan.quelle?.mediaStreams ?? []
        let z = Spurzuordnung.bilden(ton: [], untertitel: spuren.map(\.spur), stroeme: stroeme, dateien: w.dateien)
        let index = z.untertitel[position]
        let abdruck = index.flatMap { i in stroeme.first { $0.type == "Subtitle" && $0.index == i } }
            .map { Spurabdruck(strom: $0, in: stroeme, name: spuren[position].name) }
            ?? Spurabdruck(spur: spuren[position].spur)
        sperre.lock()
        if _wiedergabe.map(Self.schluessel) == Self.schluessel(w) {
            _wiedergabe?.offenerUntertitel = nil; _wiedergabe?.spuren.untertitel = index
        }
        sperre.unlock()
        protokoll("Spuren: Untertitel von Hand \(index.map(String.init) ?? "?")")
        return Self.gedaechtnisSchreiben(gedaechtnis, titel, .spur(abdruck))
    }

    /// Lesbare Namen fuer die Spurlisten. Ton: „Deutsch · AAC · 5.1" (b1b5f82) — aus der Spur selbst,
    /// fehlt dort der Codec, aus dem zugeordneten Strom. Untertitel: Sprache, bei gleichen Namen oder
    /// einer Datei das Format; `erzwungen`/`datei` haengt Kotlin uebersetzt an. libVLC 3 nennt Spuren
    /// sonst „Track 1 - [English]".
    public func spurnamen(ton: String, untertitel: String) -> String {
        let tonspuren = Self.spuren(ton), utspuren = Self.spuren(untertitel)
        let w = sperreLesen { _wiedergabe }
        let stroeme = w?.plan.quelle?.mediaStreams ?? []
        let z = Spurzuordnung.bilden(ton: tonspuren.map(\.spur), untertitel: utspuren.map(\.spur),
                                     stroeme: stroeme, dateien: w?.dateien ?? [])
        let tonnamen = tonspuren.enumerated().map { position, eingabe -> Spurname in
            let spur = eingabe.spur
            let strom = z.ton[position].flatMap { i in stroeme.first { $0.type == "Audio" && $0.index == i } }
            let eigen = Technikangaben.tonspurname(sprache: spur.sprache, codec: spur.codec, kanaele: spur.kanaele)
            let vomServer = strom.flatMap {
                Technikangaben.tonspurname(sprache: $0.language, codec: Technikangaben.codecname($0.codec), kanaele: $0.channels)
            }
            let text = spur.codec == nil ? (vomServer ?? eigen) : (eigen ?? vomServer)
            return Spurname(id: eingabe.id, text: text ?? eingabe.name, erzwungen: false, datei: false)
        }
        let utStroeme = utspuren.indices.map { position in
            z.untertitel[position].flatMap { i in stroeme.first { $0.type == "Subtitle" && $0.index == i } }
        }
        let utnamen = utspuren.enumerated().map { position, eingabe -> Spurname in
            guard let strom = utStroeme[position] else {
                let sprache = eingabe.spur.sprache.flatMap { Technikangaben.sprache($0) }
                return Spurname(id: eingabe.id, text: sprache ?? eingabe.name, erzwungen: false,
                                datei: eingabe.spur.zusatzkennung != nil)
            }
            let sprache = strom.sprachname ?? eingabe.name
            let doppelt = utStroeme.filter { ($0?.sprachname ?? "") == (strom.sprachname ?? "") }.count > 1
            let teile = [sprache, doppelt || strom.isExternal == true ? Technikangaben.codecname(strom.codec) : nil]
            return Spurname(id: eingabe.id, text: teile.compactMap { $0 }.joined(separator: " · "),
                            erzwungen: strom.isForced == true, datei: strom.isExternal == true)
        }
        return Self.kodiert(Spurnamenantwort(ton: tonnamen, untertitel: utnamen))
    }

    private static func spuren(_ json: String) -> [Spureingabe] {
        (try? JSONDecoder().decode([Spureingabe].self, from: Data(json.utf8))) ?? []
    }

    /// Dasselbe Format wie `Spurgedaechtnis`: je Titel leer (aus), ein `Spurabdruck` als JSON, oder
    /// ein alter Spurname.
    private static func gedaechtnisLesen(_ ablage: String, _ titel: String) -> Spurgedaechtnis.Wahl? {
        guard let alle = try? JSONDecoder().decode([String: String].self, from: Data(ablage.utf8)),
              let roh = alle[titel] else { return nil }
        if roh.isEmpty { return .aus }
        if roh.hasPrefix("{"), let abdruck = try? JSONDecoder().decode(Spurabdruck.self, from: Data(roh.utf8)) {
            return .spur(abdruck)
        }
        return .name(roh)
    }

    private static func gedaechtnisSchreiben(_ ablage: String, _ titel: String, _ wahl: Spurgedaechtnis.Wahl) -> String {
        var alle = (try? JSONDecoder().decode([String: String].self, from: Data(ablage.utf8))) ?? [:]
        switch wahl {
        case .aus: alle[titel] = ""
        case .name(let name): alle[titel] = name
        case .spur(let abdruck):
            alle[titel] = (try? JSONEncoder().encode(abdruck)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        return kodiert(alle)
    }

    // MARK: Technikschild

    /// Die festen Zeilen des Technikschilds, einmal je Titel: Auslieferung, Grund, Bild, Video, Ton,
    /// Untertitel, Datei, Bedarf. `art` ist `gut`, `warnend` oder leer; `schluessel` die Beschriftung
    /// fuer den Katalog. Die Werte formatiert `Technikangaben`, wie auf iOS.
    public func technikFest() -> String {
        sperre.lock(); let w = _wiedergabe; _zaehlwerk = nil; sperre.unlock()
        guard let w else { return "[]" }
        let plan = w.plan
        var zeilen = [Technikzeile(text: Technikangaben.auslieferung(plan.method),
                                   art: Technikangaben.gewicht(plan.method) == .gut ? "gut" : "warnend")]
        if plan.method == .transcode, let grund = plan.reasons.first {
            zeilen.append(Technikzeile(text: grund.text, art: "warnend"))
        }
        if let q = plan.quelle {
            let stroeme = q.mediaStreams ?? []
            let video = Dateiangaben.videospur(q)
            let ton = stroeme.first { $0.type == "Audio" }
            let untertitel = stroeme.first { $0.type == "Subtitle" }
            func teile(_ werte: [String?]) -> String? {
                let da = werte.compactMap { $0 }
                return da.isEmpty ? nil : da.joined(separator: " · ")
            }
            if let bild = Technikangaben.bildzeile(breite: video?.width, hoehe: video?.height, tiefe: nil, umfang: video?.videoRangeType.map { String(describing: $0) }) {
                zeilen.append(Technikzeile(text: bild, art: ""))
            }
            if let v = teile([Technikangaben.codecname(video?.codec), Technikangaben.bildrate(video?.bildrate)]) {
                zeilen.append(Technikzeile(text: v, art: ""))
            }
            if let t = teile([Technikangaben.codecname(ton?.codec), Technikangaben.kanalwort(ton?.channels), Technikangaben.sprache(ton?.language)]) {
                zeilen.append(Technikzeile(text: t, art: "", schluessel: "Ton"))
            }
            if let u = teile([Technikangaben.codecname(untertitel?.codec), Technikangaben.sprache(untertitel?.language)]) {
                zeilen.append(Technikzeile(text: u, art: "", schluessel: "Untertitel"))
            }
            if let c = Dateiangaben.container(q) { zeilen.append(Technikzeile(text: c, art: "", schluessel: "Datei")) }
            if let groesse = q.size, let dauer = w.item.runtimeSeconds, dauer > 0,
               let bedarf = Technikangaben.bitrate(Double(groesse) * 8 / dauer) {
                zeilen.append(Technikzeile(text: "Ø " + bedarf, art: "", schluessel: "Datei braucht"))
            }
        }
        return (try? json(zeilen)) ?? "[]"
    }

    /// Ein Messpunkt aus VLCs Zaehlern — `Zaehlwerk` rechnet Raten, Lauf und Vorrat ueber sein Fenster.
    /// „zu spät" zaehlt libVLC fuer Android nicht; es geht als 0 hinein und wird nicht angezeigt.
    public func technikTakt(gelesen: Int64, entpackt: Int64, gezeigt: Int64, verworfen: Int64, videoBloecke: Int64,
                            tonBloecke: Int64, tonGespielt: Int64, tonVerloren: Int64, beschaedigt: Int64, spruenge: Int64,
                            stelle: Double, laeuft: Bool) -> String {
        func u(_ x: Int64) -> UInt64 { UInt64(max(0, x)) }
        let roh = Zaehlwerk.Rohwerte(gelesen: u(gelesen), entpackt: u(entpackt), gezeigt: u(gezeigt), verworfen: u(verworfen),
                                     zuSpaet: 0, videoBloecke: u(videoBloecke), tonBloecke: u(tonBloecke), tonGespielt: u(tonGespielt),
                                     tonVerloren: u(tonVerloren), beschaedigt: u(beschaedigt), spruenge: u(spruenge))
        sperre.lock(); let vorher = _zaehlwerk; let w = _wiedergabe; sperre.unlock()
        guard let werk = Zaehlwerk(roh, stelle: stelle, laeuft: laeuft, vorher: vorher) else { return "{}" }
        sperre.lock(); _zaehlwerk = werk; sperre.unlock()
        let quelle = w?.plan.quelle
        let soll = quelle.flatMap { Dateiangaben.videospur($0)?.bildrate }
        var jeSekunde: Double?
        if let groesse = quelle?.size, let dauer = w?.item.runtimeSeconds, dauer > 0 { jeSekunde = Double(groesse) / dauer }
        return (try? json(Technikantwort(
            eingang: Technikangaben.bitrate(werk.eingang), demuxer: Technikangaben.bitrate(werk.demuxer),
            zeigt: werk.zeigtProSekunde, gezeigt: roh.gezeigt, soll: soll, lauf: werk.laufAnteil,
            dekodiert: werk.dekodiertProSekunde,
            vorratSekunden: jeSekunde.flatMap { $0 > 0 ? Double(werk.vorratBytes) / $0 : nil },
            vorratKiB: werk.vorratBytes / 1024, verworfen: roh.verworfen, tonVerloren: roh.tonVerloren,
            beschaedigt: roh.beschaedigt, spruenge: roh.spruenge))) ?? "{}"
    }

    /// `Bewertungsfrage.zaehltAlsFertig` — ab 90 %, und nur bei mehr als einer Minute.
    public static func bewertungZaehlt(position: Double, dauer: Double) -> Bool {
        Bewertungsfrage.zaehltAlsFertig(position: position, dauer: dauer)
    }

    /// `Bewertungsfrage.faellig` — ab dem dritten fertigen Titel, einmal je Fassung.
    public static func bewertungFaellig(fertig: Int, zuletztGefragt: String, fassung: String) -> Bool {
        Bewertungsfrage.faellig(fertig: fertig, zuletztGefragt: zuletztGefragt.isEmpty ? nil : zuletztGefragt, fassung: fassung)
    }

    /// `Gemeinschaft.anstoss` — nach einem zu Ende geschauten Titel: „bewertung", „discord" oder "".
    /// `zuletztGefragt` leer heisst: noch nie gefragt.
    public static func gemeinschaftAnstoss(fertig: Int, zuletztGefragt: String, fassung: String,
                                           discordGezeigt: Bool, bewertungMoeglich: Bool) -> String {
        Gemeinschaft.anstoss(fertig: fertig, bewertungZuletzt: zuletztGefragt.isEmpty ? nil : zuletztGefragt,
                             fassung: fassung, discordGezeigt: discordGezeigt,
                             bewertungMoeglich: bewertungMoeglich)?.rawValue ?? ""
    }

    /// Die Adressen aus `Gemeinschaft`: „discord", „discordKurz", „play", „fehlerKurz",
    /// sonst das GitHub-Issue mit Fassung und Plattform.
    public static func gemeinschaftAdresse(art: String, fassung: String, plattform: String) -> String {
        switch art {
        case "discord": Gemeinschaft.discord.absoluteString
        case "discordKurz": Gemeinschaft.discordKurz
        case "play": Gemeinschaft.playStore.absoluteString
        case "fehlerKurz": Gemeinschaft.fehlerKurz
        default: Gemeinschaft.fehlerMelden(fassung: fassung, plattform: plattform).absoluteString
        }
    }

    /// `Auffrischung.faelligBeiRueckkehr` — neu laden, wenn der letzte Stand aelter als 30 s ist.
    /// `zuletztMs` in Millisekunden seit 1970, 0 heisst: noch nie geladen.
    public static func auffrischungFaellig(zuletztMs: Int64) -> Bool {
        Auffrischung.faelligBeiRueckkehr(zuletzt: zuletztMs > 0 ? Date(timeIntervalSince1970: Double(zuletztMs) / 1000) : nil)
    }

    // MARK: Fernsteuerung

    /// **Faehigkeiten melden und zuhoeren** — `AppModel.fernsteuerungStarten`. Beides ist noetig:
    /// ohne Meldung bleiben die Knoepfe im Dashboard grau, ohne Socket kommen die Befehle nie an.
    /// Und ohne beides liefert `Sessions?controllableByUserId` diese Sitzung nicht — kein anderes
    /// Geraet bietet dann „Hier weiterschauen" an.
    public func fernsteuerungStarten() async {
        sperre.lock(); let c = _client; let schon = _fern != nil; sperre.unlock()
        guard let c, !schon else { return }
        try? await c.faehigkeitenMelden()
        guard let steuerung = try? await c.fernsteuerung() else { return }
        sperre.lock()
        if _fern != nil { sperre.unlock(); return }
        _fern = steuerung
        sperre.unlock()
        let ablage = fernablage
        await steuerung.starten { befehl in ablage.ablegen(befehl) }
    }

    /// Beim Abmelden und Kontowechsel — zuerst vergessen, damit ein neuer Start nicht an der alten haengt.
    public func fernsteuerungBeenden() async {
        sperre.lock(); let alt = _fern; _fern = nil; sperre.unlock()
        await alt?.beenden()
        _ = fernablage.abholen()
    }

    /// Was seit dem letzten Abholen ankam — der Player holt es in seinem Takt ab.
    public func fernbefehle() -> String {
        Self.kodiert(fernablage.abholen())
    }

    // MARK: Hier weiterschauen

    /// Was auf einem anderen Geraet desselben Kontos laeuft und sich uebernehmen laesst — die Regel
    /// (`Uebernahme.angebote`: nicht wir, dasselbe Konto, nimmt Befehle, in den letzten 90 s bewegt)
    /// steht im Paket. **Ein Fehler ist hier kein Fehler**: dann gibt es eben kein Angebot.
    public func uebernahmeAngebote() async -> String {
        sperre.lock(); let c = _client; let s = _sitzung; sperre.unlock()
        guard let c, let s, let alle = try? await c.fremdsitzungen() else { return "[]" }
        let angebote = Uebernahme.angebote(aus: alle, eigeneGeraeteID: geraeteID, eigeneBenutzerID: s.userID)
        return Self.kodiert(angebote.compactMap { f -> Angebotantwort? in
            guard let titel = f.laeuft, !titel.id.isEmpty else { return nil }
            let art: String
            switch f.geraeteart {
            case .telefon: art = "telefon"
            case .tablet: art = "tablet"
            case .rechner: art = "rechner"
            case .fernseher: art = "fernseher"
            case .unbekannt: art = "unbekannt"
            }
            let stelle = f.stand?.stelle ?? 0
            return Angebotantwort(id: f.id, itemID: titel.id, geraet: f.geraetename, art: art,
                                  titelzeile: f.titelzeile, stelle: stelle, stelleText: zeitText(stelle))
        })
    }

    /// Das andere Geraet anhalten. **Leer heisst: angehalten** — erst dann startet Android hier.
    /// Laeuft es dort weiter, stuenden zwei Tonspuren im Raum.
    public func uebernehmen(sitzung: String) async -> String {
        guard let c = client else { return "nichtVerbunden" }
        do { try await c.fremdbefehl(.beenden, an: sitzung); return "" }
        catch { return kernFehlertext(error) }
    }

    // MARK: Downloads

    /// Posten fuer einen Download, samt der Bilder, die mit auf die Platte kommen. **Dieselbe Quelle,
    /// die der Player naehme** (H2) — die erste des Titels, sonst die aus dem Abspielplan.
    public func downloadPosten(ids: [String]) async -> String {
        sperre.lock(); let c = _client; let a = _adressen; let s = _sitzung; sperre.unlock()
        guard let c, let a, let konto = s?.userID else { return "[]" }
        let grenze = profilBitrate
        var geholt: [String: (Item, MediaSource?)] = [:]
        await withTaskGroup(of: (String, Item, MediaSource?)?.self) { gruppe in
            for id in ids {
                gruppe.addTask {
                    guard let i = try? await c.item(id: id) else { return nil }
                    if let q = i.mediaSources?.first { return (id, i, q) }
                    let plan = (try? await c.playbackPlan(for: id, profile: .vlc(maxBitrate: grenze))) ?? nil
                    return (id, i, plan?.quelle)
                }
            }
            for await r in gruppe { if let r { geholt[r.0] = (r.1, r.2) } }
        }
        var antwort: [Downloadantwort] = []
        for id in ids {
            guard let (i, q) = geholt[id] else { continue }
            let folge = i.type == "Episode"
            let posten = Downloadposten(
                id: i.id, konto: konto, art: folge ? .folge : .film, titel: i.name,
                serie: folge ? i.seriesName : nil, serienId: folge ? i.seriesId : nil,
                staffel: folge ? i.parentIndexNumber : nil, folge: folge ? i.indexNumber : nil,
                laufzeitTicks: i.runTimeTicks, container: q?.container, quelle: q?.id, bytes: q?.size ?? 0,
                gesehen: i.userData?.played ?? false)
            let bild: URL? = folge ? await c.imageURL(for: i, maxHeight: 220)
                                   : a.bauen(itemID: i.id, marke: i.imageTags?["Primary"], mass: .hoechstensHoch(600))
            let serienbild: URL? = folge ? i.seriesId.flatMap { a.bauen(itemID: $0, marke: nil, mass: .hoechstensHoch(600)) } : nil
            antwort.append(Downloadantwort(posten: posten, bild: bild?.absoluteString, serienbild: serienbild?.absoluteString))
        }
        return Self.kodiert(antwort)
    }

    /// Dieselbe Adresse wie beim Streamen, ohne Sitzung — sonst stuende das Geraet am Server als
    /// „spielt gerade" da. Nicht `/Items/{id}/Download`: das braucht ein eigenes Recht.
    public func downloadAdresse(id: String, quelle: String) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let c = client else { throw Kernfehler.nichtVerbunden }
            return try await c.downloadURL(itemID: id, mediaSourceID: quelle.isEmpty ? nil : quelle).absoluteString
        }
    }

    private static func postenLesen(_ roh: String) -> [Downloadposten] {
        (try? JSONDecoder().decode([Downloadposten].self, from: Data(roh.utf8))) ?? []
    }

    public static func downloadNaechster(liste: String, imWLAN: Bool, nurUeberWLAN: Bool) -> String {
        Downloadregeln.naechster(aus: postenLesen(liste), imWLAN: imWLAN, nurUeberWLAN: nurUeberWLAN)?.id ?? ""
    }

    public static func downloadDarfLaden(imWLAN: Bool, nurUeberWLAN: Bool) -> Bool {
        Downloadregeln.darfLaden(imWLAN: imWLAN, nurUeberWLAN: nurUeberWLAN)
    }

    /// **Der Satz zu einem HTTP-Status, den der Download bekommen hat.**
    ///
    /// Der Download selbst laeuft auf Android in Kotlin, weil er anhalten und fortsetzen koennen
    /// muss; die Worte kommen trotzdem von hier. Sonst stuende in Kotlin eine zweite Satzliste
    /// neben `lesbarerFehler` — und bis dahin stand auf der Downloadseite woertlich „HTTP 404",
    /// egal in welcher Sprache das Geraet lief.
    public static func downloadFehlertext(status: Int) -> String {
        lesbarerFehler(JellyfinError.http(status: status, body: nil))
    }

    public static func downloadPlatz(bytes: Int64, frei: Int64, liste: String) -> String {
        let p = Downloadregeln.platz(fuer: bytes, frei: frei, vorhanden: postenLesen(liste))
        return kodiert(Platzantwort(reicht: p.reicht, freiDanach: p.freiDanach, entbehrlich: p.entbehrlich.map(\.id),
                                    entbehrlichBytes: p.entbehrlichBytes, reichtNachAufraeumen: p.reichtNachAufraeumen))
    }

    /// H12: eine Serie ist eine Zeile.
    public static func downloadGruppen(liste: String) -> String {
        kodiert(Downloadregeln.gruppiert(postenLesen(liste)).map { g -> Downloadgruppenantwort in
            switch g {
            case let .einzeln(p): Downloadgruppenantwort(id: g.id, titel: g.titel, bytes: g.bytes, serienId: nil, folgen: [p.id])
            case let .serie(sid, _, f): Downloadgruppenantwort(id: g.id, titel: g.titel, bytes: g.bytes, serienId: sid, folgen: f.map(\.id))
            }
        })
    }

    public static func downloadGroesse(bytes: Int64) -> String { Downloadregeln.groesse(bytes) }

    /// Gesehen und „noch auf dem Server" nachziehen. **Ohne Antwort bleibt alles, wie es war** —
    /// unterwegs antwortet kein Server, und sonst stuende an jedem Titel „nicht mehr auf dem Server".
    public func downloadsNachziehen(liste: String) async -> String {
        guard let c = client else { return liste }
        var posten = Self.postenLesen(liste)
        guard !posten.isEmpty else { return liste }
        let ids = posten.map(\.id)
        var vorhanden: Set<String> = []
        var gesehen: Set<String> = []
        for ab in stride(from: 0, to: ids.count, by: 100) {
            let stueck = Array(ids[ab ..< min(ab + 100, ids.count)])
            guard let antwort = try? await c.items(limit: stueck.count, ids: stueck) else { return liste }
            for t in antwort.items {
                vorhanden.insert(t.id)
                if t.istGesehen { gesehen.insert(t.id) }
            }
        }
        for i in posten.indices {
            posten[i].nochAufDemServer = vorhanden.contains(posten[i].id)
            if vorhanden.contains(posten[i].id) { posten[i].gesehen = gesehen.contains(posten[i].id) }
        }
        return Self.kodiert(posten)
    }

    /// Wiedergabe von der Platte — **vor jedem Server**, damit im Flugzeug kein Zeitlimit wartet.
    /// `bild` ist die abgelegte Datei fuer die Mediensteuerung.
    public func wiedergabeVonDerPlatte(posten: String, pfad: String, bild: String) throws -> String {
        let p = try JSONDecoder().decode(Downloadposten.self, from: Data(posten.utf8))
        let plan = PlaybackPlan.vonDerPlatte(URL(fileURLWithPath: pfad), container: p.container, mediaSourceID: p.quelle)
        let item = p.alsItem
        let w = Wiedergabe(item: item, plan: plan, abschnitte: [], naechste: nil)
        sperre.lock(); _wiedergabe = w; _folgenwechsel = Folgenwechsel(); sperre.unlock()
        let istFolge = item.type == "Episode"
        let kopfzeile = (istFolge && !(item.seriesName ?? "").isEmpty) ? item.seriesName! : item.name
        return try json(Spielplanantwort(
            url: plan.url.absoluteString, lossless: plan.isLossless, methode: plan.method.rawValue,
            titel: item.name, untertitel: item.kontextzeile ?? "",
            naechste: false, dateizeile: dateizeile(plan), serie: item.seriesName, kuerzel: item.folgenkuerzel,
            bild: bild.isEmpty ? nil : bild,
            itemId: item.id, episode: istFolge, serieId: item.seriesId, staffelId: item.seasonId,
            kopfzeile: kopfzeile, staffelNr: istFolge ? item.parentIndexNumber : nil,
            folgeNr: istFolge ? item.indexNumber : nil,
            nebenzeile: istFolge ? nil : (item.nebenzeile.isEmpty ? nil : item.nebenzeile)))
    }

    // MARK: Nachmeldungen

    private static func nachmeldungenLesen(_ roh: String) -> [Nachmeldung] {
        (try? JSONDecoder().decode([Nachmeldung].self, from: Data(roh.utf8))) ?? []
    }

    /// Eine je Titel und Konto; die neuere gewinnt.
    public static func nachmeldungAufnehmen(ablage: String, meldung: String) -> String {
        guard let m = try? JSONDecoder().decode(Nachmeldung.self, from: Data(meldung.utf8)) else { return ablage }
        return kodiert(Nachmelderegeln.aufnehmen(m, in: nachmeldungenLesen(ablage)))
    }

    /// Nach einer erfolgreichen Verbindung. **Beim ersten Fehler abbrechen** — dann ist der Server
    /// wieder weg, und die uebrigen stuenden danach als verloren da.
    public func nachmeldungenAbschicken(ablage: String) async -> String {
        sperre.lock(); let c = _client; let s = _sitzung; sperre.unlock()
        let alle = Self.nachmeldungenLesen(ablage)
        guard let c, let konto = s?.userID else { return ablage }
        let offen = Nachmelderegeln.faellig(alle, konto: konto)
        guard !offen.isEmpty else { return ablage }
        var geschafft: [String] = []
        for m in offen {
            let plan = PlaybackPlan.vonDerPlatte(URL(fileURLWithPath: "/"), container: nil)
            do {
                try await c.reportStopped(itemID: m.itemID, plan: plan, positionTicks: m.ticks)
                geschafft.append(m.id)
            } catch { break }
        }
        return Self.kodiert(Nachmelderegeln.erledigt(geschafft, in: alle))
    }

    // MARK: Seerr

    private var seerr: SeerrClient? { sperre.lock(); defer { sperre.unlock() }; return _seerr }

    /// Setzt den gemerkten Zugang ein — Kotlin legt ihn je Jellyfin-Server verschluesselt ab.
    public func seerrSetzen(zugang: String) {
        let z = try? JSONDecoder().decode(Seerrzugang.self, from: Data(zugang.utf8))
        sperre.lock(); _seerr = z.map { SeerrClient(zugang: $0) }; sperre.unlock()
    }

    /// Auch der Keks der Verbindung geht weg, nicht nur der gemerkte Zugang:
    /// eine noch gueltige Sitzung im Speicher laesst Seerr beim naechsten
    /// Anmelden keine neue ausstellen (`Seerr.kekseVergessen`).
    public func seerrTrennen() {
        sperre.lock()
        let adresse = _seerr?.adresse
        _seerr = nil
        sperre.unlock()
        if let adresse { Seerr.kekseVergessen(fuer: adresse) }
    }

    /// Verbindet mit Jellyfins eigenem Namen und Passwort. **Ein zweites Schema nur, wenn es geraten
    /// war** (`Seerr.adressen`) — und nur nach einem Netzfehler, nie nach einem falschen Passwort.
    /// Antwort: der Zugang als JSON; das Passwort bleibt nirgends liegen.
    public func seerrVerbinden(adresse: String, benutzer: String, passwort: String) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            let adressen = Seerr.adressen(aus: adresse)
            guard !adressen.isEmpty else { throw Kernfehler.adresse(adresse) }
            var letzter: Error = Kernfehler.adresse(adresse)
            for url in adressen {
                do {
                    let zugang = try await SeerrClient.anmelden(an: url, benutzer: benutzer, passwort: passwort)
                    sperre.lock(); _seerr = SeerrClient(zugang: zugang); sperre.unlock()
                    return try json(zugang)
                } catch let fehler as URLError {
                    letzter = fehler
                }
            }
            throw letzter
        }
    }

    public func seerrGilt() async -> Bool {
        guard let s = seerr else { return false }
        return await s.gilt()
    }

    /// Nur, was der eigene Server noch nicht hat — das andere steht im oberen Block.
    public func seerrSuchen(begriff: String) async -> String {
        guard let s = seerr, Anzeigeregeln.suchbegriffTaugt(begriff) else { return "[]" }
        return Self.kodiert((await s.suchen(begriff)).filter { !$0.stand.schonDa }.map(Self.seerrkachel))
    }

    public func seerrFilmografie(tmdb: Int) async -> String {
        guard let s = seerr else { return "[]" }
        return Self.kodiert((await s.filmografie(person: tmdb)).filter { !$0.stand.schonDa }.map(Self.seerrkachel))
    }

    /// Details und Vorschlaege — Seerr holt beides nebeneinander; fehlen die Vorschlaege, steht der Rest trotzdem.
    public func seerrDetail(art: String, id: Int) async -> String {
        guard let s = seerr, let d = await s.detail(art: art, id: id) else { return "{}" }
        return Self.kodiert(Seerrdetailantwort(
            beschreibung: d.beschreibung, genres: d.genres, laufzeit: d.laufzeit, bewertung: d.bewertung,
            staffeln: d.staffeln.map { Seerrstaffelantwort(nummer: $0.nummer, folgen: $0.folgen, stand: $0.stand.rawValue, anfragbar: $0.stand.anfragbar) },
            besetzung: d.besetzung.map { Personantwort(id: String($0.id), name: $0.name, rolle: $0.rolle, bild: $0.bild()?.absoluteString) },
            aehnliches: d.aehnliches.map(Self.seerrkachel)))
    }

    /// Leer heisst: erledigt. `staffeln` als „1,2" — bei einem Film ohne Bedeutung, bei einer Serie nie leer.
    public func seerrAnfragen(art: String, id: Int, staffeln: String) async -> String {
        guard let s = seerr else { return "nichtAngemeldet" }
        let nummern = staffeln.split(separator: ",").compactMap { Int($0) }
        if art == "tv", nummern.isEmpty { return "" }
        do { try await s.anfragen(art: art, id: id, staffeln: art == "tv" ? nummern : nil); return "" }
        catch { return kernFehlertext(error) }
    }

    private static func seerrkachel(_ t: Seerrtreffer) -> Seerrkachelantwort {
        Seerrkachelantwort(id: t.id, art: t.art, titel: t.titel, jahr: t.jahr, plakat: t.plakat()?.absoluteString,
                           kulisse: t.kulisse()?.absoluteString, stand: t.stand.rawValue, anfragbar: t.stand.anfragbar)
    }

    // MARK: Person

    /// Die Personenseite — `PersonView.laden()` ohne Seerr: die Auskunft ueber die Person, ihre
    /// Titel auf dem Server (`JellyfinClient.titel(person:)`, die Regel steht im Paket) und die
    /// Querbilder fuer das wechselnde Banner.
    public func person(id: String) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let c = client, let a = adressen else { throw Kernfehler.nichtVerbunden }
            async let eigene = c.titel(person: id)
            let auskunft = try? await c.item(id: id)
            let titel = await eigene
            // **Nur, was wirklich quer liegt** (`querbildEcht`) — ein beschnittenes Plakat gehoert
            // nicht in den Wechsel. Gibt es keines, steht irgendein Kopfbild da.
            var banner = titel.compactMap { Bildwahl.kopf($0, adressen: a)?.absoluteString }
            // **Derselbe Ersatz wie auf der Serienseite**, mit derselben Folge als
            // Rueckfall (`AppModel.kopfbildErsatzSuchen`) — sonst landet hier ein
            // anderes Bild als das, von dem man gerade kam. Eine Serie ohne
            // eigenen Hintergrund hat auf der Serienseite den Hintergrund ihrer
            // naechsten Folge; ohne diesen Rueckfall waere es hier das Plakat.
            if banner.isEmpty, let erstes = titel.first {
                var folge: Item?
                if erstes.type == "Series" {
                    if let naechste = try? await c.naechsteFolgeDerSerie(seriesID: erstes.id) { folge = naechste }
                    if folge == nil { folge = (try? await c.folgen(seriesID: erstes.id))?.first }
                }
                if let url = Bildwahl.kopfMitErsatz(erstes, folge: folge, adressen: a) {
                    banner = [url.absoluteString]
                }
            }
            let bild: URL? = a.bauen(itemID: id, marke: auskunft?.imageTags?["Primary"], mass: .hoechstensHoch(300))
            let geboren = auskunft?.tagesdatum.flatMap { k -> String? in
                guard let jahr = k.year, let monat = k.month, let tag = k.day else { return nil }
                return String(format: "%04d-%02d-%02d", jahr, monat, tag)
            }
            return try json(Personenseitenantwort(
                beschreibung: auskunft?.beschreibung, geboren: geboren,
                ort: auskunft?.productionLocations?.first { !$0.isEmpty },
                bild: bild?.absoluteString, banner: banner,
                titel: titel.map { rasterkachel($0, a) }, tmdb: auskunft?.tmdbKennung))
        }
    }

    /// Aehnliche Titel und Extras — `AppModel.aehnliche(_:)` und `extras(_:)`. Fehler geben leere Reihen.
    public func titelUmfeld(id: String) async throws -> String {
        return try await lesbarWerfen { () async throws -> String in
            guard let c = client, let a = adressen else { throw Kernfehler.nichtVerbunden }
            async let aehnlich = try? c.aehnliche(itemID: id)
            async let zusatz = try? c.extras(itemID: id)
            let ae = await aehnlich ?? []
            let ex = await zusatz ?? []
            return try json(Umfeldantwort(
                aehnliche: ae.map { rasterkachel($0, a) },
                extras: ex.map { e in
                    Extraantwort(id: e.id, name: e.name, bild: Bildwahl.quer(e, adressen: a)?.url.absoluteString,
                                 laufzeit: Anzeigeregeln.laufzeitZeigen(sekunden: e.runtimeSeconds)
                                     ? e.runtimeSeconds.map { laufzeit($0) } : nil)
                }))
        }
    }

    /// Der erste Trailer, der als eigene Datei auf dem Server liegt — steht auf tvOS vorn in den
    /// Extras der Filmseite (`DetailView.task`: `model.trailer(zu:)`, `extras.insert(vorschau, at: 0)`).
    /// Leer JSON-Objekt, wenn es keinen gibt oder nicht verbunden — Kotlin ueberspringt ihn dann.
    public func lokalerTrailer(id: String) async -> String {
        guard let c = client, let a = adressen else { return "{}" }
        guard let t = (try? await c.trailer(zu: id))?.first else { return "{}" }
        return Self.kodiert(Extraantwort(
            id: t.id, name: t.name, bild: Bildwahl.quer(t, adressen: a)?.url.absoluteString,
            laufzeit: Anzeigeregeln.laufzeitZeigen(sekunden: t.runtimeSeconds)
                ? t.runtimeSeconds.map { laufzeit($0) } : nil))
    }

    /// Die Folge nach `episode` in derselben Serie — fuer „Nächste Folge abspielen" im Mehr-Blatt
    /// der Serienseite (`Titelhandlung.fuerSerie`, `model.folgeNach`). Leer, wenn keine folgt.
    public func folgeDanach(episode: String, serie: String) async -> String {
        guard let c = client else { return "" }
        guard let naechste = try? await c.folgeNach(itemID: episode, seriesID: serie) else { return "" }
        return naechste.id
    }

    /// Leer heisst: erledigt. Sonst der Grund — `nichtAngemeldet` als Kennung, der Wortlaut steht im App-Katalog.
    public func merken(id: String, an: Bool) async -> String {
        await erledigen { try await $0.setzeMerkliste(itemID: id, an: an) }
    }

    public func gesehen(id: String, an: Bool) async -> String {
        await erledigen { try await $0.setzeGesehen(itemID: id, an: an) }
    }

    public func metadatenAuffrischen(id: String) async -> String {
        await erledigen { try await $0.metadatenAuffrischen(id) }
    }

    private func erledigen(_ tun: (JellyfinClient) async throws -> Void) async -> String {
        guard let c = client else { return "nichtAngemeldet" }
        do { try await tun(c); return "" } catch { return kernFehlertext(error) }
    }

    /// Die Beschriftungen fuer Sortierung und Filter, in der Reihenfolge von `allCases`.
    public static func beschriftungen() -> String {
        let alle = Beschriftungsantwort(
            sortierung: Sortierung.allCases.map { .init(wert: $0.rawValue, text: $0.beschriftung) },
            filter: Bibliotheksfilter.allCases.map { .init(wert: $0.rawValue, text: $0.beschriftung) })
        return (try? JSONEncoder().encode(alle)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Dieselben Zeilen wie `PosterTile`: bei einer Folge Serie und Nummer, sonst Titel und Jahr.
    /// Die Marke kommt aus `Anzeigeregeln.kachelmarke`; Kotlin setzt nur den Wortlaut ein.
    private func rasterkachel(_ i: Item, _ a: Bildadresse) -> Rasterkachelantwort {
        let folge = i.type == "Episode"
        let (marke, zahl): (String?, Int) = switch Anzeigeregeln.kachelmarke(
            art: i.type, staffeln: i.childCount, gesehen: i.userData?.played,
            offeneFolgen: i.userData?.unplayedItemCount) {
        case .gesehen?: ("gesehen", 0)
        case .offen(let n)?: ("offen", n)
        case .staffeln(let n)?: ("staffeln", n)
        case .none: (nil, 0)
        }
        return Rasterkachelantwort(
            id: i.id, titel: folge ? (i.seriesName ?? i.name) : i.name, typ: i.type ?? "",
            unterzeile: folge ? i.folgenkuerzel : i.productionYear.map(String.init),
            plakat: Bildwahl.hochkant(i, adressen: a)?.absoluteString,
            fortschritt: i.userData?.playedPercentage.map { $0 / 100 },
            marke: marke, markenzahl: zahl)
    }

    private func json<T: Encodable>(_ wert: T) throws -> String {
        String(decoding: try JSONEncoder().encode(wert), as: UTF8.self)
    }
}

// MARK: Antworten — was Kotlin liest

struct Serverantwort: Encodable { let name, version, adresse: String }
struct Startseitenantwort: Encodable { let reihen: [Reihenantwort]; let gestoert: Bool }
struct Reihenantwort: Encodable {
    /// Deutscher Wortlaut als Schluessel — Kotlin uebersetzt mit `uebersetzt(...)`.
    let titelSchluessel: String?
    /// Name einer Genre-Reihe, wird nicht uebersetzt.
    let name: String?
    let quer: Bool
    let kacheln: [Kachelantwort]
}
struct Sammlungsantwort: Encodable { let id, name: String }
struct Rasterseitenantwort: Encodable { let titel: [Rasterkachelantwort]; let gesamt: Int }
struct Rasterkachelantwort: Encodable {
    let id, titel, typ: String
    let unterzeile, plakat: String?
    let fortschritt: Double?
    /// `gesehen`, `offen`, `staffeln` — oder nichts.
    let marke: String?
    let markenzahl: Int
}
struct Titelantwort: Encodable {
    let id, name, typ, nebenzeile: String
    /// „2026 · 1 Std. 52 Min." — ohne Gattung, fuer den Fernseher.
    let jahrLaufzeit: String
    let kopfbild: String?
    let bewertung: Double?
    let freigabe: String?
    let planDa, lossless: Bool
    let methode: String?
    let fortsetzenAb: Double?
    let fortsetzenText, beschreibung: String?
    let regie: [String]
    let darsteller: [Personantwort]
    let gemerkt, gesehen: Bool
    let trailer: String?
    let datei: Dateiantwort?
    /// Siehe `Kern.kulisse` — dieselbe Adresse wie `Kachelantwort.kulisse`.
    let kulisse: String?
}
struct Serienantwort: Encodable {
    let id, name: String
    let jahr, staffelzeile: String?
    let staffelzahl: Int?
    let gattungen, kopfbild: String?
    let bewertung: Double?
    let freigabe, beschreibung: String?
    let gemerkt, gesehen: Bool
    let trailer: String?
    let planDa, lossless: Bool
    let methode: String?
    let stand: Standantwort?
    let knopftext: String
    let staffeln: [Staffelantwort]
    let gewaehlt: String?
    let darsteller: [Personantwort]
    /// Siehe `Kern.kulisse` — dieselbe Adresse wie `Kachelantwort.kulisse`.
    let kulisse: String?
}
struct Standantwort: Encodable {
    let id: String
    let fortsetzen: Bool
    let restzeit: String?
    let fortschritt: Double?
    let staffel, folge: Int?
    let ab: Double?
}
struct Staffelantwort: Encodable { let id, name: String }
struct Folgenantwort: Encodable {
    let id, titel: String
    let unterzeile, bild: String?
    let fortschritt: Double?
    let gesehen: Bool
    let ab: Double?
    /// Roh, fuer den Fernseher — siehe `Kern.folgen(serie:staffel:)`.
    let name: String
    let nummer: Int?
    let laufzeitMin: Int?
    let restzeit: String?
}
struct Serverkartenantwort: Encodable { let adresse, host: String; let aktiv: Bool; let konten: [Kontoantwort] }
struct Kontoantwort: Encodable { let kennung, name: String; let aktiv: Bool; let bild: String? }
struct Technikzeile: Encodable { let text, art: String; var schluessel: String? = nil }
struct Technikantwort: Encodable {
    let eingang, demuxer: String?
    let zeigt: Double?
    let gezeigt: UInt64
    let soll, lauf, dekodiert, vorratSekunden: Double?
    let vorratKiB, verworfen, tonVerloren, beschaedigt, spruenge: UInt64
}
struct Wahlantwort: Encodable { let wert, text: String }
struct Pufferantwort: Encodable { let wert, text: String; let netz: Int? }
struct Spielplanantwort: Encodable {
    let url: String
    let lossless: Bool
    let methode, titel, untertitel: String
    let naechste: Bool
    /// „MKV · 1080p · H.264 · German · AAC · Stereo" — fuer den Beleg im Wiedergabeblatt.
    let dateizeile: String?
    let serie, kuerzel, bild: String?
    /// Fuer den Kopf des neuen Players (Vorlage iOS) und die Folgenebene.
    let itemId: String
    let episode: Bool
    let serieId, staffelId: String?
    /// Serie bei einer Folge, sonst der Titel selbst — `titelzeile` auf iOS.
    let kopfzeile: String
    let staffelNr, folgeNr: Int?
    /// Jahr · Laufzeit · Genre, nur beim Film — `metatext`/`item.nebenzeile` auf iOS.
    let nebenzeile: String?
}
struct Wechselantwort: Encodable {
    let ergebnis: String
    var spielplan, fehler, nachmeldung: String?
}
/// Was die nebeneinander laufenden Schritte eines Folgenwechsels zurueckgeben.
final class Wechselablage: @unchecked Sendable {
    private let schloss = NSLock()
    private var _nachmeldung, _fehler, _spielplan: String?
    func setzen(nachmeldung: String) { schloss.lock(); _nachmeldung = nachmeldung.isEmpty ? nil : nachmeldung; schloss.unlock() }
    func setzen(fehler: String) { schloss.lock(); _fehler = fehler; schloss.unlock() }
    func setzen(spielplan: String?) { schloss.lock(); _spielplan = spielplan; schloss.unlock() }
    var nachmeldung: String? { schloss.lock(); defer { schloss.unlock() }; return _nachmeldung }
    var fehler: String? { schloss.lock(); defer { schloss.unlock() }; return _fehler }
    var spielplan: String? { schloss.lock(); defer { schloss.unlock() }; return _spielplan }
}
struct Taktantwort: Encodable {
    let ladeschirmWeg, spurenAnwenden: Bool
    let position: Double
    let angebot: String
    let nach: Double?
    let angebotstext: String
    /// Die Einblendung ohne Steuerung: `nichts`, `knopf` oder `karte` (Countdown, `countdown` 0…1).
    let einblendung: String
    let countdown: Double
    /// Ganze Sekunden bis zum Wechsel — fuer TalkBack („Startet in 5 Sekunden").
    let countdownRest: Int
    /// Wie lange die Fuellung der Karte laeuft — Kotlin animiert den Rest daraus durchgehend.
    let countdownLaenge: Double
    let weiterschalten: Bool
}
struct Personenseitenantwort: Encodable {
    let beschreibung, geboren, ort, bild: String?
    let banner: [String]
    let titel: [Rasterkachelantwort]
    let tmdb: Int?
}
struct Seerrkachelantwort: Encodable {
    let id: Int
    let art, titel: String
    let jahr: Int?
    let plakat, kulisse: String?
    let stand: Int
    let anfragbar: Bool
}
struct Seerrstaffelantwort: Encodable { let nummer, folgen, stand: Int; let anfragbar: Bool }
struct Seerrdetailantwort: Encodable {
    let beschreibung: String?
    let genres: [String]
    let laufzeit: Int?
    let bewertung: Double?
    let staffeln: [Seerrstaffelantwort]
    let besetzung: [Personantwort]
    let aehnliches: [Seerrkachelantwort]
}
struct Personantwort: Encodable { let id, name: String; let rolle, bild: String? }
struct Dateiantwort: Encodable {
    let container, video: String?
    let ton: [String]
    let untertitel: String
    let hatUntertitel: Bool
}
struct Umfeldantwort: Encodable { let aehnliche: [Rasterkachelantwort]; let extras: [Extraantwort] }
struct Extraantwort: Encodable { let id, name: String; let bild, laufzeit: String? }
struct Beschriftungsantwort: Encodable {
    struct Eintrag: Encodable { let wert, text: String }
    let sortierung, filter: [Eintrag]
}
struct Kachelantwort: Encodable {
    let id, name, typ: String
    let unterzeile: String?
    let plakat: String?
    let quer: String?
    let fortschritt: Double?
    /// `gesehen`, `offen`, `staffeln` — oder nichts. Wie `Rasterkachelantwort.marke`.
    let marke: String?
    let markenzahl: Int
    /// Fuer die Kopfzone der Startseite, wenn diese Kachel den Fokus haelt — Jahr, Laufzeit,
    /// Folgenkuerzel, wie `Kopfauskunft.angabenzeile` auf tvOS.
    let angabenzeile: String?
    /// „Noch 50 Minuten" — wie `Restzeitmarke`. `nil` heisst: nichts angefangen.
    let restzeit: String?
    let gesehen: Bool
    /// Nur bei einer Folge gesetzt — der Serienname steht schon in `name`.
    let folgenname: String?
    /// Fuer Android TVs Watch-Next-Reihe — siehe `kachel(_:neuzugang:mitMarke:_:)`.
    let laufzeitSekunden: Double?
    let positionSekunden: Double?
    /// Fuer Android TVs Kopfzone (`Kopfauskunft`) — dieselben drei Angaben, die `Kopfauskunft`
    /// auf tvOS direkt vom vollen `Item` liest (Bewertung, Freigabe, Beschreibung). Die Startseite
    /// des Telefons braucht sie nicht und liest sie nicht.
    let bewertung: Double?
    let freigabe: String?
    let beschreibung: String?
    /// Siehe `Kern.kulisse` — die Kulisse, die auch Film- und Serienseite zeigen.
    let kulisse: String?
}

struct Downloadantwort: Encodable { let posten: Downloadposten; let bild, serienbild: String? }
struct Platzantwort: Encodable {
    let reicht: Bool
    let freiDanach: Int64
    let entbehrlich: [String]
    let entbehrlichBytes: Int64
    let reichtNachAufraeumen: Bool
}
struct Downloadgruppenantwort: Encodable { let id, titel: String; let bytes: Int64; let serienId: String?; let folgen: [String] }
struct Planantwort: Encodable { let lossless: Bool; let methode: String }
struct Trickplayantwort: Encodable { let breite, hoehe, kachelnBreit, kachelnHoch, anzahl, intervall: Int }
struct Angebotantwort: Encodable { let id, itemID: String; let geraet: String?; let art, titelzeile: String; let stelle: Double; let stelleText: String }

struct Fernbefehlantwort: Encodable { let art: String; let wert: Double? }

/// Nimmt Befehle aus dem Socket entgegen, bis der Player sie abholt. Eigene Sperre — der Socket ruft
/// von seinem eigenen Faden aus.
final class Befehlsablage: @unchecked Sendable {
    private let sperre = NSLock()
    private var befehle: [Fernbefehlantwort] = []

    func ablegen(_ befehl: Fernbefehl) {
        let eintrag: Fernbefehlantwort
        switch befehl {
        case .pause: eintrag = .init(art: "pause", wert: nil)
        case .weiter: eintrag = .init(art: "weiter", wert: nil)
        case .umschalten: eintrag = .init(art: "umschalten", wert: nil)
        case .stopp: eintrag = .init(art: "stopp", wert: nil)
        case let .springenAuf(s): eintrag = .init(art: "springen", wert: s)
        case .vor: eintrag = .init(art: "vor", wert: nil)
        case .zurueck: eintrag = .init(art: "zurueck", wert: nil)
        case .naechste: eintrag = .init(art: "naechste", wert: nil)
        case .vorige: eintrag = .init(art: "vorige", wert: nil)
        default: return
        }
        sperre.lock(); befehle.append(eintrag); if befehle.count > 20 { befehle.removeFirst() }; sperre.unlock()
    }

    func abholen() -> [Fernbefehlantwort] {
        sperre.lock(); defer { sperre.unlock() }
        let alle = befehle
        befehle = []
        return alle
    }
}

/// Eine Spur aus libVLC, wie Kotlin sie hereinreicht.
struct Spureingabe: Decodable {
    let id: Int
    /// `audio/<id>`, `spu/<id>`, eine nachgeladene Datei `<md5>/spu/<n>` (wie libVLC 4).
    let kennung: String
    let name: String
    let sprache: String?
    let fourcc: Int?
    let kanaele: Int?

    var spur: Abspielerspur {
        let sprache = (self.sprache?.isEmpty == false) ? self.sprache : Self.klammersprache(name)
        return Abspielerspur(kennung: kennung, name: name, sprache: sprache,
                             codec: fourcc.flatMap { $0 == 0 ? nil : Technikangaben.codecname(vlcKennung: UInt32(truncatingIfNeeded: $0)) },
                             kanaele: kanaele.flatMap { $0 > 0 ? $0 : nil })
    }

    /// libVLC 3 nennt Spuren „Track 1 - [English]" — die Sprache steht in der Klammer.
    static func klammersprache(_ name: String) -> String? {
        guard name.hasSuffix("]"), let auf = name.lastIndex(of: "[") else { return nil }
        let innen = name[name.index(after: auf)..<name.index(before: name.endIndex)]
        return innen.isEmpty ? nil : String(innen)
    }
}
struct Untertiteldateiantwort: Encodable { let index: Int; let adresse: String }
struct Spurwahlantwort: Encodable { let ton: Int?; let untertitel: Int }
struct Spurname: Encodable { let id: Int; let text: String; let erzwungen: Bool; let datei: Bool }
struct Spurnamenantwort: Encodable { let ton: [Spurname]; let untertitel: [Spurname] }
