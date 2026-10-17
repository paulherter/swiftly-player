import SwiftUI

// MARK: - Color from the image (experiment, branch experiment-glas)

/// **Loads the tones of an image and shows `content` as soon as they are there.**
///
/// The tones come from `ImageTone`, the same computation as on TV, once per image,
/// in the background, cached. If already cached (returning to a page), they are
/// there in the first pass: no fade-in, no flash. Newly computed ones cross-fade.
/// An image without color (empty tones) shows nothing: then `reason` stays.
struct MoodLoader<ContentBody: View>: View {
    let url: URL?
    let content: ([Double]) -> ContentBody
    @State private var tones: [Double]

    init(url: URL?, @ViewBuilder content: @escaping ([Double]) -> ContentBody) {
        self.url = url
        self.content = content
        _tones = State(initialValue: url.flatMap { ImageTone.shared.remembered(for: $0) } ?? [])
    }

    /// Soft, without overshoot: a color arriving is not a button.
    private static var reveal: Animation {
        Theme.motionReduced ? Theme.fadeReduced : .smooth(duration: 0.55)
    }

    var body: some View {
        ZStack {
            if !tones.isEmpty {
                content(tones).transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { tones = []; return }
            if let alreadyPresent = ImageTone.shared.remembered(for: url) {
                if alreadyPresent != tones { tones = alreadyPresent }
                return
            }
            let new = await ImageTone.shared.tones(for: url)
            #if os(macOS)
            // A screen-high gradient that fades in costs the page sliding in some frames;
            // it comes when the page has settled.
            await InTravel.waitFor()
            #endif
            guard !Task.isCancelled else { return }
            withAnimation(Self.reveal) { tones = new }
        }
    }
}

/// **The background under a detail page in the color of its header image**, the
/// same mesh as on TV (`ImageTone.network`): strongest at the top right where the
/// backdrop sits, darker toward the bottom left.
///
/// It lies as the background of the scroll content, not fixed behind the page, so
/// the color always sits at the same place relative to the header image, and the
/// header image's run-out (``Heldauslauf``) shows exactly the same part of the
/// mesh. Below the header image's edge the color fades into `reason` via `runOut`,
/// in OKLab, on a smoothing curve, with TV's noise, so neither a kink nor a band
/// draws an edge.
struct MoodReason: View {
    let url: URL?
    /// Height of the header image.
    let since: CGFloat
    /// The color is distributed over this height as on TV; that is how it stood when
    /// it was approved.
    static let colorHeight: CGFloat = 900
    /// **Long**, so no boundary appears while scrolling: the color returns to
    /// `reason` over 1300 pt in OKLab
    /// (``Bildton/netz(_:hoehe:farbhoehe:ab:auslauf:)``), lightness and chroma
    /// together, and ends exactly on it.
    static let runOut: CGFloat = 1300

    var body: some View {
        MoodLoader(url: url) { tones in
            Self.network(tones, since: since)
        }
        .frame(height: since + Self.runOut)
    }

    /// The mesh over the whole height, with noise against banding.
    static func network(_ tones: [Double], since: CGFloat) -> some View {
        let total = since + runOut
        return ZStack {
            ImageTone.network(tones, height: Double(total), colorHeight: Double(since + colorHeight),
                         since: Double(since), runOut: Double(runOut))
            ImageTone.noise
                .resizable(resizingMode: .tile)
                .opacity(0.008)
        }
        .frame(height: total)
    }
}
