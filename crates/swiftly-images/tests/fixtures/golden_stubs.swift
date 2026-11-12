import Foundation
public enum ServerKind: String { case jellyfin, emby, plex }
public enum EmbyPaths {
    public static func tokenName(for kind: ServerKind) -> String {
        switch kind { case .emby: "api_key"; case .plex: "X-Plex-Token"; case .jellyfin: "ApiKey" }
    }
}
