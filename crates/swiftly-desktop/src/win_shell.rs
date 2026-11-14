//! Windows details around the window that are not drawing: no console next to the release exe, the taskbar identity
//! (AppUserModelID, so the button shows the app's icon and groups its windows) and the first window rectangle (clamped
//! to the work area and centred, so the window buttons are always reachable). The pure rectangle rule is tested on every
//! platform; the system calls exist on Windows only.
#![allow(unsafe_code)]

/// The identity the taskbar groups the app under (also the notification and jump-list identity).
pub const APP_USER_MODEL_ID: &str = crate::window_extras::APP_ID;

/// A rectangle in physical pixels.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rect {
    /// Left edge.
    pub x: i32,
    /// Top edge.
    pub y: i32,
    /// Width.
    pub w: i32,
    /// Height.
    pub h: i32,
}

/// The first window rectangle: the wanted size, never larger than the work area (screen without taskbar), centred in it.
pub fn fit_to_work_area(wanted: (i32, i32), work: Rect) -> Rect {
    let w = wanted.0.clamp(1, work.w.max(1));
    let h = wanted.1.clamp(1, work.h.max(1));
    Rect {
        x: work.x + (work.w - w) / 2,
        y: work.y + (work.h - h) / 2,
        w,
        h,
    }
}

/// The smallest window size (points) the window may be dragged to: the app's minimum, but never more than the work area
/// holds at this `scale`. A 900x560 pt minimum does not fit a 1366x768 laptop at 150 % (910x485 pt of work area): the
/// window would then be forced larger than the screen and its buttons would sit off the edge.
pub fn min_size_for_work(min: (f64, f64), work: Rect, scale: f64) -> (f64, f64) {
    let scale = if scale > 0.0 { scale } else { 1.0 };
    (
        min.0.min((f64::from(work.w) / scale).floor().max(1.0)),
        min.1.min((f64::from(work.h) / scale).floor().max(1.0)),
    )
}

