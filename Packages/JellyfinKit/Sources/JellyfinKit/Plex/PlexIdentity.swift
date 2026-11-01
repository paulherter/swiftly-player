import Foundation

/// **Who is asking**: the fixed facts every Plex request carries as headers.
///
/// `clientID` must be created once per installation and kept (a UUID); Plex lists the
/// device under it and ties tokens to it. It is a parameter on purpose: the app decides
/// where it lives (keychain, file), the package only uses it.
public struct PlexIdentity: Sendable, Equatable {
    public let clientID: String
    public let product: String
    public let version: String
    /// `iOS`, `tvOS`, `macOS`, `Android`, `Linux`, `Windows`.
    public let platform: String
    public let platformVersion: String?
    /// Model, e.g. `iPhone15,2`.
    public let device: String
    /// The name the user gave the device; UTF-8 is allowed.
    public let deviceName: String

    public init(clientID: String, product: String = "Swiftly Player",
                version: String = VersionNumber.outBundle, platform: String,
                platformVersion: String? = nil, device: String, deviceName: String) {
        self.clientID = clientID
        self.product = product
        self.version = version
        self.platform = platform
        self.platformVersion = platformVersion
        self.device = device
        self.deviceName = deviceName
    }

    /// This device's identity: the platform it runs on, the app's name and version.
    public static func thisDevice(clientID: String, deviceName: String,
                                  product: String = "Swiftly Player",
                                  version: String = VersionNumber.outBundle) -> PlexIdentity {
        #if os(iOS)
        let platform = "iOS"
        #elseif os(tvOS)
        let platform = "tvOS"
        #elseif os(macOS)
        let platform = "macOS"
        #elseif os(Windows)
        let platform = "Windows"
        #elseif os(Android)
        let platform = "Android"
        #else
        let platform = "Linux"
        #endif
        return PlexIdentity(clientID: clientID, product: product, version: version,
                            platform: platform, device: platform, deviceName: deviceName)
    }

    /// A fresh id for the first start. The caller stores it.
    public static func makeClientID() -> String { UUID().uuidString.lowercased() }

    /// The header fields for a request; `token` only for routes that need one.
    func headers(token: String? = nil, sessionID: String? = nil) -> [String: String] {
        var fields = [
            "Accept": "application/json",
            "X-Plex-Client-Identifier": clientID,
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Platform": platform,
            "X-Plex-Device": device,
            "X-Plex-Device-Name": Self.safeValue(deviceName),
        ]
        if let platformVersion { fields["X-Plex-Platform-Version"] = platformVersion }
        if let token { fields["X-Plex-Token"] = token }
        if let sessionID { fields["X-Plex-Session-Identifier"] = sessionID }
        return fields
    }

    /// A header value cannot hold a line break. Everything else (umlauts, emoji) is fine.
    static func safeValue(_ raw: String) -> String {
        String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }))
    }
}

/// What can go wrong with Plex beyond what ``JellyfinError`` already says.
public enum PlexError: LocalizedError, Equatable, Sendable {
    /// The browser sign-in was not finished in time or the code expired.
    case pinExpired
    /// The profile asks for its PIN, or the PIN was wrong.
    case profilePinWrong
    /// plex.tv shows no server for this account.
    case noServer
    /// No address of the server answered; none of local, remote or relay.
    case serverUnreachable
    /// A different server answered at the remembered address.
    case wrongServer
    /// The server refuses remote streaming without Plex Pass / Remote Watch Pass.
    case remoteAccessMissing
    /// The title has no file to play.
    case noFile
    /// The call has no counterpart on a Plex server (sign-in with a password, a Jellyfin-only
    /// feature). The app hides what the server's capabilities do not list, so this is the
    /// answer to a call that should not have been made.
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .pinExpired:
            translated("Die Anmeldung bei Plex ist abgelaufen. Bitte noch einmal starten.")
        case .profilePinWrong:
            translated("Die PIN des Profils stimmt nicht.")
        case .noServer:
            translated("Zu diesem Plex-Konto gehört kein Server.")
        case .serverUnreachable:
            translated("Der Plex-Server antwortet unter keiner seiner Adressen.")
        case .wrongServer:
            translated("Unter dieser Adresse meldet sich ein anderer Server.")
        case .remoteAccessMissing:
            translated("Dieser Server erlaubt das Abspielen von unterwegs nicht. Der Besitzer braucht dafür Plex Pass oder den Remote Watch Pass.")
        case .noFile:
            translated("Zu diesem Titel gibt es keine Datei.")
        case .unsupported:
            translated("Das kann ein Plex-Server nicht.")
        }
    }
}
