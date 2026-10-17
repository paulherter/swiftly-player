import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Jellyseerr and Overseerr: search for what the server does **not** have, and
/// request it.
///
/// **Why half the integration lives here and not in a view.** What a search hit
/// means, which state allows which action and how a response becomes an entry is the
/// same question on all six platforms, and testable without a simulator. The view
/// only decides how it looks.
///
/// **Sign-in goes through Jellyfin, not through an own account.** Seerr accepts the
/// same user name and password as the media server at `/api/v1/auth/jellyfin` and
/// creates a session for it, as a **cookie**, not as a token in a header. So
/// `SeerrAccess` holds a string that looks like a token and is not one.

/// How far a title has got at Seerr.
///
/// The numbers come from the API and read exactly like this:
/// `1 = UNKNOWN, 2 = PENDING, 3 = PROCESSING, 4 = PARTIALLY_AVAILABLE,
/// 5 = AVAILABLE, 6 = DELETED`. They are not renamed: anyone seeing them in the
/// log should recognise them in Seerr's own UI.
public enum SeerrState: Int, Codable, Sendable, Equatable {
    /// Nobody has requested it. The only state that deserves a button.
    case opened = 1
    case waitsSharing = 2
    case loads = 3
    case partWayPresent = 4
    case present = 5
    case deleted = 6

    /// May the user request here?
    ///
    /// **A state is not a button.** What is waiting or loading cannot be requested again;
    /// a button there would claim there is something to do. For `partWayPresent` it applies:
    /// seasons are missing there, and exactly those can be requested.
    public var requestable: Bool {
        switch self {
        case .opened, .deleted, .partWayPresent: true
        case .waitsSharing, .loads, .present: false
        }
    }

    /// Is the title already on the server? Then it belongs in the upper block, not the
    /// lower one.
    public var alreadyPresent: Bool { self == .present }
}

/// A Seerr hit: a title the own server does not (yet) have.
public struct SeerrHit: Sendable, Hashable, Identifiable, Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case art
        case title = "titel"
        case year = "jahr"
        case posterPath = "plakatPfad"
        case backdropPath = "kulissePfad"
        case state = "stand"
    }
    /// The TMDB identifier. Seerr takes it as `mediaId` when requesting.
    public let id: Int
    /// `movie` or `tv`. People are dropped when parsing.
    public let art: String
    public let title: String
    public let year: Int?
    public let posterPath: String?
    /// The **landscape image**, not the poster.
    ///
    /// TMDB delivers both separately, and the header of a detail page needs the landscape
    /// image: a stretched poster is too tall, pushes everything below it down and was
    /// never meant for this.
    public let backdropPath: String?
    public let state: SeerrState

    public var isSeries: Bool { art == "tv" }

    /// The image URL at TMDB.
    ///
    /// **Not from Seerr, but from TMDB.** Seerr only supplies the path; the user fetches
    /// the image directly, without going through the own server and without a token.
    /// `w342` is the smallest size that does not look soft on a poster in a grid.
    public func poster(width: Int = 342) -> URL? {
        Self.tmdb(posterPath, width: width)
    }

    /// The landscape image for the head of a page. **Only the landscape image**: if it is
    /// missing, nothing is returned instead of a stretched poster.
    public func backdrop(width: Int = 780) -> URL? {
        Self.tmdb(backdropPath, width: width)
    }

    private static func tmdb(_ path: String?, width: Int) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w\(width)\(path)")
    }
}


/// A person from the cast.
///
/// **Role, not profession.** Seerr lists the actors under `credits.cast` with their
/// character; the crew sits next to it and does not belong on a page where one
/// requests a title.
public struct SeerrPerson: Sendable, Hashable, Identifiable, Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case role = "rolle"
        case imagePath = "bildPfad"
    }
    public let id: Int
    public let name: String
    /// The character they play. May be missing.
    public let role: String?
    public let imagePath: String?

    /// The portrait at TMDB. `w185` is the smallest size that does not get soft in a
    /// 76-point circle.
    public func image(width: Int = 185) -> URL? {
        guard let imagePath, !imagePath.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w\(width)\(imagePath)")
    }
}

/// A season as Seerr knows it.
public struct SeerrSeason: Sendable, Hashable, Identifiable, Codable {
    enum CodingKeys: String, CodingKey {
        case number = "nummer"
        case episodes = "folgen"
        case state = "stand"
    }
    /// The number as it goes out again when requesting.
    public let number: Int
    public let episodes: Int
    /// What the own server already has of it.
    public let state: SeerrState

