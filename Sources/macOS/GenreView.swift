import JellyfinKit
import SwiftUI

/// **All titles of one genre**, reached from the chips on the home screen.
///
/// Same grid and column calculation as Library and Search. Newest first:
/// people who tap a genre usually look for what is new.
struct GenreView: View {
    let model: AppModel
    let name: String
    let back: () -> Void

    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section

    @State private var items: [Item] = []
    @State private var loads = true
    /// **`nil` means failed, `[]` means empty.** `model.title` returns the two separately;
    /// collapsing them with `?? []` would turn a network error into
    /// "nothing in this genre".
    @State private var disrupted = false

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.tileWidth, maximum: Theme.tileWidth),
                  spacing: Theme.tileSpacing, alignment: .topLeading)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The name comes from the server and is not translated.
                SubpageHeader(name: name, back: back)

                // Shape first, then content, as in the library.
                if items.isEmpty, loads {
                    GridPlaceholder(columns: 6, rails: 2).padding(.top, 20)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(items, id: \.id) { entryRecord in
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
                                         symbolText: entryRecord.tileCharacter,
                                         prefetch: {
                SeriesCache.shared.prefetch(entryRecord, with: model)
                PlanPreAdvice.prefetch(entryRecord, with: model)
            })
                        }
                        .buttonStyle(Theme.PressButton())
                        .tileMenu(entryRecord, model: model)
                    }
                }
                .padding(.top, 20)

                if !loads, disrupted, items.isEmpty {
                    EmptyState(
                        symbol: "externaldrive.badge.xmark",
                        headerLine: "Server ist abgetaucht",
                        text: "\(model.serverAddress ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                        primaryButton: ("Erneut versuchen", { Task { await fetch() } }))
                        .padding(.top, 80)
                } else if !loads, items.isEmpty {
                    // **No button, on purpose.** An empty state only gets one when there is something
                    // to do; here the way out is the back button.
                    EmptyState(symbol: "tag", headerLine: "Nichts in diesem Genre",
                                text: "In diesem Genre gibt es auf deinem Server gerade keine Filme und Serien.")
                        .padding(.top, 80)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .pagesScroll()
        .task(id: "\(name)|\(model.listenRefresh)") { await fetch() }
    }

    private func fetch() async {
        loads = items.isEmpty
        let result = await model.title(genre: name, limit: 200)
        disrupted = result == nil
        items = result ?? []
        loads = false
    }
}
