import XCTest
import CoreText
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import JellyfinKit
@testable import RenderKit

/// One line in the saved default look on a flat mid-grey ground, drawn like an iPhone in landscape (852 x 393 points at 3x), as PNG.
/// Run by `Werkzeuge/subtitle-compare.sh` once for the overlay of an older commit and once for the current one, so the two looks can
/// be measured with `Werkzeuge/subtitle-measure.py` and shown side by side.
@MainActor
final class SubtitleCompareTests: XCTestCase {
    func testRenderDefaultLook() throws {
        let env = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: env["SUBTITLE_OUT"] ?? NSTemporaryDirectory())
        CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: env["SUBTITLE_FONT"] ?? "") as CFURL, .process, nil)
        let w = 852, h = 393, s = 3
        let look = SubtitleLook.standard
        UserDefaults.standard.set(look.encoded(), forKey: "utAussehen")
        var report = ""
        for (name, line) in [("illinois", "Illinois"), ("sentence", "Where did you go, Jack? Chaos must reign.")] {
            let overlay = SubtitleOverlay()
            overlay.show(line, in: CGRect(x: 0, y: 0, width: w, height: h), picture: .zero)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: w * s, height: h * s, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w * s, height: h * s))
            #if canImport(UIKit)
            ctx.translateBy(x: 0, y: CGFloat(h * s)); ctx.scaleBy(x: 1, y: -1)
            #endif
            ctx.scaleBy(x: CGFloat(s), y: CGFloat(s))
            overlay.layer.render(in: ctx)
            let crop = CGRect(x: (w * s - 1500) / 2, y: h * s - 260, width: 1500, height: 260)
            let image = ctx.makeImage()!.cropping(to: crop)!
            let data = NSMutableData()
            let target = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(target, image, nil); CGImageDestinationFinalize(target)
            try (data as Data).write(to: out.appendingPathComponent("\(name).png"))
            report += "\(name) font-px=\(Double(h) * 0.0625 * 0.82 * Double(s))\n"
        }
        try report.write(to: out.appendingPathComponent("numbers.txt"), atomically: true, encoding: .utf8)
    }
}
