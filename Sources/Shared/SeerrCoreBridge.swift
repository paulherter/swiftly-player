import Foundation
import JellyfinKit
import SwiftlyCore

/// The core's Seerr (`SeerrModel`: search, detail, request, filmography, session check, sign-in)
/// behind the types the views already use. The views keep `JellyfinKit.SeerrHit` and friends; the
/// conversions are one-to-one (same fields, same state numbers).
enum SeerrCore {

    /// A failure whose text the core already worded; shown as it is.
    struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    typealias Client = SwiftlyCore.SeerrModel

    /// Requests a title; throws the core's German text.
    static func askFor(_ client: Client, art: String, id: Int, seasons: [Int]?) async throws {
        do {
            try await client.askFor(art: art, id: Int64(id), seasons: seasons?.map(Int64.init))
        } catch SwiftlyCore.CoreError.Failed(let message) {
            throw Failure(text: message)
        }
    }

    static func cookiesForget(for address: URL) {
        HTTPCookieSeerrJar().forget(address: address.absoluteString)
    }

    @MainActor
    static func model(_ access: JellyfinKit.SeerrAccess) -> SwiftlyCore.SeerrModel {
        AppCore.shared.raw.seerrModel(connection: connection(access), jar: HTTPCookieSeerrJar())
    }

    /// Signs in with the media server's user. The core tries the typed address with the schemes and ports
    /// of the old `Seerr.addresses` and keeps the first failure when the second only trips over the scheme.
    @MainActor
    static func signIn(typed: String, user: String, password: String,
                       headers: [JellyfinKit.OwnHeader]) async throws -> JellyfinKit.SeerrAccess {
        let made: SwiftlyCore.SeerrConnection
        do {
            made = try await AppCore.shared.raw.seerrSignIn(
                typed: typed, user: user, password: password,
                headers: headers.map { SwiftlyCore.OwnHeader(name: $0.name, value: $0.value) },
                jar: HTTPCookieSeerrJar())
        } catch SwiftlyCore.CoreError.Failed(let message) {
            throw Failure(text: message)
        }
        guard let url = URL(string: made.address) else { throw Failure(text: "") }
        return JellyfinKit.SeerrAccess(
            address: url, cookie: made.cookie,
            headers: made.headers.map { JellyfinKit.OwnHeader(name: $0.name, value: $0.value) })
    }

    /// The core's sign-in and setup screen (`SeerrSetupFlow` drives it): one state, three ways in, the address asked
    /// once per server of the admin only, every sentence worded by the core.
    @MainActor
    static func setup() -> SwiftlyCore.SeerrSetupScreen {
        AppCore.shared.raw.seerrSetup(locale: AppCore.language, jar: HTTPCookieSeerrJar())
    }

    /// The session the core hands back after a sign-in, as the stored connection.
    static func access(_ made: SwiftlyCore.SeerrConnection) -> JellyfinKit.SeerrAccess? {
        guard let url = URL(string: made.address) else { return nil }
        return JellyfinKit.SeerrAccess(
            address: url, cookie: made.cookie,
            headers: made.headers.map { JellyfinKit.OwnHeader(name: $0.name, value: $0.value) })
    }

    /// What the automatic sign-in ended in, for the model (`SeerrAutoState` without its core types).
    enum Auto: Equatable {
        case notConfigured
        case signedIn(JellyfinKit.SeerrAccess)
        case noPassword
        case rejected(String)
        case unreachable
    }

    /// Keeps a valid stored session, else signs in again with the media server's own account; the password
    /// comes from `secret` (the Keychain) and is never logged. Does not throw: every outcome is one `Auto`.
    @MainActor
    static func autoSignIn(stored: JellyfinKit.SeerrAccess, user: String, secret: any SwiftlyCore.SeerrPasswordSource,
                           headers: [JellyfinKit.OwnHeader]) async -> Auto {
        let state: SwiftlyCore.SeerrAutoState
        do {
            state = try await AppCore.shared.raw.seerrAutoSignIn(
                typed: stored.address.absoluteString, user: user, stored: connection(stored), secret: secret,
                headers: headers.map { SwiftlyCore.OwnHeader(name: $0.name, value: $0.value) },
                jar: HTTPCookieSeerrJar())
        } catch {
            return .unreachable
        }
        return auto(state)
    }

    static func auto(_ state: SwiftlyCore.SeerrAutoState) -> Auto {
        switch state {
        case .notConfigured: .notConfigured
        case .noPassword: .noPassword
        case .rejected(let message): .rejected(message)
        case .unreachable: .unreachable
        case .signedIn(let made):
            if let url = URL(string: made.address) {
                .signedIn(JellyfinKit.SeerrAccess(
                    address: url, cookie: made.cookie,
                    headers: made.headers.map { JellyfinKit.OwnHeader(name: $0.name, value: $0.value) }))
            } else { .unreachable }
        }
    }

    static func connection(_ a: JellyfinKit.SeerrAccess) -> SwiftlyCore.SeerrConnection {
        SwiftlyCore.SeerrConnection(
            address: a.address.absoluteString, cookie: a.cookie,
            headers: a.headers.map { SwiftlyCore.OwnHeader(name: $0.name, value: $0.value) })
    }

    // MARK: Types

    static func state(_ s: SwiftlyCore.SeerrState) -> JellyfinKit.SeerrState {
        switch s {
        case .opened: .opened
        case .waitsSharing: .waitsSharing
        case .loads: .loads
        case .partWayPresent: .partWayPresent
        case .present: .present
        case .blocklisted: .blocklisted
        case .deleted: .deleted
        }
    }

    static func hit(_ h: SwiftlyCore.SeerrHit) -> JellyfinKit.SeerrHit {
        JellyfinKit.SeerrHit(
            id: Int(h.id), art: h.art, title: h.title, year: h.year.map(Int.init),
            posterPath: h.posterPath, backdropPath: h.backdropPath, state: state(h.state))
    }

    static func detail(_ d: SwiftlyCore.SeerrDetail) -> JellyfinKit.SeerrDetail {
        JellyfinKit.SeerrDetail(
            description: d.description, genres: d.genres, runtime: d.runtime.map(Int.init), rating: d.rating,
            seasons: d.seasons.map {
                JellyfinKit.SeerrSeason(number: Int($0.number), episodes: Int($0.episodes), state: state($0.state))
            },
            cast: d.cast.map {
                JellyfinKit.SeerrPerson(id: Int($0.id), name: $0.name, role: $0.role, imagePath: $0.imagePath)
            },
            similarOne: d.similarOne.map(hit), state: d.state.map(state))
    }

    static func session(_ s: SwiftlyCore.SeerrSessionState) -> JellyfinKit.SeerrSessionState {
        switch s {
        case .valid: .valid
        case .invalid: .invalid
        case .unreachable: .unreachable
        }
    }
}


/// The Jellyfin account's password for the automatic Seerr sign-in, read from the Keychain only when a
/// sign-in is needed. Kept per server next to the Seerr entry; never logged.
final class KeychainSeerrPassword: SwiftlyCore.SeerrPasswordSource, @unchecked Sendable {
    private let key: String
    init(key: String) { self.key = key }
    func password() -> String? {
        Keychain.load(key: key).flatMap { String(data: $0, encoding: .utf8) }
    }
}
