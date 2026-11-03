import JellyfinKit
import SwiftUI

/// **Who has watched a title** on movie and series pages: one row of round avatars with a
/// progress ring, without a heading, as on iPhone and Apple TV. A click on an avatar names it
/// (who, how often, when last) to the right of the row, or under it when the window leaves no
/// room; hovering shows the same as help. Completely absent without the plugin, with the switch
/// off, or when nobody has watched the title.
struct WatchersRow: View {
    let model: AppModel
    let item: Item
    @State private var list: [Watcher] = []
    @State private var picked: String?

    var body: some View {
        // **A stack, not a `Group`, carries the request.** A `Group` around an empty `if` is no
        // view at all, so its `.task` never ran and the row never asked anyone; an empty stack
        // is a view of zero height that appears like any other.
        VStack(spacing: 0) {
            if !list.isEmpty {
                // Beside the avatars where they leave room, otherwise below them.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 22) { avatars; shownLine }
                    VStack(alignment: .leading, spacing: 10) { avatars; shownLine }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
        .task(id: "\(item.id)\(model.watchersShown)") {
            let found = await model.watchers(of: item)
            withAnimation(Theme.reveal) { list = found }
        }
    }

    private var avatars: some View {
        HStack(spacing: 22) {
            ForEach(list) { watcher in
                Button {
                    withAnimation(Theme.reveal) { picked = picked == watcher.id ? nil : watcher.id }
                } label: {
                    WatcherAvatar(watcher: watcher, image: model.watcherImageURL(watcher))
                }
                .buttonStyle(Theme.PressButton())
                .help(watcher.spoken())
                .accessibilityLabel(Text(verbatim: watcher.spoken()))
            }
        }
        .fixedSize()
    }

    /// Name and caption of the clicked avatar; nothing before a click.
    @ViewBuilder private var shownLine: some View {
        if let shown = list.first(where: { $0.id == picked }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: shown.name.isEmpty ? "?" : shown.name)
                    .font(Theme.small.weight(.semibold))
                    .foregroundStyle(Theme.font)
                let caption = shown.caption()
                if !caption.isEmpty {
                    Text(verbatim: caption)
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontQuiet)
                }
            }
            .lineLimit(1)
            .fixedSize()
            .transition(.opacity)
            .accessibilityHidden(true)
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
