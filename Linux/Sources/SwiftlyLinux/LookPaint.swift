import CGtk
import Foundation
import JellyfinKit

/// **The drawn pieces of the supporter screens**: the look icons, the heart, the lock, the
/// cross, the check and the mini phones of the purchase page.
///
/// The Apple versions take these from SF Symbols and the asset catalog. GTK has neither,
/// and the icon theme of a desktop has no `heart.fill`, so they are painted with cairo in
/// the same proportions. The look icons are the very PNGs of the Mac asset catalog
/// (`Resources/look-*.png`, `fan-*.png`), drawn into a rounded square like `LookTile`.

// MARK: - A drawing area with a closure

/// Holds the draw closure of one drawing area; released by GTK with the area.
final class LookPainter {
    let draw: (Widget, OpaquePointer, Double, Double) -> Void
    init(_ draw: @escaping (Widget, OpaquePointer, Double, Double) -> Void) { self.draw = draw }
}

nonisolated(unsafe) private let painterDraw: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { area, cr, width, height, data in
    guard let area, let cr, let data else { return }
    let painter = Unmanaged<LookPainter>.fromOpaque(data).takeUnretainedValue()
    painter.draw(UnsafeMutableRawPointer(area).assumingMemoryBound(to: GtkWidget.self), cr, Double(width), Double(height))
}

nonisolated(unsafe) private let painterRelease: @convention(c) (gpointer?) -> Void = { data in
    guard let data else { return }
    Unmanaged<LookPainter>.fromOpaque(data).release()
}

/// Redraws an animated area on every frame while it is mapped.
nonisolated(unsafe) private let painterTick: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { widget, _, _ in
    guard let widget else { return 0 }
    gtk_widget_queue_draw(widget)
    return 1
}

/// A drawing area of a fixed size. `animated` redraws it every frame (the bobbing icons).
func paint(width: Int, height: Int, animated: Bool = false,
           _ draw: @escaping (Widget, OpaquePointer, Double, Double) -> Void) -> Widget! {
    let area: Widget! = gtk_drawing_area_new()
    gtk_drawing_area_set_content_width(asCharacter(area), Int32(width))
    gtk_drawing_area_set_content_height(asCharacter(area), Int32(height))
    gtk_widget_set_hexpand(area, 0)
    gtk_widget_set_vexpand(area, 0)
    gtk_widget_set_can_target(area, 0)
    let painter = Unmanaged.passRetained(LookPainter(draw)).toOpaque()
    gtk_drawing_area_set_draw_func(asCharacter(area), painterDraw, painter, painterRelease)
    if animated, LookArt.moves {
        _ = gtk_widget_add_tick_callback(area, painterTick, nil, nil)
    }
    return area
}

// MARK: - Shapes and pictures

enum LookArt {

    /// GTK's own switch for animations (off when the desktop asks for reduced motion).
    static var moves: Bool { !motionReduced() }

    /// Seconds since some fixed start, for the animations.
    static var now: Double { Double(g_get_monotonic_time()) / 1_000_000 }

    /// The colour the style sheet gives this widget (`color:`), so hover and the look
    /// change it like any label.
    static func color(of widget: Widget) -> (Double, Double, Double, Double) {
        var color = GdkRGBA()
        gtk_widget_get_color(widget, &color)
        return (Double(color.red), Double(color.green), Double(color.blue), Double(color.alpha))
    }

    static func rounded(_ cr: OpaquePointer, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) {
        let r = min(r, w / 2, h / 2)
        cairo_new_sub_path(cr)
        cairo_arc(cr, x + w - r, y + r, r, -.pi / 2, 0)
        cairo_arc(cr, x + w - r, y + h - r, r, 0, .pi / 2)
        cairo_arc(cr, x + r, y + h - r, r, .pi / 2, .pi)
        cairo_arc(cr, x + r, y + r, r, .pi, 3 * .pi / 2)
        cairo_close_path(cr)
    }

    nonisolated(unsafe) private static var pictures: [String: OpaquePointer] = [:]

    /// A PNG from the resources, loaded once.
    static func picture(_ name: String) -> OpaquePointer? {
        if let known = pictures[name] { return known }
        guard let path = Bundle.module.path(forResource: name, ofType: "png"),
              let surface = cairo_image_surface_create_from_png(path),
              cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS else { return nil }
        pictures[name] = surface
        return surface
    }

    /// The file name of a look's icon (`look-neonnight`).
    static func iconName(_ look: Look) -> String { "look-" + look.id.lowercased() }

