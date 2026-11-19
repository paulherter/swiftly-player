import JellyfinKit
import SwiftUI
import SwiftlyCore

/// A title the own server does not have yet.
///
/// **Faded, and that is the whole message.** Someone scrolling quickly should
/// see without reading a word that there is nothing to play here. The
/// heading above only confirms it; it is not the explanation.
struct SeerrTile: View {
    /// What the tile draws, whichever record it came from.
    private struct Look {
        var poster: URL?
        var title: String
        var subtitle: String
        var symbol: String?
        var word: String?
        var tint: Color = Theme.fontQuiet
        /// 0...1 where the title is on its way (a thin bar cut by the poster's corners).
        var progress: Double?
        /// What VoiceOver reads (the whole line).
        var announcement: String
    }

    private let look: Look
    /// **Fixed width for a row.** In a grid the column dictates the width; in a
    /// horizontal row there is none, and the poster with its aspect ratio shrank
    /// to postage-stamp size, as seen on the person page. `nil` means as wide as
    /// the space says.
    var width: CGFloat? = nil
    /// Poster and text fade in together, same reasoning as `PosterTile`.
    @State private var present = false

    /// From the search hit of the old surfaces (desktop-style routes).
    init(hit: JellyfinKit.SeerrHit, width: CGFloat? = nil) {
        let art = hit.isSeries ? String(localized: "Serie") : String(localized: "Film")
        look = Look(
            poster: hit.poster(), title: hit.title,
            subtitle: hit.year.map { "\($0) · \(art)" } ?? art,
            symbol: hit.state == .present ? nil : hit.state.symbol, word: hit.state.shortWord,
            tint: hit.state.color, progress: nil, announcement: hit.state.announcement)
        self.width = width
    }

    /// From the core's tile: its badge says everything (symbol, short word, progress), the colour follows its kind.
    init(card: SwiftlyCore.SeerrTileCard, width: CGFloat? = nil) {
        let art = card.art == "tv" ? String(localized: "Serie") : String(localized: "Film")
        look = Look(
            poster: card.poster.flatMap { URL(string: $0) }, title: card.title,
            subtitle: card.year.map { "\($0) · \(art)" } ?? art,
            symbol: card.badge?.symbol, word: card.badge?.word,
            tint: card.badge?.kind.tint ?? Theme.fontQuiet,
            // The core's line already starts with the title ("Nordstern, Wird geholt · 62 %").
            progress: card.badge?.progress.map(Double.init), announcement: card.announcement)
        self.width = width
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Picture(url: look.poster, corner: Theme.cornerTile)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .opacity(0.45)
                if let progress = look.progress {
                    ProgressBar(share: progress)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                badge
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
            Text(verbatim: look.title)
                .font(Theme.tile)
                .foregroundStyle(Theme.fontQuiet)
                .lineLimit(1)
            Text(verbatim: look.subtitle)
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
                .lineLimit(1)
        }
        .frame(width: width)
        .opacity(present ? 1 : 0)
        .onAppear {
            guard !present else { return }
            withAnimation(Theme.reveal) { present = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: look.announcement.hasPrefix(look.title) ? look.announcement
                                                                                 : "\(look.title), \(look.announcement)"))
    }

    /// **The same symbols as on the page behind.** The table is in `SeerrMark.swift`.
    @ViewBuilder
    private var badge: some View {
        if let symbol = look.symbol {
            SeerrBadgeCapsule(symbol: symbol, word: look.word, tint: look.tint)
        }
    }
}
