import CoreGraphics
import Foundation
import ImageIO
import JellyfinKit
import UniformTypeIdentifiers
import XCTest
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import RenderKit

/// Offscreen render of the real `SubtitleOverlay`: the same cue drawn the old way (flat text, the saved
/// look only) and with the file's style. Run it with `Werkzeuge/subtitle-render.sh <out-dir>`.
/// Output: `<sample>-before.png`, `<sample>-after.png` (the subtitle band on a gradient, so opacity shows)
/// and `numbers.txt`.
@MainActor
final class SubtitleRenderTests: XCTestCase {
    static let header = """
    [Script Info]
    PlayResY: 1080

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,60,&H00CCCCCC,&H000000FF,&H00202020,&H80000000,-1,0,0,0,100,100,0,0,1,3,2,2,10,10,40,1
    Style: Yellow,Arial,60,&H0000FFFF,&H000000FF,&H00000000,&H00000000,0,-1,0,0,100,100,0,0,1,0,0,2,10,10,40,1
    Style: Box,Arial,50,&H00FFFFFF,&H000000FF,&H80000000,&H00000000,0,0,0,0,100,100,0,0,3,0,0,2,10,10,40,1
    Style: Faint,Arial,60,&H40FFFFFF,&H000000FF,&H00A00000,&H00000000,0,0,0,0,100,100,0,0,1,4,0,2,10,10,40,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    """

