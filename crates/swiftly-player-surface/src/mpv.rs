//! The libmpv engine for Windows and Linux (and the Mac when mpv is installed).
//!
//! libmpv is loaded at run time (`libmpv-2.dll`, `libmpv.so.2`, `libmpv.dylib`, or the path in `SWIFTLY_LIBMPV`), so the
//! crate builds without any mpv files. Video goes through the render API with the software renderer (`MPV_RENDER_API_TYPE_SW`):
//! the host asks for a frame at the size it wants and gets RGBA. This is the last rung of the G3 ladder and the one that
//! works on every GPU. Neither way draws on the UI thread: the software renderer runs on the render pump's thread
//! (`crate::pump`), and the GPU way (`crate::mpv_gl`, Linux) draws with libmpv's OpenGL renderer into DMA-bufs the host
//! samples. [`MpvEngine::new`] is the software way (tests, tools), [`MpvEngine::new_with`] may pick the GPU way.
#![allow(unsafe_code)]

use crate::pump::{RenderPump, Renderer, WakeSlot, Waker};
use crate::translate::{self, EofGate, EofInput, ParsedTracks};
use crate::{
    AudioDevice, Capabilities, DisplayHints, FrameBuffer, FrameDelivery, FrameStatus,
    SurfaceEngine, VideoStats, VideoSurface,
};
use libloading::Library;
use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char, c_double, c_int, c_void};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::Duration;
use swiftly_playback::engine::{
    EngineEvent, EngineLoad, EngineState, PipCmd, PlaybackEngine, Rect, SubtitleRoute,
    SubtitleTextStyle,
};
use swiftly_rules::buffer_level::BufferLevel;

// ---- the C API -----------------------------------------------------------------------------------------------------

#[repr(C)]
pub(crate) struct RenderParam {
    pub(crate) kind: c_int,
    pub(crate) data: *mut c_void,
}

#[repr(C)]
struct Event {
    id: c_int,
    error: c_int,
    userdata: u64,
    data: *mut c_void,
}

#[repr(C)]
struct EventProperty {
    name: *const c_char,
    format: c_int,
    data: *mut c_void,
}

#[repr(C)]
struct EventEndFile {
    reason: c_int,
    error: c_int,
}

const EV_NONE: c_int = 0;
const EV_SHUTDOWN: c_int = 1;
const EV_START_FILE: c_int = 6;
const EV_END_FILE: c_int = 7;
const EV_FILE_LOADED: c_int = 8;
const EV_SEEK: c_int = 20;
const EV_PLAYBACK_RESTART: c_int = 21;
const EV_PROPERTY_CHANGE: c_int = 22;
const FMT_NONE: c_int = 0;
const FMT_STRING: c_int = 1;
const FMT_FLAG: c_int = 3;
const FMT_INT64: c_int = 4;
const FMT_DOUBLE: c_int = 5;
const END_EOF: c_int = 0;
const END_ERROR: c_int = 4;
pub(crate) const RP_API_TYPE: c_int = 1;
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) const RP_OPENGL_INIT_PARAMS: c_int = 2;
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) const RP_OPENGL_FBO: c_int = 3;
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) const RP_FLIP_Y: c_int = 4;
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) const RP_DRM_DISPLAY_V2: c_int = 16;
pub(crate) const RP_BLOCK_FOR_TARGET_TIME: c_int = 12;
const RP_SW_SIZE: c_int = 17;
const RP_SW_FORMAT: c_int = 18;
const RP_SW_STRIDE: c_int = 19;
const RP_SW_POINTER: c_int = 20;
pub(crate) const UPDATE_FRAME: u64 = 1;

type FnCreate = unsafe extern "C" fn() -> *mut c_void;
type FnHandle = unsafe extern "C" fn(*mut c_void) -> c_int;
type FnDestroy = unsafe extern "C" fn(*mut c_void);
type FnSetStr = unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char) -> c_int;
type FnGetStr = unsafe extern "C" fn(*mut c_void, *const c_char) -> *mut c_char;
type FnGet = unsafe extern "C" fn(*mut c_void, *const c_char, c_int, *mut c_void) -> c_int;
type FnFree = unsafe extern "C" fn(*mut c_void);
type FnCommand = unsafe extern "C" fn(*mut c_void, *mut *const c_char) -> c_int;
type FnObserve = unsafe extern "C" fn(*mut c_void, u64, *const c_char, c_int) -> c_int;
type FnWait = unsafe extern "C" fn(*mut c_void, c_double) -> *mut Event;
type FnRcCreate = unsafe extern "C" fn(*mut *mut c_void, *mut c_void, *mut RenderParam) -> c_int;
type FnRcRender = unsafe extern "C" fn(*mut c_void, *mut RenderParam) -> c_int;
type FnRcUpdate = unsafe extern "C" fn(*mut c_void) -> u64;
type FnRcFree = unsafe extern "C" fn(*mut c_void);
type FnRcSetCb =
    unsafe extern "C" fn(*mut c_void, Option<unsafe extern "C" fn(*mut c_void)>, *mut c_void);
type FnErr = unsafe extern "C" fn(c_int) -> *const c_char;
type FnVersion = unsafe extern "C" fn() -> u64;

/// The functions we use, resolved once. The library stays loaded as long as this value lives.
pub(crate) struct Api {
    create: FnCreate,
    initialize: FnHandle,
    terminate_destroy: FnDestroy,
    set_option_string: FnSetStr,
    set_property_string: FnSetStr,
    get_property_string: FnGetStr,
    get_property: FnGet,
    free: FnFree,
    command: FnCommand,
    observe: FnObserve,
    wait_event: FnWait,
    rc_create: FnRcCreate,
    rc_render: FnRcRender,
    rc_update: FnRcUpdate,
    rc_free: FnRcFree,
    rc_set_cb: FnRcSetCb,
    set_wakeup: FnRcSetCb,
    error_string: FnErr,
    version: FnVersion,
    _lib: Library,
}

impl Api {
    fn load() -> Result<Api, String> {
        let names: Vec<String> = match std::env::var("SWIFTLY_LIBMPV") {
            Ok(p) if !p.is_empty() => vec![p],
            _ => [
                "libmpv-2.dll",
                "libmpv.so.2",
                "libmpv.so",
                "libmpv.so.1",
                "libmpv.2.dylib",
                "libmpv.dylib",
                "/opt/homebrew/lib/libmpv.dylib",
            ]
            .iter()
            .map(|s| (*s).to_owned())
            .collect(),
        };
        let mut last = String::from("no candidate");
        let lib = names
            .iter()
            .find_map(|n| match unsafe { Library::new(n) } {
                Ok(l) => Some(l),
                Err(e) => {
                    last = format!("{n}: {e}");
                    None
                }
            })
            .ok_or_else(|| format!("libmpv not found ({last}); set SWIFTLY_LIBMPV to its path"))?;
        macro_rules! sym {
            ($name:literal) => {
                *unsafe { lib.get($name) }
                    .map_err(|e| format!("libmpv lacks {}: {e}", String::from_utf8_lossy($name)))?
            };
        }
        Ok(Api {
            create: sym!(b"mpv_create\0"),
            initialize: sym!(b"mpv_initialize\0"),
            terminate_destroy: sym!(b"mpv_terminate_destroy\0"),
            set_option_string: sym!(b"mpv_set_option_string\0"),
            set_property_string: sym!(b"mpv_set_property_string\0"),
            get_property_string: sym!(b"mpv_get_property_string\0"),
            get_property: sym!(b"mpv_get_property\0"),
            free: sym!(b"mpv_free\0"),
            command: sym!(b"mpv_command\0"),
            observe: sym!(b"mpv_observe_property\0"),
            wait_event: sym!(b"mpv_wait_event\0"),
            rc_create: sym!(b"mpv_render_context_create\0"),
            rc_render: sym!(b"mpv_render_context_render\0"),
            rc_update: sym!(b"mpv_render_context_update\0"),
            rc_free: sym!(b"mpv_render_context_free\0"),
            rc_set_cb: sym!(b"mpv_render_context_set_update_callback\0"),
            set_wakeup: sym!(b"mpv_set_wakeup_callback\0"),
            error_string: sym!(b"mpv_error_string\0"),
            version: sym!(b"mpv_client_api_version\0"),
            _lib: lib,
        })
    }