/// Lets a release exe (GUI subsystem, no console of its own) print to the terminal it was started from. A redirect the
/// parent set up (`> file`, a pipe) is kept: attaching to the parent's console must not replace it, otherwise a log
/// captured by a script stays empty.
#[cfg(target_os = "windows")]
pub fn attach_parent_console() {
    use windows_sys::Win32::Foundation::{HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Console::{
        ATTACH_PARENT_PROCESS, AttachConsole, GetStdHandle, STD_ERROR_HANDLE, STD_OUTPUT_HANDLE,
        SetStdHandle,
    };
    let usable = |h: HANDLE| !h.is_null() && h != INVALID_HANDLE_VALUE;
    // SAFETY: plain system calls; failing (no parent console, double-click start) is fine and ignored.
    unsafe {
        let (out, err) = (
            GetStdHandle(STD_OUTPUT_HANDLE),
            GetStdHandle(STD_ERROR_HANDLE),
        );
        AttachConsole(ATTACH_PARENT_PROCESS);
        if usable(out) {
            SetStdHandle(STD_OUTPUT_HANDLE, out);
        }
        if usable(err) {
            SetStdHandle(STD_ERROR_HANDLE, err);
        }
    }
}

/// Lets a release exe print to the terminal it was started from (Windows only; nothing to do here).
#[cfg(not(target_os = "windows"))]
pub fn attach_parent_console() {}

/// Sets the process's AppUserModelID; must run before the first window exists.
#[cfg(target_os = "windows")]
pub fn set_app_user_model_id() {
    let wide: Vec<u16> = APP_USER_MODEL_ID
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    // SAFETY: `wide` is a NUL-terminated UTF-16 string that outlives the call.
    unsafe {
        windows_sys::Win32::UI::Shell::SetCurrentProcessExplicitAppUserModelID(wide.as_ptr());
    }
}

/// The AppUserModelID is a Windows thing (nothing to do here).
#[cfg(not(target_os = "windows"))]
pub fn set_app_user_model_id() {}

/// Gives the window's taskbar button its icon, name and relaunch command explicitly (`System.AppUserModel.Relaunch*`
/// on the window's property store). A bare exe has no Start-menu shortcut that carries the AppUserModelID, and with an
/// explicit ID the shell then showed the generic application icon although the exe and the window have icons.
#[cfg(all(feature = "window", target_os = "windows"))]
pub fn set_taskbar_identity(window: &winit::window::Window) {
    use std::ffi::c_void;
    use windows_sys::core::GUID;
    use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};
    #[repr(C)]
    struct PropertyKey {
        fmtid: GUID,
        pid: u32,
    }
    #[repr(C)]
    struct PropVariant {
        vt: u16,
        reserved: [u16; 3],
        ptr: *mut c_void,
        extra: usize,
    }
    type SetValue =
        unsafe extern "system" fn(*mut c_void, *const PropertyKey, *const PropVariant) -> i32;
    type Commit = unsafe extern "system" fn(*mut c_void) -> i32;
    type Release = unsafe extern "system" fn(*mut c_void) -> u32;
    const VT_LPWSTR: u16 = 31;
    let fmtid = GUID {
        data1: 0x9F4C_2855,
        data2: 0x9F79,
        data3: 0x4B39,
        data4: [0xA8, 0xD0, 0xE1, 0xD4, 0x2D, 0xE1, 0xD5, 0xF3],
    };
    let iid_store = GUID {
        data1: 0x886D_8EEB,
        data2: 0x8CF2,
        data3: 0x4446,
        data4: [0x8D, 0x02, 0xCD, 0xBA, 0x1D, 0xBD, 0xCF, 0x99],
    };
    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    let exe = exe.to_string_lossy().into_owned();
    let wide = |s: &str| -> Vec<u16> { s.encode_utf16().chain(std::iter::once(0)).collect() };
    let values = [
        (2_u32, wide(&format!("\"{exe}\""))),
        (3, wide(&format!("{exe},0"))),
        (4, wide(crate::window_extras::PRODUCT_NAME)),
        (5, wide(APP_USER_MODEL_ID)),
    ];
    let Ok(RawWindowHandle::Win32(h)) = window.window_handle().map(|h| h.as_raw()) else {
        return;
    };
    // SAFETY: `hwnd` is a live window of this process. The property store is a COM object: its vtable is
    // IUnknown (3 slots), then GetCount, GetAt, GetValue, SetValue (slot 6), Commit (slot 7). Each PROPVARIANT points
    // at a NUL-terminated UTF-16 string that outlives its SetValue call (the store copies it); the store is released.
    unsafe {
        let mut store: *mut c_void = std::ptr::null_mut();
        if windows_sys::Win32::UI::Shell::PropertiesSystem::SHGetPropertyStoreForWindow(
            h.hwnd.get() as windows_sys::Win32::Foundation::HWND,
            &iid_store,
            &mut store,
        ) != 0
            || store.is_null()
        {
            return;
        }
        let vtable = *(store as *const *const usize);
        let set: SetValue = std::mem::transmute(*vtable.add(6));
        let commit: Commit = std::mem::transmute(*vtable.add(7));
        let release: Release = std::mem::transmute(*vtable.add(2));
        for (pid, text) in &values {
            let key = PropertyKey { fmtid, pid: *pid };
            let value = PropVariant {
                vt: VT_LPWSTR,
                reserved: [0; 3],
                ptr: text.as_ptr() as *mut c_void,
                extra: 0,
            };
            set(store, &key, &value);
        }
        commit(store);
        release(store);
    }
}

/// The work area (physical pixels) of the monitor the window is on, or the nearest one.
#[cfg(all(feature = "window", target_os = "windows"))]
pub fn work_area(window: &winit::window::Window) -> Option<Rect> {
    use windows_sys::Win32::Graphics::Gdi::{
        GetMonitorInfoW, MONITOR_DEFAULTTONEAREST, MONITORINFO, MonitorFromWindow,
    };
    use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};
    let RawWindowHandle::Win32(h) = window.window_handle().ok()?.as_raw() else {
        return None;
    };
    // SAFETY: the handle belongs to a live window of this process; `info` is a correctly sized, initialised struct.
    unsafe {
        let monitor = MonitorFromWindow(
            h.hwnd.get() as windows_sys::Win32::Foundation::HWND,
            MONITOR_DEFAULTTONEAREST,
        );
        let mut info: MONITORINFO = std::mem::zeroed();
        info.cbSize = std::mem::size_of::<MONITORINFO>() as u32;
        if GetMonitorInfoW(monitor, &mut info) == 0 {
            return None;
        }
        let r = info.rcWork;
        Some(Rect {
            x: r.left,
            y: r.top,
            w: r.right - r.left,
            h: r.bottom - r.top,
        })
    }
}

