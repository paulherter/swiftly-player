import CGtk
import Foundation

/// **Player volume**: speaker button first in the icon row; on hover a
/// horizontal slider unfolds to its left (Mac:
/// `Sources/macOS/VolumeSlider.swift`).
///
/// Sizes as there: compartment 0 → 96 in 0.18 s (ease-out), slider 88, track 4,
/// handle 12 only on hover or drag. **The handle stays fully inside the
/// track**: its travel ends one radius before each end, otherwise the edge
/// would clip it.
///
/// **The compartment is a drawing area whose width animates.** GTK does not
/// shrink a box below the minimum width of its children; a drawing area that
/// aligns its content to the right edge (at the speaker) is instead clipped by
/// its own width, so the slider slides out of the speaker.
///
/// **The percentage sits below the handle, in the same area:** on the Mac it
/// is below the compartment, but here that would need 14 pt more height and
/// shift the icon row. At 38 pt height it fits between handle and bottom edge.
final class VolumeSlider: @unchecked Sendable {
    static let compartmentWidth = 96.0
    static let sliderWidth = 88.0
    static let height = 38.0
    static let grip = 12.0

    let display: Widget
    private let inputField: Widget
    private let symbolText: PlayerCharacter

    /// 0 to 1.
    private(set) var value: Double
    /// A key (arrows, M) opened the slider briefly.
    private var short = false
    private var atop = false
    private(set) var pulls = false
    private var progress = 0.0
    private var number = 0
    private var startX = 0.0
    fileprivate var lives = true

    /// The value changed by dragging (continuously).
    var changed: ((Double) -> Void)?
    /// Dragging begins or ends.
    var drag: ((Bool) -> Void)?
    /// The wheel turns over slider or speaker: fraction from 0 to 1 with sign,
    /// **not rounded**.
    var wheelRotated: ((Double) -> Void)?

