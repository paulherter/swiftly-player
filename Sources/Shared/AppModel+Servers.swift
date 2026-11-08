import Foundation
import JellyfinKit

// MARK: - Signing in at Emby and Plex
//
// **What the finished pages call, and the network work behind it.**
//
// `EmbySignInModel` and `PlexSignInModel` (SignInModels.swift) only hold what the screen
// shows and a set of closures; this file fills the closures. The result of both flows is
// one `Session` of the right kind, handed to ``accountAdd(_:)``: from there on it is an
// ordinary account, in the bundle of its kind.

/// What a flow holds between its steps, so the model stays a plain value holder.
@MainActor
private final class EmbyHeld {
    var server: (any MediaServer)?
}

@MainActor
private final class PlexHeld {
    var pin: PlexPin?
    var expires = Date.distantFuture
    var polling: Task<Void, Never>?
    var handled = false
    var accountToken: String?
    var accountUserID = ""
    var accountName = ""
    var accountThumb: String?
    var homeUsers: [PlexHomeUser] = []
    var profile: PlexHomeUser?
    var profileToken: String?
    var servers: [PlexServerResource] = []
}

extension AppModel {

    /// A new account of any kind: the first one starts the app, a further one switches to it.
    func accountAdd(_ s: Session) {
        let first = session == nil
        signInTransition(s) { [self] in
            if first {
                sessionAdopt(s, signedInWith: Self.makeServer(session: s))
            } else {
                serverRecord(s)
            }
        }
    }

