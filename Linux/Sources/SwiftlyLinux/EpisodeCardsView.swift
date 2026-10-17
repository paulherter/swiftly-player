import CGtk
import Foundation
import JellyfinKit

/// **The next episode as a card at the bottom right**, variant C, modeled on
/// `Sources/iOS/EpisodeCardsView.swift`. Timings, springs and sizes live in
/// ``EpisodeCard`` in the package; this is only the desktop drawing.
///
/// Episode thumbnail with the countdown ring and play symbol on it, a round X
/// at the corner; below it "S6 • F11 … in 7 s" and the title. Click or Enter
/// plays the episode, X or Escape cancels (the credits keep playing, and no
/// auto-advance happens at end of file).
///
/// **Not available here, and why** (input method):
/// - **Swipe away**: a finger gesture; with a mouse there is X and Escape.
/// - **Zoom of the card to the full frame** on start. GTK cannot grow a widget
///   over the running libVLC picture without re-laying it out every frame;
///   the card fades out instead, and the new episode starts under the loading
///   veil like any other switch.
///
/// It enters from the right at 94 % size (``Folgenkarte/versatz``,
/// ``Folgenkarte/startmass``) via the stylesheet, whose transitions follow
/// "reduce motion" automatically (`gtk-enable-animations`).
final class EpisodeCardsView: @unchecked Sendable {
    /// The whole card with its rows; an overlay above the picture.
    private(set) var wrapper: Widget!
    private var button: Widget!
    private var image: Widget!
    private var ring: Widget!
    private var abbreviation: Widget!
    private var remainingRow: Widget!
    private var title: Widget!
    private var episodeID: String?
    private var imageAddress: URL?
    private(set) var present = false
    fileprivate var clock: FillClock?
    private var tick: guint = 0
    fileprivate var lives = true

    private let metrics = EpisodeCard.iPhone
    /// Card width, ``Folgenkarte/breite(_:safeWidth:gross:)``: the desktop
    /// uses the large size like the iPad, at most 30 % of the window width.
    private(set) var width: Int32 = 300