    init(value: Double, symbolText: PlayerCharacter, button: Widget) {
        self.value = min(max(value, 0), 1)
        self.symbolText = symbolText
        let wrapper = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_valign(wrapper, GTK_ALIGN_START)
        display = wrapper!

        let inputField: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(inputField, "swiftly-blank")
        gtk_drawing_area_set_content_width(asCharacter(inputField), 0)
        gtk_drawing_area_set_content_height(asCharacter(inputField), Int32(Self.height))
        gtk_widget_set_valign(inputField, GTK_ALIGN_START)
        gtk_widget_set_can_target(inputField, 0)
        self.inputField = inputField
        append(wrapper, inputField)
        append(wrapper, button)
        symbolUpdate()

        let itself = Unmanaged.passRetained(self)
        gtk_drawing_area_set_draw_func(asCharacter(inputField), sliderFieldDraw, itself.toOpaque(), nil)
        signal(inputField, "destroy") {
            itself.takeUnretainedValue().lives = false
            itself.release()
        }

        onPointer(wrapper, inward: { [weak self] in self?.placeOver(true) },
                  out: { [weak self] in self?.placeOver(false) })

        // The drag gesture covers the whole shell but only accepts clicks inside
        // the compartment; the speaker is a button and keeps its click.
        let gesture = gtk_gesture_drag_new()
        gtk_gesture_single_set_button(gesture, 1)
        let data = itself.toOpaque()
        g_signal_connect_data(UnsafeMutableRawPointer(gesture), "drag-begin",
                              unsafeBitCast(sliderPullStart, to: GCallback.self),
                              data, nil, GConnectFlags(rawValue: 0))
        g_signal_connect_data(UnsafeMutableRawPointer(gesture), "drag-update",
                              unsafeBitCast(sliderPullState, to: GCallback.self),
                              data, nil, GConnectFlags(rawValue: 0))
        g_signal_connect_data(UnsafeMutableRawPointer(gesture), "drag-end",
                              unsafeBitCast(sliderPullEnd, to: GCallback.self),
                              data, nil, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(wrapper, gesture)

        // **Mouse wheel and two-finger scrolling** (Mac: `WheelSnap`). On the whole
        // shell, so over slider and speaker; the callback returns `TRUE` so the
        // event does not propagate upward.
        let wheel = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL)
        g_signal_connect_data(UnsafeMutableRawPointer(wheel), "scroll",
                              unsafeBitCast(sliderWheel, to: GCallback.self),
                              data, nil, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(wrapper, wheel)
    }

    /// One wheel notch is 5 %, at most three at once; a touchpad delivers
    /// points, 24 of which are 5 %, without rounding so no small nudge is lost.
    /// GTK counts positive downward, so louder is up: the sign flips. The system
    /// direction (natural scrolling) is already in `dy`.
    fileprivate func wheelState(dy: Double, detent: Bool) -> Bool {
        guard lives, dy != 0 else { return true }
        let share = detent ? min(max(dy, -3), 3) * 0.05 : dy / 24 * 0.05
        wheelRotated?(-share)
        return true
    }

    // MARK: State

    private var opened: Bool { atop || pulls || short }

    /// Set from outside (key, mute): redraws and swaps the icon.
    func setDown(_ new: Double) {
        value = min(max(new, 0), 1)
        symbolUpdate()
        if lives { gtk_widget_queue_draw(inputField) }
    }

    /// Opens or closes the slider for key presses, for 1.2 s.
    func shortShow(_ an: Bool) {
        short = an
        bringUpToDate()
    }

    private func placeOver(_ an: Bool) {
        atop = an
        bringUpToDate()
    }

    private func bringUpToDate() {
        guard lives else { return }
        drive(toward: opened ? 1 : 0)
        gtk_widget_queue_draw(inputField)
    }

    /// Icon as on the Mac: muted at 0, quiet below half, otherwise loud.
    private func symbolUpdate() {
        symbolText.setName(value <= 0 ? "speaker-muted"
                          : value < 0.5 ? "speaker-quiet" : "speaker-loud")
        if let button = gtk_widget_get_parent(symbolText.display) {
            caption(button, value <= 0 ? translated("Ton an") : translated("Ton aus"))
            gtk_widget_set_tooltip_text(button, value <= 0 ? translated("Ton an") : translated("Ton aus"))
        }
    }

    // MARK: Animation

    /// 0.18 s ease-out from the current state; a new run replaces the old one.
    private func drive(toward target: Double) {
        number += 1
        let my = number
        let from = progress
        guard abs(from - target) > 0.001 else { return }
        if motionReduced() || gtk_widget_get_mapped(inputField) == 0 {
            progressSet(target)
            return
        }
        runningCount(on: inputField, duration: 0.18, linear: true, step: { [weak self] t in
            guard let self, self.lives, self.number == my else { return }
            self.progressSet(from + (target - from) * IdLine.easeOut.value(t))
        }, done: {})
    }

    private func progressSet(_ p: Double) {
        progress = p
        gtk_drawing_area_set_content_width(asCharacter(inputField), Int32((p * Self.compartmentWidth).rounded()))
        gtk_widget_queue_draw(inputField)
    }

    // MARK: Dragging

    /// Center of the handle. **The handle stays fully inside the track**: its
    /// travel ends one radius before each end.
    static func handleX(_ value: Double, width: Double) -> Double {
        grip / 2 + (width - grip) * min(max(value, 0), 1)
    }

    /// Left edge of the track in the area: right-aligned, 4 pt from the edge.
    fileprivate func trackLeft(_ fieldWidth: Double) -> Double {
        fieldWidth - Self.compartmentWidth + 4
    }

    fileprivate func pullStart(x: Double) {
        guard progress > 0.5 else { return }
        startX = x
        pulls = true
        drag?(true)
        pullSet(x)
    }

    fileprivate func pullSet(_ x: Double) {
        let b = Double(gtk_widget_get_width(inputField))
        let left = trackLeft(b)
        let new = min(max((x - left - Self.grip / 2) / (Self.sliderWidth - Self.grip), 0), 1)
        setDown(new)
        changed?(new)
    }

    fileprivate func pullState(offset: Double) {
        guard pulls else { return }
        pullSet(startX + offset)
    }

    fileprivate func pullEnd() {
        guard pulls else { return }
        pulls = false
        drag?(false)
        bringUpToDate()
    }

    fileprivate var percentShow: Bool { pulls || short }
    fileprivate var progressValue: Double { progress }
}

// MARK: - Callbacks

nonisolated(unsafe) private let sliderPullStart: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { gesture, x, y, data in
    guard let data, let gesture else { return }
    let r = Unmanaged<VolumeSlider>.fromOpaque(data).takeUnretainedValue()
    // Only inside the compartment: the speaker button sits to its right.
    guard r.lives, x < Double(gtk_widget_get_width(r.display)) - Double(PlayerMetric.button),
          r.progressValue > 0.5 else { return }
    _ = gtk_gesture_set_state(OpaquePointer(gesture), GTK_EVENT_SEQUENCE_CLAIMED)
    r.pullStart(x: x)
}

nonisolated(unsafe) private let sliderPullState: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { _, offset, _, data in
    guard let data else { return }
    Unmanaged<VolumeSlider>.fromOpaque(data).takeUnretainedValue().pullState(offset: offset)
}

nonisolated(unsafe) private let sliderPullEnd: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { _, _, _, data in
    guard let data else { return }
    Unmanaged<VolumeSlider>.fromOpaque(data).takeUnretainedValue().pullEnd()
}

nonisolated(unsafe) private let sliderWheel: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Int32 = { watcher, _, dy, data in
    guard let data, let watcher else { return 0 }
    let r = Unmanaged<VolumeSlider>.fromOpaque(data).takeUnretainedValue()
    let detent = gtk_event_controller_scroll_get_unit(OpaquePointer(watcher)) == GDK_SCROLL_UNIT_WHEEL
    return r.wheelState(dy: dy, detent: detent) ? 1 : 0
}

nonisolated(unsafe) private let sliderFieldDraw: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, width, height, data in
    guard let cr, let data else { return }
    let r = Unmanaged<VolumeSlider>.fromOpaque(data).takeUnretainedValue()
    guard r.lives, width > 0 else { return }
    let p = r.progressValue
    let b = Double(width), center = Double(height) / 2
    let left = r.trackLeft(b)
    let length = VolumeSlider.sliderWidth
    let value = r.value
    let x = left + VolumeSlider.handleX(value, width: length)

