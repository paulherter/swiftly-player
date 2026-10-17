import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A custom HTTP header that the user enters themselves.
///
/// **What it is for.** Anyone running Jellyfin or Seerr behind Cloudflare Access,
/// Authelia, Authentik or Pangolin only lets through requests that carry a particular
/// header, for Cloudflare e.g. `CF-Access-Client-Id` and `CF-Access-Client-Secret`.
/// Without it the gateway answers with its own login page and the app gets HTML
/// instead of a response.
///
/// **The value is a secret.** It is treated like a password: entered hidden, stored in
/// the keychain and never logged, not even in ``TrackSupport``. For a log line use
/// ``Eigenkoepfe/namen(_:)``.
public struct OwnHeader: Codable, Sendable, Hashable {
    enum CodingKeys: String, CodingKey {
        case name
        case value = "wert"
    }
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Which custom headers go to which server, and which never do.
///
/// **A table keyed by address, not a field on the client.** The headers must go on
/// *every* request to this server: the API, every poster, the tile sheet, the
/// download, the control channel. Most of these never see the ``JellyfinClient``,
/// only a finished URL. So every place asks here with the URL, and the answer depends
/// only on **where** the request goes.
///
/// **Only to the own server.** A poster from TMDB, a subtitle from elsewhere, a
/// foreign stream get nothing. Compared are scheme, host, port and the path of the
/// base URL (a Jellyfin under `/jellyfin` behind a proxy). Taken from Streamyfin, where
/// this is the rule: the gateway's credentials are nobody else's business.
///
/// **Empty is the normal case.** If nothing is entered, nothing changes:
/// ``anwenden(on:)`` does not touch a request without a match.
public enum OwnHeaders {

    // MARK: What never goes out

    /// Headers that the app sets itself or that the network layer reserves.
    ///
    /// **`Authorization` and the `X-Emby-…` names** carry the Jellyfin token: a custom
    /// header of the same name would replace it, and the user would be signed out without
    /// knowing why. Streamyfin blocks the same three for the same reason. **`Cookie`**
    /// carries the Seerr session. The rest belongs to the network layer: `URLSession`
    /// ignores or overwrites it anyway, and an entry that silently does nothing is worse
    /// than one that is not accepted at all.
    static let locked: Set<String> = [
        "authorization", "x-emby-authorization", "x-emby-token", "x-mediabrowser-token",
        "cookie", "accept", "content-type", "content-length", "host",
        "connection", "transfer-encoding", "proxy-authorization", "upgrade",
    ]