    /// **Signing in plays the same overlay as the switch in the profile**: the
    /// page slides away, the new account's picture flies to the corner, the rows
    /// come in afterwards. `adopt` is what actually takes the account in; it runs
    /// at the point where the switch would happen, 0.3 s before the picture rests.
    ///
    /// The picture starts in the middle of the window since a sign-in has no
    /// circle to lift it from. Without a known corner yet (the very first sign-in,
    /// no home page was ever shown) it stays with the page sliding away.
    func signInTransition(_ s: Session, adopt: @escaping () -> Void) {
        let transition = AccountSwitchTransition.shared
        guard !transition.waits, let size = AccountSwitchStage.windowSize,
              size.width > 0, size.height > 0 else {
            adopt()
            return
        }
        let side: CGFloat = 96
        let from = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                          width: side, height: side)
        let address = userImageURL(for: s)
        let withoutImage = address.map { ImageCache.shared.image($0) == nil } ?? true
        transition.start(
            account: s.accountKey,
            image: ProfileCharacter(name: s.userName, image: address, size: side * 1.06,
                                    withoutImage: withoutImage),
            // Clear: there is no circle on the snapshot that would need covering.
            from: from, area: .clear, address: address, switchTo: adopt)
    }

    // MARK: Emby

    /// - Parameters:
    ///   - address: a server already in the set; the page then goes straight to sign-in.
    ///   - finished: the account is in; the caller leaves the page.
    ///   - back: the arrow on the address step.
    ///   - useJellyfin: only offered when an address answers as Jellyfin.
    func embySignInModel(address: String? = nil, finished: @escaping () -> Void,
                         back: @escaping () -> Void,
                         useJellyfin: ((String) -> Void)? = nil) -> EmbySignInModel {
        let model = EmbySignInModel()
        let held = EmbyHeld()
        model.actions.cancel = back
        model.actions.useJellyfin = useJellyfin
        model.actions.check = { [weak self, weak model] raw, headers in
            guard let self, let model else { return }
            Task { await self.embyCheck(raw, headers: headers, model: model, held: held) }
        }
        model.actions.signIn = { [weak self, weak model] user, password in
            guard let self, let model else { return }
            Task {
                await self.embySignIn(user: user, password: password, model: model, held: held,
                                      finished: finished)
            }
        }
        if let address {
            model.address = address
            Task { await embyCheck(address, headers: [], model: model, held: held) }
        }
        return model
    }

    private func embyCheck(_ raw: String, headers: [OwnHeader], model: EmbySignInModel,
                           held: EmbyHeld) async {
        model.checking = true
        model.problem = nil
        defer { model.checking = false }
        guard let url = Self.normalizeServerURL(raw) else {
            model.problem = .other(String(localized: "Die Adresse konnte nicht gelesen werden."))
            return
        }
        var candidates = [url]
        if !raw.contains("://"), let different = AppModelURLNormalizer.reversed(url) {
            candidates.append(different)
        }
        let new = OwnHeaders.cleaned(headers)
        var lastError: (any Error)?
        for address in candidates {
            guard let client = Self.makeServer(kind: .emby, baseURL: address) else { continue }
            let before = OwnHeaders.registered(for: address)
            if !new.isEmpty { OwnHeaders.setDown(new, for: address) }
            let info: PublicSystemInfo
            do { info = try await client.checkReachability() } catch {
                lastError = error
                if !new.isEmpty { OwnHeaders.setDown(before, for: address) }
                if !AddressCheck.fallbackPaysOff(to: error) { break }
                continue
            }
            // Emby and Jellyfin answer the same route and look alike from outside.
            if info.looksLikeJellyfin {
                if !new.isEmpty { OwnHeaders.setDown(before, for: address) }
                model.problem = .notEmby(kindFound: ServerKind.jellyfin.displayName)
                return
            }
            if !new.isEmpty { ownHeadersSafe(new, for: address) }
            held.server = client
            model.address = address.absoluteString
            model.users = nil
            model.step = .signIn(serverName: info.serverName ?? address.host() ?? String(localized: "Server"),
                                 version: info.version ?? "?")
            model.users = await embyUsers(of: client)
            return
        }
        if let j = lastError as? JellyfinError, case let .transport(text) = j,
           text == OwnHeaders.loginPageText {
            model.problem = .other(text)
            return
        }
        model.problem = .unreachable(address: raw)
    }

    /// The accounts the server offers on its own sign-in page; empty when it shows none.
    private func embyUsers(of client: any MediaServer) async -> [EmbyUserChoice] {
        guard let source = client as? any QuickSignIn,
              let found = try? await source.publicUser() else { return [] }
        var list: [EmbyUserChoice] = []
        for user in found {
            list.append(EmbyUserChoice(id: user.id, name: user.name,
                                       image: await source.userImage(user, border: 180)))
        }
        return list
    }

    private func embySignIn(user: String, password: String, model: EmbySignInModel,
                            held: EmbyHeld, finished: () -> Void) async {
        guard let client = held.server else { return }
        model.signingIn = true
        model.signInError = nil
        defer { model.signingIn = false }
        do {
            let s = try await client.authenticate(username: user, password: password)
            accountAdd(s)
            finished()
        } catch {
            model.signInError = readable(error)
        }
    }

    // MARK: Plex

    /// - Parameters:
    ///   - finished: the account is in; the caller leaves the page.
    ///   - back: the arrow at the top when there is no earlier step.
    func plexSignInModel(finished: @escaping () -> Void,
                         back: @escaping () -> Void) -> PlexSignInModel {
        let model = PlexSignInModel()
        let held = PlexHeld()
        let service = PlexAccountService(
            identity: .thisDevice(clientID: Self.deviceID, deviceName: Self.deviceName))
        // Everything the actions need, once, so each closure stays one line.
        let run = PlexRun(app: self, model: model, held: held, service: service, finished: finished)

        model.actions.start = { Task { await run.start() } }
        model.actions.browserClosed = { _ in Task { await run.pollOnce() } }
        model.actions.pickProfile = { p in Task { await run.pickProfile(p) } }
        model.actions.submitPin = { p, pin in Task { await run.submitPin(p, pin: pin) } }
        model.actions.pickServer = { s in Task { await run.pickServer(s) } }
        model.actions.reloadServers = { Task { await run.loadServers() } }
        model.actions.otherAccount = { run.otherAccount() }
        model.actions.cancel = { run.stop(); back() }
        return model
    }
}

// MARK: - The Plex steps

/// The Plex flow as one object, so the closures of the model hold it (and through it the
/// app) for as long as the page lives.
@MainActor
private final class PlexRun {
    let app: AppModel
    let model: PlexSignInModel
    let held: PlexHeld
    let service: PlexAccountService
    let finished: () -> Void

