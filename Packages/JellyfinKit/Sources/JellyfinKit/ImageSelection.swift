import Foundation

/// **Which image a tile shows: the rule, once.**
///
/// It used to live in `AppModel`, unreachable for Linux because `AppModel` is SwiftUI.
/// Here it has no UI and no translation, so it is the same everywhere and testable;
/// this is exactly the case where logic belongs in the package.
/// Two rules; each exists for a reason explained below.
public enum ImageSelection {

    /// The landscape image of a “continue watching” tile.
    ///
    /// **Why a chain and not one line.** Before, this used the series background via the
    /// index, without a tag. If the series has none, Jellyfin answers 404 and the tile
    /// stayed empty.
    ///
    /// Verified against the server: an **episode never has its own background**;
    /// `BackdropImageTags` is always empty for it. The background belongs to the series
    /// and arrives as `ParentBackdropImageTags`, a field nobody read for a long time.
    ///
    /// Each step is only taken if its **tag** is present. A tag is Jellyfin's proof that
    /// the image exists; without it the code would guess and collect 404s that look like
    /// an empty image.
    ///
    /// Also returns which step applied besides the URL; it goes to the log if a tile stays
    /// empty after all.
    public static func landscape(_ item: Item, addresses: ImageAddress,
                            width: Int = 600) -> (url: URL, source: String)? {
        let mass = ImageMetric.atMostWide(width)

        func attempt(_ source: String, _ id: String?, _ art: ImageKind,
                     _ mark: String?) -> (URL, String)? {
            guard let id, let mark,
                  let url = addresses.construct(itemID: id, art: art, mark: mark, mass: mass)
            else { return nil }
            return (url, source)
        }

        let chain: [(URL, String)?] = [
            // 1 · The series background, the closest thing to a cover.
            attempt("Serienhintergrund",
                    item.parentBackdropItemId ?? item.seriesId,
                    .background, item.parentBackdropImageTags?.first),
            // 2 · Own background. The normal case for movies.
            attempt("eigener Hintergrund", item.id, .background,
                    item.backdropImageTags?.first),
            // 3 · The series' landscape thumbnail.
            attempt("Serienvorschau", item.parentThumbItemId ?? item.seriesId,
                    .preview, item.parentThumbImageTag),
            // 4 · The own thumbnail.
            attempt("eigene Vorschau", item.id, .preview,
                    item.imageTags?["Thumb"]),
            // 5 · The still of the episode. Weaker as a cover, hence last and not first,
            //     but still an image.
            item.seriesId != nil
                ? attempt("Folgenstandbild", item.id, .poster,
                          item.imageTags?["Primary"])
                : nil,
        ]

        return chain.compactMap { $0 }.first.map { (url: $0.0, source: $0.1) }
    }

    /// **The image for the head of a page: only what is really landscape.**
    ///
    /// Own background, the series', then the thumbnails. If nothing comes out, the app keeps
    /// searching (episode, then poster); that needs a query and is not done here. Before, the
    /// head only took the own background, and a series without one had an empty head.
    public static func header(_ item: Item, addresses: ImageAddress, width: Int = 1200) -> URL? {
        let mass = ImageMetric.atMostWide(width)
        let chain: [(String?, ImageKind, String?)] = [
            (item.id, .background, item.backdropImageTags?.first),
            (item.parentBackdropItemId ?? item.seriesId, .background, item.parentBackdropImageTags?.first),
            (item.id, .preview, item.imageTags?["Thumb"]),
            (item.parentThumbItemId ?? item.seriesId, .preview, item.parentThumbImageTag),
        ]
        for (id, art, mark) in chain {
            if let id, let mark, let url = addresses.construct(itemID: id, art: art, mark: mark, mass: mass) {
                return url
            }
        }
        return nil
    }

    /// The portrait poster of a 2 : 3 tile.
    ///
    /// **For an episode, the series poster.** An episode's own image is a 16 : 9 still and
    /// would be cropped beyond recognition in a 2 : 3 tile.
    /// **The head image with fallback**: `header`, else for a series the landscape image of
    /// the episode that plays next (or the first), else the poster at head size.
    ///
    /// Lived in `AppModel.headerImageFallbackSearch` and so only on Apple. The Android facade
    /// jumped from the background straight to the poster: for a series without background it
    /// showed the poster on top, the iPhone a still from the episode. Fetching the episode
    /// stays with the caller; this only decides which image applies.
    public static func headerWithFallback(_ item: Item, episode: Item?, addresses: ImageAddress,
                                     width: Int = 1200) -> URL? {
        if let url = header(item, addresses: addresses, width: width) { return url }
        if item.type == "Series", let episode,
           let url = landscape(episode, addresses: addresses, width: width)?.url {
            return url
        }
        return portrait(item, addresses: addresses, maxHeight: width)
    }

    /// The logo of a title; for episodes, the series'. `nil` if the server has none.
    public static func logo(_ item: Item, addresses: ImageAddress, maxHeight: Int = 240) -> URL? {
        let source: (id: String, mark: String)?
        if let series = item.seriesId, let mark = item.parentLogoImageTag {
            source = (series, mark)
        } else if let mark = item.imageTags?["Logo"] {
            source = (item.id, mark)
        } else {
            source = nil
        }
        guard let source else { return nil }
        return addresses.construct(itemID: source.id, art: .logo, mark: source.mark,
                              mass: .atMostHigh(maxHeight))
    }

    public static func portrait(_ item: Item, addresses: ImageAddress,
                                maxHeight: Int = 480) -> URL? {
        let source: (id: String, mark: String)?
        if let series = item.seriesId, let mark = item.seriesPrimaryImageTag {
            source = (series, mark)
        } else if let mark = item.imageTags?["Primary"] {
            source = (item.id, mark)
        } else {
            source = nil
        }
        guard let source else { return nil }
        return addresses.construct(itemID: source.id, mark: source.mark,
                              mass: .atMostHigh(maxHeight))
    }
}
