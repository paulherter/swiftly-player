//! Keeps the Windows title bar dark. winit sets `DWMWA_USE_IMMERSIVE_DARK_MODE` only when the requested theme differs
//! from the one it remembers, and Windows resets the attribute on its own after some DPI changes (the 125 % to 100 %
//! switch while running), so winit's `set_theme` never repeats it. The attribute is therefore read back and set again
//! whenever it has fallen to 0, on every redraw, resize, scale change and focus change.
#![allow(unsafe_code)]

/// Whether the attribute must be set again: it is unknown (the read failed) or not 1.
pub fn needs_reapply(current: Option<i32>) -> bool {
    current != Some(1)
}

/// Reads `DWMWA_USE_IMMERSIVE_DARK_MODE` of the window and sets it to 1 when it is not. Returns whether it had to set
/// it (Windows only; nothing to do elsewhere).
#[cfg(all(feature = "window", target_os = "windows"))]
pub fn ensure(window: &winit::window::Window) -> bool {
    use windows_sys::Win32::Graphics::Dwm::{
        DWMWA_USE_IMMERSIVE_DARK_MODE, DwmGetWindowAttribute, DwmSetWindowAttribute,
    };
    use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};
    let Ok(handle) = window.window_handle() else {
        return false;
    };
    let RawWindowHandle::Win32(h) = handle.as_raw() else {
        return false;
    };
    let hwnd = h.hwnd.get() as windows_sys::Win32::Foundation::HWND;
    let mut value: i32 = 0;
    // SAFETY: the handle belongs to a live window of this process; `value` is a valid i32 of the size passed.
    let read = unsafe {
        DwmGetWindowAttribute(
            hwnd,
            DWMWA_USE_IMMERSIVE_DARK_MODE as u32,
            (&mut value as *mut i32).cast(),
            std::mem::size_of::<i32>() as u32,
        )
    };
    let current = (read >= 0).then_some(value);
    if !needs_reapply(current) {
        return false;
    }
    let on: i32 = 1;
    // SAFETY: as above; `on` is a valid i32 of the size passed.
    unsafe {
        DwmSetWindowAttribute(
            hwnd,
            DWMWA_USE_IMMERSIVE_DARK_MODE as u32,
            (&on as *const i32).cast(),
            std::mem::size_of::<i32>() as u32,
        );
    }
    true
}

/// Not Windows: nothing to keep.
#[cfg(not(all(feature = "window", target_os = "windows")))]
pub fn ensure(_window: &winit::window::Window) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_dropped_or_unreadable_attribute_is_set_again() {
        assert!(needs_reapply(Some(0)));
        assert!(needs_reapply(None));
        assert!(!needs_reapply(Some(1)));
    }
}
