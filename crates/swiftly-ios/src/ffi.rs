//! The C boundary the Swift host calls (`Sources/RustUI/SwiftlyRust.h`). One opaque handle per `CAMetalLayer`; all
//! calls come from the main thread. Positions are points, times are seconds of the display link.
#![allow(unsafe_code)]

use std::ffi::{CStr, c_char, c_void};

use crate::host::{Form, Host, Phase, Press, TextKind};

/// One shell: the host core and, on iOS and tvOS, its Metal output.
pub struct Handle {
    host: Host,
    #[cfg(any(target_os = "ios", target_os = "tvos"))]
    gpu: Option<crate::gpu::Gpu>,
    /// False while the app is in the background: nothing is drawn (Metal must not present there).
    active: bool,
}

fn with<R>(h: *mut Handle, default: R, f: impl FnOnce(&mut Handle) -> R) -> R {
    // SAFETY: the host passes the pointer from `swiftly_rust_create` and never uses it after `swiftly_rust_destroy`.
    match unsafe { h.as_mut() } {
        Some(handle) => guard(default, || f(handle)),
        None => default,
    }
}

/// A panic must never unwind out of an `extern "C"` function (that aborts the process): it is caught here, logged
/// through the scrubbing hook, and the call answers `default`.
fn guard<R>(default: R, f: impl FnOnce() -> R) -> R {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or(default)
}

fn text_of(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    // SAFETY: the host passes a NUL-terminated UTF-8 string that lives for the call.
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

/// Creates a shell for `layer` (a `CAMetalLayer`) of `width`x`height` pixels. `form`: 0 phone, 1 pad, 2 tv.
/// Returns null when the form is unknown. Without a GPU the shell still runs (no pictures).
///
/// # Safety
/// `layer` must be a valid `CAMetalLayer` that outlives the handle (or null for a headless shell).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn swiftly_rust_create(
    form: i32,
    width: u32,
    height: u32,
    screen_scale: f32,
    layer: *mut c_void,
) -> *mut Handle {
    let Some(form) = Form::from_code(form) else {
        return std::ptr::null_mut();
    };
    swiftly_net::redact::install_panic_hook(|line| eprintln!("SwiftlyRust: {line}"));
    let host = if crate::platform::is_live() {
        match swiftly_desktop::live::Core::open() {
            Ok(core) => Host::new_live(
                form,
                (width, height),
                screen_scale,
                std::sync::Arc::new(core),
            ),
            Err(e) => {
                eprintln!("SwiftlyRust: core failed: {e}");
                Host::new(form, (width, height), screen_scale)
            }
        }
    } else {
        Host::new(form, (width, height), screen_scale)
    };
    #[cfg(any(target_os = "ios", target_os = "tvos"))]
    let gpu = if layer.is_null() {
        None
    } else {
        match unsafe { crate::gpu::Gpu::new(layer, width, height, crate::platform::is_live()) } {
            Ok(g) => Some(g),
            Err(e) => {
                eprintln!("SwiftlyRust: gpu failed: {e}");
                None
            }
        }
    };
    #[cfg(not(any(target_os = "ios", target_os = "tvos")))]
    let _ = layer;
    Box::into_raw(Box::new(Handle {
        host,
        #[cfg(any(target_os = "ios", target_os = "tvos"))]
        gpu,
        active: true,
    }))
}

/// Frees the shell.
///
/// # Safety
/// `h` comes from `swiftly_rust_create` and is not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn swiftly_rust_destroy(h: *mut Handle) {
    if !h.is_null() {
        drop(unsafe { Box::from_raw(h) });
    }
}

/// The layer changed size (pixels) or the screen scale changed. Returns the flag set.
#[unsafe(no_mangle)]
pub extern "C" fn swiftly_rust_resize(
    h: *mut Handle,
    width: u32,
    height: u32,
    screen_scale: f32,
) -> i32 {
    with(h, 0, |s| {
        #[cfg(any(target_os = "ios", target_os = "tvos"))]
        if let Some(g) = &mut s.gpu {
            g.resize(width, height);
        }
        s.host.resize((width, height), screen_scale)
    })
}

/// Safe-area insets in points.
#[unsafe(no_mangle)]
pub extern "C" fn swiftly_rust_insets(
    h: *mut Handle,
    top: f32,
    left: f32,
    bottom: f32,
    right: f32,
) -> i32 {
    with(h, 0, |s| s.host.set_insets(top, left, bottom, right))
}

/// Dark mode and Reduce Motion (0 or 1).
#[unsafe(no_mangle)]
pub extern "C" fn swiftly_rust_appearance(h: *mut Handle, dark: i32, reduce_motion: i32) -> i32 {
    with(h, 0, |s| {
        s.host.set_appearance(dark != 0, reduce_motion != 0)
    })
}

/// One touch: `id` is stable per finger, `phase` 0 down, 1 move, 2 up, 3 cancel; `x`, `y` in points.
#[unsafe(no_mangle)]
pub extern "C" fn swiftly_rust_touch(
    h: *mut Handle,
    id: u64,
    phase: i32,
    x: f32,
    y: f32,
    time_s: f64,
) -> i32 {
    let Some(phase) = Phase::from_code(phase) else {
        return 0;
    };
    with(h, 0, |s| s.host.touch(id, phase, x, y, time_s))
}

