import JellyfinKit
import SwiftUI

struct WatchlistView: View {
    let model: AppModel

    @Environment(\.wide) private var wide
    @Environment(\.sectionActive) private var sectionActive
    @Environment(\.tabStillTimes) private var anotherTime
    @State private var state: WatchlistModel
    /// The view's pill and the model's kind must say the same at launch: the
    /// model gets it from the store, the view reads it from there.
    @State private var genre: RememberGenre
    @State private var genreListOpen = false
    /// Counter value at which the last refresh happened, see `nachholen`.
    @State private var refreshState = 0
    @State private var sortListOpen = false
    /// How far it has scrolled; the edge under the header depends on it.
    ///
    /// **Was missing here.** Movies and series had it already; this page was
    /// built without the value, so its content kept running under half a
    /// gradient instead of behind a bar. The same kind of page, two
    /// behaviors.
    @State private var offset: CGFloat = 0

    init(model: AppModel) {
        self.model = model
        let freshValue = WatchlistModel()
        _state = State(initialValue: freshValue)
        _genre = State(initialValue: RememberGenre.toward(art: freshValue.genre))
    }

    var body: some View {
        GeometryReader { frameRect in
            content(usableNow: frameRect.size.width - 2 * Theme.margin(wide: wide))
        }
        .overlay(alignment: .topTrailing) {
            SelectionSheet(opened: $genreListOpen,
                         title: "Gattung",
                         entries: RememberGenre.allCases,
                         label: { $0.label },
                         isSelected: { $0 == genre },
                         select: { genre = $0; state.genre = $0.art })
        }
        .overlay(alignment: .topTrailing) {
            SelectionSheet(opened: $sortListOpen,
                         title: "Sortieren",
                         entries: Sorting.allCases,
                         label: { $0.label },
                         isSelected: { $0 == state.sorting },
                         select: { state.sorting = $0 })
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        // Also on watched/bookmark changes elsewhere: reload quietly (`load`
        // refreshes without placeholders and without losing the position),
        // otherwise the tile shows stale bars and checkmarks and a removed title
        // would stay.
        .task(id: "\(state.identifier)|\(model.accountSwitch)|\(refreshState)") {
            await state.load(model)
        }
        .catchUp(at: model.listenRefresh) { refreshState = model.listenRefresh }
    }

    @ViewBuilder
    private func content(usableNow: CGFloat) -> some View {
        let columns = Theme.columns(usableNow: usableNow, wide: wide)
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()

            ScrollView {
                // First the shape, then the content, as in the library.
                if state.items.isEmpty, state.loads {
                    GridPlaceholder(columns: columns)
                        .padding(.horizontal, Theme.margin(wide: wide))
                        .padding(.top, 8)
                        .transition(.opacity)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                             spacing: Theme.tileSpacing),
                                         count: columns),
                          alignment: .leading, spacing: 20) {
                    ForEach(state.items) { item in
                        NavigationLink(value: item) {
                            PosterTile(model: model, item: item, width: nil)
                        }
                        .buttonStyle(Theme.PressButton())
                        .tileMenu(item, model: model)
                        .onAppear {
                            guard state.solvesLoadMoreOut(item.id, columns: columns) else { return }
                            Task { await state.loadMore(model) }
                        }
                    }
                }
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.top, 8)
                .opacity(state.items.isEmpty ? 0 : 1)
            }
            .scrollIndicators(.hidden)
            .animation(Theme.reveal, value: state.items.isEmpty)
            .toTop(order: state.identifier, anotherTime: anotherTime, active: sectionActive)
            // The finger's path, not the offset adjusted for the edge; why is
            // explained in `HeaderScrollDistance` in the package.
            .scrollDistance(active: sectionActive) { offset = $0 }
            // **The draw-in on section switch was missing here.**
            //
            // Movies and series have carried it since the rework; the watchlist was
            // built without it: wide, it is a section like those two but jumped in
            // hard. Only the scroll area, not the header above.
            // The look's glow, the same on every main page; goes up with the content.
            .lookGlow()
            .areaContent()
            // The header is a safe-area inset, not an overlay; the reasoning is
            // given at length in `MainView`. In short: its top margin came from its
            // own measurement that fed back into the same area as `contentMargins`,
            // and that cycle oscillated. `safeAreaInset` measures nothing.
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .contentMargins(.bottom, 24, for: .scrollContent)


            if state.disrupted, state.items.isEmpty, !state.loads {
                // The same text as in the library, including the server address: one
                // cause, one diagnosis. Before, this too said "Nothing bookmarked yet",
                // which is simply wrong with a full watchlist.
                EmptyState.serverDived(model, retry: { Task { await state.load(model) } })
            } else if state.items.isEmpty, !state.loads {
                // **The empty state says how to get in.** Otherwise it is a dead end: an
                // empty list that does not reveal where its content would come from.
                EmptyState(symbol: "bookmark",
                            headerLine: "Noch nichts gemerkt",
                            text: "Tippe irgendwo auf das Lesezeichen. Dein Zukunfts-Ich freut sich.")
            }
        }
    }


    private var header: some View {
        BlurHeader(offset: offset) {
            // **Four, not fourteen.** `SubpageHeader` already brings 18 pt at the
            // bottom; together with 14 the pills sat 32 pt under the title and looked
            // detached. Feedback: "way too far down". Wide has no such base, so it
            // stays at 14; that is why the number depends on `wide`.
            // One number for "header to value row", as in library and downloads: 14,
            // and it lives in `ValueRail` so it disappears with the pills.
            VStack(alignment: .leading, spacing: 0) {
                // **Wide, the watchlist is a root; narrow, a path**, and the two carry
                // different headers.
                //
                // Wide, it stands as a section in the sidebar next to Movies and Series;
                // the same header belongs there as there: large title, flush with the
                // edge, no arrow. An `SubpageHeader` without arrow looks similar but
                // sets the title off by a button width, which stands out side by side in
                // the same bar.
                //
                // Narrow, it hangs on the icon at the top right and slides in as a page;
                // then the arrow is right.
                if wide {
                    // The count sits next to the title and not after the chips: otherwise
                    // two gaps share the space and the sort chips land in the middle instead
                    // of on the right. The same place as in the library and on the Mac.
                    HStack(alignment: .firstTextBaseline) {
                        Text("Merkliste")
                            .font(Theme.titleLarge)
                            .tracking(Theme.lockTitle)
                            .foregroundStyle(Theme.font)
                        Spacer(minLength: 0)
                        if state.total > 0 { CountMark(count: state.total) }
                    }
                } else {
                    // **The count badge sits with the pills, not in the header.**
                    //
                    // It was at the top right next to "Watchlist" for a day, on a different
                    // level from the values it refers to. Feedback: "it should be to the
                    // right of the two buttons and not of the name". It counts what the two
                    // pills filtered, so it belongs in their row.
                    SubpageHeader(title: String(localized: "Merkliste"),
                                    back: { back() },
                                    // The spacing to the pill row comes from the stack, not twice.
                                    bottom: 0) { EmptyView() }
                        // The header brings its own margin; here it already sits in one.
                        .padding(.horizontal, -Theme.margin(wide: wide))
                }

                // **Narrow shows values, wide shows options**, the same rule as in
                // the library. On iPad there is room, and a sheet for something that fits
                // beside it is a detour.
                //
                // The symbol tells the two pills apart: a funnel narrows, a grid selects,
                // and the library's pill sits at the same spot on the neighboring page.
                // The same row as in the library, the same behavior: narrow it collapses
                // when scrolling, wide it stays. The reasoning is at `ValueRail`.
                pillsRow
            }
        }
    }

    @ViewBuilder
    private var pillsRow: some View {
        if wide {
            values.padding(.top, 14)
        } else {
            ValueRail(offset: offset) { values }
        }
    }

    private var values: some View {
                HStack(spacing: 8) {
                    if wide {
                        ForEach(RememberGenre.allCases) { fall in
                            SelectionChip(text: fall.label, an: genre == fall) {
                                genre = fall
                                state.genre = fall.art
                            }
                        }
                        // Far right as in the library and on the Mac.
                        Spacer(minLength: 12)
                        ForEach(Sorting.allCases) { fall in
                            SelectionChip(text: fall.label,
                                     symbol: fall == state.sorting
                                             ? "line.3.horizontal.decrease" : nil,
                                     an: state.sorting == fall) {
                                state.sorting = fall
                            }
                        }
                    } else {
                        ValuePill(symbol: "square.grid.2x2",
                                  text: genre.label) { genreListOpen = true }
                        ValuePill(symbol: "arrow.up.arrow.down",
                                  text: state.sorting.label) { sortListOpen = true }

                        Spacer(minLength: 12)
                        if state.total > 0 { CountMark(count: state.total) }
                    }
                }
    }

    @Environment(\.dismiss) private var close
    private func back() { close() }
}
