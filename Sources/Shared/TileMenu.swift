import JellyfinKit
import Observation
import SwiftUI

/// **Watch state as an entry of an action panel**, the same building block as
/// the tile menu, for the detail page's More panel.
///
/// Movie and series pages on Mac and TV had "Watched" as their own extra entry,
/// copied twice and already labeled differently. Now it lives once here, next to
/// the menu that answers the same question on every tile, and uses its wording.
///
/// **One entry that toggles**, not the two of the tile menu: the page knows its
/// state (`watched`) and toggles at once; the state is the answer.
/// If the server says no, it rolls back and reports the reason.
///
/// This part of the file also belongs to the Mac target; the menu itself lives
/// there in `Sources/macOS/TileMenuMac.swift` (right-click instead of long
/// press) and is therefore excluded below.
extension TitleAction {
    @MainActor
    static func watchState(_ item: Item, model: AppModel,
                         watched: Binding<Bool>,
                         report: @escaping (String) -> Void) -> TitleAction {
        TitleAction(symbol: watched.wrappedValue ? "checkmark.circle.fill" : "checkmark.circle",
                      text: watched.wrappedValue ? "Als ungesehen markieren" : "Als gesehen markieren") {
            watched.wrappedValue.toggle()
            Task {
                if let reason = await model.setWatched(item, an: watched.wrappedValue) {
                    watched.wrappedValue.toggle()
                    report(reason)
                }
            }
        }
    }
}

#if !os(macOS)
/// **What a tile menu asks of the app**: play, the load sheet, a message.
///
/// The menu hangs on tiles on Home, Library, Search and others; not every one of
/// those pages has its own player or load sheet. The request therefore goes to a
/// holder for the whole app, and `MainView` carries it out, as with
/// ``SharedModel/wunsch``.
@MainActor
@Observable
final class TileRequest {
    static let shared = TileRequest()

    /// What should be loaded, with title and images for the load sheet.
    struct LoadJob {
        let entries: DownloadItem
        let title: String
        let images: [String: URL]
    }

    var play: PlayRequest?
    var load: LoadJob?
    var loadSheetOpen = false
    var message: String?
}

/// **Long press on a tile: the same menu everywhere.**
///
/// Only "Continue Watching" used to have one (watched/unwatched), the other
/// tiles none. Now every movie, series and episode tile has the same list, with a
/// preview (image, title, year and runtime): play or resume, watched/unwatched,
/// download, watch together, and for "Continue Watching" removal from the row.
///
/// The actions themselves are the existing ones: `PlayRequest.start`,
/// `AppModel.setWatched`, `LoadSheet`, `SharedModel.createFor`.
struct TileMenu: ViewModifier {
    let item: Item
    let model: AppModel
    /// The tile is in "Continue Watching": then there is "Go to overview" (a tap
    /// there starts right away) and "Remove from Continue Watching".
    var continueWatching = false
    /// After a change to the watch state, so the page catches up.
    var afterwards: (() async -> Void)?
    /// The tile is horizontal (16:9, "Continue Watching") instead of portrait.
    var landscape = false
    /// **In the player: watch state only.** Without "Play" and "Watch together": the
    /// row itself already starts the episode, and both would have to replace the
    /// running player. Without "Download": the load sheet would open under the
    /// player. The same rule on the Mac (`Sources/macOS/TileMenuMac.swift`).
    var inPlayer = false

    /// Movies, series and episodes. Collections, people and folders have nothing to
    /// play or tick off.
    static func carries(_ item: Item) -> Bool {
        ["Movie", "Series", "Episode"].contains(item.type ?? "")
    }

