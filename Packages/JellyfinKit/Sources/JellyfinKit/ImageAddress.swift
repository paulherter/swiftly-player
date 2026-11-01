import Foundation

/// Which image of an item is meant.
public enum ImageKind: String, Sendable {
    case poster    = "Primary"
    case background = "Backdrop"
    /// Landscape thumbnail. Jellyfin often has it for series, rarely for episodes; still
    /// usable as a fallback for a 16:9 tile.
    case preview  = "Thumb"
    /// The title logo (wordmark) with transparency.
    case logo      = "Logo"
}

/// How the image is cropped.
public enum ImageMetric: Sendable {
    /// Limit height, keep aspect ratio; for posters.
    case atMostHigh(Int)
    /// Limit width; for backgrounds.
    case atMostWide(Int)
    /// Fill exactly this size; for round icons.
    case filling(wide: Int, up: Int)
}

/// Builds the address of an image on the server.
///
/// This used to exist in seven nearly identical places. Two attached the access token, two
/// did not, which went unnoticed as long as the server serves images without
/// authentication.
public struct ImageAddress: Sendable {
    public let base: URL
    public let token: String?
    /// The query name that carries the token: `ApiKey`, `api_key` on Emby
    /// (``EmbyPaths/tokenName(for:)``).
    public let tokenName: String
    /// Plex names images by path (the item's `thumb`/`art`), not by id and kind.
    public let kind: ServerKind

    public init(base: URL, token: String?, kind: ServerKind = .jellyfin) {
        self.base = base
        self.token = token
        self.kind = kind
        self.tokenName = EmbyPaths.tokenName(for: kind)
    }

    public func construct(itemID: String, art: ImageKind = .poster, mark: String? = nil,
                      mass: ImageMetric, index: Int? = nil, guete: Int = 90) -> URL? {
        if kind == .plex { return plexImage(itemID: itemID, art: art, mark: mark, mass: mass, quality: guete) }
        var path = "Items/\(itemID)/Images/\(art.rawValue)"
        if let index { path += "/\(index)" }
        var parts = URLComponents(url: base.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)

        var values: [URLQueryItem] = []
        // The tag is Jellyfin's fingerprint of the image. Without it the server still
        // answers, but caches may keep stale versions.
        if let mark { values.append(.init(name: "tag", value: mark)) }
        switch mass {
        case let .atMostHigh(h):
            values.append(.init(name: "maxHeight", value: String(h)))
        case let .atMostWide(b):
            values.append(.init(name: "maxWidth", value: String(b)))
        case let .filling(wide, up):
            values.append(.init(name: "fillWidth", value: String(wide)))
            values.append(.init(name: "fillHeight", value: String(up)))
        }
        values.append(.init(name: "quality", value: String(guete)))
        if let token { values.append(.init(name: tokenName, value: token)) }

        parts?.queryItems = values
        return parts?.url
    }

    /// **A Plex image.** The "tag" of a Plex item is the path the server wrote in `thumb` /
    /// `art` (``PlexMapper``); the server scales it at `/photo/:/transcode`. Measured: the
    /// scaler answers `400` unless both sides are given, so the open side gets a limit no
    /// picture reaches, and JPEG quality 75 unless `quality` is given. Without a path the item's own current image is asked for, which
    /// exists for the poster and the background only. People's `thumb` is already a full
    /// address and stays one.
    private func plexImage(itemID: String, art: ImageKind, mark: String?, mass: ImageMetric,
                           quality: Int) -> URL? {
        var path = mark
        if path == nil {
            switch art {
            case .poster, .preview: path = "/library/metadata/\(itemID)/thumb"
            case .background: path = "/library/metadata/\(itemID)/art"
            case .logo: return nil
            }
        }
        guard let path else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return URL(string: path) }
        let open = 4096
        let size: (width: Int, height: Int)
        switch mass {
        case let .atMostHigh(h): size = (open, h)
        case let .atMostWide(w): size = (w, open)
        case let .filling(w, h): size = (w, h)
        }
        var parts = URLComponents(url: base.appendingPathComponent("photo/:/transcode"),
                                  resolvingAgainstBaseURL: false)
        var values = [URLQueryItem(name: "url", value: path),
                      URLQueryItem(name: "upscale", value: "0"),
                      URLQueryItem(name: "width", value: String(size.width)),
                      URLQueryItem(name: "height", value: String(size.height)),
                      // Measured: without it the scaler writes JPEG quality 75; Jellyfin's
                      // tiles ask for 90, and the Plex covers looked softer next to them.
                      URLQueryItem(name: "quality", value: String(quality))]
        // Both sides are a box to fill, not a limit: cover it and cut the rest.
        if case .filling = mass { values.append(URLQueryItem(name: "minSize", value: "1")) }
        if let token { values.append(.init(name: tokenName, value: token)) }
        parts?.queryItems = values
        return parts?.url
    }

    /// A user's profile picture.
    public func user(_ userID: String, mark: String? = nil, border: Int) -> URL? {
        // A Plex profile's picture is a full address from plex.tv; the session keeps none.
        if kind == .plex { return nil }
        var parts = URLComponents(
            url: base.appendingPathComponent("Users/\(userID)/Images/Primary"),
            resolvingAgainstBaseURL: false)
        var values: [URLQueryItem] = []
        if let mark { values.append(.init(name: "tag", value: mark)) }
        values.append(.init(name: "fillWidth", value: String(border)))
        values.append(.init(name: "fillHeight", value: String(border)))
        values.append(.init(name: "quality", value: "90"))
        if let token { values.append(.init(name: tokenName, value: token)) }
        parts?.queryItems = values
        return parts?.url
    }
}
