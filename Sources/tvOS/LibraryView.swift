import JellyfinKit
import SwiftUI

/// A library as a grid: seven columns at 1920 pt.
///
/// One row of chips, not two. Sorting used to be a second chip set, but four
/// chips where exactly one is always on is a choice, not a filter, and two
/// rows of identical-looking capsules with different meanings cluttered the page.
///
/// Now: the library capsule first (only with two or more), then filter and
/// sorting as one capsule each with an icon, the count on the right. This
/// matches the iPhone pills (`ValuePill`). Each capsule shows its current
/// value and opens its choice in place.
///
/// No filter chips: the iPhone uses a button that names the filter and opens
/// a sheet, and the tvOS chip row was replaced to match.
///
/// No header block: home and detail pages show title, facts and description
/// of one title. A library shows a collection, so there is nothing for a
/// hero image to carry. The backdrop is described at `reasonAudio`.
struct LibraryView: View {
    let model: AppModel
    /// Either by kind ("movies", "tvshows") from the top bar ...
    var art: String?
    /// ... or as a named library via the jump path ...
    var library: Item?
    /// ... or as a collection. A collection page is a library page, as on the iPhone
    /// (`CollectionView`): name, filter and sorting, grid. It sorts by year ascending
    /// (``Regalquelle/richtung(_:)``) so a series reads in order. Nothing is
    /// remembered: a collection is a look into a series, not a place to return to.
    var collection: Item?
    var filter: [LibraryFilter] = LibraryFilter.allCases

    /// Paging, filtering and sorting live in `LibraryModel`, shared with the iPhone version.
    @State private var state: LibraryModel
    /// Which panel is open (at most one). The same id tells on close which capsule gets focus back.
    @State private var openPanel: Panel?
    /// What the first capsule selected: "All", "Collections", then the libraries, like the
    /// iPhone title menu. The rule is in ``SectionOffering``. Only when the view
    /// came in by kind; via the jump path the library is named and there is nothing to choose.
    @State private var choice: SectionSelection = .all
    /// What was loaded from last. If the source changes under the same choice
    /// (a mixed library arrives later), it reloads.
    @State private var loadedSource: String?
    @FocusState private var atTrigger: Panel?

    private enum Panel: Hashable {
        case library, filter, sorting

        /// Name of the button the panel hangs from; see `PanelAnchor`.
        var firer: String {
            switch self {
            case .library: "bibliothek"
            case .filter:     "filter"
            case .sorting: "sortierung"
            }
        }
    }
    /// Which tile has focus and which had it last, like `lastAtTitle` in `HomeView`.
    /// `atTitle` becomes `nil` when a detail page opens; `lastAtTitle` keeps the title.
    @FocusState private var atTitle: String?
    @State private var lastAtTitle: String?
    /// Sorting or filter changed and the response is pending: the grid keeps the old order, dimmed.
    @State private var switchedOver = false

