import CGtk
import Foundation
#if os(Windows)
import WinSDK

/// **The ring around the window showed as black on Windows.**
///
/// GTK's client-side decoration reserves a ring of 12 px around the window for its shadow
/// and the resize handles (measured: surface 2046 x 1235, widget 2022 x 1211). The cause of
/// the black was that these calls went to the wrong window: the process has a second
/// top-level window, the GL layer (`GdkWin32GL`), and it came first in the enumeration. The
/// real window (`gdkSurfaceToplevel`) now gets the see-through frame, Windows 11's rounding
/// and a clip region around the ring, with the resize edges moved inside the content.
enum WindowFrame {
    nonisolated(unsafe) private static var found: HWND?
    nonisolated(unsafe) private static var foundArea = 0

    /// The visible top-level window of this process.
    private static func handle() -> HWND? {
        found = nil
        foundArea = 0
        EnumWindows({ h, _ in
            var pid: DWORD = 0
            GetWindowThreadProcessId(h, &pid)
            if pid == GetCurrentProcessId(), IsWindowVisible(h) {
                // The GL layer (class GdkWin32GL) is a window of its own and can come first.
                var buf = [CChar](repeating: 0, count: 64)
                GetClassNameA(h, &buf, 64)
                var w = RECT()
                GetWindowRect(h, &w)
                let area = Int(w.right - w.left) * Int(w.bottom - w.top)
                if String(cString: buf) == "gdkSurfaceToplevel", area > WindowFrame.foundArea {
                    WindowFrame.found = h
                    WindowFrame.foundArea = area
                }
            }
            return true
        }, 0)
        return found
    }

    /// `dwmapi` is loaded by name so the build needs no extra library.
    private static func dwm(_ name: String) -> UnsafeMutableRawPointer? {
        guard let lib = LoadLibraryA("dwmapi.dll"), let p = GetProcAddress(lib, name) else { return nil }
        return unsafeBitCast(p, to: UnsafeMutableRawPointer.self)
    }

    /// Makes one native window see-through where GTK paints nothing, and gives it
    /// Windows 11's own rounding when it is a plain top-level window.
    static func transparent(_ h: HWND) {
        typealias Extend = @convention(c) (HWND?, UnsafePointer<MARGINS>?) -> Int32
        if let p = dwm("DwmExtendFrameIntoClientArea") {
            var m = MARGINS(cxLeftWidth: -1, cxRightWidth: -1, cyTopHeight: -1, cyBottomHeight: -1)
            _ = unsafeBitCast(p, to: Extend.self)(h, &m)
        }
        // The clip region does the rounding. Windows would otherwise still draw its 1 px
        // border and its shadow around the whole window rectangle, 12 px outside the content.
        typealias Attribute = @convention(c) (HWND?, DWORD, UnsafeRawPointer?, DWORD) -> Int32
        if let p = dwm("DwmSetWindowAttribute") {
            let set = unsafeBitCast(p, to: Attribute.self)
            var none: UInt32 = 0xFFFFFFFE  // DWMWA_COLOR_NONE
            _ = set(h, 34, &none, 4)       // DWMWA_BORDER_COLOR
            var off: Int32 = 1             // DWMNCRP_DISABLED
            _ = set(h, 2, &off, 4)         // DWMWA_NCRENDERING_POLICY
        }
    }

    static func makeTransparent() {
        guard let h = handle() else { return }
        transparent(h)
        frameless(h)
    }

    // MARK: Cutting the ring away

    /// GTK's ring (shadow and resize handles) is 12 px; DirectComposition shows it black, and
    /// no CSS removes it for a resizable window. So the native window is clipped to the
    /// visible content with round corners, and the resize edges move inside that content.
    /// Measured by `measureRing` (12 on every scale seen so far; the DPI of the screen does not change it).
    nonisolated(unsafe) static var ring = 12
    private static let edge = 6
    nonisolated(unsafe) private static var original: Int = 0


    /// Whether the window covers its whole monitor or is maximized: GTK has no ring there.
    private static func full(_ h: HWND) -> Bool {
        if IsZoomed(h) { return true }
        var w = RECT(), info = MONITORINFO()
        info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        GetWindowRect(h, &w)
        guard GetMonitorInfoW(MonitorFromWindow(h, DWORD(MONITOR_DEFAULTTONEAREST)), &info) else { return false }
        return w.left <= info.rcMonitor.left && w.top <= info.rcMonitor.top
            && w.right >= info.rcMonitor.right && w.bottom >= info.rcMonitor.bottom
    }

