import JellyfinKit
import SwiftUI

/// **The episodes of the player layer as a horizontal strip of landscape cards**, the Mac
/// counterpart of `EpisodesStrip` on the TV (`Sources/tvOS/TitleRails.swift`): 16:9
/// thumbnail with progress bar and watched badge, "F3 · Title" above the runtime and the
/// remaining time. The TV moves focus from card to card; here the pointer hovers, the
/// trackpad scrolls, the arrow buttons and the keys left/right page, and the running
/// episode is marked by a larger card (no frame) and scrolled to the middle on opening.
///
/// A generic view like this could move to `Sources/Shared` if iOS wants the same cards;
/// the tile menu and `ImageArea` it uses are macOS-side today.
struct PlayerEpisodeStrip: View {
    let model: AppModel
    let episodes: [Item]
    /// The running episode.
    let currentID: String
    var afterwards: (() async -> Void)? = nil
    let start: (Item) -> Void
    /// Left margin, so the first card lines up with the layer's title.
    let leading: CGFloat
    let trailing: CGFloat

    @State private var position = ScrollPosition()
    @State private var width: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var total: CGFloat = 0
    @State private var canLeft = false
    @State private var canRight = false
    @State private var scrolledToCurrent = false

    private let spacing: CGFloat = 16
    /// Card width follows the window: three to four cards visible, never tiny or huge.
    private var cardWidth: CGFloat { min(max((width - leading - trailing) / 4 - spacing, 240), 360) }
    private var imageHeight: CGFloat { (cardWidth * 9 / 16).rounded() }

    /// The running card (1.25x) sets the strip's height; the regular cards sit at its bottom.
    private var hasCurrent: Bool { episodes.contains { $0.id == currentID } }

    var body: some View {
        ScrollView(.horizontal) {
            // Bottom: image bottoms and text lines share one baseline; the running card grows upwards.
            LazyHStack(alignment: .bottom, spacing: spacing) {
                ForEach(episodes) { episode in
                    EpisodeCardMac(model: model, episode: episode,
                                      isCurrent: episode.id == currentID,
                                      width: cardWidth, imageHeight: imageHeight) { start(episode) }
                        .tileMenu(episode, model: model, inPlayer: true, afterwards: afterwards)
                        .id(episode.id)
                }
            }
            .scrollTargetLayout()
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            // Room for the hover scale.
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
        .scrollPosition($position)
        // Hug the cards: without this the scroll view takes all the height the layer offers and the
        // bottom-aligned row sits at the screen bottom.
        .fixedSize(horizontal: false, vertical: true)
        .onScrollGeometryChange(for: [CGFloat].self) {
            [$0.contentOffset.x, $0.contentSize.width, $0.containerSize.width]
        } action: { _, new in
            offset = new[0]; total = new[1]; width = new[2]
            let fits = total <= width + 4
            let left = !fits && offset > 4
            let right = !fits && offset + width < total - 4
            if left != canLeft { canLeft = left }
            if right != canRight { canRight = right }
        }
        .overlay(alignment: .topLeading) {
            if canLeft { arrow("chevron.left", "Zurückblättern") { page(-1, cards: 3) } }
        }
        .overlay(alignment: .topTrailing) {
            if canRight { arrow("chevron.right", "Weiterblättern") { page(1, cards: 3) } }
        }
        .animation(Theme.timeArrow, value: canLeft)
        .animation(Theme.timeArrow, value: canRight)
        // Keys ← / → page by one card. Hidden buttons, so no focus is needed.
        .background {
            Group {
                Button("") { page(-1, cards: 1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { page(1, cards: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
            }
            .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
        // The running episode in the middle, unanimated, once the cards exist.
        .task(id: episodes.map(\.id)) {
            guard !scrolledToCurrent, episodes.contains(where: { $0.id == currentID }) else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            position.scrollTo(id: currentID, anchor: .center)
            scrolledToCurrent = true
        }
    }

    private func page(_ direction: CGFloat, cards: CGFloat) {
        let target = max(0, min(total - width, offset + direction * (cardWidth + spacing) * cards))
        withAnimation(Theme.reveal) { position.scrollTo(x: target) }
    }

    private func arrow(_ symbol: String, _ name: LocalizedStringKey,
                       _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            Image(icon: symbol)
                .font(Theme.listTitle)
                .foregroundStyle(Theme.font)
                .frame(width: 34, height: 34)
                .background(Theme.area,
                            in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityLabel(Text(name))
        .padding(.horizontal, 12)
        .offset(y: 8 + (hasCurrent ? imageHeight * 0.25 : 0) + imageHeight / 2 - 17)
        .transition(.opacity)
    }
}

/// One card: the TV `TileContent` in landscape form with Mac hover.
private struct EpisodeCardMac: View {
    let model: AppModel
    let episode: Item
    let isCurrent: Bool
    let width: CGFloat
    let imageHeight: CGFloat
    let pick: () -> Void

    @State private var hovers = false

    /// The running episode is simply bigger than the others, no frame.
    private var scale: CGFloat { isCurrent ? 1.25 : 1 }

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 8) {
                ImageArea(image: model.imageURL(for: episode, maxHeight: 360)
                                  ?? model.landscapeImageURL(for: episode, width: 640),
                          width: width * scale, height: imageHeight * scale,
                          // A bar and a badge would say the same twice.
                          progress: episode.isWatched ? nil : episode.watchedShare,
                          symbolText: episode.tileCharacter)
                    .colorMultiply(Color(white: episode.isWatched ? 0.45 : 1))
                    .overlay(alignment: .topTrailing) {
                        if episode.isWatched { TileBadge(mark: .watched) }
                    }
                    .scaleEffect(hovers && !Theme.motionReduced ? 1.04 : 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: headerLine)
                        .font(Theme.tile)
                        .foregroundStyle(hovers || isCurrent ? Theme.font : Theme.fontQuiet)
                        .lineLimit(1)
                    if let line = durationRow {
                        Text(verbatim: line)
                            .font(Theme.secondLine).monospacedDigit()
                            .foregroundStyle(Theme.fontVeryQuiet)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: width * scale, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [headerLine, durationRow].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    /// "F3 · Name", localized like the TV (German F, English E).
    private var headerLine: String {
        guard let number = episode.indexNumber else { return episode.name }
        return String(localized: "F\(number)") + " · " + episode.name
    }

    /// "52 Min.", and where something is started, the remainder behind it.
    private var durationRow: String? {
        var parts: [String] = []
        if DisplayRules.runtimeShow(seconds: episode.runtimeSeconds),
           let seconds = episode.runtimeSeconds {
            parts.append(String(localized: "\(Int(seconds / 60)) Min."))
        }
        if let rest = episode.remainingTimeText { parts.append(rest) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
