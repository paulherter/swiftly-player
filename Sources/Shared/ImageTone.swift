import CoreGraphics
import Foundation
import ImageIO
import JellyfinKit
import SwiftUI

/// **The hue of an image: only the tone, not the color.**
///
/// The detail page tints its background after the backdrop image. What is
/// deliberately *not* taken over matters: the app sets saturation and
/// brightness itself, only the hue comes from the image.
///
/// Reason: averaging a dark movie poster almost always gives brownish gray,
/// because opposing colors cancel out. Taking only the hue and fixing the rest
/// makes the result always look like Swiftly: a cool film turns blue-green, a
/// warm one amber, and both stay equally dark and restrained.
///
/// **Averaging happens on the circle, not on the number.** Hues are angles:
/// 350 and 10 degrees are neighbors, but their arithmetic mean is 180, the
/// opposite color. So hues are added as unit vectors and converted back.
///
/// Weight is the squared saturation: the most colorful spot carries the
/// impression of the image, not the gray area around it.
///
/// **Shared, because the iPhone needs the same hue.** TV and iPhone compute the
/// same hues from the same image; each platform decides how they become a
/// background (`TVImageReason.swift`, `Sources/iOS/ImageMood.swift`).
@MainActor
final class ImageTone {
    static let shared = ImageTone()

    /// Computed once, then remembered. Otherwise every return to the same page
    /// recomputes, and the background fades in each time.
    ///
    /// **Capped.** An entry is small, but browsing a library for an hour collects
    /// thousands; the oldest drop out.
    private var known: [URL: [Double]] = [:]
    private var railsEpisode: [URL] = []
    private static let atMost = 300
    private var ongoing: [URL: Task<[Double], Never>] = [:]

    /// **Already known?** No waiting, no `await`.
    ///
    /// Lets the detail page set the hues **immediately** instead of fading them in.
    /// Coming from the home page they are usually there already: it computes them on
    /// image change, and both pages fetch the same image (`width: 1600`).
    ///
    /// `nil` means "never computed", an empty array "computed, found nothing". These
    /// differ: a grayscale image must not be searched again on every open.
    func remembered(for url: URL) -> [Double]? { known[url] }

    // `vorrechnen` existed while only the detail pages were tinted and the home
    // page merely precomputed the hue. Now the home page tints itself, so
    // `ImageReason` computes it there anyway, and `remembered(fuer:)` lets the detail
    // page take it over without waiting or cross-fading.

    /// Up to three hues in degrees, by weight; empty if none can be derived.
    func tones(for url: URL) async -> [Double] {
        if let done = known[url] { return done }
        if let running = ongoing[url] { return await running.value }

        // **Detached, not just `nonisolated`.** A plain `Task` inherits the main
        // actor, and `audioOut` ran on it despite `nonisolated`: decoding, downscaling
        // and a histogram over every pixel, in the middle of a focus change.
        let task = Task.detached(priority: .userInitiated) { () -> [Double] in
            guard let (data, _) = try? await URLSession.shared.data(for: .withOwnHeaders(url)) else { return [] }
            return Self.audioOut(data)
        }
        ongoing[url] = task
        let result = await task.value
        if known[url] == nil { railsEpisode.append(url) }
        known[url] = result
        ongoing[url] = nil
        if railsEpisode.count > Self.atMost {
            let distance = railsEpisode.prefix(railsEpisode.count - Self.atMost)
            for alt in distance { known[alt] = nil }
            railsEpisode.removeFirst(distance.count)
        }
        return result
    }

    /// Downscaled to 32 x 32, then pixel by pixel into a hue histogram.
    ///
    /// **A single mean is not enough.** An image rarely has just one hue: a sunset
    /// is orange **and** blue, and the mean of both is neither.
    ///
    /// So: 36 bins of ten degrees each, weighted by squared saturation times
    /// brightness. The strongest peaks are then picked with a minimum distance: two
    /// adjacent bins are the same hue, not a second one.
    ///
    /// **Five, not three.** More hues mean more movement across the surface, which
    /// is also the best remedy against banding: the more the three channels run at
    /// different speeds, the less their quantization steps coincide.
    nonisolated static func audioOut(_ data: Data) -> [Double] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 48,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return [] }

        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return [] }

        var points = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let area = CGContext(data: &points, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        area.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // The histogram and peaks live in the package so Android computes the same
        // hues (`AvComputation.tones`).
        return AvComputation.tones(rgba: points)
    }

}

