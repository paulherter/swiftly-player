//! The GPU way of the libmpv engine (Windows): libmpv's OpenGL renderer draws, scales and tone-maps the picture on the
//! GPU into a small ring of images that the host's Vulkan device owns, and the host samples those images directly (no
//! frame is ever copied to the CPU).
//!
//! Everything GL lives on one thread of its own ("video-gpu"): a hidden window with a WGL core-profile context, the
//! libmpv render context and the ring. The ring's images are allocated by the host through the hook set with
//! [`set_ring_allocator`] (Vulkan memory exported as an opaque Win32 handle); this thread imports each one into GL
//! (`GL_EXT_memory_object_win32`), makes a texture and a framebuffer of it, and libmpv draws into the framebuffer. After
//! every frame `glFinish` makes the GPU done before the buffer is published (a semaphore would be faster; correctness
//! first). Everything is loaded at run time; a machine whose OpenGL driver lacks the extension (the default Windows
//! display driver, a remote session) makes [`GlPump::start`] fail with the reason and the engine keeps the software
//! renderer.
#![allow(unsafe_code)]

use crate::mpv::{
    RP_API_TYPE, RP_BLOCK_FOR_TARGET_TIME, RP_FLIP_Y, RP_OPENGL_FBO, RP_OPENGL_INIT_PARAMS, RcApi,
    RenderParam, UPDATE_FRAME, cstr, lock,
};
use crate::pump::{PumpStats, WakeSlot};
use crate::{SharedFrame, SharedStatus};
use libloading::Library;
use std::ffi::{CStr, c_char, c_int, c_void};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

type Ptr = *mut c_void;

const RING: usize = 4;
const DEBOUNCE: Duration = Duration::from_millis(200);
const IDLE_WAIT: Duration = Duration::from_millis(250);
const SAMPLES: usize = 512;
const START_WAIT: Duration = Duration::from_secs(5);

pub use crate::win_ring::WinImage;
use crate::win_ring::{Backoff, next_generation};

/// An image of the ring for the host to hand over: its Win32 `handle` is closed by `CloseHandle` when the image is dropped
/// without the engine having imported it.
pub fn new_image(handle: usize, mem_size: u64, dedicated: bool) -> WinImage {
    WinImage::with_closer(handle, mem_size, dedicated, close_handle)
}

/// Makes `count` exportable `R8G8B8A8` images of `width x height` for ring number `generation` and keeps their
/// textures on the host side. Set once by the host before the first engine starts.
pub type RingAlloc = dyn Fn(u64, u32, u32, usize) -> Result<Vec<WinImage>, String> + Send + Sync;

/// Tells the host that the engine freed the ring with this number, so the host forgets its textures.
pub type RingRelease = dyn Fn(u64) + Send + Sync;

static ALLOC: OnceLock<Box<RingAlloc>> = OnceLock::new();
static RELEASE: OnceLock<Box<RingRelease>> = OnceLock::new();
static ADAPTER: OnceLock<String> = OnceLock::new();

/// The host's Vulkan side tells how to make ring images and which GPU it draws on.
pub fn set_ring_allocator(alloc: Box<RingAlloc>, release: Box<RingRelease>, adapter_name: &str) {
    let _ = ALLOC.set(alloc);
    let _ = RELEASE.set(release);
    let _ = ADAPTER.set(adapter_name.to_owned());
}

/// The name of the GPU the host draws on (libmpv's `d3d11-adapter` takes it), once the host has told.
pub fn adapter_name() -> Option<&'static str> {
    ADAPTER.get().map(String::as_str)
}

