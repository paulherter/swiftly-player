import CGtk
import Foundation
import JellyfinKit

/// A measured, cropped logo as a texture.
///
/// The pointer is a reference that memory holds and never releases: there is at
/// most one logo per address, and it is small.
struct TitleLogo: @unchecked Sendable {
    let texture: OpaquePointer
    let measurement: LogoMeasurement
}

/// Remembers logos per address; "no usable logo" is remembered too, so not
/// every page fetches again. Touched only on GTK's main thread.
///
/// Cropping and measuring (`TitleMarksMetric`, in the package) run elsewhere.
enum TitleLogoCache {
    nonisolated(unsafe) private static var known: [URL: TitleLogo] = [:]
    nonisolated(unsafe) private static var empty: Set<URL> = []

    /// `.some(nil)`: address without a usable logo. `nil`: not tried yet.
    static func remembered(_ url: URL) -> TitleLogo?? {
        if let present = known[url] { return .some(present) }
        return empty.contains(url) ? .some(nil) : nil
    }

    static func remember(_ url: URL, _ logo: TitleLogo?) {
        if let logo { known[url] = logo } else { empty.insert(url) }
    }

    /// Decode, read premultiplied, measure, crop to the opaque area. Dark logos
    /// become a white silhouette (same alpha). Allowed on any thread.
    static func gauge(_ data: Data) -> TitleLogo? {
        data.withUnsafeBytes { buffer -> TitleLogo? in
            guard let base = buffer.baseAddress, let loader = gdk_pixbuf_loader_new() else { return nil }
            defer { g_object_unref(UnsafeMutableRawPointer(loader)) }
            var error: UnsafeMutablePointer<GError>?
            let written = gdk_pixbuf_loader_write(loader, base.assumingMemoryBound(to: guchar.self),
                                                      gsize(buffer.count), &error) != 0
            if let f = error { g_error_free(f); error = nil }
            let closed = gdk_pixbuf_loader_close(loader, &error) != 0
            if let f = error { g_error_free(f) }
            guard written, closed, let image = gdk_pixbuf_loader_get_pixbuf(loader),
                  gdk_pixbuf_get_bits_per_sample(image) == 8 else { return nil }
            let alpha = gdk_pixbuf_get_has_alpha(image) != 0
            let channels = Int(gdk_pixbuf_get_n_channels(image))
            guard channels == (alpha ? 4 : 3) else { return nil }
            let b = Int(gdk_pixbuf_get_width(image)), h = Int(gdk_pixbuf_get_height(image))
            let step = Int(gdk_pixbuf_get_rowstride(image))
            guard b > 0, h > 0, let pixel = gdk_pixbuf_read_pixel_bytes(image) else { return nil }
            defer { g_bytes_unref(pixel) }
            var length: gsize = 0
            guard let raw = g_bytes_get_data(pixel, &length)?.assumingMemoryBound(to: UInt8.self),
                  Int(length) >= (h - 1) * step + b * channels else { return nil }

            // GdkPixbuf does not deliver premultiplied data; the package measures and GTK
            // draws premultiplied.
            var rgba = [UInt8](repeating: 0, count: b * h * 4)
            for y in 0..<h {
                for x in 0..<b {
                    let q = y * step + x * channels
                    let z = (y * b + x) * 4
                    let a = alpha ? Int(raw[q + 3]) : 255
                    rgba[z] = UInt8((Int(raw[q]) * a + 127) / 255)
                    rgba[z + 1] = UInt8((Int(raw[q + 1]) * a + 127) / 255)
                    rgba[z + 2] = UInt8((Int(raw[q + 2]) * a + 127) / 255)
                    rgba[z + 3] = UInt8(a)
                }
            }
            guard let m = TitleMarksMetric.measure(rgba: rgba, width: b, height: h) else { return nil }
            let dark = TitleMarksMetric.isDark(luminance: m.luminance)
            var toward = [UInt8](repeating: 0, count: m.width * m.height * 4)
            for y in 0..<m.height {
                for x in 0..<m.width {
                    let q = ((y + m.y) * b + x + m.x) * 4
                    let z = (y * m.width + x) * 4
                    let a = rgba[q + 3]
                    if dark {
                        // White, premultiplied: all channels equal alpha.
                        toward[z] = a; toward[z + 1] = a; toward[z + 2] = a
                    } else {
                        toward[z] = rgba[q]; toward[z + 1] = rgba[q + 1]; toward[z + 2] = rgba[q + 2]
                    }
                    toward[z + 3] = a
                }
            }
            let texture: OpaquePointer? = toward.withUnsafeBytes { p in
                guard let bytes = g_bytes_new(p.baseAddress, gsize(p.count)) else { return nil }
                defer { g_bytes_unref(bytes) }
                return gdk_memory_texture_new(Int32(m.width), Int32(m.height),
                                              GDK_MEMORY_R8G8B8A8_PREMULTIPLIED,
                                              bytes, gsize(m.width * 4))
            }
            guard let texture else { return nil }
            return TitleLogo(texture: texture, measurement: m)
        }
    }
}

