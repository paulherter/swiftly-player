import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A sign-in in progress: the code the user confirms in the browser or at plex.tv/link.
public struct PlexPin: Sendable, Equatable, Decodable {
    public let id: Int
    public let code: String
    /// Set once the user has confirmed; `nil` until then.
    public let authToken: String?
    /// Seconds the code lives from creation; Plex answered 1800 for a strong one.
    public let expiresIn: Int?
    public let expiresAt: String?

    enum CodingKeys: String, CodingKey { case id, code, authToken, expiresIn, expiresAt }

    public init(id: Int, code: String, authToken: String? = nil,
                expiresIn: Int? = nil, expiresAt: String? = nil) {
        self.id = id; self.code = code; self.authToken = authToken
        self.expiresIn = expiresIn; self.expiresAt = expiresAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.looseInt(.id), let code = c.looseString(.code) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath,
                                                                 debugDescription: "pin"))
        }
        self.id = id; self.code = code
        authToken = c.looseString(.authToken).flatMap { $0.isEmpty ? nil : $0 }
        expiresIn = c.looseInt(.expiresIn)
        expiresAt = c.looseString(.expiresAt)
    }
}

/// A person of the Plex Home (a profile you can switch to).
public struct PlexHomeUser: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    /// The new route (`/api/v2/home/users/{uuid}/switch`) works with this.
    public let uuid: String
    public let title: String
    public let thumb: String?
    /// Asks for a PIN when switching to it.
    public let isProtected: Bool
    public let isAdmin: Bool
    public let isRestricted: Bool
    public let isGuest: Bool

    enum CodingKeys: String, CodingKey {
        case id, uuid, title, thumb, admin, restricted, guest
        case isProtected = "protected"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.looseString(.id), let uuid = c.looseString(.uuid) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath,
                                                                 debugDescription: "id"))
        }
        self.id = id; self.uuid = uuid
        title = c.looseString(.title) ?? ""
        thumb = c.looseString(.thumb)
        isProtected = c.looseBool(.isProtected) ?? false
        isAdmin = c.looseBool(.admin) ?? false
        isRestricted = c.looseBool(.restricted) ?? false
        isGuest = c.looseBool(.guest) ?? false
    }
}

/// The signed-in plex.tv account, as far as the app needs it.
public struct PlexAccount: Sendable, Equatable, Decodable {
    public let id: String
    public let uuid: String?
    public let title: String
    public let thumb: String?

    enum CodingKeys: String, CodingKey { case id, uuid, title, username, friendlyName, thumb }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.looseString(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath,
                                                                 debugDescription: "id"))
        }
        self.id = id
        uuid = c.looseString(.uuid)
        title = c.looseString(.title) ?? c.looseString(.friendlyName)
            ?? c.looseString(.username) ?? ""
        thumb = c.looseString(.thumb)
    }
}

/// Everything that goes to **plex.tv** rather than to the server: sign-in with a PIN,
/// token check, the list of servers, switching Plex Home profiles.
///
/// Mapping to the future `MediaServer` protocol: this is the "sign-in" half
/// (`signIn(.pin)`, `sessionStillValid`); the server itself is ``PlexClient``.
public struct PlexAccountService: Sendable {

    public let identity: PlexIdentity
    private let session: URLSession
    /// Overridable for tests; production uses plex.tv.
    let tvBase: URL
    let clientsBase: URL
    let appBase: URL

    public init(identity: PlexIdentity, urlSession: URLSession = .localNetworkCapable) {
        self.init(identity: identity, urlSession: urlSession,
                  tvBase: URL(string: "https://plex.tv")!,
                  clientsBase: URL(string: "https://clients.plex.tv")!,
                  appBase: URL(string: "https://app.plex.tv")!)
    }

    init(identity: PlexIdentity, urlSession: URLSession, tvBase: URL, clientsBase: URL,
         appBase: URL) {
        self.identity = identity
        self.session = urlSession
        self.tvBase = tvBase
        self.clientsBase = clientsBase
        self.appBase = appBase
    }

    // MARK: - PIN sign-in

    /// Step 1: ask for a code. `strong` gives a long code for the browser link; without it
    /// a short one (four characters) that the user types at `plex.tv/link`, the Apple TV
    /// way and Plex's counterpart to Jellyfin's Quick Connect.
    public func startPin(strong: Bool = true) async throws -> PlexPin {
        var parts = URLComponents(url: tvBase.appendingPathComponent("api/v2/pins"),
                                  resolvingAgainstBaseURL: false)!
        if strong { parts.queryItems = [.init(name: "strong", value: "true")] }
        return try await send(url: parts.url!, method: "POST", as: PlexPin.self)
    }

