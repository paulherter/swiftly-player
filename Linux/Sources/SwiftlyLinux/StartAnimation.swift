// **Only where rlottie is built.** On Linux `Werkzeuge/rlottie-build.sh`
// builds the library; there is no build for Windows yet. Without it the
// start animation is skipped and the app goes straight to sign-in, which is
// not an error, just less polished.
#if canImport(CRlottie)
import CGtk
import CRlottie
import Foundation

/// **The start animation: the same file as on iPhone, TV and Mac.**
///
/// The template is a Lottie file from After Effects: the triangle rises, then
/// the letters slide out. `Sources/Shared/StartAnimation.swift` explains why
/// it is not rebuilt by hand: every keyframe carries its own Bezier easing,
/// and recomputing those manually gives a motion that is *almost* right,
/// which is more noticeable than an extra package.
///
/// Apple plays it with the Lottie package. GTK cannot, so **rlottie** renders
/// the frames and Cairo paints them. rlottie writes BGRA with premultiplied
/// alpha, which is exactly what `CAIRO_FORMAT_ARGB32` expects on a
/// little-endian machine, so nothing is reordered.
///
/// **Driven by the frame clock, not a timer**, as everywhere here:
/// `g_timeout_add` would run 62 frames on every screen.
final class StartAnimation: @unchecked Sendable {

    private var tier: OpaquePointer?
    /// **Allocated by hand, not a field.**
    ///
    /// `cairo_image_surface_create_for_data` keeps the pointer it is given. A
    /// Swift field may move at any time, and the pointer from
    /// `withUnsafeMutableBufferPointer` is only valid inside the block; handing
    /// it out is the bug that crashed the app on the first frame.
    private var points: UnsafeMutablePointer<UInt32>?
    private var mass: Int = 0
    private var divider: Int32 = 1
    /// The frame that should be drawn now.
    fileprivate var image = 0
    private var images = 0
    private var duration = 1.0
    private var beginning = Date()
    private let done: () -> Void
    private var alreadyReady = false
    private var started = false
    /// **With "reduce motion" the still frame, not the animation**, as on Apple
    /// (`Sources/Shared/StartAnimation.swift`): the mark appears immediately in
    /// its final position and stays for `postRun`, then the app fades in as
    /// usual.
    private var stillImage = false
    private let postRun = 0.5
    private var beats = 0
    /// Which frame is already in the surface.
    private var computed = -1

    /// **Is the drawing area still alive?** See the `destroy` job in
    /// ``init(done:)``.
    private var lives = true

    let display: Widget

