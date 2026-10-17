import CoreGraphics
import Foundation
import ImageIO
import JellyfinKit
import SwiftUI

// The background of the tvOS detail pages, tinted by their backdrop image. Which tones an
// image has and how they become the mesh is shared in `Sources/Shared/ImageTone.swift`;
// iPhone paints its background from the same computation. This file only covers how the TV
// lays it under the page.

/// Tints the background of a whole page by its backdrop image.
///
/// **On the page, not on the header.** It used to live in `DetailHeader`, so the tint ended
/// at the header's bottom edge, leaving plain `#0B0B0D` and a seam across the screen. The
/// background belongs under everything the page shows, rows included.
///
/// **The initial value comes from memory, not from nothing.** Every page creates its own
/// `ImageReason`, so the detail page gets a new one when it opens. With `[]` it drew the bare
/// background first and filled in on the next pass, which was visible as a flash. Setting
/// it later without animation came too late, since the empty pass had already happened. A
/// known tone must therefore be in place **in the first** pass.
struct ImageReason: ViewModifier {
    let url: URL?
    @State private var tones: [Double]

    @MainActor init(url: URL?) {
        self.url = url
        _tones = State(initialValue: url.flatMap { ImageTone.shared.remembered(for: $0) } ?? [])
    }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    ImageTone.network(tones).ignoresSafeArea()

                    // The last bit against banding; see `ImageTone.noise`.
                    if !tones.isEmpty {
                        ImageTone.noise
                            .resizable(resizingMode: .tile)
                            .opacity(0.008)
                            .ignoresSafeArea()
                    }
                }
                .allowsHitTesting(false)
            }
            .animation(Theme.motion(.easeInOut(duration: 0.4)), value: tones)
            .task(id: url) {
                guard let url else { tones = []; return }

                // Already known? Then it has been in place since the first pass (see
                // `init`) and nothing is left to do. Without this early return, the same
                // assignment would trigger an animation although the value does not change.
                if let alreadyPresent = ImageTone.shared.remembered(for: url) {
                    if alreadyPresent != tones {
                        var without = Transaction()
                        without.disablesAnimations = true
                        withTransaction(without) { tones = alreadyPresent }
                    }
                    return
                }

                // Only genuinely new tones are cross-faded, e.g. a title opened directly
                // via search.
                tones = await ImageTone.shared.tones(for: url)
            }
    }
}

extension View {
    func imageReason(url: URL?) -> some View { modifier(ImageReason(url: url)) }
}
