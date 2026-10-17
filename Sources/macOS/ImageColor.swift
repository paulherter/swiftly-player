import CoreGraphics
import ImageIO
import JellyfinKit
import SwiftUI

/// The dominant color of an image.
///
/// Apple TV fades its cover art into a tinted ramp rather than black: the bottom
/// of the image blends into a tone taken from the image itself. This makes the
/// page look like one piece, whereas a black gradient cuts the image off.
///
/// The color is computed on a single pixel: the image is scaled down to 1 x 1
/// and the result is the average.
///
/// **This does not run on the main actor.** It looks cheap (one pixel), but it
/// requires decoding the whole image first, which takes several milliseconds for
/// a 1600 px backdrop. That cost landed exactly when the page slides in and made
/// the slide-in stutter.
@MainActor
@Observable
final class ImageColor {
    private(set) var audio: Color = Theme.reason
    private var loaded: URL?

    func load(_ url: URL?) async {
        guard let url, url != loaded else { return }
        // **Only record the URL after the fetch succeeded.** Setting `loaded = url`
        // before the request meant that a single failed fetch marked the URL as done and
        // it was never retried, so the header kept the previous page's tint. Same class
        // of bug as setting state before the operation has succeeded.
        guard let (data, _) = try? await URLSession.shared.data(for: .withOwnHeaders(url)) else { return }
        loaded = url
        // Decode and compute off the main actor.
        let computed = await Task.detached(priority: .utility) {
            Self.audioValues(from: data)
        }.value
        guard let values = computed else { return }
        // Darken and desaturate: the tint should color the base tone, not replace it.
        //
        // **The tint is never lighter than `Theme.area`.** At 26 % it was lighter than
        // `erhoeht` (18.8 %), i.e. lighter than the top step of the surface ladder. For the
        // button row under the play button: the gradient spans `heroHeightValue + 260` = 640 pt,
        // the row's center sits at 356, i.e. 55.6 %, giving 0.26 - (0.26 - 0.063) * 0.556
        // = **0.150**. `Theme.area` is 0.149, so the buttons sat exactly on their own
        // color and no longer read as buttons.
        //
        // 14.6 % is the largest value that keeps the tint below `area`. At the button
        // row 0.101 arrives, a full step below the buttons. The tone stays visible at the
        // top, just calmer.
        //
        // **No jumping.** The tint colors a screen-tall gradient; if it changes without
        // an explicit animation, half the page flashes the new color. The change comes
        // from the network and will hit at some point, often mid slide-in.
        withAnimation(.easeInOut(duration: 0.40)) {
            audio = Color(hue: values.colorAudio, saturation: min(values.saturation, 0.45),
                        brightness: 0.146)
        }
    }

    /// Hue and saturation of the average, **without AppKit**, so the computation can
    /// run from any context.
    private nonisolated static func audioValues(from data: Data)
        -> (colorAudio: Double, saturation: Double)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        var point: [UInt8] = [0, 0, 0, 0]
        guard let drawing = point.withUnsafeMutableBytes({ cache in
            CGContext(data: cache.baseAddress, width: 1, height: 1,
                      bitsPerComponent: 8, bytesPerRow: 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        drawing.interpolationQuality = .medium
        drawing.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let result = drawing.data else { return nil }
        let values = result.assumingMemoryBound(to: UInt8.self)

        let r = Double(values[0]) / 255, g = Double(values[1]) / 255, b = Double(values[2]) / 255
        let up = max(r, g, b), deep = min(r, g, b), extentSpan = up - deep
        guard extentSpan > 0 else { return (0, 0) }

        var colorAudio: Double
        switch up {
        case r:  colorAudio = (g - b) / extentSpan
        case g:  colorAudio = 2 + (b - r) / extentSpan
        default: colorAudio = 4 + (r - g) / extentSpan
        }
        colorAudio /= 6
        if colorAudio < 0 { colorAudio += 1 }
        return (colorAudio, up > 0 ? extentSpan / up : 0)
    }
}
