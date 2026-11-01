import Foundation

/// **Playback addresses and plans for Plex, as pure functions.**
///
/// Swiftly never transcodes, and Plex makes that easy: the original file is at
/// `Part.key`, and a request with the token in the query is served as a plain ranged
/// download (measured: `206`). So the plan is always ``DeliveryMethod/directPlay`` and
/// there is no `decision` call and no transcode session. (`/photo/:/transcode` exists, but
/// only scales pictures.)
public struct PlexPlayback: Sendable {

    public let base: URL
    public let token: String

    public init(base: URL, token: String) {
        self.base = base
        self.token = token
    }

    // MARK: - Addresses

    /// `base` + path + query. The path may contain `:` (`/:/timeline`), which
    /// `appendingPathComponent` would mangle, so the text is joined by hand.
    public func url(path: String, query: [(String, String)] = [], withToken: Bool = false) -> URL? {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        text += path.hasPrefix("/") ? path : "/" + path
        var pairs = query
        if withToken { pairs.append(("X-Plex-Token", token)) }
        if !pairs.isEmpty {
            text += "?" + pairs.map { Self.escape($0.0) + "=" + Self.escape($0.1) }.joined(separator: "&")
        }
        return URL(string: text)
    }

    /// The file itself. For a player this is the address: it cannot set headers, so the
    /// token goes in the query.
    public func fileURL(partKey: String, download: Bool = false) -> URL? {
        url(path: partKey, query: download ? [("download", "1")] : [], withToken: true)
    }

    /// A subtitle next to the file (`Stream.key`); a track inside the container has none
    /// and is opened by the player from the file itself.
    public func subtitleURL(_ stream: PlexStream) -> URL? {
        guard stream.streamType == 3, let key = stream.key else { return nil }
        return url(path: key, withToken: true)
    }

    /// A picture, scaled by the server when a size is given. `path` is what Plex wrote in
    /// `thumb` / `art`; a person's `thumb` is already an absolute address and stays one.
    public func imageURL(path: String, maxHeight: Int? = nil, maxWidth: Int? = nil) -> URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return URL(string: path) }
        guard maxHeight != nil || maxWidth != nil else { return url(path: path, withToken: true) }
        // Measured: the scaler answers `400` unless both `width` and `height` are given, and
        // with `minSize=1` it covers the box instead of fitting into it. So: no `minSize`,
        // and the side the caller left open gets a limit no picture reaches.
        let open = 4096
        let query: [(String, String)] = [("url", path), ("upscale", "0"),
                                         ("width", String(maxWidth ?? open)),
                                         ("height", String(maxHeight ?? open)),
                                         ("quality", "90")]
        return url(path: "/photo/:/transcode", query: query, withToken: true)
    }

    /// Preview pictures when scrubbing: the BIF file of a part (`404` if the server has
    /// not made them).
    public func previewIndexURL(partID: Int) -> URL? {
        url(path: "/library/parts/\(partID)/indexes/sd", withToken: true)
    }

    // MARK: - Plan

    /// Picks the version (``PlexMedia``) and builds the direct play plan.
    ///
    /// - Parameter mediaSourceID: `MediaSource.id` of a version the user chose; without
    ///   it the first version with a file.
    public func plan(for metadata: PlexMetadata, mediaSourceID: String? = nil,
                     audioStreamID: Int? = nil, subtitleStreamID: Int? = nil,
                     sessionID: String = UUID().uuidString) throws -> PlaybackPlan {
        guard let file = Self.file(of: metadata, mediaSourceID: mediaSourceID),
              let address = fileURL(partKey: file.part.key) else {
            throw PlexError.noFile
        }
        let media = file.media, part = file.part
        var source: MediaSource? = PlexMapper().mediaSource(file, duration: metadata.duration)
        // The caller's choice becomes the source's default, so the player starts on it.
        if let audioStreamID { source?.defaultAudioStreamIndex = audioStreamID }
        if let subtitleStreamID { source?.defaultSubtitleStreamIndex = subtitleStreamID }
        return PlaybackPlan(url: address, method: .directPlay,
                            mediaSourceID: file.sourceID, playSessionID: sessionID,
                            container: part.container ?? media.container, reasons: [],
                            source: source)
    }

    /// The part a plan belongs to (needed for progress and track choice).
    public static func part(of metadata: PlexMetadata, mediaSourceID: String?) -> PlexPart? {
        file(of: metadata, mediaSourceID: mediaSourceID)?.part
    }

    /// **Every playable file of a title**, in the order the server lists them. The first
    /// part of a version keeps the plain `Media` id (what was stored and sent before);
    /// further parts of the same version get `<id>-<number>`.
    public static func files(of metadata: PlexMetadata) -> [PlexFile] {
        metadata.media.flatMap { media in
            media.parts.enumerated().map { offset, part in
                PlexFile(media: media, part: part, number: offset + 1,
                         sourceID: offset == 0 ? String(media.id) : "\(media.id)-\(offset + 1)")
            }
        }
    }

    /// The file a source id names; without a (known) id the first one.
    public static func file(of metadata: PlexMetadata, mediaSourceID: String?) -> PlexFile? {
        let all = files(of: metadata)
        return all.first(where: { $0.sourceID == mediaSourceID }) ?? all.first
    }

    // MARK: - Reports

    public enum State: String, Sendable { case playing, paused, buffering, stopped }

    /// The query of `/:/timeline`. Offsets are milliseconds; Swiftly counts ticks.
    public static func timelineQuery(ratingKey: String, state: State, positionTicks: Int64,
                                     durationMilliseconds: Int?) -> [(String, String)] {
        var query: [(String, String)] = [
            ("ratingKey", ratingKey),
            ("key", "/library/metadata/\(ratingKey)"),
            ("state", state.rawValue),
            ("time", String(max(0, positionTicks / 10_000))),
            ("identifier", "com.plexapp.plugins.library"),
        ]
        if let durationMilliseconds, durationMilliseconds > 0 {
            query.append(("duration", String(durationMilliseconds)))
        }
        return query
    }

    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
}

/// One file of a title: a ``PlexPart`` with the ``PlexMedia`` (version) it belongs to.
public struct PlexFile: Sendable, Equatable {
    public let media: PlexMedia
    public let part: PlexPart
    /// 1 for the first part of a version.
    public let number: Int
    /// `MediaSource.id` of this file.
    public let sourceID: String
}
