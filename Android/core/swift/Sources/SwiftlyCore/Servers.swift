import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JellyfinKit

// MARK: - Signing in at Emby and Plex
//
// **What the finished pages call, and the network work behind it** (`AppModel+Servers.swift` on
// Apple). The Compose pages only hold what the screen shows; every step that talks to a server
// is here, and every answer is a finished JSON text. The result of both flows is one `Session`
// of the right kind, which Kotlin hands to the account bundle like any other.
//
// **Plex is a sequence of short calls, not a task that runs on its own:** Kotlin asks
// ``plexPoll()`` about once a second. That keeps all timing in one place (the page) and leaves
// nothing in the core that could outlive it.

/// An account the Emby server offers on its sign-in page.
struct EmbyUserResponse: Encodable {
    let id, name: String
    let image: String?
}

/// `result`: `ok`, `unreachable`, `badAddress`, `notEmby` (`found` names what answered), `other` (`message`).
struct EmbyCheckResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case result, name, version, address = "adresse", users = "konten", found, message
    }
    var result: String
    var name = "", version = "", address = ""
    var users: [EmbyUserResponse] = []
    var found: String?
    var message: String?
}

struct PlexProfileResponse: Encodable {
    let id, name: String
    let image: String?
    let protected: Bool
}

struct PlexServerChoiceResponse: Encodable {
    let id, name: String
    /// `nil`: the account's own server; otherwise the name of whoever shared it (empty when unknown).
    let sharedBy: String?
    let local, online: Bool
}

/// One answer for every step of the Plex flow. `step`: `waiting`, `profiles`, `servers`,
/// `pinWrong`, `unreachable`, `expired`, `plexUnreachable`, `failed` (`message`), `done` (`session`).
struct PlexStepResponse: Encodable {
    var step: String
    var secondsLeft: Int?
    var account: String?
    /// The Plex Home profile chosen before the servers, if there was a choice.
    var profile: String?
    var profiles: [PlexProfileResponse]?
    var servers: [PlexServerChoiceResponse]?
    var message: String?
    var session: String?
    var url: String?
    /// The short code of the TV sign-in (`plexStartTv`); `nil` for the browser way.
    var code: String?
}

/// What the flow holds between its steps.
final class PlexHeld: @unchecked Sendable {
    let lock = NSLock()
    var pin: PlexPin?
    var expires = Date.distantFuture
    var handled = false
    var failures = 0
    var accountToken: String?
    var accountUserID = ""
    var accountName = ""
    var accountThumb: String?
    var homeUsers: [PlexHomeUser] = []
    var profile: PlexHomeUser?
    var profileChosen: String?
    var profileToken: String?
    var servers: [PlexServerResource] = []
    var connecting = false
}

extension Kern {

    // MARK: Emby

    /// Checks the address as an Emby server and fetches the accounts it offers on its sign-in page.
    /// The checked server waits as ``_onboarding``; ``embySignIn(user:password:)`` uses it.
    public func embyCheck(address raw: String, headers: String) async -> String {
        guard let url = AppModelURLNormalizer.normalize(raw) else {
            return Self.encoded(EmbyCheckResponse(result: "badAddress"))
        }
        var candidates = [url]
        if !raw.contains("://"), let different = AppModelURLNormalizer.reversed(url) { candidates.append(different) }
        let ownOnes = Self.headersRead(headers)
        let mark = checkBegin(raw)
        defer { checkComplete(mark) }
        var lastError: (any Error)?
        for candidate in candidates {
            let c = newClient(candidate, kind: .emby)
            let info: PublicSystemInfo
            do {
                info = try await Self.withHeaders(ownOnes, for: candidate) { try await c.checkReachability() }
            } catch {
                lastError = error
                if !AddressCheck.fallbackPaysOff(to: error) { break }
                continue
            }
            guard checkApplies(mark) else { return Self.encoded(EmbyCheckResponse(result: "other")) }
            // Emby and Jellyfin answer the same route and look alike from outside.
            if info.looksLikeJellyfin {
                return Self.encoded(EmbyCheckResponse(result: "notEmby", address: candidate.absoluteString,
                                                      found: "Jellyfin"))
            }
            barrier.lock(); _onboarding = c; barrier.unlock()
            var users: [EmbyUserResponse] = []
            if let source = c as? any QuickSignIn, c.capabilities.contains(.publicUsers),
               let found = try? await source.publicUser() {
                for u in found {
                    users.append(EmbyUserResponse(id: u.id, name: u.name,
                                                  image: await source.userImage(u, border: 180)?.absoluteString))
                }
            }
            return Self.encoded(EmbyCheckResponse(result: "ok",
                name: info.serverName ?? candidate.host() ?? "", version: info.version ?? "?",
                address: candidate.absoluteString, users: users))
        }
        if let j = lastError as? JellyfinError, case let .transport(text) = j, text == OwnHeaders.loginPageText {
            return Self.encoded(EmbyCheckResponse(result: "other", message: text))
        }
        return Self.encoded(EmbyCheckResponse(result: "unreachable", address: raw))
    }

