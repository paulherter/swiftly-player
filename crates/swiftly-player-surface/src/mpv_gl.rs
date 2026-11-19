//! The GPU way of the libmpv engine (Linux): libmpv's OpenGL renderer draws, scales and tone-maps the picture on the GPU
//! into a small ring of DMA-bufs, and the host samples those buffers directly (no frame is ever copied to the CPU).
//!
//! Everything GL lives on one thread of its own ("video-gpu"): an EGL context on a GBM device of the render node (no
//! window, no compositor), the libmpv render context, and the ring. mpv's update callback wakes the thread; it asks
//! libmpv whether a frame is due, draws it into a free buffer of the ring (linear layout, so any Vulkan driver can
//! import it), waits for the GPU (`glFinish`, on this thread only) and publishes the buffer as the newest frame.
//! The UI side asks for the newest frame ([`GlPump::take`]) and gets a buffer number; it never waits. With hardware
//! decoding the decoded surface goes to OpenGL through VA-API / EGL (zero copy); libmpv does HDR tone mapping and
//! scaling in its shaders.
//!
//! GL, EGL and GBM are loaded at run time (`libloading`), like libmpv: the crate links against none of them, and a
//! machine without them keeps the software renderer ([`GlPump::start`] returns an error then).
#![allow(unsafe_code)]

use crate::mpv::{
    RP_API_TYPE, RP_BLOCK_FOR_TARGET_TIME, RP_DRM_DISPLAY_V2, RP_FLIP_Y, RP_OPENGL_FBO,
    RP_OPENGL_INIT_PARAMS, RcApi, RenderParam, UPDATE_FRAME, cstr, lock,
};
use crate::pump::{PumpStats, WakeSlot};
use crate::{DmabufImage, SharedFrame, SharedStatus};
use libloading::Library;
use std::ffi::{c_char, c_int, c_void};
use std::os::fd::{FromRawFd, OwnedFd, RawFd};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

/// Buffers in the ring: one being drawn, the newest finished one, the one the host holds, and one of slack so the GPU
/// is done reading a buffer before it is drawn into again.
const RING: usize = 4;
/// A new size must stay for this long before the ring is made again (a window drag changes it every tick).
const DEBOUNCE: Duration = Duration::from_millis(200);
const IDLE_WAIT: Duration = Duration::from_millis(250);
const SAMPLES: usize = 512;
/// How long [`GlPump::start`] waits for the render thread to come up (EGL, GBM and the libmpv context).
const START_WAIT: Duration = Duration::from_secs(5);

const FOURCC_ABGR8888: u32 = 0x3432_4241; // 'AB24': R, G, B, A in memory
const DRM_FORMAT_MOD_LINEAR: u64 = 0;
const DRM_FORMAT_MOD_INVALID: u64 = 0x00ff_ffff_ffff_ffff;
const GBM_BO_USE_RENDERING: u32 = 1 << 2;
const GBM_BO_USE_LINEAR: u32 = 1 << 4;

type Ptr = *mut c_void;

// ---- EGL, GBM and GL entry points -----------------------------------------------------------------------------------

struct Egl {
    _lib: &'static Library,
    get_proc: unsafe extern "C" fn(*const c_char) -> Ptr,
    initialize: unsafe extern "C" fn(Ptr, *mut i32, *mut i32) -> u32,
    terminate: unsafe extern "C" fn(Ptr) -> u32,
    bind_api: unsafe extern "C" fn(u32) -> u32,
    choose_config: unsafe extern "C" fn(Ptr, *const i32, *mut Ptr, i32, *mut i32) -> u32,
    create_context: unsafe extern "C" fn(Ptr, Ptr, Ptr, *const i32) -> Ptr,
    destroy_context: unsafe extern "C" fn(Ptr, Ptr) -> u32,
    make_current: unsafe extern "C" fn(Ptr, Ptr, Ptr, Ptr) -> u32,
    get_error: unsafe extern "C" fn() -> i32,
    create_image: unsafe extern "C" fn(Ptr, Ptr, u32, Ptr, *const i32) -> Ptr,
    destroy_image: unsafe extern "C" fn(Ptr, Ptr) -> u32,
    display: Ptr,
    context: Ptr,
}