    public var id: Int { number }
    /// Season 0 is where TMDB collects specials.
    public var isSpecials: Bool { number == 0 }
}

/// What is on the page of a title that does not exist yet.
public struct SeerrDetail: Sendable, Equatable, Codable {
    enum CodingKeys: String, CodingKey {
        case description = "beschreibung"
        case genres
        case runtime = "laufzeit"
        case rating = "bewertung"
        case seasons = "staffeln"
        case cast = "besetzung"
        case similarOne = "aehnliches"
        case state = "stand"
    }
    public let description: String?
    /// At most two: more does not fit into a secondary line, and the third says nothing
    /// anyway.
    public let genres: [String]
    /// In minutes. For a series, the length of one episode.
    public let runtime: Int?
    public let rating: Double?
    public let seasons: [SeerrSeason]
    /// The cast, in the order in which Seerr delivers it, which is the order of
    /// importance, not alphabetical.
    public let cast: [SeerrPerson]
    /// What else Seerr suggests. **The same kind of hit as from search**, so the tile and
    /// the page behind it are the same.
    ///
    /// Comes from a **second** fetch, see ``Seerr/vorschlaege(aus:art:)``.
    public let similarOne: [SeerrHit]
    /// **The state of the whole title, fresh from the server.** The search hit only
    /// carries the state at the time of the search; after a request (which Seerr may
    /// approve at once) and on reopening, this one applies.
    /// `nil` if the response does not carry it; then the hit stays.
    public let state: SeerrState?

    /// The same information, only with the suggestions from the second fetch.
    public func with(similarOne new: [SeerrHit]) -> SeerrDetail {
        SeerrDetail(description: description, genres: genres, runtime: runtime,
                    rating: rating, seasons: seasons, cast: cast,
                    similarOne: new, state: state)
    }
}

/// Address and session. Held by the user, not here.
public struct SeerrAccess: Codable, Sendable, Equatable {
    public let address: URL
    /// The session cookie as it goes out again in the `Cookie` header.
    public let cookie: String
    /// Custom headers for a gateway in front of Seerr: Cloudflare Access,
    /// Authelia, Pangolin. **Empty for almost everyone.** They are stored with the cookie
    /// in the keychain because they are credentials just the same.
    public let headers: [OwnHeader]

    public init(address: URL, cookie: String, headers: [OwnHeader] = []) {
        self.address = address
        self.cookie = cookie
        self.headers = OwnHeaders.cleaned(headers)
    }

    private enum CodingKeys: String, CodingKey { case address = "adresse", cookie = "keks", headers = "koepfe" }

    /// **A stored credential from before has no `headers` field** and must still be
    /// readable. If reading failed, every existing user would be silently disconnected
    /// from Seerr; that has happened once already with storage.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = try c.decode(URL.self, forKey: .address)
        cookie = try c.decode(String.self, forKey: .cookie)
        headers = try c.decodeIfPresent([OwnHeader].self, forKey: .headers) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(address, forKey: .address)
        try c.encode(cookie, forKey: .cookie)
        // Empty is left out: a credential without headers looks as it always did.
        if !headers.isEmpty { try c.encode(headers, forKey: .headers) }
    }
}

/// The parts that can be tested without a network.
///
/// **Deliberately separate from the fetch.** What a response means is the question
/// everything depends on; whether the fetch gets through is up to the network. This
/// separation was missing in storage, and it cost every existing user their sign-in.
public enum Seerr {

    /// From Seerr's search response, the hits that matter here.
    ///
    /// **People are dropped.** The API includes them (`mediaType: person`), and an
    /// actor is nothing that can be requested. Entries without any title are dropped
    /// too.
    ///
    /// If `mediaInfo` is missing, nobody has ever asked for it: that is `opened`, not
    /// “unknown”. Seerr only creates the entry with the first request.
    public static func hit(fromSearch data: Data) -> [SeerrHit] {
        guard let a = try? JSONDecoder().decode(HitList.self, from: data) else { return [] }
        return hit(from: a.results, standardArt: nil)
    }

