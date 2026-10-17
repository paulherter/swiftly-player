import JellyfinKit
import SwiftUI

/// A title the own server does not have yet.
///
/// **Faded, and that is the whole message.** Someone scrolling quickly should
/// see without reading a word that there is nothing to play here. The
/// heading above only confirms it; it is not the explanation.
struct SeerrTile: View {
    let hit: SeerrHit
    /// **Fixed width for a row.** In a grid the column dictates the width; in a
    /// horizontal row there is none, and the poster with its aspect ratio shrank
    /// to postage-stamp size, as seen on the person page. `nil` means as wide as
    /// the space says.
    var width: CGFloat? = nil
    /// Poster and text fade in together, same reasoning as `PosterTile`.
    @State private var present = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Picture(url: hit.poster(), corner: Theme.cornerTile)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .opacity(0.45)
                badge
                    .padding(6)
            }
            Text(verbatim: hit.title)
                .font(Theme.tile)
                .foregroundStyle(Theme.fontQuiet)
                .lineLimit(1)
            Text(verbatim: subtitle)
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
        .accessibilityLabel(Text(verbatim: "\(hit.title), \(announcement)"))
    }

    private var subtitle: String {
        let art = hit.isSeries ? String(localized: "Serie") : String(localized: "Film")
        return hit.year.map { "\($0) · \(art)" } ?? art
    }

    /// **The same symbols as on the page behind.** The table is in
    /// `SeerrMark.swift`; here is only how it looks: symbol and, where it adds
    /// something, a word.
    @ViewBuilder
    private var badge: some View {
        if hit.state != .present {
            HStack(spacing: 3) {
                Image(systemName: hit.state.symbol)
                    // The symbol size stays a number, since a glyph is not on any type ladder.
                    // Only the weight changes: bold appears exactly once, on the page title,
                    // and the word next to it is semibold anyway.
                    .font(.system(size: 10, weight: .semibold))
                if let word = hit.state.shortWord {
                    // Badge from the ladder, 10 semibold.
                    Text(verbatim: word).font(Theme.badge)
                }
            }
            .foregroundStyle(Theme.reason)
            .padding(.horizontal, hit.state.shortWord == nil ? 5 : 7)
            .padding(.vertical, 3)
            .background(hit.state.color, in: Capsule())
        }
    }

    private var announcement: String { hit.state.announcement }
}