/// A remote press: 0 up, 1 down, 2 left, 3 right, 4 select, 5 menu, 6 play/pause.
#[unsafe(no_mangle)]
pub extern "C" fn swiftly_rust_press(h: *mut Handle, press: i32, down: i32, time_s: f64) -> i32 {
    let Some(press) = Press::from_code(press) else {
        return 0;
    };
    with(h, 0, |s| s.host.press(press, down != 0, time_s))
}

/// Text from the keyboard bridge: `kind` 0 commit, 1 preedit, 2 cancel, 3 backspace, 4 submit; `utf8` may be null.
#[unsafe(no_mangle)]
pub extern "C" fn swiftly_rust_text(h: *mut Handle, kind: i32, utf8: *const c_char) -> i32 {
    let Some(kind) = TextKind::from_code(kind) else {
        return 0;
    };
    let text = text_of(utf8);
    with(h, 0, |s| s.host.text(kind, &text))
}

/// Pinches finished since the last call: writes up to `cap` magnifications to `out`, returns how many.
///
/// # Safety
/// `out` must point to `cap` writable doubles.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn swiftly_rust_take_pinches(
    h: *mut Handle,
    out: *mut f64,
    cap: usize,
) -> usize {
    with(h, 0, |s| {
        let all = s.host.take_pinches();
        let n = all.len().min(cap);
        for (i, v) in all.iter().take(n).enumerate() {
            unsafe { out.add(i).write(*v) };
        }
        n
    })
}

/// The haptics seam: the host's callback receives `haptic::*` codes. Pass null to remove it.
#[unsafe(no_mangle)]
pub extern "C" fn swiftly_rust_set_haptics(h: *mut Handle, callback: Option<extern "C" fn(i32)>) {
    with(h, (), |s| match callback {
        Some(cb) => s.host.set_haptics(Box::new(move |k| cb(k))),
        None => s.host.set_haptics(Box::new(|_| {})),
    });
}

/// One display-link frame at `time_s`: runs the app, draws, returns the flag set (wants another frame, wants text).
#[unsafe(no_mangle)]
pub extern "C" fn swiftly_rust_frame(h: *mut Handle, time_s: f64) -> i32 {
    with(h, 0, |s| {
        let (list, more) = s.host.frame(time_s);
        #[cfg(any(target_os = "ios", target_os = "tvos"))]
        if let (true, Some(g)) = (s.active, &mut s.gpu) {
            g.draw(&s.host, &list);
        }
        #[cfg(not(any(target_os = "ios", target_os = "tvos")))]
        let _ = list;
        s.host.frame_flags(more)
    })
}

/// Registers the platform pieces of the real app (HTTP, secrets, the AVPlayer engine). Once, before `swiftly_rust_create`.
///
/// # Safety
/// `platform` points to a valid table; the strings are NUL-terminated UTF-8 that live for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn swiftly_rust_init_live(
    platform: *const crate::platform::Platform,
    config_dir: *const c_char,
    cache_dir: *const c_char,
    device_name: *const c_char,
) {
    swiftly_net::redact::install_panic_hook(|line| eprintln!("SwiftlyRust: {line}"));
    if let Some(p) = unsafe { platform.as_ref() } {
        crate::platform::init_live(
            *p,
            &text_of(config_dir),
            &text_of(cache_dir),
            &text_of(device_name),
        );
    }
}

/// The app went to the background (0) or came back (1): drawing stops and resumes; the picture is redrawn on return.
#[unsafe(no_mangle)]
pub extern "C" fn swiftly_rust_set_active(h: *mut Handle, active: i32) -> i32 {
    with(h, 0, |s| {
        s.active = active != 0;
        s.host.frame_flags(true)
    })
}

/// One event line from the player engine (JSON, see `swiftly_player_surface::wire`). Returns 1 when understood.
#[unsafe(no_mangle)]
pub extern "C" fn swiftly_rust_engine_event(line: *const c_char) -> i32 {
    i32::from(crate::platform::engine().feed(&text_of(line)))
}

/// The commands the Rust player queued since the last call, one JSON line each; free with `swiftly_rust_free_string`.
#[unsafe(no_mangle)]
pub extern "C" fn swiftly_rust_engine_commands() -> *mut c_char {
    std::ffi::CString::new(crate::platform::engine().take_commands())
        .unwrap_or_default()
        .into_raw()
}

/// Frees a string returned by this library.
///
/// # Safety
/// `s` comes from `swiftly_rust_engine_commands` and is not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn swiftly_rust_free_string(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { std::ffi::CString::from_raw(s) });
    }
}

#[cfg(test)]
mod guard_tests {
    use super::guard;

    #[test]
    fn a_panic_becomes_the_default_answer() {
        assert_eq!(guard(-1, || -> i32 { panic!("boom") }), -1);
        assert_eq!(guard(-1, || 7), 7);
    }
}
