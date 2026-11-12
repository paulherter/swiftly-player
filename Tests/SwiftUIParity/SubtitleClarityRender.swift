import AppKit
import JellyfinKit
import XCTest

/// Renders the real `SubtitleOverlay` offscreen (Latin and several scripts, four looks) into PNGs and measures them.
/// `SUBTITLE_CLARITY_TAG` names the run (`before`, `after`), `SUBTITLE_CLARITY_OUT` is the folder (default
/// `/tmp/tf-feedback`). Latin lines must stay byte-identical to the `before-` files when those exist.
@MainActor
class SubtitleClarityRender: XCTestCase {
    struct Sample { let name: String; let line: String; let latin: Bool }
    static let samples = [
        Sample(name: "latin", line: "Chaos must reign... Where did you go, Jack?", latin: true),
        Sample(name: "arabic", line: "لا يمكنك الهروب من الماضي، مهما حاولت", latin: false),
        Sample(name: "arabic-dots", line: "ثبت نبي بين يديك يا تيتي", latin: false),
        Sample(name: "mixed", line: "قال Jack: سأعود غداً، ثم ضحك", latin: false),
        Sample(name: "hebrew", line: "אי אפשר לברוח מהעבר, לא משנה כמה תנסה", latin: false),
        Sample(name: "devanagari", line: "तुम अतीत से भाग नहीं सकते, चाहे कितनी कोशिश करो", latin: false),
    ]
    static let looks: [(name: String, look: SubtitleLook)] = [
        ("normal", SubtitleLook(outline: .normal)),
        ("shadow", SubtitleLook(outline: .normal, shadow: true)),
        ("thin", SubtitleLook(outline: .thin, shadow: true)),
        ("plain", SubtitleLook(outline: .off)),
    ]
    static let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUBTITLE_CLARITY_OUT"] ?? "/tmp/tf-feedback")
    static let tag = ProcessInfo.processInfo.environment["SUBTITLE_CLARITY_TAG"] ?? "run"
    static let width = 1080, height = 540, scale = 2

    override func setUp() async throws {
        // The unhosted test bundle has no Inter in its main bundle: register the app's file.
        let font = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Shared/Assets/Inter-SemiBold.ttf")
        CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
    }

    /// The whole picture area with the subtitle on a flat grey, cropped to the subtitle band (RGBA, premultiplied).
    func render(_ line: String, look: SubtitleLook) -> (image: CGImage, pixels: [UInt8]) {
        UserDefaults.standard.set(look.encoded(), forKey: "utAussehen")
        let overlay = SubtitleOverlay()
        let bounds = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        overlay.show(line, in: bounds, picture: .zero)
        let s = Self.scale
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(data: nil, width: Self.width * s, height: Self.height * s, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space, bitmapInfo: info)!
        ctx.setFillColor(CGColor(gray: 0.44, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: Self.width * s, height: Self.height * s))
        ctx.scaleBy(x: CGFloat(s), y: CGFloat(s))
        overlay.layer.render(in: ctx)
        let crop = CGRect(x: (Self.width * s - 1500) / 2, y: Self.height * s - 190 - 6, width: 1500, height: 190)
        let image = ctx.makeImage()!.cropping(to: crop)!
        return (image, pixels(of: image))
    }

    func pixels(of image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    func png(_ image: CGImage) -> Data {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    }

    /// Pixels that are clearly the white letter / the black outline on the grey (grey is 112).
    func counts(_ pixels: [UInt8]) -> (white: Int, dark: Int) {
        var white = 0, dark = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let v = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
            if v > 3 * 190 { white += 1 } else if v < 3 * 50 { dark += 1 }
        }
        return (white, dark)
    }

    /// Renders everything, writes `<tag>-<sample>-<look>.png` and `<tag>-numbers.txt`; Latin against `before-`.
    func testRenderAll() throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var report = "sample look white dark whiteVsPlain\n"
        for sample in Self.samples {
            let reference = counts(render(sample.line, look: Self.looks[3].look).pixels).white
            for (name, look) in Self.looks {
                let (image, pixels) = render(sample.line, look: look)
                let data = png(image)
                let file = "\(Self.tag)-\(sample.name)-\(name).png"
                try data.write(to: Self.out.appendingPathComponent(file))
                let c = counts(pixels)
                report += "\(sample.name) \(name) \(c.white) \(c.dark) \(String(format: "%.3f", Double(c.white) / Double(max(reference, 1))))\n"
                if !sample.latin, Self.tag != "before" {
                    // The letters are drawn on top of the outline: (nearly) all of their white is back.
                    // (A mixed line keeps its Latin words as they were, with about a third of the white.)
                    if look.outline != .off {
                        XCTAssertGreaterThan(Double(c.white) / Double(max(reference, 1)), sample.name == "mixed" ? 0.6 : 0.8, file)
                    }
                    if look.outline == .off { XCTAssertEqual(c.dark, 0, file) }
                }
                if sample.latin, Self.tag != "before" {
                    let before = Self.out.appendingPathComponent("before-\(sample.name)-\(name).png")
                    if let old = try? Data(contentsOf: before) {
                        XCTAssertEqual(data, old, "Latin line changed: \(file)")
                    }
                }
            }
        }
        try report.write(to: Self.out.appendingPathComponent("\(Self.tag)-numbers.txt"), atomically: true, encoding: .utf8)
    }
}
