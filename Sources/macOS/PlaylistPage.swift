import JellyfinKit
import SwiftUI

/// **A video playlist as a subpage.** Template: `PlaylistView` in
/// `Sources/Shared/PlaylistPage.swift` (iPhone and iPad).
///
/// The entries stand in the playlist's order (the server keeps it); sorting or
/// filtering would undo what someone arranged, so there are neither. Back arrow in the
/// bar, name, "Abspielen" and the count, then the grid. "Abspielen" starts the first
/// entry; the player's "next episode" then walks along the list
/// (``AppModel/playlistStart(_:)``).
struct PlaylistPage: View {
    let model: AppModel
    let playlist: Item
    let art: String?
    let back: () -> Void

    @Environment(Navigator.self) private var navigator
    @Environment(PlayControls.self) private var controls
    @Environment(\.section) private var section
    @State private var entries: [Item] = []
    @State private var loads = true
    @State private var disrupted = false
    @State private var headerState = HeaderState()

    private var shown: [Item] { AppModel.playlistShown(entries, art: art) }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.tileWidth, maximum: Theme.tileWidth),
                  spacing: Theme.tileSpacing, alignment: .topLeading)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    // The name comes from the server and is not translated.
                    Text(verbatim: playlist.name)
                        .font(Theme.titleLarge)
                        .tracking(Theme.lockTitle)
                        .foregroundStyle(Theme.font)
                    Spacer()
                    if !shown.isEmpty { CountMark(count: shown.count) }
                }

                HStack {
                    PrimaryButton(label: "Abspielen") { start() }
                        .frame(width: 200)
                        .disabled(shown.isEmpty || controls.prepares)
                    Spacer(minLength: 0)
                }
                .padding(.top, 14)

                if shown.isEmpty, loads {
                    GridPlaceholder(columns: 6, rails: 2)
                        .padding(.top, 22)
                        .allowsHitTesting(false)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(shown, id: \.id) { item in
                        Button { navigator.openIt(.title(item), in: section) } label: {
                            PosterCell(title: item.name,
                                         secondLine: item.productionYear.map { "\($0)" },
                                         image: model.imageURL(for: item, portrait: true),
                                         progress: item.userData?.playedPercentage.map { $0 / 100 },
                                         mark: DisplayRules.tileMark(
                                            art: item.type,
                                            seasons: item.childCount,
                                            watched: item.userData?.played,
                                            openEpisodes: item.userData?.unplayedItemCount),
                                         symbolText: item.type == "Movie" ? "film" : "tv")
                        }
                        .buttonStyle(Theme.PressButton())
                        .tileMenu(item, model: model)
                    }
                }
                .padding(.top, 22)

                if shown.isEmpty, !loads {
                    if disrupted {
                        EmptyState(
                            symbol: "externaldrive.badge.xmark",
                            headerLine: "Server ist abgetaucht",
                            text: "\(model.serverAddress ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                            primaryButton: ("Erneut versuchen", { Task { await load() } }))
                            .padding(.top, 80)
                    } else {
                        EmptyState(
                            symbol: "tray",
                            headerLine: "Hier ist noch nichts",
                            text: "Sobald in dieser Wiedergabeliste etwas liegt, taucht es hier auf.",
                            quietButton: ("Aktualisieren", { Task { await load() } }))
                            .padding(.top, 80)
                    }
                }
            }
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        .lookGlow()
        .scrollIndicators(.never)
        .overlay(alignment: .top) {
            StateBar(title: "", name: playlist.name, state: headerState, back: back)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
            headerState.offset = new
        }
        .task(id: "\(playlist.id)|\(model.accountSwitch)|\(model.listenRefresh)") { await load() }
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
        controls.launch(first)
    }
}