    /// **`LookTile`**: the icon in a rounded square (corner 22.5 % of the side) with a thin
    /// light edge. `x`, `y` is the top left corner.
    static func tile(_ cr: OpaquePointer, _ name: String, x: Double, y: Double, size: Double,
                     corner: Double? = nil, edge: Bool = true) {
        let r = corner ?? size * 0.225
        cairo_save(cr)
        rounded(cr, x, y, size, size, r)
        cairo_clip(cr)
        if let surface = picture(name) {
            let side = Double(cairo_image_surface_get_width(surface))
            cairo_translate(cr, x, y)
            cairo_scale(cr, size / side, size / side)
            cairo_set_source_surface(cr, surface, 0, 0)
            cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD)
            cairo_paint(cr)
        } else {
            cairo_set_source_rgb(cr, 0.19, 0.19, 0.19)
            cairo_paint(cr)
        }
        cairo_restore(cr)
        if edge {
            rounded(cr, x + 0.5, y + 0.5, size - 1, size - 1, r - 0.5)
            cairo_set_source_rgba(cr, 1, 1, 1, 0.08)
            cairo_set_line_width(cr, 1)
            cairo_stroke(cr)
        }
    }

    /// A soft shadow under a rounded square: a few widening, fading layers (cairo has no
    /// blur). `radius` and `y` as in SwiftUI's `.shadow`.
    static func shadow(_ cr: OpaquePointer, x: Double, y: Double, w: Double, h: Double, corner: Double,
                       opacity: Double, radius: Double, drop: Double) {
        let steps = 6
        for step in 0..<steps {
            let grow = radius * Double(step + 1) / Double(steps)
            rounded(cr, x - grow / 2, y + drop - grow / 2 + radius * 0.25, w + grow, h + grow, corner + grow / 2)
            cairo_set_source_rgba(cr, 0, 0, 0, opacity / Double(steps) * 0.9)
            cairo_fill(cr)
        }
    }

    /// **`heart.fill`**: two lobes and a point, in a square of `size` centred on `cx`, `cy`.
    /// The SF symbol is a little wider than tall (about 1.1 to 1).
    static func heart(_ cr: OpaquePointer, cx: Double, cy: Double, size: Double) {
        let w = size * 1.1
        let h = size
        let x = cx - w / 2
        let y = cy - h / 2
        cairo_new_path(cr)
        cairo_move_to(cr, cx, y + h)
        cairo_curve_to(cr, x + w * 0.38, y + h * 0.80, x, y + h * 0.58, x, y + h * 0.30)
        cairo_curve_to(cr, x, y + h * 0.11, x + w * 0.14, y, x + w * 0.27, y)
        cairo_curve_to(cr, x + w * 0.38, y, x + w * 0.46, y + h * 0.07, cx, y + h * 0.18)
        cairo_curve_to(cr, x + w * 0.54, y + h * 0.07, x + w * 0.62, y, x + w * 0.73, y)
        cairo_curve_to(cr, x + w * 0.86, y, x + w, y + h * 0.11, x + w, y + h * 0.30)
        cairo_curve_to(cr, x + w, y + h * 0.58, x + w * 0.62, y + h * 0.80, cx, y + h)
        cairo_close_path(cr)
    }

    /// **`lock.fill`** at `size` (the symbol's point size), centred.
    static func lock(_ cr: OpaquePointer, cx: Double, cy: Double, size: Double) {
        let bodyW = size * 0.86
        let bodyH = size * 0.62
        let top = cy - size * 0.05
        rounded(cr, cx - bodyW / 2, top, bodyW, bodyH, size * 0.14)
        cairo_fill(cr)
        cairo_set_line_width(cr, size * 0.17)
        cairo_new_path(cr)
        let r = size * 0.26
        cairo_move_to(cr, cx - r, top + 0.5)
        cairo_line_to(cr, cx - r, cy - size * 0.28)
        cairo_arc(cr, cx, cy - size * 0.28, r, .pi, 2 * .pi)
        cairo_line_to(cr, cx + r, top + 0.5)
        cairo_stroke(cr)
    }

    /// **`xmark`** in a square of `size`, stroked at the symbol's bold weight.
    static func cross(_ cr: OpaquePointer, cx: Double, cy: Double, size: Double) {
        let half = size * 0.36
        cairo_set_line_width(cr, size * 0.17)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_move_to(cr, cx - half, cy - half)
        cairo_line_to(cr, cx + half, cy + half)
        cairo_move_to(cr, cx + half, cy - half)
        cairo_line_to(cr, cx - half, cy + half)
        cairo_stroke(cr)
    }

    /// **`checkmark`** in a square of `size`.
    static func check(_ cr: OpaquePointer, cx: Double, cy: Double, size: Double) {
        cairo_set_line_width(cr, size * 0.2)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        cairo_move_to(cr, cx - size * 0.38, cy + size * 0.02)
        cairo_line_to(cr, cx - size * 0.1, cy + size * 0.3)
        cairo_line_to(cr, cx + size * 0.4, cy - size * 0.3)
        cairo_stroke(cr)
    }

    /// **`chevron.right`**, bold, `size` tall.
    static func chevron(_ cr: OpaquePointer, cx: Double, cy: Double, size: Double) {
        cairo_set_line_width(cr, size * 0.2)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        cairo_move_to(cr, cx - size * 0.18, cy - size * 0.38)
        cairo_line_to(cr, cx + size * 0.2, cy)
        cairo_line_to(cr, cx - size * 0.18, cy + size * 0.38)
        cairo_stroke(cr)
    }

    static func set(_ cr: OpaquePointer, _ color: LookColor, _ alpha: Double = 1) {
        cairo_set_source_rgba(cr, color.red, color.green, color.blue, alpha)
    }
}

