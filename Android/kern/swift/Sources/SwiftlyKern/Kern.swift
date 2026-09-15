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
    private let geraeteName: String
    private let fassung: String
    private let sperre = NSLock()
    private var _client: JellyfinClient?
    private var _adressen: Bildadresse?
    private var _sitzung: Session?
    private var _wiedergabe: Wiedergabe?
    /// Der Client eines Servers, der gerade aufgenommen wird — `AppModel.aufnahme`. Die laufende
    /// Sitzung bleibt dabei unberuehrt; bricht die Aufnahme ab, ist nichts passiert.
    private var _aufnahme: JellyfinClient?
    /// Der laufende Quick-Connect-Vorgang. Der geheime Teil verlaesst Swift nie.
    private var _quickconnect: Anmeldecode?
    /// Der Zaehlstand des Technikschilds — je Titel neu.
    private var _zaehlwerk: Zaehlwerk?
    /// Seerr — ein Bonus: ohne Zugang gibt es keinen Client, und nichts auf den Seiten deutet darauf hin.
    private var _seerr: SeerrClient?
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
    private struct Wiedergabe {
        let item: Item
        let plan: PlaybackPlan
        var abschnitte: [Abschnitt]
        var naechste: Item?
        var stand = Wiedergabetakt.Stand()
        let start = Date()
    }

    public init(geraeteID: String, geraeteName: String, fassung: String) {
        self.geraeteID = geraeteID
        self.geraeteName = geraeteName
        self.fassung = fassung
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
                       clientVersion: fassung, session: sitzung)
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

    /// Antwort: die Sitzung als JSON — Kotlin legt sie verschluesselt ab und gibt
    /// sie beim naechsten Start an ``sitzungSetzen(json:)`` zurueck.
    public func anmelden(benutzer: String, passwort: String) async throws -> String {
        guard let c = client else { throw Kernfehler.nichtVerbunden }
        let s = try await c.authenticate(username: benutzer, password: passwort)
        let neu = neuerClient(s.serverURL, s)
        setzen(neu, Bildadresse(basis: s.serverURL, token: s.accessToken), s)
        return try json(s)
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

    public func aufnahmeAbbrechen() {
        sperre.lock(); _aufnahme = nil; _quickconnect = nil; sperre.unlock()
    }

    /// Anmelden am aufgenommenen Server. Die Sitzung kommt zurueck; aktiv wird sie erst ueber `sitzungSetzen`.
    public func aufnahmeAnmelden(benutzer: String, passwort: String) async throws -> String {
        guard let c = anmeldeclient(true) else { throw Kernfehler.nichtVerbunden }
        return try json(try await c.authenticate(username: benutzer, password: passwort))
    }

    /// Holt einen Code — am verbundenen oder am aufgenommenen Server. Antwort: der Code.
    public func quickConnectStarten(neuerServer: Bool) async throws -> String {
        guard let c = anmeldeclient(neuerServer) else { throw Kernfehler.nichtVerbunden }
        let vorgang = try await c.quickConnectStarten()
        sperre.lock(); _quickconnect = vorgang; sperre.unlock()
        return vorgang.code
    }

    /// Ob der Code freigegeben ist. Wirft, wenn er abgelaufen ist.
    public func quickConnectFreigegeben(neuerServer: Bool) async throws -> Bool {
        sperre.lock(); let vorgang = _quickconnect; sperre.unlock()
        guard let c = anmeldeclient(neuerServer), let vorgang else { throw Kernfehler.nichtVerbunden }
        return try await c.quickConnectFreigegeben(vorgang)
    }

    /// Der freigegebene Code wird zur Sitzung. Am verbundenen Server gilt sie sofort, wie nach ``anmelden(benutzer:passwort:)``.
    public func quickConnectAnmelden(neuerServer: Bool) async throws -> String {
        sperre.lock(); let vorgang = _quickconnect; sperre.unlock()
        guard let c = anmeldeclient(neuerServer), let vorgang else { throw Kernfehler.nichtVerbunden }
        let s = try await c.anmeldenMitQuickConnect(vorgang)
        sperre.lock(); _quickconnect = nil; sperre.unlock()
        if !neuerServer { setzen(neuerClient(s.serverURL, s), Bildadresse(basis: s.serverURL, token: s.accessToken), s) }
        return try json(s)
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
        let inhalt: [Startreihe: (quer: Bool, neu: Bool, items: [Item])] = [
            .weiterschauen: (true, false, stand.weiterschauen ?? []),
            .naechsteFolge: (false, false, stand.naechsteFolge ?? []),
            .neuzugaenge: (false, true, stand.zuletzt ?? []),
            .neueFilme: (false, true, stand.neueFilme ?? []),
            .neueSerien: (false, true, stand.neueSerien ?? []),
        ]
        var reihen: [Reihenantwort] = Startreihenfolge
            .sichtbar(abgelegt: abgelegt, aus: Set(aus), getrennt: getrennt)
            .compactMap { r in
                guard let (quer, neu, items) = inhalt[r], !items.isEmpty else { return nil }
                return Reihenantwort(titelSchluessel: r.reihentitel, name: nil, quer: quer,
                                     kacheln: items.map { kachel($0, neuzugang: neu, a) })
            }
        reihen += stand.gattungsreihen.map {
            Reihenantwort(titelSchluessel: nil, name: $0.name, quer: false,
                          kacheln: $0.items.map { kachel($0, neuzugang: false, a) })
        }
        return try json(Startseitenantwort(reihen: reihen, gestoert: stand.gestoert))
    }

    /// Dieselben Zeilen wie `HomeView.Kachel` auf dem iPhone: `neuzugangszeile`
    /// in den Neuzugangsreihen, sonst `folgenkuerzel` — beide aus dem Paket.
    private func kachel(_ i: Item, neuzugang: Bool, _ a: Bildadresse) -> Kachelantwort {
        Kachelantwort(
            id: i.id, name: i.seriesName ?? i.name, typ: i.type ?? "",
            unterzeile: neuzugang ? i.neuzugangszeile : i.folgenkuerzel,
            plakat: Bildwahl.hochkant(i, adressen: a)?.absoluteString,
            quer: Bildwahl.quer(i, adressen: a)?.url.absoluteString,
            fortschritt: i.gesehenerAnteil)
    }

    // MARK: Bibliothek

    /// Die Sammlungen einer Art (`movies`, `tvshows`) — `AppModel.bibliotheken(art:)`.
    /// Antwort: `[{"id","name"}]`.
    public func bibliotheken(art: String) async throws -> String {
        guard let c = client else { throw Kernfehler.nichtVerbunden }
        let sammlungen = try await c.userViews().filter { $0.collectionType == art }
        return try json(sammlungen.map { Sammlungsantwort(id: $0.id, name: $0.name) })
    }

    /// Der Name des Servers fuer die Zeile unter dem Titel — leer, wenn er keinen nennt.
    public func servername() async throws -> String {
        guard let c = client else { throw Kernfehler.nichtVerbunden }
        return try await c.publicSystemInfo().serverName ?? ""
    }

    /// Eine Seite einer Bibliothek — dieselbe Abfrage wie `AppModel.items(in:art:sortierung:filter:ab:)`.
    /// `sortierung`/`filter` sind die `rawValue`s aus dem Paket; Unbekanntes faellt auf die Vorgabe.
    public func bibliothekSeite(bibliothek: String, art: String, sortierung: String, filter: String,
                                ab: Int, anzahl: Int) async throws -> String {
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

    // MARK: Titel

    /// Alles fuer die Titelseite in einem Zug — `ItemDetailView.task`: Titel und Abspielplan
    /// parallel. Aehnliches und Extras kommen getrennt (``titelUmfeld(id:)``), damit die Seite
    /// nicht auf sie wartet.
    public func titel(id: String) async throws -> String {
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
        return try json(Titelantwort(
            id: i.id, name: i.name, typ: i.type ?? "", nebenzeile: i.nebenzeile,
            kopfbild: Bildwahl.kopfMitErsatz(i, folge: nil, adressen: a)?.absoluteString,
            bewertung: i.communityRating, freigabe: i.officialRating,
            planDa: p != nil, lossless: p?.isLossless ?? false, methode: p.map { $0.method.rawValue },
            fortsetzenAb: ab, fortsetzenText: ab.map { zeitText($0) },
            beschreibung: i.beschreibung, regie: i.regie,
            darsteller: Array(i.darsteller.prefix(12)).map {
                Personantwort(id: $0.id, name: $0.name, rolle: $0.role, bild: personenbild($0))
            },
            gemerkt: i.userData?.isFavorite ?? false, gesehen: i.userData?.played ?? false,
            trailer: i.remoteTrailers?.first?.url.map { "\($0)" }, datei: datei))
    }

    // MARK: Serie

    /// Die Serienseite — `SeriesDetailView.laden()` samt `StaffelZiel`. Ist `id` eine **Folge**,
    /// wird sie frisch geholt (eine Kachel kann eine veraltete `seasonId` tragen), ihre Serie
    /// geladen und ihre Staffel vorgewaehlt.
    ///
    /// Vorwahl wie auf iOS: Staffel der Folge → Staffel des Stands → Nummer der Folge → Nummer
    /// des Stands → erste. **ID und Nummer sind gleichrangig**: der Server laesst `SeasonId`
    /// manchmal weg, und ein Vergleich nur ueber die ID fiel still auf die erste Staffel.
    public func serie(id: String) async throws -> String {
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
        let gewaehlt = staffeln.first { hinweisID != nil && $0.id == hinweisID }
            ?? staffeln.first { stand?.seasonId != nil && $0.id == stand?.seasonId }
            ?? staffeln.first { hinweisNummer != nil && $0.indexNumber == hinweisNummer }
            ?? staffeln.first { stand?.parentIndexNumber != nil && $0.indexNumber == stand?.parentIndexNumber }
            ?? staffeln.first
        var plan: PlaybackPlan?
        if let stand {
            plan = try? await c.playbackPlan(for: stand.id,
                                             profile: .vlc(maxBitrate: profilBitrate))
        }
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
            planDa: plan != nil, lossless: plan?.isLossless ?? false, methode: plan.map { $0.method.rawValue },
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
            }))
    }

    /// Die Folgen einer Staffel — Zeilen wie `Folgenzeile`: „3. Name", Restzeit oder Laufzeit,
    /// der Balken nur, solange nicht gesehen.
    public func folgen(serie: String, staffel: String) async throws -> String {
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
                ab: f.fortsetzenAb))
        }
        return try json(zeilen)
    }

    // MARK: Konto und Server

    /// Name und Fassung des Servers — fuer Profil und Einstellungen.
    public func serverauskunft() async throws -> String {
        guard let c = client else { throw Kernfehler.nichtVerbunden }
        let info = try await c.publicSystemInfo()
        return try json(Serverantwort(name: info.serverName ?? "", version: info.version ?? "", adresse: ""))
    }

    /// Meldet beim Server ab und vergisst die Sitzung. Die Ablage leert Kotlin.
    public func abmelden() async {
        if let c = client { await c.abmelden() }
        setzen(nil, nil, nil)
    }

    /// Den Code eines anderen Geraets freigeben — `QuickConnectView`. Leer heisst: erledigt.
    public func quickConnectFreigeben(code: String) async -> String {
        await erledigen { try await $0.quickConnectFreigeben(code: code) }
    }

    /// Die Genres des Servers — fuer „Genre hinzufuegen".
    public func gattungen() async throws -> String {
        guard let c = client else { throw Kernfehler.nichtVerbunden }
        return try json(try await c.gattungen())
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

    /// Welche Spur zu einer Sprache passt — `Sprache.passt` ueber den Namen, den VLC nennt. -1: keine.
    public static func spurWaehlen(namen: [String], sprache: String) -> Int {
        namen.firstIndex { Sprache.passt($0, zu: sprache) } ?? -1
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
        guard let c = client, let a = adressen else { throw Kernfehler.nichtVerbunden }
        guard let titel = await c.titel(gattung: name, limit: 200) else { throw URLError(.cannotLoadFromNetwork) }
        return try json(titel.map { rasterkachel($0, a) })
    }

    // MARK: Merkliste

    /// Eine Seite der Merkliste — `AppModel.gemerkte`: Favoriten ueber alle Bibliotheken
    /// (rekursiv, **immer mit Gattungen** — ohne sie kamen leere virtuelle Ordner als Titel),
    /// dieselben Kacheln wie die Bibliothek. `gattung` ist `Merkgattung.art`, leer heisst beides.
    public func merkliste(gattung: String, sortierung: String, ab: Int, anzahl: Int) async throws -> String {
        guard let c = client, let a = adressen else { throw Kernfehler.nichtVerbunden }
        let art = Merkgattung.zu(art: gattung.isEmpty ? nil : gattung)
        let s = Sortierung(rawValue: sortierung) ?? .neueste
        let antwort = try await c.items(limit: anzahl, startIndex: ab, sortBy: s.feld, sortOrder: s.richtung,
                                        filters: ["IsFavorite"], recursive: true, includeItemTypes: art.typen)
        let titel = ab == 0 ? Listenregeln.ohneDoppelte(antwort.items) : antwort.items
        return try json(Rasterseitenantwort(titel: titel.map { rasterkachel($0, a) }, gesamt: antwort.totalRecordCount))
    }

    /// „Filme & Serien", „Filme", „Serien" — `wert` ist die Art, leer fuer beides.
    public static func merkgattungen() -> String {
        kodiert(Merkgattung.allCases.map { Wahlantwort(wert: $0.art ?? "", text: $0.beschriftung) })
    }

    // MARK: Suche

    /// `SucheView.suchen` ohne Seerr: `JellyfinClient.suche` (nur Filme und Serien), ohne doppelte
    /// Kennungen, die Zeile unter dem Plakat aus `trefferauskunft`. Unter der Mindestlaenge leer.
    public func suche(begriff: String) async throws -> String {
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
    public func wiedergabeOeffnen(id: String) async throws -> String {
        guard let c = client else { throw Kernfehler.nichtVerbunden }
        let a = adressen
        try? await c.faehigkeitenMelden()
        let item = try await c.item(id: id)
        let grenze = profilBitrate
        async let geplant = c.playbackPlan(for: id, profile: .vlc(maxBitrate: grenze))
        async let teile = c.abschnitte(fuer: id)
        async let danach = naechsteFolge(nach: item, c)
        guard let plan = try await geplant else { throw URLError(.resourceUnavailable) }
        let w = Wiedergabe(item: item, plan: plan, abschnitte: await teile, naechste: await danach)
        sperre.lock(); _wiedergabe = w; sperre.unlock()
        return try json(Spielplanantwort(
            url: plan.url.absoluteString, lossless: plan.isLossless, methode: plan.method.rawValue,
            titel: item.name,
            untertitel: [item.seriesName, item.folgenkuerzel].compactMap { $0 }.joined(separator: " · "),
            naechste: w.naechste != nil,
            // Fuer die Mediensteuerung: bei einer Folge ihr Standbild — es zeigt, wo man ist —, sonst das Plakat.
            serie: item.seriesName, kuerzel: item.folgenkuerzel,
            bild: { () -> String? in
                let u: URL? = a?.bauen(itemID: item.id, marke: item.imageTags?["Primary"], mass: .hoechstensHoch(600))
                return u?.absoluteString
            }()))
    }

    private func naechsteFolge(nach item: Item, _ c: JellyfinClient) async -> Item? {
        guard item.type == "Episode", let serie = item.seriesId else { return nil }
        return try? await c.folgeNach(itemID: item.id, seriesID: serie)
    }

    /// Ein Takt alle 500 ms — `Wiedergabetakt.rechnen` wie auf iOS. Start und Fortschritt gehen
    /// von hier an den Server; zurueck kommt, was die Oberflaeche tun soll.
    public func wiedergabeTakt(dauer: Double, position: Double, zeigtBild: Bool, laeuft: Bool,
                               hatTonspuren: Bool, amSchieben: Bool, sprungLaeuft: Bool) -> String {
        sperre.lock()
        guard var w = _wiedergabe, let c = _client else { sperre.unlock(); return "{}" }
        let messung = Wiedergabetakt.Messung(dauer: dauer, position: position, guteStelle: position,
                                             zeigtBild: zeigtBild, stelltEin: false, laeuft: laeuft,
                                             hatTonspuren: hatTonspuren)
        let auftrag = Wiedergabetakt.rechnen(&w.stand, messung: messung, stelltWiederHer: false,
                                             sprungLaeuft: sprungLaeuft, amSchieben: amSchieben, seitStart: w.start)
        _wiedergabe = w
        sperre.unlock()

        let stelle = w.stand.position
        let ticks = JellyfinClient.ticks(fromSeconds: stelle)
        let id = w.item.id, plan = w.plan, pausiert = !w.stand.laeuft
        if auftrag.startMelden {
            Task { try? await c.reportStart(itemID: id, plan: plan, ticks: ticks) }
        } else if auftrag.fortschrittMelden {
            Task { try? await c.reportProgress(itemID: id, plan: plan, positionTicks: ticks, paused: pausiert) }
        }

        // Mit Abschnitten entscheidet `Abschnittslogik`; ohne sie die Restzeitregel aus `Folgenende`.
        var art = "keiner"
        var nach: Double?
        var text = ""
        if w.abschnitte.isEmpty {
            if w.naechste != nil, Folgenende.knopfZeigen(position: stelle, dauer: w.stand.dauer) {
                art = "naechste"
                text = Knopfangebot.naechsteFolge.beschriftung
            }
        } else {
            let angebot = Abschnittslogik.angebot(position: stelle, dauer: w.stand.dauer,
                                                  abschnitte: w.abschnitte, hatNaechsteFolge: w.naechste != nil)
            text = angebot.beschriftung
            switch angebot {
            case .keiner: break
            case let .ueberspringen(ziel, _): art = "ueberspringen"; nach = ziel
            case .naechsteFolge: art = "naechste"
            }
        }
        let weiter = w.naechste != nil
            && Folgenende.weiterschalten(position: stelle, dauer: w.stand.dauer,
                                         seitOeffnen: Date().timeIntervalSince(w.start))
        return (try? json(Taktantwort(ladeschirmWeg: auftrag.ladeschirmWeg, spurenAnwenden: auftrag.spurenAnwenden,
                                      position: stelle, angebot: art, nach: nach, angebotstext: text,
                                      weiterschalten: weiter))) ?? "{}"
    }

    /// Ausser der Reihe melden — nach Anhalten, Weiterspielen und Springen.
    public func wiedergabeMelden(position: Double, pausiert: Bool) {
        sperre.lock(); let w = _wiedergabe; let c = _client; sperre.unlock()
        guard let w, let c, w.stand.startGemeldet else { return }
        let ticks = JellyfinClient.ticks(fromSeconds: position)
        Task { try? await c.reportProgress(itemID: w.item.id, plan: w.plan, positionTicks: ticks, paused: pausiert) }
    }

    /// Beendet — muss auch beim Schliessen kommen, sonst haengt die Sitzung im Dashboard. Ob der
    /// Titel als gesehen gilt, entscheidet der Server aus der gemeldeten Stelle.
    public func wiedergabeBeenden(position: Double) {
        sperre.lock(); let w = _wiedergabe; let c = _client; _wiedergabe = nil; sperre.unlock()
        guard let w, let c else { return }
        let ticks = JellyfinClient.ticks(fromSeconds: position)
        Task { try? await c.reportStopped(itemID: w.item.id, plan: w.plan, positionTicks: ticks) }
    }

    /// Zur naechsten Folge: die alte beenden, die neue oeffnen.
    public func naechsteFolgeOeffnen(position: Double) async throws -> String {
        sperre.lock(); let naechste = _wiedergabe?.naechste; sperre.unlock()
        guard let naechste else { throw URLError(.resourceUnavailable) }
        wiedergabeBeenden(position: position)
        return try await wiedergabeOeffnen(id: naechste.id)
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

    // MARK: Seerr

    private var seerr: SeerrClient? { sperre.lock(); defer { sperre.unlock() }; return _seerr }

    /// Setzt den gemerkten Zugang ein — Kotlin legt ihn je Jellyfin-Server verschluesselt ab.
    public func seerrSetzen(zugang: String) {
        let z = try? JSONDecoder().decode(Seerrzugang.self, from: Data(zugang.utf8))
        sperre.lock(); _seerr = z.map { SeerrClient(zugang: $0) }; sperre.unlock()
    }

    public func seerrTrennen() { sperre.lock(); _seerr = nil; sperre.unlock() }

    /// Verbindet mit Jellyfins eigenem Namen und Passwort. **Ein zweites Schema nur, wenn es geraten
    /// war** (`Seerr.adressen`) — und nur nach einem Netzfehler, nie nach einem falschen Passwort.
    /// Antwort: der Zugang als JSON; das Passwort bleibt nirgends liegen.
    public func seerrVerbinden(adresse: String, benutzer: String, passwort: String) async throws -> String {
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
        catch { return error.localizedDescription }
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
        guard let c = client, let a = adressen else { throw Kernfehler.nichtVerbunden }
        async let eigene = c.titel(person: id)
        let auskunft = try? await c.item(id: id)
        let titel = await eigene
        // **Nur, was wirklich quer liegt** (`querbildEcht`) — ein beschnittenes Plakat gehoert
        // nicht in den Wechsel. Gibt es keines, steht irgendein Kopfbild da.
        var banner = titel.compactMap { Bildwahl.kopf($0, adressen: a)?.absoluteString }
        if banner.isEmpty, let erstes = titel.first,
           let url = Bildwahl.kopfMitErsatz(erstes, folge: nil, adressen: a) {
            banner = [url.absoluteString]
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

    /// Aehnliche Titel und Extras — `AppModel.aehnliche(_:)` und `extras(_:)`. Fehler geben leere Reihen.
    public func titelUmfeld(id: String) async throws -> String {
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
        do { try await tun(c); return "" } catch { return error.localizedDescription }
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
    let serie, kuerzel, bild: String?
}
struct Taktantwort: Encodable {
    let ladeschirmWeg, spurenAnwenden: Bool
    let position: Double
    let angebot: String
    let nach: Double?
    let angebotstext: String
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
}
