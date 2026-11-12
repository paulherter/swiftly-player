//! The libmpv engine for Windows and Linux (and the Mac when mpv is installed).
//!
//! libmpv is loaded at run time (`libmpv-2.dll`, `libmpv.so.2`, `libmpv.dylib`, or the path in `SWIFTLY_LIBMPV`), so the
//! crate builds without any mpv files. Video goes through the render API with the software renderer (`MPV_RENDER_API_TYPE_SW`):
//! the host asks for a frame at the size it wants and gets RGBA. This is the last rung of the G3 ladder and the one that
//! works on every GPU; the GL/Vulkan rungs replace [`MpvEngine::render_into`] and nothing above it.
#![allow(unsafe_code)]

use crate::translate::{self, EofGate, EofInput, ParsedTracks};
use crate::{
    AudioDevice, Capabilities, DisplayHints, FrameBuffer, FrameDelivery, FrameStatus,
    SurfaceEngine, VideoStats, VideoSurface,
};
use libloading::Library;
use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char, c_double, c_int, c_void};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};
use swiftly_playback::engine::{
    EngineEvent, EngineLoad, EngineState, PipCmd, PlaybackEngine, Rect, SubtitleRoute,
    SubtitleTextStyle,
};
use swiftly_rules::buffer_level::BufferLevel;

// ---- the C API -----------------------------------------------------------------------------------------------------

#[repr(C)]
struct RenderParam {
    kind: c_int,
    data: *mut c_void,
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
const RP_API_TYPE: c_int = 1;
const RP_BLOCK_FOR_TARGET_TIME: c_int = 12;
const RP_SW_SIZE: c_int = 17;
const RP_SW_FORMAT: c_int = 18;
const RP_SW_STRIDE: c_int = 19;
const RP_SW_POINTER: c_int = 20;
const UPDATE_FRAME: u64 = 1;

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
type FnErr = unsafe extern "C" fn(c_int) -> *const c_char;
type FnVersion = unsafe extern "C" fn() -> u64;

/// The functions we use, resolved once. The library stays loaded as long as this value lives.
struct Api {
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
    frames_rendered: u64,
    render_ns: u128,
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
    render: Mutex<*mut c_void>,
    st: Mutex<State>,
    /// The look of text subtitles, drawn by libass into the picture.
    style: Mutex<Option<SubtitleTextStyle>>,
    skip_alpha: AtomicBool,
}

// The raw pointers are libmpv handles; the client API may be called from any thread and the render context sits behind a mutex.
unsafe impl Send for MpvEngine {}
unsafe impl Sync for MpvEngine {}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

fn cstr(s: &str) -> CString {
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
        let Some(style) = lock(&self.style).clone() else {
            return;
        };
        for (k, v) in translate::text_options(&style, out_w, out_h) {
            self.set_prop(k, &v);
        }
    }

    /// The host's shader ignores alpha: leave the fourth byte of every pixel as libmpv wrote it.
    pub fn set_skip_alpha(&self, on: bool) {
        self.skip_alpha.store(on, Ordering::Relaxed);
    }

