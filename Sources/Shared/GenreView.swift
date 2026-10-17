import JellyfinKit
import SwiftUI

/// **All titles of a genre**, from the chips on the home page.
///
/// The same grid as library, search and watchlist, with the same column
/// calculation. Most recently added first: whoever taps a genre usually wants
/// what is new.
struct GenreView: View {
    let model: AppModel
    let name: String

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var items: [Item] = []
    /// Titles the server has in total, for the count badge and the question "is
    /// there more".
    @State private var total = 0
    /// How many server entries are already fetched. **Not `items.count`:**
    /// duplicates (one work in two libraries) drop out per page, but the server counts
    /// them; loading continues from the fetch offset, otherwise the same page would
    /// come again.
    @State private var retrieved = 0
    @State private var loadsPost = false
    /// Changes with watched state or watchlist elsewhere; then reload silently.
    @State private var refreshState = 0
    @State private var loads = true
    /// The fetch failed, which is not the same as "the genre is empty".
    @State private var disrupted = false
    /// How far it is scrolled, for the fade and the header's scroll edge.
    ///
    /// **No feedback loop:** this header is always the same height (no value row that
    /// collapses), and what is measured is the sum of offset and top inset, which
    /// stays correct even if the inset changes. See the long reasoning in
    /// `WatchlistView`.
    @State private var offset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            GeometryReader { frameRect in
                grid(columns: Theme.columns(usableNow: frameRect.size.width - 2 * Theme.margin(wide: wide),
                                             wide: wide))
            }
            if !loads, disrupted {
                // **`nil` means failed, `[]` means empty.** `model.title` returns both
                // separately, and `?? []` used to be here, discarding the difference, so a
                // network error became the statement "there is nothing in this genre".
                EmptyState.serverDived(model, retry: { Task { await fetch() } })
            } else if !loads, items.isEmpty {
                EmptyState(symbol: "tag",
                            headerLine: "Nichts in diesem Genre",
                            text: "In diesem Genre gibt es auf deinem Server gerade keine Filme und Serien.")
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        // Also on watched/bookmark changes elsewhere: reload silently (no
        // placeholders, with as much as is already shown), otherwise the tile shows the
        // previous bar and checkmark.
        .task(id: "\(name)|\(refreshState)") { await fetch() }
        .catchUp(at: model.listenRefresh) { refreshState = model.listenRefresh }
    }

    private func fetch() async {
        loads = items.isEmpty
        let state = retrieved
        let reach = min(300, max(AppModel.pagesSize, state))
        let result = await model.titleWithNumber(genre: name, limit: reach)
        // A cancelled run (`.task(id:)`) has nothing left to say.
        guard !Task.isCancelled else { return }
        // If `loadMore` appended a page meanwhile, this response is shorter than what
        // is shown: the list would shrink and immediately load more. Then once more
        // with the new extent.
        guard state == retrieved else { return await fetch() }
        if let result {
            disrupted = false
            items = result.items
            total = result.total
            retrieved = reach
        } else {
            // A list that stays is better than an error message.
            disrupted = items.isEmpty
        }
        loads = false
    }

    private func loadMore() async {
        guard retrieved < total, !loadsPost, !loads else { return }
        loadsPost = true
        defer { loadsPost = false }
        let since = retrieved
        guard let page = await model.titleWithNumber(genre: name, startIndex: since),
              since == retrieved else { return }
        // Across pages by id: the page only merges its own duplicates.
        items = ListRules.append(page.items, an: items)
        total = page.total
        retrieved = since + AppModel.pagesSize
    }

    /// **The same header as on the other two pushed grid pages.**
    ///
    /// It used to sit fixed above the scroll area: no fade, no scroll edge, posters
    /// ran past a hard edge. Watchlist and the downloads subpage hang their header in
    /// `BlurHeader` and pass it the offset; genre was the only one of the three
    /// that did not.
    ///
    /// `SubpageHeader` brings its own page margin, as does `BlurHeader`, so the
    /// inner one is subtracted, exactly as in `WatchlistView` and `DownloadsView`.
    private var header: some View {
        BlurHeader(offset: offset) {
            // The name comes from the server and is not translated.
            //
            // **The count badge on the right, and nothing else.** A subpage carries arrow,
            // title and count badge, and it was missing here, although
            // "have I been through this?" is the same question for a genre as in the
            // library. A server name explicitly does **not** belong here: only the library
            // page shows it, because with two accounts two libraries can have the same name.
            SubpageHeader(title: name, back: { back() }) {
                if !items.isEmpty { CountMark(count: max(total, items.count)) }
            }
            .padding(.horizontal, -Theme.margin(wide: wide))
        }
    }

    private func grid(columns: Int) -> some View {
        ScrollView {
            // Shape first, then content, as in the library.
            if items.isEmpty, loads {
                GridPlaceholder(columns: columns)
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 8)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.tileSpacing),
                                     count: columns),
                      alignment: .leading, spacing: 20) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        PosterTile(model: model, item: item, width: nil)
                    }
                    .buttonStyle(Theme.PressButton())
                    .tileMenu(item, model: model)
                    .onAppear {
                        guard ListRules.postLoadSection(item.id, in: items, columns: columns)
                        else { return }
                        Task { await loadMore() }
                    }
                }
            }
            .padding(.horizontal, Theme.margin(wide: wide))
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self) {
            $0.contentOffset.y + $0.contentInsets.top
        } action: { _, new in offset = new }
        // The header sits as a safe-area inset, not as an overlay; the reasoning is in
        // `MainView`. In short: its top inset otherwise came from a measurement of its
        // own that feeds back into the same area.
        .safeAreaInset(edge: .top, spacing: 0) { header }
    }
}