    /// Must this name not be used? For the hint in the input field; the check itself
    /// lives in ``bereinigt(_:)``.
    public static func isLocked(_ name: String) -> Bool {
        locked.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Is this a valid header name? RFC 9110, “token”: letters, digits and
    /// ``!#$%&'*+-.^_`|~``; no space, no colon.
    public static func nameSuits(_ name: String) -> Bool {
        let permitted = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return !name.isEmpty && name.allSatisfy { permitted.contains($0) }
    }

    /// What is left of an input before it is stored or sent: **the one gate** for both.
    ///
    /// Dropped: entries without a name or value, with an invalid name, that are
    /// ``locked``, with a control character in the value (a line break there would
    /// append another header), and every further entry of the same name; case does not
    /// matter for headers, so not here either. The first wins.
    public static func cleaned(_ headers: [OwnHeader]) -> [OwnHeader] {
        var watched = Set<String>()
        return headers.compactMap { k in
            let name = k.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = k.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard nameSuits(name), !value.isEmpty,
                  !locked.contains(name.lowercased()),
                  !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
                  watched.insert(name.lowercased()).inserted
            else { return nil }
            return OwnHeader(name: name, value: value)
        }
    }

    /// Only the names, for a log. **Never the values.**
    public static func names(_ headers: [OwnHeader]) -> String {
        headers.isEmpty ? "keine" : headers.map(\.name).joined(separator: ", ")
    }

    // MARK: The table

    /// Behind a lock, because images, downloads and the player ask from everywhere,
    /// including outside any actor.
    private final class Panel: @unchecked Sendable {
        let barrier = NSLock()
        var entries: [String: [OwnHeader]] = [:]
    }
    private static let panel = Panel()

    /// Sets the headers for a server. An empty list removes it.
    public static func setDown(_ headers: [OwnHeader], for base: URL) {
        guard let key = key(base) else { return }
        let clean = cleaned(headers)
        panel.barrier.lock(); defer { panel.barrier.unlock() }
        if clean.isEmpty { panel.entries[key] = nil }
        else { panel.entries[key] = clean }
    }

    /// What is registered for exactly this base URL, for the input that should show
    /// the state. For sending, use ``fuer(_:)``.
    public static func registered(for base: URL) -> [OwnHeader] {
        guard let key = key(base) else { return [] }
        panel.barrier.lock(); defer { panel.barrier.unlock() }
        return panel.entries[key] ?? []
    }

    /// The headers for a request to this URL.
    ///
    /// **The longest matching base wins.** If Jellyfin under `/jellyfin` and Seerr under
    /// `/seerr` are behind the same host, each gets its own.
    public static func of(_ url: URL) -> [OwnHeader] {
        guard let target = parts(url) else { return [] }
        panel.barrier.lock(); defer { panel.barrier.unlock() }
        guard !panel.entries.isEmpty else { return [] }
        var bester: (length: Int, headers: [OwnHeader])?
        for (key, headers) in panel.entries {
            guard let base = URL(string: key).flatMap(parts),
                  base.provenance == target.provenance,
                  base.path.isEmpty || target.path == base.path
                    || target.path.hasPrefix(base.path + "/")
            else { continue }
            if base.path.count >= (bester?.length ?? -1) { bester = (base.path.count, headers) }
        }
        return bester?.headers ?? []
    }

    /// The same headers as a dictionary, for `AVURLAsset` and anything that takes no
    /// `URLRequest`.
    public static func fields(for url: URL) -> [String: String] {
        Dictionary(of(url).map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    /// Write into a request. Without a match it stays as it was.
    public static func apply(on petition: inout URLRequest) {
        guard let url = petition.url else { return }
        apply(of(url), on: &petition)
    }

    /// Write a known list into a request, for Seerr, whose headers hang on the
    /// account and are not in the table.
    public static func apply(_ headers: [OwnHeader], on petition: inout URLRequest) {
        for k in cleaned(headers) { petition.setValue(k.value, forHTTPHeaderField: k.name) }
    }

    // MARK: Storage

    /// The whole table for storing, **in the keychain**, not in settings:
    /// the values are credentials.
    public static func store() -> Data {
        panel.barrier.lock(); defer { panel.barrier.unlock() }
        return (try? JSONEncoder().encode(panel.entries)) ?? Data("{}".utf8)
    }

    /// Restore a stored table. Replaces what was there.
    public static func load(_ data: Data?) {
        let hasRead = data.flatMap { try? JSONDecoder().decode([String: [OwnHeader]].self, from: $0) } ?? [:]
        var clean: [String: [OwnHeader]] = [:]
        for (s, k) in hasRead {
            let b = cleaned(k)
            if !b.isEmpty, let url = URL(string: s), let new = key(url) { clean[new] = b }
        }
        panel.barrier.lock(); defer { panel.barrier.unlock() }
        panel.entries = clean
    }

    // MARK: Address comparison

    private struct Parts { let provenance: String; let path: String }

    /// Scheme, host, port and path in comparable form.
    ///
    /// **`ws` counts as `http`, `wss` as `https`**: the control channel is a WebSocket to
    /// the same server, and the gateway in front of it is the same.
    /// **A `..` in the path never matches**: it could be used to climb out of the base path.
    private static func parts(_ url: URL) -> Parts? {
        guard let k = URLComponents(url: url, resolvingAgainstBaseURL: true),
              var schema = k.scheme?.lowercased(), let computer = k.host?.lowercased(),
              !computer.isEmpty else { return nil }
        if schema == "ws" { schema = "http" }
        if schema == "wss" { schema = "https" }
        guard schema == "http" || schema == "https" else { return nil }
        let port = k.port ?? (schema == "https" ? 443 : 80)
        var path = k.percentEncodedPath
        guard !path.split(separator: "/").contains("..") else { return nil }
        while path.hasSuffix("/") { path.removeLast() }
        return Parts(provenance: "\(schema)://\(computer):\(port)", path: path)
    }

    private static func key(_ base: URL) -> String? {
        parts(base).map { $0.provenance + $0.path }
    }

    // MARK: Intercepted

    /// Did a gateway answer instead of the server, with a login page?
    ///
    /// **This is the failure this whole file fixes**, and without this check it looked like
    /// something else: Cloudflare Access redirects to its login page, `URLSession` follows,
    /// and in the end there is a 200 with HTML. The app reported “unintelligible response”
    /// or “Seerr did not return a session”: both true, and neither says what to do.
    /// The Jellyfin and Seerr APIs never return HTML.
    public static func loginPage(_ answer: URLResponse?) -> Bool {
        guard let http = answer as? HTTPURLResponse,
              let art = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        else { return false }
        return art.hasPrefix("text/html")
    }

    /// The sentence for the user.
    public static var loginPageText: String {
        translated("Vor dem Server sitzt eine Anmeldeseite, etwa Cloudflare Access oder Authelia. Trag die Header, die sie verlangt, unter „Erweitert“ ein.")
    }
}

public extension URLRequest {
    /// Adds the target server's custom headers, if there are any.
    mutating func ownHeadersSet() { OwnHeaders.apply(on: &self) }

    /// A plain fetch of `url`, with the custom headers of its server, for the places that
    /// used to say `data(from: url)`: images, subtitles, downloads. Without an entry it is
    /// the same request as before.
    static func withOwnHeaders(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.ownHeadersSet()
        return r
    }
}
