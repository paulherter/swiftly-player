import CGtk
import Foundation

/// **GTK has no inheritance, only pointer casts.**
///
/// Every function takes the type it is meant for (`gtk_box_append` wants a box,
/// `gtk_button_set_label` a button), but every `*_new()` returns a `GtkWidget*`.
/// C macros do the casting; Swift has none, so the conversions live here.
///
/// **Which types Swift can name is not guessable:** `GtkBox`, `GtkButton` and
/// `GtkEntry` yes, `GtkLabel` and `GtkEditable` no (they arrive as opaque
/// pointers). When adding a cast, ask the compiler for the expected types
/// instead of guessing.
typealias Widget = UnsafeMutablePointer<GtkWidget>

@inline(__always) func asBox(_ w: Widget!) -> UnsafeMutablePointer<GtkBox>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkBox>.self)
}
@inline(__always) func asButton(_ w: Widget!) -> UnsafeMutablePointer<GtkButton>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkButton>.self)
}
@inline(__always) func asField(_ w: Widget!) -> UnsafeMutablePointer<GtkEntry>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkEntry>.self)
}
@inline(__always) func asWindow(_ w: Widget!) -> UnsafeMutablePointer<GtkWindow>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkWindow>.self)
}
@inline(__always) func asCharacter(_ w: Widget!) -> UnsafeMutablePointer<GtkDrawingArea>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkDrawingArea>.self)
}
@inline(__always) func asFixed(_ w: Widget!) -> UnsafeMutablePointer<GtkFixed>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkFixed>.self)
}
@inline(__always) func asPanel(_ w: Widget!) -> UnsafeMutablePointer<GtkPopover>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkPopover>.self)
}
@inline(__always) func asCheckmark(_ w: Widget!) -> UnsafeMutablePointer<GtkCheckButton>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkCheckButton>?.self)
}

@inline(__always) func asScale(_ w: Widget!) -> UnsafeMutablePointer<GtkScale>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkScale>.self)
}
@inline(__always) func asSection(_ w: Widget!) -> UnsafeMutablePointer<GtkRange>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkRange>.self)
}
@inline(__always) func asField2(_ w: Widget!) -> UnsafeMutablePointer<GtkFixed>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkFixed>.self)
}

// MARK: - Building blocks

/// A vertical or horizontal stack with spacing.
func stack(_ bearing: GtkOrientation, spacing: Int32 = 0) -> Widget! {
    gtk_box_new(bearing, spacing)
}

func append(_ parent: Widget!, _ kind: Widget!) {
    gtk_box_append(asBox(parent), kind)
}

/// Empties a box. GTK has no ready-made call; remove the first child until none is left.
/// A popover tied to its anchor that goes away with it.
///
/// **GTK does not clean up a popover together with its anchor.** It becomes a child
/// through `gtk_widget_set_parent`, but nobody unparents it. When the anchor is
/// destroyed, GTK reports
///
///     Finalizing GtkButton …, but it still has children left: GtkPopover …
///
/// and leaves a dangling pointer. This goes unnoticed until the memory is reused,
/// then the app crashes (it did when opening a series: the home page attaches one
/// popover to **every** tile).
///
/// So attach it here and schedule the unparenting in the same step. Use this
/// function instead of `gtk_popover_new` by hand.
/// **The anchor owns the popover; whoever stores it must forget it.**
///
/// When the anchor is destroyed, the popover is unparented and freed. A field that
/// still holds it then points at dead memory, and the next `gtk_widget_unparent`
/// on it crashes (SIGSEGV).
///
/// Code that keeps the popover in a field should use ``App/panelOpen(an:stil:)``
/// instead of this function alone.
final class PanelState { var present = true }

///
/// **The popover hangs from a corner of its button:** flush left below it, no
/// arrow, 8 pt gap, and it grows from that corner (`swiftly-aufklappen` in the
/// stylesheet). `flush` picks the corner.
func panelAn(_ anchor: Widget!, style: String = "swiftly-mehr",
             status: GtkPositionType = GTK_POS_BOTTOM,
             flush: GtkAlign = GTK_ALIGN_START) -> Widget! {
    let panel: Widget! = gtk_popover_new()
    gtk_widget_add_css_class(panel, style)
    gtk_popover_set_position(asPanel(panel), status)
    gtk_popover_set_has_arrow(asPanel(panel), 0)
    gtk_popover_set_offset(asPanel(panel), 0, Scaling.windowMetric(8))
    gtk_widget_set_halign(panel, flush)
    gtk_widget_add_css_class(panel, flush == GTK_ALIGN_START ? "swiftly-links"
                                  : flush == GTK_ALIGN_END ? "swiftly-rechts" : "swiftly-mitte")
    // **Next to the button, not inside it.** On press GTK sets `:active` on the target
    // *and every parent*, and the parent of a popover is its anchor. Holding an entry
    // in a "Filme ▾" menu would press "Filme" too, shrinking the button
    // (`scale(0.97)`). `GtkMenuButton` attaches its popover to itself for the same
    // reason. So the popover hangs from the button's parent and points at the
    // button's rectangle; containers do not lay out a popover and measure nothing.
    let button = g_type_check_instance_is_a(
        UnsafeMutableRawPointer(anchor).assumingMemoryBound(to: GTypeInstance.self),
        gtk_button_get_type()) != 0
    if button, let parent = gtk_widget_get_parent(anchor) {
        gtk_widget_set_parent(panel, parent)
        var r = graphene_rect_t()
        if gtk_widget_compute_bounds(anchor, parent, &r) != 0 {
            var frameRect = GdkRectangle(x: Int32(r.origin.x.rounded()), y: Int32(r.origin.y.rounded()),
                                      width: Int32(r.size.width.rounded()),
                                      height: Int32(r.size.height.rounded()))
            gtk_popover_set_pointing_to(asPanel(panel), &frameRect)
        }
    } else {
        gtk_widget_set_parent(panel, anchor)
    }
    // **Only if it still exists.** `panelClose` unparents (and thus frees) the
    // popover itself; if the anchor went away afterwards, this callback touched freed
    // memory and crashed when leaving the page.
    let lives = PanelState()
    signal(panel, "destroy") { lives.present = false }
    signal(anchor, "destroy") { if lives.present { gtk_widget_unparent(panel) } }
    return panel
}

