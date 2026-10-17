import SwiftUI

/// The background image of a detail page: **on the right, not across the full
/// width**, and faded out with a mask rather than a paint-over.
///
/// Taken from the tvOS version (`Backdrop` and `BackdropsFade` in
/// `Sources/tvOS/TVComponents.swift`), scaled to window dimensions: there 1180 x 700
/// in a 1920-wide frame, here the same proportion.
///
/// **Why a mask and not a paint-over:** a paint-over ends in opaque `Theme.reason`
/// and so assumes the background is exactly that. As soon as the background tints
/// itself (see `ImageColor`), the painted area shows as a patch. A mask ends in
/// transparency, and whatever lies behind shows through.
struct Backdrop: View {
    let url: URL?
    var height: CGFloat

    /// **What is showing, not what is being requested.** After the entry animation
    /// (`InTravel`) the full title arrives, sometimes with a different image URL.
    /// `NetworkImage` clears its image on a new URL and reloads, causing a brief black at
    /// the end of the move. Here the old image stays until the new one is decoded in
    /// memory, then cross-fades. The same URL does nothing.
    @State private var shown: URL?

    var body: some View {
        GeometryReader { space in
            let width = max(space.size.width * 0.62, 520)
            ZStack {
                NetworkImage(url: shown ?? url)
                    .id(shown ?? url)
                    .transition(.opacity)
            }
            .frame(width: width, height: height)
            .clipped()
            .backdropsFade()
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .task(id: url) {
            guard let url else { return }
            guard let alt = shown else { shown = url; return }
            guard url != alt else { return }
            // Load first, then swap; never empty in between.
            _ = await ImageCache.shared.load(url)
            guard !Task.isCancelled else { return }
            withAnimation(Theme.reveal) { shown = url }
        }
    }

}

extension View {
    func backdropsFade() -> some View { modifier(BackdropsFade()) }
}

/// The curve is taken unchanged from the tvOS version, where it came out of four
/// rebuilds; the comment there explains why every change made it worse.
struct BackdropsFade: ViewModifier {
    func body(content: Content) -> some View {
        content
            .mask {
                LinearGradient(stops: [
                    .init(color: .white.opacity(0.00), location: 0),
                    .init(color: .white.opacity(0.05), location: 0.15),
                    .init(color: .white.opacity(0.22), location: 0.29),
                    .init(color: .white.opacity(0.50), location: 0.45),
                    .init(color: .white.opacity(0.75), location: 0.57),
                    .init(color: .white.opacity(0.90), location: 0.70),
                    .init(color: .white.opacity(0.98), location: 0.85),
                    .init(color: .white.opacity(1.00), location: 1),
                ], startPoint: .leading, endPoint: .trailing)
            }
            .mask {
                LinearGradient(stops: [
                    .init(color: .white.opacity(1.00), location: 0),
                    .init(color: .white.opacity(1.00), location: 0.50),
                    .init(color: .white.opacity(0.88), location: 0.60),
                    .init(color: .white.opacity(0.62), location: 0.70),
                    .init(color: .white.opacity(0.34), location: 0.80),
                    .init(color: .white.opacity(0.14), location: 0.89),
                    .init(color: .white.opacity(0.04), location: 0.95),
                    .init(color: .white.opacity(0.00), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
    }
}
