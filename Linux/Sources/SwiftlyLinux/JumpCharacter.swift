import CGtk
import Foundation

/// **The circular arrow with a number, drawn rather than looked up.**
///
/// The Mac uses `gobackward.10` and `goforward.30` from SF Symbols: an open
/// circle with an arrowhead at the top and the skip distance in the middle.
/// Adwaita has nothing like it; the closest icons (`media-seek-backward`) are
/// two triangles and say nothing about the distance.
///
/// That matters because **the distance is a setting**; ten back and thirty
/// forward are only the defaults. A fixed icon could not show it. So it is
/// drawn, which keeps every number correct, and both directions are the same
/// image, mirrored once.
final class JumpCharacter: @unchecked Sendable {
    /// **Is the drawing area still alive?** See the `destroy` job in the
    /// initializer.
    fileprivate var lives = true

    fileprivate let back: Bool
    fileprivate var figure: Int
    fileprivate let mass: Double
    let display: Widget

    init(back: Bool, figure: Int, mass: Double = 30) {
        self.back = back
        self.figure = figure
        self.mass = mass
        let inputField: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(inputField, "swiftly-blank")
        gtk_drawing_area_set_content_width(asCharacter(inputField), Int32(mass))
        gtk_drawing_area_set_content_height(asCharacter(inputField), Int32(mass))
        display = inputField!
        gtk_drawing_area_set_draw_func(asCharacter(inputField), jumpDraw,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        // **The drawing area holds the symbol, not `App`.**
        //
        // The draw callback above gets `self` *unretained*. It used to be held only by
        // a field in `App`, which is overwritten on **every** player start because
        // `playerPageBuild` rebuilds the controls each time. The old symbol dies the
        // moment the new one is created, but its drawing area still hangs in the old
        // player page, which slides down for 380 ms and keeps drawing. Starting the
        // next movie in that window draws into freed memory.
        //
        // Same bug as in ``Backdrop`` and ``StartAnimation``. The strong capture in
        // the job keeps the symbol alive while its area lives; the guard in `malen`
        // catches the rest.
        signal(inputField, "destroy") { self.lives = false }
    }

    /// How far the symbol is currently deflected. The Mac uses
    /// `.symbolEffect(.bounce)` for this: "plays once and returns to rest by
    /// itself". A skip without feedback feels as if the button had not registered.
    fileprivate var impulse: Double = 0

    /// One deflection. Counts **every** press, even the tenth in a row.
    func nudge() {
        // No deflection with reduced motion, like the Mac's `.symbolEffect(.bounce)`,
        // which stays still then.
        guard !motionReduced() else { return }
        runningCount(on: display, duration: 0.34) { [weak self] e in
            guard let self else { return }
            self.impulse = sin(Double.pi * e)
            gtk_widget_queue_draw(self.display)
        } done: { [weak self] in
            guard let self else { return }
            self.impulse = 0
            gtk_widget_queue_draw(self.display)
        }
    }

    /// The distance can change in the settings while the player is open. Then it
    /// is redrawn, not rebuilt.
    func setNumber(_ new: Int) {
        guard new != figure else { return }
        figure = new
        gtk_widget_queue_draw(display)
    }
}

/// Draws the circular arrow. The draw function supplies width and height;
/// again a custom shape, again a custom callback.
nonisolated(unsafe) private let jumpDraw: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, width, height, data in
    guard let cr, let data else { return }
    let z = Unmanaged<JumpCharacter>.fromOpaque(data).takeUnretainedValue()
    guard z.lives else { return }

    let cx = Double(width) / 2, cy = Double(height) / 2
    // Radius, stroke and arrowhead scale with the symbol so large and small ones
    // look the same. The proportions were measured against `gobackward.10`.
    let r = z.mass * 0.34
    let stroke = max(z.mass * 0.068, 1.2)
    let arc = Double.pi / 180
    let spot = -76 * arc

    // **The deflection covers the whole symbol, number included.**
    // Hence a guard around everything, not only the arc.
    cairo_save(cr)
    if z.impulse > 0.001 {
        let f = 1 + 0.18 * z.impulse
        cairo_translate(cr, cx, cy)
        cairo_scale(cr, f, f)
        cairo_translate(cr, -cx, -cy)
    }

    cairo_save(cr)
    // **Back is forward, mirrored.** One image, two directions, so one cannot
    // drift away from the other.
    if z.back {
        cairo_translate(cr, cx, 0)
        cairo_scale(cr, -1, 1)
        cairo_translate(cr, -cx, 0)
    }

    cairo_set_source_rgba(cr, 1, 1, 1, 1)
    cairo_set_line_width(cr, stroke)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)

    // The circle with a gap at the top: from −76° clockwise to 250°.
    cairo_new_path(cr)
    cairo_arc(cr, cx, cy, r, spot, 250 * arc)
    cairo_stroke(cr)

    // The arrowhead sits at the end of the gap and is **rotated along the
    // direction of travel**; unrotated it stood sideways and looked like a flag.
    let tip = z.mass * 0.088
    cairo_save(cr)
    cairo_translate(cr, cx + r * cos(spot), cy + r * sin(spot))
    cairo_rotate(cr, spot + 90 * arc)
    cairo_new_path(cr)
    cairo_move_to(cr, tip * 1.5, 0)
    cairo_line_to(cr, -tip * 0.5, -tip * 1.05)
    cairo_line_to(cr, -tip * 0.5, tip * 1.05)
    cairo_close_path(cr)
    cairo_fill(cr)
    cairo_restore(cr)
    cairo_restore(cr)

    // **The color must be set again.** `cairo_restore` undoes not only the
    // mirroring but all painting state, including the source. Without this line the
    // number took the color from before `save`: invisible on the background in a
    // test run, and in the app just whatever GTK had set last.
    let text = "\(z.figure)"
    cairo_set_source_rgba(cr, 1, 1, 1, 1)
    cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    cairo_set_font_size(cr, z.mass * 0.34)
    var mass = cairo_text_extents_t()
    cairo_text_extents(cr, text, &mass)
    cairo_move_to(cr, cx - mass.width / 2 - mass.x_bearing,
                      cy - mass.height / 2 - mass.y_bearing)
    cairo_show_text(cr, text)
    cairo_restore(cr)
}