/// Removes all children from a container, **from any container, not only boxes.**
///
/// **The earlier version hung the app.** It called `gtk_box_remove` on a blindly
/// cast pointer. If the container is not a `GtkBox`, the call fails its assertion
/// and **removes nothing**; `gtk_widget_get_first_child` then returns the same child
/// and the loop never ends: one core at 100 %, and a log growing by tens of MB per
/// second:
///
/// ```
/// Gtk-CRITICAL **: gtk_box_remove: assertion 'GTK_IS_BOX (box)' failed
/// ```
///
/// A `GtkFixed` triggered it, but the bug was this loop: **it depended on a child
/// existing, not on progress.**
///
/// So `gtk_widget_unparent` is used for every widget (the failure case cannot
/// occur), and a guard at the end aborts if a child still remains. A container
/// that does not become fully empty is better than a frozen app.
func wipe(_ container: Widget!) {
    while let kind = gtk_widget_get_first_child(container) {
        gtk_widget_unparent(kind)
        guard gtk_widget_get_first_child(container) != kind else { return }
    }
}

func label(_ text: String, style: String? = nil, wrap: Bool = false) -> Widget! {
    let l: Widget! = gtk_label_new(text)
    if let style { gtk_widget_add_css_class(l, style) }
    if wrap {
        gtk_label_set_wrap(OpaquePointer(l), 1)
        gtk_label_set_justify(OpaquePointer(l), GTK_JUSTIFY_CENTER)
    }
    return l
}

func edges(_ w: Widget!, _ all: Int32) {
    gtk_widget_set_margin_top(w, all)
    gtk_widget_set_margin_bottom(w, all)
    gtk_widget_set_margin_start(w, all)
    gtk_widget_set_margin_end(w, all)
}

// MARK: - Callbacks with state

/// **A C callback cannot capture anything.**
///
/// It is a bare function pointer. To pass something along, hand a pointer to an
/// object through and unpack it on the other side. This wrapper does that: it
/// keeps the Swift closure alive until GTK no longer needs it.
final class WorkItem {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
}

nonisolated(unsafe) let jobAsSignalPublic: @convention(c) (UnsafeMutableRawPointer?, gpointer?) -> Void = { _, data in
    guard let data else { return }
    Unmanaged<WorkItem>.fromOpaque(data).takeUnretainedValue().block()
}

nonisolated(unsafe) let jobSharePublic: @convention(c) (gpointer?, UnsafeMutablePointer<_GClosure>?) -> Void = { data, _ in
    guard let data else { return }
    Unmanaged<WorkItem>.fromOpaque(data).release()
}

/// Connects a signal to a Swift closure.
///
/// `g_signal_connect` is a macro and invisible to Swift; `g_signal_connect_data`
/// is underneath. The closure is retained and released when GTK disconnects the
/// signal, so it never dangles after cleanup.
///
/// **Only for signals without arguments of their own.** The callback below takes
/// two pointers: sender and user data. A signal that passes something in between
/// shifts the user data by one slot, and the callback then reads that value as a
/// pointer (this crashed with "Bad pointer dereference at 0x8"). For signals with
/// arguments, write a callback of the matching shape; see ``onPointer`` for
/// "enter", which brings x and y.
func signal(_ target: Widget!, _ name: String, _ block: @escaping () -> Void) {
    let job = Unmanaged.passRetained(WorkItem(block)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(target), name,
                          unsafeBitCast(jobAsSignalPublic, to: GCallback.self),
                          job, jobSharePublic, GConnectFlags(rawValue: 0))
}

/// The same for something that is not a widget, e.g. a `GtkAdjustment`.
/// The same shape rules as ``signal`` apply.
func signalRaw(_ target: UnsafeMutableRawPointer, _ name: String,
                  _ block: @escaping () -> Void) {
    let job = Unmanaged.passRetained(WorkItem(block)).toOpaque()
    g_signal_connect_data(target, name,
                          unsafeBitCast(jobAsSignalPublic, to: GCallback.self),
                          job, jobSharePublic, GConnectFlags(rawValue: 0))
}

nonisolated(unsafe) private let jobAsProperty: @convention(c) (
    UnsafeMutableRawPointer?, OpaquePointer?, gpointer?
) -> Void = { _, _, data in
    guard let data else { return }
    Unmanaged<WorkItem>.fromOpaque(data).takeUnretainedValue().block()
}

/// Listens to a property: `notify::is-active` and similar.
///
/// **Own callback because `notify` passes the property.** This is exactly the shape
/// that crashed the app: the GParamSpec sits where ``signal`` expects the user
/// data.
func onProperty(_ target: UnsafeMutableRawPointer, _ name: String,
                    _ block: @escaping () -> Void) {
    let job = Unmanaged.passRetained(WorkItem(block)).toOpaque()
    g_signal_connect_data(target, name,
                          unsafeBitCast(jobAsProperty, to: GCallback.self),
                          job, jobSharePublic, GConnectFlags(rawValue: 0))
}

/// **A GTK pointer is not "sendable", and Swift 6 insists on that.**
///
/// Rightly so: a raw pointer says nothing about who may touch it concurrently.
/// With GTK the answer is simple anyway: everything runs on the main thread, and
/// ``onMainThread`` sends work back there. This box carries the pointer across the
/// boundary; the guarantee holds as long as it is unpacked **only** inside an
/// `onMainThread` block.
struct PointerBox: @unchecked Sendable {
    let widget: Widget!
    init(_ widget: Widget!) { self.widget = widget }
}

// MARK: - Back to the main thread

nonisolated(unsafe) private let jobEmptyRun: @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    Unmanaged<WorkItem>.fromOpaque(data).takeRetainedValue().block()
    return 0   // run once, then remove the source
}

