import JellyfinKit
import SwiftUI

/// **"Gesehen von"** on movie and series pages: one row of round avatars with a progress
/// ring. Name and "2 × · gestern" show as the hover help. Completely absent without the
/// plugin, with the switch off, or when nobody has watched the title.
struct WatchersRow: View {
    let model: AppModel
    let item: Item
    /// The core's own list (detail pages); `nil` fetches it here (other pages).
    var fromCore: [Watcher]? = nil
    @State private var fetched: [Watcher] = []
    private var list: [Watcher] { fromCore ?? fetched }

    var body: some View {
        Group {
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    RailTitle(text: "Gesehen von")
                    HStack(spacing: 22) {
                        ForEach(list) { watcher in
                            WatcherAvatar(watcher: watcher, image: model.watcherImageURL(watcher))
                                .help(watcher.spoken)
                                .accessibilityElement(children: .ignore)
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

/// Avatar with the progress ring: track white 18 %, arc in the accent, 3 pt.
struct WatcherAvatar: View {
    let watcher: Watcher
    let image: URL?
    private let size: CGFloat = 60

    var body: some View {
        let inner = size - 10
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 3)
            Circle()
                .trim(from: 0, to: watcher.ring)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
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
    }
}