struct Gbm {
    _lib: &'static Library,
    destroy_device: unsafe extern "C" fn(Ptr),
    bo_create: unsafe extern "C" fn(Ptr, u32, u32, u32, u32) -> Ptr,
    bo_destroy: unsafe extern "C" fn(Ptr),
    bo_fd: unsafe extern "C" fn(Ptr) -> c_int,
    bo_stride: unsafe extern "C" fn(Ptr) -> u32,
    bo_modifier: unsafe extern "C" fn(Ptr) -> u64,
    device: Ptr,
}

struct Gl {
    gen_textures: unsafe extern "C" fn(i32, *mut u32),
    bind_texture: unsafe extern "C" fn(u32, u32),
    delete_textures: unsafe extern "C" fn(i32, *const u32),
    gen_framebuffers: unsafe extern "C" fn(i32, *mut u32),
    bind_framebuffer: unsafe extern "C" fn(u32, u32),
    framebuffer_texture_2d: unsafe extern "C" fn(u32, u32, u32, u32, i32),
    check_framebuffer_status: unsafe extern "C" fn(u32) -> u32,
    delete_framebuffers: unsafe extern "C" fn(i32, *const u32),
    finish: unsafe extern "C" fn(),
    image_target_texture_2d: unsafe extern "C" fn(u32, Ptr),
}

/// A system library (EGL, GBM), loaded once per process and never unloaded. Closing and loading them again for every
/// engine breaks Mesa's EGL after about ten rounds (the display is gone, `eglCreateImageKHR` is not found any more).
fn system_library(names: &[&str]) -> Option<&'static Library> {
    static LOADED: Mutex<Vec<(String, &'static Library)>> = Mutex::new(Vec::new());
    let mut loaded = lock(&LOADED);
    if let Some((_, l)) = loaded.iter().find(|(n, _)| names.contains(&n.as_str())) {
        return Some(*l);
    }
    let (name, lib) = names
        .iter()
        .find_map(|n| unsafe { Library::new(n) }.ok().map(|l| (*n, l)))?;
    let lib: &'static Library = Box::leak(Box::new(lib));
    loaded.push((name.to_owned(), lib));
    Some(lib)
}

macro_rules! sym {
    ($lib:expr, $name:literal) => {
        *unsafe { $lib.get($name) }
            .map_err(|e| format!("{}: {e}", String::from_utf8_lossy($name)))?
    };
}