/// **GTK is not thread-safe.** Every UI change must happen on the main thread;
/// a call from a task would eventually corrupt things silently. `g_idle_add` is the
/// intended way back.
///
/// **Priority above redraw, not below.** `G_PRIORITY_DEFAULT_IDLE` (200) is wrong:
/// GTK redraws at `GDK_PRIORITY_REDRAW` (120), and smaller means more important, so
/// a 200 source never runs while a redraw is pending. The player always has one
/// pending, because every frame sets a new paintable. The symptom was a black
/// loading veil over a picture that was already there: black image, time 0:00,
/// audio playing, and VLC's "buffering 100 %" arriving about fifteen seconds late.
///
/// `0` (`G_PRIORITY_DEFAULT`) is right. What arrives here is a network response or
/// a VLC message: real work, not something that can wait until nothing is left to
/// do.
func onMainThread(_ block: @escaping @Sendable () -> Void) {
    let job = Unmanaged.passRetained(WorkItem(block)).toOpaque()
    g_idle_add_full(0, jobEmptyRun, job, nil)   // 0 = G_PRIORITY_DEFAULT
}

/// **Is the widget still alive?** A weak GLib reference that empties itself on
/// teardown.
///
/// A job that runs after a network response otherwise hits a widget the page has
/// already removed: `GTK_IS_LABEL failed` in the log, or freed memory. `held`
/// keeps the widget alive longer than its page; this one holds nothing and only
/// asks.
///
/// **Create it on the main thread** while the widget is certainly alive, i.e. before
/// `Task.detached`, not inside it. Querying and releasing is allowed from any
/// thread; `GWeakRef` is built for that.
final class LifeCharacter: @unchecked Sendable {
    private let reference: UnsafeMutablePointer<GWeakRef>
    init(_ widget: Widget!) {
        reference = .allocate(capacity: 1)
        reference.initialize(to: GWeakRef())
        g_weak_ref_init(reference, widget.map { UnsafeMutableRawPointer($0) })
    }
    deinit {
        g_weak_ref_clear(reference)
        reference.deallocate()
    }
    /// Ask only on the main thread: there the widget cannot disappear between the
    /// answer and its use.
    var lives: Bool {
        guard let strong = g_weak_ref_get(reference) else { return false }
        g_object_unref(strong)
        return true
    }
}

/// ``onMainThread``, but only while the widget is still alive.
/// If it was torn down, the job is silently dropped: its page is gone and nobody
/// would see the result.
func onMainThread(during symbolText: LifeCharacter, _ block: @escaping @Sendable () -> Void) {
    onMainThread {
        guard symbolText.lives else { return }
        block()
    }
}

// MARK: - Smooth paging

/// **A jump looks broken even when it is correct.**
///
/// On the Mac the row pages with `easeInOut` over 280 ms. GTK does not animate a
/// `GtkAdjustment`; the value is set immediately. This wrapper sets it anew on
/// every frame instead.
///
/// **Driven by the frame clock, not a timer.** `g_timeout_add` with 16 ms means 62
/// frames per second on every screen. `gtk_widget_add_tick_callback` follows the
/// window's frame clock and thus runs as fast as the screen.
private final class Motion {
    let setDown: (Double) -> Void
    let from: Double
    let to: Double
    let beginning = Date()
    static let duration = 0.28
    /// With reduced motion: short and linear, like `linearReduced` on the Mac (there
    /// every curve asks `motionReduced`; `gentle` never did).
    var duration = Motion.duration
    var linear = false
    var tick: guint = 0
    var divider: Double = 1

    init(from: Double, to: Double, setDown: @escaping (Double) -> Void) {
        self.from = from
        self.to = to
        self.setDown = setDown
    }
}

nonisolated(unsafe) private let motionTick: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, data in
    guard let data else { return 0 }
    let b = Unmanaged<Motion>.fromOpaque(data).takeUnretainedValue()
    let t = min(Date().timeIntervalSince(b.beginning) / b.duration, 1)
    // easeInOut, the same curve as `Animation.easeInOut` on the Mac.
    let e = b.linear ? t : (t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2)
    // Snap to whole device pixels, for the same reason as in scrolling.
    let raw = b.from + (b.to - b.from) * e
    b.setDown((raw * b.divider).rounded() / b.divider)
    if t >= 1 {
        Unmanaged<Motion>.fromOpaque(data).release()
        return 0   // G_SOURCE_REMOVE
    }
    return 1
}

/// Moves a value smoothly from `from` to `to`, in step with the screen.
func gentle(on widget: Widget!, from: Double, to: Double,
           setDown: @escaping (Double) -> Void) {
    guard abs(to - from) > 0.5 else { return }
    let run = Motion(from: from, to: to, setDown: setDown)
    if motionReduced() {
        run.duration = Theme.timeReduced
        run.linear = true
    }
    run.divider = Scaling.devicesPoints(widget)
    let b = Unmanaged.passRetained(run).toOpaque()
    _ = gtk_widget_add_tick_callback(widget, motionTick, b, nil)
}

// MARK: - Pointer in, pointer out

nonisolated(unsafe) let jobAsMotionPublic: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { _, _, _, data in
    guard let data else { return }
    Unmanaged<WorkItem>.fromOpaque(data).takeUnretainedValue().block()
}

nonisolated(unsafe) private let jobAsMotion: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { _, _, _, data in
    guard let data else { return }
    Unmanaged<WorkItem>.fromOpaque(data).takeUnretainedValue().block()
}

