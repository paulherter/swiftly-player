import JellyfinKit
import SwiftUI

/// **A video playlist as a page.** Template: `PlaylistView` in
/// `Sources/Shared/PlaylistPage.swift` (iPhone and iPad).
///
/// The entries stand in the playlist's order (the server keeps it); sorting or
/// filtering would undo what someone arranged, so there are neither. Name on top,
/// "Abspielen" and the count in the capsule row, then the grid. "Abspielen" starts the
/// first entry; the player's "next episode" then walks along the list
/// (``AppModel/playlistStart(_:)``).
struct PlaylistView: View {
    let model: AppModel
    let playlist: Item
    let art: String?

    @Environment(\.playRequest) private var play
    @State private var entries: [Item] = []
    @State private var loads = true
    @State private var disrupted = false
    @State private var prepares = false
    @FocusState private var atTitle: String?
    @State private var lastAtTitle: String?

    private var shown: [Item] { AppModel.playlistShown(entries, art: art) }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Theme.gridColumn),
              count: Theme.gridColumns)
    }

    var body: some View {
        ZStack {
            if loads {
                GridPlaceholder()
                    .padding(.horizontal, Theme.edgePage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, Theme.gridTop)
                    .transition(.opacity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.capsuleRailPadding) {
                        // The name comes from the server and is not translated.
                        RailTitle(name: playlist.name)
                            .padding(.horizontal, Theme.edgePage)
                        controls
                        if shown.isEmpty { empty } else { lattice }
                    }
                    .padding(.top, Theme.headerOffsetDetail + 40 - Theme.edgeTop)
                    .padding(.bottom, 60)
                }
                .scrollIndicators(.hidden)
                .lookGlow()
                .defaultFocus($atTitle, lastAtTitle,
                              priority: lastAtTitle == nil ? .automatic : .userInitiated)
                .onChange(of: atTitle) { _, now in
                    if let now { lastAtTitle = now }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.reason.ignoresSafeArea())
        .ignoresSafeArea(edges: .horizontal)
        .animation(Theme.reveal, value: loads)
        .task(id: "\(playlist.id)|\(model.accountSwitch)|\(model.listenRefresh)") { await load() }
    }

    private var controls: some View {
        HStack(spacing: 20) {
            Button { start() } label: {
                Text("Abspielen")
            }
            .buttonStyle(CapsuleStyle(symbol: "play.fill"))
            .disabled(shown.isEmpty || prepares)
            Spacer(minLength: 40)
            if !shown.isEmpty {
                Text("\(shown.count) Titel")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
            }
        }
        .frame(height: Theme.chipHeight)
        .focusSection()
        .padding(.horizontal, Theme.edgePage)
    }

    private var lattice: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.latticeRow) {
            ForEach(shown) { item in
                NavigationLink(value: item) {
                    TileContent(image: model.imageURL(for: item, maxHeight: 600, portrait: true),
                                 title: item.name,
                                 progress: item.userData?.playedPercentage.map { $0 / 100 },
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
            }
        }
        .padding(.horizontal, Theme.edgePage)
        .scrollClipDisabled()
    }

    @ViewBuilder
    private var empty: some View {
        if disrupted {
            EmptyState(
                symbol: "externaldrive.badge.xmark",
                title: "Server ist abgetaucht",
                hint: "\(model.serverAddress ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                button: ("Erneut versuchen", { Task { await load() } }))
            .frame(height: 500)
        } else {
            EmptyState(
                symbol: "tray",
                title: "Hier ist noch nichts",
                hint: "Sobald in dieser Wiedergabeliste etwas liegt, taucht es hier auf.",
                button: ("Aktualisieren", { Task { await load() } }))
            .frame(height: 500)
        }
    }

    private func load() async {
        let found = await model.playlistEntries(playlist)
        if let found {
            entries = found
            disrupted = false
        } else {
            disrupted = entries.isEmpty
        }
        loads = false
    }

    /// From the first entry on; the rest follows through the player's "next episode".
    private func start() {
        guard let first = model.playlistStart(shown) else { return }
        PlayRequest.start(first, freshValue: true, model: model, prepares: $prepares,
                          play: { play.wrappedValue = $0 })
    }
}