    /// Sets (or clears) the clip region to match the window's current state.
    private static func clip(_ h: HWND) {
        if full(h) { SetWindowRgn(h, nil, true); return }
        var w = RECT()
        GetWindowRect(h, &w)
        let r = ring, d = 16
        let region = CreateRoundRectRgn(
            Int32(r), Int32(r), Int32(Int(w.right - w.left) - r + 1), Int32(Int(w.bottom - w.top) - r + 1),
            Int32(d), Int32(d))
        SetWindowRgn(h, region, true)
    }

    /// The resize edge under the pointer, now measured inside the clipped content.
    private static func edgeHit(_ h: HWND, _ lp: LPARAM) -> Int32? {
        var w = RECT()
        GetWindowRect(h, &w)
        let x = Int(Int16(truncatingIfNeeded: lp)) - Int(w.left)
        let y = Int(Int16(truncatingIfNeeded: lp >> 16)) - Int(w.top)
        let r = ring, e = edge
        let width = Int(w.right - w.left), height = Int(w.bottom - w.top)
        let left = x < r + e, right = x >= width - r - e, top = y < r + e, bottom = y >= height - r - e
        switch (left, right, top, bottom) {
        case (true, _, true, _): return HTTOPLEFT
        case (_, true, true, _): return HTTOPRIGHT
        case (true, _, _, true): return HTBOTTOMLEFT
        case (_, true, _, true): return HTBOTTOMRIGHT
        case (true, _, _, _): return HTLEFT
        case (_, true, _, _): return HTRIGHT
        case (_, _, true, _): return HTTOP
        case (_, _, _, true): return HTBOTTOM
        default: return nil
        }
    }

    private static func frameless(_ h: HWND) {
        var w = RECT()
        GetWindowRect(h, &w)
        guard w.right - w.left > 600 else { return }
        if original == 0 {
            let proc: @convention(c) (HWND?, UINT, WPARAM, LPARAM) -> LRESULT = { h, msg, wp, lp in
                guard let h else { return 0 }
                if msg == UINT(WM_NCHITTEST), !WindowFrame.full(h) {
                    if let code = WindowFrame.edgeHit(h, lp) { return LRESULT(code) }
                }
                let result = CallWindowProcW(unsafeBitCast(WindowFrame.original, to: WNDPROC?.self), h, msg, wp, lp)
                if msg == UINT(WM_WINDOWPOSCHANGED) { WindowFrame.clip(h) }
                return result
            }
            original = Int(GetWindowLongPtrW(h, GWLP_WNDPROC))
            SetWindowLongPtrW(h, GWLP_WNDPROC, LONG_PTR(Int(bitPattern: unsafeBitCast(proc, to: UnsafeRawPointer.self))))
        }
        clip(h)
    }

    /// **Is the mouse pointer somewhere else than over this program?** GTK does not always
    /// report leaving the window on Windows, so the player asks directly: outside the
    /// window's rectangle, or another program's window lies under the pointer.
    static func pointerOutside() -> Bool {
        var p = POINT()
        guard GetCursorPos(&p), let h = handle() else { return false }
        var r = RECT()
        guard GetWindowRect(h, &r) else { return false }
        if p.x < r.left || p.x >= r.right || p.y < r.top || p.y >= r.bottom { return true }
        guard let under = WindowFromPoint(p) else { return false }
        var pid: DWORD = 0
        GetWindowThreadProcessId(under, &pid)
        return pid != GetCurrentProcessId()
    }

    nonisolated(unsafe) private static var hook: HWINEVENTHOOK?

    /// **Every window of ours, as soon as it appears.** The menus and pop-ups of GTK are
    /// windows of their own with the same transparent ring as the main window, and they
    /// showed as a black rectangle behind their rounded corners. They are created whenever a
    /// menu opens, so there is no moment to ask once; this notices each one.
    static func watch() {
        guard hook == nil else { return }
        hook = SetWinEventHook(
            DWORD(EVENT_OBJECT_SHOW), DWORD(EVENT_OBJECT_SHOW), nil,
            { _, _, h, object, child, _, _ in
                guard object == OBJID_WINDOW, child == 0, let h else { return }
                var pid: DWORD = 0
                GetWindowThreadProcessId(h, &pid)
                guard pid == GetCurrentProcessId() else { return }
                WindowFrame.transparent(h)
            },
            GetCurrentProcessId(), 0, DWORD(WINEVENT_OUTOFCONTEXT))
    }
}
#else
enum WindowFrame {
    static func pointerOutside() -> Bool { false }
}
#endif