impl Egl {
    /// EGL display on the GBM device, a desktop-GL context and no surface (the context is made current on this thread).
    // The target type of each transmute is the declared type of the field or binding it fills.
    #[allow(clippy::missing_transmute_annotations)]
    fn open(gbm: &Gbm) -> Result<Egl, String> {
        let lib = system_library(&["libEGL.so.1", "libEGL.so"]).ok_or("libEGL not found")?;
        let get_proc: unsafe extern "C" fn(*const c_char) -> Ptr =
            sym!(lib, b"eglGetProcAddress\0");
        let get_platform_display = unsafe { get_proc(c"eglGetPlatformDisplayEXT".as_ptr()) };
        if get_platform_display.is_null() {
            return Err("EGL lacks eglGetPlatformDisplayEXT".into());
        }
        let get_platform_display: unsafe extern "C" fn(u32, Ptr, *const i32) -> Ptr =
            unsafe { std::mem::transmute(get_platform_display) };
        let create_image = unsafe { get_proc(c"eglCreateImageKHR".as_ptr()) };
        let destroy_image = unsafe { get_proc(c"eglDestroyImageKHR".as_ptr()) };
        if create_image.is_null() || destroy_image.is_null() {
            return Err("EGL lacks eglCreateImageKHR".into());
        }
        let mut egl = Egl {
            get_proc,
            initialize: sym!(lib, b"eglInitialize\0"),
            terminate: sym!(lib, b"eglTerminate\0"),
            bind_api: sym!(lib, b"eglBindAPI\0"),
            choose_config: sym!(lib, b"eglChooseConfig\0"),
            create_context: sym!(lib, b"eglCreateContext\0"),
            destroy_context: sym!(lib, b"eglDestroyContext\0"),
            make_current: sym!(lib, b"eglMakeCurrent\0"),
            get_error: sym!(lib, b"eglGetError\0"),
            create_image: unsafe { std::mem::transmute(create_image) },
            destroy_image: unsafe { std::mem::transmute(destroy_image) },
            display: std::ptr::null_mut(),
            context: std::ptr::null_mut(),
            _lib: lib,
        };
        const EGL_PLATFORM_GBM_KHR: u32 = 0x31D7;
        egl.display =
            unsafe { get_platform_display(EGL_PLATFORM_GBM_KHR, gbm.device, std::ptr::null()) };
        if egl.display.is_null() {
            return Err(format!(
                "no EGL display on the GBM device (EGL error {:#x})",
                unsafe { (egl.get_error)() }
            ));
        }
        let (mut major, mut minor) = (0, 0);
        if unsafe { (egl.initialize)(egl.display, &mut major, &mut minor) } == 0 {
            return Err(format!("eglInitialize failed ({:#x})", unsafe {
                (egl.get_error)()
            }));
        }
        const EGL_OPENGL_API: u32 = 0x30A2;
        if unsafe { (egl.bind_api)(EGL_OPENGL_API) } == 0 {
            return Err("no desktop OpenGL in EGL".into());
        }
        // Any config will do: the context never gets a surface.
        let config_attribs = [0x3040, 0x0008, 0x3033, 0, 0x3038];
        let mut config: Ptr = std::ptr::null_mut();
        let mut n = 0;
        if unsafe {
            (egl.choose_config)(egl.display, config_attribs.as_ptr(), &mut config, 1, &mut n)
        } == 0
            || n < 1
        {
            return Err("no EGL config for desktop OpenGL".into());
        }
        // The newest core profile first: libmpv uses compute shaders (HDR peak detection) from 4.3 on.
        for (maj, min) in [(4, 6), (4, 3), (3, 3)] {
            let attribs = [0x3098, maj, 0x30FB, min, 0x30FD, 1, 0x3038];
            let ctx = unsafe {
                (egl.create_context)(egl.display, config, std::ptr::null_mut(), attribs.as_ptr())
            };
            if !ctx.is_null() {
                egl.context = ctx;
                break;
            }
        }
        if egl.context.is_null() {
            return Err(format!("no OpenGL context ({:#x})", unsafe {
                (egl.get_error)()
            }));
        }
        if unsafe {
            (egl.make_current)(
                egl.display,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                egl.context,
            )
        } == 0
        {
            return Err(format!(
                "eglMakeCurrent without a surface failed ({:#x})",
                unsafe { (egl.get_error)() }
            ));
        }
        Ok(egl)
    }

    fn proc(&self, name: &str) -> Ptr {
        let n = cstr(name);
        unsafe { (self.get_proc)(n.as_ptr()) }
    }

    // The target type of each transmute is the declared type of the field or binding it fills.
    #[allow(clippy::missing_transmute_annotations)]
    fn gl(&self) -> Result<Gl, String> {
        macro_rules! f {
            ($n:literal) => {{
                let p = self.proc($n);
                if p.is_null() {
                    return Err(format!("OpenGL lacks {}", $n));
                }
                unsafe { std::mem::transmute(p) }
            }};
        }
        Ok(Gl {
            gen_textures: f!("glGenTextures"),
            bind_texture: f!("glBindTexture"),
            delete_textures: f!("glDeleteTextures"),
            gen_framebuffers: f!("glGenFramebuffers"),
            bind_framebuffer: f!("glBindFramebuffer"),
            framebuffer_texture_2d: f!("glFramebufferTexture2D"),
            check_framebuffer_status: f!("glCheckFramebufferStatus"),
            delete_framebuffers: f!("glDeleteFramebuffers"),
            finish: f!("glFinish"),
            image_target_texture_2d: f!("glEGLImageTargetTexture2DOES"),
        })
    }
}

impl Drop for Egl {
    fn drop(&mut self) {
        unsafe {
            if !self.display.is_null() {
                (self.make_current)(
                    self.display,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                );
                if !self.context.is_null() {
                    (self.destroy_context)(self.display, self.context);
                }
                (self.terminate)(self.display);
            }
        }
    }
}