    func body(content: Content) -> some View {
        #if os(tvOS)
        // **No preview on TV**: the focused tile already stands large, and tvOS lifts it
        // itself on long press.
        if Self.carries(item) {
            content.contextMenu { entries }
                // If the tile holds focus, `TileStyle` fetches the series' state ahead of time;
                // see `SeriesCache.nextPreload`.
                .environment(\.tilePreload, { [item, model] in
                    await SeriesCache.shared.nextPreload(toward: item, with: model)
                })
        } else {
            content
        }
        #else
        if Self.carries(item) {
            content
                // The shape in which the system lifts and returns the tile, the same corner as
                // the image so mask and image stay one.
                .contentShape(.contextMenuPreview,
                              RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
                .contextMenu {
                entries
            } preview: {
                TilePreview(item: item, model: model, landscape: landscape)
            }
        } else {
            content
        }
        #endif
    }

    private var isSeries: Bool { item.type == "Series" }

    @ViewBuilder
    private var entries: some View {
        if !inPlayer {
            Button { play() } label: {
                if !isSeries, item.resumeFrom != nil {
                    Label("Fortsetzen", systemImage: "play.fill")
                } else {
                    Label("Abspielen", systemImage: "play.fill")
                }
            }
        }
        if continueWatching {
            NavigationLink(value: item) {
                Label("Zur Übersicht", systemImage: "info.circle")
            }
        }
        // **Only the entry that has an effect**, except for series (partly watched) and
        // started titles: an episode that was only skipped through counts as started,
        // and "unwatched" takes it out of "Continue Watching". An entry without effect
        // would be noise, a missing way out a bug.
        let isWatched = item.userData?.played ?? false
        let begun = item.resumeFrom != nil
        if isSeries || !isWatched {
            Button { watched(true) } label: {
                Label("Als gesehen markieren", systemImage: "checkmark.circle")
            }
        }
        if isSeries || isWatched || begun {
            Button { watched(false) } label: {
                Label("Als ungesehen markieren", systemImage: "eye.slash")
            }
        }
        // The TV downloads nothing; there are no downloads there.
        #if !os(tvOS)
        if !isSeries, !inPlayer, model.downloadButtonShow, model.downloads.entries(for: item.id) == nil {
            Button { load() } label: {
                Label("Laden", systemImage: "arrow.down.circle")
            }
        }
        #endif
        if !isSeries, !inPlayer, SharedModel.shared.mayCreate {
            Button { SharedModel.shared.createFor = item } label: {
                Label("Gemeinsam schauen", systemImage: "person.2")
            }
        }
        if continueWatching {
            Button { remove() } label: {
                Label("Aus Weiterschauen entfernen", systemImage: "minus.circle")
            }
        }
    }

    // MARK: Actions

    /// Fetch fresh: the position in the list entry is often stale. For a series, the
    /// episode you are at.
    private func play() {
        let model = model, item = item
        Task {
            var target = item
            if item.type == "Series" {
                // **Failed is not "nothing left".** Without a network this gave the same answer
                // as a series without episodes.
                do {
                    guard let state = try await model.stateInSeriesChecked(item) else {
                        TileRequest.shared.message = String(localized: "Danach kommt nichts mehr.")
                        return
                    }
                    target = state
                } catch {
                    TileRequest.shared.message = readableError(error)
                    return
                }
            }
            PlayRequest.start(target, freshValue: true, model: model, prepares: .constant(false),
                                  missing: {
                                      // Instead of silence when the server has no file.
                                      TileRequest.shared.message = String(localized: "Der Server hat keine Datei zu diesem Titel.")
                                  }) {
                TileRequest.shared.play = $0
            }
        }
    }

    private func watched(_ an: Bool) {
        let model = model, item = item, afterwards = afterwards
        Task {
            if let error = await model.setWatched(item, an: an) {
                TileRequest.shared.message = error
                return
            }
            await afterwards?()
        }
    }

    private func remove() {
        let model = model, item = item, afterwards = afterwards
        Task {
            if let error = await model.fromContinueWatchingTake(item) {
                TileRequest.shared.message = error
                return
            }
            await afterwards?()
        }
    }

    /// Fetched fresh because rows and search deliver their titles without file
    /// details; the load sheet needs size and container.
    private func load() {
        let model = model, item = item
        Task {
            guard let account = model.session?.userID else { return }
            let title = await model.item(id: item.id) ?? item
            let source = title.mediaSources?.first
            let episode = title.type == "Episode"
            let entries = DownloadItem(
                id: title.id, account: account, art: episode ? .episode : .film, title: title.name,
                series: episode ? title.seriesName : nil, seriesIdentifier: episode ? title.seriesId : nil,
                season: episode ? title.parentIndexNumber : nil,
                episode: episode ? title.indexNumber : nil,
                runtimeTicks: title.runTimeTicks, container: source?.container,
                source: source?.id, bytes: source?.size ?? 0,
                watchState: title.userData, videoCodec: source?.videoCodec)
            var images: [String: URL] = [:]
            if episode {
                if let sid = title.seriesId,
                   let poster = model.imageURL(for: title, maxHeight: 600, portrait: true) {
                    images[sid] = poster
                }
                if let landscape = model.landscapeImageURL(for: title) { images[title.id] = landscape }
            } else if let poster = model.posterURL(itemID: title.id,
                                                   mark: title.imageTags?["Primary"]) {
                images[title.id] = poster
            }
            TileRequest.shared.load = .init(entries: entries, title: title.name, images: images)
            TileRequest.shared.loadSheetOpen = true
        }
    }
}

#if !os(tvOS)
/// **The preview above the menu**: landscape image, below it the title and the
/// details you want before tapping: year and runtime, for an episode season,
/// episode and its name.
private struct TilePreview: View {
    let item: Item
    let model: AppModel
    let landscape: Bool

