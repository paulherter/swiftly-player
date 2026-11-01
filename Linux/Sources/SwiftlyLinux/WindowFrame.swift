import CGtk
import Foundation
#if os(Windows)
import WinSDK

/// **The transparent ring around the window shows as black on Windows.**
///
/// GTK's client-side decoration reserves a ring of 12 px around the window for its shadow
/// and the resize handles (measured: surface 2046 x 1235, widget 2022 x 1211). Under
/// DirectComposition that ring is composed without desktop alpha, so it appeared as a black
/// square layer behind the rounded window. Extending the DWM frame over the whole client
/// area (`DwmExtendFrameIntoClientArea` with -1) makes DWM honour the alpha of the swap
/// chain: the ring is see-through again and GTK's own shadow and rounded corners show.
enum WindowFrame {
    nonisolated(unsafe) private static var found: HWND?

    /// The visible top-level window of this process.
    private static func handle() -> HWND? {
        found = nil
        EnumWindows({ h, _ in
            var pid: DWORD = 0
            GetWindowThreadProcessId(h, &pid)
            if pid == GetCurrentProcessId(), IsWindowVisible(h) { WindowFrame.found = h; return false }
            return true
        }, 0)
        return found
    }

    /// `dwmapi` is loaded by name so the build needs no extra library.
    static func makeTransparent() {
        guard let h = handle(), let lib = LoadLibraryA("dwmapi.dll"),
              let p = GetProcAddress(lib, "DwmExtendFrameIntoClientArea") else { return }
        typealias Fn = @convention(c) (HWND?, UnsafePointer<MARGINS>?) -> Int32
        var m = MARGINS(cxLeftWidth: -1, cxRightWidth: -1, cyTopHeight: -1, cyBottomHeight: -1)
        _ = unsafeBitCast(p, to: Fn.self)(h, &m)
    }
}
#endif
