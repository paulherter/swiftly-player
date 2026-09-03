import Foundation

public enum JellyfinError: LocalizedError, Equatable {
    case invalidServerURL
    case notAuthenticated
    case http(status: Int, body: String?)
    case decoding(String)
    case transport(String)
    case noPlayableSource

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return uebersetzt("Die Serveradresse ist ungültig.")
        case .notAuthenticated:
            return uebersetzt("Nicht angemeldet.")
        case .noPlayableSource:
            return uebersetzt("Der Server nennt keine abspielbare Fassung.")
        // Der Antwortkörper des Servers bleibt draußen: er kann alles
        // enthalten, von einer Stapelablaufverfolgung bis zu einer Adresse
        // mit Zugangsmerkmal, und für den Nutzer sagt er nichts.
        // Für die Fehlersuche steht er in `.http(status:body:)` weiterhin
        // bereit — nur eben nicht in dem Text, den die Oberfläche zeigt.
        case .http(401, _):
            return uebersetzt("Anmeldung abgelehnt.")
        case let .http(status, _):
            return uebersetzt("Server antwortete mit \(status).")
        case let .decoding(detail):
            return uebersetzt("Antwort nicht lesbar: \(detail)")
        case let .transport(detail):
            return uebersetzt("Verbindung fehlgeschlagen: \(detail)")
        }
    }
}

/// Angemeldete Sitzung. Wird von der App im Keychain abgelegt.
public struct Session: Codable, Sendable, Equatable {
    public let accessToken: String
    public let userID: String
    public let userName: String
    public let serverURL: URL

    public init(accessToken: String, userID: String, userName: String, serverURL: URL) {
        self.accessToken = accessToken
        self.userID = userID
        self.userName = userName
        self.serverURL = serverURL
    }
}

