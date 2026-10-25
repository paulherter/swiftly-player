import Foundation
// On Linux URLSession is not in Foundation but in its own module. On Apple platforms that
// module does not exist, so the import is conditional and has no effect there.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// **What made the server's certificate fail.**
///
/// Five cases instead of one, because what to do differs each time: an expired certificate
/// is renewed by the server operator, a wrong name means a different server answered.
public enum CertificateReason: String, Sendable, Equatable, CaseIterable {
    /// Self-signed, or the issuer is unknown.
    case notTrusted = "nichtVertraut"
    /// The validity period is over.
    case expired = "abgelaufen"
    /// The validity period has not started yet; usually the clock is wrong.
    case appliesNotYet = "giltNochNicht"
    /// Valid, but issued for a different name.
    case otherAddress = "andereAdresse"
    /// TLS failed and the reason is not available.
    case otherwise = "sonst"
}

public enum JellyfinError: LocalizedError, Equatable {
    case invalidServerURL
    case notAuthenticated
    /// **Name and password are correct, the server wants another confirmation.**
    /// Two-factor plugins such as JellyfinSecurity answer 401 and put a valid `AccessToken`
    /// in the body; a wrong password gives 401 without a token. Without this case both
    /// meant "wrong user name or password", and users with 2FA looked for the error in the
    /// wrong place.
    case twoFactor
    case http(status: Int, body: String?)
    case decoding(String)
    /// **The request did not get through**: the `NSURLErrorDomain` code, e.g. `-1001`
    /// (timeout) or `-1004` (no server at the address). ``urlErrorCode`` reads it as
    /// `URLError.Code`; a bare `.transport(localizedDescription)` would make the cause
    /// text, and on Android/Linux curl's English sentence.
    case network(code: Int)
    /// **The server's certificate was the cause**, and exactly how. A case of its own
    /// because the cause is not available everywhere: Apple has codes for it, on the curl
    /// platforms every TLS error arrives as `-1`. So it is classified in this one place;
    /// see ``zertifikatsgrund(code:text:)``.
    case certificate(CertificateReason)
    /// A sentence of the package's own, already worded for the user.
    case transport(String)
    case noPlayableSource
    /// The server names no version and says why (`ErrorCode` in `PlaybackInfo`). This used
    /// to become an empty plan: on the Mac "no data came", on the iPhone home page nothing
    /// happened.
    case playbackRejected(String)

    /// From a `URLSession` error: with a code, if it is one.
    init(petition error: any Error) {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else {
            self = .transport(error.localizedDescription)
            return
        }
        // **Ask whether it was the certificate before looking at the code.** On the curl
        // platforms it would otherwise be `.netz(code: -1)`, and `-1` says nothing; curl's
        // sentence is gone by then.
        if let reason = certificateReason(code: ns.code, text: error.localizedDescription) {
            self = .certificate(reason)
        } else {
            self = .network(code: ns.code)
        }
    }

    /// The `URLError` code if the request did not get through. For ``certificate(_:)`` there
    /// is none that says anything.
    public var urlErrorCode: URLError.Code? {
        if case let .network(code) = self { return URLError.Code(rawValue: code) }
        return nil
    }

    /// **One rule for the text: ``readableError(_:)``.** A second one with its own
    /// sentences used to exist, and every place using `localizedDescription` showed that.
    public var errorDescription: String? { readableError(self) }
}