    /// Signs in at the checked Emby server. The session comes back; the account is only in once
    /// Kotlin has recorded it.
    public func embySignIn(user: String, password: String) async throws -> String {
        try await throwReadable { () async throws -> String in
            barrier.lock(); let c = _onboarding; barrier.unlock()
            guard let c, c.kind == .emby else { throw CoreError.notConnected }
            return try json(try await c.authenticate(username: user, password: password))
        }
    }

    // MARK: Plex: browser sign-in

    private var plexService: PlexAccountService {
        PlexAccountService(identity: .thisDevice(clientID: devicesIdentifier, deviceName: devicesName,
                                                 version: version))
    }

    private func plexHeldGet() -> PlexHeld {
        barrier.lock(); defer { barrier.unlock() }
        if let h = _plexHeld { return h }
        let h = PlexHeld(); _plexHeld = h; return h
    }

    /// Fetches the PIN and the page to open in the browser (Custom Tab).
    public func plexStart() async -> String { await plexBegin(strong: true) }

    /// The TV has no browser (`#if os(tvOS)` in `AppModel+Servers`): a short code the person types at
    /// plex.tv/link on another device. The answer carries that page as `url` and the code as `code`.
    public func plexStartTv() async -> String { await plexBegin(strong: false) }

    private func plexBegin(strong: Bool) async -> String {
        plexReset()
        let held = plexHeldGet()
        do {
            let service = plexService
            let pin = try await service.startPin(strong: strong)
            let url: URL
            if strong {
                guard let auth = service.authURL(for: pin) else { throw PlexError.pinExpired }
                url = auth
            } else {
                url = service.linkPage
            }
            held.lock.lock()
            held.pin = pin
            held.expires = Date().addingTimeInterval(TimeInterval(pin.expiresIn ?? 900))
            held.lock.unlock()
            return Self.encoded(PlexStepResponse(step: "waiting", secondsLeft: Int(pin.expiresIn ?? 900),
                                                 url: url.absoluteString, code: strong ? nil : pin.code))
        } catch {
            return plexFail(error)
        }
    }

    /// One look at plex.tv. Waiting: `waiting` with the seconds left. Once the token is there,
    /// this goes on to the profiles or the servers by itself, so the answer is that step.
    public func plexPoll() async -> String {
        let held = plexHeldGet()
        held.lock.lock()
        let pin = held.pin, handled = held.handled, expires = held.expires
        held.lock.unlock()
        guard let pin, !handled else { return Self.encoded(PlexStepResponse(step: "waiting", secondsLeft: 0)) }
        if Date() >= expires { return Self.encoded(PlexStepResponse(step: "expired")) }
        do {
            let checked = try await plexService.checkPin(pin)
            held.lock.lock(); held.failures = 0; held.lock.unlock()
            if let token = checked.authToken, !token.isEmpty { return await plexSignedIn(token: token) }
        } catch JellyfinError.http(let status, _) where status == 404 || status == 410 {
            return Self.encoded(PlexStepResponse(step: "expired"))
        } catch {
            held.lock.lock(); held.failures += 1; let many = held.failures >= 5; held.lock.unlock()
            if many { return plexFail(error) }
        }
        return Self.encoded(PlexStepResponse(
            step: "waiting", secondsLeft: max(Int(expires.timeIntervalSinceNow.rounded(.up)), 0)))
    }