    func capsule(_ from: Double, _ until: Double) {
        cairo_new_path(cr)
        cairo_move_to(cr, from + 2, center)
        cairo_line_to(cr, max(until - 2, from + 2), center)
    }
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_line_width(cr, 4)
    // Track: white at 18 %.
    cairo_set_source_rgba(cr, 1, 1, 1, 0.18 * p)
    capsule(left, left + length)
    cairo_stroke(cr)
    // Fill in accent up to the center of the handle.
    if value > 0 {
        let a = Theme.accentRGB
        cairo_set_source_rgba(cr, a.0, a.1, a.2, p)
        capsule(left, x)
        cairo_stroke(cr)
    }
    // Handle: white, 12 round, grows from 60 % to 100 % with the compartment.
    cairo_set_source_rgba(cr, 1, 1, 1, p)
    cairo_new_path(cr)
    cairo_arc(cr, x, center, VolumeSlider.grip / 2 * (0.6 + 0.4 * p), 0, 2 * .pi)
    cairo_fill(cr)
    // Small percentage below the handle, only while dragging or on key press.
    if r.percentShow {
        let text = "\(Int((value * 100).rounded())) %"
        cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
        cairo_set_font_size(cr, 11)
        var mass = cairo_text_extents_t()
        cairo_text_extents(cr, text, &mass)
        // #CCCCCC like `Theme.schriftLeise`.
        cairo_set_source_rgba(cr, 0.8, 0.8, 0.8, 1)
        let centerX = min(max(x, mass.width / 2 + 1), b - mass.width / 2 - 1)
        cairo_move_to(cr, centerX - mass.width / 2 - mass.x_bearing, Double(height) - 3)
        cairo_show_text(cr, text)
    }
}
