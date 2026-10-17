import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Application credentials

/// **The id of the Trakt application, not of a user.**
///
/// Trakt requires every app to be registered at trakt.tv/oauth/applications;
/// `client_id` and `client_secret` come from there. Both are **not in the
/// repo**: it is public, and whoever has them speaks to Trakt in the name of
/// Swiftly.
///
/// They therefore live in a file that `.gitignore` excludes:
///
///     Packages/JellyfinKit/Sources/JellyfinKit/Resources/Trakt.json
///     {"client_id": "…", "client_secret": "…"}
///
/// **One file for all versions that build the package.** Apple, Linux and
/// Windows take it along through the package's resource bundle; an `.xcconfig`
/// would have reached only the Apple targets, and Linux and Windows would have
/// needed a second path that drifts apart. Android has no `Bundle.module` (see
/// `Translation.swift`) and passes the values in through
/// ``init(clientID:secret:)``.
///
/// **If the file is missing, there is no Trakt**: ``outPackage`` is then `nil`,
/// and the setting for it is not shown at all. A build without credentials is
/// not a broken build, just one without this extra.
///
/// That a secret can be extracted from a shipped app holds for every native
/// Trakt app (Plezy even keeps it in the source). It does not protect a user's
/// account, which has its own token, only the name of the application.
public struct TraktAccess: Sendable, Equatable {
    public let clientID: String
    public let secret: String

    public init(clientID: String, secret: String) {
        self.clientID = clientID
        self.secret = secret
    }