    /// The storage name is fixed at creation; see `LibraryModel`. A named library
    /// remembers its own sorting, a kind remembers its kind's.
    init(model: AppModel, art: String? = nil, library: Item? = nil,
         collection: Item? = nil,
         filter: [LibraryFilter] = LibraryFilter.allCases) {
        self.model = model
        self.art = art
        self.library = library
        self.collection = collection
        // For series, the same sentence as on the series library.
        self.filter = collection != nil && art == "tvshows"
            ? [.all, .begun, .watchlist] : filter
        let state = LibraryModel(rememberName: collection == nil ? (library?.id ?? art) : nil)
        if collection != nil { state.sorting = .erscheinung }
        _state = State(initialValue: state)
    }
    @Environment(\.panelOpen) private var panelOpen

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Theme.gridColumn),
              count: Theme.gridColumns)
    }

    var body: some View {
        ZStack {
            if state.loads, choice != .collections {
                // No spinner: the grid already has its shape and is cross-faded once the titles arrive.
                GridPlaceholder()
                    .padding(.horizontal, Theme.edgePage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, Theme.gridTop)
                    .transition(.opacity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.capsuleRailPadding) {
                        if let collection {
                            // The name comes from the server and is not translated, like the genre page title.
                            RailTitle(name: collection.name)
                                .padding(.horizontal, Theme.edgePage)
                        }
                        chipRail

                        if choice == .collections {
                            // The list is already in memory: "Collections" only appears in the panel if there are any.
                            collectionGrid
                        } else if state.items.isEmpty {
                            empty
                        } else {
                            lattice
                                .opacity(switchedOver ? 0.4 : 1)
                                .animation(Theme.reveal, value: switchedOver)
                        }
                    }
                    // The capsule row starts at `Theme.contentTop`, where the title starts on the home
                    // page, minus the top safe area where the scroll area begins.
                    // The collection page carries its name above and so starts like the genre page.
                    .padding(.top, collection != nil
                             ? Theme.headerOffsetDetail + 40 - Theme.edgeTop
                             : library == nil
                             ? Theme.contentTop - Theme.edgeTop
                             : Theme.edgeTop)
                    .padding(.bottom, 60)
                }
                .scrollIndicators(.hidden)
                // The look's glow, the same on every main page; goes up with the content.
                .lookGlow()
                // Back means: onto the title that was open. Without a preference tvOS picks a tile
                // itself at the top of the visible area, one or two rows above the opened title.
                // Same solution as `HomeView`: remember the title, `userInitiated` overrides the
                // system choice. On first open nothing is remembered and system focus stays.
                .defaultFocus($atTitle, lastAtTitle,
                              priority: lastAtTitle == nil ? .automatic : .userInitiated)
                .onChange(of: atTitle) { _, now in
                    if let now { lastAtTitle = now }
                }
            }
        }
        // A different list: the remembered title no longer belongs to it.
        .onChange(of: state.identifier) { lastAtTitle = nil; switchedOver = true }
        .onChange(of: choice) { lastAtTitle = nil }
        // Collections and mixed libraries arrive later (from `offeringLoad()`). If that changes
        // what "All" reads or what may be selected, reload.
        .onChange(of: offeringId) { _, _ in
            guard overGenre else { return }
            let new = model.sectionSelection(art: art ?? "")
            guard new != choice || source?.key != loadedSource else { return }
            choice = new
            Task { await load() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(reasonAudio.ignoresSafeArea())
        // Side margin: see `HomeView`. The system margin is dropped so `edgePage` does not double it.
        .ignoresSafeArea(edges: .horizontal)
        // Nothing behind the open panel is focusable; see the detail pages, same bug there.
        .disabled(openPanel != nil)
        // Below its trigger, at its edge; see `PanelAnchor`.
        //
        // Two overlays with fixed offsets (`Theme.edgePage` sideways, `Theme.erstesEnde + 16`
        // down) were meant from the image edge, but an overlay is measured from the safe
        // area (80 pt sideways, 60 pt up). Measured in the simulator, both were off by exactly
        // the safe margin.
        .panel(under: openPanel?.firer) {
            ActionPanel(actions: panelContent.actions,
                           opened: panelBinding,
                           selected: panelContent.selected,
                           category: panelCategory)
                .transition(.opacity)
        }
        .animation(Theme.motion(.easeInOut(duration: 0.18)), value: openPanel)
        // The page disables itself, but the top bar is not its own: `MainView` must disable it,
        // otherwise focus climbs out of the open panel onto the section buttons.
        // After closing, focus returns to the capsule that opened it.
        .onChange(of: openPanel) { alt, new in
            panelOpen.wrappedValue = new != nil
            if new == nil, let alt { atTrigger = alt }
        }
        // Leaving the page with a panel open would leave the bar dead.
        .onDisappear { panelOpen.wrappedValue = false }
        .animation(Theme.reveal, value: state.loads)
        // The account switch belongs in the id too. `state.identifier` covers library, filter and
        // sorting, none of which change on a switch, so the page kept the previous account's
        // titles and their checkmarks. iPhone and iPad attach the counter already.
        .task(id: "\(state.identifier)|\(model.accountSwitch)|\(model.listenRefresh)") { await load() }
    }

    /// One backdrop for all library pages.
    ///
    /// There used to be a gradient per section (series in the accent, movies in the
    /// complement) so one could tell where one is. It is dropped: the top bar already says
    /// so in words, and the watchlist, the same kind of page, never had a gradient, so three
    /// library pages looked like three different apps. Plain grey it is.
    ///
    /// Color stays where it means something: on the selected filter, on progress, on the
    /// checkmark. Not under everything.
    private var reasonAudio: some View {
        Theme.reason.ignoresSafeArea()
    }

    /// What the open panel shows and which row is current.
    private var panelContent: (actions: [TitleAction], selected: Int?) {
        switch openPanel {
        case .filter:
            (filterActions, filter.firstIndex(of: state.filter))
        case .sorting:
            (sortActions, Sorting.allCases.firstIndex(of: state.sorting))
        case .library, nil:
            (libraryActions, offering.entries.firstIndex(of: choice))
        }
    }

    /// The filters as a panel: same icons as sorting and library choice, same entries as on the iPhone.
    private var filterActions: [TitleAction] {
        filter.map { f in
            TitleAction(symbol: state.filter == f ? "checkmark.circle.fill" : "circle",
                          text: "\(f.label)") { state.filter = f }
        }
    }

    /// The sort options as an action panel, not a second chip set.
    private var sortActions: [TitleAction] {
        Sorting.allCases.map { s in
            TitleAction(symbol: state.sorting == s ? "checkmark.circle.fill" : "circle",
                          text: "\(s.label)") { state.sorting = s }
        }
    }

    /// The title menu as a panel: All, Collections, divider, libraries. Library names come
    /// from the server and are shown verbatim; see `TitleAction.wortlaut`.
    private var libraryActions: [TitleAction] {
        offering.entries.map { entryRecord in
            TitleAction(symbol: entryRecord == choice ? "checkmark.circle.fill" : "circle",
                          wording: label(entryRecord)) {
                guard entryRecord != choice else { return }
                model.sectionSelect(entryRecord, art: art ?? "")
                choice = entryRecord
                Task { await load() }
            }
        }
    }

    /// Where in the panel the "Libraries" section is.
    private func panelCategory(_ row: Int) -> LocalizedStringKey? {
        guard openPanel == .library,
              offering.entries.indices.contains(row),
              offering.entries[row] == offering.firstLibrary else { return nil }
        return "Bibliotheken"
    }

    /// `Handlungstafel` only knows open or closed; closed here means no panel.
    private var panelBinding: Binding<Bool> {
        Binding(get: { openPanel != nil },
                set: { if !$0 { openPanel = nil } })
    }

    // MARK: Parts

    private var chipRail: some View {
        HStack(alignment: .center, spacing: 20) {
            // The library comes first, as a capsule, and only with two or more. It used to be one
            // chip per library; with eight libraries they filled the row, and two chip sets with
            // different meaning looked the same. Now the capsule names the selected one and opens
            // the rest as a panel, like sorting. It is the iPhone title menu: All, Collections,
            // divider, libraries. The capsule shows "All Movies" rather than just "Movies": here the top
            // bar already says where one is, and the capsule is a choice next to filter and sorting.
            if overGenre, offering.isMenu {
                Button { openPanel = .library } label: {
                    Text(verbatim: label(choice))
                }
                .buttonStyle(CapsuleStyle())
                .focused($atTrigger, equals: .library)
                .panelTrigger(Panel.library.firer)
                .accessibilityLabel(Text("Bibliothek, \(label(choice))"))

                // A vertical divider instead of spacing: choice and filter side by side would otherwise
                // read as one row. Without a filter ("Collections") it separates nothing and is dropped.
                if choice != .collections { CapsuleSeparator() }
            }

            // Filter and sorting side by side, with icons, like the two `ValuePill`s on the iPhone,
            // same icons in the same order. For "Collections" only the count shows, since the list
            // needs neither filtering nor sorting (`ShelfControls.onlyCount`). The row keeps its height, see below.
            if choice != .collections {
                Button { openPanel = .filter } label: {
                    Text(verbatim: state.filter.label)
                }
                .buttonStyle(CapsuleStyle(symbol: "line.3.horizontal.decrease"))
                .focused($atTrigger, equals: .filter)
                .panelTrigger(Panel.filter.firer)
                .accessibilityLabel(Text("Filter, \(state.filter.label)"))

                Button { openPanel = .sorting } label: {
                    Text(verbatim: state.sorting.label)
                }
                .buttonStyle(CapsuleStyle(symbol: "arrow.up.arrow.down"))
                .focused($atTrigger, equals: .sorting)
                .panelTrigger(Panel.sorting.firer)
                .accessibilityLabel(Text("Sortierung, \(state.sorting.label)"))
            }

            Spacer(minLength: 40)

            // The count is the only information a library can give about itself.
            if choice == .collections {
                if !collectionList.isEmpty {
                    Text("\(collectionList.count) Sammlungen")
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontVeryQuiet)
                }
            } else if state.total > 0 {
                Text("\(state.total) Titel")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
            }
        }
        // Same height with and without capsules. For "Collections" filter and sorting are missing;
        // without a fixed height the row would shift up on switch and the grid would jump along
        // (`ShelfControls` avoids this on the iPhone with `minHeight`).
        .frame(height: Theme.chipHeight)
        .focusSection()
        .padding(.horizontal, Theme.edgePage)
    }

    private var lattice: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.latticeRow) {
            ForEach(state.items) { item in
                NavigationLink(value: item) {
                    TileContent(image: model.imageURL(for: item, maxHeight: 600,
                                                      portrait: true),
                                 title: item.name,
                                 progress: item.userData?.playedPercentage
                                     .map { $0 / 100 },
                                 withUnderRow: false,
                                 mark: DisplayRules.tileMark(
                                    art: item.type,
                                    seasons: item.childCount,
                                    watched: item.userData?.played,
                                    openEpisodes: item.userData?.unplayedItemCount),
                                 symbolText: item.tileCharacter)
                }
                .buttonStyle(TileStyle())
                .tileMenu(item, model: model)
                .focused($atTitle, equals: item.id)
                // Load more as soon as one of the last three rows appears, so the next page is there before focus reaches the bottom.
                .onAppear {
                    guard state.solvesLoadMoreOut(item.id, columns: Theme.gridColumns)
                    else { return }
                    Task { await loadMore() }
                }
            }
        }
        .padding(.horizontal, Theme.edgePage)
        // Otherwise the focus ring of the outer columns sits under the edge.
        .scrollClipDisabled()
    }

    /// A failure is not empty.
    ///
    /// `LibraryModel.disrupted` was in the model but not read here: when the server did
    /// not answer, the page said "nothing here yet", an unchecked claim about server content.
    /// Now it shows what `HomeView` shows: the server address and the question that helps.
    @ViewBuilder
    private var empty: some View {
        if state.disrupted {
            EmptyState(
                symbol: "externaldrive.badge.xmark",
                title: "Server ist abgetaucht",
                hint: "\(model.serverAddress ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                button: ("Erneut versuchen", { Task { await load() } }))
            .frame(height: 500)
        } else {
            EmptyState(
                symbol: state.filter == .all ? "tray" : "line.3.horizontal.decrease",
                title: state.filter == .all ? "Hier ist noch nichts" : "Nichts gefunden",
                hint: state.filter != .all
                    ? "Unter diesem Filter liegt gerade nichts."
                    : collection != nil
                    ? "Sobald in dieser Sammlung etwas liegt, taucht es hier auf."
                    : "Sobald in dieser Bibliothek etwas liegt, taucht es hier auf.",
                button: state.filter == .all
                    ? ("Aktualisieren", { Task { await load() } })
                    : ("Filter zurücksetzen", { state.filter = .all }))
            .frame(height: 500)
        }
    }

    // MARK: Collections

    /// Collections in the same grid with the same tile. The name is followed by how many
    /// movies or series it holds, like on the iPhone. Without its own image the tile shows
    /// a mosaic of the first posters (`Sammlungsmosaik`).
    private var collectionGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.latticeRow) {
            ForEach(collectionList) { entryRecord in
                NavigationLink(value: CollectionRoute(collection: entryRecord.item, art: art)) {
                    TileContent(image: model.imageURL(for: entryRecord.item, maxHeight: 600,
                                                      portrait: true),
                                 title: entryRecord.item.name,
                                 subline: countText(entryRecord.count(art: art ?? "")),
                                 substitute: entryRecord.item.imageTags?["Primary"] == nil
                                     ? CollectionMosaic(model: model, collection: entryRecord,
                                                       art: art ?? "")
                                     : nil)
                }
                .buttonStyle(TileStyle())
                .focused($atTitle, equals: entryRecord.id)
            }
        }
        .padding(.horizontal, Theme.edgePage)
        .scrollClipDisabled()
    }

    private var collectionList: [ItemCollection] {
        model.collectionDirectory?.collections(art: art ?? "") ?? []
    }

    private func countText(_ n: Int) -> String {
        art == "tvshows" ? String(localized: "\(n) Serien") : String(localized: "\(n) Filme")
    }

    private func label(_ w: SectionSelection) -> String {
        switch w {
        case .all:
            art == "tvshows" ? String(localized: "Alle Serien") : String(localized: "Alle Filme")
        case .collections:
            String(localized: "Sammlungen")
        case .library(let id):
            offering.library(id)?.name ?? ""
        }
    }

    // MARK: Loading

    /// There is only something to choose when coming in by kind.
    private var overGenre: Bool { library == nil && collection == nil && art != nil }

    /// What the capsule offers. With two or more entries it is shown.
    private var offering: SectionOffering { model.sectionOffering(art: art ?? "") }

    /// If this changes, the choice is rechecked, via the ids rather than the count (see the iPhone `LibraryView`).
    private var offeringId: String {
        offering.entries.map(\.rememberValue).joined(separator: ",") + "|"
            + offering.allSources.joined(separator: "+")
    }

    /// What the grid reads from. `nil`: nothing in this section.
    private var source: ShelfSource? {
        if let collection { return ShelfSource(parent: collection.id, art: art, collection: true) }
        if let library {
            return ShelfSource(parent: library.id, art: art ?? library.collectionType)
        }
        guard let art else { return nil }
        switch choice {
        case .all:
            // From one library as before; from several, de-duplicated so each title appears once (``TitleFilter``).
            return offering.hasInventory
                ? ShelfSource(parent: offering.allOut, art: art,
                              onlyOut: offering.allOut == nil ? offering.allSources : [])
                : nil
        case .library(let id):
            return ShelfSource(parent: id, art: art)
        case .collections:
            return nil
        }
    }

    private func load() async {
        // An aborted run leaves it standing; its successor cleans up.
        defer { if !Task.isCancelled { switchedOver = false } }
        if library == nil, model.views.isEmpty { await model.loadViews() }
        if overGenre {
            // Collections and mixed libraries come in alongside; the page does not wait for them.
            // When they arrive, `offeringId` reports it and the choice is rechecked. If there is
            // no source yet (only mixed libraries, shares missing), wait here, otherwise "nothing here
            // yet" would show until the offer arrives.
            if source == nil {
                await model.offeringLoad()
            } else {
                Task { await model.offeringLoad() }
            }
            // The remembered choice belongs to an account. On every load it is checked against the
            // signed-in account's offer; a library of the previous account is not in it, and the
            // page falls back to "All" instead of querying a foreign id.
            choice = model.sectionSelection(art: art ?? "")
            guard choice != .collections else { return }
        }
        loadedSource = source?.key
        await state.load(model, from: source)
    }

    private func loadMore() async {
        guard let source else { return }
        await state.loadMore(model, from: source)
    }
}