    /// Step 2: the address to open in the browser (strong code).
    public func authURL(for pin: PlexPin, forwardURL: URL? = nil) -> URL? {
        // The parameters live behind the `#`, as the web app reads them there.
        var fragment = "?clientID=\(Self.encode(identity.clientID))&code=\(Self.encode(pin.code))"
        fragment += "&context%5Bdevice%5D%5Bproduct%5D=\(Self.encode(identity.product))"
        if let forwardURL { fragment += "&forwardUrl=\(Self.encode(forwardURL.absoluteString))" }
        return URL(string: appBase.absoluteString + "/auth#" + fragment)
    }

    /// Where the user types a short code (a PIN started without `strong`).
    public var linkPage: URL { tvBase.appendingPathComponent("link") }

    /// Step 3: has the user confirmed? One look; `authToken` is set once they have.
    public func checkPin(_ pin: PlexPin) async throws -> PlexPin {
        var parts = URLComponents(url: tvBase.appendingPathComponent("api/v2/pins/\(pin.id)"),
                                  resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "code", value: pin.code)]
        return try await send(url: parts.url!, method: "GET", as: PlexPin.self)
    }

    /// Polls about once a second until the token is there, the code has expired or the
    /// task is cancelled. `pause` and `limit` are parameters so a test does not wait.
    public func awaitToken(_ pin: PlexPin, pause: Duration = .seconds(1),
                           limit: Duration = .seconds(1800)) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while clock.now < deadline {
            try Task.checkCancellation()
            do {
                if let token = try await checkPin(pin).authToken { return token }
            } catch JellyfinError.http(let status, _) where status == 404 || status == 410 {
                // Plex forgets an expired code: 404 (measured elsewhere: 410).
                throw PlexError.pinExpired
            }
            try await Task.sleep(for: pause)
        }
        throw PlexError.pinExpired
    }

    // MARK: - Token

    public enum TokenState: Sendable, Equatable { case valid(PlexAccount), invalid }

    /// `200` valid, `401` invalid; **anything else is an error, not a sign-out**: a plex.tv
    /// outage must not throw users out.
    public func validate(token: String) async throws -> TokenState {
        do {
            let user = try await send(url: tvBase.appendingPathComponent("api/v2/user"),
                                      token: token, as: PlexAccount.self)
            return .valid(user)
        } catch JellyfinError.http(let status, _) where status == 401 {
            return .invalid
        }
    }

    // MARK: - Servers

    /// The servers this account may use, with every address.
    public func servers(token: String) async throws -> [PlexServerResource] {
        var parts = URLComponents(url: clientsBase.appendingPathComponent("api/v2/resources"),
                                  resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "includeHttps", value: "1"),
                            .init(name: "includeRelay", value: "1"),
                            .init(name: "includeIPv6", value: "1")]
        let all = try await send(url: parts.url!, token: token,
                                 as: Lenient<PlexServerResource>.self).values
        return all.filter { $0.provides.contains("server") }
    }

    // MARK: - Plex Home

    public func homeUsers(token: String) async throws -> [PlexHomeUser] {
        struct Answer: Decodable {
            let users: [PlexHomeUser]
            enum CodingKeys: String, CodingKey { case users }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                users = c.looseList(.users) ?? []
            }
        }
        let url = clientsBase.appendingPathComponent("api/v2/home/users")
        return try await send(url: url, token: token, as: Answer.self).users
    }

    /// Switches to a profile and returns **that profile's own token**. With it the
    /// resources, the server and the progress belong to the profile. A protected profile
    /// needs its PIN; a wrong one is ``PlexError/profilePinWrong``.
    public func switchUser(_ user: PlexHomeUser, pin: String?, token: String) async throws
        -> String {
        struct Answer: Decodable {
            let authToken: String?
            enum CodingKeys: String, CodingKey { case authToken }
            init(from decoder: any Decoder) throws {
                authToken = try decoder.container(keyedBy: CodingKeys.self)
                    .looseString(.authToken)
            }
        }
        var parts = URLComponents(
            url: clientsBase.appendingPathComponent("api/v2/home/users/\(user.uuid)/switch"),
            resolvingAgainstBaseURL: false)!
        if let pin, !pin.isEmpty { parts.queryItems = [.init(name: "pin", value: pin)] }
        do {
            let answer = try await send(url: parts.url!, method: "POST", token: token,
                                        as: Answer.self)
            guard let fresh = answer.authToken, !fresh.isEmpty else {
                throw JellyfinError.decoding("Kein Token in der Antwort.")
            }
            return fresh
        } catch JellyfinError.http(let status, _) where [401, 403, 429].contains(status) {
            // plex.tv answers a wrong PIN with 401/403.
            throw PlexError.profilePinWrong
        }
    }

    // MARK: - Transport

    private func send<T: Decodable>(url: URL, method: String = "GET", token: String? = nil,
                                    as: T.Type) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = method
        for (name, value) in identity.headers(token: token) {
            req.setValue(value, forHTTPHeaderField: name)
        }
        return try await PlexTransport.decode(req, session: session, as: T.self)
    }

    /// Percent-encoding for a value inside the `#` fragment: everything but unreserved.
    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters:
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))
            ?? text
    }
}