    fn err(&self, code: c_int) -> String {
        let p = unsafe { (self.error_string)(code) };
        if p.is_null() {
            format!("mpv error {code}")
        } else {
            unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
        }
    }
}

/// The render functions of libmpv a render thread needs, by value (they stay valid while the engine's `Api` lives).
#[derive(Clone, Copy)]
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) struct RcApi {
    pub(crate) create: FnRcCreate,
    pub(crate) render: FnRcRender,
    pub(crate) update: FnRcUpdate,
    pub(crate) free: FnRcFree,
    pub(crate) set_cb: FnRcSetCb,
}

impl Api {
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    pub(crate) fn rc(&self) -> RcApi {
        RcApi {
            create: self.rc_create,
            render: self.rc_render,
            update: self.rc_update,
            free: self.rc_free,
            set_cb: self.rc_set_cb,
        }
    }
}

// ---- audio output choice ---------------------------------------------------------------------------------------------

/// The `ao` list for libmpv, or `None` to leave libmpv's own order alone.
///
/// libmpv tries PipeWire first. With no PipeWire socket in reach (a container, a bare session, a test box) that
/// attempt fails inside libpipewire and about one run in twenty hangs for good in `pw_thread_loop_stop`. So PipeWire
/// is only tried when its socket (or `PIPEWIRE_REMOTE`) exists; PulseAudio only when its socket (or `PULSE_SERVER`)
/// does; ALSA and the silent output always stay as the way out, so playback never fails for want of a sound server.
fn audio_output_list(
    env: &dyn Fn(&str) -> Option<String>,
    exists: &dyn Fn(&Path) -> bool,
) -> Option<&'static str> {
    if !cfg!(target_os = "linux") {
        return None;
    }
    let set = |k: &str| env(k).is_some_and(|v| !v.is_empty());
    let sockets = |name: &str, dirs: &[&str]| {
        dirs.iter()
            .filter_map(|d| env(d))
            .filter(|d| !d.is_empty())
            .any(|d| exists(&Path::new(&d).join(name)))
    };
    if set("PIPEWIRE_REMOTE") || sockets("pipewire-0", &["PIPEWIRE_RUNTIME_DIR", "XDG_RUNTIME_DIR"])
    {
        return None;
    }
    if set("PULSE_SERVER") || sockets("pulse/native", &["XDG_RUNTIME_DIR"]) {
        return Some("pulse,alsa,null");
    }
    Some("alsa,null")
}

/// How many engines were left behind because their close did not finish ([`CLOSE_LIMIT`]). Each one still holds its
/// threads and handles (about forty descriptors); a stuck audio output repeats, so after [`ABANDON_LIMIT`] of them every
/// new engine plays through the silent output instead of trying that audio stack again.
static ABANDONED: AtomicUsize = AtomicUsize::new(0);
/// Set when starting an engine hung once: the retry (and every later engine) uses the silent output.
static FORCE_NULL_AUDIO: AtomicBool = AtomicBool::new(false);
/// Abandoned engines after which the audio stack counts as broken.
const ABANDON_LIMIT: usize = 2;
/// How long creating an engine may take before it counts as hung (a normal start is well under a second).
const START_LIMIT: Duration = Duration::from_secs(6);

/// Whether new engines must use the silent output: the audio stack hung a start, or left engines behind on close.
fn silent_audio_needed(forced: bool, abandoned: usize) -> bool {
    forced || abandoned >= ABANDON_LIMIT
}

/// Runs `work` on its own thread and waits at most `limit` for the answer; `None` when it did not come in time (the
/// thread is left to finish by itself and its result is dropped). The caller never blocks for good on libmpv or the
/// audio stack below it.
fn bounded<T: Send + 'static>(
    limit: Duration,
    work: impl FnOnce() -> T + Send + 'static,
) -> Option<T> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::Builder::new()
        .name("mpv-start".into())
        .spawn(move || {
            let _ = tx.send(work());
        })
        .ok()?;
    rx.recv_timeout(limit).ok()
}

/// Sets a property on a handle from any thread (libmpv's client API is thread-safe).
pub(crate) fn set_prop_raw(api: &Api, handle: usize, k: &str, v: &str) -> bool {
    let (k, v) = (cstr(k), cstr(v));
    unsafe { (api.set_property_string)(handle as *mut c_void, k.as_ptr(), v.as_ptr()) >= 0 }
}

/// Applies the stored subtitle look at the picture size `out_w x out_h` (libass sizes and margins are relative to it).
pub(crate) fn apply_style_raw(
    api: &Api,
    handle: usize,
    style: &Mutex<Option<SubtitleTextStyle>>,
    out_w: u32,
    out_h: u32,
) {
    let Some(style) = lock(style).clone() else {
        return;
    };
    for (k, v) in translate::text_options(&style, out_w, out_h) {
        set_prop_raw(api, handle, k, &v);
    }
}

/// libmpv's wake-up callback: events wait in its queue.
unsafe extern "C" fn mpv_wakeup_callback(user: *mut c_void) {
    // `user` is the engine's `WakeSlot`, alive until `Drop` clears the callback.
    let wake = unsafe { &*user.cast::<WakeSlot>() };
    wake.fire();
}

/// libmpv's update callback of the software way: wakes the render pump (it only sets a flag).
unsafe extern "C" fn sw_update_callback(user: *mut c_void) {
    // `user` is the pump's shared state, alive until the callback is cleared in `Drop`.
    let shared = unsafe { &*user.cast::<crate::pump::Shared>() };
    shared.notify();
}

/// Work an event asks for that calls into libmpv and so waits for the player core: opening a file keeps the core busy
/// for a while (decoder, video output), and a call made then held the UI thread for over 100 ms. These run on the
/// worker thread; the UI thread only reads the event queue (`mpv_wait_event` with no timeout never waits).
enum Job {
    /// A new file started: it plays (keep-open leaves mpv paused on the last frame of the previous one).
    StartFile,
    /// The file is loaded: add the external subtitles, then the subtitle look.
    FileLoaded(Vec<translate::PendingSub>, u32, u32),
    TrackList,
    VideoParams,
}

struct Worker {
    api: Arc<Api>,
    handle: usize,
    st: Arc<Mutex<State>>,
    style: Arc<Mutex<Option<SubtitleTextStyle>>>,
}

impl Worker {
    fn get_string(&self, k: &str) -> Option<String> {
        let k = cstr(k);
        let p = unsafe { (self.api.get_property_string)(self.handle as *mut c_void, k.as_ptr()) };
        if p.is_null() {
            return None;
        }
        let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
        unsafe { (self.api.free)(p.cast()) };
        Some(s)
    }

