import CGtk
import Foundation
#if os(Windows)
import WinSDK
#endif

/// **Fractional display scaling on Windows: 125 %, 150 %, 175 %.**
///
/// GDK's Win32 backend only knows integer factors: it divides the system DPI
/// by 96 with integer arithmetic (`gdk_win32_display_get_monitor_scale_factor`,
/// GTK 4.22). At 150 % (144 DPI) this gives 1, and since the process also
/// declares itself DPI-aware, Windows does not scale anything up either.
/// Measured with GTK 4.22.4: 100 % and 150 % give the same line,
/// `scale_factor 1`, window 1440 x 900 device points, so the UI appeared at
/// two thirds of the size of every other program. Only `gtk-xft-dpi` followed
/// (144), and that only affects font sizes in pt; the metrics here are in `px`.
///
/// No GTK version up to 4.24.1 does this on Win32 itself (checked in NEWS). So
/// the app does the rest: **the content is laid out smaller by the missing
/// factor and drawn enlarged with a transform** (`gtk_widget_allocate` takes
/// one). Text, lines and drawings stay vectors and so stay sharp, unlike
/// Windows stretching the finished bitmap. One place instead of hundreds:
/// every metric in `Theme` and every size request keeps the same points as on
/// Linux.
///
/// The factor is DPI / 96 divided by what GDK already does: 1.5 at 150 %, 1.0
/// at 200 % (GDK computes 2 itself), 1.25 at 250 %.
///
/// **Linux is unchanged by default.** Wayland hands GTK the fractional factor
/// via `fractional-scale`, so the system part stays 1 and no wrapper is
/// created.
///
/// **Plus the user's part** ("Groesse der Oberflaeche" under appearance, 80 to
/// 150 %): it multiplies the system part and goes through the same wrapper,
/// on Windows and Linux. At 100 % everything is as it would be without it.
enum Scaling {
    /// What the system lacks: DPI / 96 divided by GDK's integer factor. Always 1
    /// on Linux.
    nonisolated(unsafe) private(set) static var systemShare: Double = 1
    /// What the user chose, one of ``levels``.
    nonisolated(unsafe) private(set) static var userShare: Double = 1
    /// How much larger the content is drawn than GDK does it: system part times
    /// user part.
    nonisolated(unsafe) private(set) static var factor: Double = 1

    /// The slider steps. Steps of ten: finer differences are not noticeable, and
    /// eight stops are easy to hit with a mouse.
    static let levels: [Double] = [0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5]

    /// Any value (from the file, edited by hand) snapped to the nearest step.
    static func snapped(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return levels.min { abs($0 - value) < abs($1 - value) } ?? 1
    }

    private static func togetherSet() {
        let f = systemShare * userShare
        factor = abs(f - 1) < 0.005 ? 1 : f
    }

    /// Once at startup, before the style sheet and before any metric is set.
    static func setUp(user: Double = 1) {
        userShare = snapped(user)
        var gdk = 1
        var screen = "?"
        if let display = gdk_display_get_default(),
           let list = gdk_display_get_monitors(display),
           g_list_model_get_n_items(list) > 0,
           let raw = g_list_model_get_item(list, 0) {
            var area = GdkRectangle()
            gdk_monitor_get_geometry(OpaquePointer(raw), &area)
            gdk = Int(max(gdk_monitor_get_scale_factor(OpaquePointer(raw)), 1))
            gdkFactor = gdk
            screen = "\(area.width) x \(area.height), GDK \(gdk_monitor_get_scale(OpaquePointer(raw)))"
            g_object_unref(raw)
        }
        #if os(Windows)
        // The DPI this process started with, the same number GDK derives its whole
        // factor from.
        let dpi = Int(GetDpiForSystem())
        let raw = Double(dpi) / 96 / Double(gdk)
        // Only what is noticeable. Windows offers quarter steps; anything below that
        // is noise and not worth the wrapper.
        systemShare = raw > 1.05 ? raw : 1
        if systemShare != 1, let settings = gtk_settings_get_default() {
            // GDK sets `gtk-xft-dpi` to the Windows DPI. Text in pt would already be
            // enlarged and the wrapper would enlarge it a second time.
            var value = GValue()
            g_value_init(&value, g_type_from_name("gint"))
            g_value_set_int(&value, 96 * 1024)
            g_object_set_property(unsafeBitCast(settings, to: UnsafeMutablePointer<GObject>.self),
                                  "gtk-xft-dpi", &value)
            g_value_unset(&value)
        }
        togetherSet()
        AppLog.writeOut(String(format: "[Start] Skalierung: Windows %d %% (%d DPI), Schirm %@, System %.2f x Nutzer %.2f, eigener Faktor %.2f",
                                 locale: Locale(identifier: "en_US_POSIX"),
                                 Int((Double(dpi) / 96 * 100).rounded()), dpi, screen,
                                 systemShare, userShare, factor))
        #else
        togetherSet()
        AppLog.writeOut(String(format: "[Start] Skalierung: Schirm %@, Nutzer %.2f",
                                 locale: Locale(identifier: "en_US_POSIX"), screen, userShare))
        #endif
    }