/// One Plex server of the account.
public struct PlexServerResource: Sendable, Equatable, Decodable, Identifiable {
    public var id: String { machineIdentifier }
    public let name: String
    public let machineIdentifier: String
    public let provides: [String]
    public let owned: Bool
    /// The token **for this one server**; always take this one, not the account token.
    public let accessToken: String?
    public let httpsRequired: Bool
    public let presence: Bool
    public let connections: [PlexConnectionInfo]
    /// For a server somebody else shares: that person's name (plex.tv's `sourceTitle`).
    public let sourceTitle: String?

    enum CodingKeys: String, CodingKey {
        case name, provides, owned, accessToken, httpsRequired, presence, connections, sourceTitle
        case machineIdentifier = "clientIdentifier"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let machine = c.looseString(.machineIdentifier) else {
            throw DecodingError.keyNotFound(CodingKeys.machineIdentifier, .init(
                codingPath: c.codingPath, debugDescription: "clientIdentifier"))
        }
        machineIdentifier = machine
        name = c.looseString(.name) ?? ""
        provides = (c.looseString(.provides) ?? "").split(separator: ",").map(String.init)
        owned = c.looseBool(.owned) ?? false
        accessToken = c.looseString(.accessToken)
        httpsRequired = c.looseBool(.httpsRequired) ?? false
        presence = c.looseBool(.presence) ?? true
        connections = c.looseList(.connections) ?? []
        sourceTitle = c.looseString(.sourceTitle)
    }
}

/// One address under which a server may be reachable.
public struct PlexConnectionInfo: Sendable, Equatable, Codable, Hashable {
    public let uri: String
    public let address: String
    public let port: Int
    public let isHTTPS: Bool
    public let isLocal: Bool
    public let isRelay: Bool
    public let isIPv6: Bool

    public init(uri: String, address: String, port: Int, isHTTPS: Bool,
                isLocal: Bool, isRelay: Bool, isIPv6: Bool = false) {
        self.uri = uri; self.address = address; self.port = port; self.isHTTPS = isHTTPS
        self.isLocal = isLocal; self.isRelay = isRelay; self.isIPv6 = isIPv6
    }

    enum CodingKeys: String, CodingKey {
        case uri, address, port, local, relay
        case isHTTPS = "protocol", isIPv6 = "IPv6"
        case isLocal, isRelayStored
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let uri = c.looseString(.uri) else {
            throw DecodingError.keyNotFound(CodingKeys.uri, .init(codingPath: c.codingPath,
                                                                  debugDescription: "uri"))
        }
        self.uri = uri
        address = c.looseString(.address) ?? ""
        port = c.looseInt(.port) ?? 32400
        // plex.tv writes `"protocol": "https"`; the stored form (below) a flag.
        let proto = c.looseString(.isHTTPS)
        isHTTPS = proto.map { $0.lowercased() == "https" } ?? uri.lowercased().hasPrefix("https")
        isLocal = c.looseBool(.local) ?? c.looseBool(.isLocal) ?? false
        isRelay = c.looseBool(.relay) ?? c.looseBool(.isRelayStored) ?? false
        isIPv6 = c.looseBool(.isIPv6) ?? false
    }

    /// Stored in the app's own form (flags instead of plex.tv's spelling).
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uri, forKey: .uri)
        try c.encode(address, forKey: .address)
        try c.encode(port, forKey: .port)
        try c.encode(isHTTPS ? "https" : "http", forKey: .isHTTPS)
        try c.encode(isLocal, forKey: .isLocal)
        try c.encode(isRelay, forKey: .isRelayStored)
        try c.encode(isIPv6, forKey: .isIPv6)
    }
}

/// Shared by plex.tv and server calls: send, check the status, decode.
enum PlexTransport {

    static func decode<T: Decodable>(_ req: URLRequest, session: URLSession,
                                     as: T.Type) async throws -> T {
        let data = try await fetch(req, session: session)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw JellyfinError.decoding(String(describing: error))
        }
    }

    @discardableResult
    static func fetch(_ req: URLRequest, session: URLSession) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw JellyfinError(petition: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError.transport("Keine HTTP-Antwort.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError.http(status: http.statusCode,
                                     body: String(data: data.prefix(300), encoding: .utf8))
        }
        return data
    }
}
