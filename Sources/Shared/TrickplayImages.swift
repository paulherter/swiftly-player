import CoreGraphics
import ImageIO
import JellyfinKit
import SwiftUI

/// **The preview image above the bar when scrubbing**, cut out of Jellyfin's
/// trickplay sheets.
///
/// Which tile belongs to which position is computed by ``Trickplay`` in the
/// package. Only fetching, decoding and the cache live here: a sheet carries a
/// hundred images, and someone scrubbing mostly stays on one or two sheets. A
/// sheet is therefore fetched exactly once.
@MainActor @Observable
final class TrickplayImages {
    /// `nil`: the server has none, or it is not known yet. Then the bar shows only
    /// the time.
    private(set) var detail: Trickplay?
    private var title: String?
    private var source: String?

    /// Decoded sheets, by number. A sheet of 10x10 tiles at 320x180 is about 9 MB;
    /// we keep no more than a handful.
    @ObservationIgnored private var leaves: [Int: CGImage] = [:]
    @ObservationIgnored private var railsEpisode: [Int] = []
    @ObservationIgnored private var onTheGo: Set<Int> = []
    private static let atMost = 6
    /// Counts arriving sheets so the view redraws.
    private(set) var state = 0

    /// Check once for a new title whether trickplay exists.
    func load(model: AppModel, item: Item, plan: PlaybackPlan) async {
        guard title != item.id else { return }
        title = item.id
        source = plan.mediaSourceID
        detail = nil
        leaves = [:]
        railsEpisode = []
        onTheGo = []
        let found = await model.trickplay(for: item.id, source: plan.mediaSourceID)
        // If the next title came in the meantime, this no longer belongs here.
        guard title == item.id else { return }
        detail = found
        AppLog.writeOut("[Trickplay] \(item.id): "
            + (found.map { "\($0.width)px, \($0.count) Bilder, alle \($0.interval) ms" } ?? "keins"))
    }

    /// The image for the position, or `nil` while its sheet is still on the way. If
    /// it is missing, it is requested.
    func image(at seconds: Double, model: AppModel) -> CGImage? {
        _ = state
        guard let detail, let title, let tile = detail.tile(seconds: seconds) else { return nil }
        guard let sheet = leaves[tile.sheet] else {
            demand(tile.sheet, detail: detail, title: title, model: model)
            return nil
        }
        return sheet.cropping(to: CGRect(x: tile.x, y: tile.y,
                                         width: tile.width, height: tile.height))
    }

    private func demand(_ number: Int, detail: Trickplay, title: String, model: AppModel) {
        guard !onTheGo.contains(number) else { return }
        onTheGo.insert(number)
        let source = source
        Task {
            let data = await model.trickplaySheet(title, source: source,
                                                   width: detail.width, sheet: number)
            let image = await Task.detached(priority: .userInitiated) {
                Self.decrypt(data)
            }.value?.image
            guard self.title == title else { return }
            onTheGo.remove(number)
            guard let image else { return }
            leaves[number] = image
            railsEpisode.append(number)
            if railsEpisode.count > Self.atMost {
                leaves[railsEpisode.removeFirst()] = nil
            }
            state += 1
        }
    }

    /// Off the main thread: a sheet is 3200x1800 pixels.
    nonisolated private static func decrypt(_ data: Data?) -> SheetBox? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return SheetBox(image: image)
    }
}

/// `CGImage` is immutable, just not declared `Sendable`.
private struct SheetBox: @unchecked Sendable { let image: CGImage }
