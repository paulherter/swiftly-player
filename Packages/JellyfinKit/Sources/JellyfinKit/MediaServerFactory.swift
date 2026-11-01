import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// **The one place that builds a media server client.** The app and the other front ends
/// ask here instead of naming a class, so a new kind needs no change at the call sites.
public enum MediaServerFactory {

    /// - Returns: `nil` only for a kind without a backend (none at the moment).
    public static func make(
        kind: ServerKind = .jellyfin,
        baseURL: URL,
        deviceID: String,
        deviceName: String,
        clientVersion: String = VersionNumber.outBundle,
        program: String = "Swiftly Player",
        session: Session? = nil,
        urlSession: URLSession = .localNetworkCapable
    ) -> (any MediaServer)? {
        switch kind {
        case .jellyfin:
            JellyfinClient(baseURL: baseURL, deviceID: deviceID, deviceName: deviceName,
                           clientVersion: clientVersion, program: program,
                           session: session, urlSession: urlSession)
        case .emby:
            JellyfinClient(baseURL: baseURL, deviceID: deviceID, deviceName: deviceName,
                           clientVersion: clientVersion, program: program,
                           session: session, urlSession: urlSession, kind: .emby)
        case .plex:
            // A Plex account is the session from sign-in; without one, only the address
            // is known (e.g. to ask the server who it is).
            PlexClient.make(session: session, baseURL: baseURL, deviceID: deviceID,
                            deviceName: deviceName, clientVersion: clientVersion,
                            program: program, urlSession: urlSession)
        }
    }

    /// For an account that is already known: kind and address come from the session.
    public static func make(
        session: Session,
        deviceID: String,
        deviceName: String,
        clientVersion: String = VersionNumber.outBundle,
        program: String = "Swiftly Player",
        urlSession: URLSession = .localNetworkCapable
    ) -> (any MediaServer)? {
        make(kind: session.kind, baseURL: session.serverURL, deviceID: deviceID,
             deviceName: deviceName, clientVersion: clientVersion, program: program,
             session: session, urlSession: urlSession)
    }
}
