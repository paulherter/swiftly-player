import Foundation

/// **The Plex part of a ``Session``.**
///
/// A Jellyfin account is "this address, this token". A Plex account is "this server of
/// this plex.tv account", and the address is only the way that worked last: it changes
/// with the network (home, mobile data, relay). So the session keeps what does not change
/// and what is needed to ask plex.tv for the addresses again.
///
/// In the ``Session`` the usual fields mean:
/// - `accessToken`: the token that the **server** accepts. For a server of the account's
///   own that is the account token; for a shared one, plex.tv hands out a separate one.
/// - `userID` / `userName`: the plex.tv user, i.e. the home profile that signed in.
/// - `serverURL`: the address in use, replaced when ``PlexClient`` switches.
///
/// **Written only when present** (``Session/plex``), and read with `decodeIfPresent`:
/// older sessions and every Jellyfin session carry no such block.
public struct PlexSessionDetails: Codable, Sendable, Equatable {
    /// The server, for good: what `/identity` and plex.tv call `machineIdentifier`.
    public let machineIdentifier: String
    public let serverName: String
    /// The plex.tv token of this profile. Needed to list the server's addresses again.
    public let accountToken: String
    /// Whether the address in ``Session/serverURL`` is on the home network / a relay.
    public let isLocal: Bool
    public let isRelay: Bool
    /// The home profile's `uuid`, if the account is a profile of a Plex Home.
    public let homeUserUUID: String?
    /// The profile's picture: a full address at plex.tv (the server has none). Kept here
    /// because a session otherwise knows nothing about the person but the name.
    public let userImage: URL?

    public init(machineIdentifier: String, serverName: String, accountToken: String,
                isLocal: Bool = false, isRelay: Bool = false, homeUserUUID: String? = nil,
                userImage: URL? = nil) {
        self.machineIdentifier = machineIdentifier
        self.serverName = serverName
        self.accountToken = accountToken
        self.isLocal = isLocal
        self.isRelay = isRelay
        self.homeUserUUID = homeUserUUID
        self.userImage = userImage
    }

    /// The same details after the client moved to another address.
    func moved(to connection: PlexChosenConnection) -> PlexSessionDetails {
        PlexSessionDetails(machineIdentifier: machineIdentifier, serverName: serverName,
                           accountToken: accountToken, isLocal: connection.isLocal,
                           isRelay: connection.isRelay, homeUserUUID: homeUserUUID,
                           userImage: userImage)
    }

    private enum CodingKeys: String, CodingKey {
        case machineIdentifier
        case serverName
        case accountToken
        case isLocal
        case isRelay
        case homeUserUUID
        case userImage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machineIdentifier = try c.decode(String.self, forKey: .machineIdentifier)
        serverName = try c.decodeIfPresent(String.self, forKey: .serverName) ?? ""
        accountToken = try c.decode(String.self, forKey: .accountToken)
        isLocal = try c.decodeIfPresent(Bool.self, forKey: .isLocal) ?? false
        isRelay = try c.decodeIfPresent(Bool.self, forKey: .isRelay) ?? false
        homeUserUUID = try c.decodeIfPresent(String.self, forKey: .homeUserUUID)
        userImage = try c.decodeIfPresent(URL.self, forKey: .userImage)
    }
}

public extension Session {

    /// A Plex session from what sign-in found out.
    init(plexServer server: PlexServerResource, connection: PlexChosenConnection,
         accountToken: String, userID: String, userName: String, homeUserUUID: String? = nil,
         userImage: URL? = nil) {
        self.init(accessToken: server.accessToken ?? accountToken, userID: userID,
                  userName: userName, serverURL: connection.uri, kind: .plex,
                  plex: PlexSessionDetails(machineIdentifier: server.machineIdentifier,
                                           serverName: server.name, accountToken: accountToken,
                                           isLocal: connection.isLocal, isRelay: connection.isRelay,
                                           homeUserUUID: homeUserUUID, userImage: userImage))
    }

    /// **Which server this account belongs to, as a stable text.**
    ///
    /// For per-server settings, the Seerr entry and the list of servers in a bundle. A
    /// Jellyfin server is its address (lower case, no trailing slash, as before). A Plex
    /// server is its machine, never its address: that changes with the network, and the
    /// settings would otherwise start over every time.
    var serverIdentity: String {
        if kind == .plex, let plex { return "plex:" + plex.machineIdentifier }
        return Self.serverIdentity(of: serverURL)
    }

    /// The identity of a server known only by its address.
    static func serverIdentity(of url: URL) -> String {
        var text = url.absoluteString.lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// The suffix of a setting that applies per server (`"immerDirectPlay" + suffix`).
    /// **For Jellyfin exactly the address as it was written before**, so nothing stored
    /// is lost.
    var serverSuffix: String {
        if kind == .plex, let plex { return "|plex:" + plex.machineIdentifier }
        return "|" + serverURL.absoluteString
    }

    /// **The account as downloads, positions to send later and offline lists keep it.**
    ///
    /// Jellyfin: the user id, as ever. Plex: a `ratingKey` is only unique per server, and
    /// the same plex.tv user sits on every server of the account, so the user id alone
    /// would put two servers' titles into one list. The machine goes in front.
    var storageAccount: String {
        if kind == .plex, let plex { return "plex-" + plex.machineIdentifier + "-" + userID }
        return userID
    }
}
