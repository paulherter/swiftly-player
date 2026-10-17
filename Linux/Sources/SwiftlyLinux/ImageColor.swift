import CGtk
import Foundation
import JellyfinKit

/// **The hues of an image, for the detail page background.**
///
/// Same calculation as on iPhone, Mac and TV (`Sources/Shared/ImageTone.swift`):
/// only the **hues** come from the image, up to five, as peaks of a histogram;
/// the app sets saturation and brightness. The calculation itself lives in
/// ``Bildtonrechnung`` in the package, with tests. This file only covers the
/// path to the pixels and the GTK presentation.
enum ImageColor {

    /// The hues in degrees; empty if the image yields none (grayscale).
    ///
    /// The path to the pixels is the same as in ``imageSet``: raw bytes to
    /// `GBytes`, then a `GdkTexture` that detects the format itself.
    /// `gdk_texture_download` returns BGRA; the package works in RGBA. The server
    /// already delivers the image small (48 points, like
    /// `kCGImageSourceThumbnailMaxPixelSize: 48` on Apple).
    static func tones(from data: Data) -> [Double]? {
        data.withUnsafeBytes { buffer -> [Double]? in
            guard let base = buffer.baseAddress else { return nil }
            guard let bytes = g_bytes_new(base, gsize(buffer.count)) else { return nil }
            defer { g_bytes_unref(bytes) }

            var error: UnsafeMutablePointer<GError>?
            guard let texture = gdk_texture_new_from_bytes(bytes, &error) else {
                if let error { g_error_free(error) }
                return nil
            }
            defer { g_object_unref(UnsafeMutableRawPointer(texture)) }

            let width = Int(gdk_texture_get_width(texture))
            let height = Int(gdk_texture_get_height(texture))
            guard width > 0, height > 0 else { return nil }

            let tick = width * 4
            var points = [UInt8](repeating: 0, count: tick * height)
            points.withUnsafeMutableBufferPointer { cache in
                guard let base = cache.baseAddress else { return }
                gdk_texture_download(texture, base, gsize(tick))
            }
            // BGRA → RGBA
            var i = 0
            while i + 3 < points.count {
                points.swapAt(i, i + 2)
                i += 4
            }
            return AvComputation.tones(rgba: points)
        }
    }
}

/// **A second style sheet, only for the color of open pages.**
///
/// The large sheet in ``Theme`` is fixed; the color changes with every title. A
/// separate provider with higher priority can be swapped without reloading
/// everything else.
///
/// **One class per page** (`swiftly-bildton-<n>`). A single rule for all pages
/// made a new detail page show the previous page's hue until its own arrived,
/// visible during the slide-in. The last few classes stay so the outgoing page
/// keeps its color while it slides out.
///
/// **The background is an image, not a gradient.** GTK style sheets only know
/// linear and radial gradients; the reference color is a mesh
/// (`MeshGradient`), strongest at the top right under the backdrop, fading back
/// to `reason` in OKLab over ``auslauf`` points. The package computes the color
/// at each point of a coarse grid
/// (``Bildtonrechnung/punkte(_:spalten:zeilen:hoehe:farbhoehe:ab:auslauf:)``);
/// GTK scales it smoothly as the page background. The last row is exactly
/// `reason`, so the base color continues below without an edge.
///
/// **Plus the TV's noise** (`ImageTone.noise`, one step of amplitude), tiled
/// over the image: dark gradients in eight bit would otherwise show banding.
enum AudioSheet {
    nonisolated(unsafe) private static var provider: UnsafeMutablePointer<GtkCssProvider>?
    nonisolated(unsafe) private static var rules: [(classKind: String, css: String)] = []
    nonisolated(unsafe) private static var counter = 0
    nonisolated(unsafe) private static var remembered: [String: [Double]] = [:]
    nonisolated(unsafe) private static var railsEpisode: [String] = []

    /// Height of the header image (Linux: ``Stil/heroHeightValue``) above which the color
    /// is at full strength, like `MoodReason(since: Theme.heroHeightValue)` on the Mac.
    static var since: Double { Double(Theme.heroHeightValue) }
    /// The color is spread over this height, as on TV (`MoodReason.colorHeight`).
    static let colorHeight: Double = 900
    /// Length over which the color fades back to `reason` below the header
    /// (`MoodReason.runOut`).
    static let runOut: Double = 1300

    /// For the ``Fernsteuerpult``: which classes have rules, and how long.
    static var state: String {
        rules.map { "\($0.classKind)=\($0.css.count)" }.joined(separator: " ")
    }

    /// A new class for a new page.
    static func newClass() -> String {
        counter += 1
        return "swiftly-bildton-\(counter)"
    }

    /// The class a page carries, read from the page itself so a late-loaded header
    /// does not take the class of a newer page.
    static func classKind(from page: Widget!) -> String? {
        guard let page, let list = gtk_widget_get_css_classes(page) else { return nil }
        defer { g_strfreev(list) }
        var i = 0
        while let entryRecord = list[i] {
            let name = String(cString: entryRecord)
            if name.hasPrefix("swiftly-bildton-") { return name }
            i += 1
        }
        return nil
    }

    /// Hues already computed for a title, without waiting, so a page you return to
    /// has its color in the first frame (iOS `ImageTone.remembered(fuer:)`).
    static func remembers(_ id: String) -> [Double]? { remembered[id] }