    /// `nil` if the template is missing or rlottie cannot read it. Then there is
    /// no animation and no crash.
    init?(done: @escaping () -> Void) {
        guard let source = StartAnimation.preStatus,
              let text = try? String(contentsOfFile: source, encoding: .utf8) else { return nil }
        self.done = done
        // The second name is the cache key, the third the location for images loaded
        // later; there are none.
        guard let tier = lottie_animation_from_data(text, "swiftly-start", "") else { return nil }
        self.tier = tier
        images = Int(lottie_animation_get_totalframe(tier))
        duration = lottie_animation_get_duration(tier)
        guard images > 0, duration > 0 else {
            lottie_animation_destroy(tier)
            return nil
        }

        let inputField: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(inputField, "swiftly-blank")
        gtk_widget_set_hexpand(inputField, 1)
        gtk_widget_set_vexpand(inputField, 1)
        display = inputField!
        gtk_drawing_area_set_draw_func(asCharacter(inputField), startDraw,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        // **The drawing area holds the animation, not `App`.**
        //
        // The draw callback gets `self` *unretained*, and the animation was held
        // only by the tick (which releases itself at the end) and by
        // `App.startAnimation`. `startImageDistance()` sets that to `nil` **while the
        // image is still fading out**: the surface stays visible and keeps being
        // drawn after `deinit` has called `lottie_animation_destroy`. The next draw
        // then rendered into freed memory:
        //
        //     rlottie::Animation::renderSync(unsigned __int64, rlottie::Surface, bool)
        //
        // It crashed every third or fourth start with nothing in the log. Same bug
        // as in ``Backdrop``, at the same kind of spot.
        signal(inputField, "destroy") { self.lives = false }
        // **Start when the widget is actually on screen.**
        //
        // `gtk_widget_add_tick_callback` only requests frames if the widget already
        // has a frame clock, i.e. once it is mapped. The call used to come right
        // after `gtk_window_present`, which is not enough on Wayland because
        // mapping happens later. Measured: not a single tick. It still ran for a
        // while because a layout loop elsewhere kept forcing frames; when that was
        // gone, the animation stalled.
        //
        // `map` is the point where it is safe.
        signal(inputField, "map") { [weak self] in self?.startMoving() }

    }

    deinit {
        if let points { points.deallocate() }
        if let tier { lottie_animation_destroy(tier) }
    }

    /// The template sits next to the app in the same `Resources` folder as the
    /// application icon, derived from the binary path.
    private static var preStatus: String? {
        Platform.bundled("startanimation.json")
    }

    /// **Start once the window is actually up.**
    ///
    /// The frame tick used to be attached in `init`. Measured: it ran exactly
    /// once, at 0.05 s, and never again. A widget that is in no window yet has no
    /// frame clock; GTK remembers the callback but the clock requests no frames
    /// for it, and anything that gets through afterwards is luck.
    ///
    /// Apple has the same lesson for SwiftUI ("start once the page is really
    /// up"), where a `Task.sleep` was the race and here it is the frame clock.
    ///
    /// **The tick holds the animation:** the deadline can release it from `App`
    /// while a tick is still pending. It is freed when the tick unregisters.
    func startMoving() {
        guard !started else { return }
        started = true
        beginning = Date()
        stillImage = motionReduced()
        _ = gtk_widget_add_tick_callback(display, startTick,
                                         Unmanaged.passRetained(self).toOpaque(), nil)
    }

    /// One tick: which frame is due now?
    ///
    /// **By the clock, not by a counter.** A counter that advances one frame per
    /// tick runs 2.5 times too fast at 144 Hz; the template has its own frame
    /// rate, and the clock is the common denominator.
    fileprivate func proceed() -> Bool {
        guard !alreadyReady else { return false }
        beats += 1
        if beats % 40 == 1 {
        }
        let since = Date().timeIntervalSince(beginning)
        let new = stillImage ? images - 1 : min(Int(since / duration * Double(images)), images - 1)
        if new != image {
            image = new
            gtk_widget_queue_draw(display)
        }
        if since >= (stillImage ? postRun : duration) {
            complete()
            return false
        }
        return true
    }

    /// **Exactly once**, whether from the end of the animation or the deadline;
    /// the same guarantee the `Einmal` class gives on Apple.
    func complete() {
        guard !alreadyReady else { return }
        alreadyReady = true
        done()
    }

    /// Renders the current frame and returns a **fresh** surface over it.
    ///
    /// **Why a new one each time.** One surface kept across frames and marked
    /// dirty after each render crashes: Cairo creates a snapshot of a surface that
    /// has served as a source once, and `cairo_surface_mark_dirty` then aborts:
    ///
    ///     cairo-surface.c:1739: Assertion
    ///     `! _cairo_surface_has_snapshots (surface)' failed.
    ///
    /// The app crashed on the second frame, so a second tick never came because
    /// there was no process left to tick.
    ///
    /// `cairo_image_surface_create_for_data` copies nothing, it only wraps the
    /// buffer. One per frame costs almost nothing and has no history.
    fileprivate func draw(_ cr: OpaquePointer, _ width: Int32, _ height: Int32) {
        guard lives, let tier else { return }
        let t = Scaling.grid(display)
        // **520 pt edge, as on the Mac** (`StartAnimation.swift`: the window is
        // smaller than a TV and larger than a phone; 520 sits between). It was 360,
        // a pure performance cap unrelated to that number, so the mark looked
        // smaller at startup than there.
        //
        // The `min` against the surface stays: in a window smaller than 520 it must
        // not run past the edge.
        let page = min(Int(min(width, height)), 520)
        let new = page * Int(t)
        guard new > 0 else { return }

        if new != mass || divider != t || points == nil {
            if let alt = points { alt.deallocate() }
            mass = new
            divider = t
            let inputField = UnsafeMutablePointer<UInt32>.allocate(capacity: new * new)
            inputField.initialize(repeating: 0, count: new * new)
            points = inputField
            computed = -1
        }
        guard let points else { return }

        if computed != image {
            computed = image
            lottie_animation_render(tier, size_t(image), points,
                                    size_t(mass), size_t(mass), size_t(mass * 4))
        }

        guard let area = cairo_image_surface_create_for_data(
            UnsafeMutableRawPointer(points).assumingMemoryBound(to: UInt8.self),
            CAIRO_FORMAT_ARGB32, Int32(mass), Int32(mass), Int32(mass * 4))
        else { return }
        defer { cairo_surface_destroy(area) }

        let border = Double(mass) / Double(divider)
        cairo_save(cr)
        cairo_translate(cr, (Double(width) - border) / 2, (Double(height) - border) / 2)
        cairo_scale(cr, 1 / Double(divider), 1 / Double(divider))
        cairo_set_source_surface(cr, area, 0, 0)
        cairo_paint(cr)
        cairo_restore(cr)
    }

}

nonisolated(unsafe) private let startTick: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, data in
    guard let data else { return 0 }
    let a = Unmanaged<StartAnimation>.fromOpaque(data)
    if a.takeUnretainedValue().proceed() { return 1 }
    a.release()
    return 0   // G_SOURCE_REMOVE
}

nonisolated(unsafe) private let startDraw: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, width, height, data in
    guard let cr, let data else { return }
    Unmanaged<StartAnimation>.fromOpaque(data).takeUnretainedValue()
        .draw(cr, width, height)
}

#else

import CGtk

/// **Without rlottie there is no start animation**, and call sites must not
/// care. The placeholder has the same initializer as the original but fails,
/// so the branch in ``App`` never runs and contains no `#if`.
final class StartAnimation {
    let display: Widget
    init?(done: @escaping () -> Void) { return nil }
    /// Called by the deadline in ``App``. There is nothing to finish here.
    func complete() {}
}

#endif
