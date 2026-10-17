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

    public init(base: URL, token: String?) {
        self.base = base
        self.token = token
    }

    public func construct(itemID: String, art: ImageKind = .poster, mark: String? = nil,
                      mass: ImageMetric, index: Int? = nil, guete: Int = 90) -> URL? {
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
        if let token { values.append(.init(name: "ApiKey", value: token)) }

        parts?.queryItems = values
        return parts?.url
    }

    /// A user's profile picture.
    public func user(_ userID: String, mark: String? = nil, border: Int) -> URL? {
        var parts = URLComponents(
            url: base.appendingPathComponent("Users/\(userID)/Images/Primary"),
            resolvingAgainstBaseURL: false)
        var values: [URLQueryItem] = []
        if let mark { values.append(.init(name: "tag", value: mark)) }
        values.append(.init(name: "fillWidth", value: String(border)))
        values.append(.init(name: "fillHeight", value: String(border)))
        values.append(.init(name: "quality", value: "90"))
        if let token { values.append(.init(name: "ApiKey", value: token)) }
        parts?.queryItems = values
        return parts?.url
    }
}
