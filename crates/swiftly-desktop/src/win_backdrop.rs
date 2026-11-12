//! The colour a Windows window shows where nothing is drawn yet (the strip that opens while the window is dragged larger,
//! before the next frame arrives): the theme's ground colour instead of the white class default.
#![allow(unsafe_code)]

use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};
use winit::window::Window;

/// Paints the window class background (`WM_ERASEBKGND`) in `rgb` (0xRRGGBB).
pub fn set(window: &Window, rgb: u32) {
    let Ok(handle) = window.window_handle() else {
        return;
    };
    let RawWindowHandle::Win32(h) = handle.as_raw() else {
        return;
    };
    let (r, g, b) = ((rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff);
    // SAFETY: the window handle belongs to a live window of this process; the brush is owned by the class for its life.
    unsafe {
        let brush = windows_sys::Win32::Graphics::Gdi::CreateSolidBrush(r | (g << 8) | (b << 16));
        windows_sys::Win32::UI::WindowsAndMessaging::SetClassLongPtrW(
            h.hwnd.get() as windows_sys::Win32::Foundation::HWND,
            windows_sys::Win32::UI::WindowsAndMessaging::GCLP_HBRBACKGROUND,
            brush as isize,
        );
    }
}
