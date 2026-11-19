import SwiftUI

/// Thin progress bar at the bottom edge of a tile.
///
/// Measures itself instead of the surrounding frame. `containerRelativeFrame`
/// took the width of the nearest *container*; in a horizontal row that is the
/// whole row, not the tile. The bar then ran far beyond the tile and even pushed
/// the title down in the "Continue Watching" row. `GeometryReader` doesn't work
/// here either: it expands greedily. `onGeometryChange` measures without touching
/// the layout.
struct ProgressBar: View {
    let share: Double
    /// **Capsule where it stands free in a row**, as in the download list. On a tile
    /// it stays square: there it forms the edge of the image, and a rounded edge would
    /// sit in front of it.
    var round = false
    @State private var width: CGFloat = 0

    /// **Flush with the bottom edge, not floating.**
    ///
    /// It used to float: eight points of spacing, capsule shape. Feedback on device:
    /// it looked better at the bottom. A bar that forms the edge reads as part of the
    /// image; one that floats inside reads as a second thing on top of it.
    var body: some View {
        ZStack(alignment: .leading) {
            // **Light track, not dark.**
            //
            // It was light once, then dark, and the reason for that was "a light gray
            // disappears on light posters". That is true for a *gray*; white at 30 percent
            // does not disappear, it lies on top as a veil, and it is what Apple's TV app
            // shows on its cards. Feedback: "we had it light before too, that looked
            // better."
            //
            // The difference is not taste. Read as dark, the bar says "something is missing
            // here"; read as light, it says "this is how long the whole thing is, and this
            // is how far you are": the track is the length, not the remainder. And on a tile
            // that is itself framed dark, the dark track vanished into the edge.
            Rectangle().fill(Color.white.opacity(0.30))
            // The filled part is a capsule itself, otherwise it ends straight on the inside.
            (round ? AnyShape(Capsule()) : AnyShape(Rectangle()))
                .fill(Theme.accent)
                .frame(width: width * min(max(share, 0), 1))
        }
        .clipShape(round ? AnyShape(Capsule()) : AnyShape(Rectangle()))
        // Four points instead of three; at three it was barely visible on the tiles.
        .frame(height: 4)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
