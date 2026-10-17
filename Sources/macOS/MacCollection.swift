import JellyfinKit
import SwiftUI

// MARK: - Collection page

/// **A collection as a subpage.** Template: `CollectionView` in
/// `Sources/Shared/CollectionDetailPage.swift`.
///
/// A collection page is a library page: arrow, name, filter and sort, grid.
/// So it is `LibraryView` with a collection as source, not a separate
/// type. The default sort is by year, ascending
/// (``Regalquelle/richtung(_:)``), so that a series of films appears in order.
///
/// Sort and filter are **not** remembered: a collection is not a place you
/// return to but a look into a series. The shelf therefore belongs to the
/// page and has no storage name.
struct CollectionDetailPage: View {
    let model: AppModel
    let collection: Item
    /// Whether its movies or its shows are meant. `nil`: everything in it (from
    /// search or watchlist, without a scope).
    let art: String?
    let back: () -> Void

    @State private var shelf: LibraryModel

    init(model: AppModel, collection: Item, art: String?, back: @escaping () -> Void) {
        self.model = model
        self.collection = collection
        self.art = art
        self.back = back
        let shelf = LibraryModel()
        shelf.sorting = .erscheinung
        _shelf = State(initialValue: shelf)
    }

    var body: some View {
        LibraryView(model: model,
                       art: art ?? "movies",
                       title: LocalizedStringKey(collection.name),
                       shelf: shelf,
                       choice: .constant(.all),
                       collection: (collection, art),
                       // For shows, the same sentence as on iPhone.
                       filter: art == "tvshows" ? [.all, .begun, .watchlist]
                                                : LibraryFilter.allCases,
                       back: back)
    }
}

// MARK: - Placeholder poster

/// **Placeholder poster for a collection without its own image**: a mosaic of
/// the posters of its first titles, with the aspect ratio and corners of every
/// `PosterCell`. Template and rationale: `Sammlungsmosaik` in
/// `Sources/Shared/CollectionDetailPage.swift`.
///
/// A single title fills the whole field, two sit side by side, from three on
/// it becomes a 2×2 mosaic. The posters are loaded small (260 pt tall): a
/// mosaic tile does not need an image at tile size.
struct CollectionMosaic: View {
    let model: AppModel
    let collection: ItemCollection
    let art: String
    var width: CGFloat = Theme.tileWidth
    var height: CGFloat = Theme.tileHeight

    @State private var title: [Item] = []

    private var rails: [[Item]] {
        title.isEmpty ? [] : (title.count > 2 ? [Array(title.prefix(2)), Array(title[2...].prefix(2))]
                                               : [title])
    }

    var body: some View {
        let slot = rails.isEmpty ? [[]] : rails
        let railsHeight = (height - CGFloat(slot.count - 1) * 2) / CGFloat(slot.count)
        VStack(spacing: 2) {
            ForEach(Array(slot.enumerated()), id: \.offset) { _, stack in
                row(stack, height: railsHeight)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
        .task(id: collection.id) {
            let found = await model.collectionPosters(collection, art: art)
            withAnimation(Theme.reveal) { title = Array((found ?? []).prefix(4)) }
        }
    }

    private func row(_ stack: [Item], height: CGFloat) -> some View {
        let fieldWidth = stack.isEmpty ? width : (width - CGFloat(stack.count - 1) * 2) / CGFloat(stack.count)
        return HStack(spacing: 2) {
            if stack.isEmpty {
                inputField(url: nil, width: fieldWidth, height: height)
            } else {
                ForEach(stack) { entryRecord in
                    inputField(url: model.imageURL(for: entryRecord, maxHeight: 260, portrait: true),
                         width: fieldWidth, height: height)
                }
            }
        }
    }

    private func inputField(url: URL?, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Theme.area
            NetworkImage(url: url, symbolText: "film", displayEdge: max(width, height))
        }
        .frame(width: width, height: height)
        .clipped()
    }
}

// MARK: - Detail page: part of the collection

/// **The "Teil der Sammlung" row on the movie page**: the other titles of the
/// collection, in order. Its header opens the collection page. Template:
/// `Sammlungsreihe` in `Sources/Shared/CollectionDetailPage.swift`.
///
/// Membership comes from the ``CollectionDirectory``, loaded once per
/// account; only the row's posters are fetched fresh from the server. If the
/// collection is missing, so is the row, as with the extras.
///
/// **The movie page loads the rows, not the row itself.** There all rows sit
/// in a stack with fixed spacing; an empty view that exists only to load would
/// get that spacing too, leaving a gap under the extras. A `ForEach` over
/// nothing takes no space at all.
struct CollectionRail: View {
    typealias Rail = AppModel.CollectionRailsData

    let model: AppModel
    let rail: Rail

    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section
    @State private var hovers = false

    /// Whether its movies or its shows are meant.
    let art: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                navigator.openIt(.collection(rail.collection.item, art: art), in: section)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        RailTitle(text: "Teil der Sammlung")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(hovers ? Theme.font : Theme.fontVeryQuiet)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: rail.collection.item.name)
                        .font(Theme.body)
                        .foregroundStyle(Theme.fontQuiet)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressButton())
            .onHover { hovers = $0 }
            .animation(Theme.timeFloat, value: hovers)

            PagingRail(margin: 0) {
                ForEach(rail.title, id: \.id) { entryRecord in
                    Button { navigator.openIt(.title(entryRecord), in: section) } label: {
                        PosterCell(title: entryRecord.name,
                                     secondLine: entryRecord.productionYear.map { "\($0)" },
                                     image: model.imageURL(for: entryRecord, portrait: true),
                                     progress: entryRecord.userData?.playedPercentage.map { $0 / 100 },
                                     mark: DisplayRules.tileMark(
                                        art: entryRecord.type,
                                        seasons: entryRecord.childCount,
                                        watched: entryRecord.userData?.played,
                                        openEpisodes: entryRecord.userData?.unplayedItemCount),
                                     symbolText: entryRecord.tileCharacter)
                    }
                    .buttonStyle(Theme.PressButton())
                    .tileMenu(entryRecord, model: model)
                }
            }
        }
    }
}