struct Gl {
    _opengl32: Library,
    get_proc: unsafe extern "system" fn(*const c_char) -> Ptr,
    finish: unsafe extern "system" fn(),
    gen_textures: unsafe extern "system" fn(c_int, *mut u32),
    bind_texture: unsafe extern "system" fn(u32, u32),
    delete_textures: unsafe extern "system" fn(c_int, *const u32),
    gen_fbos: unsafe extern "system" fn(c_int, *mut u32),
    bind_fbo: unsafe extern "system" fn(u32, u32),
    delete_fbos: unsafe extern "system" fn(c_int, *const u32),
    fbo_texture: unsafe extern "system" fn(u32, u32, u32, u32, c_int),
    fbo_status: unsafe extern "system" fn(u32) -> u32,
    create_memory: unsafe extern "system" fn(c_int, *mut u32),
    delete_memory: unsafe extern "system" fn(c_int, *const u32),
    memory_param: unsafe extern "system" fn(u32, u32, *const c_int),
    import_win32: unsafe extern "system" fn(u32, u64, u32, usize),
    tex_storage_mem: unsafe extern "system" fn(u32, c_int, u32, c_int, c_int, u32, u64),
    get_error: unsafe extern "system" fn() -> u32,
    clear_color: unsafe extern "system" fn(f32, f32, f32, f32),
    clear: unsafe extern "system" fn(u32),
}

/// The hidden window and its WGL context (current on the render thread).
struct Wgl {
    gl: Gl,
    hwnd: usize,
    hdc: usize,
    ctx: usize,
    user32: Library,
    gdi32: Library,
}

fn gl_proc(lib: &Library, get: unsafe extern "system" fn(*const c_char) -> Ptr, name: &str) -> Ptr {
    let c = std::ffi::CString::new(name).unwrap_or_default();
    let p = unsafe { get(c.as_ptr()) };
    // wglGetProcAddress answers 0, 1, 2, 3 or -1 for "not there"; GL 1.1 functions come from the library itself.
    if (p as usize) <= 3 || p as usize == usize::MAX {
        return unsafe { lib.get::<Ptr>(c.as_bytes_with_nul()) }
            .map(|s| *s)
            .unwrap_or(std::ptr::null_mut());
    }
    p
}

