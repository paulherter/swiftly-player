import JellyfinKit
import SwiftUI

/// **"Gesehen von"** on movie and series pages: one row of round avatars, each with a ring
/// that fills with how far that person got (full ring = watched). Completely absent when the
/// server has no Jelly Twiggy plugin, the switch is off, or nobody has watched the title.
/// A tap shows the name and "2 × · gestern" under the row.
struct WatchersRow: View {
    @Environment(\.wide) private var wide
    let model: AppModel
    let item: Item
    @State private var list: [Watcher] = []
    @State private var picked: String?

    var body: some View {
        Group {
            if !list.isEmpty {
                Segment(title: "Gesehen von") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 14) {
                            ForEach(list) { watcher in
                                Button {
                                    withAnimation(Theme.reveal) { picked = picked == watcher.id ? nil : watcher.id }
                                } label: {
                                    WatcherAvatar(watcher: watcher, image: model.watcherImageURL(watcher), size: 60)
                                }
                                .buttonStyle(Theme.PressButton())
                                .accessibilityLabel(Text(verbatim: watcher.spoken))
                            }
                        }
                        if let shown = list.first(where: { $0.id == picked }) {
                            Text(verbatim: shown.spoken)
                                .font(Theme.small)
                                .foregroundStyle(Theme.fontQuiet)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, Theme.margin(wide: wide))
                }
                .transition(.opacity)
            }
        }
        .task(id: "\(item.id)\(model.watchersShown)") {
            let found = await model.watchers(of: item)
            withAnimation(Theme.reveal) { list = found }
        }
    }
}

/// Avatar with the progress ring: track white 18 %, arc in the accent, 3 pt.
struct WatcherAvatar: View {
    let watcher: Watcher
    let image: URL?
    let size: CGFloat

    var body: some View {
        let inner = size - 10
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 3)
            Circle()
                .trim(from: 0, to: watcher.ring)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Picture(url: image, width: inner, height: inner, corner: inner / 2) {
                ZStack {
                    Theme.raised
                    Text(verbatim: watcher.initial)
                        .font(.app(size: inner * 0.42, weight: .semibold))
                        .foregroundStyle(Theme.font)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
    }
}
