import JellyfinKit
import SwiftUI

/// All titles of a genre, from the chips on the home page. Same grid and column count as the library. Most recently added first: opening a genre usually means looking for what is new.
struct GenreView: View {
    let model: AppModel
    let name: String

    @State private var items: [Item] = []
    @State private var loads = true
    /// The server did not answer, as opposed to "nothing in this genre".
    @State private var disrupted = false

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Theme.gridColumn),
              count: Theme.gridColumns)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The name comes from the server and is not translated.
                RailTitle(name: name)
                    .padding(.horizontal, Theme.edgePage)
                    .padding(.top, Theme.headerOffsetDetail + 40)
                    .padding(.bottom, Theme.titleSpacing)

                LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.latticeRow) {
                    ForEach(items) { item in
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
                    }
                }
                .padding(.horizontal, Theme.edgePage)
            }
            .padding(.bottom, Theme.completionPadding)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        .overlay {
            if loads {
                // No loading ring; the grid stands in its final shape, as in library, saved list and search. This page was the only genre version that showed a black screen while loading.
                GridPlaceholder()
                    .padding(.horizontal, Theme.edgePage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, Theme.barBottom + 90)
                    .transition(.opacity)
            } else if disrupted {
                // Disturbed is not empty: `title(genre:)` returns `nil` when the server does not answer; `?? []` turned that into an empty list and the page claimed the genre was empty. Same text as the library.
                EmptyState(
                    symbol: "externaldrive.badge.xmark",
                    title: "Server ist abgetaucht",
                    hint: "\(model.serverAddress ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                    button: ("Erneut versuchen", { Task { await load() } }))
            } else if items.isEmpty {
                // A way out, not a dead-end sign.
                EmptyState(symbol: "tag", title: "Nichts in diesem Genre",
                            hint: "In diesem Genre gibt es auf deinem Server gerade keine Filme und Serien.",
                            button: ("Aktualisieren", { Task { await load() } }))
            }
        }
        .animation(Theme.reveal, value: loads)
        .task(id: name) { await load() }
        // Seen/saved elsewhere: reload quietly, the list stays.
        .onChange(of: model.pagesRefresh) { _, _ in Task { await load(still: true) } }
    }

    private func load(still: Bool = false) async {
        if !still { loads = true }
        let answer = await model.title(genre: name, limit: 200)
        // Reloaded quietly and failed: the old state stays.
        if still, answer == nil { return }
        disrupted = answer == nil
        items = ListRules.withoutDouble(answer ?? [])
        loads = false
    }
}