    /// Loads libmpv, creates the player and the software render context.
    pub fn new() -> Result<MpvEngine, String> {
        let api = Arc::new(Api::load()?);
        let h = unsafe { (api.create)() };
        if h.is_null() {
            return Err("mpv_create failed".into());
        }
        let engine = MpvEngine {
            api,
            handle: h,
            render: Mutex::new(std::ptr::null_mut()),
            st: Mutex::new(State::default()),
            style: Mutex::new(None),
            skip_alpha: AtomicBool::new(false),
        };
        let hwdec = std::env::var("SWIFTLY_MPV_HWDEC").unwrap_or_else(|_| "auto-copy-safe".into());
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
        if let Some(dir) = Self::fonts_dir() {
            engine.set_option("sub-fonts-dir", &dir);
        }
        if let Some(list) = audio_output_list(&|k| std::env::var(k).ok(), &|p| p.exists()) {
            engine.set_option("ao", list);
        }
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
        *lock(&engine.render) = ctx;
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
        let (k, v) = (cstr(k), cstr(v));
        unsafe { (self.api.set_property_string)(self.handle, k.as_ptr(), v.as_ptr()) >= 0 }
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

    /// Renders the current picture as `width x height` RGBA (alpha forced to 255). Returns the time it took.
    fn render_into(
        &self,
        width: u32,
        height: u32,
        out: &mut FrameBuffer,
    ) -> Option<std::time::Duration> {
        let ctx = *lock(&self.render);
        if ctx.is_null() || width == 0 || height == 0 {
            return None;
        }
        out.resize(width, height);
        let started = Instant::now();
        let mut size: [c_int; 2] = [width as c_int, height as c_int];
        let format = cstr("rgb0");
        // The host paces itself; mpv must not sleep inside render until the frame's display time.
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
                data: out.rgba.as_mut_ptr().cast(),
            },
            RenderParam {
                kind: 0,
                data: std::ptr::null_mut(),
            },
        ];
        let rc = unsafe { (self.api.rc_render)(ctx, params.as_mut_ptr()) };
        if rc < 0 {
            return None;
        }
        // "rgb0" leaves the fourth byte undefined. A host that draws the frame with a shader that ignores alpha (the GPU
        // layer) skips this pass: at 4K it is 8 million writes per frame.
        if !self.skip_alpha.load(Ordering::Relaxed) {
            for px in out.rgba.as_chunks_mut::<4>().0 {
                px[3] = 255;
            }
        }
        Some(started.elapsed())
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
                // keep-open leaves mpv paused on the last frame of the previous file; the new file plays.
                self.set_prop("pause", "no");
            }
            EV_FILE_LOADED => {
                let subs = std::mem::take(&mut lock(&self.st).pending_subs);
                for sub in subs {
                    let mut args = vec!["sub-add", sub.url.as_str(), "auto"];
                    if let Some(n) = sub.title.as_deref() {
                        args.push(n);
                    }
                    if let Some(l) = sub.language.as_deref() {
                        if args.len() == 3 {
                            args.push("external");
                        }
                        args.push(l);
                    }
                    let _ = self.command(&args);
                }
                lock(&self.st).loaded = true;
                let (w, h) = lock(&self.st).last_size;
                self.apply_style(if w == 0 { 1920 } else { w }, if h == 0 { 1080 } else { h });
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
            "track-list" => {
                if let Some(json) = self.get_string("track-list") {
                    let t = translate::parse_tracks(&json);
                    let mut s = lock(&self.st);
                    s.events.push(t.event());
                    s.tracks = t;
                }
            }
            "video-params" => {
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
    fn drop(&mut self) {
        let ctx = std::mem::replace(&mut *lock(&self.render), std::ptr::null_mut()) as usize;
        let handle = self.handle as usize;
        let api = Arc::clone(&self.api);
        let (tx, rx) = std::sync::mpsc::channel();
        let spawned = std::thread::Builder::new()
            .name("mpv-close".into())
            .spawn(move || {
                if ctx != 0 {
                    unsafe { (api.rc_free)(ctx as *mut c_void) };
                }
                unsafe { (api.terminate_destroy)(handle as *mut c_void) };
                let _ = tx.send(());
            });
        if spawned.is_ok() {
            let _ = rx.recv_timeout(CLOSE_LIMIT);
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
        if r.software_decode {
            self.set_prop("hwdec", "no");
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

    fn acquire_frame(&self, max_width: u32, max_height: u32, out: &mut FrameBuffer) -> FrameStatus {
        self.drain_for_frame();
        let (fill, source, last_size) = {
            let s = lock(&self.st);
            (s.fill, s.hints.size, s.last_size)
        };
        let Some((sw, sh)) = source else {
            return FrameStatus::NotReady;
        };
        let (w, h) = if fill {
            (max_width, max_height)
        } else {
            let k =
                (f64::from(max_width) / f64::from(sw)).min(f64::from(max_height) / f64::from(sh));
            (
                ((f64::from(sw) * k) as u32).max(2) & !1,
                ((f64::from(sh) * k) as u32).max(2) & !1,
            )
        };
        let ctx = *lock(&self.render);
        if ctx.is_null() {
            return FrameStatus::NotReady;
        }
        let flags = unsafe { (self.api.rc_update)(ctx) };
        if flags & UPDATE_FRAME == 0 && last_size == (w, h) {
            return FrameStatus::Unchanged;
        }
        if last_size != (w, h) {
            self.apply_style(w, h);
        }
        match self.render_into(w, h, out) {
            Some(took) => {
                let mut s = lock(&self.st);
                s.last_size = (w, h);
                if flags & UPDATE_FRAME != 0 {
                    s.frames_rendered += 1;
                    s.render_ns += took.as_nanos();
                }
                FrameStatus::New
            }
            None => FrameStatus::NotReady,
        }
    }

    fn display_hints(&self) -> DisplayHints {
        lock(&self.st).hints
    }
}

impl MpvEngine {
    fn drain_for_frame(&self) {
        self.drain();
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
        let (frames, ns) = {
            let s = lock(&self.st);
            (s.frames_rendered, s.render_ns)
        };
        VideoStats {
            frames_rendered: frames,
            decoder_drops: self.get_i64("decoder-frame-drop-count").unwrap_or(0).max(0) as u64,
            output_drops: self.get_i64("frame-drop-count").unwrap_or(0).max(0) as u64,
            avg_render_ms: if frames == 0 {
                0.0
            } else {
                ns as f64 / 1.0e6 / frames as f64
            },
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
    use super::audio_output_list;
    use std::path::Path;

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
}
