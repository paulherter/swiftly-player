import CGtk
import Foundation

/// **UI size**: a slider with steps from 80 to 150 %.
///
/// Built like the volume slider (`VolumeSlider.swift`): a drawing area,
/// track 4, fill in accent up to the handle, white handle. Not a `GtkScale`,
/// which would bring the system's track, handle and sizes.
///
/// **The value is applied on release, not while dragging.** Every step
/// re-lays out the whole UI, including the slider itself; if the change took
/// effect during the drag, the track would run away under the pointer. While
/// dragging only handle and percentage move.
///
/// With the keyboard: arrows one step, Home/End to the ends. That applies
/// immediately because nothing is under the pointer.
final class SizesSlider: @unchecked Sendable {
    static let height = 32.0
    static let grip = 16.0
    /// Padding left and right so the handle is fully visible at the ends.
    static let margin = 10.0

    let display: Widget
    private let inputField: Widget
    private let valueField: Widget
    private(set) var rung: Int
    private var pulls = false
    fileprivate var lives = true
    private let levels = Scaling.levels

    /// A step is chosen and should take effect.
    var selected: ((Double) -> Void)?

    init(value: Double, title: String, under: String?) {
        rung = Self.stageTo(Scaling.snapped(value))

        let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        display = block!

        let w = label("", style: "swiftly-koerper")
        gtk_widget_add_css_class(w, "dim-label")
        gtk_widget_set_valign(w, GTK_ALIGN_CENTER)
        valueField = w!
        let header = rowBody(symbol: "zoom-in-symbolic", title: title, under: under,
                               accent: false, right: w)
        gtk_widget_add_css_class(header, "swiftly-zeilenrumpf")
        append(block, header)

        // **The role is fixed at construction**: `accessible-role` is a property GTK
        // only accepts at creation.
        var role = GValue()
        g_value_init(&role, gtk_accessible_role_get_type())
        g_value_set_enum(&role, Int32(GTK_ACCESSIBLE_ROLE_SLIDER.rawValue))
        let raw: UnsafeMutablePointer<GObject>? = "accessible-role".withCString { name in
            var names: [UnsafePointer<CChar>?] = [name]
            return withUnsafePointer(to: &role) { values in
                names.withUnsafeMutableBufferPointer {
                    g_object_new_with_properties(gtk_drawing_area_get_type(), 1, $0.baseAddress, values)
                }
            }
        }
        g_value_unset(&role)
        let inputField: Widget! = raw.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: GtkWidget.self) }
            ?? gtk_drawing_area_new()
        gtk_widget_add_css_class(inputField, "swiftly-groessenregler")
        gtk_drawing_area_set_content_height(asCharacter(inputField), Int32(Self.height))
        gtk_widget_set_hexpand(inputField, 1)
        gtk_widget_set_focusable(inputField, 1)
        // Below the title, not below the icon: 12 margin + 20 icon + 14.
        gtk_widget_set_margin_start(inputField, 46 - Int32(Self.margin))
        gtk_widget_set_margin_end(inputField, 12 - Int32(Self.margin) + 4)
        gtk_widget_set_margin_bottom(inputField, 8)
        caption(inputField, title)
        self.inputField = inputField
        append(block, inputField)

        let itself = Unmanaged.passRetained(self)
        gtk_drawing_area_set_draw_func(asCharacter(inputField), sizesSliderDraw, itself.toOpaque(), nil)
        signal(inputField, "destroy") {
            itself.takeUnretainedValue().lives = false
            itself.release()
        }
        let data = itself.toOpaque()

        let gesture = gtk_gesture_drag_new()
        gtk_gesture_single_set_button(gesture, 1)
        g_signal_connect_data(UnsafeMutableRawPointer(gesture), "drag-begin",
                              unsafeBitCast(sizePullStart, to: GCallback.self),
                              data, nil, GConnectFlags(rawValue: 0))
        g_signal_connect_data(UnsafeMutableRawPointer(gesture), "drag-update",
                              unsafeBitCast(sizePullState, to: GCallback.self),
                              data, nil, GConnectFlags(rawValue: 0))
        g_signal_connect_data(UnsafeMutableRawPointer(gesture), "drag-end",
                              unsafeBitCast(sizePullEnd, to: GCallback.self),
                              data, nil, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(inputField, gesture)

        let keys = gtk_event_controller_key_new()
        g_signal_connect_data(UnsafeMutableRawPointer(keys), "key-pressed",
                              unsafeBitCast(sizeKey, to: GCallback.self),
                              data, nil, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(inputField, keys)

        bringUpToDate()
    }

    var value: Double { levels[rung] }

    private static func stageTo(_ value: Double) -> Int {
        Scaling.levels.firstIndex(of: value) ?? Scaling.levels.firstIndex(of: 1) ?? 0
    }

    /// Set from outside ("Zurücksetzen"): shows the value, reports nothing.
    func setDown(_ new: Double) {
        rung = Self.stageTo(Scaling.snapped(new))
        bringUpToDate()
    }

    private func bringUpToDate() {
        guard lives else { return }
        let text = "\(Int((value * 100).rounded())) %"
        gtk_label_set_text(OpaquePointer(valueField), text)
        gtk_widget_queue_draw(inputField)
        // Value for assistive technology: number and wording.
        var names = [GTK_ACCESSIBLE_PROPERTY_VALUE_MIN, GTK_ACCESSIBLE_PROPERTY_VALUE_MAX,
                     GTK_ACCESSIBLE_PROPERTY_VALUE_NOW, GTK_ACCESSIBLE_PROPERTY_VALUE_TEXT]
        var values = [GValue(), GValue(), GValue(), GValue()]
        let numbers = [(levels.first ?? 0.8) * 100, (levels.last ?? 1.5) * 100, value * 100]
        for (i, z) in numbers.enumerated() {
            g_value_init(&values[i], g_type_from_name("gdouble"))
            g_value_set_double(&values[i], z)
        }
        g_value_init(&values[3], g_type_from_name("gchararray"))
        text.withCString { g_value_set_string(&values[3], $0) }
        gtk_accessible_update_property_value(OpaquePointer(inputField), 4, &names, &values)
        for i in values.indices { g_value_unset(&values[i]) }
    }

    // MARK: Layout

    fileprivate func x(for rung: Int, width: Double) -> Double {
        let n = Double(max(levels.count - 1, 1))
        return Self.margin + (width - 2 * Self.margin) * Double(rung) / n
    }

    fileprivate func rung(at x: Double) -> Int {
        let b = Double(gtk_widget_get_width(inputField))
        let n = Double(max(levels.count - 1, 1))
        let share = (x - Self.margin) / max(b - 2 * Self.margin, 1)
        return min(max(Int((share * n).rounded()), 0), levels.count - 1)
    }

    // MARK: Dragging

    private var startX = 0.0

    fileprivate func pullStart(x: Double) {
        guard lives else { return }
        pulls = true
        startX = x
        gtk_widget_grab_focus(inputField)
        pullSet(x)
    }

    fileprivate func pullState(offset: Double) {
        guard pulls else { return }
        pullSet(startX + offset)
    }

    private func pullSet(_ x: Double) {
        let new = rung(at: x)
        guard new != rung else { return }
        rung = new
        bringUpToDate()
    }

    fileprivate func pullEnd() {
        guard pulls else { return }
        pulls = false
        selected?(value)
    }

    fileprivate func keyButton(_ keyButton: UInt32) -> Bool {
        let new: Int
        switch keyButton {
        case 0xff51, 0xff54: new = rung - 1             // left, down
        case 0xff53, 0xff52: new = rung + 1             // right, up
        case 0xff50:         new = 0                     // Home
        case 0xff57:         new = levels.count - 1      // End
        default: return false
        }
        let clamped = min(max(new, 0), levels.count - 1)
        guard clamped != rung else { return true }
        rung = clamped
        bringUpToDate()
        selected?(value)
        return true
    }

    fileprivate var levelsNumber: Int { levels.count }
    fileprivate var center: Int { levels.firstIndex(of: 1) ?? 0 }
}

