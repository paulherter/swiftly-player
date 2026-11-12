//! What the real app asks of the Swift host: the HTTP stack (`URLSession`: system trust, user CAs, proxy, the local
//! network prompt as in the real app), the secret store (Keychain) and the player engine (AVPlayer under the Metal
//! layer). HTTP and secrets go through a C table of callbacks the host registers once (`swiftly_rust_init_live`); the
//! engine talks JSON lines (`swiftly_player_surface::wire`, the same format as Media3 on Android).
#![allow(unsafe_code)]

use std::ffi::{CStr, CString, c_char, c_void};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};

use swiftly_accounts::SecretStore;
use swiftly_desktop::net::{HostHttp, set_host_http};
use swiftly_desktop::store::set_secret_backend;
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse};
use swiftly_playback::engine::PlaybackEngine;
use swiftly_player_surface::SurfaceEngine;
use swiftly_player_surface::wire::QueueEngine;

#[path = "../../swiftly-android/src/http_wire.rs"]
mod http_wire;

/// The callbacks the Swift host provides. Returned buffers and strings are `malloc`ed by the host and given back
/// through `release`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Platform {
    /// Passed to every callback.
    pub ctx: *mut c_void,
    /// One complete HTTP exchange: method, url, header lines `name: value\n`, body, timeout ms (0 = default). Returns
    /// the answer in the wire format of `http_wire` and its length in `out_len`, or null.
    pub http: extern "C" fn(
        *mut c_void,
        *const c_char,
        *const c_char,
        *const c_char,
        *const u8,
        usize,
        i32,
        *mut usize,
    ) -> *mut u8,
    /// The secret for a name, or null.
    pub secret_get: extern "C" fn(*mut c_void, *const c_char) -> *mut c_char,
    /// Stores a secret.
    pub secret_set: extern "C" fn(*mut c_void, *const c_char, *const c_char),
    /// Removes a secret.
    pub secret_remove: extern "C" fn(*mut c_void, *const c_char),
    /// Frees a buffer returned by `http` or `secret_get`.
    pub release: extern "C" fn(*mut c_void, *mut c_void),
}

// SAFETY: the host promises the table's functions are callable from any thread (URLSession and Keychain are).
unsafe impl Send for Platform {}
// SAFETY: as above; the table is only read.
unsafe impl Sync for Platform {}

static LIVE: AtomicBool = AtomicBool::new(false);

/// Whether the host registered the platform pieces (the real app runs instead of the demo suite).
pub fn is_live() -> bool {
    LIVE.load(Ordering::Relaxed)
}

fn c(s: &str) -> CString {
    CString::new(s.replace('\0', "")).unwrap_or_default()
}

impl Platform {
    fn take_string(&self, p: *mut c_char) -> Option<String> {
        if p.is_null() {
            return None;
        }
        // SAFETY: the host returns a NUL-terminated UTF-8 string it allocated.
        let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
        (self.release)(self.ctx, p.cast());
        Some(s)
    }
}

struct Http(Platform);

impl HostHttp for Http {
    fn send(&self, request: HttpRequest) -> Result<HttpResponse, ErrorKind> {
        let headers: String = request
            .headers
            .iter()
            .map(|(n, v)| format!("{n}: {}\n", v.replace('\n', " ")))
            .collect();
        let (method, url, headers) = (
            c(request.method.as_str()),
            c(request.url.as_str()),
            c(&headers),
        );
        let body = request.body.as_deref().unwrap_or(&[]);
        let timeout = request
            .timeout
            .map_or(0, |t| t.as_millis().min(i32::MAX as u128) as i32);
        let mut len = 0usize;
        let p = (self.0.http)(
            self.0.ctx,
            method.as_ptr(),
            url.as_ptr(),
            headers.as_ptr(),
            body.as_ptr(),
            body.len(),
            timeout,
            &mut len,
        );
        if p.is_null() {
            return Err(ErrorKind::Network { code: -1005 });
        }
        // SAFETY: the host returns `len` readable bytes at `p`.
        let bytes = unsafe { std::slice::from_raw_parts(p, len) }.to_vec();
        (self.0.release)(self.0.ctx, p.cast());
        http_wire::parse_answer(&bytes)
    }
}

struct Secrets(Platform);

impl SecretStore for Secrets {
    fn get(&self, name: &str) -> Option<String> {
        self.0
            .take_string((self.0.secret_get)(self.0.ctx, c(name).as_ptr()))
    }
    fn set(&self, name: &str, value: &str) {
        (self.0.secret_set)(self.0.ctx, c(name).as_ptr(), c(value).as_ptr());
    }
    fn remove(&self, name: &str) {
        (self.0.secret_remove)(self.0.ctx, c(name).as_ptr());
    }
}

/// The one engine of the process; the player screen holds a clone of this reference.
pub fn engine() -> &'static Arc<QueueEngine> {
    static ENGINE: OnceLock<Arc<QueueEngine>> = OnceLock::new();
    ENGINE.get_or_init(|| Arc::new(QueueEngine::new()))
}

/// Events (no frames: AVPlayer draws into its own layer under the UI) for the live player.
struct Feed(Arc<QueueEngine>);

impl swiftly_desktop::player_screen::LiveEngine for Feed {
    fn events(&self) -> Vec<swiftly_playback::engine::EngineEvent> {
        self.0.poll_events()
    }
    fn frame(&self, _max_w: u32, _max_h: u32, _sink: &mut dyn FnMut(u32, u32, &[u8])) {}
}

/// Registers everything the real app needs from the platform. Call once, before the first handle is created.
pub fn init_live(p: Platform, config_dir: &str, cache_dir: &str, device_name: &str) {
    // Single-threaded start-up: nothing else reads the environment yet.
    unsafe {
        std::env::set_var("SWIFTLY_CONFIG_DIR", config_dir);
        std::env::set_var("SWIFTLY_CACHE_DIR", cache_dir);
        std::env::set_var("SWIFTLY_DEVICE_NAME", device_name);
    }
    set_host_http(Arc::new(Http(p)));
    set_secret_backend(Arc::new(Secrets(p)));
    // AVPlayer plays mp4/mov/HLS, so the plan asks for the narrow profile (anything else is transcoded to HLS).
    swiftly_desktop::live_play::set_flavour(swiftly_playback::device_profile::Flavour::AirPlay {
        av1: false,
    });
    swiftly_desktop::live_play::set_engine_factory(Box::new(|| {
        let e = Arc::clone(engine());
        Ok((Arc::clone(&e) as Arc<dyn PlaybackEngine>, Arc::new(Feed(e))))
    }));
    LIVE.store(true, Ordering::Relaxed);
}
