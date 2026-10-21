import JellyfinKit
import SwiftUI

/// Everything saved, across all libraries: the TV version.
/// A library like any other, except that its boundary is the check mark, not a
/// folder: movies and series are mixed. Structure and parts are those of the
/// library page (chip row, count, grid, tile marks, placeholder instead of ring).
/// Here it is its own section rather than a target from a corner: on iPhone the
/// fourth tab slot belongs to Downloads, which a TV does not have, so the header
/// bar slot is free, and a tab is the shortest path with a remote.
struct WatchlistView: View {
    let model: AppModel

    @State private var state: WatchlistModel

    init(model: AppModel) {
        self.model = model
        let freshValue = WatchlistModel()
        _state = State(initialValue: freshValue)
        _genre = State(initialValue: RememberGenre.toward(art: freshValue.genre))
    }
    /// The pill of the view and the kind in the model must agree at start: the
    /// model takes it from storage and the view reads it from there.
    @State private var genre: RememberGenre
    /// As in the library. Sorting was a second chip row beside the kind, while on
    /// movies and series it is a button that opens a panel under it; two versions of
    /// the same question on neighbouring pages. The chip row also did not catch the
    /// Menu button, so Back left the page instead of closing the choice. The kind is
    /// now a capsule too: it is a choice, not a filter, since exactly one is always
    /// on. On iPhone it has always sat behind a button (`SelectionSheet`, kind).
    @State private var openPanel: Panel?
    @FocusState private var atTrigger: Panel?

    /// At most one panel is open. The same id says on closing which capsule focus returns to, as in `LibraryView`.
    private enum Panel: Hashable {
        case genre, sorting

        /// Name of the button the panel hangs on; see `PanelAnchor`.
        var firer: String { self == .genre ? "gattung" : "sortierung" }
    }
    @Environment(\.panelOpen) private var panelOpen

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Theme.gridColumn),
              count: Theme.gridColumns)
    }

    var body: some View {
        ZStack {
            if state.items.isEmpty, state.loads {
                GridPlaceholder()
                    .padding(.horizontal, Theme.edgePage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, Theme.gridTop)
                    .transition(.opacity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.capsuleRailPadding) {
                        chipRail
                        if state.disrupted, state.items.isEmpty {
                            // Disturbed is not empty: `state.disrupted` was in the model but not read, so a full list with a silent server showed "nothing saved", which is wrong. Same text as the library: one cause, one diagnosis.
                            EmptyState(
                                symbol: "externaldrive.badge.xmark",
                                title: "Server ist abgetaucht",
                                hint: "\(model.serverAddress ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                                button: ("Erneut versuchen", { Task { await state.load(model) } }))
                                .frame(height: 460)
                        } else if state.items.isEmpty {
                            // The empty state says how to get in; otherwise it is a dead end, worse with a remote.
                            EmptyState(symbol: "bookmark",
                                        title: "Noch nichts gemerkt",
                                        hint: "Auf jeder Film- und Serienseite steht „Merkliste“ in der Knopfreihe. Was du dort auswählst, sammelt sich hier.",
                                        button: ("Aktualisieren", { Task { await state.load(model) } }))
                                .frame(height: 460)
                        } else {
                            lattice
                        }
                    }
                    // Top edge like every main page; see `Theme.contentTop`.
                    .padding(.top, Theme.contentTop - Theme.edgeTop)
                    .padding(.bottom, 60)
                    .padding(.horizontal, Theme.edgePage)
                }
                // The look's glow, the same on every main page; goes up with the content.
                .lookGlow()
            }
        }
        // The side system margin is dropped, as in the library and home. Otherwise `edgePage` sits on the margin tvOS already keeps free and the spacing applies twice: the chip row stood about sixty points further right than on movies and series.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .horizontal)
        // Nothing behind the open panel is focusable, as in the library; otherwise focus climbs out of the panel.
        .disabled(openPanel != nil)
        // Under its button, at its edge; see `PanelAnchor`. Fixed offsets from the edge would be off by the safe margin; same spot as on the movie page.
        .panel(under: openPanel?.firer) {
            ActionPanel(actions: openPanel == .genre
                                       ? genreActions : sortActions,
                           opened: panelBinding)
                .transition(.opacity)
        }
        .animation(Theme.motion(.easeInOut(duration: 0.18)), value: openPanel)
        // The page switches itself off, but the header bar is not its own; `MainView` must disable it.
        .onChange(of: openPanel) { alt, new in
            panelOpen.wrappedValue = new != nil
            if new == nil, let alt { atTrigger = alt }
        }
        .onDisappear { panelOpen.wrappedValue = false }
        .animation(Theme.reveal, value: state.items.isEmpty)
        .task(id: "\(state.identifier)|\(model.accountSwitch)|\(model.listenRefresh)") { await state.load(model) }
    }

    private var chipRail: some View {
        HStack(alignment: .center, spacing: 20) {
            Button { openPanel = .genre } label: {
                Text(genre.label)
            }
            .buttonStyle(CapsuleStyle())
            .focused($atTrigger, equals: .genre)
            .panelTrigger(Panel.genre.firer)
            .accessibilityLabel(Text("Gattung, \(genre.label)"))

            // Built as on movies and series: the choice first, the rule, then sorting with its glyph, left and in the same order and style. Only the count is on the right.
            CapsuleSeparator()

            Button { openPanel = .sorting } label: {
                Text(state.sorting.label)
            }
            .buttonStyle(CapsuleStyle(symbol: "arrow.up.arrow.down"))
            .focused($atTrigger, equals: .sorting)
            .panelTrigger(Panel.sorting.firer)
            .accessibilityLabel(Text("Sortierung, \(state.sorting.label)"))

            Spacer(minLength: 40)

            if state.total > 0 {
                Text("\(state.total) Titel")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
            }
        }
        // Same fixed height as the library row.
        .frame(height: Theme.chipHeight)
        .focusSection()
    }

    /// `Handlungstafel` knows only open or closed; closed here means no panel.
    private var panelBinding: Binding<Bool> {
        Binding(get: { openPanel != nil },
                set: { if !$0 { openPanel = nil } })
    }

    /// The kinds as a panel, with the same glyphs as the library choice.
    private var genreActions: [TitleAction] {
        RememberGenre.allCases.map { fall in
            TitleAction(symbol: genre == fall ? "checkmark.circle.fill" : "circle",
                          text: LocalizedStringKey(fall.label)) {
                genre = fall
                state.genre = fall.art
            }
        }
    }

    private var sortActions: [TitleAction] {
        Sorting.allCases.map { fall in
            // Check mark and empty circle, as in `LibraryView`; a check against a sort glyph would be two meanings in one column.
            TitleAction(symbol: state.sorting == fall ? "checkmark.circle.fill" : "circle",
                          // `label` is a finished string, translated in the model, not here.
                          text: LocalizedStringKey(fall.label)) {
                state.sorting = fall
            }
        }
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
                .onAppear {
                    guard state.solvesLoadMoreOut(item.id, columns: Theme.gridColumns)
                    else { return }
                    Task { await state.loadMore(model) }
                }
            }
        }
    }
}
