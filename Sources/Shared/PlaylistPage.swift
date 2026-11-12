import JellyfinKit
import SwiftlyCore
import SwiftUI

// MARK: - Playlists

/// **The playlist page is a collection page without sorting.**
///
/// The entries stand in the playlist's order (the server keeps it); sorting or
/// filtering would undo what someone arranged. Header, back arrow and grid are those
/// of ``CollectionView``. Next to the count sits "Abspielen": it starts the first
/// entry, and the player's "next episode" then walks along the list
/// (``AppModel/playlistStart(_:)``).
struct PlaylistView: View {
    let model: AppModel
    let playlist: Item
    let art: String?

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var core: PlaylistController?
    @State private var offset: CGFloat = 0
    @State private var prepares = false
    @State private var play: PlayRequest?
    /// The first entry has several versions and waits for the pick.
    @State private var versionChoice: VersionChoice?
    @State private var message: String?

    /// What this section shows: movies in "Movies", episodes in "Series"; without a
    /// section (search, watchlist) everything.
    private var shown: [SwiftlyCore.Tile] { core?.page.shown ?? [] }
    private var loads: Bool { core?.page.loading ?? !failedOpen }
    private var disrupted: Bool { failedOpen || (core?.page.disrupted ?? false) }
    /// No session, so the core could not even be opened: say so instead of loading forever.
    @State private var failedOpen = false

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            GeometryReader { frameRect in
                grid(columns: Theme.columns(usableNow: frameRect.size.width - 2 * Theme.margin(wide: wide),
                                             wide: wide))
            }
            if disrupted {
                EmptyState.serverDived(model, retry: { Task { await load() } })
            } else if shown.isEmpty, !loads {
                EmptyState(symbol: "tray",
                           headerLine: "Hier ist noch nichts",
                           text: "Sobald in dieser Wiedergabeliste etwas liegt, taucht es hier auf.",
                           quietButton: ("Aktualisieren", { Task { await load() } }))
            }
            if let message {
                HintStrip(text: message) { self.message = nil }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        .playerCover(item: $play) { wish in
            PlayerScreen(model: model, item: wish.item,
                         plan: wish.plan, startAt: wish.startAt)
        }
        .versionChoice($versionChoice) { choice, version in
            PlayRequest.start(choice, picking: version, model: model, prepares: $prepares,
                              missing: { message = String(localized: "Der Server hat keine Datei zu diesem Titel.") },
                              play: { play = $0 })
        }
        .catchUp(at: model.listenRefresh) { Task { await load() } }
        .task(id: "\(playlist.id)|\(model.accountSwitch)") { await load() }
    }

    private func load() async {
        if core == nil { core = try? AppCore.shared.playlist(session: model.session, playlist: playlist, art: art) }
        failedOpen = core == nil
        try? await core?.load()
    }

    private var header: some View {
        BlurHeader(offset: offset) {
            VStack(alignment: .leading, spacing: 0) {
                SubpageHeader(title: playlist.name, back: { back() }, bottom: 0) {
                    if wide, !shown.isEmpty { CountMark(count: shown.count) }
                }
                .padding(.horizontal, -Theme.margin(wide: wide))
                ValueRail(offset: offset) { controls }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            ValuePill(symbol: "play.fill", text: String(localized: "Abspielen")) { start() }
                .disabled(shown.isEmpty || prepares)
            Spacer(minLength: 8)
            if !wide, !shown.isEmpty { CountMark(count: shown.count) }
        }
        .frame(minHeight: 30)
    }

    /// From the first entry on; the rest follows through the player's
    /// "next episode".
    private func start() {
        guard core?.start() != nil, let first = model.playlistStart(shown.map { Item(rust: $0) }) else { return }
        Theme.jerk(.medium)
        PlayRequest.start(first, freshValue: true,
                          ask: VersionAsk(choose: { versionChoice = $0 },
                                          failed: { message = $0 }),
                          model: model, prepares: $prepares,
                          missing: { message = String(localized: "Der Server hat keine Datei zu diesem Titel.") },
                          play: { play = $0 })
    }

    private func grid(columns: Int) -> some View {
        ScrollView {
            if shown.isEmpty, loads {
                GridPlaceholder(columns: columns)
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 8)
                    .transition(.opacity)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.tileSpacing),
                                     count: columns),
                      alignment: .leading, spacing: Theme.gridRowGap) {
                ForEach(shown, id: \.id) { tile in
                    let item = Item(rust: tile)
                    NavigationLink(value: item) {
                        PosterTile(model: model, item: item, width: nil, coreLook: RustTileLook(tile))
                    }
                    .buttonStyle(Theme.PressButton())
                    .tileMenu(item, model: model)
                }
            }
            .padding(.horizontal, Theme.margin(wide: wide))
            .padding(.top, 8)
            .padding(.bottom, 40)
            .opacity(shown.isEmpty ? 0 : 1)
        }
        .scrollIndicators(.hidden)
        .animation(Theme.reveal, value: shown.isEmpty)
        .scrollDistance {
            let clamped = min(max($0, 0), Theme.valueRailsDistance)
            if clamped != offset { offset = clamped }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
    }
}