// MARK: - Widgets

extension App {

    /// **`LookTile`** as a widget: the look's icon at `size`.
    func lookTile(_ look: Look, size: Int) -> Widget! {
        let name = LookArt.iconName(look)
        let tile = paint(width: size, height: size) { _, cr, w, _ in
            LookArt.tile(cr, name, x: 0, y: 0, size: w)
        }
        gtk_widget_set_halign(tile, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(tile, GTK_ALIGN_CENTER)
        return tile
    }
}

/// A painted symbol in the colour the style sheet gives it (`color:` on `style`).
func symbolPaint(_ kind: SymbolKind, size: Int, box: Int? = nil, style: String) -> Widget! {
    let side = box ?? size
    let area = paint(width: side, height: side) { widget, cr, w, h in
        let c = LookArt.color(of: widget)
        cairo_set_source_rgba(cr, c.0, c.1, c.2, c.3)
        let s = Double(size)
        switch kind {
        case .heart:
            LookArt.heart(cr, cx: w / 2, cy: h / 2, size: s * 0.88)
            cairo_fill(cr)
        case .lock: LookArt.lock(cr, cx: w / 2, cy: h / 2, size: s)
        case .cross: LookArt.cross(cr, cx: w / 2, cy: h / 2, size: s)
        case .check: LookArt.check(cr, cx: w / 2, cy: h / 2, size: s)
        case .chevron: LookArt.chevron(cr, cx: w / 2, cy: h / 2, size: s)
        }
    }
    gtk_widget_add_css_class(area, style)
    gtk_widget_set_halign(area, GTK_ALIGN_CENTER)
    gtk_widget_set_valign(area, GTK_ALIGN_CENTER)
    return area
}

enum SymbolKind { case heart, lock, cross, check, chevron }

// MARK: - The mini phones of the purchase page

/// **`LookMiniPhone`, 104 × 208**: the home page in a look's colours, drawn. Wordmark,
/// heart, "Weiterschauen", a wide poster with progress, two posters, the bar.
enum MiniPhone {

