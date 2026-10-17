import Foundation

/// Turns user input such as "tv.example.de" or "192.168.1.5:8096" into a usable
/// base URL.
public enum AppModelURLNormalizer {

    public static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            // No scheme given: guess, and the right way round.
            //
            // It used to assume `https` always. But most self-hosted Jellyfin servers run
            // on the home network under an IP without a certificate; anyone typing the
            // address without a scheme got an error whose cause could not be guessed.
            // A bare IPv6 address needs brackets, otherwise `URL` reads its colons as a
            // port and finds no host.
            if isIPv6(text) { text = "[" + text + "]" }
            text = (isHomeNetwork(text) ? "http://" : "https://") + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host() != nil else { return nil }
        return url
    }

    /// **Append a server-relative path to the server address, keeping its path.**
    ///
    /// Jellyfin gives `TranscodingUrl` and `DeliveryUrl` as a path with a leading
    /// slash ("/videos/…/master.m3u8"), without the subpath under which a reverse
    /// proxy publishes the server. `URL(string:relativeTo:)` resolves such a path
    /// per RFC 3986 against the **root** of the host: `https://h.de/jellyfin`
    /// became `https://h.de/videos/…`, a 404 at the proxy. External subtitles were
    /// then missing, and every repackaged playback (AirPlay, bitrate limit) stayed
    /// black. With IP and port and no subpath this never shows (Swiftfin#1695).
    /// The playback address itself always went through `appendingPathComponent` and
    /// was not affected.
    ///
    /// A complete address (external subtitles with `IsExternalUrl`) stays as it is.
    public static func serverRelative(_ detail: String, base: URL) -> URL? {
        if let full = URL(string: detail), full.scheme != nil { return full }
        guard let rel = URLComponents(string: detail),
              var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return nil }
        var ahead = parts.percentEncodedPath
        while ahead.hasSuffix("/") { ahead.removeLast() }
        var behind = rel.percentEncodedPath
        while behind.hasPrefix("/") { behind.removeFirst() }
        parts.percentEncodedPath = ahead + "/" + behind
        parts.percentEncodedQuery = rel.percentEncodedQuery
        parts.fragment = nil
        return parts.url
    }

    /// The same address with the other scheme, for the second attempt when the first
    /// fails at the connection.
    ///
    /// `nil` if it is already `http`: switching there would be no fallback, and a
    /// step back to unencrypted must never happen automatically if the user asked
    /// for `https`.
    public static func reversed(_ url: URL) -> URL? {
        guard url.scheme == "https" else { return nil }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.scheme = "http"
        return parts?.url
    }

    /// Addresses where a certificate is unlikely: IP literals, `.local`, `.lan`,
    /// `.home`, `.internal` and bare host names without a dot.
    public static func isHomeNetwork(_ text: String) -> Bool {
        // Cut off before any port and path.
        let name = text.split(separator: "/").first.map(String.init) ?? text
        // **IPv6 literal**, with brackets ("[fd00::5]:8096") or without, as
        // `URL.host()` returns it. Counts as home network like any IP literal; before,
        // that only happened by accident: cutting at the first colon left "fd00",
        // and a name without a dot is a host name.
        if name.hasPrefix("["), let toward = name.firstIndex(of: "]") {
            return isIPv6(String(name[name.index(after: name.startIndex) ..< toward]))
        }
        if isIPv6(name) { return true }
        let withoutPort = name.split(separator: ":").first.map(String.init) ?? name
        let small = withoutPort.lowercased()

        if small.hasSuffix(".local") || small.hasSuffix(".lan")
            || small.hasSuffix(".home") || small.hasSuffix(".internal")
            || small == "localhost" {
            return true
        }
        // A name without a dot is a host name on the own network.
        if !small.contains(".") { return true }
        // IPv4 literal.
        let parts = small.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ piece in
            !piece.isEmpty && piece.allSatisfy(\.isNumber) && (Int(piece) ?? 256) < 256
        }) {
            return true
        }
        return false
    }

    /// Does the text look like an IPv6 address? At least two colons, otherwise only
    /// hex digits and dots (for "::ffff:1.2.3.4"); a zone ("fe80::1%en0") is cut
    /// off first.
    static func isIPv6(_ text: String) -> Bool {
        let withoutZone = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        guard withoutZone.filter({ $0 == ":" }).count >= 2 else { return false }
        return withoutZone.allSatisfy { $0 == ":" || $0 == "." || $0.isHexDigit }
    }
}
