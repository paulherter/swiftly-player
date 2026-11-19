import SwiftUI

#if canImport(SwiftlyCore)
import SwiftlyCore
#endif

// The picture of a tile or a page head, **one view for every Apple platform** (iPhone, iPad, Apple TV, Mac): the
// memory lookup before the first draw, the tile picture or the BlurHash standing in frame 1, the sharp picture
// replacing it in place. The platforms differ only in their dimensions (`Theme`), their loading field (`LoadField`) and
// their progress bar (`TileProgress`), which each platform's style file provides.

/// **Sharp pictures of one row arrive in index order.** Every slot of the row already holds its BlurHash (or the quiet
/// field) in final size; slot k swaps in its sharp picture only once the slots before it have settled (arrived or
/// failed), so a row never fills 1, 3, 2. Slots from `limit` on (off screen when the row opens) show at once, and
/// `releaseAll()` ends the wait for a slow picture.
@MainActor @Observable
final class ArrivalOrder {
    let limit: Int
    private(set) var released = 0
    @ObservationIgnored private var settled: Set<Int> = []

    init(limit: Int) { self.limit = limit }

    func mayShow(_ slot: Int) -> Bool { slot >= limit || slot <= released }

    func settle(_ slot: Int) {
        settled.insert(slot)
        while settled.contains(released) { released += 1 }
    }

    func releaseAll() { released = limit }
}

/// One slot of an ``ArrivalOrder``, as a `Picture` takes it.
struct ArrivalSlot {
    let order: ArrivalOrder
    let index: Int
}

/// Image at a fixed size.
///
/// Important: the size comes from the frame, the image only overlays it. If you
/// put `aspectRatio(.fill)` directly on the image instead, it becomes wider than
/// its frame; `clipped()` then clips the rendering but not the layout size, and
/// everything around it shifts.
struct Picture<Placeholder: View>: View {
    let url: URL?
    var width: CGFloat?
    var height: CGFloat?
    /// Instead of a fixed height: the height follows the width.
    ///
    /// Needed as soon as the tile fills its column instead of having a fixed size.
    /// Before, the poster grid computed the height from `tileWidth`; on iPhone
    /// that happened to be right because three columns are about 110 pt wide there.
    /// On iPad and Mac the columns are wider, the height stayed at 168, and the
    /// posters were squashed.
    var ratio: CGFloat?
    var corner: CGFloat = Theme.cornerTile
    /// Progress at the bottom edge. Deliberately **here** and not as an overlay from
    /// outside: an overlay lies outside the mask, so the bar would stick out past the
    /// rounded corners with square ends.
    var progress: Double? = nil
    /// The BlurHash of the picture: drawn in the picture's final size while it loads, so a detail page's head and an
    /// episode's still stand in frame 1 and the sharp picture replaces them in place.
    var blur: String? = nil
    /// The pictures the title's tiles showed (landscape first). A detail page's head picture opens with the first of
    /// them the picture memory still holds, in the head's final size and with the same `fill`, so frame 1 is not empty
    /// and not a different gray: the sharp picture replaces it, in place and without a fade when it is the same source
    /// (same path and tag), with a short cross-fade (150 ms) when it is another one (poster → backdrop). The
    /// BlurHash is the fallback only when no tile picture is in memory.
    var stand: [URL] = []
    /// Set for the pictures of a row that must fill in index order (the episode stills).
    var slot: ArrivalSlot? = nil
    /// Where a picture that is taller or wider than the frame is cut: `.center` for tiles, `.top` for a page head, so a
    /// portrait poster standing in for the landscape head shows its top, not a zoomed middle slice.
    var anchor: Alignment = .center
    /// **The one picture a page's first impression waits for** (a detail page's head): it skips the connection gate
    /// (`ImageCache.load(preRank:)`) instead of queueing behind the tile pictures of the screen the user just left,
    /// which keep loading after their tile was scrolled past. One per page; with more it would abolish the gate.
    var urgent = false
    @ViewBuilder var placeholder: () -> Placeholder