    static func draw(_ cr: OpaquePointer, palette: LookPalette, x: Double, y: Double) {
        let w = 104.0, h = 208.0, r = 14.0
        LookArt.shadow(cr, x: x, y: y, w: w, h: h, corner: r, opacity: 0.5, radius: 20, drop: 18)
        cairo_save(cr)
        LookArt.rounded(cr, x, y, w, h, r)
        cairo_clip(cr)
        // The page and its glow.
        cairo_set_source_rgb(cr, 16 / 255, 16 / 255, 16 / 255)
        cairo_paint(cr)
        let accent = palette.accent.main
        let glow = cairo_pattern_create_radial(x + w / 2, y, 0, x + w / 2, y, w * 0.75)!
        cairo_pattern_add_color_stop_rgba(glow, 0, accent.red, accent.green, accent.blue, 0.34)
        cairo_pattern_add_color_stop_rgba(glow, 1, accent.red, accent.green, accent.blue, 0)
        cairo_save(cr)
        cairo_rectangle(cr, x, y, w, 64)
        cairo_clip(cr)
        cairo_translate(cr, x + w / 2, y)
        cairo_scale(cr, 1, 64 / (w * 0.75))
        cairo_translate(cr, -(x + w / 2), -y)
        cairo_set_source(cr, glow)
        cairo_paint(cr)
        cairo_restore(cr)
        cairo_pattern_destroy(glow)

        // Wordmark: the word in white, the play mark in the look's gradient.
        cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
        cairo_set_font_size(cr, 11)
        cairo_set_source_rgb(cr, 1, 1, 1)
        cairo_move_to(cr, x + 9, y + 26)
        cairo_show_text(cr, "swiftly")
        var extents = cairo_text_extents_t()
        cairo_text_extents(cr, "swiftly", &extents)
        let markX = x + 9 + extents.x_advance + 2
        let tones = palette.logoGradient
        let mark = cairo_pattern_create_linear(markX, y + 18, markX + 7, y + 26)!
        for (index, tone) in tones.enumerated() {
            let offset = tones.count > 1 ? Double(index) / Double(tones.count - 1) : 0
            cairo_pattern_add_color_stop_rgb(mark, offset, tone.red, tone.green, tone.blue)
        }
        cairo_move_to(cr, markX, y + 18)
        cairo_line_to(cr, markX + 7, y + 22)
        cairo_line_to(cr, markX, y + 26)
        cairo_close_path(cr)
        cairo_set_source(cr, mark)
        cairo_fill(cr)
        cairo_pattern_destroy(mark)

        // Heart top right.
        cairo_set_source_rgb(cr, 1, 1, 1)
        LookArt.heart(cr, cx: x + w - 9 - 5, cy: y + 22, size: 8.5)
        cairo_fill(cr)

        // "Weiterschauen".
        cairo_set_font_size(cr, 7.5)
        cairo_move_to(cr, x + 9, y + 42)
        cairo_show_text(cr, translated("Weiterschauen"))

        poster(cr, x: x + 9, y: y + 47, w: 86, h: 48, r: 5, progress: 0.44, accent: accent)
        poster(cr, x: x + 9, y: y + 104, w: 40, h: 60, r: 4)
        poster(cr, x: x + 55, y: y + 104, w: 40, h: 60, r: 4)

        // The bar.
        cairo_set_source_rgba(cr, 1, 1, 1, 0.07)
        cairo_rectangle(cr, x, y + h - 24, w, 1)
        cairo_fill(cr)
        for index in 0..<4 {
            let slot = w / 4
            let cx = x + slot * Double(index) + slot / 2
            if index == 0 { LookArt.set(cr, accent) } else { cairo_set_source_rgb(cr, 0.333, 0.333, 0.333) }
            LookArt.rounded(cr, cx - 4, y + h - 16, 8, 8, 2.5)
            cairo_fill(cr)
        }
        cairo_restore(cr)

        LookArt.rounded(cr, x + 0.5, y + 0.5, w - 1, h - 1, r - 0.5)
        cairo_set_source_rgba(cr, 1, 1, 1, 0.1)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
    }