    /// The shape in which Seerr delivers hit lists, search as well as suggestions.
    /// **Described once, used twice.**
    struct HitList: Decodable {
        struct Record: Decodable {
            let id: Int
            let mediaType: String?
            let title: String?
            let name: String?
            let releaseDate: String?
            let firstAirDate: String?
            let posterPath: String?
            let backdropPath: String?
            let mediaInfo: Info?
            struct Info: Decodable { let status: Int? }
        }
        let results: [Record]
    }

    /// **`standardArt` is the difference between search and suggestion.**
    ///
    /// In search every entry says what it is, so the field *must* be read, otherwise an
    /// actor could not be told from a film. Under `recommendations` of a film page there
    /// are only films, and Seerr omits the field. Without this fallback no hit ever
    /// arrived there although the response was full.
    struct Filmography: Decodable { let cast: [HitList.Record]? }

    /// **Without duplicates.** A series appears in the filmography once per role, so
    /// someone who played two characters would appear twice.
    public static func hit(fromFilmography data: Data) -> [SeerrHit] {
        guard let f = try? JSONDecoder().decode(Filmography.self, from: data) else { return [] }
        var watched = Set<String>()
        return hit(from: f.cast ?? [], standardArt: nil)
            .filter { watched.insert("\($0.art)-\($0.id)").inserted }
    }

    static func hit(from entries: [HitList.Record],
                        standardArt: String?) -> [SeerrHit] {
        entries.compactMap { e in
            guard let art = e.mediaType ?? standardArt, art == "movie" || art == "tv" else { return nil }
            guard let title = e.title ?? e.name, !title.isEmpty else { return nil }
            let date = e.releaseDate ?? e.firstAirDate
            return SeerrHit(
                id: e.id,
                art: art,
                title: title,
                year: date.flatMap { Int($0.prefix(4)) },
                posterPath: e.posterPath,
                backdropPath: e.backdropPath,
                state: e.mediaInfo?.status.flatMap(SeerrState.init(rawValue:)) ?? .opened)
        }
    }

    /// From Seerr's detail response, what the page needs.
    ///
    /// **Season 0 is dropped.** TMDB keeps specials there; whoever requests “all
    /// seasons” does not mean them, and in a list to tick it sits at the very top where
    /// nobody expects it.
    ///
    /// If a season has no state, it is **open**, same reasoning as for the search hit:
    /// Seerr only creates the entry with the first request.
    public static func detail(from data: Data) -> SeerrDetail? {
        struct Reply: Decodable {
            struct Cast: Decodable {
                struct Header: Decodable {
                    let id: Int
                    let name: String?
                    let character: String?
                    let profilePath: String?
                }
                let cast: [Header]?
            }
            struct Season: Decodable {
                let seasonNumber: Int
                let episodeCount: Int?
                let mediaInfo: Info?
            }
            struct Info: Decodable { let status: Int? }
            struct Genre: Decodable { let name: String? }
            let overview: String?
            let genres: [Genre]?
            let runtime: Int?
            let episodeRunTime: [Int]?
            let voteAverage: Double?
            let seasons: [Season]?
            let credits: Cast?
            let mediaInfo: MediaInfo?
            struct MediaInfo: Decodable {
                let status: Int?
                struct SeasonState: Decodable { let seasonNumber: Int; let status: Int? }
                let seasons: [SeasonState]?
            }
        }
        guard let a = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }

        // The state per season is not on the season but in a second list next to it. Merge
        // first, then deliver.
        var states: [Int: SeerrState] = [:]
        for e in a.mediaInfo?.seasons ?? [] {
            if let s = e.status.flatMap(SeerrState.init(rawValue:)) { states[e.seasonNumber] = s }
        }
        let seasons = (a.seasons ?? [])
            .filter { $0.seasonNumber > 0 }
            .map { SeerrSeason(number: $0.seasonNumber,
                                episodes: $0.episodeCount ?? 0,
                                state: states[$0.seasonNumber] ?? .opened) }

        // **Without a name, it is not cast.** And nobody reads more than twenty heads: TMDB
        // lists over a hundred for big series, and each would be an image to fetch.
        let cast = (a.credits?.cast ?? []).compactMap { k -> SeerrPerson? in
            guard let name = k.name, !name.isEmpty else { return nil }
            return SeerrPerson(id: k.id, name: name,
                               role: (k.character?.isEmpty ?? true) ? nil : k.character,
                               imagePath: k.profilePath)
        }.prefix(20).map { $0 }

