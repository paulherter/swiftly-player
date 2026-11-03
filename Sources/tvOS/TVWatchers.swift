import JellyfinKit
import SwiftUI

/// **Who has watched a title, in the button row** of the movie and series page: round avatars
/// after the buttons, each in a ring filled by ``Watcher/ring``. No heading: on a TV the button
/// row is where the eye already is, and a section of its own below cost a whole row of focus.
///
/// The focused avatar names itself to the right of the row: who, how often, when last
/// ("Anna · 2 × · gestern"). The text stands after the last avatar, so focus moving along the
/// row never shifts the buttons. Completely absent without the plugin, with the switch off,
/// or when nobody has watched the title.
struct WatcherDots: View {
    let model: AppModel
    let item: Item
    @State private var list: [Watcher] = []
    @FocusState private var focused: String?

    var body: some View {
        // **A stack, not a `Group`, carries the request.** A `Group` around an empty `if` is no
        // view at all, so its `.task` never ran and the avatars never asked anyone; an empty
        // stack is a view of zero size that appears like any other.
        HStack(spacing: 18) {
            if !list.isEmpty {
                ForEach(list) { watcher in
                    // Nothing to open, so no button: only a place focus can rest on.
                    WatcherDot(watcher: watcher, image: model.watcherImageURL(watcher),
                               focused: focused == watcher.id)
                        .focusable()
                        .focused($focused, equals: watcher.id)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: watcher.spoken()))
                }
                shownLine
            }
        }
        // Apart from the buttons, so the avatars do not read as one more button.
        .padding(.leading, list.isEmpty ? 0 : 40)
        .transition(.opacity)
        .task(id: "\(item.id)\(model.watchersShown)") {
            let found = await model.watchers(of: item)
            withAnimation(Theme.reveal) { list = found }
        }
    }

    /// Name and caption of the focused avatar; empty space otherwise.
    @ViewBuilder private var shownLine: some View {
        let shown = list.first { $0.id == focused }
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: shown.map { $0.name.isEmpty ? "?" : $0.name } ?? " ")
                .font(Theme.tile)
                .foregroundStyle(Theme.font)
            Text(verbatim: shown?.caption() ?? " ")
                .font(Theme.small)
                .foregroundStyle(Theme.fontQuiet)
        }
        .lineLimit(1)
        .padding(.leading, 8)
        .opacity(shown == nil ? 0 : 1)
        .animation(Theme.focusAnimation, value: focused)
        .accessibilityHidden(true)
    }
}

/// One avatar as tall as a button: track white 18 %, arc in the accent.
private struct WatcherDot: View {
    let watcher: Watcher
    let image: URL?
    let focused: Bool

    private let size: CGFloat = Theme.buttonHeight
    private let line: CGFloat = 4

    var body: some View {
        let inner = size - 2 * (line + 3)
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
        .scaleEffect(focused ? Theme.focusMagnifier : 1)
        .animation(Theme.focusAnimation, value: focused)
    }
}
