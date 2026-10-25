import CGtk
import Foundation
import JellyfinKit

/// **The letter strip beside a "By name" grid** (`AlphabetRail` on macOS and iPhone).
///
/// A column of the letters the list has (``AlphabetIndex``), spread over the height of the
/// page. A click or a drag along it jumps the grid to the first title of the letter under
/// the pointer; while the grid scrolls, the letter of the topmost title is in the accent.
///
/// **One drag gesture for click and slide**, as on the Mac: the press lands on a letter
/// and may then slide; each new letter under the pointer jumps once.
final class AlphabetStrip {
    let widget: Widget
    /// Called with the letter under the pointer.
    var jump: (String) -> Void = { _ in }

    private var entries: [AlphabetIndex.Entry] = []
    private var labels: [Widget] = []
    private var current: String?
    private var touched: String?
    private var pressY = 0.0
    fileprivate var lives = true

    /// The smallest row a letter gets; below it the strip condenses.
    static let minimumRow = 14.0
    static let width: Int32 = 22

    init() {
        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        // Every letter the same height, so the strip spreads over the whole page.
        gtk_box_set_homogeneous(OpaquePointer(widget), 1)
        gtk_widget_set_size_request(widget, Self.width, -1)
        gtk_widget_set_halign(widget, GTK_ALIGN_END)
        gtk_widget_set_valign(widget, GTK_ALIGN_FILL)
        gtk_widget_set_visible(widget, 0)
        caption(widget, translated("Alphabet"))

        let itself = Unmanaged.passRetained(self)
        signal(widget, "destroy") {
            itself.takeUnretainedValue().lives = false
            itself.release()
        }
        let data = itself.toOpaque()
        let gesture = gtk_gesture_drag_new()
        gtk_gesture_single_set_button(gesture, 1)
        g_signal_connect_data(UnsafeMutableRawPointer(gesture), "drag-begin",
                              unsafeBitCast(stripPullStart, to: GCallback.self),
                              data, nil, GConnectFlags(rawValue: 0))
        g_signal_connect_data(UnsafeMutableRawPointer(gesture), "drag-update",
                              unsafeBitCast(stripPullState, to: GCallback.self),
                              data, nil, GConnectFlags(rawValue: 0))
        g_signal_connect_data(UnsafeMutableRawPointer(gesture), "drag-end",
                              unsafeBitCast(stripPullEnd, to: GCallback.self),
                              data, nil, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(widget, gesture)
    }

    /// Shows the letters of `index` (or hides the strip for `nil`), condensed to what fits
    /// into `height`.
    func show(_ index: AlphabetIndex?, height: Double) {
        guard lives else { return }
        guard let index, index.isUseful else {
            gtk_widget_set_visible(widget, 0)
            return
        }
        let slots = max(2, Int((height > 0 ? height : 600) / Self.minimumRow))
        let shown = index.condensed(fitting: slots)
        gtk_widget_set_visible(widget, 1)
        guard shown != entries else { return }
        entries = shown
        wipe(widget)
        labels = shown.map { entry in
            let letter = label(entry.letter, style: "swiftly-buchstabe")
            gtk_widget_set_vexpand(letter, 1)
            append(widget, letter)
            return letter
        }
        paint()
    }

    /// The letter of the topmost title, lit while the pointer is not on the strip.
    func highlight(_ letter: String?) {
        guard lives, letter != current else { return }
        current = letter
        paint()
    }

    private func paint() {
        let lit = touched ?? current
        for (entry, letter) in zip(entries, labels) {
            if entry.letter == lit { gtk_widget_add_css_class(letter, "swiftly-buchstabe-aktiv") }
            else { gtk_widget_remove_css_class(letter, "swiftly-buchstabe-aktiv") }
        }
    }

    fileprivate func pullStart(y: Double) {
        pressY = y
        pointer(at: y)
    }

    fileprivate func pullState(dy: Double) { pointer(at: pressY + dy) }

    fileprivate func pullEnd() {
        touched = nil
        paint()
    }

    private func pointer(at y: Double) {
        guard lives, !entries.isEmpty else { return }
        let height = Double(gtk_widget_get_height(widget))
        guard height > 0 else { return }
        let row = Int(y / (height / Double(entries.count)))
        let letter = entries[min(max(row, 0), entries.count - 1)].letter
        guard letter != touched else { return }
        touched = letter
        paint()
        jump(letter)
    }
}

nonisolated(unsafe) private let stripPullStart: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { gesture, _, y, data in
    guard let data, let gesture else { return }
    _ = gtk_gesture_set_state(OpaquePointer(gesture), GTK_EVENT_SEQUENCE_CLAIMED)
    Unmanaged<AlphabetStrip>.fromOpaque(data).takeUnretainedValue().pullStart(y: y)
}

nonisolated(unsafe) private let stripPullState: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { _, _, dy, data in
    guard let data else { return }
    Unmanaged<AlphabetStrip>.fromOpaque(data).takeUnretainedValue().pullState(dy: dy)
}

nonisolated(unsafe) private let stripPullEnd: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { _, _, _, data in
    guard let data else { return }
    Unmanaged<AlphabetStrip>.fromOpaque(data).takeUnretainedValue().pullEnd()
}