impl Gbm {
    fn open(render_fd: RawFd) -> Result<Gbm, String> {
        let lib = system_library(&["libgbm.so.1", "libgbm.so"]).ok_or("libgbm not found")?;
        let create_device: unsafe extern "C" fn(c_int) -> Ptr = sym!(lib, b"gbm_create_device\0");
        let device = unsafe { create_device(render_fd) };
        if device.is_null() {
            return Err("gbm_create_device failed".into());
        }
        Ok(Gbm {
            destroy_device: sym!(lib, b"gbm_device_destroy\0"),
            bo_create: sym!(lib, b"gbm_bo_create\0"),
            bo_destroy: sym!(lib, b"gbm_bo_destroy\0"),
            bo_fd: sym!(lib, b"gbm_bo_get_fd\0"),
            bo_stride: sym!(lib, b"gbm_bo_get_stride\0"),
            bo_modifier: sym!(lib, b"gbm_bo_get_modifier\0"),
            device,
            _lib: lib,
        })
    }
}

impl Drop for Gbm {
    fn drop(&mut self) {
        unsafe { (self.destroy_device)(self.device) };
    }
}

static PREFERRED_NODE: Mutex<Option<std::path::PathBuf>> = Mutex::new(None);

/// The render node of the GPU the host draws on; the GPU way draws there too (buffers cannot be shared between GPUs).
pub fn prefer_render_node(path: std::path::PathBuf) {
    *lock(&PREFERRED_NODE) = Some(path);
}

/// The DRM render node to draw on: `SWIFTLY_DRM_RENDER_NODE`, the host's GPU, else the first `renderD*` of `/dev/dri`.
fn open_render_node() -> Result<std::fs::File, String> {
    let mut candidates: Vec<std::path::PathBuf> = Vec::new();
    if let Some(p) = std::env::var_os("SWIFTLY_DRM_RENDER_NODE").filter(|p| !p.is_empty()) {
        candidates.push(p.into());
    }
    if let Some(p) = lock(&PREFERRED_NODE).clone() {
        candidates.push(p);
    }
    if let Ok(rd) = std::fs::read_dir("/dev/dri") {
        let mut nodes: Vec<_> = rd
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with("renderD"))
            })
            .collect();
        nodes.sort();
        candidates.extend(nodes);
    }
    candidates
        .iter()
        .find_map(|p| {
            std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(p)
                .ok()
        })
        .ok_or_else(|| "no DRM render node".to_owned())
}

// ---- the ring --------------------------------------------------------------------------------------------------------

struct Slot {
    bo: Ptr,
    egl_image: Ptr,
    texture: u32,
    fbo: u32,
}

struct Ring {
    slots: Vec<Slot>,
    size: (u32, u32),
}

