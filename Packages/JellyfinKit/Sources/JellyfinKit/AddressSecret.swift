import Foundation

public extension URL {

    /// The address without anything that does not belong in a log.
    ///
    /// Jellyfin takes the access credential as a query value, so every image
    /// and stream address carries `api_key=<token>` in plain text. If such an
    /// address lands in the system log, the token shows up in the console of every
    /// connected machine and in every sysdiagnose bundle. The token is a full
    /// server credential that never expires.
    ///
    /// Therefore: addresses are logged only through this.
    var withoutSecret: String {
        guard var parts = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return absoluteString
        }
        let secret: Set<String> = ["api_key", "ApiKey", "X-Emby-Token", "token",
                                   "secret", "Secret", "pw", "Pw", "password"]
        parts.queryItems = parts.queryItems?.map { value in
            secret.contains(value.name)
                ? URLQueryItem(name: value.name, value: "…")
                : value
        }
        return parts.url?.absoluteString ?? absoluteString
    }
}

/// **Under which name an image is cached** - the other side of the same rule.
///
/// Every image address carries `ApiKey`. Used raw as the key, the same poster
/// gets a different name after an account switch: the whole cache goes cold
/// at once, every tile is fetched again, and the old entries stay until they
/// fall out at the back. With two accounts that is half the space.
///
/// **An image belongs to no account.** The server serves it under the same
/// id, and Jellyfin's `tag` stays in the key, so a changed version is still
/// noticed. It is fetched with the full path and cached without the credential.
///
/// For the `SeriesCache` the account belongs in the key, because an `Item`
/// carries the watch state. An image carries none.
public enum ImageKey {

    public static func of(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let values = parts.queryItems, values.contains(where: { attribute($0.name) })
        else { return url.absoluteString }
        parts.queryItems = values.filter { !attribute($0.name) }
        return (parts.url ?? url).absoluteString
    }

    private static func attribute(_ name: String) -> Bool {
        name == "ApiKey" || name == "api_key"
    }
}