/// Reports when the pointer enters or leaves a widget.
///
/// GTK4 uses `GtkEventControllerMotion` with "enter" and "leave", two signals with
/// **different** shapes: "enter" carries the coordinates, "leave" does not. Hence
/// two callbacks instead of one.
func onPointer(_ target: Widget!, inward: @escaping () -> Void, out: @escaping () -> Void) {
    let watcher = gtk_event_controller_motion_new()
    let a = Unmanaged.passRetained(WorkItem(inward)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(watcher), "enter",
                          unsafeBitCast(jobAsMotion, to: GCallback.self),
                          a, jobSharePublic, GConnectFlags(rawValue: 0))
    let b = Unmanaged.passRetained(WorkItem(out)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(watcher), "leave",
                          unsafeBitCast(jobAsSignalPublic, to: GCallback.self),
                          b, jobSharePublic, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(target, watcher)
}

/// Reports **where** the pointer is over a widget: every movement, no threshold,
/// and leaving. For the trickplay preview at the seek bar, which must follow the
/// pointer, not just know it is there (``onPointer`` and ``onMotion`` are not
/// enough).
final class LocalGuard {
    let moved: (Double, Double) -> Void
    let leave: () -> Void
    init(moved: @escaping (Double, Double) -> Void, leave: @escaping () -> Void) {
        self.moved = moved
        self.leave = leave
    }
}

nonisolated(unsafe) private let guardAsPlace: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { _, x, y, data in
    guard let data else { return }
    Unmanaged<LocalGuard>.fromOpaque(data).takeUnretainedValue().moved(x, y)
}

nonisolated(unsafe) private let guardAsLeave: @convention(c) (
    UnsafeMutableRawPointer?, gpointer?
) -> Void = { _, data in
    guard let data else { return }
    Unmanaged<LocalGuard>.fromOpaque(data).takeUnretainedValue().leave()
}

nonisolated(unsafe) private let localGuardShare: @convention(c) (
    gpointer?, UnsafeMutablePointer<_GClosure>?
) -> Void = { data, _ in
    guard let data else { return }
    Unmanaged<LocalGuard>.fromOpaque(data).release()
}

func onMousePosition(_ target: Widget!, moved: @escaping (Double, Double) -> Void,
                leave: @escaping () -> Void) {
    let watcher = gtk_event_controller_motion_new()
    let sentry = Unmanaged.passRetained(LocalGuard(moved: moved, leave: leave)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(watcher), "motion",
                          unsafeBitCast(guardAsPlace, to: GCallback.self),
                          sentry, nil, GConnectFlags(rawValue: 0))
    g_signal_connect_data(UnsafeMutableRawPointer(watcher), "leave",
                          unsafeBitCast(guardAsLeave, to: GCallback.self),
                          sentry, localGuardShare, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(target, watcher)
}

// MARK: - Smooth scrolling

/// **GTK scrolls in jumps with a mouse wheel.** One notch, one jump; that is the
/// stutter. GTK smooths touchpad scrolling itself, but not the wheel.
///
/// Each notch becomes a target, and a tick follows it. Further notches only move
/// the target; no second motion starts that fights the first.
///
/// **Time-based, not frame-based.** A `g_timeout_add` tick with 16 ms is tied to 62
/// frames per second instead of the screen (on 144 Hz it feels like 60), and a
/// fixed fraction *per frame* would run the same motion more than twice as fast on
/// a fast screen. Both now depend on **time**: `1 − e^(−k·dt)` with `k = 13.9`,
/// which at 16 ms gives exactly one fifth per step.
private final class SoftRun {
    let read: () -> Double
    let setDown: (Double) -> Void
    let upperLimit: () -> Double
    var target: Double
    var tick: guint = 0
    var recent: Int = 0
    /// How many device pixels make one point.
    var divider: Double = 1

    init(read: @escaping () -> Double, setDown: @escaping (Double) -> Void,
         upperLimit: @escaping () -> Double) {
        self.read = read
        self.setDown = setDown
        self.upperLimit = upperLimit
        self.target = read()
    }

    /// **Snap to whole device pixels.**
    ///
    /// A fractional scroll offset shifts all content by half a pixel. Then **all**
    /// widget edges are drawn at half coverage, and where two boxes of the same color
    /// meet, the background shows through (a dark line between header and body: both
    /// have the same tone, black lies behind, and two half-covered rows give
    /// 66 → 60 → 52 → 64, measured on a screenshot).
    func latch(_ value: Double) -> Double {
        (value * divider).rounded() / divider
    }
}

/// How far one notch carries: about three lines of text, the same order of
/// magnitude as a touchpad swipe.
private let detentRange: Double = 110
/// How fast the remainder melts away. At 16 ms one fifth is left.
private let softRate: Double = 13.9

nonisolated(unsafe) private let softTick: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, clock, data in
    guard let data else { return 0 }
    let w = Unmanaged<SoftRun>.fromOpaque(data).takeUnretainedValue()

    // The time comes from the frame clock, in microseconds.
    let nowTime = Int(clock.map { gdk_frame_clock_get_frame_time($0) } ?? 0)
    let dt = w.recent == 0 ? 1.0 / 60 : Double(nowTime - w.recent) / 1_000_000
    w.recent = nowTime

    let now = w.read()
    let rest = w.target - now
    if abs(rest) < 0.5 {
        w.setDown(w.latch(w.target))
        w.tick = 0
        Unmanaged<SoftRun>.fromOpaque(data).release()
        return 0
    }
    w.setDown(w.latch(now + rest * (1 - exp(-softRate * min(dt, 0.1)))))
    return 1
}

nonisolated(unsafe) private let wheelRotated: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> gboolean = { watcher, _, dy, data in
    guard let data else { return 0 }
    let w = Unmanaged<SoftRun>.fromOpaque(data).takeUnretainedValue()
    let highest = w.upperLimit()
    // **Start over on every new grab.** When nothing is running, the stored target may
    // be stale: the page may have been rebuilt or scrolled elsewhere in the meantime.
    if w.tick == 0 { w.target = w.read(); w.recent = 0 }
    w.target = min(max(w.target + dy * detentRange, 0), max(highest, 0))
    if w.tick == 0, let watcher,
       let target = gtk_event_controller_get_widget(OpaquePointer(watcher)) {
        w.divider = Scaling.devicesPoints(target)
        w.tick = gtk_widget_add_tick_callback(target, softTick,
                                              Unmanaged.passRetained(w).toOpaque(), nil)
    }
    return 1   // consumed: GTK must not jump on top of it
}

nonisolated(unsafe) private let softRunShare: @convention(c) (
    gpointer?, UnsafeMutablePointer<_GClosure>?
) -> Void = { data, _ in
    guard let data else { return }
    Unmanaged<SoftRun>.fromOpaque(data).release()
}

/// Attaches smooth scrolling to a scrolled window.
func softScroll(_ scroller: Widget!) {
    guard let adjustment = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))
    else { return }
    // GTK's own kinetic scrolling would otherwise fight this motion.
    gtk_scrolled_window_set_kinetic_scrolling(OpaquePointer(scroller), 0)
    let w = SoftRun(
        read: { gtk_adjustment_get_value(adjustment) },
        setDown: { gtk_adjustment_set_value(adjustment, $0) },
        upperLimit: {
            gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment)
        })
    let watcher = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL)
    // **In the capture phase, otherwise nothing arrives.** A controller on the scrolled
    // window runs in the bubble phase by default, i.e. *after* the scrolled window has
    // already handled the wheel and jumped. `CAPTURE` sees the event first.
    gtk_event_controller_set_propagation_phase(watcher, GTK_PHASE_CAPTURE)
    g_signal_connect_data(UnsafeMutableRawPointer(watcher), "scroll",
                          unsafeBitCast(wheelRotated, to: GCallback.self),
                          Unmanaged.passRetained(w).toOpaque(),
                          softRunShare, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(scroller, watcher)
}

