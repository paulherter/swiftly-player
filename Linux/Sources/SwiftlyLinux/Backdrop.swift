import CGtk
import Foundation
import JellyfinKit

/// **Header image: masked, not painted over.**
///
/// The Mac fades the backdrop out with a *mask*: the image turns transparent
/// at its edges and whatever is behind shows through, so there is no visible
/// edge. Two gradient layers painted **over** the image look the same, but an
/// overpainted edge has to match the background exactly at every scroll
/// position and window placement; in practice it left seams (light, black, or
/// a white hairline).
///
/// `cairo_mask` paints a source **through** a pattern. Two nested groups
/// multiply the two masks, like two consecutive `.mask` calls. Where the mask
/// is zero nothing is painted, so no edge can appear.
///
/// The stops match the tvOS version. Only the vertical one is compressed: on
/// the Mac the backdrop extends beyond the header zone and fades out below it
/// (via `zIndex`). In a GTK box the next sibling paints on top, so the fade
/// has to end within the 380 points.
///
/// `@unchecked Sendable` for the same reason as ``Zeigerkiste``: it is only
/// touched on GTK's main thread. Reloads come back via ``onMainThread``
/// before ``setzen(_:)`` is called.
final class Backdrop: @unchecked Sendable {

    /// Pixel data in the layout Cairo expects. The buffer must outlive the
    /// surface, so it is stored here.
    private var points: [UInt8] = []
    private var area: OpaquePointer?
    private var width = 0
    private var height = 0

    /// **The finished masked image, computed once.**
    ///
    /// Without it every draw recomputes the whole chain (scaling a 1600 pt wide
    /// image, two mask groups) on each frame. GTK redraws continuously while
    /// scrolling, so it stuttered exactly while the header zone was visible.
    ///
    /// It is now recomputed only when size or image change; otherwise the
    /// finished surface is composited.
    private var done: OpaquePointer?
    private var readyWidth = 0
    private var readyHeight = 0
    private var readySplitter: Int32 = 1

    let display: Widget

    /// **Is the drawing area still alive?**
    ///
    /// The header image comes from the network and may arrive after the page is
    /// closed. ``setzen(_:)`` then called `gtk_widget_queue_draw` on a widget GTK
    /// had already destroyed:
    ///
    ///     Gtk-CRITICAL: gtk_widget_queue_draw: assertion 'GTK_IS_WIDGET (widget)' failed
    ///
    /// The assertion itself reads freed memory, so it is not a safety net but the
    /// first bad access.
    ///
    /// Not private: the banner timer of the person page asks this before it sets
    /// a new image or keeps waiting. A timer pointing at a destroyed GTK object
    /// crashes.
    private(set) var lives = true

    /// **Paint across the full width instead of right-aligned at 62 %.**
    ///
    /// The 62 % layout is the *detail page* composition: text on a dark
    /// background on the left, image on the right. The **person page** has no
    /// such text (a round head sits bottom left) and the banner fills the whole
    /// width (`Heldbild` on Apple). With the detail-page layout the left 38 %
    /// stayed empty.
    var fullWide = false

