import Observation

/// Hears the seconds left of a Quick Connect code or a Plex PIN (one call a second, from the core's
/// task) and hands them to the main actor.
final class RestListener: QuickConnectListener, PlexPinListener {
    private let handler: @Sendable (Int64) -> Void
    init(_ handler: @escaping @Sendable (Int64) -> Void) { self.handler = handler }
    func rest(seconds: Int64) { handler(seconds) }
}

/// The `@MainActor @Observable` adapter of `AccountsModel`: the saved accounts and the one in use are
/// plain properties; every call that changes them re-reads both, so a view only reads them.
@MainActor
@Observable
public final class AccountsController {
    /// Every saved account of every server kind.
    public private(set) var accounts: [AccountInfo]
    /// The account in use, with its token.
    public private(set) var active: AccountRef?
    /// Seconds left of the Quick Connect code being waited for (`nil`: not waiting).
    public private(set) var quickSecondsLeft: Int64?

    @ObservationIgnored private let model: AccountsModel

    public init(model: AccountsModel) {
        self.model = model
        self.accounts = model.accounts()
        self.active = model.active()
    }

    private func reread() {
        accounts = model.accounts()
        active = model.active()
    }

    /// After another process wrote the stored accounts.
    public func reload() {
        model.reload()
        reread()
    }

    @discardableResult
    public func switchTo(_ key: String) -> AccountRef? {
        let account = model.switchTo(key: key)
        reread()
        return account
    }

    @discardableResult
    public func remove(_ key: String) -> AccountRef? {
        let account = model.remove(key: key)
        reread()
        return account
    }

    /// The server refused the token of `key`: dropped only while it is still the one in use.
    public func signOutRevoked(_ key: String) -> RevokedInfo? {
        let info = model.signOutRevoked(checkedKey: key)
        reread()
        return info
    }

    public func checkServer(_ address: String, kind: ServerKind) async throws -> ServerCheck {
        try await model.checkServer(address: address, kind: kind)
    }

    public func signIn(address: String, kind: ServerKind, user: String, password: String) async throws -> SignedIn {
        let signedIn = try await model.signIn(address: address, kind: kind, user: user, password: password)
        reread()
        return signedIn
    }

    public func quickConnectStart(_ address: String) async throws -> QuickCode {
        try await model.quickConnectStart(address: address)
    }

    /// Waits for the approval; `quickSecondsLeft` counts down meanwhile. Cancelling the Task stops it.
    public func quickConnectWait(_ address: String, code: QuickCode) async throws -> QuickEnd {
        let listener = RestListener { [weak self] seconds in
            Task { @MainActor in self?.quickSecondsLeft = seconds }
        }
        defer { quickSecondsLeft = nil }
        let end = try await model.quickConnectWait(address: address, code: code, listener: listener)
        reread()
        return end
    }

    /// The Plex sign-in of this installation (`platform`: `iOS`, `tvOS`, `macOS`, ...).
    public func plexSignIn(
        clientId: String, appVersion: String, platform: String, device: String, deviceName: String
    ) -> PlexSignInController {
        let flow = model.plexSignIn(
            clientId: clientId, appVersion: appVersion, platform: platform, device: device, deviceName: deviceName)
        return PlexSignInController(flow: flow) { [weak self] in self?.reread() }
    }
}

/// The `@MainActor @Observable` adapter of `PlexSignIn`: the code to show and the seconds left are
/// properties; the steps are plain async calls the host runs in order (`start`, `waitForToken`,
/// `loadAccount`, `pickProfile`, `servers`, `connect`).
@MainActor
@Observable
public final class PlexSignInController {
    /// The code and the links of the running sign-in.
    public private(set) var pin: PlexPinInfo?
    /// Seconds until the code runs out, while `waitForToken` runs.
    public private(set) var secondsLeft: Int64?

    @ObservationIgnored private let flow: PlexSignIn
    @ObservationIgnored private let signedIn: @MainActor () -> Void

    init(flow: PlexSignIn, signedIn: @escaping @MainActor () -> Void) {
        self.flow = flow
        self.signedIn = signedIn
    }

    /// `strong`: the long browser code; a TV shows the short one.
    public func start(strong: Bool) async throws -> PlexPinInfo {
        let info = try await flow.start(strong: strong)
        pin = info
        secondsLeft = info.seconds
        return info
    }

    public func checkNow() async throws -> Bool { try await flow.checkNow() }

    public func waitForToken() async throws -> PlexWaitEnd {
        let listener = RestListener { [weak self] seconds in
            Task { @MainActor in self?.secondsLeft = seconds }
        }
        return try await flow.waitForToken(listener: listener)
    }

    public func loadAccount() async throws -> PlexAccountEnd { try await flow.loadAccount() }
    public func pickProfile(_ id: String, pin: String? = nil) async throws -> PlexProfileEnd {
        try await flow.pickProfile(id: id, pin: pin)
    }
    public func servers() async throws -> [PlexServerOption] { try await flow.servers() }

    /// Signs in at the server and saves the account; the accounts controller re-reads its list.
    public func connect(_ serverId: String) async throws -> PlexConnectEnd {
        let end = try await flow.connect(serverId: serverId)
        signedIn()
        return end
    }

    public func bestRoute(accountToken: String, machineIdentifier: String, remembered: String?) async throws
        -> PlexRouteInfo?
    {
        try await flow.bestRoute(accountToken: accountToken, machineIdentifier: machineIdentifier, remembered: remembered)
    }

    /// Another account: everything held is forgotten.
    public func reset() {
        flow.reset()
        pin = nil
        secondsLeft = nil
    }
}