/// After the system changed the window's scale (a 100 % to 125 % switch with the app open): when the window is now larger
/// than its work area, it is fitted and centred again, so no button ends up off screen. Other sizes stay as they are.
#[cfg(all(feature = "window", target_os = "windows"))]
pub fn keep_in_work_area(window: &winit::window::Window, min: (f64, f64)) {
    let Some(work) = work_area(window) else {
        return;
    };
    if window.is_maximized() {
        return;
    }
    let outer = window.outer_size();
    if outer.width as i32 > work.w || outer.height as i32 > work.h {
        place_in_work_area(window, min);
    }
}

/// Moves a not yet shown window into its work area at its first show: never larger than the work area, centred.
#[cfg(all(feature = "window", target_os = "windows"))]
pub fn place_in_work_area(window: &winit::window::Window, min: (f64, f64)) {
    use winit::dpi::{LogicalSize, PhysicalPosition, PhysicalSize};
    let Some(work) = work_area(window) else {
        return;
    };
    // The minimum size must fit the work area too (see `min_size_for_work`), or the clamp below is overruled by it.
    let m = min_size_for_work(min, work, window.scale_factor());
    window.set_min_inner_size(Some(LogicalSize::new(m.0, m.1)));
    let outer = window.outer_size();
    let inner = window.inner_size();
    let fit = fit_to_work_area((outer.width as i32, outer.height as i32), work);
    // Frame (zero for this frameless window, kept for safety) stays around the inner size.
    let frame = (
        outer.width.saturating_sub(inner.width),
        outer.height.saturating_sub(inner.height),
    );
    let _ = window.request_inner_size(PhysicalSize::new(
        (fit.w as u32).saturating_sub(frame.0),
        (fit.h as u32).saturating_sub(frame.1),
    ));
    window.set_outer_position(PhysicalPosition::new(fit.x, fit.y));
}

#[cfg(test)]
mod tests {
    use super::*;

    const WORK_1280X800: Rect = Rect {
        x: 0,
        y: 0,
        w: 1280,
        h: 752,
    };

    #[test]
    fn the_default_window_is_clamped_to_a_small_screen_and_centred() {
        let r = fit_to_work_area((1440, 900), WORK_1280X800);
        assert_eq!(
            r,
            Rect {
                x: 0,
                y: 0,
                w: 1280,
                h: 752
            }
        );
        // Every edge lies inside the work area, so the buttons at the top right are reachable.
        assert!(r.x >= 0 && r.y >= 0 && r.x + r.w <= 1280 && r.y + r.h <= 752);
    }

    #[test]
    fn a_window_that_fits_is_only_centred() {
        let r = fit_to_work_area((1000, 600), WORK_1280X800);
        assert_eq!(
            r,
            Rect {
                x: 140,
                y: 76,
                w: 1000,
                h: 600
            }
        );
    }

    #[test]
    fn a_second_monitor_with_an_offset_and_a_taskbar_on_top_is_respected() {
        let work = Rect {
            x: -1920,
            y: 40,
            w: 1920,
            h: 1040,
        };
        let r = fit_to_work_area((2400, 1200), work);
        assert_eq!(r, work);
        let r = fit_to_work_area((1440, 900), work);
        assert_eq!((r.x, r.y), (-1920 + 240, 40 + 70));
    }

    #[test]
    fn the_minimum_size_never_exceeds_a_small_work_area() {
        // 1366x768 laptop at 150 %: 910x485 pt of work area (taskbar 40 px) against the 900x560 pt minimum.
        let work = Rect {
            x: 0,
            y: 0,
            w: 1366,
            h: 728,
        };
        assert_eq!(min_size_for_work((900.0, 560.0), work, 1.5), (900.0, 485.0));
        // A roomy screen keeps the app's minimum.
        let big = Rect {
            x: 0,
            y: 0,
            w: 1920,
            h: 1040,
        };
        assert_eq!(min_size_for_work((900.0, 560.0), big, 1.5), (900.0, 560.0));
        // The VM case: 1280x740 work area at 125 %.
        let vm = Rect {
            x: 0,
            y: 0,
            w: 1280,
            h: 740,
        };
        assert_eq!(min_size_for_work((900.0, 560.0), vm, 1.5), (853.0, 493.0));
        assert_eq!(min_size_for_work((900.0, 560.0), vm, 0.0), (900.0, 560.0));
    }

    #[test]
    fn a_degenerate_work_area_never_gives_an_empty_window() {
        let r = fit_to_work_area(
            (1440, 900),
            Rect {
                x: 0,
                y: 0,
                w: 0,
                h: 0,
            },
        );
        assert!(r.w >= 1 && r.h >= 1);
    }
}
