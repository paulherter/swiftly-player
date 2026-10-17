import Foundation

/// Where one stands in a series, and which season follows from that.
///
/// **Why in the package.** Both used to live in `AppModel` and therefore did not
/// reach Linux and Windows. The season choice is not a display question but a
/// rule: which season is shown is decided by the way onto the page. It must
/// give the same answer on every platform.
public extension JellyfinClient {

    /// The episode one is at in this series.
    ///
    /// If the series is finished or the server has nothing open, the first episode
    /// applies; otherwise the page would have no anchor.
    func stateInSeries(_ seriesID: String) async -> Item? {
        // Swift flattens `try?` of an optional return to **one** level, so `opened` is
        // already an `Item` here, and an additional `opened != nil` would always be
        // true.
        if let opened = try? await nextEpisodeSeries(seriesID: seriesID) {
            return opened
        }
        return try? await firstEpisode(seriesID: seriesID)
    }

    /// The same, but a failed request **throws** instead of coming back as
    /// "nothing there". `nil` now only means: the series has no episodes. For places
    /// that tell the user why nothing starts.
    func stateInSeriesChecked(_ seriesID: String) async throws -> Item? {
        if let opened = try await nextEpisodeSeries(seriesID: seriesID) {
            return opened
        }
        return try await firstEpisode(seriesID: seriesID)
    }
}

/// **Which season is shown on opening.**
///
/// If a hint comes along, the season's ID or number, as on every path from an
/// episode, it applies. If none does, e.g. from the library or from search, the
/// **current** season is shown, not season 1: the main button next to it says
/// "Continue S3E4", and an episode list showing season 1 contradicts it on the
/// same screen. The bug had exactly this shape before: "Play S6E1" on top,
/// season 5 below.
///
/// **ID *and* number are compared.** The server does not always deliver a
/// `SeasonId` on an episode; then the ID comparison hits nothing and only the
/// number still works.
public enum SeasonSelectionRule {

    /// Pure calculation, without a request, so the caller decides when to fetch the
    /// state and can fetch it alongside.
    ///
    /// - Parameters:
    ///   - liste: the seasons of the series, in server order.
    ///   - hintID: the season ID one came through. `nil` without a hint.
    ///   - hintNumber: the season number one came through.
    ///   - stand: where one is in the series; only needed if no hint came.
    public static func choose(from list: [Item],
                              hintID: String? = nil,
                              hintNumber: Int? = nil,
                              state: Item? = nil) -> Item? {
        list.first { $0.id == hintID }
            ?? list.first { $0.indexNumber != nil && $0.indexNumber == hintNumber }
            ?? list.first { $0.id == state?.seasonId }
            ?? list.first { $0.indexNumber != nil && $0.indexNumber == state?.parentIndexNumber }
            ?? list.first
    }

    /// Whether the state has to be fetched at all. Yes without a hint, otherwise no.
    public static func needsState(hintID: String?, hintNumber: Int?) -> Bool {
        hintID == nil && hintNumber == nil
    }
}

public extension JellyfinClient {

    /// **What the head of a page shows when there is no background.**
    ///
    /// For a series, the still of the next episode steps in; that is a real
    /// landscape image and fits the head zone. Only if that is missing too, the
    /// poster is cropped to landscape.
    ///
    /// **Why not just the poster.** A portrait poster cropped into a 380-point head
    /// zone shows a section from the middle of the image, in which usually nothing
    /// can be recognized. An episode still is made for this.
    func headerImageFallback(for item: Item, addresses: ImageAddress,
                        width: Int = 1200) async -> URL? {
        if item.type == "Series" {
            // Not with `??` in one line: its right side is an autoclosure and must not
            // contain `await`.
            var episode = try? await nextEpisodeSeries(seriesID: item.id)
            if episode == nil { episode = try? await firstEpisode(seriesID: item.id) }
            if let episode, let url = ImageSelection.landscape(episode, addresses: addresses,
                                                  width: width)?.url {
                return url
            }
        }
        return ImageSelection.portrait(item, addresses: addresses, maxHeight: width)
    }
}

public extension JellyfinClient {

    /// **The head image in two sizes: large for the backdrop, tiny for the tone.**
    ///
    /// Both must show the same image: the tone is computed from the tiny copy and
    /// colors the surface the large one lies on.
    ///
    /// **Why this exists.** Linux fetched the large one through ``headerImageFallback``
    /// and the tiny one separately through `ImageSelection.landscape`; for a series without a
    /// background the first gave the still of the next episode and the second
    /// nothing. Result: image there, tone not, and under the backdrop a hard edge
    /// against the bare background, on series pages while movie pages were fine.
    /// The Mac does not have the case, because **one** address (`headerImageURL`)
    /// serves both.
    ///
    /// The second reason for a pair instead of two calls: the search for the
    /// substitute costs a request. Called twice, paid twice.
    func headerImagePair(for item: Item, addresses: ImageAddress,
                      large: Int = 1600,
                      small: Int = 16) async -> (large: URL, small: URL)? {
        if let g = ImageSelection.landscape(item, addresses: addresses, width: large)?.url,
           let k = ImageSelection.landscape(item, addresses: addresses, width: small)?.url {
            return (g, k)
        }
        // Not with `??` in one line: its right side is an autoclosure and must not
        // contain `await`.
        if item.type == "Series" {
            var episode = try? await nextEpisodeSeries(seriesID: item.id)
            if episode == nil { episode = try? await firstEpisode(seriesID: item.id) }
            if let episode,
               let g = ImageSelection.landscape(episode, addresses: addresses, width: large)?.url,
               let k = ImageSelection.landscape(episode, addresses: addresses, width: small)?.url {
                return (g, k)
            }
        }
        // **The poster of the item itself, not that of the episode.** An episode
        // carries the series poster as its poster, the same image, one detour more.
        guard let g = ImageSelection.portrait(item, addresses: addresses, maxHeight: large),
              let k = ImageSelection.portrait(item, addresses: addresses, maxHeight: small)
        else { return nil }
        return (g, k)
    }
}
