#if DEBUG
import CGtk
import Foundation

/// **Frame times on the real, signed-in app** (`heimprobe` via the remote console): the home
/// page scrolled top to bottom and back, then page switches between Start and Movies. It
/// reads the frame interval of the window's frame clock (no own drawing), so header edge,
/// posters, shadows and anything that costs per frame show up as a long interval.
final class HomeProbe: @unchecked Sendable {
    nonisolated(unsafe) static var ongoing: HomeProbe?

    private unowned let app: App
    private enum Phase: String { case scroll, switching, done }
    private var phase = Phase.scroll
    private var begin: gint64 = 0
    private var last: gint64 = 0
    private var intervals: [Double] = []
    private var adjustment: UnsafeMutablePointer<GtkAdjustment>?
    private var lastSwitch: gint64 = 0
    private var onMovies = false

    init(app: App) { self.app = app }

    private static func scroller(in widget: Widget?) -> Widget? {
        guard let widget else { return nil }
        if g_type_check_instance_is_a(UnsafeMutablePointer<GTypeInstance>(OpaquePointer(widget)), gtk_scrolled_window_get_type()) != 0,
           let adj = gtk_scrolled_window_get_vadjustment(OpaquePointer(widget)),
           gtk_adjustment_get_upper(adj) - gtk_adjustment_get_page_size(adj) > 200 { return widget }
        var child = gtk_widget_get_first_child(widget)
        while let c = child {
            if let found = scroller(in: c) { return found }
            child = gtk_widget_get_next_sibling(c)
        }
        return nil
    }

    func start() {
        guard HomeProbe.ongoing == nil, let cover = app.windowCover else { return }
        HomeProbe.ongoing = self
        app.show(.start)
        postDeadline(1.0) { [self] in
            adjustment = HomeProbe.scroller(in: app.pagesWidget).flatMap { gtk_scrolled_window_get_vadjustment(OpaquePointer($0)) }
            if adjustment == nil { AppLog.writeOut("[Heimprobe] keine scrollbare Startseite gefunden") }
            begin = g_get_monotonic_time(); last = 0; intervals = []
            gtk_widget_add_tick_callback(cover, homeProbeTick, Unmanaged.passUnretained(self).toOpaque(), nil)
        }
    }

    fileprivate func tick(_ clock: OpaquePointer?) -> Bool {
        let time = clock.map { gdk_frame_clock_get_frame_time($0) } ?? g_get_monotonic_time()
        if last != 0 { intervals.append(Double(time - last) / 1000) }
        last = time
        let seconds = Double(time - begin) / 1_000_000
        switch phase {
        case .scroll:
            if let adj = adjustment {
                let range = gtk_adjustment_get_upper(adj) - gtk_adjustment_get_page_size(adj)
                let t = (seconds / 4).truncatingRemainder(dividingBy: 1)
                gtk_adjustment_set_value(adj, range * (t < 0.5 ? t * 2 : 2 - t * 2))
            }
            if seconds >= 8 { finish("scroll"); phase = .switching; begin = time; lastSwitch = time; intervals = []; last = 0 }
        case .switching:
            if time - lastSwitch > 600_000 {
                lastSwitch = time
                onMovies.toggle()
                app.show(onMovies ? .movies : .start)
            }
            if seconds >= 6 { finish("switching"); phase = .done }
        case .done:
            app.show(.start)
            HomeProbe.ongoing = nil
            return false
        }
        return true
    }

    private func finish(_ name: String) {
        let sorted = intervals.sorted()
        guard !sorted.isEmpty else { return }
        func p(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        let slow = sorted.filter { $0 > 20 }.count
        AppLog.writeOut(String(format: "[Heimprobe] %@: %d Frames, Abstand median %.1f p95 %.1f p99 %.1f max %.1f ms, %d ueber 20 ms",
                               locale: Locale(identifier: "en_US_POSIX"), name, sorted.count,
                               p(0.5), p(0.95), p(0.99), sorted.last ?? 0, slow))
    }
}

nonisolated(unsafe) private let homeProbeTick: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, clock, data in
    guard let data else { return 0 }
    let probe = Unmanaged<HomeProbe>.fromOpaque(data).takeUnretainedValue()
    return probe.tick(clock) ? 1 : 0
}
#endif