    /// **One subtitle rule for every renderer** (`swiftly_playback::subtitle_cues::chain_text`): libass shows a cue
    /// exactly from its start to its end, so back-to-back cues with a small gap flash a blank frame (mpv's own
    /// `sub-fix-timing` closes 210 ms at most and has no threshold). The external file is read once (through a
    /// second silent libmpv handle with `stream-dump`, so the player needs no HTTP client and keeps its headers and
    /// proxies), its ends are held to the next start, and the result is added as a local file. `None` when the
    /// text is not SRT/WebVTT, has nothing to close, or could not be read.
    fn chained_sub(&self, url: &str, temp: &mut Vec<std::path::PathBuf>) -> Option<String> {
        if !(url.starts_with("http://") || url.starts_with("https://")) {
            return None;
        }
        let text = self.fetch_text(url)?;
        let chained = swiftly_playback::subtitle_cues::chain_text(&text);
        if chained == text {
            return None;
        }
        static COUNT: AtomicUsize = AtomicUsize::new(0);
        let ext = if chained.contains("WEBVTT") {
            "vtt"
        } else {
            "srt"
        };
        let path = std::env::temp_dir().join(format!(
            "swiftly-subchain-{}-{}.{ext}",
            std::process::id(),
            COUNT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::write(&path, chained).ok()?;
        let shown = path.to_str().map(str::to_owned);
        // Removed with the next file's subtitles and when the player thread ends: no temp files are left behind.
        temp.push(path);
        shown
    }

    /// The text behind `url`, dumped by a throwaway libmpv handle (no video, no audio, no config, 15 s at most).
    fn fetch_text(&self, url: &str) -> Option<String> {
        const LIMIT: Duration = Duration::from_secs(15);
        let dump = std::env::temp_dir().join(format!(
            "swiftly-subdump-{}-{}",
            std::process::id(),
            self.handle
        ));
        let h = unsafe { (self.api.create)() };
        if h.is_null() {
            return None;
        }
        let set = |k: &str, v: &str| {
            let (k, v) = (cstr(k), cstr(v));
            unsafe { (self.api.set_option_string)(h, k.as_ptr(), v.as_ptr()) };
        };
        for (k, v) in [
            ("config", "no"),
            ("load-scripts", "no"),
            ("ytdl", "no"),
            ("vo", "null"),
            ("ao", "null"),
            ("idle", "yes"),
            ("terminal", "no"),
        ] {
            set(k, v);
        }
        set("stream-dump", dump.to_str()?);
        if let Some(headers) = self.get_string("http-header-fields")
            && !headers.is_empty()
        {
            set("http-header-fields", &headers);
        }
        let mut text = None;
        if unsafe { (self.api.initialize)(h) } >= 0 {
            let args = [cstr("loadfile"), cstr(url)];
            let mut ptrs: Vec<*const c_char> = args.iter().map(|c| c.as_ptr()).collect();
            ptrs.push(std::ptr::null());
            if unsafe { (self.api.command)(h, ptrs.as_mut_ptr()) } >= 0 {
                let started = std::time::Instant::now();
                while started.elapsed() < LIMIT {
                    let ev = unsafe { (self.api.wait_event)(h, 0.2) };
                    if ev.is_null() {
                        continue;
                    }
                    let id = unsafe { (*ev).id };
                    if id == EV_END_FILE || id == EV_SHUTDOWN {
                        text = std::fs::read(&dump)
                            .ok()
                            .map(|b| String::from_utf8_lossy(&b).into_owned());
                        break;
                    }
                }
            }
        }
        unsafe { (self.api.terminate_destroy)(h) };
        std::fs::remove_file(&dump).ok();
        text
    }

    fn run(self, rx: std::sync::mpsc::Receiver<Job>) {
        let mut temp: Vec<std::path::PathBuf> = Vec::new();
        while let Ok(job) = rx.recv() {
            match job {
                Job::StartFile => {
                    set_prop_raw(&self.api, self.handle, "pause", "no");
                }
                Job::FileLoaded(subs, w, h) => {
                    for old in temp.drain(..) {
                        std::fs::remove_file(old).ok();
                    }
                    for sub in subs {
                        // Text subtitles come back with short gaps closed (the core's chain rule); anything
                        // else, or a failed read, is added from its address as before.
                        let chained = self.chained_sub(&sub.url, &mut temp);
                        let source = chained.as_deref().unwrap_or(sub.url.as_str());
                        let mut args = vec!["sub-add", source, "auto"];
                        if let Some(n) = sub.title.as_deref() {
                            args.push(n);
                        }
                        if let Some(l) = sub.language.as_deref() {
                            if args.len() == 3 {
                                args.push("external");
                            }
                            args.push(l);
                        }
                        let owned: Vec<CString> = args.iter().map(|a| cstr(a)).collect();
                        let mut ptrs: Vec<*const c_char> =
                            owned.iter().map(|c| c.as_ptr()).collect();
                        ptrs.push(std::ptr::null());
                        unsafe {
                            (self.api.command)(self.handle as *mut c_void, ptrs.as_mut_ptr())
                        };
                    }
                    apply_style_raw(&self.api, self.handle, &self.style, w, h);
                }
                Job::TrackList => {
                    if let Some(json) = self.get_string("track-list") {
                        let t = translate::parse_tracks(&json);
                        let mut s = lock(&self.st);
                        s.events.push(t.event());
                        s.tracks = t;
                    }
                }
                Job::VideoParams => {
                    if let Some(json) = self.get_string("video-params") {
                        let mut s = lock(&self.st);
                        let hints = translate::parse_hints(&json, s.fps);
                        if let Some((w, h)) = hints.size
                            && s.video_size != Some((f64::from(w), f64::from(h)))
                        {
                            s.video_size = Some((f64::from(w), f64::from(h)));
                            s.events.push(EngineEvent::VideoSize {
                                width: f64::from(w),
                                height: f64::from(h),
                            });
                        }
                        s.hints = hints;
                    }
                }
            }
        }
        for old in temp.drain(..) {
            std::fs::remove_file(old).ok();
        }
    }
}

/// The software renderer behind the render pump: `mpv_render_context_render(sw)` into the pump's buffer.
struct SwRenderer {
    api: Arc<Api>,
    ctx: usize,
    handle: usize,
    style: Arc<Mutex<Option<SubtitleTextStyle>>>,
    st: Arc<Mutex<State>>,
}

impl Renderer for SwRenderer {
    fn frame_due(&mut self) -> bool {
        (unsafe { (self.api.rc_update)(self.ctx as *mut c_void) } & UPDATE_FRAME) != 0
    }

    fn resized(&mut self, width: u32, height: u32) {
        lock(&self.st).last_size = (width, height);
        apply_style_raw(&self.api, self.handle, &self.style, width, height);
    }

    fn render(&mut self, width: u32, height: u32, rgba: &mut [u8], skip_alpha: bool) -> bool {
        let mut size: [c_int; 2] = [width as c_int, height as c_int];
        let format = cstr("rgb0");
        // The pump has its own thread: mpv need not sleep inside render until the frame's display time either.
        let mut block: c_int = 0;
        let mut stride: usize = width as usize * 4;
        let mut params = [
            RenderParam {
                kind: RP_BLOCK_FOR_TARGET_TIME,
                data: std::ptr::from_mut(&mut block).cast(),
            },
            RenderParam {
                kind: RP_SW_SIZE,
                data: size.as_mut_ptr().cast(),
            },
            RenderParam {
                kind: RP_SW_FORMAT,
                data: format.as_ptr().cast_mut().cast(),
            },
            RenderParam {
                kind: RP_SW_STRIDE,
                data: std::ptr::from_mut(&mut stride).cast(),
            },
            RenderParam {
                kind: RP_SW_POINTER,
                data: rgba.as_mut_ptr().cast(),
            },
            RenderParam {
                kind: 0,
                data: std::ptr::null_mut(),
            },
        ];
        let rc = unsafe { (self.api.rc_render)(self.ctx as *mut c_void, params.as_mut_ptr()) };
        if rc < 0 {
            return false;
        }
        // "rgb0" leaves the fourth byte undefined. A host that draws the frame with a shader that ignores alpha (the GPU
        // layer) skips this pass: at 4K it is 8 million writes per frame.
        if !skip_alpha {
            for px in rgba.as_chunks_mut::<4>().0 {
                px[3] = 255;
            }
        }
        true
    }
}

// ---- the engine ------------------------------------------------------------------------------------------------------

#[derive(Default)]
struct State {
    events: Vec<EngineEvent>,
    clock: Option<f64>,
    tracks: ParsedTracks,
    pending_subs: Vec<translate::PendingSub>,
    loaded: bool,
    eof: EofGate,
    first_frame: bool,
    paused: bool,
    seeking: bool,
    /// The target of the seek mpv is still moving to; `playback-restart` answers it with `SeekLanded`.
    seek_to: Option<f64>,
    hints: DisplayHints,
    fps: Option<f64>,
    video_size: Option<(f64, f64)>,
    fill: bool,
    last_size: (u32, u32),
    sub_text: String,
    position: f64,
}

impl State {
    /// Feeds the end-of-file gate and queues `Ended` when it says so.
    fn report_eof(&mut self, input: EofInput) {
        let (next, report) = self.eof.step(input, self.loaded);
        self.eof = next;
        if report {
            self.events.push(EngineEvent::State(EngineState::Ended));
        }
    }
}

/// libmpv behind [`SurfaceEngine`]. All methods take `&self`; libmpv's client API is thread-safe, the render context is
/// serialised by a mutex.
pub struct MpvEngine {
    api: Arc<Api>,
    handle: *mut c_void,
    /// The render context of the software way (null on the GPU way, where the render thread owns it).
    sw_ctx: *mut c_void,
    /// The way the picture takes to the host, chosen once in [`MpvEngine::create`].
    path: OnceLock<RenderPath>,
    st: Arc<Mutex<State>>,
    /// The look of text subtitles, drawn by libass into the picture.
    style: Arc<Mutex<Option<SubtitleTextStyle>>>,
    skip_alpha: Arc<AtomicBool>,
    /// The `hwdec` value a title plays with unless the player asks for software decoding.
    hwdec: String,
    /// The host's waker: called when a frame is ready or libmpv has events (see [`MpvEngine::set_waker`]).
    wake: Arc<WakeSlot>,
    /// Runs the libmpv calls an event needs and that wait for the player core (see [`Worker`]).
    jobs: Option<std::sync::mpsc::Sender<Job>>,
    worker: Option<std::thread::JoinHandle<()>>,
}

/// The name of the GPU way in the logs and the technical badge.
#[cfg(target_os = "linux")]
const GPU_PATH: &str = "gpu-dmabuf";
#[cfg(windows)]
const GPU_PATH: &str = "gpu-wgl";

/// How the picture reaches the host.
enum RenderPath {
    /// libmpv's software renderer on the render pump's thread, RGBA buffers.
    Sw(RenderPump),
    /// libmpv's OpenGL renderer on its own thread, DMA-bufs the host samples.
    #[cfg(any(target_os = "linux", windows))]
    Gl(crate::mpv_gl::GlPump),
}

// The raw pointers are libmpv handles; the client API may be called from any thread and the render context sits behind a mutex.
unsafe impl Send for MpvEngine {}
unsafe impl Sync for MpvEngine {}

pub(crate) fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

pub(crate) fn cstr(s: &str) -> CString {
    CString::new(s.replace('\0', "")).unwrap_or_default()
}

impl MpvEngine {
    /// Writes the bundled Inter next to the temp dir (once) so libass finds the same font as the Apple overlay.
    fn fonts_dir() -> Option<String> {
        // Once per process (engines are made on several threads); the file is written next to its final name and
        // moved into place, so another process never reads a half-written font.
        static DIR: std::sync::OnceLock<Option<String>> = std::sync::OnceLock::new();
        DIR.get_or_init(|| {
            const INTER: &[u8] = include_bytes!("../fonts/Inter-SemiBold.ttf");
            let dir = std::env::temp_dir().join(format!("swiftly-subfonts-{}", INTER.len()));
            let file = dir.join("Inter-SemiBold.ttf");
            if std::fs::metadata(&file).ok().map(|m| m.len() as usize) != Some(INTER.len()) {
                std::fs::create_dir_all(&dir).ok()?;
                // Outside the fonts folder: libass scans it and must never meet a half-written font.
                let tmp = std::env::temp_dir()
                    .join(format!("swiftly-subfont-part-{}", std::process::id()));
                std::fs::write(&tmp, INTER).ok()?;
                std::fs::rename(&tmp, &file).ok()?;
            }
            dir.to_str().map(str::to_owned)
        })
        .clone()
    }

    /// Applies the stored look at this picture size (libass sizes and margins are relative to it).
    fn apply_style(&self, out_w: u32, out_h: u32) {
        apply_style_raw(&self.api, self.handle as usize, &self.style, out_w, out_h);
    }

    /// The host's shader ignores alpha: leave the fourth byte of every pixel as libmpv wrote it.
    pub fn set_skip_alpha(&self, on: bool) {
        self.skip_alpha.store(on, Ordering::Relaxed);
    }

    /// Loads libmpv, creates the player and the software render context (frames come as CPU buffers through
    /// [`VideoSurface::acquire_frame`]). Never blocks for good: a start that hangs (an audio stack that does not
    /// answer) is given up after [`START_LIMIT`] and tried once more with the silent output, then it is an error the
    /// player screen shows as a failed start.
    pub fn new() -> Result<MpvEngine, String> {
        Self::new_with(false)
    }

    /// Like [`MpvEngine::new`]; with `gpu` the engine draws on the GPU into shared DMA-bufs
    /// ([`VideoSurface::acquire_shared`]) when it can (Linux, EGL, GBM and an OpenGL libmpv), and falls back to the
    /// software renderer when it cannot. `SWIFTLY_VIDEO_PATH=cpu` forces the software way. The way taken is printed
    /// to stderr and named in [`VideoStats::path`].
    pub fn new_with(gpu: bool) -> Result<MpvEngine, String> {
        let gpu = gpu
            && std::env::var("SWIFTLY_VIDEO_PATH")
                .map(|v| v != "cpu")
                .unwrap_or(true);
        match bounded(START_LIMIT, move || Self::create(gpu)) {
            Some(r) => r,
            None => {
                FORCE_NULL_AUDIO.store(true, Ordering::Relaxed);
                bounded(START_LIMIT, move || Self::create(gpu))
                    .unwrap_or_else(|| Err("libmpv did not start in time".into()))
            }
        }
    }

    fn create(gpu: bool) -> Result<MpvEngine, String> {
        let api = Arc::new(Api::load()?);
        let h = unsafe { (api.create)() };
        if h.is_null() {
            return Err("mpv_create failed".into());
        }
        // Software way: the frame is copied to the CPU, so only the copying decoders can serve it. GPU way: the decoder
        // hands its surface to OpenGL (zero copy), where the system allows it.
        let hwdec_default = if gpu {
            if cfg!(target_os = "linux") {
                // Zero copy where OpenGL can take the decoder's surface, the copying decoders where it cannot.
                "vaapi,nvdec,vaapi-copy,nvdec-copy"
            } else if cfg!(windows) {
                // The GPU decodes (on the adapter the window draws on, see `d3d11-adapter` below); libmpv's WGL
                // renderer takes the picture back through system memory, which it can do at 4K without effort.
                "d3d11va-copy"
            } else {
                "auto-safe"
            }
        } else {
            "auto-copy-safe"
        };
        let hwdec = std::env::var("SWIFTLY_MPV_HWDEC").unwrap_or_else(|_| hwdec_default.into());
        let mut engine = MpvEngine {
            api,
            handle: h,
            sw_ctx: std::ptr::null_mut(),
            path: OnceLock::new(),
            st: Arc::new(Mutex::new(State::default())),
            style: Arc::new(Mutex::new(None)),
            skip_alpha: Arc::new(AtomicBool::new(false)),
            hwdec: hwdec.clone(),
            wake: Arc::new(WakeSlot::default()),
            jobs: None,
            worker: None,
        };
        {
            let (tx, rx) = std::sync::mpsc::channel();
            let w = Worker {
                api: Arc::clone(&engine.api),
                handle: h as usize,
                st: Arc::clone(&engine.st),
                style: Arc::clone(&engine.style),
            };
            engine.worker = std::thread::Builder::new()
                .name("mpv-events".into())
                .spawn(move || w.run(rx))
                .ok();
            engine.jobs = Some(tx);
        }
        for (k, v) in [
            ("config", "no"),
            ("terminal", "no"),
            ("vo", "libmpv"),
            ("idle", "yes"),
            ("keep-open", "yes"),
            ("video-sync", "audio"),
            ("sub-auto", "no"),
            ("sub-visibility", "yes"),
            ("osc", "no"),
            // libmpv's built-in Lua scripts (stats overlay, console, select, ...) run on their own threads; the app
            // draws all UI itself. Destroying the engine while they were still starting crashed with SIGSEGV in about
            // one of three parallel runs (`tests/mpv_parallel_new.rs`). Options an older libmpv lacks are ignored.
            ("load-scripts", "no"),
            ("load-stats-overlay", "no"),
            ("load-console", "no"),
            ("load-select", "no"),
            ("load-commands", "no"),
            ("load-positioning", "no"),
            ("load-context-menu", "no"),
            ("load-auto-profiles", "no"),
            ("input-default-bindings", "no"),
            ("ytdl", "no"),
            ("hwdec", hwdec.as_str()),
        ] {
            engine.set_option(k, v);
        }
        #[cfg(windows)]
        if gpu && let Some(name) = crate::mpv_gl::adapter_name() {
            // The decoder runs on the GPU the window draws on, never on the basic display adapter.
            engine.set_option("d3d11-adapter", name);
        }
        if let Some(dir) = Self::fonts_dir() {
            engine.set_option("sub-fonts-dir", &dir);
        }
        if silent_audio_needed(
            FORCE_NULL_AUDIO.load(Ordering::Relaxed),
            ABANDONED.load(Ordering::Relaxed),
        ) {
            engine.set_option("ao", "null");
        } else if let Some(list) = audio_output_list(&|k| std::env::var(k).ok(), &|p| p.exists()) {
            engine.set_option("ao", list);
        }
        // No device opens (a busy or missing one): carry on silently instead of failing the title.
        engine.set_option("audio-fallback-to-null", "yes");
        // A diagnosis aid: `SWIFTLY_MPV_LOG=<file>` writes libmpv's own log (decoder, hwdec, render messages).
        if let Ok(path) = std::env::var("SWIFTLY_MPV_LOG")
            && !path.is_empty()
        {
            engine.set_option("log-file", &path);
            engine.set_option("msg-level", "all=v");
        }
        if let Ok(extra) = std::env::var("SWIFTLY_MPV_OPTS") {
            for kv in extra.split(',').filter_map(|p| p.split_once('=')) {
                engine.set_option(kv.0, kv.1);
            }
        }
        let rc = unsafe { (engine.api.initialize)(h) };
        if rc < 0 {
            return Err(format!("mpv_initialize: {}", engine.api.err(rc)));
        }
        #[cfg(any(target_os = "linux", windows))]
        if gpu {
            let on_resize: Box<dyn Fn(u32, u32) + Send> = {
                let (api, style, st, handle) = (
                    Arc::clone(&engine.api),
                    Arc::clone(&engine.style),
                    Arc::clone(&engine.st),
                    h as usize,
                );
                Box::new(move |w, hh| {
                    lock(&st).last_size = (w, hh);
                    apply_style_raw(&api, handle, &style, w, hh);
                })
            };
            match crate::mpv_gl::GlPump::start(
                engine.api.rc(),
                h as usize,
                on_resize,
                Arc::clone(&engine.wake),
            ) {
                Ok(pump) => {
                    eprintln!(
                        "swiftly-player: video path {GPU_PATH} (libmpv OpenGL into shared buffers)"
                    );
                    let _ = engine.path.set(RenderPath::Gl(pump));
                }
                Err(e) => {
                    eprintln!(
                        "swiftly-player: GPU video path unavailable ({e}); using the software renderer"
                    );
                    // The software renderer copies frames to the CPU: its decoders are the copying ones.
                    engine.hwdec = "auto-copy-safe".into();
                    engine.set_option("hwdec", "auto-copy-safe");
                }
            }
        }
        if engine.path.get().is_none() {
            let api_type = cstr("sw");
            let mut params = [
                RenderParam {
                    kind: RP_API_TYPE,
                    data: api_type.as_ptr().cast_mut().cast(),
                },
                RenderParam {
                    kind: 0,
                    data: std::ptr::null_mut(),
                },
            ];
            let mut ctx: *mut c_void = std::ptr::null_mut();
            let rc = unsafe { (engine.api.rc_create)(&mut ctx, h, params.as_mut_ptr()) };
            if rc < 0 {
                return Err(format!(
                    "mpv_render_context_create(sw): {}",
                    engine.api.err(rc)
                ));
            }
            engine.sw_ctx = ctx;
            let pump = RenderPump::spawn_with(
                SwRenderer {
                    api: Arc::clone(&engine.api),
                    ctx: ctx as usize,
                    handle: h as usize,
                    style: Arc::clone(&engine.style),
                    st: Arc::clone(&engine.st),
                },
                Arc::clone(&engine.wake),
            )
            .map_err(|e| format!("render thread: {e}"))?;
            unsafe {
                (engine.api.rc_set_cb)(
                    ctx,
                    Some(sw_update_callback),
                    Arc::as_ptr(pump.shared()).cast_mut().cast(),
                );
            }
            eprintln!(
                "swiftly-player: video path cpu-sw (libmpv software renderer on the render thread)"
            );
            let _ = engine.path.set(RenderPath::Sw(pump));
        }
        // libmpv tells the host when events wait (time, track and state changes), so the host need not poll for them.
        unsafe {
            (engine.api.set_wakeup)(
                h,
                Some(mpv_wakeup_callback),
                Arc::as_ptr(&engine.wake).cast_mut().cast(),
            );
        }
        for (id, (name, fmt)) in [
            ("time-pos", FMT_DOUBLE),
            ("duration", FMT_DOUBLE),
            ("pause", FMT_FLAG),
            ("track-list", FMT_NONE),
            ("video-params", FMT_NONE),
            ("container-fps", FMT_DOUBLE),
            ("sub-text", FMT_STRING),
            ("paused-for-cache", FMT_FLAG),
            ("eof-reached", FMT_FLAG),
        ]
        .iter()
        .enumerate()
        {
            let n = cstr(name);
            unsafe { (engine.api.observe)(h, id as u64 + 1, n.as_ptr(), *fmt) };
        }
        Ok(engine)
    }

    /// Registers the host's waker. It is called (from libmpv's and the render threads) whenever a new frame is ready or
    /// libmpv has events waiting, so a host that redraws only on wake-ups never polls while the picture is still.
    pub fn set_waker(&self, waker: Waker) {
        self.wake.set(waker);
    }

    /// Whether a waker is registered (the host redraws on wake-ups).
    pub fn wakes_host(&self) -> bool {
        self.wake.is_set()
    }

    /// The version of the loaded libmpv client API as `major.minor`.
    pub fn api_version(&self) -> String {
        let v = unsafe { (self.api.version)() };
        format!("{}.{}", v >> 16, v & 0xffff)
    }

    /// The playback clock (mpv `time-pos`) read right now, not the polled value of the event queue. A test that matches a
    /// rendered frame with the cue windows reads it in the same call as the frame, so both belong to the same instant.
    pub fn clock_now(&self) -> Option<f64> {
        self.get_f64("time-pos")
    }

    fn set_option(&self, k: &str, v: &str) {
        let (k, v) = (cstr(k), cstr(v));
        unsafe { (self.api.set_option_string)(self.handle, k.as_ptr(), v.as_ptr()) };
    }

    fn set_prop(&self, k: &str, v: &str) -> bool {
        set_prop_raw(&self.api, self.handle as usize, k, v)
    }

    fn get_string(&self, k: &str) -> Option<String> {
        let k = cstr(k);
        let p = unsafe { (self.api.get_property_string)(self.handle, k.as_ptr()) };
        if p.is_null() {
            return None;
        }
        let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
        unsafe { (self.api.free)(p.cast()) };
        Some(s)
    }

    fn get_f64(&self, k: &str) -> Option<f64> {
        let k = cstr(k);
        let mut v: f64 = 0.0;
        let rc = unsafe {
            (self.api.get_property)(
                self.handle,
                k.as_ptr(),
                FMT_DOUBLE,
                std::ptr::from_mut(&mut v).cast(),
            )
        };
        (rc >= 0).then_some(v)
    }

    fn get_i64(&self, k: &str) -> Option<i64> {
        let k = cstr(k);
        let mut v: i64 = 0;
        let rc = unsafe {
            (self.api.get_property)(
                self.handle,
                k.as_ptr(),
                FMT_INT64,
                std::ptr::from_mut(&mut v).cast(),
            )
        };
        (rc >= 0).then_some(v)
    }

    fn command(&self, args: &[&str]) -> Result<(), String> {
        let owned: Vec<CString> = args.iter().map(|a| cstr(a)).collect();
        let mut ptrs: Vec<*const c_char> = owned.iter().map(|c| c.as_ptr()).collect();
        ptrs.push(std::ptr::null());
        let rc = unsafe { (self.api.command)(self.handle, ptrs.as_mut_ptr()) };
        if rc < 0 {
            Err(self.api.err(rc))
        } else {
            Ok(())
        }
    }

    fn job(&self, job: Job) {
        if let Some(tx) = &self.jobs {
            let _ = tx.send(job);
        }
    }

    fn drain(&self) {
        loop {
            let ev = unsafe { (self.api.wait_event)(self.handle, 0.0) };
            if ev.is_null() {
                break;
            }
            let ev = unsafe { &*ev };
            if ev.id == EV_NONE {
                break;
            }
            self.on_event(ev);
        }
    }

    fn on_event(&self, ev: &Event) {
        match ev.id {
            EV_START_FILE => {
                let mut s = lock(&self.st);
                s.loaded = false;
                s.first_frame = false;
                s.eof = s.eof.step(EofInput::Reset, false).0;
                s.paused = false;
                s.events.push(EngineEvent::State(EngineState::Loading));
                drop(s);
                self.job(Job::StartFile);
            }
            EV_FILE_LOADED => {
                let subs = std::mem::take(&mut lock(&self.st).pending_subs);
                lock(&self.st).loaded = true;
                let (w, h) = lock(&self.st).last_size;
                self.job(Job::FileLoaded(
                    subs,
                    if w == 0 { 1920 } else { w },
                    if h == 0 { 1080 } else { h },
                ));
            }
            EV_SEEK => {
                let mut s = lock(&self.st);
                s.eof = s.eof.step(EofInput::Reset, s.loaded).0;
                s.seeking = true;
                s.events.push(EngineEvent::State(EngineState::Seeking));
            }
            EV_PLAYBACK_RESTART => {
                let mut s = lock(&self.st);
                let state = if s.paused {
                    EngineState::Paused
                } else {
                    EngineState::Playing
                };
                s.seeking = false;
                s.events.push(EngineEvent::State(state));
                if let Some(target) = s.seek_to.take() {
                    s.events.push(EngineEvent::SeekLanded { target });
                }
                if !s.first_frame {
                    s.first_frame = true;
                    s.events.push(EngineEvent::FirstFrame);
                }
            }
            EV_END_FILE => {
                let data = ev.data.cast::<EventEndFile>();
                let (reason, error) = if data.is_null() {
                    (END_EOF, 0)
                } else {
                    unsafe { ((*data).reason, (*data).error) }
                };
                let mut s = lock(&self.st);
                if reason == END_ERROR {
                    s.events.push(EngineEvent::State(EngineState::Error {
                        message: self.api.err(error),
                        kind: Some("mpv".into()),
                    }));
                } else if reason == END_EOF {
                    s.report_eof(EofInput::EndFile);
                }
            }
            EV_PROPERTY_CHANGE => {
                let p = ev.data.cast::<EventProperty>();
                if p.is_null() {
                    return;
                }
                let (name, format, data) = unsafe {
                    (
                        CStr::from_ptr((*p).name).to_string_lossy().into_owned(),
                        (*p).format,
                        (*p).data,
                    )
                };
                self.on_property(&name, format, data);
            }
            _ => {}
        }
    }

    fn on_property(&self, name: &str, format: c_int, data: *mut c_void) {
        let number =
            || (format == FMT_DOUBLE && !data.is_null()).then(|| unsafe { *data.cast::<f64>() });
        let flag = || {
            (format == FMT_FLAG && !data.is_null()).then(|| unsafe { *data.cast::<c_int>() } != 0)
        };
        match name {
            "time-pos" => {
                if let Some(t) = number() {
                    let mut s = lock(&self.st);
                    s.position = t;
                    s.clock = Some(t);
                }
            }
            "duration" => {
                if let Some(d) = number() {
                    lock(&self.st).events.push(EngineEvent::Duration(d));
                }
            }
            "pause" => {
                if let Some(p) = flag() {
                    let mut s = lock(&self.st);
                    s.paused = p;
                    // mpv pauses itself on the last frame (keep-open): that is the end, not a user pause.
                    if s.first_frame && !s.seeking && s.eof == EofGate::Running {
                        s.events.push(EngineEvent::State(if p {
                            EngineState::Paused
                        } else {
                            EngineState::Playing
                        }));
                    }
                }
            }
            "eof-reached" => {
                if let Some(reached) = flag() {
                    lock(&self.st).report_eof(EofInput::Flag(reached));
                }
            }
            "track-list" => self.job(Job::TrackList),
            "video-params" => self.job(Job::VideoParams),
            "container-fps" => {
                if let Some(f) = number() {
                    let mut s = lock(&self.st);
                    s.fps = Some(f);
                    s.hints.frame_rate = Some(f).filter(|f| *f > 0.0);
                }
            }
            "sub-text" if format == FMT_STRING && !data.is_null() => {
                // libass draws the text into the picture; the host draws no cue of its own.
                let p = unsafe { *data.cast::<*const c_char>() };
                let text = if p.is_null() {
                    String::new()
                } else {
                    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
                };
                lock(&self.st).sub_text = text;
            }
            _ => {}
        }
    }
}

/// How long closing the engine may take before it is abandoned (a normal close is well under a second).
const CLOSE_LIMIT: Duration = Duration::from_secs(4);

impl Drop for MpvEngine {
    /// Closing never blocks the caller for good: libmpv's audio output can hang while it shuts down (libpipewire's
    /// `pw_thread_loop_stop`, a sound server that stops answering). The teardown runs on its own thread; when it
    /// does not finish in [`CLOSE_LIMIT`] the engine is left behind (the stuck thread dies with the process).
    /// The render thread stops first (the GPU way frees its render context on that thread), then the software
    /// context goes, then the player.
    fn drop(&mut self) {
        let path = self.path.take();
        let wake = Arc::clone(&self.wake);
        let ctx = std::mem::replace(&mut self.sw_ctx, std::ptr::null_mut()) as usize;
        let handle = self.handle as usize;
        let api = Arc::clone(&self.api);
        drop(self.jobs.take());
        let worker = self.worker.take();
        let (tx, rx) = std::sync::mpsc::channel();
        let spawned = std::thread::Builder::new()
            .name("mpv-close".into())
            .spawn(move || {
                // No more wake-ups for the host; joins the render thread: nothing draws any more after this.
                unsafe { (api.set_wakeup)(handle as *mut c_void, None, std::ptr::null_mut()) };
                drop(path);
                drop(wake);
                if ctx != 0 {
                    unsafe {
                        (api.rc_set_cb)(ctx as *mut c_void, None, std::ptr::null_mut());
                        (api.rc_free)(ctx as *mut c_void);
                    }
                }
                // The worker leaves when its queue is closed; it must be gone before the handle is destroyed.
                if let Some(w) = worker {
                    let _ = w.join();
                }
                unsafe { (api.terminate_destroy)(handle as *mut c_void) };
                let _ = tx.send(());
            });
        if spawned.is_ok() && rx.recv_timeout(CLOSE_LIMIT).is_err() {
            ABANDONED.fetch_add(1, Ordering::Relaxed);
        }
    }
}

impl PlaybackEngine for MpvEngine {
    fn set_audio_output(&self, mode: &swiftly_playback::decoder_choice::AudioOutputMode) {
        for (name, value) in mode.options() {
            if !self.set_prop(name, &value) {
                self.set_option(name, &value);
            }
        }
    }

    fn load(&self, r: EngineLoad) {
        {
            let mut s = lock(&self.st);
            *s = State {
                fill: s.fill,
                ..State::default()
            };
            s.pending_subs = r
                .external_subtitles
                .iter()
                .map(|e| translate::PendingSub {
                    url: e.url.clone(),
                    title: e.name.clone(),
                    language: e.language.clone(),
                })
                .collect();
        }
        if r.headers.is_empty() {
            self.set_prop("http-header-fields", "");
        } else {
            let list: Vec<String> = r.headers.iter().map(|(k, v)| format!("{k}: {v}")).collect();
            self.set_prop("http-header-fields", &list.join(","));
        }
        self.set_prop(
            "start",
            &r.start
                .map_or_else(|| "0".to_owned(), |t| format!("{t:.3}")),
        );
        // Server indexes are mapped to mpv ids once the track list is known; until then the default pick plays.
        self.set_prop("aid", "auto");
        self.set_prop("sid", "no");
        // A title the player wants decoded in software must not leave the next one without hardware decoding.
        self.set_prop(
            "hwdec",
            if r.software_decode {
                "no"
            } else {
                self.hwdec.as_str()
            },
        );
        match self.path.get() {
            Some(RenderPath::Sw(p)) => p.reset(),
            #[cfg(any(target_os = "linux", windows))]
            Some(RenderPath::Gl(p)) => p.reset(),
            None => {}
        }
        let (secs, bytes) = match r.buffer_level {
            BufferLevel::Normal => ("30", "150MiB"),
            BufferLevel::Bad => ("90", "300MiB"),
            BufferLevel::VeryBad => ("240", "600MiB"),
        };
        self.set_prop("cache-secs", secs);
        self.set_prop("demuxer-max-bytes", bytes);
        if let Err(e) = self.command(&["loadfile", &r.url, "replace"]) {
            lock(&self.st)
                .events
                .push(EngineEvent::State(EngineState::Error {
                    message: e,
                    kind: Some("mpv".into()),
                }));
        }
    }

    fn play(&self) {
        self.set_prop("pause", "no");
    }

    fn pause(&self) {
        self.set_prop("pause", "yes");
    }

    fn seek(&self, seconds: f64) {
        lock(&self.st).seek_to = Some(seconds);
        let _ = self.command(&["seek", &format!("{seconds:.3}"), "absolute+exact"]);
    }

    fn set_rate(&self, tempo: f32) {
        self.set_prop("speed", &format!("{tempo:.3}"));
    }

    fn set_volume(&self, percent: u8) {
        self.set_prop("volume", &percent.min(100).to_string());
    }

    fn set_audio_delay(&self, milliseconds: i32) {
        self.set_prop(
            "audio-delay",
            &format!("{:.3}", f64::from(milliseconds) / 1000.0),
        );
    }

    fn select_audio(&self, server_index: i32) -> bool {
        let id = lock(&self.st)
            .tracks
            .audio_ids
            .iter()
            .find(|(ours, _)| *ours == i64::from(server_index))
            .map(|(_, m)| *m);
        id.is_some_and(|m| self.set_prop("aid", &m.to_string()))
    }

    fn select_subtitle(&self, server_index: i32) -> SubtitleRoute {
        if server_index < 0 {
            self.set_prop("sid", "no");
            return SubtitleRoute::EngineDrawn;
        }
        let (id, codec) = {
            let s = lock(&self.st);
            let found = s
                .tracks
                .subtitle_ids
                .iter()
                .find(|(ours, _)| *ours == i64::from(server_index))
                .map(|(_, m)| *m);
            let codec = s
                .tracks
                .subtitles
                .iter()
                .find(|t| t.id == i64::from(server_index))
                .map(|t| t.codec.clone())
                .unwrap_or_default();
            (found, codec)
        };
        let Some(id) = id else {
            return SubtitleRoute::Unsupported;
        };
        // libass draws every kind (bitmap, ASS, text) into the picture. A native ASS track keeps its own style
        // when the look says so; plain text (SRT, VTT, a server-converted SRT) always takes the look.
        let keep = lock(&self.style).as_ref().is_none_or(|s| s.keep_file_style);
        self.set_prop("sub-ass-override", translate::ass_override(&codec, keep));
        self.set_prop("sid", &id.to_string());
        SubtitleRoute::EngineDrawn
    }

    fn set_subtitle_style(&self, style: &SubtitleTextStyle) {
        *lock(&self.style) = Some(style.clone());
        // Before a file is loaded the look is only stored: it is applied when the file is up (libass is not
        // touched while the player is still starting, which crashed now and then under load).
        let (w, h, loaded) = {
            let s = lock(&self.st);
            (s.last_size.0, s.last_size.1, s.loaded)
        };
        if !loaded {
            return;
        }
        self.apply_style(if w == 0 { 1920 } else { w }, if h == 0 { 1080 } else { h });
        // The switch may have changed under the track on screen.
        if let Some(codec) = self.get_string("current-tracks/sub/codec") {
            self.set_prop(
                "sub-ass-override",
                translate::ass_override(&codec, style.keep_file_style),
            );
        }
    }

    fn set_subtitle_delay(&self, milliseconds: i32) {
        self.set_prop(
            "sub-delay",
            &format!("{:.3}", f64::from(milliseconds) / 1000.0),
        );
    }

    fn set_fill(&self, on: bool) {
        lock(&self.st).fill = on;
        self.set_prop("panscan", if on { "1.0" } else { "0.0" });
    }

    fn place(&self, _rect: Rect) {}

    fn stop(&self, _reset_display: bool) {
        let _ = self.command(&["stop"]);
    }

    fn pip(&self, _command: PipCmd) {}
}

impl VideoSurface for MpvEngine {
    fn delivery(&self) -> FrameDelivery {
        FrameDelivery::Frames
    }

    fn place(&self, _rect: Rect) {}

    /// Never draws and never waits: it tells the render thread which size the UI wants and takes the newest frame that
    /// thread has finished, if there is one.
    fn acquire_frame(&self, max_width: u32, max_height: u32, out: &mut FrameBuffer) -> FrameStatus {
        self.drain();
        let Some(RenderPath::Sw(pump)) = self.path.get() else {
            return FrameStatus::NotReady;
        };
        let Some((w, h)) = self.frame_box(max_width, max_height) else {
            return FrameStatus::NotReady;
        };
        pump.want(w, h, self.skip_alpha.load(Ordering::Relaxed));
        pump.take(out)
    }

    #[cfg(any(unix, windows))]
    fn acquire_shared(&self, max_width: u32, max_height: u32) -> crate::SharedStatus {
        #[cfg(any(target_os = "linux", windows))]
        if let Some(RenderPath::Gl(pump)) = self.path.get() {
            self.drain();
            let Some((w, h)) = self.frame_box(max_width, max_height) else {
                return crate::SharedStatus::NotReady;
            };
            pump.want(w, h);
            return pump.take();
        }
        let _ = (max_width, max_height);
        crate::SharedStatus::Unsupported
    }

    fn display_hints(&self) -> DisplayHints {
        lock(&self.st).hints
    }
}

impl MpvEngine {
    /// The picture size to draw for a box of `max_width x max_height`: the box (fill), or the largest size of the
    /// source's aspect that fits it (fit). `None` until the source size is known.
    fn frame_box(&self, max_width: u32, max_height: u32) -> Option<(u32, u32)> {
        let (fill, source) = {
            let s = lock(&self.st);
            (s.fill, s.hints.size)
        };
        let (sw, sh) = source?;
        Some(if fill {
            (max_width, max_height)
        } else {
            let k =
                (f64::from(max_width) / f64::from(sw)).min(f64::from(max_height) / f64::from(sh));
            (
                ((f64::from(sw) * k) as u32).max(2) & !1,
                ((f64::from(sh) * k) as u32).max(2) & !1,
            )
        })
    }
}

impl SurfaceEngine for MpvEngine {
    fn poll_events(&self) -> Vec<EngineEvent> {
        self.drain();
        let mut s = lock(&self.st);
        let mut out = std::mem::take(&mut s.events);
        if let Some(t) = s.clock.take() {
            out.push(EngineEvent::Clock {
                position: t,
                source_time: t,
            });
        }
        out
    }

    fn stats(&self) -> VideoStats {
        let (name, p) = match self.path.get() {
            Some(RenderPath::Sw(p)) => ("cpu-sw", p.stats()),
            #[cfg(any(target_os = "linux", windows))]
            Some(RenderPath::Gl(p)) => (GPU_PATH, p.stats()),
            None => ("", crate::pump::PumpStats::default()),
        };
        VideoStats {
            path: name.to_owned(),
            render_p50_ms: p.p50_ms,
            render_p99_ms: p.p99_ms,
            frames_superseded: p.superseded,
            render_size: p.size,
            frames_rendered: p.rendered,
            decoder_drops: self.get_i64("decoder-frame-drop-count").unwrap_or(0).max(0) as u64,
            output_drops: self.get_i64("frame-drop-count").unwrap_or(0).max(0) as u64,
            avg_render_ms: p.avg_ms,
            decoded_fps: self.get_f64("estimated-vf-fps").unwrap_or(0.0),
            hwdec: self
                .get_string("hwdec-current")
                .unwrap_or_else(|| "none".into()),
        }
    }

    fn audio_devices(&self) -> Vec<AudioDevice> {
        let Some(json) = self.get_string("audio-device-list") else {
            return Vec::new();
        };
        let Ok(serde_json::Value::Array(list)) = serde_json::from_str::<serde_json::Value>(&json)
        else {
            return Vec::new();
        };
        list.iter()
            .filter_map(|d| {
                let id = d.get("name")?.as_str()?.to_owned();
                let name = d
                    .get("description")
                    .and_then(|v| v.as_str())
                    .unwrap_or(&id)
                    .to_owned();
                Some(AudioDevice { id, name })
            })
            .collect()
    }

    fn set_audio_device(&self, id: &str) -> bool {
        self.audio_devices().iter().any(|d| d.id == id) && self.set_prop("audio-device", id)
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            hdr_passthrough: false,
            frame_rate_match: false,
            pip: false,
            audio_devices: true,
            draws_bitmap_subtitles: true,
            audio_passthrough: true,
            exclusive_audio: true,
        }
    }
}

/// Which options a caller might want to print next to a measurement.
pub fn describe(engine: &MpvEngine) -> HashMap<&'static str, String> {
    let mut m = HashMap::new();
    m.insert("api", engine.api_version());
    m.insert(
        "hwdec-requested",
        engine.get_string("hwdec").unwrap_or_default(),
    );
    m.insert(
        "video-codec",
        engine.get_string("video-codec").unwrap_or_default(),
    );
    m
}