// MARK: - Clicking without a button

nonisolated(unsafe) let jobAsClick: @convention(c) (
    UnsafeMutableRawPointer?, Int32, Double, Double, gpointer?
) -> Void = { _, _, _, _, data in
    guard let data else { return }
    Unmanaged<WorkItem>.fromOpaque(data).takeUnretainedValue().block()
}

/// Makes any widget clickable without making it a button.
///
/// **Why not a button.** An episode row contains its own button (the checkmark
/// toggle). A button inside a button is not safe in GTK, so the outer one uses a
/// gesture. On the Mac `.onTapGesture` is used instead of a `Button` for the same
/// reason.
///
/// `released` carries count and position: four arguments, not two.
///
/// - Parameter tastatur: **Also reachable by keyboard.** A gesture is not a button:
///   without this, Tab never reaches it, and Enter or Space do nothing. With `true`
///   the widget becomes focusable and takes both keys like a click, but only when
///   **it** has focus; a button inside keeps its own keys.
func onClick(_ target: Widget!, keyboard: Bool = false, _ block: @escaping () -> Void) {
    let gesture = gtk_gesture_click_new()
    let job = Unmanaged.passRetained(WorkItem(block)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(gesture), "released",
                          unsafeBitCast(jobAsClick, to: GCallback.self),
                          job, jobSharePublic, GConnectFlags(rawValue: 0))
    // `GtkEventController` is an incomplete type in C; Swift gets it as
    // `OpaquePointer`, which is what the gesture already is.
    gtk_widget_add_controller(target, gesture)
    guard keyboard else { return }
    gtk_widget_set_focusable(target, 1)
    let watcher = gtk_event_controller_key_new()
    let keysJob = Unmanaged.passRetained(WorkItem(block)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(watcher), "key-pressed",
                          unsafeBitCast(keyAsClick, to: GCallback.self),
                          keysJob, jobSharePublic, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(target, watcher)
}

/// Enter, keypad Enter, Space: the keys that trigger a button. GDK key values are
/// macros in C and not available in Swift.
nonisolated(unsafe) private let keyAsClick: @convention(c) (
    OpaquePointer?, UInt32, UInt32, GdkModifierType, gpointer?
) -> gboolean = { watcher, value, _, _, data in
    guard let data, [0xFF0D, 0xFF8D, 0x020, 0xFF80].contains(value),
          let watcher, let target = gtk_event_controller_get_widget(watcher),
          gtk_widget_has_focus(target) != 0 else { return 0 }
    Unmanaged<WorkItem>.fromOpaque(data).takeUnretainedValue().block()
    return 1
}

/// Reports when keyboard focus enters a widget or one of its children and when it
/// leaves entirely: the counterpart to ``onPointer`` for keyboard users. A move
/// **between** children reports nothing.
func focus(_ target: Widget!, inward: @escaping () -> Void, out: @escaping () -> Void) {
    let watcher = gtk_event_controller_focus_new()
    let a = Unmanaged.passRetained(WorkItem(inward)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(watcher), "enter",
                          unsafeBitCast(jobAsSignalPublic, to: GCallback.self),
                          a, jobSharePublic, GConnectFlags(rawValue: 0))
    let b = Unmanaged.passRetained(WorkItem(out)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(watcher), "leave",
                          unsafeBitCast(jobAsSignalPublic, to: GCallback.self),
                          b, jobSharePublic, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(target, watcher)
}

// MARK: - A run from zero to one

/// A run over a duration, in step with the screen. ``sanft(on:from:to:setzen:)``
/// moves **one** value; this one exposes the progress itself, for when several
/// layers depend on it.
private final class Run {
    let step: (Double) -> Void
    let done: () -> Void
    let duration: Double
    /// **The clock starts at the first frame, not at the request.** If a page is built
    /// and the fade starts right after, the first frame would otherwise come only after
    /// layout, which for a long episode list costs more than half the fade, and the
    /// motion would jump in midway.
    var beginning: Date?
    var linear = false

    init(duration: Double, step: @escaping (Double) -> Void, done: @escaping () -> Void) {
        self.duration = duration
        self.step = step
        self.done = done
    }
}

nonisolated(unsafe) private let runTick: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, data in
    guard let data else { return 0 }
    let l = Unmanaged<Run>.fromOpaque(data).takeUnretainedValue()
    let now = Date()
    let beginning = l.beginning ?? now
    l.beginning = beginning
    let t = min(now.timeIntervalSince(beginning) / l.duration, 1)
    // easeInOut, the same curve as `Animation.easeInOut` on the Mac; `linear` passes
    // the progress through raw when the caller applies its own curve.
    l.step(l.linear ? t : (t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2))
    if t >= 1 {
        l.done()
        Unmanaged<Run>.fromOpaque(data).release()
        return 0   // G_SOURCE_REMOVE
    }
    return 1
}

/// Calls `schritt` with the eased progress 0…1, then `done` once.
func runningCount(on widget: Widget!, duration: Double, linear: Bool = false,
            step: @escaping (Double) -> Void,
            done: @escaping () -> Void) {
    let run = Run(duration: duration, step: step, done: done)
    run.linear = linear
    _ = gtk_widget_add_tick_callback(widget, runTick,
                                     Unmanaged.passRetained(run).toOpaque(), nil)
}

// MARK: - Reporting size

final class MetricJob {
    let block: (Int32, Int32) -> Void
    init(_ block: @escaping (Int32, Int32) -> Void) { self.block = block }
}

nonisolated(unsafe) private let jobAsMass: @convention(c) (
    UnsafeMutableRawPointer?, Int32, Int32, gpointer?
) -> Void = { _, width, height, data in
    guard let data else { return }
    Unmanaged<MetricJob>.fromOpaque(data).takeUnretainedValue().block(width, height)
}

nonisolated(unsafe) private let massShare: @convention(c) (
    gpointer?, UnsafeMutablePointer<_GClosure>?
) -> Void = { data, _ in
    guard let data else { return }
    Unmanaged<MetricJob>.fromOpaque(data).release()
}

/// Reports the size of a drawing area. **`resize` carries width and height**
/// (four arguments), so again a dedicated callback.
func onSize(_ inputField: Widget!, _ block: @escaping (Int32, Int32) -> Void) {
    let job = Unmanaged.passRetained(MetricJob(block)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(inputField), "resize",
                          unsafeBitCast(jobAsMass, to: GCallback.self),
                          job, massShare, GConnectFlags(rawValue: 0))
}

// MARK: - Nothing heavy while a page is moving

/// **The stutter was never the curve.**
///
/// On the Mac, an `HStack` built every tile immediately, in the same frame in which
/// the page slides in. The motion was not hard; it dropped frames because half the
/// page was built next to it. A `LazyHStack` fixed that.
///
/// GTK has no lazy layout, and the heavy things here are different: decoding a 1600
/// pt wide header image, reloading the stylesheet for the tint (which restyles
/// **every** widget of the app), discarding half the page and rebuilding it with the
/// full data set from the server. All of that comes from the network and hits the
/// page right in the middle of the slide.
///
/// So it waits. The slide takes 0.45 s; whatever comes after is unaffected and the
/// motion keeps all its frames.
///
/// `nonisolated(unsafe)` because it belongs to GTK's main thread like everything
/// here; it is only touched from within ``onMainThread``.
enum PushLock {
    nonisolated(unsafe) private static var depth = 0
    nonisolated(unsafe) private static var since = Date.distantPast
    nonisolated(unsafe) private static var queue: [@Sendable () -> Void] = []

    /// **A lock that sticks is worse than none.** The frame clock does not guarantee
    /// that a run finishes: if the window is torn down meanwhile, the last callback
    /// never arrives and the app would never load an image again. A slide takes 0.45 s;
    /// anything claiming to slide for over a second is not sliding.
    static var drives: Bool {
        guard depth > 0 else { return false }
        guard Date().timeIntervalSince(since) < 1 else { depth = 0; return false }
        return true
    }

    static func begin() {
        depth += 1
        since = Date()
    }

    static func finish() {
        depth = max(depth - 1, 0)
        guard !drives, !queue.isEmpty else { return }
        let opened = queue
        queue = []
        // **Not in the last frame of the slide.** The callback still runs in the frame
        // clock; work here costs exactly the frame that completes the motion.
        onMainThread { for block in opened { block() } }
    }

    /// Locks for a fixed time. Needed for motions that **GTK** drives: a `GtkStack`
    /// does not signal when it is done, and when the player closes, the home page
    /// rebuilds itself right in the middle of the slide.
    static func of(_ seconds: Double) {
        begin()
        let job = Unmanaged.passRetained(WorkItem { finish() }).toOpaque()
        g_timeout_add_full(200, guint(seconds * 1000 + 30), jobInTimes,
                           job, jobShareRaw)
    }

    static func later(_ block: @escaping @Sendable () -> Void) {
        guard drives else { finish(); block(); return }
        queue.append(block)
    }
}

/// Like ``onMainThread``, but **not while a page is sliding**.
///
/// **Only for the many, not the few.** The header image, tint, title block and
/// season picker are what one looks at during the slide and must not pop in later;
/// they are also one item each, not twenty. What waits here are episode images,
/// cast and "similar": many small images arriving at the same moment. Not for
/// navigation itself, which triggers the slide.
func postPush(_ block: @escaping @Sendable () -> Void) {
    onMainThread { PushLock.later(block) }
}

/// A fetch that runs next to others, **instead of `async let`**.
///
/// Swift 6.2.1 on Windows terminates the app with "freed pointer was not the last
/// allocation" (0xC0000409) when three `async let` stand side by side and one of
/// them carries a large value such as `Item?`: the task allocator frees in the
/// wrong order. Linux is unaffected, and with explicit tasks Windows is fine too.
/// So no `async let` here; all concurrency goes through this helper, awaited with
/// `.value`.
@discardableResult
func besideFrom<T: Sendable>(_ labor: @escaping @Sendable () async -> T) -> Task<T, Never> {
    Task.detached(operation: labor)
}


nonisolated(unsafe) private let jobInTimes: @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    Unmanaged<WorkItem>.fromOpaque(data).takeUnretainedValue().block()
    return 0   // G_SOURCE_REMOVE
}