    init(app: AppModel, model: PlexSignInModel, held: PlexHeld, service: PlexAccountService,
         finished: @escaping () -> Void) {
        self.app = app; self.model = model; self.held = held
        self.service = service; self.finished = finished
    }

    func stop() { held.polling?.cancel(); held.polling = nil }

    // MARK: Browser sign-in

    func start() async {
        stop()
        held.handled = false
        model.step = .opening
        do {
            #if os(tvOS)
            // The TV has no browser: a short code the person types at plex.tv/link on
            // another device, shown next to a QR code of that page.
            let pin = try await service.startPin(strong: false)
            let url = service.linkPage
            #else
            let pin = try await service.startPin(strong: true)
            guard let url = service.authURL(for: pin) else {
                throw PlexError.pinExpired
            }
            #endif
            held.pin = pin
            held.expires = Date().addingTimeInterval(TimeInterval(pin.expiresIn ?? 900))
            model.step = .waiting(prompt(url))
            held.polling = Task { [weak self] in await self?.poll(url) }
        } catch {
            fail(error)
        }
    }

    // No forwardUrl: plex.tv documents https addresses there, and with a custom scheme
    // the page was seen landing on the Watch start page. The poll sees the token anyway.

    private func prompt(_ url: URL) -> PlexPinPrompt {
        // The code of the browser sign-in is long and not made for typing; only the
        // countdown is shown. On the TV the code is the short one and is the point.
        #if os(tvOS)
        let code = held.pin?.code
        #else
        let code: String? = nil
        #endif
        return PlexPinPrompt(url: url, callbackScheme: "swiftly", code: code,
                      secondsLeft: max(Int(held.expires.timeIntervalSinceNow.rounded(.up)), 0))
    }

