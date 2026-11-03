import JellyfinKit
import SwiftUI

/// **Who has watched a title** on movie and series pages: one row of round avatars, each with a
/// ring that fills with how far that person got (full ring = watched), without a heading, as on
/// Apple TV. A tap on an avatar names it: who, how often, when last, to the right of the row, or
/// under it when the row leaves no room. Completely absent when the server has no Jelly Twiggy
/// plugin, the switch is off, or nobody has watched the title.
struct WatchersRow: View {
    @Environment(\.wide) private var wide
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
                    HStack(spacing: 16) { avatars; shownLine }
                    VStack(alignment: .leading, spacing: 8) { avatars; shownLine }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.margin(wide: wide))
                // The rhythm "row to row" of the page (`Segment`), now without the heading.
                .padding(.top, Theme.railsSpacing)
                .transition(.opacity)
            }
        }
        .task(id: "\(item.id)\(model.watchersShown)") {
            let found = await model.watchers(of: item)
            withAnimation(Theme.reveal) { list = found }
        }
    }

    private var avatars: some View {
        HStack(spacing: 14) {
            ForEach(list) { watcher in
                Button {
                    withAnimation(Theme.reveal) { picked = picked == watcher.id ? nil : watcher.id }
                } label: {
                    WatcherAvatar(watcher: watcher, image: model.watcherImageURL(watcher), size: 60)
                }
                .buttonStyle(Theme.PressButton())
                .accessibilityLabel(Text(verbatim: watcher.spoken()))
            }
        }
        .fixedSize()
    }

    /// Name and caption of the tapped avatar; nothing before a tap.
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
