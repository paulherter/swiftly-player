import JellyfinKit
import SwiftUI

// MARK: - Collections

/// A collection opened from a section. `art` says whether its movies or its
/// series are meant. `nil`: everything in it.
struct CollectionRoute: Hashable {
    let collection: Item
    let art: String?
}

/// **The collection page is a library page.**
///
/// No hero image, no build of its own: arrow, name, filter and sort, grid, like
/// `GenreView` as a subpage and like `LibraryView` in the control row. Sorted
/// by year by default, ascending (``Regalquelle/richtung(_:)``), so a series of
/// films appears in order.
///
/// Sort and filter are **not** remembered: a collection is not a place you return
/// to but a view into a series. Whoever reopens it wants to see it in order again.
struct CollectionView: View {
    let model: AppModel
    let collection: Item
    let art: String?

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var state: LibraryModel
    @State private var offset: CGFloat = 0
    @State private var filterListOpen = false
    @State private var sortListOpen = false
    /// The letter strip, as on the library page: where to scroll, which titles are on
    /// screen, and the letter of the topmost one.
    @State private var jump: ScrollJump?
    @State private var onScreen = OnScreenTiles()
    @State private var topLetter: String?

    init(model: AppModel, collection: Item, art: String?) {
        self.model = model
        self.collection = collection
        self.art = art
        let state = LibraryModel()
        state.sorting = .erscheinung
        _state = State(initialValue: state)
    }

    private var source: ShelfSource {
        ShelfSource(parent: collection.id, art: art, collection: true)
    }

    @Environment(\.watchlistShown) private var watchlistShown

    /// For series the same sentence as on the series library; without the watchlist when
    /// it is switched off.
    private var filter: [LibraryFilter] {
        LibraryFilter.offered(art == "tvshows" ? [.all, .begun, .watchlist] : LibraryFilter.allCases,
                              watchlist: watchlistShown)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            GeometryReader { frameRect in
                let usable = frameRect.size.width - Theme.margin(wide: wide) - trailingLane
                grid(columns: Theme.columns(usableNow: usable, wide: wide), usable: usable)
            }
            if state.disrupted {
                EmptyState.serverDived(model, retry: { Task { await state.load(model, from: source) } })
            } else if state.items.isEmpty, !state.loads {
                EmptyState(
                    symbol: state.filter == .all ? "tray" : "line.3.horizontal.decrease",
                    headerLine: state.filter == .all ? "Hier ist noch nichts" : "Nichts gefunden",
                    text: state.filter == .all
                        ? "Sobald in dieser Sammlung etwas liegt, taucht es hier auf."
                        : "Unter \u{201E}\(state.filter.label)\u{201C} liegt gerade nichts. Nimm einen anderen Filter.",
                    quietButton: state.filter == .all
                        ? ("Aktualisieren", { Task { await state.load(model, from: source) } })
                        : ("Filter zurücksetzen", { state.filter = .all }))
            }
        }
        .shelfSheets(state: state, filter: filter,
                       filterOpen: $filterListOpen, sortingOpen: $sortListOpen)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        .task(id: "\(state.identifier)|\(model.accountSwitch)") { await state.load(model, from: source) }
        .task(id: "\(state.identifier)|\(model.accountSwitch)|\(model.alphabetShown)") {
            guard model.alphabetShown else { return }
            await state.loadAlphabet(model, from: source)
        }
    }

    // MARK: Letter strip

    /// Only sorted by name, switched on, and with more than one letter.
    private var shownAlphabet: AlphabetIndex? {
        guard model.alphabetShown, state.sorting == .name,
              let alphabet = state.alphabet, alphabet.isUseful else { return nil }
        return alphabet
    }

    /// The right margin makes room for the strip, as on the library page.
    private var trailingLane: CGFloat {
        let margin = Theme.margin(wide: wide)
        return shownAlphabet == nil ? margin : max(margin, AlphabetRail.width)
    }

    /// The letter of the first loaded title on screen, written only when it changes.
    private func updateTopLetter() {
        guard shownAlphabet != nil,
              let item = state.items.first(where: { onScreen.ids.contains($0.id) }) else { return }
        let letter = AlphabetIndex.letter(name: item.name, sortName: item.sortName)
        if letter != topLetter { topLetter = letter }
    }

    private var header: some View {
        BlurHeader(offset: offset) {
            VStack(alignment: .leading, spacing: 0) {
                SubpageHeader(title: collection.name, back: { back() }, bottom: 0) {
                    if wide, state.total > 0 { CountMark(count: state.total) }
                }
                .padding(.horizontal, -Theme.margin(wide: wide))
                ShelfControls(state: state, filter: filter,
                               filterOpen: $filterListOpen,
                               sortingOpen: $sortListOpen,
                               offset: offset)
            }
        }
    }

    private func grid(columns: Int, usable: CGFloat) -> some View {
        ScrollViewReader { reader in
        ScrollView {
            if state.items.isEmpty, state.loads {
                GridPlaceholder(columns: columns)
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 8)
                    .transition(.opacity)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.tileSpacing),
                                     count: columns),
                      alignment: .leading, spacing: 20) {
                ForEach(state.items) { item in
                    NavigationLink(value: item) {
                        PosterTile(model: model, item: item, width: nil)
                    }
                    .buttonStyle(Theme.PressButton())
                    .tileMenu(item, model: model)
                    .id(item.id)
                    .onAppear {
                        onScreen.ids.insert(item.id)
                        updateTopLetter()
                        guard state.solvesLoadMoreOut(item.id, columns: columns) else { return }
                        Task { await state.loadMore(model, from: source) }
                    }
                    .onDisappear {
                        onScreen.ids.remove(item.id)
                        updateTopLetter()
                    }
                }
            }
            .padding(.leading, Theme.margin(wide: wide))
            .padding(.trailing, trailingLane)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .opacity(state.items.isEmpty ? 0 : 1)
        }
        .scrollIndicators(.hidden)
        .animation(Theme.reveal, value: state.items.isEmpty)
        // The same measurement as in library and watchlist; see `HeaderScrollDistance`.
        .scrollDistance { offset = $0 }
        // Not moved sideways (``ScrollJump/anchor(index:columns:leading:trailing:usable:spacing:)``).
        .onChange(of: jump) { _, new in
            guard let new, let index = state.items.firstIndex(where: { $0.id == new.id }) else { return }
            let anchor = ScrollJump.anchor(index: index, columns: columns, leading: Theme.margin(wide: wide),
                                           trailing: trailingLane, usable: usable, spacing: Theme.tileSpacing)
            withAnimation(Motion.select) { reader.scrollTo(new.id, anchor: anchor) }
        }
        .overlay(alignment: .trailing) {
            if let alphabet = shownAlphabet {
                AlphabetRail(index: alphabet, current: topLetter) { letter in
                    Task {
                        guard let id = await state.jumpTarget(letter, model: model, from: source) else { return }
                        jump = ScrollJump(id: id, serial: (jump?.serial ?? 0) + 1)
                    }
                }
                .padding(.trailing, (trailingLane - AlphabetRail.width) / 2)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        }
    }
}