nonisolated(unsafe) private let jobShareRaw: @convention(c) (gpointer?) -> Void = { data in
    guard let data else { return }
    Unmanaged<WorkItem>.fromOpaque(data).release()
}


/// Once after a delay, on the main thread. For throttling: computing on every
/// scroll signal means sixty times per second.
func postDeadline(_ seconds: Double, _ block: @escaping () -> Void) {
    let job = Unmanaged.passRetained(WorkItem(block)).toOpaque()
    g_timeout_add_full(200, guint(seconds * 1000), jobInTimes, job, jobShareRaw)
}

/// Reports when a scroller reaches the **bottom**.
///
/// `edge-reached` passes the reached edge as a second argument, exactly the shape
/// that crashed the app when it went through ``signal``. Hence a dedicated
/// callback, and only the bottom edge (`GTK_POS_BOTTOM` = 3) is reported.
func edgeReport(_ scroller: Widget!, _ block: @escaping () -> Void) {
    let job = Unmanaged.passRetained(WorkItem(block)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(scroller), "edge-reached",
                          unsafeBitCast(jobAnEdge, to: GCallback.self),
                          job, jobSharePublic, GConnectFlags(rawValue: 0))
}

nonisolated(unsafe) private let jobAnEdge: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, gpointer?
) -> Void = { _, border, data in
    guard let data, border == GTK_POS_BOTTOM.rawValue else { return }
    Unmanaged<WorkItem>.fromOpaque(data).takeUnretainedValue().block()
}