impl Ring {
    fn make(
        gbm: &Gbm,
        egl: &Egl,
        gl: &Gl,
        w: u32,
        h: u32,
    ) -> Result<(Ring, Vec<DmabufImage>), String> {
        let mut ring = Ring {
            slots: Vec::new(),
            size: (w, h),
        };
        let mut images = Vec::new();
        for _ in 0..RING {
            let bo = unsafe {
                (gbm.bo_create)(
                    gbm.device,
                    w,
                    h,
                    FOURCC_ABGR8888,
                    GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR,
                )
            };
            if bo.is_null() {
                ring.free(gbm, egl, gl);
                return Err(format!("gbm_bo_create {w}x{h} failed"));
            }
            let fd = unsafe { (gbm.bo_fd)(bo) };
            let (stride, modifier) = unsafe { ((gbm.bo_stride)(bo), (gbm.bo_modifier)(bo)) };
            // The buffer was asked for as linear. Some drivers answer "invalid" (implicit layout) for it: it is linear.
            let modifier = if modifier == DRM_FORMAT_MOD_INVALID {
                DRM_FORMAT_MOD_LINEAR
            } else {
                modifier
            };
            if fd < 0 {
                unsafe { (gbm.bo_destroy)(bo) };
                ring.free(gbm, egl, gl);
                return Err("gbm_bo_get_fd failed".into());
            }
            let fd = unsafe { OwnedFd::from_raw_fd(fd) };
            let attribs = [
                0x3057,
                w as i32,
                0x3056,
                h as i32,
                0x3271,
                FOURCC_ABGR8888 as i32,
                0x3272,
                std::os::fd::AsRawFd::as_raw_fd(&fd),
                0x3273,
                0,
                0x3274,
                stride as i32,
                0x3038,
            ];
            const EGL_LINUX_DMA_BUF_EXT: u32 = 0x3270;
            let image = unsafe {
                (egl.create_image)(
                    egl.display,
                    std::ptr::null_mut(),
                    EGL_LINUX_DMA_BUF_EXT,
                    std::ptr::null_mut(),
                    attribs.as_ptr(),
                )
            };
            if image.is_null() {
                unsafe { (gbm.bo_destroy)(bo) };
                ring.free(gbm, egl, gl);
                return Err(format!("eglCreateImage failed ({:#x})", unsafe {
                    (egl.get_error)()
                }));
            }
            let (mut tex, mut fbo) = (0_u32, 0_u32);
            unsafe {
                (gl.gen_textures)(1, &mut tex);
                (gl.bind_texture)(0x0DE1, tex);
                (gl.image_target_texture_2d)(0x0DE1, image);
                (gl.gen_framebuffers)(1, &mut fbo);
                (gl.bind_framebuffer)(0x8D40, fbo);
                (gl.framebuffer_texture_2d)(0x8D40, 0x8CE0, 0x0DE1, tex, 0);
            }
            let complete = unsafe { (gl.check_framebuffer_status)(0x8D40) } == 0x8CD5;
            unsafe { (gl.bind_framebuffer)(0x8D40, 0) };
            ring.slots.push(Slot {
                bo,
                egl_image: image,
                texture: tex,
                fbo,
            });
            if !complete {
                ring.free(gbm, egl, gl);
                return Err("the shared buffer is not a complete framebuffer".into());
            }
            images.push(DmabufImage {
                fd,
                fourcc: FOURCC_ABGR8888,
                modifier,
                stride,
                offset: 0,
                width: w,
                height: h,
            });
        }
        Ok((ring, images))
    }

    fn free(&mut self, gbm: &Gbm, egl: &Egl, gl: &Gl) {
        for s in self.slots.drain(..) {
            unsafe {
                (gl.delete_framebuffers)(1, &s.fbo);
                (gl.delete_textures)(1, &s.texture);
                (egl.destroy_image)(egl.display, s.egl_image);
                (gbm.bo_destroy)(s.bo);
            }
        }
    }
}

// ---- shared state between the UI side, libmpv's callback and the thread -------------------------------------------------

#[derive(Default)]
struct Slots {
    want: (u32, u32),
    /// When `want` last changed.
    want_at: Option<Instant>,
    wake: bool,
    stop: bool,
    /// Changes with every new ring.
    generation: u64,
    images: Option<Arc<[DmabufImage]>>,
    /// The newest finished buffer the host has not taken.
    latest: Option<usize>,
    /// The buffer the host took last (it may still sample it).
    hand: Option<usize>,
    delivered: bool,
    /// The ring was reset: draw again even when libmpv has no new frame.
    redraw: bool,
    drawn_size: (u32, u32),
    times: Vec<f32>,
}

/// State shared with libmpv's update callback.
pub struct GlShared {
    slots: Mutex<Slots>,
    cond: Condvar,
    rendered: AtomicU64,
    superseded: AtomicU64,
    render_ns: AtomicU64,
}

impl GlShared {
    fn notify(&self) {
        lock(&self.slots).wake = true;
        self.cond.notify_one();
    }
}

unsafe extern "C" fn update_callback(user: Ptr) {
    // `user` is the `GlShared` that the thread keeps alive until the callback is cleared.
    let shared = unsafe { &*user.cast::<GlShared>() };
    shared.notify();
}

unsafe extern "C" fn get_proc_address(ctx: Ptr, name: *const c_char) -> Ptr {
    // `ctx` is the thread's `Egl`, alive while libmpv's context is.
    let egl = unsafe { &*ctx.cast::<Egl>() };
    unsafe { (egl.get_proc)(name) }
}

#[repr(C)]
struct InitParams {
    get_proc_address: unsafe extern "C" fn(Ptr, *const c_char) -> Ptr,
    ctx: Ptr,
}