    init(fire: @escaping () -> Void, cancel: @escaping () -> Void) {
        let outer = stack(GTK_ORIENTATION_VERTICAL, spacing: Int32(metrics.spacing))
        gtk_widget_add_css_class(outer, "swiftly-folgenkarte")
        gtk_widget_add_css_class(outer, "swiftly-folgenkarte-weg")
        gtk_widget_set_halign(outer, GTK_ALIGN_END)
        gtk_widget_set_valign(outer, GTK_ALIGN_END)
        gtk_widget_set_can_target(outer, 0)
        wrapper = outer

        // The card: a button with image and ring, the X sits on top.
        let corner: Widget! = gtk_overlay_new()
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-kartenbild")
        gtk_widget_set_overflow(button, GTK_OVERFLOW_HIDDEN)
        let inner: Widget! = gtk_overlay_new()
        let image: Widget! = gtk_picture_new()
        gtk_picture_set_content_fit(OpaquePointer(image), GTK_CONTENT_FIT_COVER)
        gtk_picture_set_can_shrink(OpaquePointer(image), 1)
        gtk_overlay_set_child(OpaquePointer(inner), image)
        let ring: Widget! = gtk_drawing_area_new()
        gtk_drawing_area_set_content_width(asCharacter(ring), Int32(metrics.ring))
        gtk_drawing_area_set_content_height(asCharacter(ring), Int32(metrics.ring))
        gtk_widget_set_halign(ring, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(ring, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(ring, 0)
        gtk_drawing_area_set_draw_func(asCharacter(ring), paintRing,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        gtk_overlay_add_overlay(OpaquePointer(inner), ring)
        gtk_button_set_child(asButton(button), inner)
        signal(button, "clicked", fire)
        gtk_overlay_set_child(OpaquePointer(corner), button)

        // The round X at the card corner (as on Max): card gone, countdown off,
        // credits keep playing.
        let toward: Widget! = gtk_button_new()
        gtk_widget_add_css_class(toward, "swiftly-kartenzu")
        let cross = PlayerCharacter("close", size: 11)
        gtk_button_set_child(asButton(toward), cross.display)
        gtk_widget_set_halign(toward, GTK_ALIGN_END)
        gtk_widget_set_valign(toward, GTK_ALIGN_START)
        caption(toward, translated("Karte schließen"))
        gtk_widget_set_tooltip_text(toward, translated("Karte schließen"))
        signal(toward, "clicked") {
            AppLog.writeOut("[Karte] × gedrückt")
            cancel()
        }
        gtk_overlay_add_overlay(OpaquePointer(corner), toward)
        append(outer, corner)

        // The two rows below.
        let rows = stack(GTK_ORIENTATION_VERTICAL, spacing: 3)
        gtk_widget_set_can_target(rows, 0)
        let top = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        abbreviation = label("", style: "swiftly-kartenklein")
        gtk_label_set_xalign(OpaquePointer(abbreviation), 0)
        gtk_widget_set_hexpand(abbreviation, 1)
        gtk_label_set_ellipsize(OpaquePointer(abbreviation), PANGO_ELLIPSIZE_END)
        append(top, abbreviation)
        remainingRow = label("", style: "swiftly-kartenklein")
        gtk_widget_add_css_class(remainingRow, "swiftly-tnum")
        append(top, remainingRow)
        append(rows, top)
        title = label("", style: "swiftly-kartentitel")
        gtk_label_set_xalign(OpaquePointer(title), 0)
        gtk_label_set_ellipsize(OpaquePointer(title), PANGO_ELLIPSIZE_END)
        gtk_label_set_single_line_mode(OpaquePointer(title), 1)
        append(rows, title)
        append(outer, rows)

        self.button = button
        self.image = image
        self.ring = ring
        gtk_widget_set_visible(outer, 0)

        // The overlay holds the object; after teardown nothing points to it.
        let itself = Unmanaged.passRetained(self)
        signal(outer, "destroy") {
            let k = itself.takeUnretainedValue()
            k.lives = false
            k.tick = 0
            k.wrapper = nil; k.button = nil; k.image = nil; k.ring = nil
            k.abbreviation = nil; k.remainingRow = nil; k.title = nil
            itself.release()
        }
    }

    /// Takes over the state: the episode, whether the card is shown, the
    /// countdown clock and the remaining seconds.
    func setDown(episode: Item?, image address: URL?, present new: Bool, clock newClock: FillClock?,
                rest: Int, windowWidthValue: Int32) {
        guard lives, wrapper != nil else { return }
        let b = Int32(EpisodeCard.width(metrics, safeWidth: Double(windowWidthValue), large: true)
            .rounded())
        if b > 0, b != width || gtk_widget_get_width(button) == 0 {
            width = b
            gtk_widget_set_size_request(button, b, b * 9 / 16)
            gtk_widget_set_size_request(wrapper, b, -1)
        }
        if let episode, episode.id != episodeID {
            episodeID = episode.id
            // From the package (`episodeCode`), no longer by hand: it was hardcoded as
            // "F", also in English, where it is "E".
            let k = episode.episodeCode ?? episode.name
            gtk_label_set_text(OpaquePointer(abbreviation), k)
            gtk_label_set_text(OpaquePointer(title), episode.name)
            caption(button, String(format: translated("Nächste Folge abspielen: %@"), k))
        }
        if address != imageAddress {
            imageAddress = address
            gtk_picture_set_paintable(OpaquePointer(image), nil)
            if let address {
                imageLoad(image, url: address, key: ImageKey.of(address), immediate: true)
            }
        }
        gtk_label_set_text(OpaquePointer(remainingRow), String(format: translated("in %lld s"), Int64(rest)))
        if new != present {
            present = new
            AppLog.writeOut("[Karte] \(new ? "herein" : "hinaus")")
            fflush(nil)
            if new {
                gtk_widget_set_visible(wrapper, 1)
                // First visible, then remove the class in the next frame; otherwise GTK
                // skips the transition.
                postDeadline(EpisodeCard.appearLag) { [weak self] in
                    guard let self, self.lives, self.present, let h = self.wrapper else { return }
                    gtk_widget_remove_css_class(h, "swiftly-folgenkarte-weg")
                }
            } else {
                gtk_widget_add_css_class(wrapper, "swiftly-folgenkarte-weg")
            }
            gtk_widget_set_can_target(wrapper, new ? 1 : 0)
        }
        clock = newClock
        if present, clock != nil {
            gtk_widget_queue_draw(ring)
            if tick == 0 {
                tick = gtk_widget_add_tick_callback(ring, ringTick,
                                                    Unmanaged.passUnretained(self).toOpaque(), nil)
            }
        } else if tick != 0 {
            gtk_widget_remove_tick_callback(ring, tick)
            tick = 0
        }
    }

    /// How far the card sits above the bottom edge: above the timeline while the
    /// controls are open.
    func bottom(_ spacing: Int32) {
        guard lives, let wrapper else { return }
        let before = Double(gtk_widget_get_margin_bottom(wrapper))
        guard Int32(before) != spacing else { return }
        gentle(on: wrapper, from: before, to: Double(spacing)) { [weak self] value in
            guard let self, self.lives, let h = self.wrapper else { return }
            gtk_widget_set_margin_bottom(h, Int32(value.rounded()))
        }
    }

    fileprivate func drawRing() {
        guard lives, let ring else { return }
        gtk_widget_queue_draw(ring)
    }

    fileprivate var share: Double { clock?.share() ?? 0 }
}

nonisolated(unsafe) private let ringTick: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, data in
    guard let data else { return 0 }
    Unmanaged<EpisodeCardsView>.fromOpaque(data).takeUnretainedValue().drawRing()
    return 1
}

/// Countdown ring with play symbol, copied from `CountdownRing` in
/// `Sources/Shared/EpisodeCardParts.swift`: black 50 %, track white 18 %,
/// fill in accent with round caps, stroke 3/56 of the diameter, the triangle
/// 30 % in size and shifted 3 % to the right.
nonisolated(unsafe) private let paintRing: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, width, height, data in
    guard let cr, let data else { return }
    let k = Unmanaged<EpisodeCardsView>.fromOpaque(data).takeUnretainedValue()
    guard k.lives else { return }
    let d = Double(min(width, height))
    let m = (x: Double(width) / 2, y: Double(height) / 2)
    let stroke = d * 3 / 56
    cairo_set_source_rgba(cr, 0, 0, 0, 0.5)
    cairo_arc(cr, m.x, m.y, d / 2, 0, 2 * .pi)
    cairo_fill(cr)
    let r = d / 2 - stroke
    cairo_set_line_width(cr, stroke)
    cairo_set_source_rgba(cr, 1, 1, 1, 0.18)
    cairo_arc(cr, m.x, m.y, r, 0, 2 * .pi)
    cairo_stroke(cr)
    let share = k.share
    if share > 0 {
        let a = Theme.accentRGB
        cairo_set_source_rgba(cr, a.0, a.1, a.2, 1)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_arc(cr, m.x, m.y, r, -.pi / 2, -.pi / 2 + 2 * .pi * share)
        cairo_stroke(cr)
    }
    // Play symbol: equilateral, 30 % of the diameter in height.
    let h = d * 0.3, w = h * 0.87
    let x0 = m.x - w / 2 + d * 0.03 + w * 0.08
    cairo_set_source_rgba(cr, 1, 1, 1, 1)
    cairo_move_to(cr, x0, m.y - h / 2)
    cairo_line_to(cr, x0 + w, m.y)
    cairo_line_to(cr, x0, m.y + h / 2)
    cairo_close_path(cr)
    cairo_fill(cr)
}
