import Foundation

/// Several Jellyfin accounts on the same server, and which one is current.
///
/// **Why a dedicated type and not just an array in the state holder.** A set of
/// small rules hangs on this collection that seem obvious at first glance and
/// can each go wrong: what happens when the same account signs in a second
/// time; which account applies after the active one was removed; what happens
/// to an old single session from before this feature. Such rules belong where
/// they can be tested without a simulator, not in a view.
public struct AccountBundle: Codable, Sendable, Equatable {
    enum CodingKeys: String, CodingKey {
        case accounts = "konten"
        case activeId = "aktiveKennung"
    }

    /// The accounts in the order in which they were added. They appear in that
    /// order in the strip above the profile page.
    public private(set) var accounts: [Session]

    /// The ID of the account the app is currently signed in with.
    public private(set) var activeId: String

    /// The active account.
    ///
    /// **Never optional to the outside.** A bundle without an active account is
    /// not a state that should exist; the occasions where it could arise are
    /// handled in here. If the pointer still points to nothing, e.g. because the
    /// keychain was edited by hand, the first account applies, rather than
    /// leaving the app without a session.
    public var activeOne: Session { account(activeId) ?? accounts[0] }

    /// The servers of the bundle, each once, in the order of their first account.
    /// There can be several. Previously a bundle belonged to exactly one server,
    /// and signing in to another one started over.
    public var server: [URL] {
        var watched = Set<String>()
        return accounts.map(\.serverURL).filter { watched.insert(Self.identifier($0)).inserted }
    }

    /// The accounts of one server, in their order.
    public func accounts(on server: URL) -> [Session] {
        accounts.filter { Self.identifier($0.serverURL) == Self.identifier(server) }
    }

    /// An account by its key (`Session.accountKey`) or, for remembered bundles
    /// from before the second server, by the bare user ID.
    public func account(_ identifier: String) -> Session? {
        accounts.first { $0.accountKey == identifier } ?? accounts.first { $0.userID == identifier }
    }

    /// The server of the active account.
    public var serverURL: URL { activeOne.serverURL }

    /// A single account, as it looks after the first sign-in.
    public init(_ firstOne: Session) {
        accounts = [firstOne]
        activeId = firstOne.accountKey
    }

    /// From stored values. Returns `nil` if there is nothing; an empty bundle is
    /// no bundle.
    public init?(accounts: [Session], active: String?) {
        guard let firstOne = accounts.first else { return nil }
        self.accounts = accounts
        let wished = active.flatMap { a in
            accounts.first { $0.accountKey == a } ?? accounts.first { $0.userID == a }
        }
        activeId = (wished ?? firstOne).accountKey
    }

    /// The old store of the GTK version: other field names, same meaning.
    ///
    /// **Why this is in the package although it sounds platform-specific.** It
    /// knows no paths and no store, only field names; it is a statement about our
    /// own legacy data, and that can be tested without a simulator. The GTK layer
    /// has no test target, so exactly this conversion would have gone untested.
    ///
    /// **And it did go wrong**: the old file was handed raw to
    /// ``ausAblage(bundle:individual:)``, which wants to read it as a ``Session``.
    /// Three of four keys do not match, `try?` swallows the failure, and **every
    /// existing user faced the sign-in screen after the update.** On a machine that
    /// already has the new store nothing shows; it was only noticed because a test
    /// machine still had the old state.
    ///
    /// `serverName` is dropped: it is not in the new store and is fetched fresh on
    /// the first connection anyway.
    public static func outOldGtkStore(_ data: Data) -> Session? {
        struct Stored: Decodable {
            enum CodingKeys: String, CodingKey {
                case serverURL
                case token
                case userIdentifier = "benutzerID"
                case username = "benutzername"
            }
            let serverURL: URL
            let token: String
            let userIdentifier: String
            let username: String
        }
        guard let a = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return Session(accessToken: a.token, userID: a.userIdentifier,
                       userName: a.username, serverURL: a.serverURL)
    }