    private static func poster(_ cr: OpaquePointer, x: Double, y: Double, w: Double, h: Double, r: Double,
                               progress: Double? = nil, accent: LookColor? = nil) {
        cairo_save(cr)
        LookArt.rounded(cr, x, y, w, h, r)
        cairo_clip(cr)
        let fill = cairo_pattern_create_linear(x, y, x, y + h)!
        cairo_pattern_add_color_stop_rgb(fill, 0, 0x30 / 255, 0x30 / 255, 0x30 / 255)
        cairo_pattern_add_color_stop_rgb(fill, 1, 0x26 / 255, 0x26 / 255, 0x26 / 255)
        cairo_set_source(cr, fill)
        cairo_paint(cr)
        cairo_pattern_destroy(fill)
        if let progress, let accent {
            cairo_set_source_rgba(cr, 1, 1, 1, 0.3)
            cairo_rectangle(cr, x, y + h - 2.5, w, 2.5)
            cairo_fill(cr)
            LookArt.set(cr, accent)
            cairo_rectangle(cr, x, y + h - 2.5, w * progress, 2.5)
            cairo_fill(cr)
        }
        cairo_restore(cr)
    }
}

/// **`LooksHero`**: three phones, the outer two turned by 8 degrees, bobbing, fading out
/// towards the pill below them. Width 480 (the sheet), height 252 minus the pill.
func looksHeroPaint(width: Int) -> Widget! {
    let phones: [(selection: LookSelection, x: Double, y: Double, turn: Double, delay: Double)] = [
        (LookSelection(lookID: Look.original.id, glow: .soft), -104, 34, -8, 0),
        (LookSelection(lookID: Look.neonNight.id, accentID: LookAccent.coral.id), 104, 34, 8, 0.8),
        (LookSelection(lookID: Look.neonNight.id), 0, 16, 0, 0.4),
    ]
    let height = 252
    return paint(width: width, height: height, animated: true) { _, cr, w, h in
        // Drawn into a group so the fade below can be a mask over all three.
        cairo_push_group(cr)
        let moving = LookArt.moves
        for phone in phones {
            // easeInOut over 2 s, up 6 and back.
            let t = moving ? (LookArt.now - phone.delay) / 2 : 0
            let phase = t - floor(t / 2) * 2
            let half = phase < 1 ? phase : 2 - phase
            let eased = 0.5 - cos(half * .pi) / 2
            let lift = -6 * eased
            let cx = w / 2 + phone.x
            let top = phone.y + lift
            cairo_save(cr)
            cairo_translate(cr, cx, top + 104)
            cairo_rotate(cr, phone.turn * .pi / 180)
            MiniPhone.draw(cr, palette: phone.selection.palette, x: -52, y: -104)
            cairo_restore(cr)
        }
        let content = cairo_pop_group(cr)!
        // Opaque to 62 %, gone at 90 % (measured from 40 above the top, as on Apple).
        let total = h + 40
        let fade = cairo_pattern_create_linear(0, -40, 0, h)!
        cairo_pattern_add_color_stop_rgba(fade, 0, 0, 0, 0, 1)
        cairo_pattern_add_color_stop_rgba(fade, 0.62, 0, 0, 0, 1)
        cairo_pattern_add_color_stop_rgba(fade, 0.9, 0, 0, 0, 0)
        _ = total
        cairo_set_source(cr, content)
        cairo_mask(cr, fade)
        cairo_pattern_destroy(fade)
        cairo_pattern_destroy(content)
    }
}

/// **The fan of the teaser card**: five icons, the middle one larger with a white ring that
/// comes and goes, each bobbing 3 up and down. 104 high.
func iconFanPaint() -> Widget! {
    let icons: [(name: String, turn: Double, drop: Double, size: Double, delay: Double)] = [
        ("fan-sunset", -10, 12, 60, 0),
        ("look-neonnight", -4, 4, 60, 0.3),
        ("look-original", 0, 0, 70, 0.6),
        ("fan-aurora", 4, 4, 60, 0.9),
        ("fan-gold", 10, 12, 60, 1.2),
    ]
    let width = Int(icons.reduce(0) { $0 + $1.size } - 10 * Double(icons.count - 1)) + 40
    let area = paint(width: width, height: 104, animated: true) { _, cr, w, _ in
        let moving = LookArt.moves
        let total = icons.reduce(0) { $0 + $1.size } - 10 * Double(icons.count - 1)
        var x = (w - total) / 2
        var placed = [(Int, Double)]()
        for (index, icon) in icons.enumerated() {
            placed.append((index, x))
            x += icon.size - 10
        }
        // The middle one on top.
        for (index, left) in placed.sorted(by: { ($0.0 == 2 ? 1 : 0) < ($1.0 == 2 ? 1 : 0) }) {
            let icon = icons[index]
            let t = moving ? (LookArt.now - icon.delay) / 1.6 : 0
            let phase = t - floor(t / 2) * 2
            let half = phase < 1 ? phase : 2 - phase
            let lift = -3 * (0.5 - cos(half * .pi) / 2)
            let s = icon.size
            let top = 22 + icon.drop + lift
            cairo_save(cr)
            cairo_translate(cr, left + s / 2, top + s / 2)
            cairo_rotate(cr, icon.turn * .pi / 180)
            LookArt.shadow(cr, x: -s / 2, y: -s / 2, w: s, h: s, corner: 14, opacity: 0.25, radius: 6, drop: 4)
            LookArt.tile(cr, icon.name, x: -s / 2, y: -s / 2, size: s, corner: 14, edge: false)
            if index == 2, moving {
                // pick: off, on from 70 to 92 percent of a 4.8 s cycle (with 0.38 s fades).
                let cycle = (LookArt.now - icon.delay).truncatingRemainder(dividingBy: 4.8)
                let ring: Double
                switch cycle {
                case ..<2.98: ring = 0
                case ..<3.36: ring = (cycle - 2.98) / 0.38
                case ..<4.42: ring = 1
                default: ring = max(0, 1 - (cycle - 4.42) / 0.38)
                }
                if ring > 0 {
                    LookArt.rounded(cr, -s / 2 - 3, -s / 2 - 3, s + 6, s + 6, 18 - 1)
                    cairo_set_source_rgba(cr, 1, 1, 1, ring)
                    cairo_set_line_width(cr, 2)
                    cairo_stroke(cr)
                }
            }
            cairo_restore(cr)
        }
    }
    gtk_widget_set_halign(area, GTK_ALIGN_CENTER)
    return area
}