        let text = a.overview?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SeerrDetail(description: (text?.isEmpty ?? true) ? nil : text,
                           genres: (a.genres ?? []).compactMap(\.name).prefix(2).map { $0 },
                           runtime: a.runtime ?? a.episodeRunTime?.first,
                           rating: a.voteAverage,
                           seasons: seasons,
                           cast: cast,
                           // **Empty, and that is no oversight.** The suggestions come from a separate fetch;
                           // ``SeerrClient/detail(art:id:)`` adds them afterwards.
                           similarOne: [],
                           // If `mediaInfo` is missing, nobody has ever asked.
                           state: a.mediaInfo?.status.flatMap(SeerrState.init(rawValue:)) ?? .opened)
    }

    /// The suggestions for a title.
    ///
    /// **A separate fetch, not a field of the detail response.** Seerr includes
    /// `credits` in the detail response, but not the suggestions; those are under
    /// `/{art}/{id}/recommendations`. So the cast was there while “Similar” stayed empty,
    /// heading included, even for titles that have plenty.
    ///
    /// `art` is not decoration: in this response the entries carry **no** `mediaType`,
    /// since the page knows what it is. Without the fallback nothing would arrive even
    /// from a full response.
    public static func suggestions(from data: Data, art: String) -> [SeerrHit] {
        guard let a = try? JSONDecoder().decode(HitList.self, from: data) else { return [] }
        return hit(from: a.results, standardArt: art)
    }

    /// Get the session cookie from the response to the sign-in.
    ///
    /// **Seerr works with a session, not a token.** After `POST /api/v1/auth/jellyfin` it
    /// is in `Set-Cookie`, usually as `connect.sid`. Everything after the first semicolon
    /// is cut off: `Path`, `HttpOnly` and `Expires` belong to the browser, not to the app.
    ///
    /// Several cookies are joined with `, `; so each part is searched instead of hoping
    /// for a single one.
    public static func cookie(fromHeader setCookie: String) -> String? {
        for part in setCookie.split(separator: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard let same = piece.firstIndex(of: "="),
                  piece[..<same].contains("sid") else { continue }
            let until = piece.firstIndex(of: ";") ?? piece.endIndex
            let cookie = String(piece[..<until])
            if !cookie.hasSuffix("=") { return cookie }
        }
        return nil
    }

    /// Get the session cookie from the connection's cookie store.
    static func cookieOutCache(for address: URL, session: URLSession) -> String? {
        guard let cache = session.configuration.httpCookieStorage,
              let cookies = cache.cookies(for: address) else { return nil }
        guard let hit = cookies.first(where: { $0.name.contains("sid") && !$0.value.isEmpty })
        else { return nil }
        return "\(hit.name)=\(hit.value)"
    }

    /// On sign-out: remove the cookies of this address from the connection.
    ///
    /// **Otherwise the session stays alive where nobody can see it.** The stored
    /// credential is gone, the cookie in memory is not, and the next sign-in attempt
    /// therefore gets no new session.
    public static func cookiesForget(for address: URL,
                                      session: URLSession = .localNetworkCapable) {
        guard let cache = session.configuration.httpCookieStorage,
              let cookies = cache.cookies(for: address) else { return }
        for cookie in cookies { cache.deleteCookie(cookie) }
    }

    /// What goes to Seerr when requesting.
    ///
    /// **A movie has no seasons, and then the field must not be there.** Seerr takes
    /// either a list of numbers or the word `all`; an empty field has once been mistaken
    /// for “none at all”.
    public static func requestBody(art: String, id: Int, seasons: [Int]?) -> [String: Any] {
        var shell: [String: Any] = ["mediaType": art, "mediaId": id]
        if art == "tv", let seasons, !seasons.isEmpty {
            shell["seasons"] = seasons
        } else if art == "tv" {
            shell["seasons"] = "all"
        }
        return shell
    }

    /// Tidy the address before it is stored.
    ///
    /// The same care as for the Jellyfin server: the user types `seerr.example.de`,
    /// `https://seerr.example.de/` or with `/api/v1` at the end; the same thing is meant.
    public static func address(from typedInput: String) -> URL? {
        var text = typedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // **The same rule as for the media server, not a second one.** Whoever types
        // `192.168.1.9:5055` does not mean `https`: there is practically never a certificate,
        // and the sign-in would fail on something unrelated to Seerr.
        // `AppModelURLNormalizer.isHomeNetwork` answers that for the Jellyfin server;
        // writing it again here would be the copy that drifts apart.
        if !text.lowercased().hasPrefix("http") {
            text = (AppModelURLNormalizer.isHomeNetwork(text) ? "http://" : "https://") + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        for attachment in ["/api/v1", "/api"] where text.lowercased().hasSuffix(attachment) {
            text.removeLast(attachment.count)
        }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }

    /// The addresses that are tried, in this order.
    ///
    /// **Because guessing sometimes misses.** `address(aus:)` picks the scheme by the same
    /// rule as for the media server, which hits most cases. If it misses, sign-in ran into
    /// a timeout and the user had to type `https://` themselves.
    ///
    /// The media server has long had the second attempt
    /// (``AppModelURLNormalizer.reversed``); Seerr now gets it too.
    ///
    /// **Only if the scheme was guessed.** Whoever writes the scheme has decided, and then
    /// there is no fallback. That is also why the list is built here and not at the call
    /// site: only this function knows whether it guessed.
    public static func addresses(from typedInput: String) -> [URL] {
        guard let first = address(from: typedInput) else { return [] }
        let wasTapped = typedInput.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().hasPrefix("http")
        guard !wasTapped else { return [first] }
        var parts = URLComponents(url: first, resolvingAgainstBaseURL: false)
        parts?.scheme = first.scheme == "https" ? "http" : "https"
        guard let second = parts?.url else { return [first] }
        return [first, second]
    }
}