/// **Play and pause, also drawn, with a transition.**
///
/// Adwaita's `media-playback-pause-symbolic` is a clunky double bar at 48
/// points; the Mac uses `pause.fill`, two slim bars with round ends, plus
/// `.contentTransition(.symbolEffect(.replace.offUp))`.
///
/// The transition is not decoration: the button must flip at the same moment
/// the sound stops, otherwise the whole player feels sluggish. A change
/// without a transition feels choppy; what is missing is not time but motion.
final class PlayMarker: @unchecked Sendable {
    /// **Is the drawing area still alive?** See ``Sprungzeichen``.
    fileprivate var lives = true
    fileprivate var pause: Bool
    /// 0 … 1 over the transition. At 1 the new symbol is shown.
    fileprivate var run: Double = 1
    fileprivate let mass: Double
    let display: Widget

    init(pause: Bool, mass: Double = 48) {
        self.pause = pause
        self.mass = mass
        let inputField: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(inputField, "swiftly-blank")
        gtk_drawing_area_set_content_width(asCharacter(inputField), Int32(mass))
        gtk_drawing_area_set_content_height(asCharacter(inputField), Int32(mass))
        display = inputField!
        gtk_drawing_area_set_draw_func(asCharacter(inputField), playDraw,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        // Same retention as ``Sprungzeichen``; see there for why.
        signal(inputField, "destroy") { self.lives = false }
    }

    func setDown(_ new: Bool) {
        guard new != pause else { return }
        pause = new
        run = 0
        // **90 ms and no movement.** The old symbol used to travel up and out while
        // the new one came in from below. With two such different shapes that looked
        // messy and took too long. A short cross-fade reads as a switch, not as
        // motion.
        runningCount(on: display, duration: 0.09) { [weak self] e in
            self?.run = e
            self.map { gtk_widget_queue_draw($0.display) }
        } done: { [weak self] in
            self?.run = 1
            self.map { gtk_widget_queue_draw($0.display) }
        }
    }
}

/// A bar with round ends; the building block of the pause symbol.
private func stab(_ cr: OpaquePointer, _ x: Double, _ y: Double,
                  _ b: Double, _ h: Double) {
    let r = b / 2
    cairo_new_path(cr)
    cairo_arc(cr, x + r, y + r, r, Double.pi, 3 * Double.pi / 2)
    cairo_arc(cr, x + b - r, y + r, r, 3 * Double.pi / 2, 2 * Double.pi)
    cairo_arc(cr, x + b - r, y + h - r, r, 0, Double.pi / 2)
    cairo_arc(cr, x + r, y + h - r, r, Double.pi / 2, Double.pi)
    cairo_close_path(cr)
    cairo_fill(cr)
}

nonisolated(unsafe) private let playDraw: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, width, height, data in
    guard let cr, let data else { return }
    let z = Unmanaged<PlayMarker>.fromOpaque(data).takeUnretainedValue()
    guard z.lives else { return }
    let cx = Double(width) / 2, cy = Double(height) / 2
    let m = z.mass

    /// Draws one of the two symbols, with opacity and an upward offset.
    func symbolText(_ pause: Bool, _ coverage: Double, _ offset: Double) {
        guard coverage > 0.01 else { return }
        cairo_save(cr)
        cairo_translate(cr, 0, offset)
        cairo_set_source_rgba(cr, 1, 1, 1, coverage)
        if pause {
            // Two bars: each 0.155 wide, 0.52 high, 0.105 apart.
            let b = m * 0.155, h = m * 0.52, gap = m * 0.105
            stab(cr, cx - gap / 2 - b, cy - h / 2, b, h)
            stab(cr, cx + gap / 2, cy - h / 2, b, h)
        } else {
            // A triangle with rounded corners: the same path filled **and** stroked with
            // round joins, so the tips are round without computing each one.
            let r = m * 0.26, corner = m * 0.055
            cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
            cairo_set_line_width(cr, corner * 2)
            cairo_new_path(cr)
            // Shifted slightly right: a triangle's centroid lies left of its center,
            // otherwise it would look off-center.
            let vx = cx + m * 0.045
            cairo_move_to(cr, vx + r, cy)
            cairo_line_to(cr, vx - r * 0.62, cy - r * 0.9)
            cairo_line_to(cr, vx - r * 0.62, cy + r * 0.9)
            cairo_close_path(cr)
            cairo_fill_preserve(cr)
            cairo_stroke(cr)
        }
        cairo_restore(cr)
    }

    let e = min(max(z.run, 0), 1)
    symbolText(!z.pause, 1 - e, 0)
    symbolText(z.pause, e, 0)
}