    /// Profile → Appearance. See `EnvironmentValues.progressOnTiles`.
    @Environment(\.progressOnTiles) private var barShow
    /// **Loads via ``ImageCache``, not via `AsyncImage`.**
    ///
    /// This used `AsyncImage`, while `NetworkImage.swift` already held a loader that
    /// avoids exactly its three faults: it decodes off the main thread, remembers the
    /// result and downsamples to the required edge length. The users of it were the
    /// Mac, the download page and the profile icon, **but not the home page and the
    /// library**, the two surfaces that get scrolled and where fifty posters decode
    /// at the same time.
    ///
    /// Built and not connected, the same class as the two download rules. No test
    /// sees this: both loaders work.
    ///
    /// **The retry counter goes away**, and that is no loss. It counted
    /// `NSURLErrorCancelled`, the cancellation `AsyncImage` triggers itself as soon as
    /// its tile leaves the screen, only to remain in the error state afterwards. A
    /// bandage around somebody else's property. `ImageCache` fetches in a task of
    /// its own that doesn't hang on the tile; there is nothing to cancel and nothing
    /// to retry.
    @State private var loaded: Image?
    /// Where the sharp picture stands: `waiting` (not drawn, or drawn at opacity 0), `fading` (the one cross-fade from
    /// the placeholder runs), `settled` (it covers everything, the placeholder is gone). One step, never several.
    @State private var stage: Stage = .waiting
    private enum Stage { case waiting, fading, settled }
    /// No image to be expected: no address, or the fetch came back without one. Only
    /// then does the caller's placeholder step in, not already during loading,
    /// otherwise it flashes briefly in front of every tile.
    @State private var withoutImage = false
    /// The tile's picture standing in until the sharp one is there, and whether it is the same source as that one.
    @State private var standIn: Image?
    @State private var standIsSame = false

    /// **Look up what is known once at creation, not on every draw.**
    ///
    /// The cache lookup used to sit in `body`. It looked harmless and wasn't:
    /// `ImageCache.image(_:)` first takes the address apart to remove the access
    /// token (`URLComponents`, filter, reassemble). In `body` that means on **every**
    /// pass, for **every** tile, on the main thread. A detail page draws many images
    /// and goes through several passes; this was work that took the track away from
    /// loading without ever contributing anything.
    ///
    /// So here, as `NetworkImage` has done from the start: ask once before drawing. A
    /// value supplied later would come one pass too late, and that one pass is the
    /// flash.
    @MainActor
    init(url: URL?, width: CGFloat? = nil, height: CGFloat? = nil,
         ratio: CGFloat? = nil, corner: CGFloat = Theme.cornerTile,
         progress: Double? = nil, blur: String? = nil, stand: [URL] = [], slot: ArrivalSlot? = nil,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.blur = blur
        self.slot = slot
        self.stand = stand
        self.url = url
        self.width = width
        self.height = height
        self.ratio = ratio
        self.corner = corner
        self.progress = progress
        self.placeholder = placeholder
        let immediate = url.flatMap { ImageCache.shared.image($0) }
        _loaded = State(initialValue: immediate)
        _stage = State(initialValue: immediate != nil ? .settled : .waiting)
        _withoutImage = State(initialValue: url == nil)
        if immediate == nil, let found = Self.standing(stand, for: url) {
            _standIn = State(initialValue: found.image)
            _standIsSame = State(initialValue: found.same)
        }
    }

    /// The first tile picture that is already in the picture memory, and whether it is the sharp picture's own source.
    @MainActor
    private static func standing(_ stand: [URL], for url: URL?) -> (image: Image, same: Bool)? {
        for candidate in stand {
            if let image = ImageCache.shared.image(candidate) {
                return (image, url.map { sameSource(candidate, $0) } ?? false)
            }
        }
        return nil
    }