/// The fetch. Everything here depends on the network; what it **means** is above in
/// ``Seerr`` and tested without a network.
public actor SeerrClient {
    private let access: SeerrAccess

    /// The address this credential belongs to, needed for sign-out so that the cookies of
    /// the same address go with it. **`nonisolated`**, because `zugang` is a `let` of a
    /// `Sendable` and sign-out on Android comes from a non-async function that cannot
    /// wait.
    public nonisolated var address: URL { access.address }
    private let session: URLSession

    public init(access: SeerrAccess, session: URLSession = .localNetworkCapable) {
        self.access = access
        self.session = session
    }

    /// Sign in with the credentials of the **media server**.
    ///
    /// Seerr asks Jellyfin itself whether name and password are right and creates an own
    /// session for it. The cookie comes back and every further call carries it.
    ///
    /// `headers` go out with this very first request, since a gateway in front of Seerr
    /// would otherwise not let anything through to the sign-in.
    public static func signIn(an address: URL, user: String, password: String,
                                headers: [OwnHeader] = [],
                                session: URLSession = .localNetworkCapable) async throws -> SeerrAccess {
        var req = URLRequest(url: address.appendingPathComponent("api/v1/auth/jellyfin"))
        req.httpMethod = "POST"
        OwnHeaders.apply(headers, on: &req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["username": user, "password": password])
        // **No old cookie when signing in.** Seerr uses express-session: if a still valid
        // cookie of the connection is attached, the old session stays valid and the server
        // sends **no** `Set-Cookie`, so the sign-in looked like “Seerr did not return a
        // session” although it had succeeded. That is what happened after signing out in the
        // app: it only threw away the stored cookie, the one in the connection's cookie store
        // stayed, and afterwards no sign-in worked any more.
        req.httpShouldHandleCookies = false

        let (data, answer) = try await session.data(for: req)
        guard let http = answer as? HTTPURLResponse else {
            throw JellyfinError.transport("Keine Antwort von Seerr.")
        }
        // **Before any other interpretation.** A login page in front looked like “Seerr did
        // not return a session” (200 after redirect) or like a wrong password (403): both
        // misleading. Except for 404: there simply no Seerr answered, and a foreign web
        // server also sends its error page as HTML.
        if http.statusCode != 404, OwnHeaders.loginPage(http) {
            throw JellyfinError.transport(OwnHeaders.loginPageText)
        }
        switch http.statusCode {
        case 200, 201: break
        case 401, 403:
            throw JellyfinError.transport("Name oder Passwort stimmen nicht.")
        case 404:
            throw JellyfinError.transport("Unter dieser Adresse antwortet kein Seerr.")
        default:
            throw JellyfinError.http(status: http.statusCode,
                                     body: String(data: data.prefix(200), encoding: .utf8))
        }
        // **The cookie is the credential.** Without it the sign-in would have succeeded, but
        // the next call would face the same wall again.
        //
        // The fallback to the cookie store is the second half of the same case: if the
        // connection already swallowed the cookie (or a redirect sits in front), it is there
        // and no longer in the header. Throwing away a valid session just because it sits in
        // the other place would be the costlier mistake of the two.
        let cookie = http.value(forHTTPHeaderField: "Set-Cookie").flatMap(Seerr.cookie(fromHeader:))
            ?? Seerr.cookieOutCache(for: address, session: session)
        guard let cookie else {
            throw JellyfinError.transport("Seerr hat keine Sitzung mitgegeben.")
        }
        return SeerrAccess(address: address, cookie: cookie, headers: headers)
    }


    private func petition(_ path: String, method: String = "GET",
                         query: [URLQueryItem] = [], shell: Data? = nil) throws -> URLRequest {
        var parts = URLComponents(url: access.address.appendingPathComponent("api/v1/" + path),
                                  resolvingAgainstBaseURL: false)
        if !query.isEmpty { parts?.queryItems = query }
        guard let url = parts?.url else { throw JellyfinError.transport("Adresse unbrauchbar.") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        // The custom headers first: `Cookie` is blocked there, so the cookie stays the
        // app's own.
        OwnHeaders.apply(access.headers, on: &req)
        req.setValue(access.cookie, forHTTPHeaderField: "Cookie")
        // The cookie comes only from the app, not from the shared store (as when signing
        // in).
        req.httpShouldHandleCookies = false
        if let shell {
            req.httpBody = shell
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// Search. Errors are no reason to throw here: the Seerr hits are an extra on top of
    /// the own library, and if Seerr is silent, search should still show something.
    public func searching(_ term: String) async -> [SeerrHit] {
        guard let req = try? petition("search", query: [.init(name: "query", value: term)]),
              let (data, answer) = try? await session.data(for: req),
              let http = answer as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        return Seerr.hit(fromSearch: data)
    }

    /// Request. This one does throw: the user pressed a button and must learn whether it
    /// worked.
    public func askFor(art: String, id: Int, seasons: [Int]? = nil) async throws {
        let shell = try JSONSerialization.data(
            withJSONObject: Seerr.requestBody(art: art, id: id, seasons: seasons))
        let req = try petition("request", method: "POST", shell: shell)
        let (data, answer) = try await session.data(for: req)
        guard let http = answer as? HTTPURLResponse else {
            throw JellyfinError.transport("Keine Antwort von Seerr.")
        }
        switch http.statusCode {
        case 200, 201: return
        case 401, 403:
            throw JellyfinError.transport("Deine Seerr-Anmeldung gilt nicht mehr.")
        case 409:
            // Not an error: someone was faster. The state says so on the next load by itself.
            return
        default:
            throw JellyfinError.http(status: http.statusCode,
                                     body: String(data: data.prefix(200), encoding: .utf8))
        }
    }

    /// Description, rating and seasons for a hit.
    ///
    /// If nothing comes, the page stays with what the search hit already carries; an empty
    /// description is better than an error message for something that only decorates.
    public func detail(art: String, id: Int) async -> SeerrDetail? {
        // **Two fetches, side by side.** The suggestions are not in the detail response but
        // under a path of their own. Sequentially, that would be two waits for one page.
        async let main = hole("\(art)/\(id)")
        async let preHit = hole("\(art)/\(id)/recommendations")
        let (a, b) = await (main, preHit)

        guard let a, let inquiry = Seerr.detail(from: a) else { return nil }
        // **If no suggestions come, the page still stands.** They are an extra; an error there
        // must not cost the description.
        guard let b else { return inquiry }
        return inquiry.with(similarOne: Seerr.suggestions(from: b, art: art))
    }

    /// A GET that returns nothing for anything but a 200.
    /// **What a person has done**, as far as Seerr knows, for “Can be requested” on their
    /// page. Without throwing: this is an extra, an error here must not cost the page.
    public func filmography(person tmdb: Int) async -> [SeerrHit] {
        guard let data = await hole("person/\(tmdb)/combined_credits") else { return [] }
        return Seerr.hit(fromFilmography: data)
    }

    private func hole(_ path: String) async -> Data? {
        guard let req = try? petition(path),
              let (data, answer) = try? await session.data(for: req),
              let http = answer as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    /// Whether the stored session is still valid.
    public func applies() async -> Bool {
        guard let req = try? petition("auth/me"),
              let (_, answer) = try? await session.data(for: req),
              let http = answer as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}