    init(height: Int = Theme.heroHeightValue) {
        let inputField: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(inputField, "swiftly-blank")
        gtk_widget_set_hexpand(inputField, 1)
        gtk_widget_set_size_request(inputField, -1, Int32(height))
        display = inputField!
        gtk_drawing_area_set_draw_func(asCharacter(inputField), backdropDraw,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        // **The drawing area holds the backdrop, not the other way round.** The
        // draw callback gets `self` *unretained*, so it must not be the last owner.
        // The job here provides that ownership: it hangs on the widget and is freed
        // with it. A dictionary in ``App`` used to do this and was never emptied, so
        // every opened detail page stayed in memory.
        signal(inputField, "destroy") { self.lives = false }
    }

    deinit { areaResolve(); readyResolve() }

    private func areaResolve() {
        if let area { cairo_surface_destroy(area); self.area = nil }
    }

    private func readyResolve() {
        if let done { cairo_surface_destroy(done); self.done = nil }
        readyWidth = 0
        readyHeight = 0
        readySplitter = 1
    }

    /// When the backdrop was created: an image that is available right away
    /// (from cache) is shown immediately; a later one fades in.
    private let born = Date()

    /// Decoded pixels of an image, passed across thread boundaries.
    struct Unpacked: Sendable {
        let points: [UInt8]
        let width: Int
        let height: Int
        let tick: Int
    }

    /// Decodes an image. Callable **off the main thread**
    /// (`gdk_texture_new_from_bytes` is thread-safe). Decoding a 1600 pt wide
    /// header on the main thread caused a visible stall when opening a series.
    static func unpack(_ data: Data) -> Unpacked? {
        data.withUnsafeBytes { buffer -> Unpacked? in
            guard let base = buffer.baseAddress,
                  let bytes = g_bytes_new(base, gsize(buffer.count)) else { return nil }
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
            // Cairo dictates the row stride.
            let tick = Int(cairo_format_stride_for_width(CAIRO_FORMAT_RGB24, Int32(width)))
            var points = [UInt8](repeating: 0, count: tick * height)
            points.withUnsafeMutableBufferPointer { cache in
                guard let target = cache.baseAddress else { return }
                // `gdk_texture_download` returns 8-bit BGRA, which on a little-endian
                // machine is exactly Cairo's ARGB32.
                gdk_texture_download(texture, target, gsize(tick))
            }
            return Unpacked(points: points, width: width, height: height, tick: tick)
        }
    }

    /// Accepts a downloaded image. Decoding happens in the background, placing
    /// on the main thread.
    func setDown(_ data: Data) {
        guard lives else { return }
        Task.detached { [self] in
            guard let image = Backdrop.unpack(data) else { return }
            onMainThread { self.layOn(image) }
        }
    }

    // MARK: Same image on rebuild

    /// **A rebuilt page takes the image along.** The detail page rebuilds with
    /// the full title after the push transition (``postPush``), including a
    /// new backdrop. That backdrop stayed empty until the same image was fetched
    /// and decoded a second time, causing a brief black flash. Now the last
    /// decoded image of a title is placed in the first frame of the new backdrop,
    /// and an identical URL is not applied again.
    /// Two entries (the page and the one below); more would only waste memory.
    nonisolated(unsafe) private static var remembered: [(key: String, source: URL, image: Unpacked)] = []

    /// The title under which this backdrop remembers its image, and the one it shows.
    private var key: String?
    private(set) var source: URL?

    /// Immediately applies the remembered image of the title, if there is one.
    func withRemembered(_ key: String) {
        self.key = key
        guard let entryRecord = Backdrop.remembered.first(where: { $0.key == key }) else { return }
        source = entryRecord.source
        layOn(entryRecord.image)
    }

    /// Like ``setzen(_:)`` but with a URL: the one already shown is not applied
    /// again. A different one is applied once it is decoded and ready; the old
    /// image stays until then, never an empty view.
    func setDown(_ data: Data, from url: URL) {
        guard lives, url != source else { return }
        let remember = key
        Task.detached { [self] in
            guard let image = Backdrop.unpack(data) else { return }
            onMainThread {
                if let remember {
                    Backdrop.remembered.removeAll { $0.key == remember }
                    Backdrop.remembered.insert((remember, url, image), at: 0)
                    if Backdrop.remembered.count > 2 { Backdrop.remembered.removeLast() }
                }
                guard self.lives, url != self.source else { return }
                let change = self.source != nil
                self.source = url
                self.layOn(image)
                // A genuinely different image cross-fades instead of jumping.
                if change {
                    gtk_widget_set_opacity(self.display, 0.4)
                    crossfade(self.display, on: 1, duration: FadeTimes.headerImage, curve: .easeOut)
                }
            }
        }
    }

    /// **It also fades in** when it arrives after opening, like the header image
    /// on Apple (`NetworkImage`), using `FadeTimes.headerImage`.
    private func layOn(_ image: Unpacked) {
        // If the image arrives after the page is gone, there is nothing to paint.
        guard lives else { return }
        let firstOne = area == nil
        width = image.width
        height = image.height
        points = image.points
        areaResolve()
        readyResolve()
        points.withUnsafeMutableBufferPointer { cache in
            guard let target = cache.baseAddress else { return }
            area = cairo_image_surface_create_for_data(
                target, CAIRO_FORMAT_RGB24, Int32(width), Int32(height), Int32(image.tick))
        }
        if firstOne, Date().timeIntervalSince(born) > Backdrop.immediateDeadline {
            gtk_widget_set_opacity(display, 0)
            crossfade(display, on: 1, duration: FadeTimes.headerImage, curve: .easeOut)
        }
        gtk_widget_queue_draw(display)
    }

    /// An image that arrives this fast came from cache and is shown directly.
    static let immediateDeadline = 0.15

    /// **The stops of the tvOS version.** Values are the image's visibility.
    private static let landscape: [(Double, Double)] = [
        (0.00, 0.00), (0.15, 0.05), (0.29, 0.22), (0.45, 0.50),
        (0.57, 0.75), (0.70, 0.90), (0.85, 0.98), (1.00, 1.00),
    ]
    private static let up: [(Double, Double)] = [
        (0.00, 1.00), (0.55, 1.00), (0.65, 0.92), (0.78, 0.70),
        (0.88, 0.38), (0.95, 0.12), (1.00, 0.00),
    ]

    fileprivate func draw(_ cr: OpaquePointer, _ w: Double, _ h: Double) {
        // **An implausible allocation is not recomputed, but still painted.**
        //
        // While the content is rebuilt, GTK briefly allocates the area a width of a
        // few points. Recomputing for that would show a postage-stamp sized image
        // for one frame and the correct one on the next, which flickers. Below 80 pt
        // width the existing surface therefore stays.
        //
        // A `guard` here used to abort painting too, which caused flicker on the
        // first switch to a tab: the finished surface existed but was not painted.
        // Now the condition only affects recomputation.
        let divider = max(gtk_widget_get_scale_factor(display), 1)
        let credible = area != nil && width > 0 && height > 0
                           && w >= 80 && h >= 40
        if credible,
           done == nil || readyWidth != Int(w) || readyHeight != Int(h)
            || readySplitter != divider {
            readyCompute(w, h, divider)
        }
        guard let done else { return }
        // **The cache is in device pixels.** The draw call works in points; on a
        // HiDPI screen a surface of point size would be scaled up and blurry.
        cairo_save(cr)
        let s = 1.0 / Double(readySplitter)
        cairo_scale(cr, s, s)
        cairo_set_source_surface(cr, done, 0, 0)
        cairo_paint(cr)
        cairo_restore(cr)
    }

    /// Computes the masked image once into its own surface.
    ///
    /// **The old surface stays until the new one is finished.**
    ///
    /// `readyResolve()` used to be the first line. If anything failed afterwards
    /// (during a content rebuild GTK briefly gives the drawing area an unusable
    /// size), `done` was `nil` and ``malen(_:_:_:)`` returned without drawing
    /// anything. The header image seemed to vanish briefly and come back when
    /// switching between episodes, cast and similar. The Mac does not have this
    /// because there the image is a view, not a surface that gets discarded.
    private func readyCompute(_ w: Double, _ h: Double, _ divider: Int32) {
        guard let area else { return }
        guard let target = cairo_image_surface_create(CAIRO_FORMAT_ARGB32,
                                                    Int32(w) * divider,
                                                    Int32(h) * divider),
              let cr = cairo_create(target) else { return }
        // From here the new surface is in place; only now may the old one go.
        readyResolve()
        defer { cairo_destroy(cr) }
        cairo_scale(cr, Double(divider), Double(divider))

        // **`max(width * 0.62, 520)`: the Mac's formula**, right-aligned.
        // The person page uses the full width instead, see ``fullWide``.
        let bb = fullWide ? w : max(w * 0.62, 520)
        let x0 = w - bb

        // Fill-fit: the larger of the two scale factors wins, the rest is cropped.
        let s = max(bb / Double(width), h / Double(height))
        let bx = x0 + (bb - Double(width) * s) / 2
        let by = (h - Double(height) * s) / 2

        cairo_rectangle(cr, x0, 0, bb, h)
        cairo_clip(cr)

        // Two groups: the inner one carries the image, the outer one the image
        // times the first mask. The second mask then applies to both, like two
        // consecutive `.mask` calls on the Mac.
        cairo_push_group(cr)
        cairo_push_group(cr)
        cairo_save(cr)
        cairo_translate(cr, bx, by)
        cairo_scale(cr, s, s)
        cairo_set_source_surface(cr, area, 0, 0)
        cairo_paint(cr)
        cairo_restore(cr)
        cairo_pop_group_to_source(cr)

        let levelRight = cairo_pattern_create_linear(x0, 0, x0 + bb, 0)
        for (spot, coverage) in Self.landscape {
            cairo_pattern_add_color_stop_rgba(levelRight, spot, 1, 1, 1, coverage)
        }
        cairo_mask(cr, levelRight)
        cairo_pattern_destroy(levelRight)
        cairo_pop_group_to_source(cr)

        let verticalRight = cairo_pattern_create_linear(0, 0, 0, h)
        for (spot, coverage) in Self.up {
            cairo_pattern_add_color_stop_rgba(verticalRight, spot, 1, 1, 1, coverage)
        }
        cairo_mask(cr, verticalRight)
        cairo_pattern_destroy(verticalRight)

        done = target
        readyWidth = Int(w)
        readyHeight = Int(h)
        readySplitter = divider
    }
}

/// Signature: `(GtkDrawingArea*, cairo_t*, int, int, gpointer)`.
nonisolated(unsafe) private let backdropDraw: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, width, height, data in
    guard let cr, let data else { return }
    Unmanaged<Backdrop>.fromOpaque(data).takeUnretainedValue()
        .draw(cr, Double(width), Double(height))
}
