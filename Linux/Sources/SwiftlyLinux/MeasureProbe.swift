#if DEBUG
import CGtk
import Foundation

/// **A probe page for frame time while scrolling; debug builds only, only via
/// the ``Fernsteuerpult``.**
///
/// Built from the same parts as the movie grid (`gridBuild`,
/// `framedImage`, `tileWrapper`, poster 300 × 450 as from the server) but
/// without a server: the image comes from a file. This allows measuring, on a
/// machine without a login, what a grid with 4, 20 or 60 tiles costs per frame,
/// at factor 1 and with the wrapper from ``Skalierung``.
///
/// ```
/// echo probe:60 > %TEMP%\swiftly-zeige          # page with 60 tiles
/// echo messreihe > %TEMP%\swiftly-zeige          # 1.0 and 1.5 each at 4/20/60
/// ```
/// The image is at `%TEMP%\swiftly-probe.jpg` (Linux `/tmp`); if it is missing,
/// the frames stay empty and the output line says so.
///
/// Measured on the window's frame clock: from the end of the `update` phase
/// (where the scroll step is set) to `after-paint`, i.e. layout, drawing and
/// handing off one frame. Plus the interval between two frames.
final class MeasureProbe: @unchecked Sendable {
    nonisolated(unsafe) static var ongoing: MeasureProbe?

    private unowned let app: App
    private var steps: [(factor: Double, tiles: Int)]
    private let prior: Double
    private var page: Widget?
    private var scroller: Widget?
    private var firstImage: Widget?
    private var grid: Widget?

    private enum Phase { case structure, roles, pause, part, done }
    private var phase = Phase.structure
    private var until: gint64 = 0
    private var images = 0
    private var bearing = 1.0
    private var beginning: gint64 = 0
    private var labor: [Double] = []
    private var spacings: [Double] = []
    private var lastTime: gint64 = 0
    nonisolated(unsafe) private static var clockConnected = false

    /// `withoutImage`, `ohneEcke`, `ohneText`, `ungerastet`, `double`: to break down
    /// the cost of a tile.
    private let options: Set<String>

    init(app: App, steps: [(Double, Int)], options: Set<String> = []) {
        self.app = app
        self.options = options
        self.steps = steps.map { (factor: $0.0, tiles: $0.1) }
        self.prior = Scaling.userShare
    }

    static var imageFile: URL {
        #if os(Windows)
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("swiftly-probe.jpg")
        #else
        URL(fileURLWithPath: "/tmp/swiftly-probe.jpg")
        #endif
    }

    // MARK: The page