    /// Jellyfin names a picture by item, kind and `tag`; size parameters do not make another picture.
    private static func sameSource(_ a: URL, _ b: URL) -> Bool {
        func tag(_ url: URL) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name.lowercased() == "tag" }?.value
        }
        guard let tagA = tag(a), let tagB = tag(b) else { return false }
        return tagA == tagB && a.path == b.path
    }

    var body: some View {
        frameRect
            .overlay(alignment: anchor) {
                if let standIn {
                    // Underneath: the sharp picture (opaque) covers it, so nothing has to be removed afterwards.
                    standIn.resizable().aspectRatio(contentMode: .fill)
                } else if loaded == nil || stage != .settled {
                    // **The placeholder stays until the sharp picture has fully faded in over it**, then it goes.
                    // Before, it was removed the moment the picture arrived, so the picture faded in over
                    // nothing (or, on a page that arrives still, simply appeared).
                    cover
                }
                if let loaded, ready {
                    loaded.resizable().aspectRatio(contentMode: .fill)
                        .opacity(stage == .waiting ? 0 : 1)
                }
            }
            .onChange(of: ready) { reveal() }
            .task(id: url) {
                guard let url else { loaded = nil; withoutImage = true; slot.map { $0.order.settle($0.index) }; return }
                withoutImage = false
                if let present = ImageCache.shared.image(url) {
                    loaded = present
                    stage = .settled
                    slot.map { $0.order.settle($0.index) }
                    return
                }
                loaded = nil
                stage = .waiting
                if standIn == nil, let found = Self.standing(stand, for: url) {
                    standIn = found.image
                    standIsSame = found.same
                }
                // **The tile knows its size, so it says so.**
                //
                // Without it every image is decoded at 1200 pt, twelve times the memory for a
                // poster 112 pt wide. The screen has at most three pixels per point; add a bit
                // so a poster doesn't fray on spring animations, and nobody needs more.
                //
                // Where no fixed width is available (in the grid the column sets it), it stays at
                // the full edge length.
                let needed = [width, height].compactMap { $0 }.max()
                    .map { Int($0 * 3.2) }
                guard let new = await ImageCache.shared.load(url, preRank: urgent, border: needed) else {
                    withoutImage = standIn == nil
                    slot.map { $0.order.settle($0.index) }
                    return
                }
                loaded = new
                slot.map { $0.order.settle($0.index) }
                reveal()
            }
            .overlay(alignment: .bottom) {
                // **Zero is not progress.**
                //
                // This was only `if let progress`. But for a title never started, Jellyfin
                // returns not `nil` but **0**, so the bar was drawn with width zero. As long as
                // its track was dark this hardly showed; since it became light (white 30 %), a
                // light stripe lies on every series not started. Feedback: "stripe also shows up
                // on series I haven't started."
                //
                // A bar says "this is how far you are". Whoever hasn't started has no position,
                // and then nothing belongs there.
                if let progress, progress > 0, barShow {
                    TileProgress(share: progress)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            // A fill image can be far wider than the frame; clipping only hides it, taps would
            // still land on the overflow and open the neighbouring title.
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    /// Whether the picture may be drawn yet (a row that fills in index order holds later pictures back).
    private var ready: Bool { slot.map { $0.order.mayShow($0.index) } ?? true }

    /// The placeholder drawn while the sharp picture is missing, held back, or still fading in.
    @ViewBuilder private var cover: some View {
        if url != nil, !withoutImage {
            // **No placeholder while loading.** The callers' placeholder is the film symbol
            // and means "there is no image for this title". During the fetch that is simply
            // wrong, and you could see it.
            if let blur { BlurFill(hash: blur) } else { LoadField(corner: 0) }
        } else if url == nil, let blur {
            // **No address yet, but the hash is known** (a page opened from a tile before the title named its head
            // picture): the blurred stand-in in the final frame, not the flat "no picture" surface.
            BlurFill(hash: blur)
        } else {
            placeholder()
        }
    }

    /// **The one step from placeholder to picture**, run once the picture is fully decoded and may be shown: a
    /// single short ease-out cross-fade (a plain dissolve also under reduced motion), whether the picture arrived
    /// during a page transition, on a page that opens complete, or in a row. A picture already in memory never gets
    /// here (it starts `settled`); the same source as the stand-in, only sharper, swaps in place without a fade.
    private func reveal() {
        guard stage == .waiting, loaded != nil, ready else { return }
        if standIn != nil, standIsSame {
            var swap = Transaction(animation: nil)
            swap.disablesAnimations = true
            withTransaction(swap) { stage = .settled }
            return
        }
        withAnimation(.easeOut(duration: Self.fadeDuration), completionCriteria: .logicallyComplete) {
            stage = .fading
        } completion: {
            if stage == .fading { stage = .settled }
        }
    }

    private static var fadeDuration: Double { 0.2 }

    /// The surface everything is measured against.
    private var area: some View {
        Color.clear
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
    }

    /// **`aspectRatio` only when there is a ratio.**
    ///
    /// `aspectRatio(nil, contentMode: .fit)` doesn't mean "leave it" but "take the
    /// content's ratio", and the content here is a `Color.clear`, which has none.
    /// Where a width is set this doesn't show: the surface is fixed anyway. Where only
    /// a height is set, nothing is left for the width to hang on, and the surface
    /// collapsed to a strip at the left edge.
    ///
    /// That is exactly how `Heldbild` came about (height yes, width no, ratio no),
    /// and with it the image at the top of every detail page in the narrow layout. The
    /// ratio was added later from main, for the poster grid; callers without one were
    /// not considered.
    @ViewBuilder
    private var frameRect: some View {
        if let ratio {
            area.aspectRatio(ratio, contentMode: .fit)
        } else {
            area
        }
    }
}

extension Picture {
    /// The same picture as the one its page waits for: it does not queue behind other pictures (see ``urgent``).
    func urgent(_ on: Bool = true) -> Self {
        var copy = self
        copy.urgent = on
        return copy
    }

    /// The same picture, cut at `alignment` when it does not match the frame's shape.
    func anchored(_ alignment: Alignment) -> Self {
        var copy = self
        copy.anchor = alignment
        return copy
    }
}

extension Picture where Placeholder == Color {
    init(url: URL?, width: CGFloat? = nil, height: CGFloat? = nil,
         ratio: CGFloat? = nil, corner: CGFloat = Theme.cornerTile,
         progress: Double? = nil, blur: String? = nil, stand: [URL] = [], slot: ArrivalSlot? = nil) {
        self.init(url: url, width: width, height: height,
                  ratio: ratio, corner: corner,
                  progress: progress, blur: blur, stand: stand, slot: slot) {
            Theme.area
        }
    }
}


/// The placeholder of a picture that has no image, on the platforms that show a symbol instead of a free surface
/// (a film or a person) only once it is certain there is none.
struct PictureSymbol: View {
    let name: String?
    var size: CGFloat = 22

    var body: some View {
        if let name {
            Image(icon: name, size: size)
                .font(.app(size: size))
                .foregroundStyle(Theme.font)
        } else {
            Theme.area
        }
    }
}

extension Picture where Placeholder == PictureSymbol {
    /// A symbol for the title's kind where no picture arrives (`symbolText` is a symbol name).
    init(url: URL?, width: CGFloat? = nil, height: CGFloat? = nil,
         ratio: CGFloat? = nil, corner: CGFloat = Theme.cornerTile,
         progress: Double? = nil, blur: String? = nil, stand: [URL] = [], slot: ArrivalSlot? = nil,
         symbolText: String?, characterSize: CGFloat = 44) {
        self.init(url: url, width: width, height: height,
                  ratio: ratio, corner: corner,
                  progress: progress, blur: blur, stand: stand, slot: slot) {
            PictureSymbol(name: symbolText, size: characterSize)
        }
    }
}

/// **The blurred stand-in of a picture, from its BlurHash.**
///
/// A detail page paints it in the final size of the picture in frame 1 (the hash comes with the tile or the stored
/// copy), and the sharp picture replaces it in place when it arrives. The core decodes the hash to a tiny opaque
/// bitmap; the view scales it up. Decoded bitmaps are kept by hash, so a re-open costs nothing. One view for iPhone,
/// iPad, Apple TV and Mac (a `CGImage`, no UIKit/AppKit type).
struct BlurFill: View {
    let hash: String
    var corner: CGFloat = 0

    private static let decoded = NSCache<NSString, CGImage>()

    private var image: CGImage? {
        if let known = Self.decoded.object(forKey: hash as NSString) { return known }
        #if canImport(SwiftlyCore)
        guard let pixels = SwiftlyCore.blurPixels(hash: hash, width: 32, height: 18),
              let provider = CGDataProvider(data: Data(pixels.rgba) as CFData),
              let made = CGImage(
                width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: Int(pixels.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        Self.decoded.setObject(made, forKey: hash as NSString)
        return made
        #else
        return nil
        #endif
    }

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else {
            LoadField(corner: corner)
        }
    }
}