/// The two widgets of the title slot, carried across thread boundaries; only
/// touched on the main thread.
struct TitleFields: @unchecked Sendable {
    let image: Widget!
    let text: Widget!
    /// The frame that holds the logo size. A `GtkPicture` is naturally as large as
    /// its texture; with `halign: START` in the overlay slot it took that size (at
    /// most the slot) and `GTK_CONTENT_FIT_FILL` stretched the image to 640 x 42.
    /// So the size from `TitleMarksMetric.size` is set on the frame.
    let frameRect: Widget!

    static func showItem(_ logo: TitleLogo, in f: TitleFields, soft: Bool) {
        let g = TitleMarksMetric.size(pagesRatio: logo.measurement.pagesRatio,
                                        density: logo.measurement.density,
                                        row: Double(Theme.titleLarge), maxWidth: 640,
                                        maxHeight: 42)
        gtk_widget_set_size_request(f.frameRect, Int32(g.width.rounded()), Int32(g.height.rounded()))
        gtk_picture_set_paintable(OpaquePointer(f.image), logo.texture)
        guard soft, !PushLock.drives else {
            gtk_widget_set_opacity(f.image, 1)
            gtk_widget_set_opacity(f.text, 0)
            return
        }
        runningCount(on: f.image, duration: motionReduced() ? Theme.timeReduced : 0.22) { e in
            gtk_widget_set_opacity(f.image, e)
            gtk_widget_set_opacity(f.text, 1 - e)
        } done: {
            gtk_widget_set_opacity(f.image, 1)
            gtk_widget_set_opacity(f.text, 0)
        }
    }
}

extension App {
    /// **Title as logo** in the fixed title slot of the movie and series page
    /// (Mac: `TitleMark(slot: .compartment(height: 42))`).
    ///
    /// The text stays in place; if the switch is on and the server has a logo, it
    /// fades in over the text. Size from `TitleMarksMetric.size` (title row 28,
    /// slot 640 × 42): the logo keeps the slot height, nothing below it moves. If
    /// the fetch fails or there is none, the text stays.
    func attachTitleMark(_ wrapper: Widget!, text: Widget!, title: Item) {
        guard selection.titleAsLogo, let addresses,
              let url = ImageSelection.logo(title, addresses: addresses) else { return }
        let imageField: Widget! = gtk_picture_new()
        gtk_picture_set_can_shrink(OpaquePointer(imageField), 1)
        // CONTAIN: the texture's aspect ratio is kept, however much room the frame
        // gives.
        gtk_picture_set_content_fit(OpaquePointer(imageField), GTK_CONTENT_FIT_CONTAIN)
        gtk_widget_set_can_target(imageField, 0)
        gtk_widget_set_opacity(imageField, 0)
        let frameRect = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_halign(frameRect, GTK_ALIGN_START)
        gtk_widget_set_valign(frameRect, GTK_ALIGN_CENTER)
        gtk_widget_set_overflow(frameRect, GTK_OVERFLOW_HIDDEN)
        gtk_widget_set_can_target(frameRect, 0)
        append(frameRect, imageField)
        gtk_overlay_add_overlay(OpaquePointer(wrapper), frameRect)

        let fields = TitleFields(image: imageField, text: text, frameRect: frameRect)
        if let remembered = TitleLogoCache.remembered(url) {
            if let logo = remembered { TitleFields.showItem(logo, in: fields, soft: false) }
            return
        }
        let symbolText = LifeCharacter(imageField)
        Task.detached { [self] in
            _ = self
            var logo: TitleLogo?
            if let data = await ImageStorage.shared.load(url, key: ImageKey.of(url)) {
                logo = TitleLogoCache.gauge(data)
            }
            let result = logo
            onMainThread {
                TitleLogoCache.remember(url, result)
                guard symbolText.lives, let result else { return }
                TitleFields.showItem(result, in: fields, soft: true)
            }
        }
    }
}