/// Signed-in session. Stored by the app in the keychain.
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

    /// Immutable after creation, so readable without going through the actor. `AppModel`
    /// uses it to tell whether a switch goes to another server.
    public nonisolated let baseURL: URL
    private let deviceID: String
    private let deviceName: String
    private let clientVersion: String
    /// The name under which the server lists this client. On Android with a suffix,
    /// otherwise another device cannot tell it is a phone (`RemoteSession.devicesKind`).
    private let program: String
    private var session: Session?
    /// What the server says about downloading: ``DownloadPermission``. Stays `.unbekannt` until
    /// ``accountDefaults()`` has succeeded once, and `.unbekannt` blocks nothing.
    private var downloadRightState: DownloadPermission = .unknown
    private let urlSession: URLSession

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { try TimestampFormat.read(from: $0) }
        return d
    }()

    public init(
        baseURL: URL,
        deviceID: String,
        deviceName: String,
        clientVersion: String = VersionNumber.outBundle,
        program: String = "Swiftly Player",
        session: Session? = nil,
        urlSession: URLSession = .localNetworkCapable
    ) {
        self.baseURL = baseURL
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.clientVersion = clientVersion
        self.program = program
        self.session = session
        self.urlSession = urlSession
    }

    public func setSession(_ session: Session?) {
        self.session = session
        // **The permission belongs to the account.** If it stayed across a switch, the new
        // account would carry the old one's permission, wrong in both directions. Until
        // ``accountDefaults()`` answers for the new account, `.unbekannt` applies, i.e.
        // allowed.
        self.downloadRightState = .unknown
    }
    public func currentSession() -> Session? { session }

    /// **A second client for the same device on the same server, without an account.**
    ///
    /// For "Add another account": `authenticate` replaces the session of the client it runs
    /// on. On the signed-in client, that client would already carry the new account's token
    /// before the app has cleaned up, and leaving the group would go out in the new
    /// account's name. Signing in with this client leaves the old one as it is until the
    /// app adopts the new one.
    public nonisolated func withoutAccount() -> JellyfinClient {
        JellyfinClient(baseURL: baseURL, deviceID: deviceID, deviceName: deviceName,
                       clientVersion: clientVersion, program: program, urlSession: urlSession)
    }

    /// The last known state of the `EnableContentDownloading` permission, for UIs that do
    /// not hold ``accountDefaults()`` themselves.
    public func downloadPermission() -> DownloadPermission { downloadRightState }

    // MARK: - Authorization header
    //
    // From 10.8 Jellyfin expects the `MediaBrowser` scheme in the Authorization header. The
    // token is missing on the first call (login) and added afterwards.

    private var authorizationHeader: String {
        var parts = [
            // **The name under which the server lists this client.** It is "Swiftly
            // Player", as in the store, because that is the name a user should recognize in
            // their device list; they see it in Jellyfin, not on the home screen.
            "Client=\"\(Self.headerValue(program))\"",
            "Device=\"\(Self.headerValue(deviceName))\"",
            "DeviceId=\"\(Self.headerValue(deviceID))\"",
            "Version=\"\(Self.headerValue(clientVersion))\"",
        ]
        if let token = session?.accessToken {
            parts.append("Token=\"\(Self.headerValue(token))\"")
        }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    /// **A value that cannot break out of the header field.**
    ///
    /// The device name comes from the user. A quote in it closed the value early and the
    /// server read the rest as nonsense, in the worst case without `DeviceId`. Jellyfin has
    /// no backslash escaping, so the straight quote becomes a single quote, and line breaks
    /// and control characters are dropped.
    static func headerValue(_ raw: String) -> String {
        String(String.UnicodeScalarView(raw.unicodeScalars.compactMap { z in
            if z == "\"" { return "'" }
            if CharacterSet.controlCharacters.contains(z) { return nil }
            return z
        }))
    }

    /// The same credentials for the control channel.
    ///
    /// **Not imitated, the same.** A channel that names itself differently from the other
    /// calls ends up on a second session, and then one has the controls and the other the
    /// runtime.
    internal var credentialChannel: String { authorizationHeader }

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
        // **Own headers first, then ours.** The reserved names are removed anyway
        // (``Eigenkoepfe/bereinigt(_:)``); the order keeps it that way even if one slipped
        // through.
        req.ownHeadersSet()
        req.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest, as: T.Type,
                                    over session: URLSession? = nil) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await (session ?? urlSession).data(for: req)
        } catch {
            throw JellyfinError(petition: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError.transport("Keine HTTP-Antwort.")
        }
        guard (200..<300).contains(http.statusCode) else {
            // A gateway that rejects immediately without redirecting (Cloudflare Access
            // answers calls without a browser this way) sends its page along. Jellyfin
            // itself never rejects with HTML.
            if [401, 403].contains(http.statusCode), OwnHeaders.loginPage(http) {
                throw JellyfinError.transport(OwnHeaders.loginPageText)
            }
            throw JellyfinError.http(status: http.statusCode,
                                     body: String(data: data.prefix(400), encoding: .utf8))
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            // HTML instead of JSON means a gateway answered, not Jellyfin; see
            // ``Eigenkoepfe/anmeldeseite(_:)``.
            if OwnHeaders.loginPage(http) { throw JellyfinError.transport(OwnHeaders.loginPageText) }
            throw JellyfinError.decoding(String(describing: error))
        }
    }

    /// For the extension in PlaybackReporting.
    internal func requireSessionForReporting() throws -> Session { try requireSession() }

    /// For extensions that must evaluate a response themselves, e.g. Quick Connect, where
    /// the server sends a bare `true`/`false` and the status code carries the actual
    /// answer.
    internal func rawRequest(_ path: String, method: String,
                             query: [URLQueryItem] = []) throws -> URLRequest {
        try request(path, method: method, query: query)
    }
    internal var rawSession: URLSession { urlSession }
    /// For remote control: the socket carries the ID as a query value.
    internal var devicesId: String { deviceID }

    internal func requestForReporting(_ path: String, body: any Encodable) throws -> URLRequest {
        try request(path, method: "POST", body: body)
    }

    /// For endpoints that only return 204 without content.
    internal func sendIgnoringBody(_ req: URLRequest) async throws {
        let (data, response) = try await { () async throws -> (Data, URLResponse) in
            do { return try await urlSession.data(for: req) }
            catch { throw JellyfinError(petition: error) }
        }()
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError.transport("Keine HTTP-Antwort.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError.http(status: http.statusCode,
                                     body: String(data: data.prefix(300), encoding: .utf8))
        }
    }

    /// For sign-in paths that do not go through name and password.
    ///
    /// Lives here and not in the extension because only here may `session` be set; a token
    /// the extension returned without storing would be state in two places.
    internal func signInWith(shell: any Encodable, an path: String) async throws -> Session {
        let req = try request(path, method: "POST", body: shell)
        let result = try await send(req, as: AuthenticationResult.self)
        let new = Session(accessToken: result.accessToken,
                          userID: result.user.id,
                          userName: result.user.name,
                          serverURL: baseURL)
        session = new
        return new
    }

    private func requireSession() throws -> Session {
        guard let session else { throw JellyfinError.notAuthenticated }
        return session
    }

    // MARK: - Endpoints

    /// Reachability and version check. Needs no sign-in.
    public func publicSystemInfo() async throws -> PublicSystemInfo {
        try await send(request("System/Info/Public"), as: PublicSystemInfo.self)
    }

    /// **The same question, but with the short timeout of address entry**; see
    /// ``Adresspruefung``. Only for checking a typed address; everything after uses the
    /// usual session.
    public func checkReachability() async throws -> PublicSystemInfo {
        try await send(request("System/Info/Public"), as: PublicSystemInfo.self,
                       over: AddressCheck.session(for: baseURL))
    }

    public func authenticate(username: String, password: String) async throws -> Session {
        struct Body: Encodable {
            let Username: String
            let Pw: String
        }
        let req = try request("Users/AuthenticateByName", method: "POST",
                              body: Body(Username: username, Pw: password))
        let result: AuthenticationResult
        do {
            result = try await send(req, as: AuthenticationResult.self)
        } catch let JellyfinError.http(status, shell) {
            throw JellyfinError.loginError(status: status, shell: shell)
        }
        let newSession = Session(accessToken: result.accessToken,
                                 userID: result.user.id,
                                 userName: result.user.name,
                                 serverURL: baseURL)
        session = newSession
        return newSession
    }

    /// Signs this device out at the server and invalidates the token.
    ///
    /// Without this call the token stays valid on the server indefinitely after signing
    /// out, so someone who sells or loses their phone leaves open access. Errors do not
    /// matter here: local sign-out must work without a network.
    public func signOff() async {
        guard let req = try? request("Sessions/Logout", method: "POST") else { return }
        _ = try? await urlSession.data(for: req)
        session = nil
    }

    /// Checks whether the token is still valid.
    ///
    /// `System/Info/Public` is no good for this: the endpoint needs no sign-in and answers
    /// politely even with a revoked token. A call only a valid token passes is needed.
    ///
    /// - Returns: `true` if the session holds. `false` **only** for 401 or 403; a network
    ///   error means "unknown", and signing someone out for that would be wrong.
    public func sessionAppliesStill() async -> Bool {
        guard let s = session,
              let req = try? request("Users/\(s.userID)", method: "GET") else { return true }
        guard let (_, answer) = try? await urlSession.data(for: req),
              let http = answer as? HTTPURLResponse else { return true }
        return http.statusCode != 401 && http.statusCode != 403
    }

    /// The user's libraries (movies, series, music ...).
    ///
    /// - Parameter verborgene: Also those the user removed from "My Media" in Jellyfin.
    public func userViews(hidden: Bool = false) async throws -> [Item] {
        let s = try requireSession()
        var query: [URLQueryItem] = [.init(name: "userId", value: s.userID)]
        if hidden { query.append(.init(name: "includeHidden", value: "true")) }
        let req = try request("UserViews", query: query)
        return try await send(req, as: ItemsResponse.self).items
    }

    public func items(
        parentID: String? = nil,
        limit: Int = 100,
        startIndex: Int = 0,
        sortBy: String = "SortName",
        sortOrder: String = "Ascending",
        /// Jellyfin's `Filters`, e.g. "IsResumable" or "IsFavorite".
        filters: [String] = [],
        /// `false` means unwatched only.
        isWatched: Bool? = nil,
        recursive: Bool = false,
        /// Which kinds to return: "Movie", "Series".
        ///
        /// **Without it Jellyfin does not return the series for a series library.**
        /// Depending on server settings, the root of such a library holds virtual folders
        /// ("Continue Watching", "Next Up", "Latest", "Series", "Favorite Series",
        /// "Genres"). They have no posters and showed up as empty tiles with those names.
        ///
        /// Jellyfin's own web UI therefore always asks with a kind, recursively. On servers
        /// without these folders it changes nothing (same titles, same order).
        includeItemTypes: [String] = [],
        /// Exactly these IDs, nothing else.
        ///
        /// **The response says two things.** What comes back carries the progress
        /// (`UserData.Played`); what does *not* come back no longer exists on the server.
        /// The download reconciliation needs both.
        ids: [String] = [],
        personIDs: [String] = [],
        genres: [String] = [],
        /// **Only ID, name and sort name, all of them.** For the alphabet index
        /// (``AlphabetIndex``): no images, no user data, no overview, so a library of
        /// thousands stays a few hundred kilobytes. `limit` and `startIndex` are ignored.
        slim: Bool = false
    ) async throws -> ItemsResponse {
        let s = try requireSession()
        var query: [URLQueryItem] = [
            .init(name: "userId", value: s.userID),
            .init(name: "Limit", value: String(limit)),
            .init(name: "StartIndex", value: String(startIndex)),
            .init(name: "SortBy", value: sortBy),
            .init(name: "SortOrder", value: sortOrder),
            // Deliberately **without** MediaSources and RemoteTrailers: they carry every
            // track per title with codec, language, channels and bitrates, and with two
            // hundred entries are by far the largest part of the response, for a view that
            // shows only name, year and poster. The detail page fetches the title fresh via
            // `item(id:)` anyway, and both are in there.
            // `ProviderIds` because ``TitleFilter`` uses them to recognize two entries as the
            // same movie; small, a handful of numbers.
            .init(name: "Fields", value: "Overview,PrimaryImageAspectRatio,ProviderIds,SortName"),
            .init(name: "Recursive", value: recursive ? "true" : "false"),
        ]
        if let parentID { query.append(.init(name: "ParentId", value: parentID)) }
        if !includeItemTypes.isEmpty {
            query.append(.init(name: "IncludeItemTypes",
                               value: includeItemTypes.joined(separator: ",")))
        }
        if !filters.isEmpty {
            query.append(.init(name: "Filters", value: filters.joined(separator: ",")))
        }
        if !ids.isEmpty {
            query.append(.init(name: "Ids", value: ids.joined(separator: ",")))
        }
        if !personIDs.isEmpty {
            query.append(.init(name: "PersonIds", value: personIDs.joined(separator: ",")))
        }
        // **With a pipe, not a comma.** Genres may themselves contain a comma ("Action,
        // Adventure" exists), so Jellyfin separates this list differently from all others.
        if !genres.isEmpty {
            query.append(.init(name: "Genres", value: genres.joined(separator: "|")))
        }
        if let isWatched {
            query.append(.init(name: "IsPlayed", value: isWatched ? "true" : "false"))
        }
        if slim {
            query.removeAll { ["Limit", "StartIndex", "Fields"].contains($0.name) }
            query += [.init(name: "Fields", value: "SortName"),
                      .init(name: "EnableImages", value: "false"),
                      .init(name: "EnableUserData", value: "false")]
        }
        return try await send(try request("Items", query: query), as: ItemsResponse.self)
    }

    /// How many titles of these kinds are under a folder, without fetching them. One title
    /// is requested because `Limit=0` does not mean "none" on every server; only
    /// `TotalRecordCount` is needed.
    public func count(parentID: String, types: [String]) async throws -> Int {
        let s = try requireSession()
        let req = try request("Items", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "ParentId", value: parentID),
            .init(name: "IncludeItemTypes", value: types.joined(separator: ",")),
            .init(name: "Recursive", value: "true"),
            .init(name: "Limit", value: "1"),
            .init(name: "EnableImages", value: "false"),
            .init(name: "EnableUserData", value: "false"),
        ])
        return try await send(req, as: ItemsResponse.self).totalRecordCount
    }

    /// Everything of one kind from a library: only ID, name, year and provider IDs, without
    /// images and user data. For ``TitleFilter``.
    public func titleIds(parentID: String, types: [String],
                               filters: [String] = [], isWatched: Bool? = nil) async throws -> [Item] {
        let s = try requireSession()
        var query: [URLQueryItem] = [
            .init(name: "userId", value: s.userID),
            .init(name: "ParentId", value: parentID),
            .init(name: "IncludeItemTypes", value: types.joined(separator: ",")),
            .init(name: "Recursive", value: "true"),
            .init(name: "Fields", value: "ProviderIds"),
            .init(name: "EnableImages", value: "false"),
            .init(name: "EnableUserData", value: "false"),
        ]
        if !filters.isEmpty { query.append(.init(name: "Filters", value: filters.joined(separator: ","))) }
        if let isWatched { query.append(.init(name: "IsPlayed", value: isWatched ? "true" : "false")) }
        return try await send(try request("Items", query: query), as: ItemsResponse.self).items
    }

    /// Exactly these entries: only ID, name, kind and provider IDs. For ``Items``: the IDs
    /// of a series whose episodes are compared.
    public func identifiers(ids: [String]) async throws -> [Item] {
        guard !ids.isEmpty else { return [] }
        let s = try requireSession()
        let req = try request("Items", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "Ids", value: ids.joined(separator: ",")),
            .init(name: "Fields", value: "ProviderIds"),
            .init(name: "EnableImages", value: "false"),
            .init(name: "EnableUserData", value: "false"),
        ])
        return try await send(req, as: ItemsResponse.self).items
    }

    /// The folders above an entry up to the library. The library folder comes with the ID
    /// that `UserViews` also names.
    public func preTravel(from id: String) async throws -> [Item] {
        let s = try requireSession()
        let req = try request("Items/\(id)/Ancestors", query: [
            .init(name: "userId", value: s.userID),
        ])
        return try await send(req, as: [Item].self)
    }

    /// The whole watchlist slim (ID, kind, provider IDs), in the page's sort order. For
    /// ``rememberedItems(typen:sortBy:sortOrder:startIndex:limit:)``.
    public func rememberedIds(types: [String], sortBy: String,
                                  sortOrder: String) async throws -> [Item] {
        let s = try requireSession()
        let req = try request("Items", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "Recursive", value: "true"),
            .init(name: "Filters", value: "IsFavorite"),
            .init(name: "IncludeItemTypes", value: types.joined(separator: ",")),
            .init(name: "SortBy", value: sortBy),
            .init(name: "SortOrder", value: sortOrder),
            .init(name: "Fields", value: "ProviderIds"),
            .init(name: "EnableImages", value: "false"),
            .init(name: "EnableUserData", value: "false"),
        ])
        return try await send(req, as: ItemsResponse.self).items
    }

    /// What is in a collection: only ID and kind.
    ///
    /// **Not recursive:** a collection's titles are linked, and the first level is exactly
    /// its content. Without images and user data because the index only needs membership;
    /// the page that shows them fetches the posters.
    public func collectionMembers(_ collection: String) async throws -> [Item] {
        let s = try requireSession()
        let req = try request("Items", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "ParentId", value: collection),
            .init(name: "IncludeItemTypes", value: "Movie,Series"),
            .init(name: "Limit", value: "2000"),
            .init(name: "EnableImages", value: "false"),
            .init(name: "EnableUserData", value: "false"),
        ])
        return try await send(req, as: ItemsResponse.self).items
    }

    /// The entries of a playlist **in the playlist's order**
    /// (`GET /Playlists/{id}/Items`; the server keeps the order, so no sorting).
    ///
    /// - Parameter lean: without images and user data, for the directory that only
    ///   needs the types.
    public func playlistEntries(_ playlist: String, lean: Bool = false) async throws -> [Item] {
        let s = try requireSession()
        var query: [URLQueryItem] = [
            .init(name: "userId", value: s.userID),
            .init(name: "Limit", value: "2000"),
            .init(name: "Fields", value: "Overview,PrimaryImageAspectRatio,ProviderIds"),
        ]
        if lean {
            query.append(.init(name: "EnableImages", value: "false"))
            query.append(.init(name: "EnableUserData", value: "false"))
        }
        let req = try request("Playlists/\(playlist)/Items", query: query)
        return try await send(req, as: ItemsResponse.self).items.filter(VideoPlaylist.isVideoEntry)
    }

    /// Asks the server how it would deliver this title.
    ///
    /// The DeviceProfile is sent along; the answer reveals whether it becomes Direct Play,
    /// Direct Stream or transcode.
    ///
    /// **Always with Direct Play and from second zero.** There used to be an escape hatch:
    /// `EnableDirectPlay` off and `StartTimeTicks` set so the server delivers from a
    /// position. It was needed because VLC 4 could not seek in some Matroska files, and it
    /// cost exactly what this app exists for: the server had to remux.
    ///
    /// Since the patch to the mkv demuxer the player seeks itself, so the escape hatch is
    /// removed; see `Werkzeuge/vlckit-patches/`.
    ///
    /// - Parameter audioStreamIndex: Which audio track the server should use. Set only for
    ///   AirPlay, where the AC-3 track often must be delivered instead of the default DTS
    ///   track because the receiver does not accept DTS. With VLC it stays `nil`: VLC
    ///   chooses itself, from all tracks.
    public func playbackInfo(
        itemID: String,
        profile: DeviceProfile = .vlc(),
        maxStreamingBitrate: Int? = nil,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil
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
            let SubtitleStreamIndex: Int?
        }
        let body = Body(
            UserId: s.userID,
            DeviceProfile: profile,
            MaxStreamingBitrate: maxStreamingBitrate ?? profile.maxStreamingBitrate,
            AutoOpenLiveStream: true,
            EnableDirectPlay: true,
            EnableDirectStream: true,
            EnableTranscoding: true,
            AudioStreamIndex: audioStreamIndex,
            SubtitleStreamIndex: subtitleStreamIndex
        )
        let req = try request("Items/\(itemID)/PlaybackInfo", method: "POST", body: body)
        return try await send(req, as: PlaybackInfoResponse.self)
    }

    /// A single title, fresh from the server.
    ///
    /// Important for resuming: the playback position is in `UserData`, which is often stale
    /// or missing in list entries passed along. `UserData` is not a `Fields` value; the
    /// server returns it automatically once `userId` is sent.
    public func item(id: String) async throws -> Item {
        let s = try requireSession()
        let req = try request("Items/\(id)", query: [
            .init(name: "userId", value: s.userID),
        ])
        return try await send(req, as: Item.self)
    }

    /// **The server's genres**, across movies and series, by name.
    ///
    /// Only genres that really have titles: when scanning, the server counts every ID from
    /// the metadata, even those no movie references any more.
    public func genres() async throws -> [String] {
        let s = try requireSession()
        let req = try request("Genres", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "IncludeItemTypes", value: "Movie,Series"),
            .init(name: "Recursive", value: "true"),
            .init(name: "SortBy", value: "SortName"),
        ])
        return try await send(req, as: ItemsResponse.self).items.map(\.name)
    }

    /// Similar titles: once per title, and never the title itself.
    ///
    /// If the same movie is in two libraries (hardlinks), Jellyfin lists it with two IDs,
    /// and `Similar` returned both, or the copy of the movie currently open. So fetch twice
    /// as many and merge with ``Listenregeln/jeTitleInTimes(_:zeigen:)``.
    public func similar(itemID: String, toward preStatus: Item? = nil, limit: Int = 12) async throws -> [Item] {
        let s = try requireSession()
        let req = try request("Items/\(itemID)/Similar", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "limit", value: String(limit * 2)),
            .init(name: "Fields", value: "ProviderIds"),
        ])
        let raw = try await send(req, as: ItemsResponse.self).items
        let own = preStatus.map(ListRules.titleKey)
        let withoutSelf = raw.filter { $0.id != itemID && ListRules.titleKey($0) != own }
        return ListRules.jeTitleInTimes(withoutSelf, showItem: limit)
    }

    /// Extras: featurettes, making-of, scenes.
    public func extras(itemID: String) async throws -> [Item] {
        let s = try requireSession()
        let req = try request("Items/\(itemID)/SpecialFeatures", query: [
            .init(name: "userId", value: s.userID),
        ])
        // Lenient like `ItemsResponse`: an entry without ID or name would otherwise take
        // the whole list down.
        return try await send(req, as: Lenient<Item>.self).values
    }

    /// Full-text search over movies and series.
    ///
    /// **Episodes are deliberately excluded.** They were included and it looked broken:
    /// every episode carries its series' poster, so a search for "the" showed the same
    /// poster three or four times in a row with episode titles below. Finding a series got
    /// harder, not easier.
    ///
    /// The price: an episode can no longer be found by its own title. On TV that is
    /// tolerable, since nobody searches for an episode title they do not know. If it comes
    /// back, group it under the series, not as a hit of its own.
    public func search(_ term: String, limit: Int = 40) async throws -> [Item] {
        let s = try requireSession()
        let req = try request("Items", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "searchTerm", value: term),
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "Movie,Series"),
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: "Overview,PrimaryImageAspectRatio,ProviderIds,SortName"),
        ])
        // Across all libraries: one hit per work (``Items``).
        let hits = await jeItemInTimes(try await send(req, as: ItemsResponse.self).items)
        // **"By name", as in the libraries** (``NaturalOrder``): digits, Latin, then other
        // scripts, instead of the server's order, which mixes transliterated titles in.
        return NaturalOrder.sorted(hits) { ($0.name, $0.sortName) }
    }

    /// A title's playback state for this account: position, watched, last played. For the
    /// late report (``nachmelden(_:)``).
    public func userRecord(itemID: String) async throws -> UserItemData {
        let s = try requireSession()
        let req = try request("UserItems/\(itemID)/UserData",
                              query: [.init(name: "userId", value: s.userID)])
        return try await send(req, as: UserItemData.self)
    }

    /// Sets only `LastPlayedDate`; the other fields stay as they are
    /// (`UpdateUserItemDataDto`, partially settable since Jellyfin 10.9).
    public func lastPlaySet(itemID: String, moment: Date) async throws {
        struct PlayedDatePayload: Encodable { let LastPlayedDate: String }
        let s = try requireSession()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let req = try request("UserItems/\(itemID)/UserData", method: "POST",
                              query: [.init(name: "userId", value: s.userID)],
                              body: PlayedDatePayload(LastPlayedDate: f.string(from: moment)))
        try await sendIgnoringBody(req)
    }

    /// **Remove from "Continue Watching"**: position to zero, nothing else.
    ///
    /// Jellyfin has no "hide" of its own (12.x has no `HideFromResume`); the row contains
    /// what has a position. Watched stays as it was, unlike "unwatched", which also removes
    /// the mark.
    public func pointBackSet(itemID: String) async throws {
        struct Position: Encodable { let PlaybackPositionTicks: Int64 }
        let s = try requireSession()
        let req = try request("UserItems/\(itemID)/UserData", method: "POST",
                              query: [.init(name: "userId", value: s.userID)],
                              body: Position(PlaybackPositionTicks: 0))
        try await sendIgnoringBody(req)
    }

    #if DEBUG
    /// **For measurement runs only:** a title's playback state as raw JSON, so a run can
    /// restore it exactly (`userDataBackPut`), including count and date, not just
    /// the position.
    public func userDataRaw(itemID: String) async throws -> Data {
        let s = try requireSession()
        let req = try request("UserItems/\(itemID)/UserData",
                              query: [.init(name: "userId", value: s.userID)])
        let (data, _) = try await urlSession.data(for: req)
        return data
    }

    public func userDataBackPut(itemID: String, raw: Data) async throws {
        let s = try requireSession()
        var req = try request("UserItems/\(itemID)/UserData", method: "POST",
                              query: [.init(name: "userId", value: s.userID)])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = raw
        try await sendIgnoringBody(req)
    }
    #endif

    /// Turns the watchlist on or off.
    public func setWatchlist(itemID: String, an: Bool) async throws {
        let s = try requireSession()
        let req = try request("UserFavoriteItems/\(itemID)", method: an ? "POST" : "DELETE",
                              query: [.init(name: "userId", value: s.userID)])
        try await sendIgnoringBody(req)
    }

    /// Marks as watched or removes the mark.
    public func setWatched(itemID: String, an: Bool) async throws {
        let s = try requireSession()
        let req = try request("UserPlayedItems/\(itemID)", method: an ? "POST" : "DELETE",
                              query: [.init(name: "userId", value: s.userID)])
        try await sendIgnoringBody(req)
    }

    /// A series' seasons.
    public func seasons(seriesID: String) async throws -> [Item] {
        let s = try requireSession()
        let req = try request("Shows/\(seriesID)/Seasons", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "isMissing", value: "false"),
            .init(name: "Fields", value: "Overview"),
        ])
        return try await send(req, as: ItemsResponse.self).items
    }

    /// A season's episodes. Without `seasonID` all of the series' episodes.
    public func episodes(seriesID: String, seasonID: String? = nil) async throws -> [Item] {
        let s = try requireSession()
        var query: [URLQueryItem] = [
            .init(name: "userId", value: s.userID),
            .init(name: "isMissing", value: "false"),
            .init(name: "Fields", value: "Overview,MediaSources"),
        ]
        if let seasonID { query.append(.init(name: "seasonId", value: seasonID)) }
        let req = try request("Shows/\(seriesID)/Episodes", query: query)
        return try await send(req, as: ItemsResponse.self).items
    }

    /// **Only the series' first episode**, for fallbacks ("finished", header image
    /// substitute) that would otherwise fetch all episodes of all seasons with description
    /// and media files just to take `.first`. Missing (non-existent) episodes do not count.
    public func firstEpisode(seriesID: String) async throws -> Item? {
        let s = try requireSession()
        let req = try request("Shows/\(seriesID)/Episodes", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "isMissing", value: "false"),
            .init(name: "Limit", value: "1"),
            .init(name: "Fields", value: "Overview,MediaSources"),
        ])
        return try await send(req, as: ItemsResponse.self).items.first
    }

    /// Trailers that exist as files of their own on the server.
    ///
    /// They can be played like any other title; the server delivers a MediaSource for them
    /// too.
    public func trailer(toward itemID: String) async throws -> [Item] {
        let s = try requireSession()
        let req = try request("Items/\(itemID)/LocalTrailers",
                              query: [.init(name: "userId", value: s.userID)])
        // Lenient like `ItemsResponse`: an entry without ID or name would otherwise take
        // the whole list down.
        return try await send(req, as: Lenient<Item>.self).values
    }

    /// Asks the server to re-read the metadata.
    public func metadataRefresh(_ itemID: String) async throws {
        let req = try rawRequest("Items/\(itemID)/Refresh", method: "POST",
                                 query: [.init(name: "metadataRefreshMode", value: "FullRefresh"),
                                         .init(name: "imageRefreshMode", value: "FullRefresh"),
                                         .init(name: "replaceAllMetadata", value: "false")])
        let (_, answer) = try await rawSession.data(for: req)
        guard let http = answer as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw JellyfinError.transport("Der Server hat die Auffrischung abgelehnt.")
        }
    }

    /// Where one is in this series.
    ///
    /// Jellyfin answers both in one call: the started episode or, if none is open, the next
    /// unwatched one. Exactly what the big button on the series page needs.
    public func nextEpisodeSeries(seriesID: String) async throws -> Item? {
        let s = try requireSession()
        let req = try request("Shows/NextUp", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "seriesId", value: seriesID),
            .init(name: "Limit", value: "1"),
            .init(name: "Fields", value: "Overview"),
        ])
        return try await send(req, as: ItemsResponse.self).items.first
    }

    /// The episode after this one. `nil` for movies or at the end of a season.
    ///
    /// `adjacentTo` returns predecessor, current and successor in one go, which is easier
    /// than computing season and episode numbers ourselves.
    ///
    /// **`isMissing=false`:** if the server shows missing episodes, the neighbor could
    /// otherwise be an episode without a file and "Next Episode" would fail at the plan.
    /// Jellyfin filters before the adjacency.
    public func episodePost(itemID: String, seriesID: String) async throws -> Item? {
        let s = try requireSession()
        let req = try request("Shows/\(seriesID)/Episodes", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "isMissing", value: "false"),
            .init(name: "adjacentTo", value: itemID),
            .init(name: "Fields", value: "Overview"),
        ])
        let episodes = try await send(req, as: ItemsResponse.self).items
        guard let now = episodes.firstIndex(where: { $0.id == itemID }),
              episodes.indices.contains(now + 1) else { return nil }
        return episodes[now + 1]
    }

    /// Started titles: the "Continue Watching" row.
    public func resumeItems(limit: Int = 20) async throws -> [Item] {
        let s = try requireSession()
        let req = try request("UserItems/Resume", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: "Overview,PrimaryImageAspectRatio,ProviderIds"),
            .init(name: "MediaTypes", value: "Video"),
        ])
        // Across all libraries: once per work (``Items``).
        return await jeItemInTimes(try await send(req, as: ItemsResponse.self).items)
    }

    /// The next unwatched episode of running series.
    public func nextUp(limit: Int = 20) async throws -> [Item] {
        let s = try requireSession()
        let req = try request("Shows/NextUp", query: [
            .init(name: "userId", value: s.userID),
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: "Overview,PrimaryImageAspectRatio,ProviderIds"),
        ])
        // Across all libraries: once per work (``Items``).
        return await jeItemInTimes(try await send(req, as: ItemsResponse.self).items)
    }

    /// **What was added most recently, via the ordinary Items endpoint.**
    ///
    /// `Items/Latest` used to be used. It answers a different question than the home page
    /// asks: it **hides watched items** when the Jellyfin account has "Hide watched titles
    /// in Latest Media" on, which is the server default.
    ///
    /// **And that is not our question.** "Recently Added" answers "what is new on my
    /// server", not "what have I not watched yet"; that is what "Continue Watching" and
    /// "Next Up" are for. A movie added the day before yesterday and watched yesterday
    /// belongs in this row.
    ///
    /// **The pre-filtering cannot be turned off on `Items/Latest`.** `IsPlayed` is a
    /// `Bool?` there: `true` means watched only, `false` unwatched only, omitted means "as
    /// set in the account". There is no value for "both". The `Items` route does not know
    /// this pre-filtering; a sort field instead of a special rule.
    ///
    /// Two properties are kept, and both explain the shape of this query:
    ///
    /// - **`IncludeItemTypes=Movie,Episode`, not `Series`.** An episode carries
    ///   `ParentIndexNumber`, `IndexNumber`, `SeriesId` and `SeriesName`; a series carries
    ///   none of them. Only that allows "Season 20" under the tile and "S6 • E5" in the
    ///   detail line. Merged into the series, the server only gives the count of new
    ///   episodes, the same limitation the old `GroupItems` had. The enumeration is also
    ///   needed so a series library does not return series **and** seasons **and** episodes
    ///   three times over.
    /// - **Merging happens here, not on the server**
    ///   (``lastAdded(in:fetch:show:)``): one row per series, with its newest
    ///   episode.
    ///
    /// `IsVirtualItem=false` keeps out episodes the server only knows from the index and
    /// that have no file; the same reasoning as ``episodePost(itemID:seriesID:)``.
    ///
    /// Without `parentID` across all libraries.
    ///
    /// `slim`: only what ``Listenregeln/jeTitleInTimes(_:zeigen:)`` needs for merging,
    /// without description, images and user data. See
    /// ``lastAdded(in:fetch:show:)``.
    ///
    /// `genres`: Jellyfin's `IncludeItemTypes`, e.g. only episodes for "New Series"
    /// without a library, so movies do not use up the supply.
    public func newlyJoined(parentID: String? = nil, limit: Int = 20,
                                slim: Bool = false,
                                genres: String = "Movie,Episode") async throws -> [Item] {
        let s = try requireSession()
        var query: [URLQueryItem] = [
            .init(name: "userId", value: s.userID),
            .init(name: "Limit", value: String(limit)),
            .init(name: "Recursive", value: "true"),
            .init(name: "SortBy", value: "DateCreated"),
            .init(name: "SortOrder", value: "Descending"),
            .init(name: "IncludeItemTypes", value: genres),
            .init(name: "IsVirtualItem", value: "false"),
        ]
        if slim {
            query += [
                .init(name: "Fields", value: "ProviderIds"),
                .init(name: "EnableImages", value: "false"),
                .init(name: "EnableUserData", value: "false"),
            ]
        } else {
            query.append(.init(name: "Fields", value: "Overview,PrimaryImageAspectRatio,ProviderIds"))
        }
        if let parentID { query.append(.init(name: "ParentId", value: parentID)) }
        return try await send(try request("Items", query: query), as: ItemsResponse.self).items
    }

    /// Asks the server and builds the player's plan directly from the answer.
    public func playbackPlan(
        for itemID: String,
        profile: DeviceProfile = .vlc(),
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil
    ) async throws -> PlaybackPlan? {
        let info = try await playbackInfo(itemID: itemID, profile: profile,
                                          audioStreamIndex: audioStreamIndex,
                                          subtitleStreamIndex: subtitleStreamIndex)
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

    // MARK: - Handover

    /// The sessions this user may control.
    ///
    /// `controllableByUserId` matters: without the filter a family server also returns
    /// other people's sessions, and the badge would show what someone else is watching.
    /// `activeWithinSeconds` keeps the response small, since Jellyfin keeps old sessions
    /// for a long time.
    ///
    /// **A failure is not an error**, as with the segments: there is simply no offer. A
    /// badge is an extra, not a promise.
    /// **Throws instead of passing a failure off as "nothing there".**
    ///
    /// This used to be `catch { return [] }`. An expired token, an unreachable server and
    /// an unreadable response then looked from outside **exactly like "nothing is playing
    /// on any other device"**, the normal case nobody questions. A log line saying "0
    /// sessions, no offer" could not tell whether the server had nothing or the question
    /// never arrived.
    ///
    /// The view may stay silent when nothing works (it asks every ten seconds, so no error
    /// message belongs there), but it should **know** what happened instead of guessing.
    public func remoteSession() async throws -> [RemoteSession] {
        let s = try requireSession()
        let req = try request("Sessions", query: [
            .init(name: "controllableByUserId", value: s.userID),
            .init(name: "activeWithinSeconds", value: "120"),
        ])
        return try await send(req, as: [RemoteSession].self)
    }

    /// Sends a playback command to another session.
    ///
    /// The same route Jellyfin's own UI takes. It needs nothing from us except the session
    /// ID; the other side is already listening on its socket, see ``Fernsteuerung``.
    public func foreignCommand(_ command: ForeignCommand, an session: String) async throws {
        let req = try request("Sessions/\(session)/Playing/\(command.rawValue)",
                              method: "POST")
        let (_, answer) = try await urlSession.data(for: req)
        guard let http = answer as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw JellyfinError.transport(translated("Das andere Gerät hat nicht reagiert."))
        }
    }

    /// **The handover notice**: who takes over, to the one handing over.
    ///
    /// Goes out as a `DisplayMessage` with its own header (``Uebernahme/hintHeader``)
    /// **before** the stop. The stop alone does not tell the sender *why* it should stop;
    /// without this it cannot tell a stop from the dashboard from a handover. Only sent to
    /// Swiftly: other programs show the message as text.
    public func handoffHint(an session: String, device: String) async throws {
        var req = try request("Sessions/\(session)/Message", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "Header": Takeover.hintHeader, "Text": device, "TimeoutMs": 1000,
        ])
        let (_, answer) = try await urlSession.data(for: req)
        guard let http = answer as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw JellyfinError.transport(translated("Das andere Gerät hat nicht reagiert."))
        }
    }

    /// The account's settings and permissions: "Next episode automatically" and
    /// `EnableContentDownloading` (``DownloadPermission``). `nil` on any failure, in which case
    /// the app does what it does anyway; a network error is no reason to change anything.
    ///
    /// **The client remembers the download permission here**, so
    /// ``downloadURL(itemID:mediaSourceID:)`` does not need it as a parameter. Only on a
    /// response, never on a failure: otherwise the first timeout would lift a block the
    /// operator set.
    public func accountDefaults() async -> AccountPreGift? {
        guard let s = session,
              let req = try? request("Users/\(s.userID)"),
              let guidelines = try? await send(req, as: AccountPreGift.self) else { return nil }
        downloadRightState = guidelines.downloadPermission
        return guidelines
    }

    /// The marked segments of an episode: intro, recap, outro.
    ///
    /// **A failure is not an error.** On a server without the plugin the list is empty, and
    /// older versions do not know the endpoint at all. Both mean the same: no button.
    /// Treating that as an error shows a message for a feature the viewer never expected.
    public func sections(for itemID: String) async -> [Segment] {
        await segmentsToStore(for: itemID) ?? []
    }

    /// The same for the store used by downloads, **with the difference between "none" and
    /// "unreachable"**: `nil` means no response came and it is asked again on the next
    /// contact. An error response from the server (old version without the endpoint) counts
    /// as "none".
    public func segmentsToStore(for itemID: String) async -> [Segment]? {
        do {
            let req = try request("MediaSegments/\(itemID)")
            return try await send(req, as: SectionResponse.self).items
        } catch JellyfinError.http(_, _) {
            return []
        } catch {
            return nil
        }
    }

    /// Trickplay information for the current source; `nil` if the server has none (before
    /// 10.9, or not generated). See ``Trickplay``.
    public func trickplay(itemID: String, mediaSourceID: String?, target: Int = 320) async -> Trickplay? {
        do {
            let s = try requireSession()
            let req = try request("Items/\(itemID)", query: [
                .init(name: "userId", value: s.userID),
                .init(name: "Fields", value: "Trickplay"),
            ])
            return try await send(req, as: TrickplayResponse.self)
                .of(source: mediaSourceID, target: target)
        } catch {
            return nil
        }
    }

    /// **The chapters of the current version**, already cleaned up
    /// (``Kapitelleiste/brauchbar(_:)``). Empty on any failure, in which case the bar is
    /// one piece as before.
    ///
    /// **It asks for the source, not the title.** If a movie has several versions, each is
    /// a title of its own on the server and the source's ID is its ID; a director's cut has
    /// different chapters than the theatrical cut. If the server does not know the source
    /// as a title (it then is not one), the title itself applies.
    public func chapter(itemID: String, mediaSourceID: String?) async -> [Chapter] {
        if let source = mediaSourceID, source.lowercased() != itemID.lowercased(),
           let found = await chapterQuery(source) {
            return ChapterBar.usable(found)
        }
        // Cancelled (the title has already changed): do not ask again.
        guard !Task.isCancelled else { return [] }
        return ChapterBar.usable(await chapterQuery(itemID) ?? [])
    }

    private func chapterQuery(_ itemID: String) async -> [Chapter]? {
        do {
            let s = try requireSession()
            let req = try request("Items/\(itemID)", query: [
                .init(name: "userId", value: s.userID),
                .init(name: "Fields", value: "Chapters"),
            ])
            return try await send(req, as: ChapterResponse.self).chapter
        } catch {
            return nil
        }
    }

    /// Address of a trickplay tile sheet. Signed in like the other image requests, via
    /// `ApiKey`.
    public func trickplayURL(itemID: String, mediaSourceID: String?, width: Int, sheet: Int) -> URL? {
        guard let token = session?.accessToken else { return nil }
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("Videos/\(itemID)/Trickplay/\(width)/\(sheet).jpg"),
            resolvingAgainstBaseURL: false
        )
        var query: [URLQueryItem] = []
        if let mediaSourceID { query.append(.init(name: "MediaSourceId", value: mediaSourceID)) }
        query.append(.init(name: "ApiKey", value: token))
        comps?.queryItems = query
        return comps?.url
    }

    /// A tile sheet as raw JPEG data, over the same session as all other requests. `nil` on
    /// any error, in which case only the time is shown.
    public func trickplaySheet(itemID: String, mediaSourceID: String?, width: Int, sheet: Int) async -> Data? {
        guard let url = trickplayURL(itemID: itemID, mediaSourceID: mediaSourceID,
                                     width: width, sheet: sheet),
              let (data, answer) = try? await urlSession.data(for: .withOwnHeaders(url)),
              let http = answer as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return data
    }

    /// What AirPlay offers for this title.
    ///
    /// **The check comes before the request, not after.** The file's streams are already in
    /// the source the current plan brings, so no server visit is needed to say "not
    /// possible". And there must be none: asking first and rejecting afterwards opens a
    /// session on the server that nobody closes.
    ///
    /// If it works, **one** request runs, with the narrow profile and the audio track that
    /// gets through.
    public func airplayPlan(for itemID: String, source: MediaSource) async throws -> AirPlayInfo {
        let suitability = AirPlaySuitability.check(source: source)
        guard suitability.fitting else { return .goesNot(suitability) }
        // **`SubtitleStreamIndex: -1` is not a detail.**
        //
        // If Jellyfin picks a subtitle track AVPlayer cannot draw on its own (PGS and
        // VOBSUB are deliberately not in the AirPlay profile), it burns it into the
        // picture, which means the video is re-encoded. Then the segments no longer arrive
        // in time, AVPlayer stays at `unknown` and reports `-12889 · No response for map in
        // 3s`: no error, no picture, a black screen without diagnosis.
        //
        // Explicitly `-1` and not `nil`: `nil` means "you decide", which is exactly what
        // the server must not do here.
        let info = try await playbackInfo(itemID: itemID, profile: .airplay(),
                                          audioStreamIndex: suitability.audioTrack,
                                          subtitleStreamIndex: -1)
        guard let source = PlaybackPlan.bestSource(info.mediaSources) else {
            if let reason = info.errorCode, !reason.isEmpty { throw JellyfinError.playbackRejected(reason) }
            throw JellyfinError.noPlayableSource
        }

        // **Without an address from the server it does not work, and that was a hole.**
        //
        // If the container is not something for AVPlayer (Matroska), the server must remux
        // and name a `TranscodingUrl` for that. If it names none, the plan used to fall
        // back silently to the **original file** (`/stream?static=true`) and pass that to
        // AVPlayer, which cannot open it: a black screen on TV.
        //
        // For the VLC path the same fallback is right, since VLC opens the file. Here it is
        // wrong, so the check is here.
        if source.deliveryMethod != .directPlay, source.transcodingUrl == nil {
            return .goesNot(AirPlaySuitability(audioTrack: nil, obstacles: [
                AirPlaySuitability.Obstacle(art: .umpacken,
                                         codec: source.container ?? "?")
            ]))
        }

        guard let plan = try PlaybackPlan.make(
            from: info, itemID: itemID, profile: .airplay(),
            streamURL: { [self] id, sourceID, sessionID in
                try streamURL(itemID: id, mediaSourceID: sourceID, playSessionID: sessionID)
            },
            serverBase: baseURL
        ) else {
            throw JellyfinError.noPlayableSource
        }
        return .goes(plan)
    }

    // MARK: - URLs for the player

    /// The address VLC gets. For Direct Play this is the unchanged file on the server's
    /// disk.
    public func streamURL(itemID: String, mediaSourceID: String?,
                          playSessionID: String? = nil) throws -> URL {
        let s = try requireSession()
        guard var comps = URLComponents(
            url: baseURL.appendingPathComponent("Videos/\(itemID)/stream"),
            resolvingAgainstBaseURL: false
        ) else { throw JellyfinError.invalidServerURL }

        var query: [URLQueryItem] = [
            .init(name: "static", value: "true"),
            .init(name: "ApiKey", value: s.accessToken),
        ]
        if let mediaSourceID { query.append(.init(name: "mediaSourceId", value: mediaSourceID)) }
        if let playSessionID { query.append(.init(name: "playSessionId", value: playSessionID)) }
        comps.queryItems = query
        guard let url = comps.url else { throw JellyfinError.invalidServerURL }
        return url
    }

    /// The address a title is downloaded from.
    ///
    /// It is the same address as for playback, `/stream?static=true`, i.e. the unchanged
    /// file from the server's disk. That is the promise: what is downloaded is what would
    /// be streamed, bit for bit. An app that transcodes for downloads after all breaks it
    /// where it is most noticeable.
    ///
    /// **Without `playSessionId`, and that is the whole difference.** A download is not
    /// playback: with a session ID the device would show up on the server as "playing now",
    /// appear in remote control and be offered for handover while nobody is looking.
    ///
    /// **Not `/Items/{id}/Download`.** That route would give the same bytes but requires
    /// the `EnableContentDownloading` permission on the account; without it the user would
    /// get a 403 instead of a file.
    ///
    /// **And that turned out to be a hole.** Of the server's 409 operations only `GET
    /// /Items/{itemId}/Download` carries the `Download` permission; `/Videos/{id}/stream`
    /// carries none. This address therefore reached the file even if the operator had
    /// unchecked "Allow media downloading". The detour stays (it is right because of the
    /// "no transcoding" promise), but the permission is now read: ``DownloadPermission`` from
    /// ``accountDefaults()``.
    ///
    /// **The bolt sits here**, not only in the UI. The UI does not show the button at all
    /// (``Downloadrecht/anbieten(recht:funktionAn:)``); this place catches every other
    /// path: a resumed queue, a season from storage, a future platform. The 403 is the same
    /// response the server would give.
    public func downloadURL(itemID: String, mediaSourceID: String?) throws -> URL {
        guard downloadRightState.mayLoad else {
            throw JellyfinError.http(status: 403, body: "EnableContentDownloading")
        }
        return try streamURL(itemID: itemID, mediaSourceID: mediaSourceID, playSessionID: nil)
    }

    /// **The address for a download in lower quality.**
    ///
    /// For the original the same as above. Otherwise the same endpoint with `static=false`:
    /// the server converts continuously and sends the file while it is being created, a
    /// single request the background session loads like any other. HLS would be the other
    /// way, but it needs a muxer on the device, and a paused download would consist of
    /// hundreds of pieces.
    ///
    /// **Without length.** The server only knows the size at the end; progress uses the
    /// estimate of bitrate times runtime
    /// (``Downloadqualitaet/estimatedBytes(original:laufzeitTicks:)``).
    ///
    /// The bolt is the same as for the original: without the download permission, no
    /// address.
    public func downloadURL(itemID: String, mediaSourceID: String?,
                            quality: DownloadQuality) throws -> URL {
        guard !quality.isOriginal,
              let image = quality.imageBitrate, let audio = quality.audioBitrate,
              let height = quality.height, let width = quality.width,
              let channels = quality.audioChannels
        else { return try downloadURL(itemID: itemID, mediaSourceID: mediaSourceID) }
        guard downloadRightState.mayLoad else {
            throw JellyfinError.http(status: 403, body: "EnableContentDownloading")
        }
        let s = try requireSession()
        let c = DownloadQuality.container
        guard var comps = URLComponents(
            url: baseURL.appendingPathComponent("Videos/\(itemID)/stream.\(c)"),
            resolvingAgainstBaseURL: false
        ) else { throw JellyfinError.invalidServerURL }
        var query: [URLQueryItem] = [
            .init(name: "static", value: "false"),
            .init(name: "container", value: c),
            .init(name: "videoCodec", value: "h264"),
            .init(name: "audioCodec", value: "aac"),
            .init(name: "videoBitRate", value: String(image)),
            .init(name: "audioBitRate", value: String(audio)),
            .init(name: "maxAudioChannels", value: String(channels)),
            .init(name: "maxHeight", value: String(height)),
            .init(name: "maxWidth", value: String(width)),
            // The device ID keeps the conversion job apart on the server; two downloads of
            // the same title from two devices would otherwise share one job.
            .init(name: "deviceId", value: deviceID),
            .init(name: "ApiKey", value: s.accessToken),
        ]
        if let mediaSourceID { query.append(.init(name: "mediaSourceId", value: mediaSourceID)) }
        comps.queryItems = query
        guard let url = comps.url else { throw JellyfinError.invalidServerURL }
        return url
    }

    /// Background image for the series page. `nil` if none is set.
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
            .init(name: "ApiKey", value: token),
        ]
        return comps?.url
    }

    /// Absolute URL for a poster. `nil` if the title has no image.
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
            .init(name: "ApiKey", value: token),
        ]
        return comps?.url
    }
}

/// Small helper so `request(body:)` can accept any Encodable.
private struct AnyEncodable: Encodable {
    private let encode: (Encoder) throws -> Void
    init(_ wrapped: any Encodable) {
        encode = { try wrapped.encode(to: $0) }
    }
    func encode(to encoder: Encoder) throws { try encode(encoder) }
}

extension JellyfinError {
    /// Classifies a failed sign-in: 401 **with** a token means the password was right and a
    /// two-factor plugin wants confirmation; see ``twoFactor``. Everything else stays as
    /// it was.
    static func loginError(status: Int, shell: String?) -> JellyfinError {
        if status == 401, let shell, shell.contains("\"AccessToken\"") {
            return .twoFactor
        }
        return .http(status: status, body: shell)
    }
}