    struct Sample { let name: String; let event: String; let keep: Bool }
    static let samples = [
        Sample(name: "grey-style", event: "0,0,Default,,0,0,0,,Chaos must reign... Where did you go, Jack?", keep: true),
        Sample(name: "yellow-italic", event: "0,0,Yellow,,0,0,0,,Where did you go, Jack?", keep: true),
        Sample(name: "inline-tags", event: #"0,0,Default,,0,0,0,,{\c&H0000FF&}Red{\r} and {\1c&H00FF00&\3c&H400000&}green{\r} and {\i1}italic{\i0} and {\alpha&H90&}ghost"#, keep: true),
        Sample(name: "box", event: "0,0,Box,,0,0,0,,An opaque box in the outline colour", keep: true),
        Sample(name: "faint-alpha", event: "0,0,Faint,,0,0,0,,Fill 75 percent, blue outline", keep: true),
        Sample(name: "arabic-style", event: "0,0,Yellow,,0,0,0,,لا يمكنك الهروب من الماضي، مهما حاولت", keep: true),
        Sample(name: "switch-off", event: "0,0,Default,,0,0,0,,Switch off: the saved look only", keep: false),
    ]
    static let width = 1080, height = 540, scale = 2

    override func setUp() async throws {
        let path = ProcessInfo.processInfo.environment["SUBTITLE_FONT"] ?? ""
        CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: path) as CFURL, .process, nil)
    }

    func render(line: String, styled: [ASSRun], look: SubtitleLook, flat: CGFloat? = nil) -> CGImage {
        UserDefaults.standard.set(look.encoded(), forKey: "utAussehen")
        let overlay = SubtitleOverlay()
        let w = Self.width, h = Self.height, s = Self.scale
        overlay.show(line, styled: styled, in: CGRect(x: 0, y: 0, width: w, height: h), picture: .zero)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w * s, height: h * s, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let low = flat ?? 0.25, high = flat ?? 0.75
        let gradient = CGGradient(colorsSpace: space,
                                  colors: [CGColor(gray: low, alpha: 1), CGColor(gray: high, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: CGFloat(w * s), y: 0), options: [])
        #if canImport(UIKit)
        ctx.translateBy(x: 0, y: CGFloat(h * s)); ctx.scaleBy(x: 1, y: -1)   // UIKit layers start at the top
        #endif
        ctx.scaleBy(x: CGFloat(s), y: CGFloat(s))
        overlay.layer.render(in: ctx)
        let crop = CGRect(x: (w * s - 1500) / 2, y: h * s - 300 - 6, width: 1500, height: 300)
        return ctx.makeImage()!.cropping(to: crop)!
    }

    func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let target = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(target, image, nil)
        CGImageDestinationFinalize(target)
        return data as Data
    }

    /// Counts (white letter pixels, dark outline pixels) in a render. The gradient behind is mid grey.
    func counts(_ image: CGImage) -> (white: Int, dark: Int) {
        let w = image.width, h = image.height
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &raw, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var white = 0, dark = 0
        for i in stride(from: 0, to: raw.count, by: 4) {
            let r = raw[i], g = raw[i + 1], b = raw[i + 2]
            if r > 235, g > 235, b > 235 { white += 1 } else if r < 40, g < 40, b < 40 { dark += 1 }
        }
        return (white, dark)
    }

    var outDir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUBTITLE_OUT"] ?? "/tmp/subtitle-render")
    }

    /// **The saved look (the saved design and the default) keeps the letters full.** The outline sits outside the
    /// letter (as VLC and libass draw it), it is not painted over the letter: a stroke centred on the edge made
    /// the letters thin and the outline thick, on the Mac and in every language.
    // Edge pixels blend with the dark outline, so the white count is about 80 %, not 100 %, of the plain one.
    func testSavedLookKeepsTheLettersFull() throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let lines = [("latin", "Chaos must reign... Where did you go, Jack?"),
                     ("arabic", "لا يمكنك الهروب من الماضي، مهما حاولت"),
                     ("hebrew", "אי אפשר לברוח מהעבר, לא משנה כמה תנסה"),
                     ("devanagari", "तुम अतीत से भाग नहीं सकते, चाहे जितनी कोशिश कर लो"),
                     ("thai", "คุณหนีจากอดีตไม่ได้ ไม่ว่าจะพยายามแค่ไหน")]
        for (name, line) in lines {
            for (lookName, look) in [("default", SubtitleLook.standard), ("thin", SubtitleLook(outline: .thin, shadow: true)),
                                     ("yellow", SubtitleLook(colour: .yellow, outline: .normal))] {
                let plain = SubtitleLook(colour: look.colour, outline: .off, shadow: look.shadow)
                let letters = render(line: line, styled: [], look: plain)
                let outlined = render(line: line, styled: [], look: look)
                try png(outlined).write(to: outDir.appendingPathComponent("saved-\(name)-\(lookName).png"))
                if look.colour == .white {
                    let full = counts(letters).white, kept = counts(outlined).white
                    XCTAssertGreaterThan(full, 300, "\(name)/\(lookName): the script drew no letters at all (no font for it?)")
                    XCTAssertGreaterThanOrEqual(Double(kept), Double(full) * 0.7, "\(name)/\(lookName): letters eaten by the outline (\(kept) of \(full))")
                    if name == "latin" {
                        XCTAssertGreaterThan(counts(outlined).dark, counts(letters).dark + 200, "\(name)/\(lookName): no outline")
                    }
                }
            }
        }
    }

    /// **The overlay follows a change of the saved look at once** (the settings arrive from the server late,
    /// or the look is changed while a title plays), not only at the next title.
    func testOverlayFollowsTheStore() async throws {
        let line = "Where did you go, Jack?"
        UserDefaults.standard.set(SubtitleLook(colour: .yellow, outline: .off).encoded(), forKey: "utAussehen")
        let overlay = SubtitleOverlay()
        let bounds = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        overlay.show(line, in: bounds, picture: .zero)
        func shot() -> Data {
            let s = Self.scale
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: Self.width * s, height: Self.height * s, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            #if canImport(UIKit)
            ctx.translateBy(x: 0, y: CGFloat(Self.height * s)); ctx.scaleBy(x: 1, y: -1)
            #endif
            ctx.scaleBy(x: CGFloat(s), y: CGFloat(s))
            overlay.layer.render(in: ctx)
            return png(ctx.makeImage()!)
        }
        let before = shot()
        // The sync applies the saved look: white, big, outlined.
        UserDefaults.standard.set(SubtitleLook(size: .huge, colour: .white, outline: .normal).encoded(), forKey: "utAussehen")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotEqual(before, shot(), "the overlay kept the look it was created with")
        // A change of something else in the defaults does not redraw.
        UserDefaults.standard.set(1, forKey: "somethingElse")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        UserDefaults.standard.removeObject(forKey: "utAussehen")
    }

    func testRenderAll() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUBTITLE_OUT"] ?? "/tmp/subtitle-render")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // the saved look: white, normal outline, switch on (the default) or off.
        let on = SubtitleLook(outline: .normal)
        let off = SubtitleLook(outline: .normal, keepFileStyle: false)
        let sheet = ASSStyleSheet.parse(Self.header)
        var report = ""
        for sample in Self.samples {
            let look = sample.keep ? on : off
            // Before: what the app did: flat text in the saved look.
            let flat = ASSCue.runs(eventLines: sample.event, sheet: nil).map(\.text).joined()
            let before = png(render(line: flat, styled: [], look: look))
            // After: switch on = the file's style; off = the same flat text.
            let runs = sample.keep ? ASSCue.runs(eventLines: sample.event, sheet: sheet) : []
            let after = png(render(line: sample.keep ? runs.map(\.text).joined() : flat,
                                   styled: runs.contains(where: \.isStyled) ? runs : [], look: look))
            try before.write(to: out.appendingPathComponent("\(sample.name)-before.png"))
            try after.write(to: out.appendingPathComponent("\(sample.name)-after.png"))
            report += "\(sample.name) runs=\(runs.count) identical=\(before == after)\n"
            if sample.keep { XCTAssertNotEqual(before, after, sample.name) } else { XCTAssertEqual(before, after, sample.name) }
        }
        // Looks on one plain line (the desktop player is compared to these).
        let looks: [(String, SubtitleLook)] = [
            ("look-default", SubtitleLook()),
            ("look-custom", SubtitleLook(size: .large, colour: .yellow, outline: .thin, shadow: true, background: false)),
            ("look-box", SubtitleLook(size: .small, colour: .grey, outline: .off, shadow: false, background: true)),
            ("look-raised", SubtitleLook(position: .raised)),
        ]
        for (name, look) in looks {
            try png(render(line: "Hallo Welt, Ägypten gjpq", styled: [], look: look)).write(to: out.appendingPathComponent("\(name).png"))
        }
        try report.write(to: out.appendingPathComponent("numbers.txt"), atomically: true, encoding: .utf8)
    }

    /// Additive (Android/desktop contract, lines 8-10): the plain sentence in several looks, for the area numbers of
    /// `Werkzeuge/subtitle-measure.py` (the other platforms compare against these PNGs). Font size is 52.65 px in the PNG.
    func testLooksForComparison() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUBTITLE_OUT"] ?? "/tmp/subtitle-render")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let looks: [(String, SubtitleLook)] = [
            ("look-standard", SubtitleLook()),
            ("look-custom", SubtitleLook(size: .large, colour: .yellow, outline: .thin)),
            ("look-shadow-box", SubtitleLook(size: .small, outline: .off, shadow: true, background: true)),
        ]
        var fontError: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUBTITLE_FONT"] ?? "") as CFURL, .process, &fontError)
        #if canImport(UIKit)
        let fontName = UIFont(name: SubtitleStyle.fontName, size: 52.65)?.fontName
        #else
        let fontName = NSFont(name: SubtitleStyle.fontName, size: 52.65)?.fontName
        #endif
        try "registered=\(registered) error=\(String(describing: fontError?.takeRetainedValue())) font=\(fontName ?? "nil (system fallback)") env=\(ProcessInfo.processInfo.environment["SUBTITLE_FONT"] ?? "unset")\n"
            .write(to: out.appendingPathComponent("font.txt"), atomically: true, encoding: .utf8)
        for (name, look) in looks {
            let flat = "Switch off: the saved look only"
            try png(render(line: flat, styled: [], look: look)).write(to: out.appendingPathComponent("\(name).png"))
        }
    }

    // MARK: Contract lines 8, 9, 15 on Apple: position, pixels, colour, bitmaps

    private func textLayers(_ overlay: SubtitleOverlay) -> [CATextLayer] {
        (overlay.layer.sublayers ?? []).compactMap { $0 as? CATextLayer }
    }

    /// Distance from the bottom edge of `picture` to the lowest point of the first text layer, whatever the layer's origin.
    private func gapBelowText(_ overlay: SubtitleOverlay, picture: CGRect, bounds: CGRect) -> CGFloat {
        let frame = textLayers(overlay)[0].frame
        #if canImport(UIKit)
        return picture.maxY - frame.maxY
        #else
        return frame.minY - picture.minY
        #endif
    }

    /// **The bottom margin is 16 pt, raised adds 7 % of the picture height** (the reference for every platform), measured from
    /// the picture's bottom edge, not the screen's (a letterboxed film keeps the text on the picture).
    func testBottomMarginIsSixteenPointsAndRaisedAddsSevenPercent() {
        for (height, picture) in [(540.0, CGRect.zero), (1080.0, CGRect.zero), (540.0, CGRect(x: 0, y: 70, width: 1080, height: 400))] {
            let bounds = CGRect(x: 0, y: 0, width: 1080, height: height)
            let visible = picture.isEmpty ? bounds : picture
            for raised in [false, true] {
                UserDefaults.standard.set(SubtitleLook(position: raised ? .raised : .bottom).encoded(), forKey: "utAussehen")
                let overlay = SubtitleOverlay()
                overlay.displayScale = 2
                overlay.show("Hello world", in: bounds, picture: picture)
                let expected = 16 + (raised ? visible.height * 0.07 : 0)
                let gap = gapBelowText(overlay, picture: visible, bounds: bounds)
                XCTAssertEqual(gap, expected, accuracy: 0.5, "height \(height) picture \(picture) raised \(raised): gap \(gap)")
            }
        }
        UserDefaults.standard.removeObject(forKey: "utAussehen")
    }

    /// **No blurry line:** the layers draw at the screen's scale and sit on whole device pixels, also when the view has a
    /// fractional size (rotation, split view, full screen on the Mac). At 1x a layer rasterised at scale 1 and stretched
    /// was the "subtitles lack clarity" report.
    func testTextIsDrawnAtTheScreenScaleOnWholePixels() {
        UserDefaults.standard.removeObject(forKey: "utAussehen")
        for scale in [1.0, 2.0, 3.0] {
            let overlay = SubtitleOverlay()
            overlay.displayScale = CGFloat(scale)
            overlay.show("A line for the test, long enough to need width", in: CGRect(x: 0, y: 0, width: 843.7, height: 389.3), picture: .zero)
            for layer in textLayers(overlay) {
                XCTAssertEqual(layer.contentsScale, CGFloat(scale), "scale \(scale)")
                for value in [layer.frame.minX, layer.frame.minY, layer.frame.width] {
                    let pixels = value * CGFloat(scale)
                    XCTAssertEqual(pixels, pixels.rounded(), accuracy: 0.001, "scale \(scale): \(layer.frame) is not on whole pixels")
                }
            }
        }
    }

    /// **Picture subtitles (PGS) are scaled smoothly, at the screen's scale, on whole pixels** and land where the disc put them:
    /// the cue's canvas is mapped width-aligned onto the picture.
    func testPictureSubtitlesAreSmoothAndPlacedOnTheCanvas() throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 400, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 80))
        let image = try XCTUnwrap(ctx.makeImage())
        // The canvas is 1920 x 1080; the cue is 400 x 80 at x 760, 900 px from the top.
        let position = CGRect(x: 760.0 / 1920, y: 900.0 / 1080, width: 400.0 / 1920, height: 80.0 / 1080)
        for scale in [2.0, 3.0] {
            let overlay = SubtitleOverlay()
            overlay.displayScale = CGFloat(scale)
            let bounds = CGRect(x: 0, y: 0, width: 960.5, height: 540)
            overlay.show(images: [(1, image, position, CGSize(width: 1920, height: 1080))], in: bounds, picture: bounds)
            let layers = (overlay.layer.sublayers ?? []).filter { !($0 is CATextLayer) }
            let bitmap = try XCTUnwrap(layers.first)
            XCTAssertEqual(bitmap.magnificationFilter, .linear)
            XCTAssertEqual(bitmap.minificationFilter, .trilinear)
            XCTAssertEqual(bitmap.contentsScale, CGFloat(scale))
            XCTAssertFalse(bitmap.shouldRasterize)
            let width = 960.5 / 1920
            XCTAssertEqual(bitmap.frame.width, 400 * width, accuracy: 1 / CGFloat(scale) + 0.01)
            XCTAssertEqual(bitmap.frame.minX, 760 * width, accuracy: 1 / CGFloat(scale) + 0.01)
            #if canImport(UIKit)
            XCTAssertEqual(bitmap.frame.minY, 900 * width, accuracy: 1 / CGFloat(scale) + 0.01)
            #else
            XCTAssertEqual(bitmap.frame.maxY, 540 - 900 * width, accuracy: 1 / CGFloat(scale) + 0.01)
            #endif
            for value in [bitmap.frame.minX, bitmap.frame.minY, bitmap.frame.width, bitmap.frame.height] {
                XCTAssertEqual(value * CGFloat(scale), (value * CGFloat(scale)).rounded(), accuracy: 0.001, "\(bitmap.frame)")
            }
        }
    }

    /// **The letters are the look's colour at full strength** (reported once as "grey subtitles"): on a flat black background
    /// most of the letter pixels equal the saved colour, with the file's style switched off and on a plain line.
    /// **The default look, pinned in numbers** (the same on every platform): Inter SemiBold, size = 6.25 % of the
    /// picture height times the base scale 0.78 (the Mac / iPad value), white in sRGB, an outline of 3 % of the font
    /// height (stroke width 6, positive = stroke only, the letters come from the layer above), no shadow, no box.
    /// And measured on the render: the outline beside a stem is thinner than the stem itself (not "thin letters in a
    /// thick outline"), the stem is the font's own (about 10-16 % of the font size).
    func testDefaultLookIsPinnedInNumbersAndTheOutlineIsThinnerThanTheStem() throws {
        let look = SubtitleLook.standard
        let height = CGFloat(Self.height)
        let size = height * 0.0625 * CGFloat(SubtitleStyle.size(for: look))
        XCTAssertEqual(size, 540 * 0.0625 * 0.78, accuracy: 0.01)
        let (outline, fill) = SubtitleOverlay.strings("Illinois", runs: SubtitleScript.runs(in: "Illinois"), look: look, size: size)
        let a = outline.attributes(at: 0, effectiveRange: nil)
        #if canImport(UIKit)
        let font = a[.font] as! UIFont
        #else
        let font = a[.font] as! NSFont
        #endif
        XCTAssertEqual(font.fontName, "Inter18pt-SemiBold")
        XCTAssertEqual(font.pointSize, size, accuracy: 0.01)
        XCTAssertEqual(a[.strokeWidth] as? Double, 6, "outline 3 % of the font height, stroke only")
        XCTAssertNotNil(fill, "the letters are their own layer on top of the outline")
        XCTAssertNil(fill?.attribute(.strokeWidth, at: 0, effectiveRange: nil))
        XCTAssertFalse(look.shadow); XCTAssertFalse(look.background)
        XCTAssertEqual(look.colour.rgb, 0xFFFFFF)

        // Measure: one row through the middle of the letters "l", "l", "I" on a flat mid-grey.
        let image = render(line: "Illinois", styled: [], look: look, flat: 0.5)
        let w = image.width, h = image.height
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &raw, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func luma(_ x: Int, _ y: Int) -> Int { let i = (y * w + x) * 4; return (Int(raw[i]) + Int(raw[i + 1]) + Int(raw[i + 2])) / 3 }
        // The text sits at the bottom of the crop; take the row with the most light pixels.
        var best = 0, bestRow = 0
        for y in 0..<h { let n = (0..<w).filter { luma($0, y) > 200 }.count; if n > best { best = n; bestRow = y } }
        var stems: [Int] = [], rims: [Int] = []
        var x = 0
        while x < w {
            if luma(x, bestRow) > 200 {
                var e = x; while e < w, luma(e, bestRow) > 200 { e += 1 }
                // Dark pixels in the 8 pixels left of the stem (the edge pixel in between is a blend).
                let dark = (max(0, x - 8)..<x).filter { luma($0, bestRow) < 90 }.count
                stems.append(e - x); rims.append(dark)
                x = e
            } else { x += 1 }
        }
        XCTAssertGreaterThanOrEqual(stems.count, 3, "no stems found")
        let em = Double(size) * Double(Self.scale)
        let stem = Double(stems.sorted()[stems.count / 2]), rim = Double(rims.sorted()[rims.count / 2])
        try "stem \(stem) px (\(stem / em) em), outline \(rim) px (\(rim / em) em), font \(em) px\n"
            .appendLine(to: outDir.appendingPathComponent("stem.txt"))
        XCTAssertGreaterThan(stem / em, 0.09, "stem too thin: \(stem) of \(em)")
        XCTAssertLessThan(stem / em, 0.18)
        XCTAssertLessThanOrEqual(rim, stem * 0.6, "outline \(rim) px against a stem of \(stem) px")
        XCTAssertGreaterThanOrEqual(rim, 1, "no outline")
    }

    func testLettersAreTheSavedColourNotDimmed() {
        for colour in [SubtitleLook.Colour.white, .yellow, .grey] {
            let look = SubtitleLook(colour: colour, outline: .normal, shadow: true)
            let image = render(line: "Chaos must reign. Where did you go?", styled: [], look: look, flat: 0)
            let w = image.width, h = image.height
            var raw = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &raw, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let rgb = look.colour.rgb
            let want = ((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)
            var exact = 0, bright = 0
            var histogram: [Int: Int] = [:]
            defer {
                let top = histogram.sorted { $0.value > $1.value }.prefix(3).map { String(format: "%06X x%d", $0.key, $0.value) }
                try? "\(colour) wants \(String(rgb, radix: 16)): \(top)\n".appendLine(to: outDir.appendingPathComponent("colour.txt"))
            }
            for i in stride(from: 0, to: raw.count, by: 4) {
                let r = Int(raw[i]), g = Int(raw[i + 1]), b = Int(raw[i + 2])
                if r + g + b > 150 { bright += 1; histogram[r << 16 | g << 8 | b, default: 0] += 1 }
                if abs(r - want.0) < 6, abs(g - want.1) < 6, abs(b - want.2) < 6 { exact += 1 }
            }
            XCTAssertGreaterThan(bright, 2000, "\(colour): no letters")
            XCTAssertGreaterThan(Double(exact), Double(bright) * 0.5, "\(colour): only \(exact) of \(bright) light pixels have the colour")
        }
    }
}

extension String {
    func appendLine(to url: URL) throws {
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try (old + self).write(to: url, atomically: true, encoding: .utf8)
    }
}
