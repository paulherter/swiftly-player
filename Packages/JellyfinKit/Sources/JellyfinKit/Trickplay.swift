import Foundation

/// Preview images when scrubbing: Jellyfin's **Trickplay** (from 10.9).
///
/// On import the server stores tile sheets: per sheet a grid of
/// `tilesWide × tilesUp` images, one every `interval` milliseconds. It
/// is fetched from the server, not from the stream, so it also works with
/// Direct Play, and playback does not notice.
///
/// The details are on the item under `Trickplay`, but only with
/// `Fields=Trickplay`: `{ mediaSourceId: { "320": { Width, Height, TileWidth,
/// TileHeight, ThumbnailCount, Interval, Bandwidth } } }`. The field names come
/// from `TrickplayInfoDto` in the OpenAPI description.
///
/// **If the server has no Trickplay, there is no `Trickplay`**, and the UI
/// shows only the time when scrubbing, not an empty box.
public struct Trickplay: Sendable, Equatable {
    /// Width of a preview image in pixels, also the path part of the address.
    public let width: Int
    public let height: Int
    public let tilesWide: Int
    public let tilesUp: Int
    public let count: Int
    /// Milliseconds between two preview images.
    public let interval: Int

    public init(width: Int, height: Int, tilesWide: Int, tilesUp: Int,
                count: Int, interval: Int) {
        self.width = width
        self.height = height
        self.tilesWide = tilesWide
        self.tilesUp = tilesUp
        self.count = count
        self.interval = interval
    }

    /// Where the preview image for a position lies.
    public struct Tile: Sendable, Equatable {
        /// Number of the sheet: `/Trickplay/{breite}/{blatt}.jpg`.
        public let sheet: Int
        /// Section within the sheet, in pixels.
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
    }

    /// n = ms / interval, sheet = n / (columns × rows), place in the grid =
    /// n mod (columns × rows), row by row from the top left.
    ///
    /// Past the last image the last one stays, before the start the first; when
    /// scrubbing all the way to the end nothing should go empty.
    public func tile(seconds: Double) -> Tile? {
        let jeSheet = tilesWide * tilesUp
        guard interval > 0, jeSheet > 0, count > 0, width > 0, height > 0,
              seconds.isFinite else { return nil }
        let ms = max(seconds, 0) * 1000
        let n = min(Int(ms) / interval, count - 1)
        let slot = n % jeSheet
        return Tile(sheet: n / jeSheet,
                      x: (slot % tilesWide) * width,
                      y: (slot / tilesWide) * height,
                      width: width, height: height)
    }

    /// Of all offered widths the one closest to a preview of `target` pixels, rather
    /// a bit larger than too small.
    public static func choose(from offering: [Trickplay], target: Int = 320) -> Trickplay? {
        let valid = offering.filter { $0.interval > 0 && $0.count > 0 }
        return valid.filter { $0.width >= target }.min { $0.width < $1.width }
            ?? valid.max { $0.width < $1.width }
    }
}

/// The part of an item response that carries Trickplay.
public struct TrickplayResponse: Sendable, Decodable {
    /// Per source all offered widths.
    public let sources: [String: [Trickplay]]

    enum CodingKeys: String, CodingKey { case trickplay = "Trickplay" }

    private struct Detail: Decodable {
        let Width: Int?
        let Height: Int?
        let TileWidth: Int?
        let TileHeight: Int?
        let ThumbnailCount: Int?
        let Interval: Int?
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: [String: Detail]].self, forKey: .trickplay) ?? [:]
        var sources: [String: [Trickplay]] = [:]
        for (source, widths) in raw {
            sources[source] = widths.compactMap { key, a in
                guard let width = a.Width ?? Int(key), let height = a.Height,
                      let columns = a.TileWidth, let rows = a.TileHeight,
                      let count = a.ThumbnailCount, let interval = a.Interval
                else { return nil }
                return Trickplay(width: width, height: height, tilesWide: columns,
                                 tilesUp: rows, count: count, interval: interval)
            }
        }
        self.sources = sources
    }

    /// The details for the running source; without an ID the only one available.
    public func of(source: String?, target: Int = 320) -> Trickplay? {
        let offering: [Trickplay]?
        if let source, let matching = sources[source] ?? sources[source.lowercased()] {
            offering = matching
        } else if sources.count == 1 {
            offering = sources.first?.value
        } else {
            offering = nil
        }
        return offering.flatMap { Trickplay.choose(from: $0, target: target) }
    }
}