    /// The slider was moved. `false` if nothing changes.
    ///
    /// Existing wrappers lay themselves out again afterwards (``newLayOut()``);
    /// where none was created at startup because the factor was 1, the caller
    /// adds one afterwards (see `App.scaleSurface`).
    static func userSet(_ share: Double) -> Bool {
        let new = snapped(share)
        guard new != userShare else { return false }
        userShare = new
        togetherSet()
        return true
    }

    /// Every existing wrapper recomputes: the factor is read when measuring and
    /// allocating, not when building.
    static func newLayOut() {
        for h in wrappers { gtk_widget_queue_resize(h.assumingMemoryBound(to: GtkWidget.self)) }
    }

    /// Is the child already in a wrapper?
    static func isWrapped(_ kind: Widget!) -> Bool {
        guard let parent = gtk_widget_get_parent(kind) else { return false }
        return wrappers.contains(UnsafeMutableRawPointer(parent))
    }

    /// The wrappers currently alive: window content, title bar, open panels, the
    /// GL area.
    nonisolated(unsafe) private static var wrappers: [UnsafeMutableRawPointer] = []

    /// How many device points make one point as actually drawn: GDK's integer
    /// factor times our own. Anything that snaps to whole device points (scrolling,
    /// page push) must use this; with GDK's factor alone every second position
    /// would land on half a device point at 150 %.
    static func devicesPoints(_ widget: Widget!) -> Double {
        Double(max(gtk_widget_get_scale_factor(widget), 1)) * factor
    }

    /// The same rounded up, for image storage that only knows integer factors.
    /// Better to compute too fine and shrink than to stretch.
    static func grid(_ widget: Widget!) -> Int32 {
        Int32(devicesPoints(widget).rounded(.up))
    }

    /// **How many pixels a tile image gets when it is drawn `points` large**: the
    /// longest edge when decoding.
    ///
    /// Without a wrapper as always: double the edge, sharp even at GDK factor 2.
    /// **Under the wrapper exactly the device points.** Measured on Windows (Cairo,
    /// 2560 x 1392, 60 tiles, scrolling): with double edge one image cost about
    /// 38 ms at factor 1.5 against 13 ms at factor 1, almost all of it converting
    /// 450 to 337.5 pixels, image by image, on every step. Without images both
    /// factors were equal (5.0 vs 5.5 ms). Decoding in device points: 10.9 ms at
    /// 1.5.
    static func imageEdge(_ points: Int) -> Int {
        guard factor != 1 else { return points * 2 }
        return Int((Double(points) * Double(gdkFactor) * factor).rounded(.up))
    }

    /// What is requested from the server: as before double the edge, and more
    /// only if the device points exceed that (150 % times 150 %). An image is only
    /// ever shrunk when decoding, never enlarged.
    static func requestEdge(_ points: Int) -> Int {
        max(points * 2, imageEdge(points))
    }

    /// GDK's integer factor of the first screen, read at startup.
    nonisolated(unsafe) private(set) static var gdkFactor = 1

    /// A size in points as a window size, for the few places that talk to the
    /// window itself and so sit outside the wrapper. With `hoechstens` never
    /// larger than the screen: 900 pt minimum width at 150 % would otherwise be
    /// wider than a small screen.
    static func windowMetric(_ points: Int, atMost: Int32? = nil) -> Int32 {
        guard factor != 1 else { return Int32(points) }
        let mass = Int32((Double(points) * factor).rounded())
        return atMost.map { min(mass, $0) } ?? mass
    }

    /// **The remembered window size uses only the system part.** It is stored in
    /// points so the window does not grow by the factor on every start. The user's
    /// part stays out: someone who sets the UI larger wants more size in the same
    /// window, not a larger window.
    static func windowSize(_ points: Int) -> Int32 {
        systemShare == 1 ? Int32(points) : Int32((Double(points) * systemShare).rounded())
    }

    /// The counterpart of ``fenstergroesse(_:)``.
    static func points(_ windowMetric: Int32) -> Int {
        systemShare == 1 ? Int(windowMetric) : Int((Double(windowMetric) / systemShare).rounded())
    }

    /// The smallest window in the points of the remembered size: at 80 % the
    /// window may be narrower than 900 points, at 150 % it must be wider.
    static func minPoints(_ points: Int) -> Int {
        Int((Double(points) * userShare).rounded())
    }