// MARK: - Collections

/// A collection opened from a section; `art` says whether its movies or its series are
/// meant. `nil`: everything in it. Same path as on the iPhone (`CollectionDetailPage.swift`, not in the TV target).
struct CollectionRoute: Hashable {
    let collection: Item
    let art: String?
}

/// Fallback poster of a collection without its own image: a mosaic of the posters of
/// its first titles, in the same 2:3 format and corners as any poster. Same rule as on the
/// iPhone: one title fills the field, two sit side by side, from three a 2x2 mosaic.
///
/// Gaps are twice as wide as on the iPhone (2 to 4), like every measure on the TV; the
/// posters load at half tile size.
///
/// The size is fixed, that of the poster tile. A `GeometryReader` per cell used to
/// re-measure on every pass for a value that never changes.
struct CollectionMosaic: View {
    let model: AppModel
    let collection: ItemCollection
    let art: String
    var width: CGFloat = Theme.posterWidth
    var height: CGFloat = Theme.posterHeight

    @State private var title: [Item] = []

    private static let seam: CGFloat = 4

    private var rails: [[Item]] {
        title.isEmpty ? [] : (title.count > 2 ? [Array(title.prefix(2)), Array(title[2...].prefix(2))]
                                               : [title])
    }

    var body: some View {
        let slot = rails.isEmpty ? [[]] : rails
        let rowHeightValue = (height - CGFloat(slot.count - 1) * Self.seam) / CGFloat(slot.count)
        VStack(spacing: Self.seam) {
            ForEach(Array(slot.enumerated()), id: \.offset) { _, stack in
                row(stack, width: width, height: rowHeightValue)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
        .task(id: collection.id) {
            let found = await model.collectionPosters(collection, art: art)
            withAnimation(Theme.reveal) { title = Array((found ?? []).prefix(4)) }
        }
    }

    private func row(_ stack: [Item], width: CGFloat, height: CGFloat) -> some View {
        let fieldWidth = stack.isEmpty ? width
            : (width - CGFloat(stack.count - 1) * Self.seam) / CGFloat(stack.count)
        return HStack(spacing: Self.seam) {
            if stack.isEmpty {
                Picture(url: nil, width: fieldWidth, height: height, corner: 0)
            } else {
                ForEach(stack) { entryRecord in
                    Picture(url: model.imageURL(for: entryRecord, maxHeight: 300, portrait: true),
                         width: fieldWidth, height: height, corner: 0)
                }
            }
        }
    }
}