#[repr(C)]
struct FboParam {
    fbo: c_int,
    w: c_int,
    h: c_int,
    internal_format: c_int,
}

#[repr(C)]
struct DrmParamsV2 {
    fd: c_int,
    crtc_id: c_int,
    connector_id: c_int,
    atomic_request_ptr: Ptr,
    render_fd: c_int,
}

/// The render thread and the ring it feeds. Dropping it stops the thread, which frees libmpv's render context.
pub struct GlPump {
    shared: Arc<GlShared>,
    thread: Option<JoinHandle<()>>,
}

impl GlPump {
    /// Starts the GPU way for the libmpv player `mpv_handle`: opens the render node, EGL and the libmpv OpenGL render
    /// context on a new thread. An error means this machine cannot do it (the caller keeps the software renderer); the
    /// thread is gone then and nothing is left behind.
    pub(crate) fn start(
        rc: RcApi,
        mpv_handle: usize,
        on_resize: Box<dyn Fn(u32, u32) + Send>,
        wake: Arc<WakeSlot>,
    ) -> Result<GlPump, String> {
        let shared = Arc::new(GlShared {
            slots: Mutex::new(Slots::default()),
            cond: Condvar::new(),
            rendered: AtomicU64::new(0),
            superseded: AtomicU64::new(0),
            render_ns: AtomicU64::new(0),
        });
        let (tx, rx) = std::sync::mpsc::channel::<Result<(), String>>();
        let worker = Arc::clone(&shared);
        let thread = std::thread::Builder::new()
            .name("video-gpu".into())
            .spawn(move || thread_main(&worker, rc, mpv_handle, &*on_resize, &wake, &tx))
            .map_err(|e| format!("render thread: {e}"))?;
        match rx.recv_timeout(START_WAIT) {
            Ok(Ok(())) => Ok(GlPump {
                shared,
                thread: Some(thread),
            }),
            Ok(Err(e)) => {
                let _ = thread.join();
                Err(e)
            }
            Err(_) => {
                // The thread never answered: leave it to finish on its own, the engine goes on without it.
                lock(&shared.slots).stop = true;
                shared.cond.notify_all();
                Err("the GPU render thread did not start in time".into())
            }
        }
    }

    /// Tells the thread which size the UI wants (a changed size wakes it).
    pub(crate) fn want(&self, width: u32, height: u32) {
        let mut s = lock(&self.shared.slots);
        if s.want != (width, height) {
            s.want = (width, height);
            s.want_at = Some(Instant::now());
            s.wake = true;
            drop(s);
            self.shared.cond.notify_one();
        }
    }

    /// The newest finished buffer, if there is one the host has not taken. Never waits.
    pub(crate) fn take(&self) -> SharedStatus {
        let mut s = lock(&self.shared.slots);
        let (Some(images), Some(slot)) = (s.images.clone(), s.latest.take()) else {
            return if s.delivered {
                SharedStatus::Unchanged
            } else {
                SharedStatus::NotReady
            };
        };
        s.hand = Some(slot);
        s.delivered = true;
        SharedStatus::New(SharedFrame {
            generation: s.generation,
            images,
            slot,
        })
    }

    /// A new title starts: its first frame is "new" again and the picture is drawn once even without a frame due.
    pub(crate) fn reset(&self) {
        let mut s = lock(&self.shared.slots);
        s.latest = None;
        s.delivered = false;
        s.redraw = true;
        s.wake = true;
        drop(s);
        self.shared.cond.notify_one();
    }

    /// The counters.
    pub(crate) fn stats(&self) -> PumpStats {
        let s = lock(&self.shared.slots);
        let mut t = s.times.clone();
        let size = s.drawn_size;
        drop(s);
        t.sort_by(f32::total_cmp);
        let at = |p: f64| {
            t.get(((t.len() as f64 - 1.0).max(0.0) * p) as usize)
                .copied()
                .map_or(0.0, f64::from)
        };
        let rendered = self.shared.rendered.load(Ordering::Relaxed);
        PumpStats {
            rendered,
            superseded: self.shared.superseded.load(Ordering::Relaxed),
            avg_ms: if rendered == 0 {
                0.0
            } else {
                self.shared.render_ns.load(Ordering::Relaxed) as f64 / 1.0e6 / rendered as f64
            },
            p50_ms: at(0.5),
            p99_ms: at(0.99),
            size,
        }
    }
}