// MARK: - Placeholder poster

/// **Substitute poster for a collection without its own image**: a mosaic of the
/// posters of its first titles, in the same 2:3 format and with the same corners
/// as any other poster. Without its own image only the film symbol used to appear,
/// which says nothing for a collection of several films whose posters are already
/// there.
///
/// **One row or two depending on count.** A single title fills the whole field,
/// two stand side by side, from three it becomes a 2x2 mosaic, the second row
/// taking whatever remains of the first four.
///
/// The posters come through the same loader as any other (``Picture``/
/// ``ImageCache``), only small: a mosaic tile needs no tile-sized image.
struct CollectionMosaic: View {
    let model: AppModel
    let collection: ItemCollection
    let art: String
    /// `nil`: fills the column, like ``PosterTile`` without a fixed width.
    var width: CGFloat? = nil

    @State private var title: [Item] = []

    private var rails: [[Item]] {
        title.isEmpty ? [] : (title.count > 2 ? [Array(title.prefix(2)), Array(title[2...].prefix(2))]
                                               : [title])
    }

    var body: some View {
        Group {
            if let width {
                content(width: width, height: width * 1.5)
            } else {
                GeometryReader { frameRect in
                    content(width: frameRect.size.width, height: frameRect.size.height)
                }
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
        .task(id: collection.id) {
            let found = await model.collectionPosters(collection, art: art)
            withAnimation(Theme.reveal) { title = Array((found ?? []).prefix(4)) }
        }
    }

    private func content(width: CGFloat, height: CGFloat) -> some View {
        let slot = rails.isEmpty ? [[]] : rails
        let railsHeight = (height - CGFloat(slot.count - 1) * 2) / CGFloat(slot.count)
        return VStack(spacing: 2) {
            ForEach(Array(slot.enumerated()), id: \.offset) { _, stack in
                row(stack, width: width, height: railsHeight)
            }
        }
    }

    private func row(_ stack: [Item], width: CGFloat, height: CGFloat) -> some View {
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
        Picture(url: url, width: width, height: height, corner: 0) {
            Theme.area.overlay {
                Image(systemName: "film").foregroundStyle(Theme.fontVeryQuiet)
            }
        }
    }
}

// MARK: - Filter and sort, shared with the library page

/// The control row below the title of a grid page. It lived in `LibraryView`;
/// the collection page needs exactly the same, and two versions of the same row
/// drift apart.
///
/// **Values, not options.**
///
/// This used to be a horizontally scrolling row of filter chips plus a sort pill:
/// three words of which one lights up, so you must read the color to know the
/// state. The active chip also carried the accent and the pill next to it did not:
/// two questions, two grammars.
///
/// Now two pills show their **value**, and the count on the right. The price is
/// honest: filtering takes two taps instead of one. In return the row fits any
/// iPhone no matter how many filters are added, and the fade mask at the right
/// edge goes away entirely.
///
/// **On wide screens it stays open.** There is room, and a sheet for something that
/// fits beside it is a detour; same reasoning as before.
///
/// **Sorting sits at the far right on wide screens**, as on the Mac, where the
/// same window has the same width. In portrait the pills stay, where there is no
/// room.
struct ShelfControls: View {
    let state: LibraryModel
    let filter: [LibraryFilter]
    @Binding var filterOpen: Bool
    @Binding var sortingOpen: Bool
    let offset: CGFloat
    /// Only the count instead of filter and sort, for the list of collections that
    /// needs neither filtering nor reordering.
    var onlyCount: Int?

    @Environment(\.wide) private var wide

    var body: some View {
        if wide {
            row.padding(.top, 14)
        } else {
            ValueRail(offset: offset) { row }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            if let onlyCount {
                Spacer(minLength: 0)
                if !wide { CountMark(count: onlyCount) }
            } else if wide {
                ForEach(filter) { f in
                    SelectionChip(text: f.label, an: state.filter == f) {
                        state.filter = f
                    }
                }
                Spacer(minLength: 12)
                ForEach(Sorting.allCases) { s in
                    SelectionChip(text: s.label,
                             symbol: s == state.sorting ? "line.3.horizontal.decrease" : nil,
                             an: state.sorting == s) {
                        state.sorting = s
                    }
                }
            } else {
                ValuePill(symbol: "line.3.horizontal.decrease",
                          text: state.filter.label) { filterOpen = true }
                ValuePill(symbol: "arrow.up.arrow.down",
                          text: state.sorting.label) { sortingOpen = true }
                Spacer(minLength: 8)
                // Only once we know it. A zero that is not one yet would be a false statement.
                if state.total > 0 { CountMark(count: state.total) }
            }
        }
        // **The same height as with pills, also without them.**
        //
        // "Collections" shows only the count; its text is shorter than a `ValuePill`
        // (`minHeight: 30`). Without this bound the row jumped up a few points when
        // switching between "All movies" and "Collections", and the count on the right
        // jumped with it. Now the same space stays, with or without pills.
        .frame(minHeight: 30)
    }
}

extension View {
    /// The two sheets for `ShelfControls`. **On the page, not on the header row**;
    /// the reasoning is at `LibraryView.body`.
    func shelfSheets(state: LibraryModel, filter: [LibraryFilter],
                       filterOpen: Binding<Bool>, sortingOpen: Binding<Bool>) -> some View {
        self
            .overlay(alignment: .topTrailing) {
                SelectionSheet(opened: filterOpen,
                             title: "Filtern",
                             entries: filter,
                             label: { $0.label },
                             isSelected: { $0 == state.filter },
                             select: { state.filter = $0 })
            }
            .overlay(alignment: .topTrailing) {
                SelectionSheet(opened: sortingOpen,
                             title: "Sortieren",
                             entries: Sorting.allCases,
                             label: { $0.label },
                             isSelected: { $0 == state.sorting },
                             select: { state.sorting = $0 })
            }
            // A filter the page no longer offers (the watchlist, switched off) must not
            // keep narrowing the list with no pill left to undo it.
            .task(id: filter) {
                let kept = state.filter.kept(in: filter)
                if kept != state.filter { state.filter = kept }
            }
    }
}

// MARK: - Detail page: part of the collection

/// **The "Part of the collection" row on the movie page**: the other titles in
/// the collection, in order. Its header opens the collection page.
///
/// It does not ask per title: Jellyfin 10 has no field for it. Membership is in
/// the ``CollectionDirectory``, loaded once per account; only the row's posters
/// come fresh from the server.
///
/// If the collection is missing, so is the row, as with extras. A notice "belongs
/// to no collection" would be an answer nobody asks for.
///
/// **Loading happens on the movie page, not here.** The row used to fetch its own
/// titles and push itself into the page later than everything else; now the movie
/// page waits for it like for extras and similar, and fades everything in together.
struct CollectionRail: View {
    typealias Rail = AppModel.CollectionRailsData

    let model: AppModel
    let title: Item
    let rails: [Rail]

    @Environment(\.wide) private var wide

    private var art: String? { LibraryGenre.art(toType: title.type) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rails, id: \.collection.id) { rail in
                VStack(alignment: .leading, spacing: 12) {
                    NavigationLink(value: CollectionRoute(collection: rail.collection.item, art: art)) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                RailTitle(text: "Teil der Sammlung")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.fontVeryQuiet)
                            }
                            Text(verbatim: rail.collection.item.name)
                                .font(Theme.body)
                                .foregroundStyle(Theme.fontQuiet)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(Theme.PressButton())
                    .padding(.horizontal, Theme.margin(wide: wide))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.tileSpacing) {
                            ForEach(rail.title) { other in
                                NavigationLink(value: other) {
                                    PosterTile(model: model, item: other)
                                }
                                .buttonStyle(Theme.PressButton())
                            }
                        }
                        .padding(.horizontal, Theme.margin(wide: wide))
                    }
                }
                .padding(.top, Theme.railsSpacing)
            }
        }
    }
}
