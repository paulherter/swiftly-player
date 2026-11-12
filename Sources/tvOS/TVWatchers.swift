import JellyfinKit
import SwiftUI

/// **"Gesehen von"** on movie and series pages: a row of round avatars with a progress ring.
/// The focused avatar shows name and "2 × · gestern" below it. Completely absent without the
/// plugin, with the switch off, or when nobody has watched the title.
struct WatchersStrip: View {
    let model: AppModel
    let item: Item
    /// The core's own list (detail pages); `nil` fetches it here (other pages).
    var fromCore: [Watcher]? = nil
    @State private var fetched: [Watcher] = []
    private var list: [Watcher] { fromCore ?? fetched }

    var body: some View {
        Group {
            if !list.isEmpty {
                railsSection {
                    RailTitle(text: "Gesehen von")
                } content: {
                    strip {
                        ForEach(list) { watcher in
                            // Nothing to open, so no button: only a place focus can rest on.
                            WatcherTile(watcher: watcher, image: model.watcherImageURL(watcher))
                                .focusable()
                            .accessibilityLabel(Text(verbatim: watcher.spoken))
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .task(id: "\(item.id)\(model.watchersShown)") {
            guard fromCore == nil else { return }
            let found = await model.watchers(of: item)
            withAnimation(Theme.reveal) { fetched = found }
        }
    }
}

private struct WatcherTile: View {
    let watcher: Watcher
    let image: URL?
    @Environment(\.isFocused) private var focus

    private let size: CGFloat = 150
    private let line: CGFloat = 5

    var body: some View {
        let inner = size - 2 * (line + 4)
        VStack(spacing: 0) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.18), lineWidth: line)
                Circle()
                    .trim(from: 0, to: watcher.ring)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                ZStack {
                    Theme.raised
                    Text(verbatim: watcher.initial)
                        .font(.app(size: inner * 0.42, weight: .semibold))
                        .foregroundStyle(Theme.font)
                    if let image {
                        NetworkImage(url: image, displayEdge: inner)
                    }
                }
                .frame(width: inner, height: inner)
                .clipShape(Circle())
            }
            .frame(width: size, height: size)

            // Reserved height, so the row does not change size with focus.
            VStack(spacing: 2) {
                Text(verbatim: watcher.name)
                    .font(Theme.tile)
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
                Text(verbatim: watcher.caption)
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontQuiet)
                    .lineLimit(1)
            }
            .padding(.top, 14)
            .frame(width: 260, height: 70, alignment: .top)
            .opacity(focus ? 1 : 0)
            .animation(Theme.focusAnimation, value: focus)
        }
        .frame(width: 260)
        .scaleEffect(focus ? Theme.focusMagnifier : 1)
        .animation(Theme.focusAnimation, value: focus)
    }
}