extension ImageTone {
    /// Saturation and brightness now live in `ImageReason.farbe(at:)`, where they
    /// depend on the position in the mesh. The former `farbe` and `grundfarbe`
    /// existed only while the background was one surface plus stacked clouds; they
    /// went away with the mesh.

    /// **Fine noise against banding.**
    ///
    /// Banding comes from the number representation, not the gradient: eight bits
    /// per channel give 256 levels, and a gradient that passes through only a few
    /// levels over a thousand points necessarily has wide bands of equal color. On
    /// a large dark screen every boundary is visible.
    ///
    /// A softer gradient does not help, the steps just move. The boundary must be
    /// **broken up**: a touch of random noise makes neighboring points land on one
    /// level or the other. The eye averages over it and sees the transition the
    /// numbers cannot represent. This is dithering.
    ///
    /// **The amplitude is the whole trick, and it is tiny.** About **one** level is
    /// needed: just enough for a point to fall on either level.
    ///
    /// An earlier value of 3.5 percent gives around nine levels of swing with black
    /// and white at full random opacity. That is visible grain, not dither.
    ///
    /// 255 x 0.008 x 0.5 (mean opacity) = about 1 level
    ///
    /// Tiled at 96 x 96. Nothing is visible except that the bands are gone.
    static let noise: Image = {
        let border = 96
        var points = [UInt8](repeating: 0, count: border * border * 4)
        var condition: UInt64 = 0x2545F4914F6CDD1D
        for i in stride(from: 0, to: points.count, by: 4) {
            // Xorshift: fast, evenly distributed enough, and independent of any random
            // source that looks different on every run.
            condition ^= condition << 13
            condition ^= condition >> 7
            condition ^= condition << 17
            // **Both directions.** An earlier version was white with random opacity,
            // which could only lighten, never darken. A one-sided push shifts the gradient
            // instead of breaking up the step boundary. Here every point is randomly black
            // or white, so the mean stays neutral.
            let bright = (condition & 1) == 1
            let coverage = UInt8(truncatingIfNeeded: condition >> 8)
            // Premultiplied: black has zero color channels, white equals the opacity.
            let channel: UInt8 = bright ? coverage : 0
            points[i] = channel; points[i + 1] = channel; points[i + 2] = channel
            points[i + 3] = coverage
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let area = CGContext(data: &points, width: border, height: border,
                                bitsPerComponent: 8, bytesPerRow: border * 4,
                                space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return Image(decorative: area.makeImage()!, scale: 1)
    }()

    /// **One round fade instead of two.**
    ///
    /// Two stacked masks, one horizontal and one vertical, produce a
    /// **rectangular** falloff. However soft each is, their product traces the two
    /// straight lines they act along, and in the corner where both are half
    /// applied it gets doubly dark. Smoothed edges are still edges.
    ///
    /// A single radial falloff has no direction it acts along, hence no straight
    /// line to trace.
    ///
    /// Same curve as everywhere else, so neither start nor end has a kink where a
    /// band could form.
}

// MARK: - The mesh

/// **How hues become a background, identical on TV and iPhone.**
/// Originally in the tvOS `ImageReason`; the iPhone paints its detail pages from
/// the same computation now, hence it lives here. The numbers are style tokens
/// (`Colors.swift`, "color from the image").
extension ImageTone {
    /// **A mesh instead of stacked gradients.**
    ///
    /// Previously a linear base gradient and up to five radial clouds were stacked.
    /// Each has stops, the slope jumps at every stop, and every jump reads as a band.
    /// Five translucent layers also add up to blotchy transitions that no tuning of
    /// the numbers could fix, because the structure itself created the edges.
    ///
    /// `MeshGradient` instead interpolates on the GPU over a **surface**: nine
    /// control points with a smooth layer between. There are no stops to kink at
    /// and no stacked layers to add up. Available since tvOS 18; our target is 18.0.
    ///
    /// Colors follow the layout of the image: top right, where the backdrop sits,
    /// the strongest hue is brightest; toward the bottom left it gets darker until
    /// it merges into the background. The remaining hues fill the middle so color
    /// actually changes across the surface.
    static func network(_ tones: [Double]) -> MeshGradient {
        // **Five by five, not three by three.**
        //
        // Nine control points at 1920 x 1080 are nine islands of color, and the
        // interpolation between them shows as a bump that cannot be damped away; as
        // long as the points are that far apart, each carries its own cloud.
        //
        // 25 points sample the same color field densely enough that the patches merge
        // into one surface. `farbe(at:)` is a continuous function of position, so the
        // finer it is sampled, the smoother the result.
        let page = 5
        var points: [SIMD2<Float>] = []
        for row in 0 ..< page {
            for column in 0 ..< page {
                points.append([Float(column) / Float(page - 1),
                               Float(row) / Float(page - 1)])
            }
        }
        return MeshGradient(width: page, height: page,
                            points: points,
                            colors: points.map { color(tones, at: $0) })
    }

    /// Which color sits at which point of the mesh.
    ///
    /// **Continuous, not per cell.** Previously an integer index picked the hue, so
    /// the color jumped from point to point, and with five hues orange quickly sat
    /// next to blue. Now a value from 0 to 1 runs diagonally across the surface and
    /// blends between neighboring hues, so two neighbors in the mesh differ by only
    /// a fraction of a hue distance.
    ///
    /// Two things decide: proximity to the backdrop at the top right sets **how
    /// bright** it gets, the position in the mesh sets **which** hue.
    static func color(_ tones: [Double], at point: SIMD2<Float>) -> Color {
        guard !tones.isEmpty else { return Theme.reason }

        // The computation lives in the package (`AvComputation.hsb`); the numbers
        // are the style tokens in `Colors.swift`:
        //
        // saturation  0.38...0.58
        // brightness  0.075...0.215
        // falloff     proximity^1.6
        //
        // The falloff carries most of it: outside the image almost everything sits on
        // the base tone, color appears only where the image is. The accent color stays
        // out: this is a background, not a control, and dark enough for white text.
        let t = AvComputation.hsb(tones, x: Double(point.x), y: Double(point.y))
        return Color(hue: t.audio / 360, saturation: t.saturation, brightness: t.brightness)
    }

    /// Same color as ``farbe(_:at:)``, but `decay` (1 ... 0) leads it back to
    /// `reason`, **in OKLab**: lightness and chroma together, until at 0 exactly
    /// `reason` remains. An opacity over `reason` blended in sRGB, and where the color
    /// was darker than the background an edge showed while scrolling. Computed in
    /// the package (`AvComputation.farbe`) so Android has the same fade.
    static func color(_ tones: [Double], x: Double, y: Double, decay f: Double) -> Color {
        guard !tones.isEmpty else { return Theme.reason }
        let from = AvComputation.color(tones, x: x, y: y, decay: f)
        return Color(.sRGB, red: from.r, green: from.g, blue: from.b)
    }

    /// **The mesh for a detail page that fades out into `reason`** (iPhone). At the
    /// top exactly the TV's image over `colorHeight`; from `since` it runs over `runOut`
    /// along a smootherstep curve exactly to `reason`, with control rows dense over
    /// the fade, blended in a perceptually uniform color space.
    static func network(_ tones: [Double], height: Double, colorHeight: Double, since: Double,
                     runOut: Double) -> MeshGradient {
        let columns = 5
        var rows: [Double] = [0, since * 0.5, since]
        for i in 1 ... 10 { rows.append(since + runOut * Double(i) / 10) }
        rows.append(height)
        var points: [SIMD2<Float>] = [], colors: [Color] = []
        for y in rows {
            let f = AvComputation.decay(y: y, since: since, runOut: runOut)
            for s in 0 ..< columns {
                let x = Double(s) / Double(columns - 1)
                points.append([Float(x), Float(min(1, y / height))])
                colors.append(color(tones, x: x, y: min(1, y / colorHeight), decay: f))
            }
        }
        return MeshGradient(width: columns, height: rows.count, points: points, colors: colors,
                            background: Theme.reason, smoothsColors: true, colorSpace: .perceptual)
    }

    /// The hue at position `run` (0...1), blended between the found hues along
    /// the shortest path on the color wheel.
    ///
    /// Every hue moves toward the main color: the movement across the surface
    /// stays, its span shrinks to a third. Otherwise a full orange would sit next to
    /// blue, which shows as a blotch however fine the mesh is.
    static func audioAt(_ tones: [Double], _ run: Double) -> Double {
        AvComputation.audioAt(tones, run)
    }
}
