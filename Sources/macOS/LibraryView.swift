import JellyfinKit
import SwiftUI

/// Movies or series.
///
/// The grid is flexible, which is the one place where the Mac really computes
/// differently: on iPhone three columns are fixed because 390 pt of width is fixed.
/// A window has no fixed width, so the tile width determines the column count, not
/// the other way round.
///
/// Filter, sorting and paging come from `LibraryModel` in `Sources/Shared`,
/// the same paging logic as on the other platforms, defined once.
struct LibraryView: View {
    let model: AppModel
    let art: String
    let title: LocalizedStringKey
    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section

    /// Owned from outside, not held here. As `@State` the shelf would disappear with
    /// the view, and the view is torn down on every bar switch (`\.id(section)`). The
    /// loading bar then restarted on every switch between movies and series.
    let shelf: LibraryModel
    /// What the title selected: All, Collections or one library. The rule lives in
    /// ``SectionOffering``, as on iPhone.
    ///
    /// Owned from outside for the same reason as the shelf: as `@State` the choice
    /// would reset on every bar switch.
    ///
    /// This replaces the "Bibliotheken" section in the sidebar. The other libraries
    /// used to open there as separate roots; now they are in the title menu, as on
    /// iPhone.
    @Binding var choice: SectionSelection
    /// A collection instead of the area. The page is then a subpage with a back arrow,
    /// no title menu, and reads from the collection. `art` says whether its movies or
    /// its series are meant; `nil` means everything.
    var collection: (item: Item, art: String?)?
    /// Which filters are available.
    var filter: [LibraryFilter] = LibraryFilter.allCases
    /// `nil` means this is a root, not a pushed page, so there is no back arrow.
    var back: (() -> Void)?

    /// Where the page is scrolled to, as its own object rather than `@State`.
    ///
    /// `onScrollGeometryChange` fires on every tick. If it wrote into this view's
    /// `@State`, SwiftUI would re-evaluate the whole body (header, filter row and the
    /// entire grid) sixty times a second. During fast dragging the main thread can
    /// no longer keep up, and the scroll view loses its footing and jumps. As
    /// `@Observable`, only the views that read the value redraw: the bar and the
    /// filter row.
    @State private var headerState = HeaderState()
    @State private var position = ScrollPosition()
    /// Once per page build: the remembered position is only applied on entry.
    @State private var returned = false

    /// An account switch is running: the content holds still and only comes in
    /// staggered once the new account is loaded. This belongs to the page, not to the
    /// counter: a page opened after the switch starts with `false` and does not go
    /// through it again.
    @State private var change = false