#[cfg(test)]
mod audio_choice_tests {
    use super::{ABANDON_LIMIT, audio_output_list, bounded, silent_audio_needed};
    use std::path::Path;
    use std::time::Duration;

    fn pick(env: &[(&str, &str)], sockets: &[&str]) -> Option<&'static str> {
        audio_output_list(
            &|k| {
                env.iter()
                    .find(|(n, _)| *n == k)
                    .map(|(_, v)| (*v).to_owned())
            },
            &|p: &Path| sockets.iter().any(|s| p == Path::new(s)),
        )
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn no_sound_server_skips_pipewire_and_pulse() {
        assert_eq!(
            pick(&[("XDG_RUNTIME_DIR", "/run/user/1000")], &[]),
            Some("alsa,null")
        );
        assert_eq!(pick(&[], &[]), Some("alsa,null"));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn a_reachable_sound_server_is_used() {
        let xdg = [("XDG_RUNTIME_DIR", "/run/user/1000")];
        assert_eq!(
            pick(&xdg, &["/run/user/1000/pipewire-0"]),
            None,
            "pipewire socket: libmpv's own order"
        );
        assert_eq!(
            pick(&xdg, &["/run/user/1000/pulse/native"]),
            Some("pulse,alsa,null")
        );
        assert_eq!(pick(&[("PIPEWIRE_REMOTE", "pipewire-1")], &[]), None);
        assert_eq!(
            pick(&[("PIPEWIRE_RUNTIME_DIR", "/x")], &["/x/pipewire-0"]),
            None
        );
        assert_eq!(
            pick(&[("PULSE_SERVER", "tcp:host")], &[]),
            Some("pulse,alsa,null")
        );
    }

    #[test]
    fn a_hung_start_gives_up_instead_of_blocking() {
        let t = std::time::Instant::now();
        let hung = bounded(Duration::from_millis(100), || {
            std::thread::sleep(Duration::from_secs(5));
            1
        });
        assert_eq!(hung, None);
        assert!(
            t.elapsed() < Duration::from_secs(2),
            "the caller waited for the hung work"
        );
        assert_eq!(bounded(Duration::from_secs(5), || 7), Some(7));
    }

    #[test]
    fn a_stuck_audio_stack_switches_new_engines_to_silence() {
        assert!(!silent_audio_needed(false, 0));
        assert!(!silent_audio_needed(false, ABANDON_LIMIT - 1));
        assert!(silent_audio_needed(false, ABANDON_LIMIT));
        assert!(silent_audio_needed(true, 0));
    }
}