    /// Reads the configuration file. `nil` if a value is missing or empty: half a
    /// set of credentials would be a button that is guaranteed to fail.
    public static func read(_ data: Data) -> TraktAccess? {
        struct FileInfo: Decodable {
            let client_id: String?
            let client_secret: String?
        }
        guard let file = try? JSONDecoder().decode(FileInfo.self, from: data) else { return nil }
        let id = (file.client_id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = (file.client_secret ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        return TraktAccess(clientID: id, secret: secret)
    }

    #if os(Android)
    /// Android has no resource bundle; the app passes the values in itself.
    public static let outPackage: TraktAccess? = nil
    #else
    /// The credentials from `Resources/Trakt.json`, read once.
    public static let outPackage: TraktAccess? = {
        guard let url = Bundle.module.url(forResource: "Trakt", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return read(data)
    }()
    #endif
}

// MARK: - A user's token

/// What is stored after connecting. On Apple in the keychain, on Linux and
/// Windows in a file with the same permissions as the Jellyfin session.
public struct TraktToken: Codable, Sendable, Equatable {
    enum CodingKeys: String, CodingKey {
        case access = "zugriff"
        case renewal = "erneuerung"
        case flow = "ablauf"
        case user = "benutzer"
    }
    public var access: String
    public var renewal: String
    public var flow: Date
    /// The name at Trakt, only for the display "Verbunden als …".
    public var user: String?

    public init(access: String, renewal: String, flow: Date, user: String? = nil) {
        self.access = access
        self.renewal = renewal
        self.flow = flow
        self.user = user
    }

    /// **Renew an hour before expiry, not after.** How long a token is valid,
    /// Trakt says in `expires_in`, and it can be as little as a day. Whoever waits
    /// for the 401 sends the first report of every day twice.
    public func renewDue(now: Date = Date()) -> Bool {
        flow.timeIntervalSince(now) < 3600
    }

    /// From the response of `/oauth/device/token` or `/oauth/token`.
    static func from(_ data: Data, now: Date = Date()) -> TraktToken? {
        struct Reply: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Double?
            let created_at: Double?
        }
        guard let a = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        let beginning = a.created_at.map { Date(timeIntervalSince1970: $0) } ?? now
        return TraktToken(access: a.access_token, renewal: a.refresh_token,
                          flow: beginning.addingTimeInterval(a.expires_in ?? 86_400))
    }
}

// MARK: - Device code

/// **Signing in without a browser in the app**: the way Trakt provides for TVs,
/// and it works the same on every device. The app shows a code and an address,
/// the user enters the code at Trakt on any device, and the app polls to see
/// whether it has been approved.
public struct TraktDevicesCode: Sendable, Equatable {
    /// Goes only back to Trakt, never on screen.
    public let devicesCode: String
    /// What the user types in.
    public let userCode: String
    /// Usually `https://trakt.tv/activate`.
    public let address: URL
    /// How long the code is valid, in seconds (ten minutes at Trakt).
    public let valid: TimeInterval
    /// How often to poll, in seconds.
    public let spacing: TimeInterval

    public init(devicesCode: String, userCode: String, address: URL,
                valid: TimeInterval, spacing: TimeInterval) {
        self.devicesCode = devicesCode
        self.userCode = userCode
        self.address = address
        self.valid = valid
        self.spacing = spacing
    }

    /// The address with the code in it, so nothing has to be typed on the phone.
    /// For the QR code on the TV and the button on iPhone and Mac.
    public var directAddress: URL { address.appendingPathComponent(userCode) }

    /// The address without `https://`, for typing.
    public var addressShort: String {
        var text = address.absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return text
    }

    static func from(_ data: Data) -> TraktDevicesCode? {
        struct Reply: Decodable {
            let device_code: String
            let user_code: String
            let verification_url: String
            let expires_in: Double
            let interval: Double
        }
        guard let a = try? JSONDecoder().decode(Reply.self, from: data),
              let url = URL(string: a.verification_url) else { return nil }
        return TraktDevicesCode(devicesCode: a.device_code, userCode: a.user_code,
                                address: url, valid: a.expires_in,
                                spacing: max(1, a.interval))
    }
}

/// What a poll of `/oauth/device/token` results in.
public enum TraktSharing: Sendable, Equatable {
    case granted(TraktToken)
    /// 400: the user has not entered the code yet.
    case pending
    /// 429: asked too often; the interval grows.
    case slower
    /// 404 or 410: code unknown or expired.
    case expired
    /// 409 or 418: already used or denied.
    case rejected

    static func from(status: Int, data: Data) -> TraktSharing {
        switch status {
        case 200:
            guard let token = TraktToken.from(data) else { return .pending }
            return .granted(token)
        case 404, 410: return .expired
        case 409, 418: return .rejected
        case 429:      return .slower
        // 400 means "not yet"; anything else is a hiccup, and the next tick asks
        // again anyway.
        default:       return .pending
        }
    }
}

public enum TraktError: Error, Equatable, Sendable {
    /// Unexpected response, with the HTTP status.
    case status(Int)
    /// 429. Trakt names in `Retry-After` how long to wait.
    case rateLimit(toSeconds: TimeInterval?)
    /// The refresh token is no longer valid; the user must connect again.
    case signedOut
    case codeExpired
    case rejected
    case unreadable
}

// MARK: - Which title

/// The ids through which Trakt finds a title.
///
/// **No matching of our own by name.** Jellyfin knows IMDb, TMDB and TVDB from
/// its metadata (`ProviderIds`), and Trakt accepts exactly those. A title
/// without any of them is not reported: better nothing than the wrong episode
/// in the history.
public struct TraktIds: Sendable, Equatable, Encodable {
    public var imdb: String?
    public var tmdb: Int?
    public var tvdb: Int?

    public init(imdb: String? = nil, tmdb: Int? = nil, tvdb: Int? = nil) {
        self.imdb = imdb
        self.tmdb = tmdb
        self.tvdb = tvdb
    }

    /// From Jellyfin's `ProviderIds`. The keys there are `Imdb`, `Tmdb`, `Tvdb`;
    /// capitalization varies between plugins, so it is ignored.
    public init(provider: [String: String]?) {
        var imdb: String?, tmdb: Int?, tvdb: Int?
        for (key, value) in provider ?? [:] {
            let w = value.trimmingCharacters(in: .whitespaces)
            switch key.lowercased() {
            // An IMDb id begins with "tt"; anything else is a plugin storing something of
            // its own there.
            case "imdb" where w.hasPrefix("tt"): imdb = w
            case "tmdb": tmdb = Int(w).flatMap { $0 > 0 ? $0 : nil }
            case "tvdb": tvdb = Int(w).flatMap { $0 > 0 ? $0 : nil }
            default: break
            }
        }
        self.init(imdb: imdb, tmdb: tmdb, tvdb: tvdb)
    }

    public var empty: Bool { imdb == nil && tmdb == nil && tvdb == nil }
}

/// What is reported to Trakt: a film or an episode.
public enum TraktTarget: Sendable, Equatable {
    case film(TraktIds)
    /// **The series plus season and number**, the way Plezy does it, and for the
    /// same reason: it works even when Trakt does not (yet) list the individual
    /// episode under its own id.
    case episode(series: TraktIds, season: Int, number: Int)
    /// Only if the series carries no id but the episode does.
    case episodeSelf(TraktIds)

    /// - Parameters:
    ///   - titel: the running title, fresh from the server (`Items/{id}` always
    ///     returns `ProviderIds`, list entries do not).
    ///   - serie: for an episode its series, otherwise `nil`.
    public static func from(title: Item, series: Item?) -> TraktTarget? {
        switch title.type {
        case "Movie":
            let k = TraktIds(provider: title.providerIds)
            return k.empty ? nil : .film(k)
        case "Episode":
            let s = TraktIds(provider: series?.providerIds)
            if !s.empty, let season = title.parentIndexNumber, let number = title.indexNumber {
                return .episode(series: s, season: season, number: number)
            }
            let own = TraktIds(provider: title.providerIds)
            return own.empty ? nil : .episodeSelf(own)
        default:
            // Music videos, live TV, home videos: Trakt does not know them.
            return nil
        }
    }

    /// The body for `/scrobble/*`. Progress in percent, 0 to 100.
    func shell(progress: Double) -> Data {
        struct IdWrapper: Encodable { let ids: TraktIds }
        struct EpisodeDetail: Encodable { let season: Int; let number: Int }
        struct BodyShell: Encodable {
            var movie: IdWrapper?
            var show: IdWrapper?
            var episode: EpisodesOrId?
            let progress: Double
        }
        enum EpisodesOrId: Encodable {
            case detail(EpisodeDetail)
            case identifier(IdWrapper)
            func encode(to encoder: any Encoder) throws {
                switch self {
                case let .detail(a): try a.encode(to: encoder)
                case let .identifier(k): try k.encode(to: encoder)
                }
            }
        }
        let p = (min(100, max(0, progress)) * 100).rounded() / 100
        var r = BodyShell(progress: p)
        switch self {
        case let .film(k):
            r.movie = IdWrapper(ids: k)
        case let .episode(series, season, number):
            r.show = IdWrapper(ids: series)
            r.episode = .detail(EpisodeDetail(season: season, number: number))
        case let .episodeSelf(k):
            r.episode = .identifier(IdWrapper(ids: k))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(r)) ?? Data()
    }
}

public extension TraktTarget {
    /// **Fetches what is missing for the matching**: the title fresh (with
    /// `ProviderIds`) and, for an episode, its series.
    ///
    /// Two requests to the own server when playback starts, no more. If one fails,
    /// there is simply no Trakt report; playback notices nothing.
    static func resolve(_ title: Item, client: JellyfinClient) async -> TraktTarget? {
        let freshValue = (title.providerIds == nil ? try? await client.item(id: title.id) : nil) ?? title
        var series: Item?
        if freshValue.type == "Episode", let id = freshValue.seriesId {
            series = try? await client.item(id: id)
        }
        return from(title: freshValue, series: series)
    }
}

// MARK: - The connection to Trakt

/// What a line returns: status, body and the one header line needed here.
public struct TraktResponse: Sendable {
    public let status: Int
    public let data: Data
    public let repeatTo: TimeInterval?

    public init(status: Int, data: Data = Data(), repeatTo: TimeInterval? = nil) {
        self.status = status
        self.data = data
        self.repeatTo = repeatTo
    }
}

/// The way to the network, replaceable: the tests plug in a stand-in and send
/// not a single real request to Trakt.
public typealias TraktConnection = @Sendable (URLRequest) async throws -> TraktResponse

public struct TraktClient: Sendable {
    public static let base = URL(string: "https://api.trakt.tv")!

    public let access: TraktAccess
    private let conduit: TraktConnection

    public init(access: TraktAccess, conduit: @escaping TraktConnection = TraktClient.network) {
        self.access = access
        self.conduit = conduit
    }

    /// **A short session of its own, not `localNetworkCapable`.** Trakt is on the
    /// internet; waiting for a local-network permission would make no sense, and a
    /// report that is not through after ten seconds is outdated anyway.
    public static let network: TraktConnection = { petition in
        let (data, answer) = try await session.data(for: petition)
        let http = answer as? HTTPURLResponse
        let to = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
        return TraktResponse(status: http?.statusCode ?? 0, data: data, repeatTo: to)
    }

    private static let session: URLSession = {
        let k = URLSessionConfiguration.ephemeral
        k.timeoutIntervalForRequest = 10
        k.timeoutIntervalForResource = 15
        return URLSession(configuration: k)
    }()

    // MARK: Signing in

    /// `POST /oauth/device/code`.
    public func devicesCode() async throws -> TraktDevicesCode {
        let a = try await dispatch("oauth/device/code", shell: ["client_id": access.clientID])
        guard a.status == 200 else { throw Self.error(a) }
        guard let code = TraktDevicesCode.from(a.data) else { throw TraktError.unreadable }
        return code
    }

    /// A single poll of `POST /oauth/device/token`.
    public func sharing(_ code: TraktDevicesCode) async -> TraktSharing {
        guard let a = try? await dispatch("oauth/device/token", shell: [
            "code": code.devicesCode,
            "client_id": access.clientID,
            "client_secret": access.secret,
        ]) else { return .pending }
        return TraktSharing.from(status: a.status, data: a.data)
    }

    /// **Polls until the code is approved.**
    ///
    /// Ends with the token, with ``TraktError/codeExpired`` or
    /// ``TraktError/abgelehnt``, or with `CancellationError` when the page is
    /// closed. `sleep` is replaceable only for the tests; the deadline counts the
    /// time slept, not the clock, so a test does not wait ten minutes.
    public func sharingWaitFor(
        _ code: TraktDevicesCode,
        sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) async throws -> TraktToken {
        var spacing = code.spacing
        var lapsed: TimeInterval = 0
        while lapsed < code.valid {
            try await sleep(spacing)
            lapsed += spacing
            try Task.checkCancellation()
            switch await sharing(code) {
            case let .granted(token): return token
            case .pending:         continue
            // RFC 8628: on "slow down" add five seconds, and permanently, not only for
            // the next attempt.
            case .slower:          spacing += 5
            case .expired:         throw TraktError.codeExpired
            case .rejected:          throw TraktError.rejected
            }
        }
        throw TraktError.codeExpired
    }

    /// `POST /oauth/token` with the refresh token.
    ///
    /// **400 and 401 mean: this access is dead.** On renewal Trakt issues a *new*
    /// refresh token; whoever sends the old one a second time, or whose app was
    /// disconnected, gets `invalid_grant`. Then only reconnecting helps; anything
    /// else (5xx, no connection) is temporary, and the old token stays.
    public func renew(_ token: TraktToken) async throws -> TraktToken {
        let a = try await dispatch("oauth/token", shell: [
            "refresh_token": token.renewal,
            "client_id": access.clientID,
            "client_secret": access.secret,
            "redirect_uri": "urn:ietf:wg:oauth:2.0:oob",
            "grant_type": "refresh_token",
        ])
        switch a.status {
        case 200:
            guard var new = TraktToken.from(a.data) else { throw TraktError.unreadable }
            new.user = token.user
            return new
        case 400, 401, 403: throw TraktError.signedOut
        default: throw Self.error(a)
        }
    }

    /// `POST /oauth/revoke` on disconnecting. If it fails, the token is gone here
    /// anyway; at Trakt it then expires after a day.
    public func revoked(_ token: TraktToken) async {
        _ = try? await dispatch("oauth/revoke", shell: [
            "token": token.access,
            "client_id": access.clientID,
            "client_secret": access.secret,
        ])
    }

    /// The name at Trakt, for "Verbunden als …". `GET /users/settings`.
    public func username(_ token: TraktToken) async -> String? {
        struct Reply: Decodable {
            struct AccountUser: Decodable { let username: String?; let name: String? }
            let user: AccountUser?
        }
        guard let a = try? await dispatch("users/settings", method: "GET", token: token.access),
              a.status == 200,
              let answer = try? JSONDecoder().decode(Reply.self, from: a.data) else { return nil }
        return answer.user?.username ?? answer.user?.name
    }

    // MARK: Reporting

    public enum Step: String, Sendable {
        case start, pause, stop
    }

    /// `POST /scrobble/{start|pause|stop}`.
    ///
    /// **409 is not an error.** Trakt answers that way when the same title was just
    /// reported, on the second stop or on a restart shortly after the end. It means
    /// "already done", and it is treated exactly that way.
    ///
    /// Trakt applies the rest of the rule itself: a stop at 80% or more marks the
    /// title as watched, below that it counts as paused.
    public func report(_ step: Step, target: TraktTarget, progress: Double,
                       token: String) async throws {
        let a = try await dispatch("scrobble/\(step.rawValue)", data: target.shell(progress: progress),
                                 token: token)
        switch a.status {
        case 200, 201, 409: return
        default: throw Self.error(a)
        }
    }

    // MARK: Internals

    private func dispatch(_ path: String, method: String = "POST", shell: [String: String]? = nil,
                        token: String? = nil) async throws -> TraktResponse {
        let data = try shell.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        return try await dispatch(path, method: method, data: data, token: token)
    }

    private func dispatch(_ path: String, method: String = "POST", data: Data?,
                        token: String? = nil) async throws -> TraktResponse {
        var petition = URLRequest(url: Self.base.appendingPathComponent(path))
        petition.httpMethod = method
        petition.httpBody = data
        petition.setValue("application/json", forHTTPHeaderField: "Content-Type")
        petition.setValue("2", forHTTPHeaderField: "trakt-api-version")
        petition.setValue(access.clientID, forHTTPHeaderField: "trakt-api-key")
        // Trakt sits behind Cloudflare, which occasionally rejects requests without
        // a sender.
        petition.setValue("Swiftly", forHTTPHeaderField: "User-Agent")
        if let token { petition.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try await conduit(petition)
    }

    static func error(_ a: TraktResponse) -> TraktError {
        a.status == 429 ? .rateLimit(toSeconds: a.repeatTo) : .status(a.status)
    }
}
