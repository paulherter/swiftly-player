import JellyfinKit
import SwiftUI

/// Everything saved to the watchlist, across all libraries: the Mac version.
///
/// **A library like any other, except that its boundary is the checkmark.** Not a
/// folder on disk but what the user tapped, so movies and series are mixed here.
/// Structure and components are those of the library page: header with title and
/// count, chip row, grid. A page type of its own would be a second grammar for the
/// same thing.
///
/// **Wide shows options, narrow shows values:** on the iPhone there are two pills
/// with the current value, here the options stand open side by side. The reason is the
/// window size, which is why it is allowed.
struct WatchlistView: View {
    let model: AppModel
    /// Called by the header bar; there is no back arrow of its own here, `MainView` draws it above every pushed page.

    @State private var state: WatchlistModel

    init(model: AppModel) {
        self.model = model
        let freshValue = WatchlistModel()
        _state = State(initialValue: freshValue)
        _genre = State(initialValue: RememberGenre.toward(art: freshValue.genre))
    }
    /// The view's pill and the kind in the model must say the same at start: the model
    /// fetches it from storage, the view reads it from there.
    @State private var genre: RememberGenre

    /// Where the page stands, as its own object so a scroll tick does not re-evaluate the
    /// whole body. Reasoning at `HeaderState`.
    @State private var headerState = HeaderState()

    private var pullGait: Double {
        Double(min(max(headerState.offset / Theme.valueRailsDistance, 0), 1))
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.tileWidth, maximum: Theme.tileWidth),
                  spacing: Theme.tileSpacing, alignment: .topLeading)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Merkliste")
                        .font(Theme.titleLarge)
                        .tracking(Theme.lockTitle)
                        .foregroundStyle(Theme.font)
                    Spacer()
                    if state.total > 0 { CountMark(count: state.total) }
                }

                HStack(spacing: 8) {
                    // **Two buttons instead of six chips:** the same change as on Filme and Serien, so
                    // neighboring pages ask the same question the same way.
                    SelectionButton(symbol: "square.grid.2x2",
                              value: genre.label,
                              entries: RememberGenre.allCases,
                              label: { $0.label },
                              isSelected: { $0 == genre },
                              select: { fall in
                                  genre = fall
                                  state.genre = fall.art
                              })
                    SelectionButton(symbol: state.sorting.symbol,
                              value: state.sorting.label,
                              entries: Sorting.allCases,
                              label: { $0.label },
                              isSelected: { $0 == state.sorting },
                              select: { state.sorting = $0 })
                    Spacer(minLength: 0)
                }
                .padding(.top, 14)
                .opacity(1 - pullGait)
                .zIndex(20)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(state.items, id: \.id) { entryRecord in
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
                                         symbolText: entryRecord.tileCharacter)
                        }
                        .buttonStyle(Theme.PressButton())
                        .tileMenu(entryRecord, model: model)
                        .task {
                            if state.solvesLoadMoreOut(entryRecord.id, columns: 6) {
                                await state.loadMore(model)
                            }
                        }
                    }
                }
                .padding(.top, 22)
            }
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        // The look's glow, the same on every main page; goes up with the content.
        .lookGlow()
        .scrollIndicators(.never)
        .overlay(alignment: .top) {
            StateBar(title: "Merkliste", state: headerState)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
            headerState.offset = new
        }
        .pagesScroll()
        // No spinner: the grid already stands there in its shape.
        .overlay(alignment: .topLeading) {
            if state.items.isEmpty, state.loads {
                GridPlaceholder(columns: 6, rails: 2)
                    .padding(.horizontal, Theme.edgeSpacing)
                    .padding(.top, Theme.contentTop + 90)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if state.items.isEmpty, !state.loads {
                // **Disturbed is not empty.** The model distinguishes the two
                // (`WatchlistModel.disrupted`). Only one answer used to be shown, and the wrong one
                // sends the user to the server instead of the network.
                if state.disrupted {
                    EmptyState(
                        symbol: "externaldrive.badge.xmark",
                        headerLine: "Server ist abgetaucht",
                        text: "\(model.serverAddress ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                        primaryButton: ("Erneut versuchen", { Task { await state.load(model) } }))
                } else {
                    // **The empty state says how to get something in.** Otherwise it is a dead end.
                    EmptyState(symbol: "bookmark",
                                headerLine: "Noch nichts gemerkt",
                                text: "Auf jeder Film- und Serienseite steht „Merkliste“ in der Knopfreihe. Was du dort antippst, sammelt sich hier.")
                }
            }
        }
        .animation(Theme.reveal, value: state.items.isEmpty)
        .task(id: "\(state.identifier)|\(model.accountSwitch)|\(model.listenRefresh)") { await state.load(model) }
    }

    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section
}