impl Wgl {
    /// The reason is the error text; nothing is left behind on failure except what `Drop` frees.
    #[allow(clippy::missing_transmute_annotations)]
    fn open() -> Result<Wgl, String> {
        // Test hook for the fallback (debug builds only): the engine must keep the software renderer when this way
        // cannot start.
        if cfg!(debug_assertions) && std::env::var_os("SWIFTLY_WGL_FAIL").is_some() {
            return Err("forced by SWIFTLY_WGL_FAIL".into());
        }
        unsafe {
            let user32 = Library::new("user32.dll").map_err(|e| format!("user32: {e}"))?;
            let gdi32 = Library::new("gdi32.dll").map_err(|e| format!("gdi32: {e}"))?;
            let opengl32 = Library::new("opengl32.dll").map_err(|e| format!("opengl32: {e}"))?;
            macro_rules! need {
                ($lib:expr, $name:literal) => {
                    *$lib
                        .get($name)
                        .map_err(|e| format!("{}: {e}", String::from_utf8_lossy($name)))?
                };
            }
            let create_window: unsafe extern "system" fn(
                u32,
                *const u8,
                *const u8,
                u32,
                i32,
                i32,
                i32,
                i32,
                usize,
                usize,
                usize,
                usize,
            ) -> usize = need!(user32, b"CreateWindowExA\0");
            let get_dc: unsafe extern "system" fn(usize) -> usize = need!(user32, b"GetDC\0");
            let choose: unsafe extern "system" fn(usize, *const u8) -> i32 =
                need!(gdi32, b"ChoosePixelFormat\0");
            let set_format: unsafe extern "system" fn(usize, i32, *const u8) -> i32 =
                need!(gdi32, b"SetPixelFormat\0");
            let wcreate: unsafe extern "system" fn(usize) -> usize =
                need!(opengl32, b"wglCreateContext\0");
            let wmake: unsafe extern "system" fn(usize, usize) -> i32 =
                need!(opengl32, b"wglMakeCurrent\0");
            let wdelete: unsafe extern "system" fn(usize) -> i32 =
                need!(opengl32, b"wglDeleteContext\0");
            let get_proc: unsafe extern "system" fn(*const c_char) -> Ptr =
                need!(opengl32, b"wglGetProcAddress\0");
            let get_string: unsafe extern "system" fn(u32) -> *const c_char =
                need!(opengl32, b"glGetString\0");
            // WS_POPUP, never shown. Class STATIC needs no registration.
            let hwnd = create_window(
                0,
                c"STATIC".as_ptr().cast(),
                c"swiftly-video".as_ptr().cast(),
                0x8000_0000,
                0,
                0,
                16,
                16,
                0,
                0,
                0,
                0,
            );
            if hwnd == 0 {
                return Err("CreateWindowEx failed".into());
            }
            let hdc = get_dc(hwnd);
            let mut pfd = [0u8; 40];
            pfd[0..2].copy_from_slice(&40u16.to_le_bytes());
            pfd[2..4].copy_from_slice(&1u16.to_le_bytes());
            // PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER
            pfd[4..8].copy_from_slice(&(0x4u32 | 0x20 | 0x1).to_le_bytes());
            pfd[9] = 32;
            let pf = choose(hdc, pfd.as_ptr());
            if pf == 0 || set_format(hdc, pf, pfd.as_ptr()) == 0 {
                return Err("no pixel format for the OpenGL window".into());
            }
            let legacy = wcreate(hdc);
            if legacy == 0 || wmake(hdc, legacy) == 0 {
                return Err("wglCreateContext failed".into());
            }
            // The core profile needs the extension function, which only a current legacy context can give.
            let create_attribs = get_proc(c"wglCreateContextAttribsARB".as_ptr());
            if (create_attribs as usize) <= 3 {
                return Err("wglCreateContextAttribsARB is missing".into());
            }
            let create_attribs: unsafe extern "system" fn(usize, usize, *const i32) -> usize =
                std::mem::transmute(create_attribs);
            // 4.3 core: libmpv's renderer asks for no more than that.
            let attribs = [0x2091, 4, 0x2092, 3, 0x9126, 1, 0];
            let ctx = create_attribs(hdc, 0, attribs.as_ptr());
            wmake(0, 0);
            wdelete(legacy);
            if ctx == 0 || wmake(hdc, ctx) == 0 {
                return Err("no OpenGL 4.3 core context".into());
            }
            let s = |n: u32| {
                let p = get_string(n);
                if p.is_null() {
                    String::new()
                } else {
                    CStr::from_ptr(p).to_string_lossy().into_owned()
                }
            };
            let renderer = s(0x1F01);
            // The extension list of a core context comes from glGetStringi; the legacy string is enough for the probe's
            // facts, and the import functions are looked up below anyway.
            let load = |name: &str| gl_proc(&opengl32, get_proc, name);
            macro_rules! f {
                ($name:literal) => {{
                    let p = load($name);
                    if p.is_null() {
                        return Err(format!(
                            "OpenGL driver {renderer:?} lacks {} (no GPU OpenGL on this display)",
                            $name
                        ));
                    }
                    std::mem::transmute(p)
                }};
            }
            let gl = Gl {
                get_proc,
                finish: f!("glFinish"),
                gen_textures: f!("glGenTextures"),
                bind_texture: f!("glBindTexture"),
                delete_textures: f!("glDeleteTextures"),
                gen_fbos: f!("glGenFramebuffers"),
                bind_fbo: f!("glBindFramebuffer"),
                delete_fbos: f!("glDeleteFramebuffers"),
                fbo_texture: f!("glFramebufferTexture2D"),
                fbo_status: f!("glCheckFramebufferStatus"),
                create_memory: f!("glCreateMemoryObjectsEXT"),
                delete_memory: f!("glDeleteMemoryObjectsEXT"),
                memory_param: f!("glMemoryObjectParameterivEXT"),
                import_win32: f!("glImportMemoryWin32HandleEXT"),
                tex_storage_mem: f!("glTexStorageMem2DEXT"),
                get_error: f!("glGetError"),
                clear_color: f!("glClearColor"),
                clear: f!("glClear"),
                _opengl32: opengl32,
            };
            Ok(Wgl {
                gl,
                hwnd,
                hdc,
                ctx,
                user32,
                gdi32,
            })
        }
    }
}