    static func remember(_ id: String, _ tones: [Double]) {
        if remembered[id] == nil { railsEpisode.append(id) }
        remembered[id] = tones
        if railsEpisode.count > 300 {
            let distance = railsEpisode.prefix(railsEpisode.count - 300)
            for alt in distance { remembered[alt] = nil }
            railsEpisode.removeFirst(distance.count)
        }
    }

    /// The layout that carries a page's hue (``statusRemember(_:klasse:)``).
    nonisolated(unsafe) private static var situations: [String: Widget] = [:]

    /// Remembers a page's hue layout until GTK removes it.
    static func statusRemember(_ status: Widget!, classKind: String) {
        guard let status else { return }
        situations[classKind] = status
        signal(status, "destroy") { situations[classKind] = nil }
    }

    /// **The hue fades in** (`FadeTimes.headerImage`, `easeOut`) only if it was not
    /// already remembered on opening; otherwise the layout is already in place.
    static func reveal(_ classKind: String) {
        guard let status = situations[classKind], gtk_widget_get_opacity(status) < 0.999 else { return }
        crossfade(status, on: 1, duration: FadeTimes.headerImage, curve: .easeOut)
    }

    /// Sets a page's color. Empty hues mean `reason` stays.
    static func setDown(_ tones: [Double], classKind: String) {
        if provider == nil {
            provider = gtk_css_provider_new()
            Theme.logCssErrors(provider)
            if let display = gdk_display_get_default(), let provider {
                gtk_style_context_add_provider_for_display(display,
                                                           OpaquePointer(provider), 900)
            }
        }
        guard let provider else { return }
        rules.removeAll { $0.classKind == classKind }
        if !tones.isEmpty, let css = rule(tones, classKind: classKind) {
            rules.append((classKind, css))
        }
        if rules.count > 8 { rules.removeFirst(rules.count - 8) }
        gtk_css_provider_load_from_string(provider, rules.map(\.css).joined(separator: "\n"))
    }

    private static func rule(_ tones: [Double], classKind: String) -> String? {
        let height = since + runOut
        let columns = 48, rows = 168
        let points = AvComputation.points(tones, columns: columns, rows: rows, height: height,
                                            colorHeight: since + colorHeight, since: since, runOut: runOut)
        guard points.count == columns * rows,
              let audio = pngData(points.map { UInt32(bitPattern: $0) }, width: columns, height: rows)
        else { return nil }
        // The season list lies opaque over the episodes, in the page's hue at this
        // position, with 8 % white on top (iOS/Mac `SeriesView`,
        // `ImageTone.farbe(tones, at: (0,2, 0,55))`).
        let f = AvComputation.color(tones, x: 0.2, y: 0.55)
        func k(_ w: Double) -> Int { Int((min(max(w * 0.92 + 0.08, 0), 1) * 255).rounded()) }
        return """
        .swiftly-seitenton.\(classKind) {
            background-color: \(Theme.reason);
            background-image: url("data:image/png;base64,\(noise)"),
                              url("data:image/png;base64,\(audio.base64EncodedString())");
            background-repeat: repeat, no-repeat;
            background-size: 96px 96px, 100% \(Int(height))px;
            background-position: 0 0, 0 0;
        }
        .\(classKind) .swiftly-staffelliste { background-color: rgb(\(k(f.r)),\(k(f.g)),\(k(f.b))); }
        """
    }

    /// The noise, once: 96 × 96, each pixel randomly black or white, opacity random
    /// up to 0.8 % (`ImageTone.noise` with `.opacity(0.008)`, computed into the
    /// pixels here).
    nonisolated(unsafe) private static let noise: String = {
        let border = 96
        var points = [UInt32](repeating: 0, count: border * border)
        var condition: UInt64 = 0x2545F4914F6CDD1D
        for i in 0 ..< points.count {
            condition ^= condition << 13
            condition ^= condition >> 7
            condition ^= condition << 17
            let bright = (condition & 1) == 1
            let coverage = UInt32((Double(UInt8(truncatingIfNeeded: condition >> 8)) * 0.008).rounded())
            let channel: UInt32 = bright ? coverage : 0   // premultiplied
            points[i] = (coverage << 24) | (channel << 16) | (channel << 8) | channel
        }
        return pngData(points, width: border, height: border, premultiplied: true)?
            .base64EncodedString() ?? ""
    }()

    /// ARGB (one `UInt32` each, `0xAARRGGBB`) to PNG, via a `GdkMemoryTexture`
    /// that GTK can save itself.
    private static func pngData(_ points: [UInt32], width: Int, height: Int,
                                 premultiplied: Bool = false) -> Data? {
        // `0xAARRGGBB` lies in memory (little endian) as B, G, R, A.
        let format = premultiplied ? GDK_MEMORY_B8G8R8A8_PREMULTIPLIED : GDK_MEMORY_B8G8R8A8
        return points.withUnsafeBytes { raw -> Data? in
            guard let base = raw.baseAddress,
                  let bytes = g_bytes_new(base, gsize(raw.count)) else { return nil }
            defer { g_bytes_unref(bytes) }
            guard let texture = gdk_memory_texture_new(Int32(width), Int32(height), format,
                                                      bytes, gsize(width * 4)) else { return nil }
            defer { g_object_unref(UnsafeMutableRawPointer(texture)) }
            guard let png = gdk_texture_save_to_png_bytes(texture) else { return nil }
            defer { g_bytes_unref(png) }
            var length: gsize = 0
            guard let data = g_bytes_get_data(png, &length) else { return nil }
            return Data(bytes: data, count: Int(length))
        }
    }
}