    /// **The same image as the tile, in the same aspect ratio.** Before, a larger
    /// 16:9 landscape image was used: it was not in the cache, the menu opened empty,
    /// and on spring-back the system scaled a 16:9 image into a 2:3 tile, showing an
    /// edge left and right for a moment. Now the same address (the cache answers at
    /// once, `ImageCache`) and the same shape, only larger.
    private var address: URL? {
        let poster = model.imageURL(for: item, maxHeight: 500, portrait: true)
        return landscape ? (model.landscapeImageURL(for: item) ?? poster) : poster
    }
    private var width: CGFloat { landscape ? 320 : 220 }
    private var height: CGFloat { landscape ? width * 9 / 16 : width * 3 / 2 }

    private var row: String {
        if item.type == "Episode" {
            var parts: [String] = []
            if let abbreviation = item.episodeCode { parts.append(abbreviation) }
            parts.append(item.name)
            if let s = item.runtimeSeconds, s > 0 { parts.append(runtime(s)) }
            return parts.joined(separator: " · ")
        }
        return item.secondaryLine
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picture(url: address, width: width, height: height, corner: 0)
                .frame(width: width, height: height)
                .clipped()
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.seriesName ?? item.name)
                    .font(Theme.listTitle)
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
                if !row.isEmpty {
                    Text(verbatim: row)
                        .font(Theme.small)
                        .monospacedDigit()
                        .foregroundStyle(Theme.fontQuiet)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: width, alignment: .leading)
        }
        .background(Theme.reason)
        #if DEBUG
        .onAppear {
            AppLog.writeOut("[Kachelmenü] Vorschau \(Int(width))×\(Int(height)) · "
                + (landscape ? "16:9" : "2:3") + " · Bild im Speicher: "
                + (address.flatMap { ImageCache.shared.image($0) } != nil ? "ja" : "nein"))
        }
        #endif
    }
}

#endif

extension View {
    /// The tile menu; see ``TileMenu``.
    func tileMenu(_ item: Item, model: AppModel, continueWatching: Bool = false,
                     landscape: Bool = false, inPlayer: Bool = false,
                     afterwards: (() async -> Void)? = nil) -> some View {
        modifier(TileMenu(item: item, model: model, continueWatching: continueWatching,
                             afterwards: afterwards, landscape: landscape, inPlayer: inPlayer))
    }
}
#endif