    private func plexSignedIn(token: String) async -> String {
        let held = plexHeldGet()
        // The timer and a closing browser window can both see the token; one wins.
        held.lock.lock()
        if held.handled { held.lock.unlock(); return Self.encoded(PlexStepResponse(step: "waiting")) }
        held.handled = true
        held.lock.unlock()
        let service = plexService
        do {
            guard case .valid(let account) = try await service.validate(token: token) else { throw PlexError.pinExpired }
            let users = (try? await service.homeUsers(token: token)) ?? []
            held.lock.lock()
            held.accountToken = token
            held.accountUserID = account.id
            held.accountName = account.title
            held.accountThumb = account.thumb
            held.homeUsers = users
            if users.count <= 1 { held.profile = users.first; held.profileToken = token }
            held.lock.unlock()
            if users.count > 1 {
                return Self.encoded(PlexStepResponse(step: "profiles", account: account.title,
                                                     profiles: users.map(Self.profileChoice)))
            }
            return await plexServers()
        } catch {
            return plexFail(error)
        }
    }

    private static func profileChoice(_ u: PlexHomeUser) -> PlexProfileResponse {
        PlexProfileResponse(id: u.uuid, name: u.title, image: u.thumb, protected: u.isProtected)
    }

    /// The browser window closed unfinished or finished: look right now.
    public func plexBrowserClosed() async -> String { await plexPoll() }

    // MARK: Plex: profile and server

    /// A Plex Home profile; `pin` empty for an unprotected one. A wrong PIN answers `pinWrong`.
    public func plexPickProfile(id: String, pin: String) async -> String {
        let held = plexHeldGet()
        held.lock.lock()
        let user = held.homeUsers.first { $0.uuid == id }
        let account = held.accountToken
        held.lock.unlock()
        guard let user, let account else { return Self.encoded(PlexStepResponse(step: "failed")) }
        do {
            let token = try await plexService.switchUser(user, pin: pin.isEmpty ? nil : pin, token: account)
            held.lock.lock(); held.profile = user; held.profileChosen = user.title; held.profileToken = token; held.lock.unlock()
            return await plexServers()
        } catch PlexError.profilePinWrong {
            // A wrong PIN stays on the PIN page; an unprotected profile that is refused has
            // nothing to retry, so it goes back to the list.
            return pin.isEmpty ? plexFail(PlexError.profilePinWrong) : Self.encoded(PlexStepResponse(step: "pinWrong"))
        } catch {
            return plexFail(error)
        }
    }

    /// The account's servers (asks plex.tv again on every call).
    public func plexServers() async -> String {
        let held = plexHeldGet()
        held.lock.lock()
        let token = held.profileToken ?? held.accountToken
        let account = held.accountName, chosen = held.profileChosen
        held.lock.unlock()
        guard let token else { return Self.encoded(PlexStepResponse(step: "failed")) }
        do {
            let found = try await plexService.servers(token: token)
            held.lock.lock(); held.servers = found; held.lock.unlock()
            return Self.encoded(PlexStepResponse(step: "servers", account: account, profile: chosen, servers: found.map {
                PlexServerChoiceResponse(
                    id: $0.machineIdentifier, name: $0.name,
                    sharedBy: $0.owned ? nil : ($0.sourceTitle ?? ""),
                    local: $0.connections.contains { $0.isLocal }, online: $0.presence)
            }))
        } catch {
            return plexFail(error)
        }
    }

