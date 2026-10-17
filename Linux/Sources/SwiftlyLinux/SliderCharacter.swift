import CGtk
import Foundation

/// **Three sliders, drawn because Adwaita does not have them.**
///
/// The Mac puts `slider.horizontal.3` on the playback chip in the player:
/// three horizontal tracks, each with a knob at a different position. This
/// used `media-eq-symbolic`, which does not exist in the Adwaita set, so GTK
/// showed the "missing image" placeholder.
///
/// Same answer as for ``Sprungzeichen``: what the reference shows and the icon
/// set lacks is drawn. A similar-looking gear would say something else: it
/// means "settings", not "audio and subtitles of this playback".
final class SliderCharacter: @unchecked Sendable {
    /// **Is the drawing area still alive?** See ``Sprungzeichen``: the draw call
    /// does not hold `self`, the area does.
    fileprivate var lives = true
    fileprivate let mass: Double
    let display: Widget

    init(mass: Double = 14) {
        self.mass = mass
        let inputField: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(inputField, "swiftly-blank")
        gtk_drawing_area_set_content_width(asCharacter(inputField), Int32(mass))
        gtk_drawing_area_set_content_height(asCharacter(inputField), Int32(mass))
        display = inputField!
        gtk_drawing_area_set_draw_func(asCharacter(inputField), sliderDraw,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        signal(inputField, "destroy") { self.lives = false }
    }
}

nonisolated(unsafe) private let sliderDraw: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, width, height, data in
    guard let cr, let data else { return }
    let z = Unmanaged<SliderCharacter>.fromOpaque(data).takeUnretainedValue()
    guard z.lives else { return }

    let w = Double(width), h = Double(height)
    let stroke = max(z.mass * 0.085, 1.0)
    let margin = w * 0.08
    // Three tracks on a fifth grid: 1/5, 1/2, 4/5 of the height. The knobs are
    // offset; that is the whole point of the symbol.
    let rows: [(y: Double, knob: Double)] = [
        (h * 0.22, 0.66), (h * 0.50, 0.34), (h * 0.78, 0.72),
    ]
    cairo_set_source_rgba(cr, 1, 1, 1, 1)
    cairo_set_line_width(cr, stroke)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    for row in rows {
        cairo_new_path(cr)
        cairo_move_to(cr, margin, row.y)
        cairo_line_to(cr, w - margin, row.y)
        cairo_stroke(cr)
    }
    // Knobs last and filled: they sit on the track, not next to it, and must
    // cover it.
    for row in rows {
        let x = margin + (w - 2 * margin) * row.knob
        cairo_new_path(cr)
        cairo_arc(cr, x, row.y, stroke * 1.55, 0, 2 * Double.pi)
        cairo_fill(cr)
    }
}

/// **An empty circle, drawn because `radio-symbolic` is something else.**
///
/// The Mac uses `circle` for the *unselected* shape in the selection row: a
/// thin outline, the counterpart of the checkmark. This used `radio-symbolic`,
/// which in the Adwaita set is **a radio set with an antenna**, not a radio
/// button.
///
/// There is no plain outline circle there; `radio-checked-symbolic` would be
/// filled and mean "selected". So it is drawn, like ``Sprungzeichen`` and
/// ``Reglerzeichen``.
final class CircleCharacter: @unchecked Sendable {
    fileprivate var lives = true
    fileprivate let mass: Double
    let display: Widget

    init(mass: Double = 15) {
        self.mass = mass
        let inputField: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(inputField, "swiftly-blank")
        gtk_drawing_area_set_content_width(asCharacter(inputField), Int32(mass))
        gtk_drawing_area_set_content_height(asCharacter(inputField), Int32(mass))
        display = inputField!
        gtk_drawing_area_set_draw_func(asCharacter(inputField), circleDraw,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        signal(inputField, "destroy") { self.lives = false }
    }
}

nonisolated(unsafe) private let circleDraw: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, width, height, data in
    guard let cr, let data else { return }
    let z = Unmanaged<CircleCharacter>.fromOpaque(data).takeUnretainedValue()
    guard z.lives else { return }
    let stroke = max(z.mass * 0.09, 1.0)
    let r = Double(min(width, height)) / 2 - stroke
    // `schriftSehrLeise`: the same color the row has without a selection.
    cairo_set_source_rgba(cr, 1, 1, 1, 0.48)
    cairo_set_line_width(cr, stroke)
    cairo_new_path(cr)
    cairo_arc(cr, Double(width) / 2, Double(height) / 2, r, 0, 2 * Double.pi)
    cairo_stroke(cr)
}

/// **The bookmark, drawn because both icon sets mean something else.**
///
/// The Mac uses `bookmark` and `bookmark.fill`: a plain ribbon, empty or
/// filled. Breeze's `bookmark-new-symbolic` is a ribbon **with a plus**, meaning
/// "create bookmark" rather than "on the watchlist", and
/// `user-bookmarks-symbolic` is a folder. Both say something different from the
/// reference, and the button has two states that must look different.
///
/// Same answer as for ``Sprungzeichen``, ``Reglerzeichen`` and
/// ``Kreiszeichen``.
final class RememberCharacter: @unchecked Sendable {
    fileprivate var lives = true
    fileprivate var filled: Bool
    fileprivate let mass: Double
    let display: Widget