    /// About once a second until the token is there or the code is gone.
    private func poll(_ url: URL) async {
        var failures = 0
        while !Task.isCancelled, !held.handled {
            if Date() >= held.expires { model.step = .failed(.expired); return }
            switch await check() {
            case .token(let token): await signedIn(token: token); return
            case .waiting: failures = 0
            case .failed(let error):
                if let plex = error as? PlexError, plex == .pinExpired { fail(error); return }
                failures += 1
                if failures >= 5 { fail(error); return }
            }
            if case .waiting = model.step { model.step = .waiting(prompt(url)) }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// The browser window closed: look right now instead of waiting for the next beat.
    func pollOnce() async {
        guard case .waiting = model.step else { return }
        if case .token(let token) = await check() { await signedIn(token: token) }
    }

    private enum Poll { case token(String), waiting, failed(any Error) }

    private func check() async -> Poll {
        guard let pin = held.pin, !held.handled else { return .waiting }
        do {
            if let token = try await service.checkPin(pin).authToken, !token.isEmpty {
                return .token(token)
            }
            return .waiting
        } catch JellyfinError.http(let status, _) where status == 404 || status == 410 {
            return .failed(PlexError.pinExpired)
        } catch {
            return .failed(error)
        }
    }

    // MARK: After the token

    private func signedIn(token: String) async {
        // The timer and a closing browser window can both see the token; one wins.
        guard !held.handled else { return }
        held.handled = true
        // Not `stop()`: when the timer's own task got us here, cancelling it would cancel
        // the requests below. The loop ends by itself once `handled` is set.
        held.polling = nil
        model.step = .loading(.profiles)
        do {
            guard case .valid(let account) = try await service.validate(token: token) else {
                throw PlexError.pinExpired
            }
            held.accountToken = token
            held.accountUserID = account.id
            held.accountName = account.title
            held.accountThumb = account.thumb
            model.account = account.title
            let users = (try? await service.homeUsers(token: token)) ?? []
            held.homeUsers = users
            if users.count > 1 {
                let choices = users.map {
                    PlexProfileChoice(id: $0.uuid, name: $0.title, image: $0.thumb.flatMap(URL.init(string:)),
                                      protected: $0.isProtected)
                }
                model.lastProfiles = choices
                model.step = .profiles(choices)
            } else {
                held.profile = users.first
                held.profileToken = token
                model.step = .loading(.servers)
                await loadServers()
            }
        } catch {
            fail(error)
        }
    }

    func pickProfile(_ choice: PlexProfileChoice) async {
        guard let user = held.homeUsers.first(where: { $0.uuid == choice.id }) else { return }
        if choice.protected { model.pinWrong = false; model.step = .pin(choice); return }
        await switchTo(user, choice: choice, pin: nil)
    }

    func submitPin(_ choice: PlexProfileChoice, pin: String) async {
        guard let user = held.homeUsers.first(where: { $0.uuid == choice.id }) else { return }
        model.pinChecking = true
        model.pinWrong = false
        await switchTo(user, choice: choice, pin: pin)
        model.pinChecking = false
    }

    private func switchTo(_ user: PlexHomeUser, choice: PlexProfileChoice, pin: String?) async {
        guard let account = held.accountToken else { return }
        do {
            let token = try await service.switchUser(user, pin: pin, token: account)
            held.profile = user
            held.profileToken = token
            model.profile = choice
            model.step = .loading(.servers)
            await loadServers()
        } catch PlexError.profilePinWrong {
            // A wrong PIN stays on the PIN page; an unprotected profile that is refused
            // has nothing to retry, so it goes back to the list.
            if pin != nil { model.pinWrong = true } else { fail(PlexError.profilePinWrong) }
        } catch {
            fail(error)
        }
    }

    // MARK: Servers

    func loadServers() async {
        guard let token = held.profileToken ?? held.accountToken else { return }
        model.step = .loading(.servers)
        model.unreachable = []
        do {
            let found = try await service.servers(token: token)
            held.servers = found
            model.step = .servers(found.map {
                PlexServerChoice(id: $0.machineIdentifier, name: $0.name,
                                 sharedBy: $0.owned ? nil : ($0.sourceTitle ?? String(localized: "einem anderen Konto")),
                                 local: $0.connections.contains { $0.isLocal }, online: $0.presence)
            })
        } catch {
            fail(error)
        }
    }

    func pickServer(_ choice: PlexServerChoice) async {
        guard model.connecting == nil,
              let server = held.servers.first(where: { $0.machineIdentifier == choice.id }),
              let accountToken = held.accountToken else { return }
        let profileToken = held.profileToken ?? accountToken
        model.connecting = choice.id
        model.unreachable.remove(choice.id)
        defer { model.connecting = nil }
        // The server's own token is the one that opens it; the profile's token asks plex.tv.
        let key = server.accessToken ?? profileToken
        let connector = PlexConnector(identity: service.identity, token: key,
                                      machineIdentifier: server.machineIdentifier)
        do {
            let connection = try await connect(connector, to: server)
            let user = held.profile
            let s = Session(plexServer: server, connection: connection, accountToken: profileToken,
                            userID: user?.id ?? held.accountUserID,
                            userName: user?.title ?? held.accountName,
                            homeUserUUID: user?.uuid,
                            userImage: (user?.thumb ?? held.accountThumb).flatMap(URL.init(string:)))
            app.accountAdd(s)
            finished()
        } catch {
            model.unreachable.insert(choice.id)
        }
    }

    /// One try; when it failed at once (the system's local-network question still on the
    /// screen refuses the LAN addresses in a blink) a second after a moment. A server that
    /// is really gone fails slowly and is not asked twice.
    private func connect(_ connector: PlexConnector,
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

    func otherAccount() {
        stop()
        held.pin = nil
        held.accountToken = nil
        held.profileToken = nil
        held.profile = nil
        held.homeUsers = []
        held.servers = []
        model.account = nil
        model.profile = nil
        model.lastProfiles = nil
        model.step = .start
    }

    // MARK: Errors

    /// The sentences are in `DESIGN-AUSWAHL.md`: plex.tv gone, code expired, anything else
    /// with its own words.
    private func fail(_ error: any Error) {
        stop()
        if let plex = error as? PlexError {
            switch plex {
            case .pinExpired: model.step = .failed(.expired)
            case .noServer: model.step = .servers([])
            default: model.step = .failed(.other(app.readable(error)))
            }
            return
        }
        if error is URLError {
            model.step = .failed(.plexUnreachable)
            return
        }
        if let j = error as? JellyfinError, case .transport = j {
            model.step = .failed(.plexUnreachable)
            return
        }
        model.step = .failed(.other(app.readable(error)))
    }
}