    /// Connects to the server (the best address that answers) and returns the new session as
    /// `done`. Nothing answering: `unreachable`.
    public func plexPickServer(id: String) async -> String {
        let held = plexHeldGet()
        held.lock.lock()
        let server = held.servers.first { $0.machineIdentifier == id }
        let accountToken = held.accountToken
        let busy = held.connecting
        if server != nil, !busy { held.connecting = true }
        held.lock.unlock()
        guard let server, let accountToken, !busy else { return Self.encoded(PlexStepResponse(step: "failed")) }
        defer { held.lock.lock(); held.connecting = false; held.lock.unlock() }
        held.lock.lock()
        let profileToken = held.profileToken ?? accountToken
        let user = held.profile
        let userID = held.accountUserID, userName = held.accountName, thumb = held.accountThumb
        held.lock.unlock()
        let service = plexService
        // The server's own token is the one that opens it; the profile's token asks plex.tv.
        let key = server.accessToken ?? profileToken
        let connector = PlexConnector(identity: service.identity, token: key,
                                      machineIdentifier: server.machineIdentifier)
        do {
            let connection = try await Self.plexConnect(connector, to: server)
            let s = Session(plexServer: server, connection: connection, accountToken: profileToken,
                            userID: user?.id ?? userID, userName: user?.title ?? userName,
                            homeUserUUID: user?.uuid,
                            userImage: (user?.thumb ?? thumb).flatMap(URL.init(string:)))
            return Self.encoded(PlexStepResponse(step: "done", session: try json(s)))
        } catch {
            return Self.encoded(PlexStepResponse(step: "unreachable"))
        }
    }

    /// One try; when it failed at once (a refused local-network question) a second after a
    /// moment. A server that is really gone fails slowly and is not asked twice.
    private static func plexConnect(_ connector: PlexConnector,
                                    to server: PlexServerResource) async throws -> PlexChosenConnection {
        let started = ContinuousClock.now
        do {
            return try await connector.choose(from: server)
        } catch {
            guard ContinuousClock.now - started < .seconds(2) else { throw error }
            try await Task.sleep(for: .seconds(1.5))
            return try await connector.choose(from: server)
        }
    }

    /// Forgets everything the flow holds: the arrow at the top, or "another account".
    public func plexReset() {
        barrier.lock(); _plexHeld = nil; barrier.unlock()
    }

    // MARK: Plex: errors

    /// The sentences: plex.tv gone, code expired, anything else with its own words.
    private func plexFail(_ error: any Error) -> String {
        if let plex = error as? PlexError {
            switch plex {
            case .pinExpired: return Self.encoded(PlexStepResponse(step: "expired"))
            case .noServer: return Self.encoded(PlexStepResponse(step: "servers", servers: []))
            default: return Self.encoded(PlexStepResponse(step: "failed", message: coreErrorText(error)))
            }
        }
        if error is URLError { return Self.encoded(PlexStepResponse(step: "plexUnreachable")) }
        if let j = error as? JellyfinError, case .transport = j {
            return Self.encoded(PlexStepResponse(step: "plexUnreachable"))
        }
        return Self.encoded(PlexStepResponse(step: "failed", message: coreErrorText(error)))
    }

    // MARK: Plex: during the session

    /// Called from ``setDown``: a Plex server moves between addresses with the network, and its
    /// token can run out in the middle of a session. Both are kept for ``sessionEvents()``.
    func plexWatch(_ plex: PlexClient) {
        Task { [weak self] in
            await plex.onSessionChange { moved in
                self?.barrier.lock()
                if self?._client === plex, self?._session?.accountKey == moved.accountKey {
                    self?._plexMoved = moved
                    self?._session = moved
                }
                self?.barrier.unlock()
            }
            await plex.onUnauthorized {
                self?.barrier.lock()
                if self?._client === plex { self?._plexRejected = true }
                self?.barrier.unlock()
            }
        }
    }

    /// What happened to the connected server since the last call, for Kotlin to act on:
    /// `moved` (a session JSON to store, the server's address changed) and `revoked` (the
    /// server no longer accepts the token: sign out, then "please sign in again"). A single
    /// title can answer `401` too, so the token is asked once before it counts.
    public func sessionEvents() async -> String {
        barrier.lock()
        let moved = _plexMoved; _plexMoved = nil
        let rejected = _plexRejected; _plexRejected = false
        let c = _client
        barrier.unlock()
        var revoked = false
        if rejected, let plex = c as? PlexClient {
            if await plex.sessionAppliesStill() { await plex.unauthorizedHandled() } else { revoked = true }
        }
        struct Events: Encodable { let moved: String; let revoked: Bool }
        return Self.encoded(Events(moved: moved.flatMap { try? json($0) } ?? "", revoked: revoked))
    }
}