/// Reports **real** pointer movement over a widget.
///
/// **Why a threshold.** The Mac explicitly uses "on every real movement > 2 px"
/// (`PlayerScreen.swift`). Without it, a remote session keeps sending the pointer
/// position even when nobody touches the mouse; each of those reports brought the
/// controls back and they never faded out again.
///
/// The two points also cover the jitter of a resting finger or an optical mouse;
/// without them noise already counts.
func onMotion(_ target: Widget!, _ block: @escaping () -> Void) {
    let watcher = gtk_event_controller_motion_new()
    let a = Unmanaged.passRetained(MotionGuard(block)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(watcher), "motion",
                          unsafeBitCast(guardAsMotion, to: GCallback.self),
                          a, guardShare, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(target, watcher)
}

/// Remembers where the pointer was last.
final class MotionGuard {
    let block: () -> Void
    var x: Double = -1
    var y: Double = -1
    init(_ block: @escaping () -> Void) { self.block = block }
}

nonisolated(unsafe) private let guardAsMotion: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { _, x, y, data in
    guard let data else { return }
    let w = Unmanaged<MotionGuard>.fromOpaque(data).takeUnretainedValue()
    // **The mark only moves when it fires.**
    //
    // If it were updated on *every* report, only the distance to the previous report
    // would be checked, and slow dragging would stay below the threshold forever: the
    // controls faded out although the mouse was moving. With the mark fixed, the
    // distance accumulates until the two points are reached, which is what "real
    // movement" means.
    guard w.x >= 0 else { w.x = x; w.y = y; return }
    guard abs(x - w.x) > 2 || abs(y - w.y) > 2 else { return }
    w.x = x
    w.y = y
    w.block()
}

nonisolated(unsafe) private let guardShare: @convention(c) (
    gpointer?, UnsafeMutablePointer<_GClosure>?
) -> Void = { data, _ in
    guard let data else { return }
    Unmanaged<MotionGuard>.fromOpaque(data).release()
}

/// Reports a right click, the pointer equivalent of a long press.
///
/// The same gesture as ``onClick``, set to the right button and to `pressed`: a
/// context menu appears on press, not on release.
func rightClick(_ target: Widget!, _ block: @escaping () -> Void) {
    let gesture = gtk_gesture_click_new()
    gtk_gesture_single_set_button(gesture, 3)
    let job = Unmanaged.passRetained(WorkItem(block)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(gesture), "pressed",
                          unsafeBitCast(jobAsClick, to: GCallback.self),
                          job, jobSharePublic, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(target, gesture)
    // **The same menu from the keyboard:** Menu key or Shift+F10, the two ways GTK and
    // every desktop environment know.
    let watcher = gtk_event_controller_key_new()
    let keysJob = Unmanaged.passRetained(WorkItem(block)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(watcher), "key-pressed",
                          unsafeBitCast(keyAsContext, to: GCallback.self),
                          keysJob, jobSharePublic, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(target, watcher)
}

/// Reports a long press, the touch form of the right click, like the long press on
/// iPhone.
///
/// **The press then belongs to this gesture**: it claims the sequence so that
/// the release does not also count as a click and start the row.
func longPress(_ target: Widget!, _ block: @escaping () -> Void) {
    let gesture = gtk_gesture_long_press_new()
    let job = Unmanaged.passRetained(WorkItem(block)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(gesture), "pressed",
                          unsafeBitCast(jobAsLongPress, to: GCallback.self),
                          job, jobSharePublic, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(target, gesture)
}

/// `pressed` of a `GtkGestureLongPress`: `(gesture, x, y, data)`.
nonisolated(unsafe) private let jobAsLongPress: @convention(c) (
    OpaquePointer?, Double, Double, gpointer?
) -> Void = { gesture, _, _, data in
    guard let data else { return }
    if let gesture { _ = gtk_gesture_set_state(gesture, GTK_EVENT_SEQUENCE_CLAIMED) }
    Unmanaged<WorkItem>.fromOpaque(data).takeUnretainedValue().block()
}

nonisolated(unsafe) private let keyAsContext: @convention(c) (
    OpaquePointer?, UInt32, UInt32, GdkModifierType, gpointer?
) -> gboolean = { watcher, value, _, condition, data in
    let shift = (condition.rawValue & GDK_SHIFT_MASK.rawValue) != 0
    guard let data, value == 0xFF67 || (value == 0xFFC7 && shift),   // menu key, F10
          let watcher, let target = gtk_event_controller_get_widget(watcher),
          gtk_widget_has_focus(target) != 0 else { return 0 }
    Unmanaged<WorkItem>.fromOpaque(data).takeUnretainedValue().block()
    return 1
}

// MARK: - What assistive technology learns

/// Gives a custom control a name.
///
/// **Controls not built from standard widgets do not inherit their accessibility.**
/// A drawn button is otherwise just "button", a seek bar a nameless rectangle. On
/// Apple this is `accessibilityLabel`; in GTK4 it is
/// `GTK_ACCESSIBLE_PROPERTY_LABEL`. The short form of
/// ``bedienhilfe(_:name:selected:checkmark:)``.
func caption(_ target: Widget!, _ name: String) {
    help(target, name: name)
}

/// How a checkmark sounds to assistive technology. `partly` is the box of a season
/// of which only some episodes are selected.
enum CheckmarkState { case an, off, partly }

/// **What assistive technology learns about an element, in one place.**
///
/// Name, "selected" and "checked". On Apple these are `accessibilityLabel` and the
/// traits `.isSelected`/`.isToggle`; here `GTK_ACCESSIBLE_PROPERTY_LABEL`,
/// `GTK_ACCESSIBLE_STATE_SELECTED` and `GTK_ACCESSIBLE_STATE_CHECKED`. Anything
/// left `nil` is not touched, so code that only updates the state need not repeat
/// the name.
///
/// **The convenient forms are variadic and therefore unavailable to Swift.**
/// `gtk_accessible_update_property`/`…_state` take pairs of any length; the
/// `…_value` forms take two fields and are callable. The value types are looked up
/// by name instead of rebuilding the `G_TYPE_STRING` macros and relatives.
/// **Every state goes in as `gint`**, including the true/false value of `SELECTED`:
/// GTK 4.22 reads it with `g_value_get_int`, and a `gboolean` or the
/// `GtkAccessibleTristate` enum ends in a `CRITICAL` line (verified with a small C
/// test against GTK 4.22).
func help(_ target: Widget!, name: String? = nil, selected: Bool? = nil,
                 checkmark: CheckmarkState? = nil) {
    guard let target else { return }
    let element = OpaquePointer(target)
    if let name {
        var characteristic = GTK_ACCESSIBLE_PROPERTY_LABEL
        var value = GValue()
        g_value_init(&value, g_type_from_name("gchararray"))
        name.withCString { g_value_set_string(&value, $0) }
        gtk_accessible_update_property_value(element, 1, &characteristic, &value)
        g_value_unset(&value)
    }
    if let selected {
        var condition = GTK_ACCESSIBLE_STATE_SELECTED
        var value = GValue()
        g_value_init(&value, g_type_from_name("gint"))
        g_value_set_int(&value, selected ? 1 : 0)
        gtk_accessible_update_state_value(element, 1, &condition, &value)
        g_value_unset(&value)
    }
    if let checkmark {
        let threeValue: GtkAccessibleTristate = switch checkmark {
        case .an:    GTK_ACCESSIBLE_TRISTATE_TRUE
        case .off:   GTK_ACCESSIBLE_TRISTATE_FALSE
        case .partly: GTK_ACCESSIBLE_TRISTATE_MIXED
        }
        var condition = GTK_ACCESSIBLE_STATE_CHECKED
        var value = GValue()
        g_value_init(&value, g_type_from_name("gint"))
        g_value_set_int(&value, gint(threeValue.rawValue))
        gtk_accessible_update_state_value(element, 1, &condition, &value)
        g_value_unset(&value)
    }
}


/// **Reduce motion**: GTK's `gtk-enable-animations`, the counterpart of
/// `Theme.motionReduced` on the Mac.
///
/// Stylesheet transitions, `GtkStack` and `GtkRevealer` follow it by themselves;
/// our own frame-clock fades do not. They query it on every run, because the
/// setting can change at runtime. The convenient `g_object_get` is variadic and
/// unavailable to Swift, hence a `GValue` as in ``beschriften(_:_:)``.
func motionReduced() -> Bool {
    guard let settings = gtk_settings_get_default() else { return false }
    var value = GValue()
    g_value_init(&value, g_type_from_name("gboolean"))
    g_object_get_property(unsafeBitCast(settings, to: UnsafeMutablePointer<GObject>.self),
                          "gtk-enable-animations", &value)
    let an = g_value_get_boolean(&value) != 0
    g_value_unset(&value)
    return !an
}


/// Puts text on the clipboard.
///
/// GTK4 gets the clipboard through the widget's display; there is no global one.
/// So a widget that is currently in a window must be passed.
func inClipboard(_ text: String, an widget: Widget!) {
    guard let display = gtk_widget_get_display(widget) else { return }
    let store = gdk_display_get_clipboard(display)
    gdk_clipboard_set_text(store, text)
}

@inline(__always) func asStack(_ w: Widget!) -> OpaquePointer! {
    OpaquePointer(w)
}

/// The `GtkRevealer`, for lists that expand and collapse in the page flow.
@inline(__always) func asExpand(_ w: Widget!) -> OpaquePointer! {
    OpaquePointer(w)
}

/// **When someone grabs a control and lets go.**
///
/// For the seek bar: while the mouse is on it, the controls must not fade out and
/// the position must not be overwritten from the server. On the Mac `Zeitregler`
/// provides `atSlider` for this; here nothing comparable exists, so the gesture
/// itself is used, with **`pressed` and `released` on the same one** so both refer
/// to the same press.
func onGrip(_ target: Widget!, _ block: @escaping (Bool) -> Void) {
    // **A drag gesture, not a click gesture.** `GtkGestureClick` sends no `released`
    // once the pointer moves beyond the drag threshold, i.e. never while seeking.
    // `atSlider` then stayed set: the controls no longer faded out and the handle
    // stayed in the accent color. `drag-begin` and `drag-end` always come in pairs.
    let gesture = gtk_gesture_drag_new()
    let down = Unmanaged.passRetained(WorkItem { block(true) }).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(gesture), "drag-begin",
                          unsafeBitCast(jobAsMotionPublic, to: GCallback.self),
                          down, jobSharePublic, GConnectFlags(rawValue: 0))
    let up = Unmanaged.passRetained(WorkItem { block(false) }).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(gesture), "drag-end",
                          unsafeBitCast(jobAsMotionPublic, to: GCallback.self),
                          up, jobSharePublic, GConnectFlags(rawValue: 0))
    gtk_event_controller_set_propagation_phase(gesture, GTK_PHASE_CAPTURE)
    gtk_widget_add_controller(target, gesture)
}


/// **Opens a URL in the default browser.**
///
/// For when the server has no trailer and only a web link remains; the Mac uses
/// `NSWorkspace.shared.open` (`Sources/macOS/DetailView.swift`).
///
/// `g_app_info_launch_default_for_uri` instead of `GtkUriLauncher`: the launcher is
/// asynchronous and wants a parent window, while this call is enough. A failure is
/// silent: a message would not help someone without a browser.
func browser(_ target: URL) {
    var error: UnsafeMutablePointer<GError>?
    _ = g_app_info_launch_default_for_uri(target.absoluteString, nil, &error)
    if let error { g_error_free(error) }
}

/// Shows a file in the file manager, selected: the way to pass it on where there is
/// no share menu.
func fileManagerShow(_ file: URL) {
    let f = g_file_new_for_path(file.path)
    let starter = gtk_file_launcher_new(f)
    gtk_file_launcher_open_containing_folder(starter, nil, nil, nil, nil)
    g_object_unref(UnsafeMutableRawPointer(starter))
    g_object_unref(UnsafeMutableRawPointer(f))
}
