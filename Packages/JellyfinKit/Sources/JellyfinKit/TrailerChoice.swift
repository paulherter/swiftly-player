import Foundation

/// One way to show a trailer: a file on the server, or a page on the web.
public enum TrailerCandidate: Sendable, Equatable {
    /// A trailer the server keeps as its own file (Jellyfin and Emby `LocalTrailers`,
    /// Plex extras of kind trailer). Plays in the app's own player, Direct Play like
    /// everything else.
    case file(Item)
    /// A link the metadata carries (almost always YouTube). Only a browser can open it.
    case web(URL)
}

/// **Which trailer a title offers, and in which order to try them.**
///
/// This stood four times, slightly different each time: iPhone and iPad took the first
/// file or the first link, the Mac and Linux the same, Android phone only the link (the
/// file was never asked), Android TV and Apple TV only the file. Two things never
/// worked anywhere:
///
/// - **Several trailers.** Only the first file was tried. If its playback plan failed
///   (the file is in a container the server cannot describe, or it moved), the next
///   file and the link stayed unused although they were right there.
/// - **Links the browser cannot open.** Kodi-style NFO files carry
///   `plugin://plugin.video.youtube/?action=play_video&videoid=…`, which no browser
///   opens; "Trailer" then did nothing at all. Such a link is turned into the YouTube
///   page it stands for; anything that is not `http(s)` is dropped.
///
/// Files come first, in the server's order, then links. A platform that cannot open a
/// link (Apple TV, Android TV: no browser) passes `canOpenWeb: false` and gets files
/// only.
public enum TrailerChoice {

    public static func candidates(local: [Item], remote: [MediaURL]?,
                                  canOpenWeb: Bool) -> [TrailerCandidate] {
        var result: [TrailerCandidate] = []
        var seenFiles = Set<String>()
        for item in local where !item.id.isEmpty && seenFiles.insert(item.id).inserted {
            result.append(.file(item))
        }
        guard canOpenWeb else { return result }
        var seenLinks = Set<URL>()
        for link in remote ?? [] {
            if let url = webAddress(link.url), seenLinks.insert(url).inserted {
                result.append(.web(url))
            }
        }
        return result
    }

    /// The files among the candidates.
    public static func files(in candidates: [TrailerCandidate]) -> [Item] {
        candidates.compactMap { if case .file(let item) = $0 { item } else { nil } }
    }

    /// The extras shelf of a title page on a screen without a browser (Apple TV, Android
    /// TV): the trailers lead, then the server's extras. A trailer the server also lists
    /// among its extras appears once.
    public static func shelf(trailers: [Item], extras: [Item]) -> [Item] {
        var seen = Set<String>()
        return (trailers + extras).filter { seen.insert($0.id).inserted }
    }

    /// The page a link stands for, or `nil` if a browser could not open it.
    public static func webAddress(_ raw: String?) -> URL? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        if let id = youtubeID(inPluginLink: text) {
            return URL(string: "https://www.youtube.com/watch?v=\(id)")
        }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// `plugin://plugin.video.youtube/?action=play_video&videoid=ID` and the newer
    /// `plugin://plugin.video.youtube/play/?video_id=ID`.
    private static func youtubeID(inPluginLink text: String) -> String? {
        guard text.lowercased().hasPrefix("plugin://plugin.video.youtube"),
              let parts = URLComponents(string: text) else { return nil }
        let id = parts.queryItems?.first { $0.name == "videoid" || $0.name == "video_id" }?.value
        guard let id, !id.isEmpty,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return id
    }
}

extension MediaServer {

    /// Everything that can play as this title's trailer, in the order to try it.
    ///
    /// `item` should be the fresh title (`item(id:)`): list answers leave out
    /// `RemoteTrailers` on purpose. The file lookup failing (offline, 404) is not an
    /// error here - the links may still be there.
    public func trailerCandidates(for item: Item, canOpenWeb: Bool) async -> [TrailerCandidate] {
        let files = (try? await trailer(toward: item.id)) ?? []
        return TrailerChoice.candidates(local: files, remote: item.remoteTrailers,
                                        canOpenWeb: canOpenWeb)
    }
}