    init(filled: Bool, mass: Double = 17) {
        self.filled = filled
        self.mass = mass
        let inputField: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(inputField, "swiftly-blank")
        gtk_drawing_area_set_content_width(asCharacter(inputField), Int32(mass))
        gtk_drawing_area_set_content_height(asCharacter(inputField), Int32(mass))
        // Centered; otherwise the button stretches the area and the symbol grows.
        gtk_widget_set_halign(inputField, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(inputField, GTK_ALIGN_CENTER)
        display = inputField!
        gtk_drawing_area_set_draw_func(asCharacter(inputField), rememberDraw,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        signal(inputField, "destroy") { self.lives = false }
    }

    /// Toggle without rebuilding the button.
    func setDown(_ new: Bool) {
        guard new != filled else { return }
        filled = new
        gtk_widget_queue_draw(display)
    }

    /// **Which color the symbol uses.** A `Nebenknopf` colors its image through the
    /// style sheet; a drawing area paints itself, so it must follow the switch to
    /// dark text when the button is active.
    fileprivate var dark = false
    func onLightBackground(_ yes: Bool) {
        guard yes != dark else { return }
        dark = yes
        gtk_widget_queue_draw(display)
    }
}

nonisolated(unsafe) private let rememberDraw: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, width, height, data in
    guard let cr, let data else { return }
    let z = Unmanaged<RememberCharacter>.fromOpaque(data).takeUnretainedValue()
    guard z.lives else { return }

    let w = Double(width), h = Double(height)
    let stroke = max(z.mass * 0.088, 1.2)
    // The ribbon: 60 % wide, 78 % high, centered, with a notch at the bottom of
    // 22 % of the height. Proportions measured against `bookmark`.
    let bb = w * 0.60, bh = h * 0.78
    let x0 = (w - bb) / 2, y0 = (h - bh) / 2
    let notch = bh * 0.22
    let r = stroke * 0.9

    cairo_new_path(cr)
    cairo_move_to(cr, x0, y0 + r)
    cairo_arc(cr, x0 + r, y0 + r, r, Double.pi, 1.5 * Double.pi)
    cairo_line_to(cr, x0 + bb - r, y0)
    cairo_arc(cr, x0 + bb - r, y0 + r, r, 1.5 * Double.pi, 2 * Double.pi)
    cairo_line_to(cr, x0 + bb, y0 + bh)
    cairo_line_to(cr, x0 + bb / 2, y0 + bh - notch)
    cairo_line_to(cr, x0, y0 + bh)
    cairo_close_path(cr)

    // **Active means accent on the symbol:** the action button stays on `area`,
    // only the symbol changes, #50D5DA.
    if z.dark { cairo_set_source_rgba(cr, Theme.accentRGB.0, Theme.accentRGB.1, Theme.accentRGB.2, 1) }
    else        { cairo_set_source_rgba(cr, Theme.whiteRGB.0, Theme.whiteRGB.1, Theme.whiteRGB.2, 1) }
    if z.filled {
        cairo_fill(cr)
    } else {
        cairo_set_line_width(cr, stroke)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        cairo_stroke(cr)
    }
}

/// **The filter symbol: three lines, shorter toward the bottom.**
///
/// The Mac uses `line.3.horizontal.decrease` for the library filter button.
/// Breeze has a funnel (`view-filter-symbolic`), Adwaita nothing, and Windows
/// only has Adwaita. So it is drawn, like the four symbols before.
///
/// **The color comes from the style sheet**, not from the symbol: the button
/// switches from `schriftLeise` to `font` when opened, and
/// `gtk_widget_get_color` reads exactly the tone the style sheet currently gives
/// the surface.
final class FilterCharacter: @unchecked Sendable {
    fileprivate var lives = true
    let display: Widget

    init(mass: Int32 = 12) {
        let inputField: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(inputField, "swiftly-blank")
        gtk_widget_add_css_class(inputField, "swiftly-malzeichen")
        gtk_drawing_area_set_content_width(asCharacter(inputField), mass)
        gtk_drawing_area_set_content_height(asCharacter(inputField), mass)
        gtk_widget_set_valign(inputField, GTK_ALIGN_CENTER)
        display = inputField!
        gtk_drawing_area_set_draw_func(asCharacter(inputField), filterDraw,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        signal(inputField, "destroy") { self.lives = false }
    }
}

nonisolated(unsafe) private let filterDraw: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { area, cr, width, height, data in
    guard let cr, let data else { return }
    let z = Unmanaged<FilterCharacter>.fromOpaque(data).takeUnretainedValue()
    guard z.lives else { return }
    var color = GdkRGBA()
    gtk_widget_get_color(z.display, &color)
    cairo_set_source_rgba(cr, Double(color.red), Double(color.green),
                          Double(color.blue), Double(color.alpha))
    let w = Double(width), h = Double(height)
    let stroke = max(w * 0.14, 1.4)
    cairo_set_line_width(cr, stroke)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    for (i, share) in [1.0, 0.64, 0.28].enumerated() {
        let y = h * (0.22 + 0.28 * Double(i))
        let length = (w - stroke) * share
        cairo_move_to(cr, (w - length) / 2, y)
        cairo_line_to(cr, (w + length) / 2, y)
    }
    cairo_stroke(cr)
}