    /// How far the value row has been closed, 0 to 1.
    private var pullGait: Double {
        Double(min(max(headerState.offset / Theme.valueRailsDistance, 0), 1))
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.tileWidth, maximum: Theme.tileWidth),
                  spacing: Theme.tileSpacing, alignment: .topLeading)]
    }

    /// Where the scroll position of this page is stored (bar, collection, sorting).
    private var rememberKey: String {
        "\(section)|\(collection?.item.id ?? "")|\(shelf.identifier)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                HStack(alignment: .firstTextBaseline) {
                    // The back arrow is in the `Bestandsleiste`, not here in the content: here it
                    // scrolled away, and anyone far down the page could only get back with the ⌘[
                    // shortcut.
                    VStack(alignment: .leading, spacing: 3) {
                        titleLine
                        // Where am I? The server name was not shown on any page; with several accounts
                        // that have identically named libraries it is the only difference.
                        if let server = model.serverName, !server.isEmpty {
                            Text(verbatim: server)
                                .font(Theme.small)
                                .foregroundStyle(Theme.fontVeryQuiet)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    // The shared component instead of a second version; it used to be rebuilt here
                    // character for character.
                    if shown > 0 { CountMark(count: shown) }
                }

                // Two buttons instead of eight chips.
                //
                // All filters and all sortings used to be chips side by side: with four and four
                // that is eight items in one row, of which two apply. Now, as on iPhone, there is
                // one "All" button and one A-to-Z button; pressing one opens a popup. That is
                // much cleaner.
                //
                // The button carries the selected value; the options are in the panel below.
                //
                // The library choice is not here. It used to be chips at the front; it is now the
                // title menu above, which also takes the heading with it.
                //
                // For "Collections" the row stays, just empty: the list of collections needs
                // neither filtering nor re-sorting. If the row went away, the grid would jump by
                // its height on every switch; on iPhone `ShelfControls` keeps its height for the
                // same reason.
                HStack(spacing: 8) {
                    SelectionButton(symbol: "line.3.horizontal.decrease",
                              value: shelf.filter.label,
                              entries: filter,
                              label: { $0.label },
                              isSelected: { $0 == shelf.filter },
                              select: { shelf.filter = $0 })
                    SelectionButton(symbol: shelf.sorting.symbol,
                              value: shelf.sorting.label,
                              entries: Sorting.allCases,
                              label: { $0.label },
                              isSelected: { $0 == shelf.sorting },
                              select: { shelf.sorting = $0 })
                    Spacer(minLength: 0)
                }
                .opacity(showsCollections ? 0 : 1)
                .allowsHitTesting(!showsCollections)
                .accessibilityHidden(showsCollections)
                .padding(.top, 14)
                // It fades out on scroll: what you want to know before scrolling does not need to
                // travel along. Opacity only, not height: a height tied to the scroll offset is a
                // feedback loop.
                .opacity(1 - pullGait)
                .zIndex(20)

                // The placeholder is in the layout flow, not an overlay.
                //
                // It used to be a `.overlay(alignment: .topLeading)` with a fixed distance from
                // the top, but the header zone above is not always the same height: the library
                // chips only exist from two libraries on, and they only appear once `model.views`
                // has arrived. On the first switch that was not yet the case, so the placeholder
                // sat too high and covered the chip row.
                //
                // In the flow that cannot happen: it sits where the grid would be and moves with
                // everything above it.
                if shelf.items.isEmpty, shelf.loads, !showsCollections {
                    GridPlaceholder(columns: estimatedColumns, rails: 2)
                        .padding(.top, 22)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    if showsCollections {
                        collectionTiles
                    } else {
                    ForEach(shelf.items, id: \.id) { entryRecord in
                        Button { navigator.openIt(.title(entryRecord), in: section) } label: {
                            PosterCell(title: entryRecord.name,
                                         secondLine: entryRecord.productionYear.map { "\($0)" },
                                         image: model.imageURL(for: entryRecord, portrait: true),
                                         progress: entryRecord.userData?.playedPercentage
                                             .map { $0 / 100 },
                                         mark: DisplayRules.tileMark(
                                            art: entryRecord.type,
                                            seasons: entryRecord.childCount,
                                            watched: entryRecord.userData?.played,
                                            openEpisodes: entryRecord.userData?.unplayedItemCount),
                                         symbolText: art == "tvshows" ? "tv" : "film")
                        }
                        .buttonStyle(Theme.PressButton())
                        .tileMenu(entryRecord, model: model)
                        .task {
                            // More items are requested before the user reaches the bottom.
                            if shelf.solvesLoadMoreOut(entryRecord.id, columns: estimatedColumns),
                               let source {
                                await shelf.loadMore(model, from: source)
                            }
                        }
                    }
                    }
                }
                .padding(.top, 22)

                // The page had neither an empty nor an error state. If nothing loaded, nothing
                // was shown: no hint whether the library is empty, the filter too narrow or the
                // server unreachable. Every view that loads needs all of them. Wording and way
                // out as on iPhone. "Collections" only appears in the menu when there are any, so
                // no loading or empty state there.
                if shelf.items.isEmpty, !shelf.loads, !showsCollections {
                    if shelf.disrupted {
                        EmptyState(
                            symbol: "externaldrive.badge.xmark",
                            headerLine: "Server ist abgetaucht",
                            text: "\(model.serverAddress ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                            primaryButton: ("Erneut versuchen", { newLoad() }))
                            .padding(.top, 80)
                    } else {
                        EmptyState(
                            symbol: shelf.filter == .all ? "tray" : "line.3.horizontal.decrease",
                            headerLine: shelf.filter == .all ? "Hier ist noch nichts"
                                                             : "Nichts gefunden",
                            text: shelf.filter == .all
                                ? (collection == nil
                                   ? "Sobald in dieser Bibliothek etwas liegt, taucht es hier auf."
                                   : "Sobald in dieser Sammlung etwas liegt, taucht es hier auf.")
                                : "Unter \u{201E}\(shelf.filter.label)\u{201C} liegt gerade nichts. Nimm einen anderen Filter.",
                            quietButton: shelf.filter == .all
                                ? ("Aktualisieren", { newLoad() })
                                : ("Filter zurücksetzen", { shelf.filter = .all }))
                            .padding(.top, 80)
                    }
                }
            }
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        // The look's glow, the same on every main page; goes up with the content.
        .lookGlow()
        .scrollIndicators(.never)
        // On an account switch like the home screen: old content disappears immediately,
        // the new content fades in staggered (as on iPhone).
        .accountSwitchFade(model: model,
                            ready: !shelf.outdated(model) && (!shelf.items.isEmpty || !shelf.loads) && !shelf.disrupted,
                            change: $change)
        // The title stays at the top with the gradient behind it, as on iPhone. The large
        // title scrolls away and the small one fades in; they are never visible together.
        .overlay(alignment: .top) {
            StateBar(title: title, name: headerName, state: headerState, back: back)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
            headerState.offset = new
        }
        // A different filter or sorting scrolls to the top. Otherwise the view would stay
        // in the middle of the new list.
        .onChange(of: shelf.identifier) { _, _ in
            position.scrollTo(edge: .top)
        }
        // Switching the bar rebuilds the root (`.id(section)`). The titles stay in
        // `LibraryModel`, the scroll position does not. It is remembered when leaving
        // and restored on re-entry.
        .onDisappear { ScrollRemember.state[rememberKey] = headerState.offset }
        .onChange(of: shelf.items.isEmpty, initial: true) { _, empty in
            guard !empty, !returned else { return }
            returned = true
            guard let y = ScrollRemember.state[rememberKey], y > 1 else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                position.scrollTo(y: y)
            }
        }
        // The milky bar at the top edge. macOS 26 places it over every scroll view by
        // itself; it was never in our code. Over the image it blends in, but on plain
        // background at the left it shows as a bar.
        //
        // Whatever the framework adds unasked must be switched off just like what we
        // write ourselves.
        .pagesScroll()
        // No loading ring. Instead of a spinning ring the grid is already there in its
        // final shape and is cross-faded once the titles arrive; the page is then empty,
        // not waiting.
        .animation(Theme.reveal, value: shelf.items.isEmpty)
        .task(id: shelf.identifier) { await loadAlone() }
        // The shelf belongs to an account too. `.task(id:)` is keyed on sorting and
        // filter, which do not change on an account switch, and the shelf lives in
        // `MainView`, so it survives the bar switch. Without this line the previous
        // account's library stayed visible after switching, until restart.
        //
        // The remembered library has to go as well: it is an `Item` of the previous
        // account, and the new one may see a different selection. Nothing is cleared
        // otherwise: `LibraryModel` replaces the entries only once the new ones have
        // arrived. After playback, "Mark as watched" or watchlist changes, checkmarks and
        // bars would otherwise be stale.
        .onChange(of: model.listenRefresh) { _, _ in newLoad() }
        .onChange(of: model.accountSwitch) { _, _ in
            newLoad()
        }
        // Collections and mixed libraries arrive later, from `offeringLoad()`. If that
        // changes what "All" reads or what may be selected, the page reloads. Keyed on the
        // ids, not the count: if one library disappears and a new one appears, the count
        // stays the same.
        .onChange(of: offeringId) { _, _ in
            guard collection == nil else { return }
            let new = model.sectionSelection(art: art)
            guard new != choice || source?.key != loadedSource else { return }
            choice = new
            newLoad()
        }
    }

    /// An estimate is enough for paging: whether the third-to-last row starts at six or
    /// seven columns moves the trigger by one tile width. Computing it exactly would
    /// mean carrying the window width along.
    private var estimatedColumns: Int { 6 }

    /// Restarts `load()` and cancels the previous run.
    private func newLoad() {
        Task { await loadAlone() }
    }

    /// `load()` as the only run: the previous one is cancelled, and if this one is
    /// cancelled (`.task(id:)`), the cancellation propagates.
    private func loadAlone() async {
        loadTask?.cancel()
        let task = Task { await load() }
        loadTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func load() async {
        if model.views.isEmpty { await model.loadViews() }
        if collection == nil {
            // Collections and mixed libraries arrive alongside: the page does not wait for
            // them.
            Task { await model.offeringLoad() }
            // The remembered choice belongs to an account. On every load it is checked
            // against the signed-in account's offer; a library of the previous account does not
            // exist there, and the page falls back to "All".
            choice = model.sectionSelection(art: art)
            guard choice != .collections else { return }
        }
        loadedSource = source?.key
        await shelf.load(model, from: source)
    }

    // MARK: Title menu

    /// What the title offers to choose from. From two entries on it becomes a menu.
    private var offering: SectionOffering { model.sectionOffering(art: art) }

    private var offeringId: String {
        offering.entries.map(\.rememberValue).joined(separator: ",") + "|"
            + offering.allSources.joined(separator: "+")
    }

    private var showsCollections: Bool { collection == nil && choice == .collections }

    /// What the grid reads from. `nil`: there is nothing in this area.
    private var source: ShelfSource? {
        if let collection {
            return ShelfSource(parent: collection.item.id, art: collection.art, collection: true)
        }
        switch choice {
        case .all:
            // From one library as before; from several, filtered to one entry per title
            // (``TitleFilter``).
            return offering.hasInventory
                ? ShelfSource(parent: offering.allOut, art: art,
                              onlyOut: offering.allOut == nil ? offering.allSources : [])
                : nil
        case .library(let id):
            return ShelfSource(parent: id, art: art)
        case .collections, .playlists:
            return nil
        }
    }
    @State private var loadedSource: String?
    /// The running load; there is only ever one. It is triggered from five places and
    /// used to run side by side.
    @State private var loadTask: Task<Void, Never>?

    private var collectionList: [ItemCollection] {
        model.collectionDirectory?.collections(art: art) ?? []
    }

    /// What the count badge shows.
    private var shown: Int { showsCollections ? collectionList.count : shelf.total }

    /// The name in the bar while scrolling. `nil`: the title itself.
    private var headerName: String? {
        if let collection { return collection.item.name }
        return choice == .all ? nil : label(choice)
    }

    /// "Alle" simply means "Filme". The title says where you are; "Alle Filme" only
    /// appears in the menu.
    @ViewBuilder
    private var titleLine: some View {
        if let collection {
            // The name comes from the server and is not translated.
            Text(verbatim: collection.item.name)
                .font(Theme.titleLarge)
                .tracking(Theme.lockTitle)
                .foregroundStyle(Theme.font)
        } else if offering.isMenu {
            TitleSelection(title: choice == .all ? Text(title) : Text(verbatim: label(choice)),
                      entries: offering.entries,
                      label: { label($0) },
                      isSelected: { $0 == choice },
                      category: { $0 == offering.firstLibrary ? "Bibliotheken" : nil },
                      select: { new in
                          guard new != choice else { return }
                          model.sectionSelect(new, art: art)
                          choice = new
                          newLoad()
                      })
        } else {
            Text(title)
                .font(Theme.titleLarge)
                .tracking(Theme.lockTitle)
                .foregroundStyle(Theme.font)
        }
    }

    /// Collections in the same grid, with the same tile. Under the name, instead of the
    /// year, it shows how many movies or series it holds. Without its own image it
    /// shows a mosaic of the first posters.
    @ViewBuilder
    private var collectionTiles: some View {
        ForEach(collectionList) { entryRecord in
            Button {
                navigator.openIt(.collection(entryRecord.item, art: art), in: section)
            } label: {
                PosterCell(title: entryRecord.item.name,
                             secondLine: countText(entryRecord.count(art: art)),
                             image: model.imageURL(for: entryRecord.item, portrait: true),
                             symbolText: art == "tvshows" ? "tv" : "film",
                             mosaic: entryRecord.item.imageTags?["Primary"] == nil
                                 ? (model, entryRecord, art) : nil)
            }
            .buttonStyle(Theme.PressButton())
        }
    }

    private func countText(_ n: Int) -> String {
        ItemCollection.countText(art: art, count: n)
    }

    private func label(_ w: SectionSelection) -> String {
        switch w {
        case .all:
            art == "tvshows" ? String(localized: "Alle Serien") : String(localized: "Alle Filme")
        case .collections:
            String(localized: "Sammlungen")
        case .playlists:
            String(localized: "Wiedergabelisten")
        case .library(let id):
            offering.library(id)?.name ?? ""
        }
    }
}

/// Every sorting has its own symbol. The button used the same arrows for all four;
/// next to "Alle" with the filter symbol, "A–Z" then read like a button without a
/// symbol. Now the symbol says what the list is sorted by. Linux and Windows use
/// the same mapping (`Sorting.characterNames`).
extension Sorting {
    var symbol: String {
        switch self {
        case .name:        "textformat.abc"
        case .latest:     "clock"
        case .rating:   "star"
        case .erscheinung: "calendar"
        }
    }
}

/// Scroll positions of the library pages, kept across bar switches.
@MainActor
enum ScrollRemember {
    static var state: [String: CGFloat] = [:]
}
