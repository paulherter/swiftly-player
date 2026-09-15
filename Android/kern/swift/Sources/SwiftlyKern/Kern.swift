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
        // Die Grenze aus den Einstellungen folgt mit der Einstellungsseite; bis dahin die Vorgabe.
        let grenze = Bitratengrenze.fuer(immerDirectPlay: true, megabit: 0)
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
                                             profile: .vlc(maxBitrate: Bitratengrenze.fuer(immerDirectPlay: true, megabit: 0)))
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
        try? await c.faehigkeitenMelden()
        let item = try await c.item(id: id)
        let grenze = Bitratengrenze.fuer(immerDirectPlay: true, megabit: 0)
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
            naechste: w.naechste != nil))
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
            titel: titel.map { rasterkachel($0, a) }))
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
struct Spielplanantwort: Encodable {
    let url: String
    let lossless: Bool
    let methode, titel, untertitel: String
    let naechste: Bool
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