// MARK: - Callbacks

nonisolated(unsafe) private let sizePullStart: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { gesture, x, _, data in
    guard let data, let gesture else { return }
    _ = gtk_gesture_set_state(OpaquePointer(gesture), GTK_EVENT_SEQUENCE_CLAIMED)
    Unmanaged<SizesSlider>.fromOpaque(data).takeUnretainedValue().pullStart(x: x)
}

nonisolated(unsafe) private let sizePullState: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { _, offset, _, data in
    guard let data else { return }
    Unmanaged<SizesSlider>.fromOpaque(data).takeUnretainedValue().pullState(offset: offset)
}

nonisolated(unsafe) private let sizePullEnd: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { _, _, _, data in
    guard let data else { return }
    Unmanaged<SizesSlider>.fromOpaque(data).takeUnretainedValue().pullEnd()
}

nonisolated(unsafe) private let sizeKey: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UInt32, UInt32, gpointer?
) -> Int32 = { _, keyButton, _, _, data in
    guard let data else { return 0 }
    return Unmanaged<SizesSlider>.fromOpaque(data).takeUnretainedValue().keyButton(keyButton) ? 1 : 0
}

nonisolated(unsafe) private let sizesSliderDraw: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, width, height, data in
    guard let cr, let data else { return }
    let r = Unmanaged<SizesSlider>.fromOpaque(data).takeUnretainedValue()
    guard r.lives, width > 0 else { return }
    let b = Double(width), center = Double(height) / 2
    let left = r.x(for: 0, width: b), right = r.x(for: r.levelsNumber - 1, width: b)
    let handleX = r.x(for: r.rung, width: b)

    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_line_width(cr, 4)
    // Track: white at 18 %, as in the player.
    cairo_set_source_rgba(cr, 1, 1, 1, 0.18)
    cairo_new_path(cr)
    cairo_move_to(cr, left, center)
    cairo_line_to(cr, right, center)
    cairo_stroke(cr)
    // Fill in accent up to the handle.
    let a = Theme.accentRGB
    cairo_set_source_rgba(cr, a.0, a.1, a.2, 1)
    cairo_new_path(cr)
    cairo_move_to(cr, left, center)
    cairo_line_to(cr, max(handleX, left + 0.01), center)
    cairo_stroke(cr)
    // Steps: small dots, slightly stronger at 100 %, which means "like the system".
    for i in 0..<r.levelsNumber {
        let x = r.x(for: i, width: b)
        cairo_set_source_rgba(cr, 1, 1, 1, i == r.center ? 0.7 : 0.35)
        cairo_new_path(cr)
        cairo_arc(cr, x, center + 9, i == r.center ? 2 : 1.5, 0, 2 * .pi)
        cairo_fill(cr)
    }
    // Handle: white, 16 round, the size of the switch knob.
    cairo_set_source_rgba(cr, 1, 1, 1, 1)
    cairo_new_path(cr)
    cairo_arc(cr, handleX, center, SizesSlider.grip / 2, 0, 2 * .pi)
    cairo_fill(cr)
}
