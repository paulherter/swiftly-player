import JellyfinKit
import SwiftUI

// MARK: - Playlists

/// A video playlist opened from "Movies" or "Series".
struct PlaylistRoute: Hashable {
    let playlist: Item
    let art: String?
}

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
    @State private var entries: [Item] = []
    @State private var loads = true
    @State private var disrupted = false
    @State private var offset: CGFloat = 0
    @State private var prepares = false
    @State private var play: PlayRequest?
    @State private var message: String?

    /// What this section shows: movies in "Movies", episodes in "Series"; without a
    /// section (search, watchlist) everything.
    private var shown: [Item] {
        switch art {
        case "movies":  entries.filter { $0.type == "Movie" || $0.type == "Video" }
        case "tvshows": entries.filter { $0.type == "Episode" || $0.type == "Series" }
        default:        entries
        }
    }

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
        .catchUp(at: model.listenRefresh) { Task { await load() } }
        .task(id: "\(playlist.id)|\(model.accountSwitch)") { await load() }
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

    private var header: some View {
        BlurHeader(offset: offset) {
            VStack(alignment: .leading, spacing: 0) {
                SubpageHeader(title: playlist.name, back: { back() }, bottom: 0) {
                    if wide, !shown.isEmpty { CountMark(count: shown.count) }
                }
                .padding(.horizontal, -Theme.margin(wide: wide))
                if wide {
                    controls.padding(.top, 14)
                } else {
                    ValueRail(offset: offset) { controls }
                }
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
        guard let first = model.playlistStart(shown) else { return }
        Theme.jerk(.medium)
        PlayRequest.start(first, freshValue: true, model: model, prepares: $prepares,
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
                      alignment: .leading, spacing: 20) {
                ForEach(shown) { item in
                    NavigationLink(value: item) {
                        PosterTile(model: model, item: item, width: nil)
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
        .scrollDistance { offset = $0 }
        .safeAreaInset(edge: .top, spacing: 0) { header }
    }
}