    /// The child, drawn enlarged. For everything GTK lays out as its own root:
    /// window content, title bar, every panel. Without a factor the child itself
    /// is returned.
    static func wrapped(_ kind: Widget!) -> Widget! {
        factor == 1 ? kind : wrapper(kind, reversed: false)
    }

    /// The counterpart **inside** the wrapper: the child is laid out larger by the
    /// factor and drawn scaled down, so it is one to one in device points. For
    /// the player's GL area: its buffer size follows the allocated size, and an
    /// HDR image at two thirds of the resolution would be exactly the blur this
    /// file exists to avoid.
    static func unwarped(_ kind: Widget!) -> Widget! {
        factor == 1 ? kind : wrapper(kind, reversed: true)
    }

    private static func wrapper(_ kind: Widget!, reversed: Bool) -> Widget! {
        let h: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        if reversed {
            g_object_set_data(UnsafeMutablePointer<GObject>(OpaquePointer(h)), identifier,
                              UnsafeMutableRawPointer(bitPattern: 1))
        }
        gtk_widget_set_layout_manager(h, gtk_custom_layout_new(wrapperArt, wrapperMeasure, wrapperLayOut))
        gtk_box_append(UnsafeMutablePointer<GtkBox>(OpaquePointer(h)), kind)
        // Remembered while it lives: if the user changes the size, every existing
        // wrapper lays itself out again.
        let pointer = UnsafeMutableRawPointer(h!)
        wrappers.append(pointer)
        signal(h, "destroy") { wrappers.removeAll { $0 == pointer } }
        // The wrapper is only computation, not a building block: it stretches like
        // its child and disappears with it, otherwise it would keep space free in the
        // player once the GL area is hidden.
        gtk_widget_set_hexpand(h, gtk_widget_get_hexpand(kind))
        gtk_widget_set_vexpand(h, gtk_widget_get_vexpand(kind))
        g_object_bind_property(UnsafeMutableRawPointer(kind), "visible",
                               UnsafeMutableRawPointer(h), "visible", GBindingFlags(rawValue: 2))   // G_BINDING_SYNC_CREATE
        return h
    }

    fileprivate static let identifier = "swiftly-entzerrt"

    fileprivate static func factor(for wrapper: Widget!) -> Double {
        g_object_get_data(UnsafeMutablePointer<GObject>(OpaquePointer(wrapper)), identifier) != nil
            ? 1 / factor : factor
    }
}

private let wrapperArt: @convention(c) (Widget?) -> GtkSizeRequestMode = { wrapper in
    guard let kind = gtk_widget_get_first_child(wrapper) else { return GTK_SIZE_REQUEST_CONSTANT_SIZE }
    return gtk_widget_get_request_mode(kind)
}

/// What the child needs times the factor, rounded up so it never falls below
/// its minimum size when laid out.
private let wrapperMeasure: @convention(c) (Widget?, GtkOrientation, Int32,
                                          UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
                                          UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Void = {
    wrapper, bearing, of, min, natural, minReason, naturalReason in
    minReason?.pointee = -1
    naturalReason?.pointee = -1
    guard let kind = gtk_widget_get_first_child(wrapper), gtk_widget_get_visible(kind) != 0 else {
        min?.pointee = 0; natural?.pointee = 0
        return
    }
    let f = Scaling.factor(for: wrapper)
    var small: Int32 = 0, good: Int32 = 0
    gtk_widget_measure(kind, bearing, of < 0 ? -1 : Int32((Double(of) / f).rounded(.down)),
                       &small, &good, nil, nil)
    min?.pointee = Int32((Double(small) * f).rounded(.up))
    natural?.pointee = Int32((Double(good) * f).rounded(.up))
}

/// The child gets the area in its own points and is drawn with the factor.
/// Rounded up: better a fraction of a point over the edge (the window clips)
/// than a strip of background beside it.
private let wrapperLayOut: @convention(c) (Widget?, Int32, Int32, Int32) -> Void = {
    wrapper, width, height, _ in
    guard let kind = gtk_widget_get_first_child(wrapper), gtk_widget_get_visible(kind) != 0 else { return }
    let f = Scaling.factor(for: wrapper)
    var small: Int32 = 0
    gtk_widget_measure(kind, GTK_ORIENTATION_HORIZONTAL, -1, &small, nil, nil, nil)
    let b = max(Int32((Double(width) / f).rounded(.up)), small)
    gtk_widget_measure(kind, GTK_ORIENTATION_VERTICAL, b, &small, nil, nil, nil)
    let h = max(Int32((Double(height) / f).rounded(.up)), small)
    gtk_widget_allocate(kind, b, h, -1, gsk_transform_scale(nil, Float(f), Float(f)))
}