impl Drop for GlPump {
    fn drop(&mut self) {
        lock(&self.shared.slots).stop = true;
        self.shared.cond.notify_all();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

// ---- the thread --------------------------------------------------------------------------------------------------------

fn thread_main(
    shared: &Arc<GlShared>,
    rc: RcApi,
    mpv_handle: usize,
    on_resize: &dyn Fn(u32, u32),
    wake: &WakeSlot,
    started: &std::sync::mpsc::Sender<Result<(), String>>,
) {
    let node = match open_render_node() {
        Ok(n) => n,
        Err(e) => {
            let _ = started.send(Err(e));
            return;
        }
    };
    let setup = (|| {
        let gbm = Gbm::open(std::os::fd::AsRawFd::as_raw_fd(&node))?;
        let egl = Egl::open(&gbm)?;
        let gl = egl.gl()?;
        Ok::<_, String>((gbm, egl, gl))
    })();
    let (gbm, egl, gl) = match setup {
        Ok(v) => v,
        Err(e) => {
            let _ = started.send(Err(e));
            return;
        }
    };
    // libmpv's OpenGL renderer, with the render node for VA-API interop (zero-copy hardware decoding).
    let api_type = cstr("opengl");
    let mut init = InitParams {
        get_proc_address,
        ctx: std::ptr::from_ref(&egl).cast_mut().cast(),
    };
    let mut drm = DrmParamsV2 {
        fd: -1,
        crtc_id: -1,
        connector_id: -1,
        atomic_request_ptr: std::ptr::null_mut(),
        render_fd: std::os::fd::AsRawFd::as_raw_fd(&node),
    };
    let mut params = [
        RenderParam {
            kind: RP_API_TYPE,
            data: api_type.as_ptr().cast_mut().cast(),
        },
        RenderParam {
            kind: RP_OPENGL_INIT_PARAMS,
            data: std::ptr::from_mut(&mut init).cast(),
        },
        RenderParam {
            kind: RP_DRM_DISPLAY_V2,
            data: std::ptr::from_mut(&mut drm).cast(),
        },
        RenderParam {
            kind: 0,
            data: std::ptr::null_mut(),
        },
    ];
    let mut ctx: Ptr = std::ptr::null_mut();
    let code = unsafe { (rc.create)(&mut ctx, mpv_handle as Ptr, params.as_mut_ptr()) };
    if code < 0 || ctx.is_null() {
        let _ = started.send(Err(format!(
            "mpv_render_context_create(opengl) failed ({code})"
        )));
        return;
    }
    unsafe {
        (rc.set_cb)(
            ctx,
            Some(update_callback),
            Arc::as_ptr(shared).cast_mut().cast(),
        )
    };
    let _ = started.send(Ok(()));

    let mut ring: Option<Ring> = None;
    let mut announced = (0, 0);
    let mut last_slot = RING - 1;
    loop {
        // Wait for news (a frame due, a new size), at most until the ring's size change has settled.
        let (want, redraw, want_at) = {
            let mut s = lock(&shared.slots);
            while !s.wake && !s.stop {
                let wait = match (&ring, s.want_at) {
                    (Some(r), Some(at)) if s.want != r.size && s.want.0 != 0 => DEBOUNCE
                        .saturating_sub(at.elapsed())
                        .max(Duration::from_millis(5)),
                    _ => IDLE_WAIT,
                };
                s = match shared.cond.wait_timeout(s, wait) {
                    Ok((g, _)) => g,
                    Err(e) => e.into_inner().0,
                };
                if s.want.0 != 0 {
                    break;
                }
            }
            if s.stop {
                break;
            }
            s.wake = false;
            (s.want, std::mem::take(&mut s.redraw), s.want_at)
        };
        if want.0 == 0 || want.1 == 0 {
            continue;
        }
        let due = unsafe { (rc.update)(ctx) } & UPDATE_FRAME != 0;
        // A new ring for a new size, once the size has been steady (or at once when there is none).
        let stale = ring.as_ref().is_none_or(|r| r.size != want);
        let mut fresh = false;
        if stale {
            let steady = ring.is_none() || want_at.is_none_or(|t| t.elapsed() >= DEBOUNCE);
            if steady {
                if let Some(mut old) = ring.take() {
                    old.free(&gbm, &egl, &gl);
                }
                match Ring::make(&gbm, &egl, &gl, want.0, want.1) {
                    Ok((r, images)) => {
                        let mut s = lock(&shared.slots);
                        s.generation += 1;
                        s.images = Some(images.into());
                        s.latest = None;
                        s.hand = None;
                        s.delivered = false;
                        drop(s);
                        ring = Some(r);
                        fresh = true;
                    }
                    Err(e) => {
                        eprintln!("swiftly-player: shared video buffers failed: {e}");
                        // Try again at the next wake-up; the UI shows the last picture meanwhile.
                        std::thread::sleep(Duration::from_millis(250));
                        continue;
                    }
                }
            }
        }
        let Some(r) = ring.as_ref() else { continue };
        if !due && !fresh && !redraw {
            continue;
        }
        if announced != r.size {
            on_resize(r.size.0, r.size.1);
            announced = r.size;
        }
        // The next buffer that is neither the newest one nor the one the host holds.
        let slot = {
            let s = lock(&shared.slots);
            (1..=RING)
                .map(|k| (last_slot + k) % RING)
                .find(|i| Some(*i) != s.latest && Some(*i) != s.hand)
        };
        let Some(slot) = slot else { continue };
        let started_at = Instant::now();
        let mut fbo = FboParam {
            fbo: r.slots[slot].fbo as c_int,
            w: r.size.0 as c_int,
            h: r.size.1 as c_int,
            // GL_RGBA8
            internal_format: 0x8058,
        };
        // The host samples the buffer with its first row at the top. libmpv draws an FBO the way a window's default
        // framebuffer is drawn: right way up on the screen with GL's origin at the bottom left, so the first row in
        // memory is the picture's top row already. `flip_y` = 1 made the picture stand on its head (measured with a
        // test pattern whose clock sits at the top left: `Werkzeuge/desktop-live/l-vid.sh`, `l-upright.py`).
        let mut flip: c_int = 0;
        let mut block: c_int = 0;
        let mut p = [
            RenderParam {
                kind: RP_OPENGL_FBO,
                data: std::ptr::from_mut(&mut fbo).cast(),
            },
            RenderParam {
                kind: RP_FLIP_Y,
                data: std::ptr::from_mut(&mut flip).cast(),
            },
            RenderParam {
                kind: RP_BLOCK_FOR_TARGET_TIME,
                data: std::ptr::from_mut(&mut block).cast(),
            },
            RenderParam {
                kind: 0,
                data: std::ptr::null_mut(),
            },
        ];
        let code = unsafe { (rc.render)(ctx, p.as_mut_ptr()) };
        // The frame is done when the GPU says so; the host samples it right after.
        unsafe { (gl.finish)() };
        if code < 0 {
            continue;
        }
        last_slot = slot;
        let took = started_at.elapsed();
        shared.rendered.fetch_add(1, Ordering::Relaxed);
        shared.render_ns.fetch_add(
            u64::try_from(took.as_nanos()).unwrap_or(u64::MAX),
            Ordering::Relaxed,
        );
        let mut s = lock(&shared.slots);
        if s.times.len() >= SAMPLES {
            s.times.remove(0);
        }
        s.times.push(took.as_secs_f32() * 1000.0);
        s.drawn_size = r.size;
        if s.latest.replace(slot).is_some() {
            shared.superseded.fetch_add(1, Ordering::Relaxed);
        }
        // libmpv may already have the next picture.
        s.wake = true;
        drop(s);
        wake.fire();
    }
    unsafe {
        (rc.set_cb)(ctx, None, std::ptr::null_mut());
        (rc.free)(ctx);
    }
    if let Some(mut r) = ring.take() {
        r.free(&gbm, &egl, &gl);
    }
    drop(egl);
    drop(gbm);
    drop(node);
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_fourcc_is_abgr8888() {
        // fourcc_code('A', 'B', '2', '4'), little endian
        assert_eq!(
            super::FOURCC_ABGR8888,
            u32::from_le_bytes([b'A', b'B', b'2', b'4'])
        );
    }
}
