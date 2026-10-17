import Foundation

/// **The key under which an image lies on disk**, without host and without
/// credentials.
///
/// The same server is often reachable under two addresses (home, away), and an
/// account switch changes only the credentials. Both should hit the same stored
/// image. What remains is path and query: ID, image type, size and `tag`.
///
/// **Only with `tag`.** That is Jellyfin's fingerprint of the image: if it
/// changes on the server, the address changes and the old entry is no longer
/// hit. Without `tag` a stale image would never be noticed, so `nil`, and the
/// image does not go to disk.
///
/// Unlike ``Bildschluessel``, which keeps the host for memory: that only lives
/// for the process lifetime.
public enum ImageStoreKey {

    public static func of(_ url: URL) -> String? {
        guard let withoutAccess = URL(string: ImageKey.of(url)),
              var parts = URLComponents(url: withoutAccess, resolvingAgainstBaseURL: false),
              parts.queryItems?.contains(where: { $0.name.lowercased() == "tag" && $0.value?.isEmpty == false }) == true
        else { return nil }
        parts.scheme = nil
        parts.user = nil
        parts.password = nil
        parts.host = nil
        parts.port = nil
        return parts.string
    }
}
