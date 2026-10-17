import Foundation
import JellyfinKit
import Observation

/// The Trakt integration, as seen by the UI.
///
/// **An add-on, like Seerr.** Users who connect nothing notice nothing: without
/// a token the reporter sends nothing out and does not even ask its own
/// server for IDs. And without the application's credentials (``verfuegbar``)
/// settings show no row at all.
///
/// **A separate login per Jellyfin account.** On a TV, several people often
/// watch under different profiles; what the children watch does not belong in
/// the parents' Trakt history. The key is therefore `Session.accountKey`:
/// server plus user.
///
/// The logic (queue, refresh, Trakt's 80 % rule) lives in the package
/// (`TraktReporter`, `TraktClient`); here are only the keychain, the sign-in
/// state and the calls from `AppModel`.
@MainActor
@Observable
final class TraktAccount {

    /// `nil` if the build had no `Trakt.json`.
    private static let access = TraktAccess.outPackage

    /// Is Trakt available in this build at all?
    var available: Bool { Self.access != nil }

    /// What the sign-in page currently shows.
    enum Login: Equatable {
        case no
        case fetchesCode
        case code(TraktDevicesCode, until: Date)
        case error(String)
    }

    private(set) var login: Login = .no
    private(set) var token: TraktToken?
    var connected: Bool { token != nil }
    var user: String? { token?.user }

    @ObservationIgnored private var account: String?
    @ObservationIgnored private var preGait: Task<Void, Never>?
    @ObservationIgnored private let client: TraktClient?
    @ObservationIgnored private let reporter: TraktReporter?

    init() {
        let client = Self.access.map { TraktClient(access: $0) }
        self.client = client
        reporter = client.map { client in
            TraktReporter(
                client: client,
                changed: { new, identifier in
                    Task { @MainActor in TraktAccount.shared?.renewed(new, identifier: identifier) }
                },
                log: { row in AppLog.writeOut("[Trakt] " + row) })
        }
        Self.shared = self
    }

    /// For the callback from the reporter, which runs outside the main run loop
    /// and must not retain `self`. There is exactly one account, attached to
    /// `AppModel`.
    private static weak var shared: TraktAccount?

    // MARK: Konto

    private static func key(_ account: String) -> String { "trakt|" + account }

    /// On sign-in, account switch and sign-out of Jellyfin.
    func accountSwitched(_ new: String?) {
        guard new != account else { return }
        cancel()
        account = new
        token = new.flatMap { Keychain.load(key: Self.key($0)) }
            .flatMap { try? JSONDecoder().decode(TraktToken.self, from: $0) }
        reporter?.tokenSet(token, identifier: new)
    }

    private func persist(_ new: TraktToken?, account: String) {
        let key = Self.key(account)
        if let new, let data = try? JSONEncoder().encode(new) {
            do { try Keychain.save(data, key: key) } catch {
                AppLog.writeOut("[Trakt] Schlüsselbund: \(error)")
            }
        } else {
            Keychain.delete(key: key)
        }
    }

    /// The reporter refreshed or lost the login.
    private func renewed(_ new: TraktToken?, identifier: String?) {
        guard let identifier else { return }
        persist(new, account: identifier)
        if identifier == account { token = new }
    }

    // MARK: Verbinden

    /// Fetches a code and waits until it is entered at Trakt.
    func linkUp() {
        guard let client, let account else { return }
        preGait?.cancel()
        login = .fetchesCode
        preGait = Task { [weak self] in
            do {
                let code = try await client.devicesCode()
                self?.login = .code(code, until: Date().addingTimeInterval(code.valid))
                var new = try await client.sharingWaitFor(code)
                new.user = await client.username(new)
                guard let self, !Task.isCancelled else { return }
                self.persist(new, account: account)
                if self.account == account {
                    self.token = new
                    self.reporter?.tokenSet(new, identifier: account)
                }
                self.login = .no
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.login = .error(Self.text(error))
            }
        }
    }

    /// Page closed or "Cancel".
    func cancel() {
        preGait?.cancel()
        preGait = nil
        login = .no
    }

    /// **"Disconnect", not "Sign out"**, as with Seerr. At Trakt the history
    /// stays as it is; only this login goes.
    func disconnect() {
        guard let account else { return }
        let alt = token
        token = nil
        persist(nil, account: account)
        reporter?.tokenSet(nil, identifier: account)
        if let alt, let client { Task { await client.revoked(alt) } }
    }

    private static func text(_ error: any Error) -> String {
        switch error as? TraktError {
        case .codeExpired: String(localized: "Der Code ist abgelaufen. Hol dir einen neuen.")
        case .rejected:      String(localized: "Trakt hat die Verbindung nicht freigegeben.")
        case .rateLimit:     String(localized: "Trakt bremst gerade. Versuch es in ein paar Minuten noch mal.")
        default:              String(localized: "Trakt ist gerade nicht erreichbar.")
        }
    }

    // MARK: Playback - called from `AppModel`, next to the Jellyfin reports

    func start(item: Item, client: JellyfinClient?, seconds: Double) {
        guard let reporter, token != nil, let client else { return }
        reporter.report(.start(titleID: item.id,
                             target: { await TraktTarget.resolve(item, client: client) },
                             spot: seconds, duration: item.runtimeSeconds ?? 0))
    }

    func runState(running: Bool, seconds: Double) {
        reporter?.report(.runState(running: running, spot: seconds))
    }

    func leap(seconds: Double) {
        reporter?.report(.leap(spot: seconds))
    }

    func stop(item: Item, seconds: Double) {
        reporter?.report(.stop(titleID: item.id, spot: seconds))
    }
}