impl Drop for Wgl {
    fn drop(&mut self) {
        unsafe {
            if let Ok(opengl32) = Library::new("opengl32.dll") {
                if let Ok(make) = opengl32
                    .get::<unsafe extern "system" fn(usize, usize) -> i32>(b"wglMakeCurrent\0")
                {
                    make(0, 0);
                }
                if let Ok(del) =
                    opengl32.get::<unsafe extern "system" fn(usize) -> i32>(b"wglDeleteContext\0")
                {
                    del(self.ctx);
                }
            }
            if let Ok(rel) = self
                .user32
                .get::<unsafe extern "system" fn(usize, usize) -> i32>(b"ReleaseDC\0")
            {
                rel(self.hwnd, self.hdc);
            }
            if let Ok(dest) = self
                .user32
                .get::<unsafe extern "system" fn(usize) -> i32>(b"DestroyWindow\0")
            {
                dest(self.hwnd);
            }
            let _ = &self.gdi32;
        }
    }
}

unsafe extern "C" fn get_proc_address(ctx: Ptr, name: *const c_char) -> Ptr {
    // `ctx` is the thread's `Wgl`, alive while libmpv's context is.
    let wgl = unsafe { &*ctx.cast::<Wgl>() };
    let n = unsafe { CStr::from_ptr(name) }.to_string_lossy();
    gl_proc(&wgl.gl._opengl32, wgl.gl.get_proc, &n)
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

// ---- the ring --------------------------------------------------------------------------------------------------------

struct Slot {
    handle: usize,
    memory: u32,
    texture: u32,
    fbo: u32,
}

struct Ring {
    slots: Vec<Slot>,
    size: (u32, u32),
    generation: u64,
}

fn close_handle(handle: usize) {
    if let Ok(k) = unsafe { Library::new("kernel32.dll") }
        && let Ok(close) =
            unsafe { k.get::<unsafe extern "system" fn(usize) -> i32>(b"CloseHandle\0") }
    {
        unsafe { close(handle) };
    }
}

impl Ring {
    fn make(gl: &Gl, generation: u64, width: u32, height: u32) -> Result<Ring, String> {
        let alloc = ALLOC.get().ok_or("the host has no Vulkan ring allocator")?;
        let mut images = alloc(generation, width, height, RING)?;
        let mut ring = Ring {
            slots: Vec::new(),
            size: (width, height),
            generation,
        };
        let mut failure = None;
        for image in &mut images {
            // A slot owns its handle from the import on (GL needs it to stay open while the image is in use). After a
            // failure the remaining images keep theirs, and dropping `images` below closes them.
            if failure.is_none() {
                match unsafe { Self::import(gl, image, width, height) } {
                    Ok(s) => ring.slots.push(s),
                    Err(e) => failure = Some(e),
                }
            }
        }
        drop(images);
        match failure {
            None => Ok(ring),
            Some(e) => {
                ring.free(gl);
                Err(e)
            }
        }
    }

    unsafe fn import(gl: &Gl, image: &mut WinImage, w: u32, h: u32) -> Result<Slot, String> {
        const GL_TEXTURE_2D: u32 = 0x0DE1;
        const GL_FRAMEBUFFER: u32 = 0x8D40;
        const GL_COLOR_ATTACHMENT0: u32 = 0x8CE0;
        const GL_FRAMEBUFFER_COMPLETE: u32 = 0x8CD5;
        const GL_COLOR_BUFFER_BIT: u32 = 0x4000;
        const GL_RGBA8: u32 = 0x8058;
        const GL_DEDICATED_MEMORY_OBJECT_EXT: u32 = 0x9581;
        const GL_HANDLE_TYPE_OPAQUE_WIN32_EXT: u32 = 0x9587;
        // The slot owns the handle now, also when this import fails (the failure path below closes it).
        let handle = image.take_handle();
        let mut s = Slot {
            handle,
            memory: 0,
            texture: 0,
            fbo: 0,
        };
        unsafe {
            (gl.get_error)();
            (gl.create_memory)(1, &mut s.memory);
            if image.dedicated {
                let one: c_int = 1;
                (gl.memory_param)(s.memory, GL_DEDICATED_MEMORY_OBJECT_EXT, &one);
            }
            (gl.import_win32)(
                s.memory,
                image.mem_size,
                GL_HANDLE_TYPE_OPAQUE_WIN32_EXT,
                handle,
            );
            (gl.gen_textures)(1, &mut s.texture);
            (gl.bind_texture)(GL_TEXTURE_2D, s.texture);
            (gl.tex_storage_mem)(
                GL_TEXTURE_2D,
                1,
                GL_RGBA8,
                w as c_int,
                h as c_int,
                s.memory,
                0,
            );
            (gl.gen_fbos)(1, &mut s.fbo);
            (gl.bind_fbo)(GL_FRAMEBUFFER, s.fbo);
            (gl.fbo_texture)(
                GL_FRAMEBUFFER,
                GL_COLOR_ATTACHMENT0,
                GL_TEXTURE_2D,
                s.texture,
                0,
            );
            let status = (gl.fbo_status)(GL_FRAMEBUFFER);
            let err = (gl.get_error)();
            // The first use of freshly imported Vulkan memory must be a full clear that is finished before libmpv
            // draws: the AMD OpenGL driver otherwise crashes inside `glFinish` after libmpv's first draw (measured on
            // one machine: 3 of 3 runs crashed without the clear, 3 of 3 ran fine with it, with or without a tiling hint).
            (gl.clear_color)(0.0, 0.0, 0.0, 1.0);
            (gl.clear)(GL_COLOR_BUFFER_BIT);
            (gl.finish)();
            (gl.bind_fbo)(GL_FRAMEBUFFER, 0);
            if status != GL_FRAMEBUFFER_COMPLETE || err != 0 {
                Ring {
                    slots: vec![s],
                    size: (w, h),
                    generation: 0,
                }
                .free_slots(gl);
                return Err(format!(
                    "importing the Vulkan image into OpenGL failed (framebuffer {status:#x}, glGetError {err:#x})"
                ));
            }
        }
        Ok(s)
    }

    /// Frees the GL objects and handles, and tells the host to forget its textures of this ring.
    fn free(&mut self, gl: &Gl) {
        self.free_slots(gl);
        if let Some(release) = RELEASE.get() {
            release(self.generation);
        }
    }

    fn free_slots(&mut self, gl: &Gl) {
        for s in self.slots.drain(..) {
            unsafe {
                if s.fbo != 0 {
                    (gl.delete_fbos)(1, &s.fbo);
                }
                if s.texture != 0 {
                    (gl.delete_textures)(1, &s.texture);
                }
                if s.memory != 0 {
                    (gl.delete_memory)(1, &s.memory);
                }
                close_handle(s.handle);
            }
        }
    }
}

// ---- shared state between the UI side, libmpv's callback and the thread -------------------------------------------------

#[derive(Default)]
struct Slots {
    want: (u32, u32),
    want_at: Option<Instant>,
    wake: bool,
    stop: bool,
    generation: u64,
    size: (u32, u32),
    has_ring: bool,
    latest: Option<usize>,
    hand: Option<usize>,
    delivered: bool,
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
    let shared = unsafe { &*user.cast::<GlShared>() };
    shared.notify();
}

/// The render thread and the ring it feeds. Dropping it stops the thread, which frees libmpv's render context.
pub struct GlPump {
    shared: Arc<GlShared>,
    thread: Option<JoinHandle<()>>,
}

impl GlPump {
    /// Starts the GPU way for the libmpv player `mpv_handle`. An error means this machine cannot do it (the caller keeps
    /// the software renderer); the thread is gone then and nothing is left behind.
    pub(crate) fn start(
        rc: RcApi,
        mpv_handle: usize,
        on_resize: Box<dyn Fn(u32, u32) + Send>,
        wake: Arc<WakeSlot>,
    ) -> Result<GlPump, String> {
        if ALLOC.get().is_none() {
            return Err("the window's renderer is not Vulkan with Win32 memory sharing".into());
        }
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
        let (true, Some(slot)) = (s.has_ring, s.latest.take()) else {
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
            size: s.size,
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
    let wgl = match Wgl::open() {
        Ok(w) => w,
        Err(e) => {
            let _ = started.send(Err(e));
            return;
        }
    };
    let api_type = cstr("opengl");
    let mut init = InitParams {
        get_proc_address,
        ctx: std::ptr::from_ref(&wgl).cast_mut().cast(),
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
    // Prove the import works before the engine commits to this path: a first ring of the smallest size.
    match Ring::make(&wgl.gl, next_generation(), 64, 64) {
        Ok(mut probe) => probe.free(&wgl.gl),
        Err(e) => {
            unsafe {
                (rc.set_cb)(ctx, None, std::ptr::null_mut());
                (rc.free)(ctx);
            }
            let _ = started.send(Err(e));
            return;
        }
    }
    let _ = started.send(Ok(()));

    let mut ring: Option<Ring> = None;
    let mut backoff = Backoff::default();
    // The size a ring could not be made for: tried again only when the wanted size changes.
    let mut gave_up_at: Option<(u32, u32)> = None;
    let mut announced = (0, 0);
    let mut last_slot = RING - 1;
    loop {
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
        if gave_up_at.is_some_and(|size| size != want) {
            gave_up_at = None;
            backoff.succeeded();
        }
        let stale = gave_up_at.is_none() && ring.as_ref().is_none_or(|r| r.size != want);
        let mut fresh = false;
        if stale {
            let steady = ring.is_none() || want_at.is_none_or(|t| t.elapsed() >= DEBOUNCE);
            if steady {
                if let Some(mut old) = ring.take() {
                    old.free(&wgl.gl);
                }
                let generation = next_generation();
                match Ring::make(&wgl.gl, generation, want.0, want.1) {
                    Ok(r) => {
                        backoff.succeeded();
                        let mut s = lock(&shared.slots);
                        s.generation = generation;
                        s.size = r.size;
                        s.has_ring = true;
                        s.latest = None;
                        s.hand = None;
                        s.delivered = false;
                        drop(s);
                        ring = Some(r);
                        fresh = true;
                    }
                    Err(e) => {
                        eprintln!("swiftly-player: shared video buffers failed: {e}");
                        match backoff.failed() {
                            // Wait, but never past the engine's end.
                            Some(delay) => {
                                let s = lock(&shared.slots);
                                let _ = shared.cond.wait_timeout_while(s, delay, |s| !s.stop);
                            }
                            None => {
                                eprintln!(
                                    "swiftly-player: giving up on shared video buffers of {}x{}",
                                    want.0, want.1
                                );
                                gave_up_at = Some(want);
                            }
                        }
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
            internal_format: 0x8058,
        };
        // The host samples the image with its first row at the top, and libmpv draws an FBO right way up for GL's
        // origin at the bottom left, so no flip is wanted (`flip_y` = 1 stood the picture on its head, measured against the
        // software renderer's picture; the Linux way found the same).
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
        unsafe { (wgl.gl.finish)() };
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
        s.wake = true;
        drop(s);
        wake.fire();
    }
    unsafe {
        (rc.set_cb)(ctx, None, std::ptr::null_mut());
        (rc.free)(ctx);
    }
    if let Some(mut r) = ring.take() {
        r.free(&wgl.gl);
    }
    drop(wgl);
}