    /// Adds an account and says whether it was a **switch**.
    ///
    /// **Why this is here and not with the callers.** Both versions derived it
    /// themselves, "a bundle existed before, so it is a switch", once in
    /// `AppModel.sessionAdopt`, once in the GTK version. Two derivations of
    /// The same rule, and a lot hangs on the answer: whether the home page is
    /// cleared, whether the remote control is rebuilt, whether a second load is
    /// triggered. Deriving it wrongly produces exactly the bugs seen before.
    public static func record(_ new: Session,
                                 in available: AccountBundle?) -> (bundle: AccountBundle,
                                                                wasChange: Bool) {
        // A different server is added like another account; it no longer replaces
        // the bundle.
        guard var bundle = available else {
            return (AccountBundle(new), false)
        }
        bundle.record(new)
        return (bundle, true)
    }

    /// From what is in the store, including the migration from before multiple
    /// accounts.
    ///
    /// **This also existed twice**, in `AppModel.loadBundle()` and in the GTK
    /// version: first try the bundle, otherwise the single session from before,
    /// otherwise nothing. The old single session is left in place rather than
    /// deleted on purpose: starting an older version again should not suddenly be
    /// signed out.
    ///
    /// **Where the data comes from is the platform's business** (keychain, file,
    /// registry). Here only what it means.
    public static func outStore(bundle: Data?, individual: Data?) -> AccountBundle? {
        let reader = JSONDecoder()
        if let bundle, let b = try? reader.decode(AccountBundle.self, from: bundle) {
            return b
        }
        guard let individual,
              let alt = try? reader.decode(Session.self, from: individual) else { return nil }
        return AccountBundle(alt)
    }

    /// Adds an account and makes it the active one.
    ///
    /// **The same account never exists twice.** If someone signs in again, because
    /// the token had expired, the new session replaces the old **in place**.
    /// Appending would put the same name twice in the strip, and the user would
    /// have to guess which of the two still works.
    public mutating func record(_ new: Session) {
        if let i = accounts.firstIndex(where: { $0.accountKey == new.accountKey }) {
            accounts[i] = new
        } else {
            accounts.append(new)
        }
        activeId = new.accountKey
    }

    /// Switches to an existing account. Unknown IDs change nothing; better to stay
    /// signed in than to switch to nothing.
    public mutating func switchTo(toward identifier: String) {
        guard let target = account(identifier) else { return }
        activeId = target.accountKey
    }

    /// Removes an account and returns what remains.
    ///
    /// **Signing out affects only that one account.** If it was the active one,
    /// the following one applies afterwards; if it was the last one, `nil` is
    /// returned: the app is signed out and sign-in starts from scratch. Removing
    /// all accounts at once would be a second meaning for the same button.
    public func removed(_ identifier: String) -> AccountBundle? {
        guard let distance = account(identifier),
              let i = accounts.firstIndex(where: { $0.accountKey == distance.accountKey })
        else { return self }
        var rest = accounts
        rest.remove(at: i)
        guard !rest.isEmpty else { return nil }
        // The next in line, otherwise the last one before it, so the strip does not
        // jump back to the start just because one in the middle dropped out.
        let successor = rest[min(i, rest.count - 1)]
        let wasActive = distance.accountKey == activeOne.accountKey
        let newActive = wasActive ? successor.accountKey : activeOne.accountKey
        return AccountBundle(accounts: rest, active: newActive)
    }

    /// Does the account belong to the same server as the bundle?
    ///
    /// The comparison uses the address without a trailing slash:
    /// `https://tv.example.de` and `https://tv.example.de/` are the same server,
    /// and both spellings occur, one from user input, the other from our
    /// normalization.
    public func fitsServer(_ s: Session) -> Bool {
        Self.identifier(s.serverURL) == Self.identifier(serverURL)
    }

    static func identifier(_ url: URL) -> String {
        var text = url.absoluteString.lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

extension Session {
    /// **Server and user together.** An account is only unique through its server:
    /// the same user ID on two servers, e.g. a moved server, makes two accounts.
    public var accountKey: String { AccountBundle.identifier(serverURL) + "|" + userID }
}