    /// Builds the probe page with `count` tiles and shows it.
    static func pageShow(_ app: App, tiles count: Int, options: Set<String> = []) -> (page: Widget, scroller: Widget, grid: Widget, image: Widget?) {
        if let alt = gtk_stack_get_child_by_name(OpaquePointer(app.pages), "probe") {
            gtk_stack_remove(OpaquePointer(app.pages), alt)
        }
        let data = try? Data(contentsOf: imageFile)
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        // In the movie grid the sidebar sits next to it; here only its space.
        let bar = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_add_css_class(bar, "swiftly-seitenleiste")
        gtk_widget_set_size_request(bar, Int32(Theme.sidebarWidth), -1)
        append(rail, bar)

        let scroller = app.pagesScroller()
        let frameRect = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_margin_start(frameRect, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_end(frameRect, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_top(frameRect, Int32(Theme.edgeSpacing))
        let grid = app.gridBuild()
        var firstOne: Widget?
        for i in 0..<count {
            let (cage, image) = framedImage(width: Theme.tileWidth, height: Theme.tileHeight,
                                               style: options.contains("ohneEcke") ? "swiftly-probe" : "swiftly-plakat")
            if options.contains("ohneEcke") { gtk_widget_set_overflow(cage, GTK_OVERFLOW_VISIBLE) }
            // One texture per tile, as in the real grid, where each movie has its own
            // poster. Same as the movie grid (``Skalierung/bildkante(_:)``); `doppelt`
            // measures the previous state, always double the tile edge.
            let border = options.contains("doppelt")
                ? Theme.tileHeight * 2 : Scaling.imageEdge(Theme.tileHeight)
            if !options.contains("ohneBild"), let data, let texture = textureUnpack(data, border: border).texture {
                gtk_picture_set_paintable(OpaquePointer(image), texture)
                g_object_unref(UnsafeMutableRawPointer(texture))
            }
            if i % 3 == 0 { _ = barPut(cage, width: Theme.tileWidth, share: 0.4) }
            if firstOne == nil { firstOne = image }
            let tile = app.tileWrapper(image: cage, width: Theme.tileWidth,
                                          top: options.contains("ohneText") ? "" : "Probe \(i + 1)",
                                          bottom: options.contains("ohneText") ? nil : "2026") {}
            gtk_widget_set_halign(tile, GTK_ALIGN_CENTER)
            gtk_widget_set_valign(tile, GTK_ALIGN_START)
            gtk_flow_box_insert(OpaquePointer(grid), tile, -1)
        }
        append(frameRect, grid)
        gtk_scrolled_window_set_child(OpaquePointer(scroller), frameRect)
        append(rail, scroller)
        gtk_stack_add_named(OpaquePointer(app.pages), rail, "probe")
        gtk_stack_set_visible_child_name(OpaquePointer(app.pages), "probe")
        AppLog.writeOut("[Probe] Seite mit \(count) Kacheln \(options.sorted()), Bild \(data.map { "\($0.count) Bytes" } ?? "FEHLT")")
        return (rail!, scroller!, grid!, firstOne)
    }

    // MARK: The row

    func start() {
        MeasureProbe.ongoing = self
        // Measured on the whole screen, the way a grid is viewed.
        gtk_window_maximize(asWindow(app.window))
        _ = gtk_widget_add_tick_callback(app.window, messTick, nil, nil)
        nextStep()
    }

    private func nextStep() {
        guard let step = steps.first else {
            phase = .done
            app.scaleSurface(prior)
            AppLog.writeOut("[Probe] Messreihe fertig")
            return
        }
        app.scaleSurface(step.factor)
        let (s, sc, r, b) = MeasureProbe.pageShow(app, tiles: step.tiles, options: options)
        page = s; scroller = sc; grid = r; firstImage = b
        phase = .structure
        until = g_get_monotonic_time() + 2_000_000
    }

    fileprivate func tick(_ clock: OpaquePointer?) -> Bool {
        // Once per process; the callbacks ask ``ongoing`` instead of a stored pointer,
        // so a finished row is simply gone.
        if !MeasureProbe.clockConnected, let clock {
            MeasureProbe.clockConnected = true
            g_signal_connect_data(UnsafeMutableRawPointer(clock), "update",
                                  unsafeBitCast(clockUpdate, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
            g_signal_connect_data(UnsafeMutableRawPointer(clock), "after-paint",
                                  unsafeBitCast(clockPostDraw, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
        }
        let now = g_get_monotonic_time()
        switch phase {
        case .done:
            MeasureProbe.ongoing = nil
            return false
        case .structure:
            if now >= until { measurementBegin(.roles) }
        case .roles:
            guard let scroller else { break }
            let adjustment = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))
            let max = gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment)
            var value = gtk_adjustment_get_value(adjustment) + 15 * bearing
            if value > max { value = max; bearing = -1 }
            if value < 0 { value = 0; bearing = 1 }
            // Like ``softScroll``: to whole device points.
            if !options.contains("ungerastet") {
                let divider = Scaling.devicesPoints(scroller)
                value = (value * divider).rounded() / divider
            }
            gtk_adjustment_set_value(adjustment, value)
            images += 1
            if images == 1 { visibleCount(max) }
            if images >= 180 { evaluate("rollen"); phase = .pause; until = now + 500_000 }
        case .pause:
            if now >= until { measurementBegin(.part) }
        case .part:
            // One tile changes, the rest stays: shows whether only its area is redrawn or
            // the whole window.
            if let firstImage { gtk_widget_set_opacity(firstImage, images % 2 == 0 ? 0.98 : 1) }
            images += 1
            if images >= 120 {
                if let firstImage { gtk_widget_set_opacity(firstImage, 1) }
                evaluate("teil")
                steps.removeFirst()
                nextStep()
            }
        }
        return true
    }

    private func measurementBegin(_ new: Phase) {
        phase = new
        images = 0
        labor.removeAll()
        spacings.removeAll()
        lastTime = 0
    }

    private var visible = 0
    private var scrollBar = 0.0

    private func visibleCount(_ max: Double) {
        guard let scroller else { return }
        scrollBar = max
        let height = Float(gtk_widget_get_height(scroller))
        var figure = 0
        var tile = grid.flatMap { gtk_widget_get_first_child($0) }
        while let k = tile {
            var r = graphene_rect_t()
            if gtk_widget_compute_bounds(k, scroller, &r) != 0,
               r.origin.y + r.size.height > 0, r.origin.y < height { figure += 1 }
            tile = gtk_widget_get_next_sibling(k)
        }
        visible = figure
    }

    fileprivate func updateEnd() {
        guard phase == .roles || phase == .part else { return }
        beginning = g_get_monotonic_time()
    }

    fileprivate func drawEnd(_ clock: OpaquePointer?) {
        guard phase == .roles || phase == .part, beginning != 0 else { return }
        let now = g_get_monotonic_time()
        labor.append(Double(now - beginning) / 1000)
        beginning = 0
        let time = clock.map { gdk_frame_clock_get_frame_time($0) } ?? now
        if lastTime != 0 { spacings.append(Double(time - lastTime) / 1000) }
        lastTime = time
    }

    private func evaluate(_ was: String) {
        func spot(_ values: [Double], _ share: Double) -> Double {
            guard !values.isEmpty else { return .nan }
            let s = values.sorted()
            return s[min(Int((Double(s.count - 1) * share).rounded()), s.count - 1)]
        }
        let gdk = gtk_widget_get_scale_factor(app.window)
        let row = String(format: "[Probe] %@ faktor %.2f kacheln %d sichtbar %d fenster %d x %d px, "
                           + "%d gemalt: arbeit median %.1f p95 %.1f ms | abstand median %.1f p95 %.1f ms",
                           locale: Locale(identifier: "en_US_POSIX"),
                           was, Scaling.factor, steps.first?.tiles ?? -1, visible,
                           gtk_widget_get_width(app.window) * gdk, gtk_widget_get_height(app.window) * gdk,
                           labor.count, spot(labor, 0.5), spot(labor, 0.95),
                           spot(spacings, 0.5), spot(spacings, 0.95))
        AppLog.writeOut(row + (options.isEmpty ? "" : " \(options.sorted())") + (was == "rollen" && scrollBar <= 0 ? " (nicht scrollbar)" : ""))
    }
}

nonisolated(unsafe) private let messTick: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, clock, _ in
    guard let probe = MeasureProbe.ongoing else { return 0 }
    return probe.tick(clock) ? 1 : 0
}

nonisolated(unsafe) private let clockUpdate: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MeasureProbe.ongoing?.updateEnd()
}

nonisolated(unsafe) private let clockPostDraw: @convention(c) (OpaquePointer?, gpointer?) -> Void = { clock, _ in
    MeasureProbe.ongoing?.drawEnd(clock)
}
#endif
