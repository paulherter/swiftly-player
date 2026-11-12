import Foundation
import Observation

/// `DateText` over `DateFormatter`: the long date of an ISO timestamp in the device's language.
public final class LongDateText: DateText {
    private let locale: Locale
    public init(locale: Locale = .current) { self.locale = locale }

    public func longDate(iso: String) -> String? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        let out = DateFormatter()
        out.locale = locale
        out.dateStyle = .long
        out.timeStyle = .none
        return out.string(from: date)
    }
}

/// The `@MainActor @Observable` adapter of `PersonModel` (the page of a cast entry).
@MainActor
@Observable
public final class PersonController {
    public private(set) var page: PersonPage
    @ObservationIgnored private let model: PersonModel

    public init(model: PersonModel) {
        self.model = model
        self.page = model.pageNow()
    }

    /// Details and the first page of the filmography.
    public func load(dates: any DateText = LongDateText()) async throws {
        page = try await model.load(dates: dates)
    }

    /// The Seerr titles of the person, once the details are in.
    public func loadSeerr(_ seerr: SeerrModel?) async throws {
        page = try await model.loadSeerr(seerr: seerr)
    }

    /// A title came into view; the end of the list loads the next page.
    public func titleVisible(_ id: String) async throws {
        page = try await model.titleVisible(id: id)
    }

    public func toggleBiography() { page = model.toggleBiography() }
}

/// The `@MainActor @Observable` adapter of `PlaylistModel`.
@MainActor
@Observable
public final class PlaylistController {
    public private(set) var page: PlaylistPage
    @ObservationIgnored private let model: PlaylistModel

    public init(model: PlaylistModel) {
        self.model = model
        self.page = model.pageNow()
    }

    public func load() async throws { page = try await model.load() }

    /// "Play": the first shown entry.
    public func start() -> Tile? { model.start() }
}

/// `SeerrCookieJar` over `HTTPCookieStorage`: the platform's cookies of the Seerr address.
public final class HTTPCookieSeerrJar: SeerrCookieJar {
    private nonisolated(unsafe) let storage: HTTPCookieStorage
    public init(storage: HTTPCookieStorage = .shared) { self.storage = storage }

    public func sessionCookie(address: String) -> String? {
        guard let url = URL(string: address), let cookie = storage.cookies(for: url)?.first else { return nil }
        return "\(cookie.name)=\(cookie.value)"
    }

    public func forget(address: String) {
        guard let url = URL(string: address) else { return }
        for cookie in storage.cookies(for: url) ?? [] { storage.deleteCookie(cookie) }
    }
}

/// The `@MainActor @Observable` adapter of `SeerrModel`: the last search and the session state are
/// properties, the calls are plain async helpers.
@MainActor
@Observable
public final class SeerrController {
    public private(set) var hits: [SeerrHit] = []
    public private(set) var session: SeerrSessionState?

    @ObservationIgnored public let model: SeerrModel

    public init(model: SeerrModel) { self.model = model }

    public var address: String { model.address() }

    /// Signs in to a Seerr with the media server's user; the connection is what the host stores.
    public static func signIn(
        core: Core, typed: String, user: String, password: String, headers: [OwnHeader] = [],
        jar: (any SeerrCookieJar)? = HTTPCookieSeerrJar()
    ) async throws -> SeerrConnection {
        try await core.seerrSignIn(typed: typed, user: user, password: password, headers: headers, jar: jar)
    }

    public func search(_ term: String) async throws {
        hits = try await model.search(term: term)
    }

    public func detail(art: String, id: Int64) async throws -> SeerrDetail? {
        try await model.detail(art: art, id: id)
    }

    public func askFor(art: String, id: Int64, seasons: [Int64]? = nil) async throws {
        try await model.askFor(art: art, id: id, seasons: seasons)
    }

    public func filmography(personTmdb: Int64) async throws -> [SeerrHit] {
        try await model.filmography(personTmdb: personTmdb)
    }

    public func checkSession() async throws {
        session = try await model.applies()
    }

    public func forgetCookies() { model.forgetCookies() }
}

/// The `@MainActor @Observable` adapter of `SettingsSyncModel`: one run per call; the outcome stays readable.
@MainActor
@Observable
public final class SettingsSyncController {
    public private(set) var lastOutcome: SettingsSyncOutcome?
    @ObservationIgnored private let model: SettingsSyncModel

    public init(model: SettingsSyncModel) { self.model = model }

    /// The names that are synced, and whether each is kept per server.
    public static var entries: [SyncEntry] { settingsSyncEntries() }

    /// `localChanged`: when the local values last changed (`nil` = never synced).
    @discardableResult
    public func run(
        local: [SyncSetting], localChanged: Double?, otherAccount: Bool, now: Double = Date().timeIntervalSince1970
    ) async throws -> SettingsSyncOutcome {
        let outcome = try await model.run(local: local, localChanged: localChanged, otherAccount: otherAccount, now: now)
        lastOutcome = outcome
        return outcome
    }
}