public actor JellyfinClient {

    public let baseURL: URL
    private let deviceID: String
    private let deviceName: String
    private let clientVersion: String
    private var session: Session?
    private let urlSession: URLSession

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(
        baseURL: URL,
        deviceID: String,
        deviceName: String,
        clientVersion: String = "0.1.0",
        session: Session? = nil,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.clientVersion = clientVersion
        self.session = session
        self.urlSession = urlSession
    }

    public func setSession(_ session: Session?) { self.session = session }
    public func currentSession() -> Session? { session }

    // MARK: - Authorization-Header
    //
    // Jellyfin erwartet ab 10.8 das Schema `MediaBrowser` im Authorization-
    // Header. Der Token fehlt beim ersten Aufruf (Login) und kommt danach dazu.

    private var authorizationHeader: String {
        var parts = [
            "Client=\"Swiftly\"",
            "Device=\"\(deviceName)\"",
            "DeviceId=\"\(deviceID)\"",
            "Version=\"\(clientVersion)\"",
        ]
        if let token = session?.accessToken {
            parts.append("Token=\"\(token)\"")
        }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    private func request(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil
    ) throws -> URLRequest {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path),
                                        resolvingAgainstBaseURL: false) else {
            throw JellyfinError.invalidServerURL
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw JellyfinError.invalidServerURL }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch {
            throw JellyfinError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError.transport("Keine HTTP-Antwort.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError.http(status: http.statusCode,
                                     body: String(data: data.prefix(400), encoding: .utf8))
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw JellyfinError.decoding(String(describing: error))
        }
    }

    /// Für die Erweiterung in PlaybackReporting.
    internal func requireSessionForReporting() throws -> Session { try requireSession() }

    /// Für Erweiterungen, die eine Antwort selbst auswerten müssen — etwa
    /// Quick Connect, wo der Server nacktes `true`/`false` schickt und der
    /// Statuscode die eigentliche Aussage trägt.
    internal func rohAnfrage(_ path: String, method: String,
                             query: [URLQueryItem] = []) throws -> URLRequest {
        try request(path, method: method, query: query)
    }
    internal var rohSitzung: URLSession { urlSession }
    /// Für die Fernsteuerung: der Socket trägt die Kennung als Abfragewert.
    internal var geraeteKennung: String { deviceID }

    internal func requestForReporting(_ path: String, body: any Encodable) throws -> URLRequest {
        try request(path, method: "POST", body: body)
    }

    /// Für Endpunkte, die nur 204 ohne Inhalt liefern.
    internal func sendIgnoringBody(_ req: URLRequest) async throws {
        let (data, response) = try await { () async throws -> (Data, URLResponse) in
            do { return try await urlSession.data(for: req) }
            catch { throw JellyfinError.transport(error.localizedDescription) }
        }()
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError.transport("Keine HTTP-Antwort.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError.http(status: http.statusCode,
                                     body: String(data: data.prefix(300), encoding: .utf8))
        }
    }

    /// Für Anmeldewege, die nicht über Name und Passwort laufen.
    ///
    /// Steht hier und nicht in der Erweiterung, weil nur hier `session`
    /// gesetzt werden darf — ein Zugangsmerkmal, das die Erweiterung
    /// zurückgibt, ohne es abzulegen, waere ein Zustand an zwei Orten.
    internal func anmeldenMit(rumpf: any Encodable, an pfad: String) async throws -> Session {
        let req = try request(pfad, method: "POST", body: rumpf)
        let ergebnis = try await send(req, as: AuthenticationResult.self)
        let neu = Session(accessToken: ergebnis.accessToken,
                          userID: ergebnis.user.id,
                          userName: ergebnis.user.name,
                          serverURL: baseURL)
        session = neu
        return neu
    }

    private func requireSession() throws -> Session {
        guard let session else { throw JellyfinError.notAuthenticated }
        return session
    }

    // MARK: - Endpoints

    /// Erreichbarkeits- und Versionsprüfung. Braucht keine Anmeldung.
    public func publicSystemInfo() async throws -> PublicSystemInfo {
        try await send(request("System/Info/Public"), as: PublicSystemInfo.self)
    }

    public func authenticate(username: String, password: String) async throws -> Session {
        struct Body: Encodable {
            let Username: String
            let Pw: String
        }
        let req = try request("Users/AuthenticateByName", method: "POST",
                              body: Body(Username: username, Pw: password))
        let result = try await send(req, as: AuthenticationResult.self)
        let newSession = Session(accessToken: result.accessToken,
                                 userID: result.user.id,
                                 userName: result.user.name,
                                 serverURL: baseURL)
        session = newSession
        return newSession
    }

    /// Meldet dieses Gerät beim Server ab und macht das Zugangsmerkmal
    /// ungültig.
    ///
    /// Ohne diesen Aufruf bleibt das Token nach dem Abmelden auf dem Server
    /// dauerhaft gültig — wer sein Telefon verkauft oder verliert, hinterlässt
    /// einen offenen Zugang. Fehler sind hier unerheblich: das lokale
    /// Abmelden muss auch ohne Netz gelingen.
    public func abmelden() async {
        guard let req = try? request("Sessions/Logout", method: "POST") else { return }
        _ = try? await urlSession.data(for: req)
        session = nil
    }

    /// Prüft, ob das Zugangsmerkmal noch gilt.
    ///
    /// `System/Info/Public` taugt dafür nicht — der Endpunkt braucht keine
    /// Anmeldung und antwortet auch mit einem widerrufenen Token freundlich.
    /// Hier muss ein Aufruf her, den nur ein gültiges Token besteht.
    ///
    /// - Returns: `true`, wenn die Sitzung trägt. `false` **nur** bei 401 oder
    ///   403 — ein Netzfehler heißt „weiß nicht", und deswegen jemanden
    ///   abzumelden wäre falsch.
    public func sitzungGiltNoch() async -> Bool {
        guard let s = session,
              let req = try? request("Users/\(s.userID)", method: "GET") else { return true }
        guard let (_, antwort) = try? await urlSession.data(for: req),
              let http = antwort as? HTTPURLResponse else { return true }
        return http.statusCode != 401 && http.statusCode != 403
    }

    /// Die Bibliotheken des Nutzers (Filme, Serien, Musik …).
    public func userViews() async throws -> [Item] {
        let s = try requireSession()
        let req = try request("UserViews", query: [.init(name: "userId", value: s.userID)])
        return try await send(req, as: ItemsResponse.self).items
    }

    public func items(
        parentID: String? = nil,
        limit: Int = 100,
        startIndex: Int = 0,
        sortBy: String = "SortName",
        sortOrder: String = "Ascending",
        /// Jellyfins `Filters`, etwa „IsResumable" oder „IsFavorite".
        filters: [String] = [],
        /// `false` heißt: nur Ungesehenes.
        istGesehen: Bool? = nil,
        recursive: Bool = false
    ) async throws -> ItemsResponse {
        let s = try requireSession()
        var query: [URLQueryItem] = [
            .init(name: "userId", value: s.userID),
            .init(name: "Limit", value: String(limit)),
            .init(name: "StartIndex", value: String(startIndex)),
            .init(name: "SortBy", value: sortBy),
            .init(name: "SortOrder", value: sortOrder),
            // Bewusst **ohne** MediaSources und RemoteTrailers: die tragen je
            // Titel alle Spuren mit Codec, Sprache, Kanälen und Bitraten und
            // sind bei zweihundert Einträgen der weitaus größte Teil der
            // Antwort — für eine Ansicht, die davon Name, Jahr und Poster
            // zeigt. Die Detailseite holt den Titel ohnehin frisch über
            // `item(id:)`, und dort stehen beide drin.
            .init(name: "Fields", value: "Overview,PrimaryImageAspectRatio"),
            .init(name: "Recursive", value: recursive ? "true" : "false"),
        ]
        if let parentID { query.append(.init(name: "ParentId", value: parentID)) }
        if !filters.isEmpty {
            query.append(.init(name: "Filters", value: filters.joined(separator: ",")))
        }
        if let istGesehen {
            query.append(.init(name: "IsPlayed", value: istGesehen ? "true" : "false"))
        }
        return try await send(try request("Items", query: query), as: ItemsResponse.self)
    }

    /// Fragt den Server, wie er diesen Titel ausliefern würde.
    ///
    /// Hier wird das DeviceProfile mitgeschickt — die Antwort verrät, ob es
    /// Direct Play, Direct Stream oder Transcode wird.
    ///
    /// **Immer mit Direct Play und ab Sekunde null.** Es gab eine Zeit lang
    /// einen Notausgang: `EnableDirectPlay` aus und `StartTimeTicks` gesetzt,
    /// damit der Server ab einer Stelle liefert. Er war noetig, weil VLC 4 in
    /// manchen Matroska-Dateien nicht springen konnte — und er kostete genau
    /// das, wofuer es diese App gibt: der Server musste umpacken.
    ///
    /// Seit dem Patch am mkv-Sucher springt der Abspieler selbst. Der
    /// Notausgang ist deshalb entfernt; siehe `Werkzeuge/vlckit-patches/`.
    ///
    /// - Parameter audioStreamIndex: Welche Tonspur der Server nehmen soll.
    ///   Nur fuer AirPlay gesetzt: dort muss haeufig die AC-3-Spur statt der
    ///   DTS-Standardspur ausgeliefert werden, weil der Empfaenger DTS nicht
    ///   annimmt. Bei VLC bleibt es `nil` — der waehlt selbst, und zwar aus
    ///   allen Spuren.
    public func playbackInfo(
        itemID: String,
        profile: DeviceProfile = .vlc(),
        maxStreamingBitrate: Int? = nil,
        audioStreamIndex: Int? = nil
    ) async throws -> PlaybackInfoResponse {
        let s = try requireSession()
        struct Body: Encodable {
            let UserId: String
            let DeviceProfile: DeviceProfile
            let MaxStreamingBitrate: Int
            let AutoOpenLiveStream: Bool
            let EnableDirectPlay: Bool
            let EnableDirectStream: Bool
            let EnableTranscoding: Bool
            let AudioStreamIndex: Int?
        }
        let body = Body(
            UserId: s.userID,
            DeviceProfile: profile,
            MaxStreamingBitrate: maxStreamingBitrate ?? profile.maxStreamingBitrate,
            AutoOpenLiveStream: true,
            EnableDirectPlay: true,
            EnableDirectStream: true,
            EnableTranscoding: true,
            AudioStreamIndex: audioStreamIndex
        )
        let req = try request("Items/\(itemID)/PlaybackInfo", method: "POST", body: body)
        return try await send(req, as: PlaybackInfoResponse.self)
    }

    /// Ein einzelner Titel, frisch vom Server.
    ///
    /// Wichtig fürs Fortsetzen: die Wiedergabeposition steckt in `UserData`,
    /// und die ist in durchgereichten Listeneinträgen oft veraltet oder fehlt.
    /// `UserData` ist kein `Fields`-Wert — der Server liefert es automatisch,
    /// sobald `userId` mitgeht.
    public func item(id: String) async throws -> Item {
        let s = try requireSession()
        let req = try request("Items/\(id)", query: [
            .init(name: "userId", value: s.userID),
        ])
        return try await send(req, as: Item.self)
    }

    /// Ähnliche Titel.
    public func aehnliche(itemID: String, limit: Int = 12) async throws -> [Item] {
        let s = try requireSession()
        let req = try request("Items/\(itemID)/Similar", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "limit", value: String(limit)),
        ])
        return try await send(req, as: ItemsResponse.self).items
    }

    /// Extras — Featurettes, Making-of, Szenen.
    public func extras(itemID: String) async throws -> [Item] {
        let s = try requireSession()
        let req = try request("Items/\(itemID)/SpecialFeatures", query: [
            .init(name: "userId", value: s.userID),
        ])
        return try await send(req, as: [Item].self)
    }

    /// Volltextsuche über Filme und Serien.
    ///
    /// **Folgen sind bewusst nicht dabei.** Sie waren es, und es sah kaputt
    /// aus: Jede Folge traegt das Plakat ihrer Serie, also stand bei „the"
    /// dasselbe Plakat drei-, viermal nebeneinander, mit Folgentiteln
    /// darunter. Wer eine Serie sucht, findet sie dadurch schlechter als
    /// ohne Suche.
    ///
    /// Der Preis: Man findet eine Folge nicht mehr ueber ihren eigenen Titel.
    /// Das ist am Fernseher verschmerzbar — dort sucht niemand nach einem
    /// Folgentitel, den er nicht kennt. Kommt es zurueck, dann gruppiert
    /// unter der Serie, nicht als eigener Treffer.
    public func suche(_ begriff: String, limit: Int = 40) async throws -> [Item] {
        let s = try requireSession()
        let req = try request("Items", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "searchTerm", value: begriff),
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "Movie,Series"),
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: "Overview,PrimaryImageAspectRatio"),
        ])
        return try await send(req, as: ItemsResponse.self).items
    }

    /// Merkliste an- und abschalten.
    public func setzeMerkliste(itemID: String, an: Bool) async throws {
        let s = try requireSession()
        let req = try request("UserFavoriteItems/\(itemID)", method: an ? "POST" : "DELETE",
                              query: [.init(name: "userId", value: s.userID)])
        try await sendIgnoringBody(req)
    }

    /// Als gesehen markieren oder die Markierung entfernen.
    public func setzeGesehen(itemID: String, an: Bool) async throws {
        let s = try requireSession()
        let req = try request("UserPlayedItems/\(itemID)", method: an ? "POST" : "DELETE",
                              query: [.init(name: "userId", value: s.userID)])
        try await sendIgnoringBody(req)
    }

    /// Die Staffeln einer Serie.
    public func staffeln(seriesID: String) async throws -> [Item] {
        let s = try requireSession()
        let req = try request("Shows/\(seriesID)/Seasons", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "Fields", value: "Overview"),
        ])
        return try await send(req, as: ItemsResponse.self).items
    }

    /// Die Folgen einer Staffel. Ohne `seasonID` alle Folgen der Serie.
    public func folgen(seriesID: String, seasonID: String? = nil) async throws -> [Item] {
        let s = try requireSession()
        var query: [URLQueryItem] = [
            .init(name: "userId", value: s.userID),
            .init(name: "Fields", value: "Overview,MediaSources"),
        ]
        if let seasonID { query.append(.init(name: "seasonId", value: seasonID)) }
        let req = try request("Shows/\(seriesID)/Episodes", query: query)
        return try await send(req, as: ItemsResponse.self).items
    }

    /// Trailer, die als eigene Dateien auf dem Server liegen.
    ///
    /// Sie lassen sich wie jeder andere Titel abspielen — der Server liefert
    /// dafür ebenso eine MediaSource.
    public func trailer(zu itemID: String) async throws -> [Item] {
        let s = try requireSession()
        let req = try request("Items/\(itemID)/LocalTrailers",
                              query: [.init(name: "userId", value: s.userID)])
        return try await send(req, as: [Item].self)
    }

    /// Stößt beim Server an, die Metadaten neu einzulesen.
    public func metadatenAuffrischen(_ itemID: String) async throws {
        let req = try rohAnfrage("Items/\(itemID)/Refresh", method: "POST",
                                 query: [.init(name: "metadataRefreshMode", value: "FullRefresh"),
                                         .init(name: "imageRefreshMode", value: "FullRefresh"),
                                         .init(name: "replaceAllMetadata", value: "false")])
        let (_, antwort) = try await rohSitzung.data(for: req)
        guard let http = antwort as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw JellyfinError.transport("Der Server hat die Auffrischung abgelehnt.")
        }
    }

    /// Wo man in dieser Serie steht.
    ///
    /// Jellyfin beantwortet damit beides in einem Aufruf: die angefangene
    /// Folge, oder — wenn keine offen ist — die nächste ungesehene. Genau
    /// das, was der große Knopf auf der Serienseite braucht.
    public func naechsteFolgeDerSerie(seriesID: String) async throws -> Item? {
        let s = try requireSession()
        let req = try request("Shows/NextUp", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "seriesId", value: seriesID),
            .init(name: "Limit", value: "1"),
            .init(name: "Fields", value: "Overview"),
        ])
        return try await send(req, as: ItemsResponse.self).items.first
    }

    /// Die Folge nach dieser. `nil` bei Filmen oder am Staffelende.
    ///
    /// `adjacentTo` liefert Vorgänger, aktuelle und Nachfolger in einem Zug —
    /// bequemer als selbst über Staffel- und Folgennummern zu rechnen.
    public func folgeNach(itemID: String, seriesID: String) async throws -> Item? {
        let s = try requireSession()
        let req = try request("Shows/\(seriesID)/Episodes", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "adjacentTo", value: itemID),
            .init(name: "Fields", value: "Overview"),
        ])
        let folgen = try await send(req, as: ItemsResponse.self).items
        guard let jetzt = folgen.firstIndex(where: { $0.id == itemID }),
              folgen.indices.contains(jetzt + 1) else { return nil }
        return folgen[jetzt + 1]
    }

    /// Angefangene Titel — die „Weiterschauen"-Reihe.
    public func resumeItems(limit: Int = 20) async throws -> [Item] {
        let s = try requireSession()
        let req = try request("UserItems/Resume", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: "Overview,PrimaryImageAspectRatio"),
            .init(name: "MediaTypes", value: "Video"),
        ])
        return try await send(req, as: ItemsResponse.self).items
    }

    /// Die nächste ungesehene Folge laufender Serien.
    public func nextUp(limit: Int = 20) async throws -> [Item] {
        let s = try requireSession()
        let req = try request("Shows/NextUp", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: "Overview,PrimaryImageAspectRatio"),
        ])
        return try await send(req, as: ItemsResponse.self).items
    }

    /// Zuletzt Hinzugefügtes. Ohne `parentID` über alle Bibliotheken.
    ///
    /// Achtung: dieser Endpunkt liefert ein nacktes Array, keinen
    /// ItemsResponse-Umschlag wie die übrigen.
    /// Neu dazugekommen, neueste zuerst.
    ///
    /// `gruppieren: false` liefert die einzelnen Folgen statt der Serie. Nur
    /// so stehen Datum und Staffelnummer in der Antwort — zusammengefasst
    /// nennt der Server bloß die Serie und die Zahl der neuen Folgen.
    public func latest(parentID: String? = nil, limit: Int = 20,
                       gruppieren: Bool = true) async throws -> [Item] {
        let s = try requireSession()
        var query: [URLQueryItem] = [
            .init(name: "userId", value: s.userID),
            .init(name: "Limit", value: String(limit)),
            .init(name: "GroupItems", value: gruppieren ? "true" : "false"),
            // ChildCount ausdrücklich anfordern — ohne das fehlt die Zahl der
            // neuen Folgen in der Antwort.
            .init(name: "Fields", value: "Overview,PrimaryImageAspectRatio,ChildCount"),
        ]
        if let parentID { query.append(.init(name: "ParentId", value: parentID)) }
        return try await send(try request("Items/Latest", query: query), as: [Item].self)
    }

    /// Fragt den Server und baut daraus direkt den Plan für den Player.
    public func playbackPlan(
        for itemID: String,
        profile: DeviceProfile = .vlc(),
        audioStreamIndex: Int? = nil
    ) async throws -> PlaybackPlan? {
        let info = try await playbackInfo(itemID: itemID, profile: profile,
                                          audioStreamIndex: audioStreamIndex)
        return try PlaybackPlan.make(
            from: info,
            itemID: itemID,
            profile: profile,
            streamURL: { [self] id, sourceID, sessionID in
                try streamURL(itemID: id, mediaSourceID: sourceID, playSessionID: sessionID)
            },
            serverBase: baseURL
        )
    }

    /// Was AirPlay fuer diesen Titel hergibt.
    ///
    /// **Die Pruefung kommt vor der Anfrage, nicht danach.** Die Stroeme der
    /// Datei stehen schon in der Quelle, die der laufende Plan mitbringt — es
    /// braucht also keinen Serverbesuch, um „geht nicht" zu sagen. Und es darf
    /// keinen geben: wer erst fragt und dann ablehnt, hat auf dem Server eine
    /// Sitzung eroeffnet, die niemand wieder schliesst.
    ///
    /// Geht es, laeuft **eine** Anfrage — mit dem engen Profil und der Tonspur,
    /// die durchkommt.
    public func airplayPlan(for itemID: String, quelle: MediaSource) async throws -> AirPlayAuskunft {
        let eignung = AirPlayEignung.pruefen(quelle: quelle)
        guard eignung.geeignet else { return .gehtNicht(eignung) }
        guard let plan = try await playbackPlan(for: itemID, profile: .airplay(),
                                                audioStreamIndex: eignung.tonspur) else {
            throw JellyfinError.noPlayableSource
        }
        return .geht(plan)
    }

    // MARK: - URLs für den Player

    /// Die Adresse, die VLC bekommt. Bei Direct Play ist das die unveränderte
    /// Datei auf der Platte des Servers.
    public func streamURL(itemID: String, mediaSourceID: String?,
                          playSessionID: String? = nil) throws -> URL {
        let s = try requireSession()
        guard var comps = URLComponents(
            url: baseURL.appendingPathComponent("Videos/\(itemID)/stream"),
            resolvingAgainstBaseURL: false
        ) else { throw JellyfinError.invalidServerURL }

        var query: [URLQueryItem] = [
            .init(name: "static", value: "true"),
            .init(name: "api_key", value: s.accessToken),
        ]
        if let mediaSourceID { query.append(.init(name: "mediaSourceId", value: mediaSourceID)) }
        if let playSessionID { query.append(.init(name: "playSessionId", value: playSessionID)) }
        comps.queryItems = query
        guard let url = comps.url else { throw JellyfinError.invalidServerURL }
        return url
    }

    /// Hintergrundbild für die Serienseite. `nil`, wenn keins hinterlegt ist.
    public func backdropURL(for item: Item, maxWidth: Int = 1200) -> URL? {
        guard let tag = item.backdropImageTags?.first, let token = session?.accessToken else { return nil }
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("Items/\(item.id)/Images/Backdrop"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [
            .init(name: "tag", value: tag),
            .init(name: "maxWidth", value: String(maxWidth)),
            .init(name: "quality", value: "85"),
            .init(name: "api_key", value: token),
        ]
        return comps?.url
    }

    /// Absolute URL für ein Poster. `nil`, wenn der Titel kein Bild hat.
    public func imageURL(for item: Item, maxHeight: Int = 480) -> URL? {
        guard let tag = item.imageTags?["Primary"], let token = session?.accessToken else { return nil }
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("Items/\(item.id)/Images/Primary"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [
            .init(name: "tag", value: tag),
            .init(name: "maxHeight", value: String(maxHeight)),
            .init(name: "quality", value: "90"),
            .init(name: "api_key", value: token),
        ]
        return comps?.url
    }
}

/// Kleiner Helfer, damit `request(body:)` ein beliebiges Encodable annehmen kann.
private struct AnyEncodable: Encodable {
    private let encode: (Encoder) throws -> Void
    init(_ wrapped: any Encodable) {
        encode = { try wrapped.encode(to: $0) }
    }
    func encode(to encoder: Encoder) throws { try encode(encoder) }
}
