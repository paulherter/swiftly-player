//! The Android JNI file: the Kotlin `app.swiftly.rustshell.Native` object calls these functions on the UI thread. Every
//! function returns the `FLAG_*` bit set of `host` (frame wanted, keyboard wanted, changed). The only `unsafe` code is
//! the conversion of the Java `Surface` into an `ANativeWindow`.
#![allow(unsafe_code)]

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use jni::JNIEnv;
use jni::objects::{JClass, JObject, JString};
use jni::sys::{jboolean, jfloat, jint, jlong};
use ndk::native_window::NativeWindow;
use swiftly_render::{Color, GpuContext, WgpuRenderer};

use crate::host::{Host, TextKind};

/// The ground colour behind everything (`colour::REASON`, as on the desktop).
const CLEAR_OPAQUE: Color = Color {
    r: 0.0627451,
    g: 0.0627451,
    b: 0.0627451,
    a: 1.0,
};

/// The UI surface lies over a video `SurfaceView` (G3): clear to transparent and ask for a premultiplied surface.
static TRANSPARENT: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn transparent() -> bool {
    TRANSPARENT.load(std::sync::atomic::Ordering::Relaxed)
}

fn clear_color() -> Color {
    if transparent() {
        Color::new(0.0, 0.0, 0.0, 0.0)
    } else {
        CLEAR_OPAQUE
    }
}

/// `Native.setLive(on: Boolean)`: the real app instead of the scripted demo; call after `initLive`, before `create`.
static LIVE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[unsafe(no_mangle)]
pub extern "system" fn Java_app_swiftly_rustshell_Native_setLive(
    _env: JNIEnv,
    _class: JClass,
    on: jboolean,
) {
    LIVE.store(on != 0, std::sync::atomic::Ordering::Relaxed);
}

/// `Native.setTransparent(on: Boolean)`: call before the surface exists.
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_swiftly_rustshell_Native_setTransparent(
    _env: JNIEnv,
    _class: JClass,
    on: jboolean,
) {
    TRANSPARENT.store(on != 0, std::sync::atomic::Ordering::Relaxed);
}

#[link(name = "log")]
unsafe extern "C" {
    fn __android_log_write(
        prio: i32,
        tag: *const std::ffi::c_char,
        text: *const std::ffi::c_char,
    ) -> i32;
}

/// Writes one line to logcat under the tag `SwiftlyRust` (priority 3 debug, 4 info, 5 warn, 6 error).
fn alog(prio: i32, msg: &str) {
    let clean: String = msg.chars().filter(|c| *c != '\0').collect();
    if let (Ok(tag), Ok(text)) = (
        std::ffi::CString::new("SwiftlyRust"),
        std::ffi::CString::new(clean),
    ) {
        // SAFETY: both pointers are NUL-terminated C strings that outlive the call.
        unsafe { __android_log_write(prio, tag.as_ptr(), text.as_ptr()) };
    }
}

macro_rules! info { ($($a:tt)*) => { alog(4, &format!($($a)*)) } }
macro_rules! error { ($($a:tt)*) => { alog(6, &format!($($a)*)) } }

/// Routes the `log` records of wgpu and friends to logcat.
struct LogcatLogger;

impl log::Log for LogcatLogger {
    fn enabled(&self, m: &log::Metadata) -> bool {
        m.level() <= log::Level::Info
    }
    fn log(&self, r: &log::Record) {
        if self.enabled(r.metadata()) {
            let prio = match r.level() {
                log::Level::Error => 6,
                log::Level::Warn => 5,
                _ => 4,
            };
            alog(prio, &format!("{}: {}", r.target(), r.args()));
        }
    }
    fn flush(&self) {}
}

static LOGGER: LogcatLogger = LogcatLogger;

pub(crate) fn init_logging() {
    if log::set_logger(&LOGGER).is_ok() {
        log::set_max_level(log::LevelFilter::Info);
        swiftly_net::redact::install_panic_hook(|line| error!("{line}"));
    }
}

/// The (empty) Android display handle wgpu 30 wants on the instance before it creates a surface.
#[derive(Debug)]
struct AndroidDisplay;

impl raw_window_handle::HasDisplayHandle for AndroidDisplay {
    fn display_handle(
        &self,
    ) -> Result<raw_window_handle::DisplayHandle<'_>, raw_window_handle::HandleError> {
        Ok(raw_window_handle::DisplayHandle::android())
    }
}

struct Gpu {
    instance: wgpu::Instance,
    window: Arc<NativeWindow>,
    surface: wgpu::Surface<'static>,
    ctx: GpuContext,
    renderer: WgpuRenderer,
    config: wgpu::SurfaceConfiguration,
    frames: u64,
}

impl Gpu {
    fn new(
        window: Arc<NativeWindow>,
        w: u32,
        h: u32,
        backends: wgpu::Backends,
    ) -> Result<Gpu, String> {
        let mut desc = wgpu::InstanceDescriptor::new_with_display_handle(Box::new(AndroidDisplay));
        desc.backends = backends;
        // The emulator's vulkan.ranchu.so crashes (null `vkSetDebugUtilsObjectNameEXT`) when wgpu names objects, which
        // debug builds do through the DEBUG/VALIDATION flags; so no debug utils, in any build.
        desc.flags = wgpu::InstanceFlags::empty();
        let instance = wgpu::Instance::new(desc);
        info!("wgpu instance created for {backends:?}");
        let surface = instance
            .create_surface(wgpu::SurfaceTarget::from_window_without_display(
                Arc::clone(&window),
            ))
            .map_err(|e| format!("create_surface: {e}"))?;
        info!("wgpu surface created");
        let ctx = pollster::block_on(GpuContext::from_instance(&instance, Some(&surface)))
            .map_err(|e| e.to_string())?;
        let ai = ctx.adapter_info();
        info!(
            "adapter: backend {:?}, name {:?}, type {:?}, driver {:?}",
            ai.backend, ai.name, ai.device_type, ai.driver
        );
        info!("device and queue ready");
        ctx.device()
            .on_uncaptured_error(Arc::new(|e| error!("wgpu uncaptured error: {e}")));
        let mut config = ctx
            .surface_config(&surface, w.max(1), h.max(1))
            .ok_or("the adapter cannot present to this surface")?;
        let caps = surface.get_capabilities(ctx.adapter());
        info!(
            "surface caps: formats {:?}, present {:?}, alpha {:?}",
            caps.formats, caps.present_modes, caps.alpha_modes
        );
        if caps.present_modes.contains(&wgpu::PresentMode::Fifo) {
            config.present_mode = wgpu::PresentMode::Fifo;
        } else if let Some(m) = caps.present_modes.first() {
            config.present_mode = *m;
        }
        let over_video = [
            wgpu::CompositeAlphaMode::PreMultiplied,
            wgpu::CompositeAlphaMode::PostMultiplied,
        ]
        .into_iter()
        .find(|m| caps.alpha_modes.contains(m));
        if let (true, Some(m)) = (transparent(), over_video) {
            config.alpha_mode = m;
        } else if caps.alpha_modes.contains(&wgpu::CompositeAlphaMode::Opaque) {
            config.alpha_mode = wgpu::CompositeAlphaMode::Opaque;
        } else if let Some(m) = caps.alpha_modes.first() {
            config.alpha_mode = *m;
        }
        config.desired_maximum_frame_latency = 2;
        surface.configure(ctx.device(), &config);
        info!(
            "surface configured: format {:?}, present {:?}, alpha {:?}, {}x{}",
            config.format, config.present_mode, config.alpha_mode, config.width, config.height
        );
        let renderer = WgpuRenderer::new(&ctx, config.format).map_err(|e| e.to_string())?;
        info!("renderer ready");
        Ok(Gpu {
            instance,
            window,
            surface,
            ctx,
            renderer,
            config,
            frames: 0,
        })
    }

    fn resize(&mut self, w: u32, h: u32) {
        self.config.width = w.max(1);
        self.config.height = h.max(1);
        self.surface.configure(self.ctx.device(), &self.config);
        info!(
            "surface reconfigured: {}x{}",
            self.config.width, self.config.height
        );
    }

    /// Draws one list; `false` when the surface needs another try (outdated, lost).
    fn draw(&mut self, host: &Host, list: &swiftly_render::DrawList) -> bool {
        use wgpu::CurrentSurfaceTexture as C;
        let frame = match self.surface.get_current_texture() {
            C::Success(f) => f,
            C::Suboptimal(f) => f,
            C::Outdated => {
                error!("surface outdated, reconfiguring");
                self.resize(self.config.width, self.config.height);
                return false;
            }
            C::Lost => {
                error!("surface lost, recreating");
                match self.instance.create_surface(
                    wgpu::SurfaceTarget::from_window_without_display(Arc::clone(&self.window)),
                ) {
                    Ok(s) => {
                        self.surface = s;
                        self.resize(self.config.width, self.config.height);
                    }
                    Err(e) => error!("recreate surface: {e}"),
                }
                return false;
            }
            C::Occluded => return true,
            C::Timeout => {
                error!("get_current_texture: timeout");
                return false;
            }
            C::Validation => {
                error!("get_current_texture: validation error");
                return false;
            }
        };
        let size = (frame.texture.width(), frame.texture.height());
        let (sx, sy, sw, sh) = host.stage_px();
        if (sw, sh) == size || sw == 0 || sh == 0 {
            let view = frame
                .texture
                .create_view(&wgpu::TextureViewDescriptor::default());
            host.shell()
                .with_sources(|src| self.renderer.draw(list, &view, size, clear_color(), src));
        } else {
            // Letterbox: draw the stage into its own texture, clear the surface, copy the stage into the middle.
            let dev = self.ctx.device();
            let stage = dev.create_texture(&wgpu::TextureDescriptor {
                label: None,
                size: wgpu::Extent3d {
                    width: sw,
                    height: sh,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: self.config.format,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                    | wgpu::TextureUsages::COPY_SRC
                    | wgpu::TextureUsages::TEXTURE_BINDING,
                view_formats: &[],
            });
            let sview = stage.create_view(&wgpu::TextureViewDescriptor::default());
            host.shell().with_sources(|src| {
                self.renderer
                    .draw(list, &sview, (sw, sh), clear_color(), src)
            });
            let view = frame
                .texture
                .create_view(&wgpu::TextureViewDescriptor::default());
            host.shell().with_sources(|src| {
                self.renderer.draw(
                    &swiftly_render::DrawList::new(size.0 as f32, size.1 as f32, 1.0),
                    &view,
                    size,
                    clear_color(),
                    src,
                )
            });
            let mut enc = dev.create_command_encoder(&wgpu::CommandEncoderDescriptor::default());
            enc.copy_texture_to_texture(
                stage.as_image_copy(),
                wgpu::TexelCopyTextureInfo {
                    origin: wgpu::Origin3d { x: sx, y: sy, z: 0 },
                    ..frame.texture.as_image_copy()
                },
                wgpu::Extent3d {
                    width: sw,
                    height: sh,
                    depth_or_array_layers: 1,
                },
            );
            self.ctx.queue().submit([enc.finish()]);
        }
        self.ctx.queue().present(frame);
        if self.frames == 0 {
            info!(
                "first frame rendered and presented: {} quads, {}x{}",
                list.quads().len(),
                size.0,
                size.1
            );
        }
        self.frames += 1;
        true
    }
}

/// The software fallback: `swiftly-render` draws on the CPU and the picture is copied into the locked window buffer.
struct Cpu {
    window: Arc<NativeWindow>,
    frames: u64,
}

impl Cpu {
    fn new(window: Arc<NativeWindow>, w: u32, h: u32) -> Result<Cpu, String> {
        use ndk::hardware_buffer_format::HardwareBufferFormat as F;
        window
            .set_buffers_geometry(w as i32, h as i32, Some(F::R8G8B8A8_UNORM))
            .map_err(|e| format!("set_buffers_geometry: {e}"))?;
        info!("cpu fallback: window buffers {w}x{h} RGBA8888");
        Ok(Cpu { window, frames: 0 })
    }

    fn draw(&mut self, host: &Host, list: &swiftly_render::DrawList) -> bool {
        let img = host
            .shell()
            .with_sources(|src| swiftly_render::SoftwareRenderer::render(list, clear_color(), src));
        let mut guard = match self.window.lock(None) {
            Ok(g) => g,
            Err(e) => {
                error!("ANativeWindow_lock: {e}");
                return false;
            }
        };
        let (stride, gw, gh) = (guard.stride(), guard.width(), guard.height());
        let Some(bytes) = guard.bytes() else {
            error!("window buffer format has no byte access");
            return false;
        };
        let (ox, oy, _, _) = host.stage_px();
        let (ox, oy) = (ox as usize, oy as usize);
        let rows = img.height.min(gh.saturating_sub(oy));
        let cols = img.width.min(gw.saturating_sub(ox));
        for y in 0..rows {
            let src = &img.pixels[y * img.width * 4..y * img.width * 4 + cols * 4];
            let dst =
                &mut bytes[(y + oy) * stride * 4 + ox * 4..(y + oy) * stride * 4 + (ox + cols) * 4];
            for (d, s) in dst.iter_mut().zip(src) {
                d.write(*s);
            }
        }
        if self.frames == 0 {
            info!(
                "cpu: first frame blitted: {} quads, picture {}x{}, buffer {}x{} stride {}",
                list.quads().len(),
                img.width,
                img.height,
                gw,
                gh,
                stride
            );
        }
        self.frames += 1;
        true
    }
}

/// Where the pictures go: the GPU surface, or the CPU blit when no adapter works.
enum Output {
    Gpu(Box<Gpu>),
    Cpu(Cpu),
}

impl Output {
    fn window(&self) -> &Arc<NativeWindow> {
        match self {
            Output::Gpu(g) => &g.window,
            Output::Cpu(c) => &c.window,
        }
    }

    /// Vulkan, then GL, then the CPU. Each failure is logged.
    fn open(window: Arc<NativeWindow>, w: u32, h: u32) -> Output {
        for backends in [wgpu::Backends::VULKAN, wgpu::Backends::GL] {
            match Gpu::new(Arc::clone(&window), w, h, backends) {
                Ok(g) => return Output::Gpu(Box::new(g)),
                Err(e) => error!("gpu via {backends:?} failed: {e}"),
            }
        }
        match Cpu::new(Arc::clone(&window), w, h) {
            Ok(c) => Output::Cpu(c),
            Err(e) => {
                error!("cpu fallback failed: {e}");
                // Last resort: still a CPU output so frames keep trying.
                Output::Cpu(Cpu { window, frames: 0 })
            }
        }
    }

    fn draw(&mut self, host: &Host, list: &swiftly_render::DrawList) -> bool {
        match self {
            Output::Gpu(g) => g.draw(host, list),
            Output::Cpu(c) => c.draw(host, list),
        }
    }
}

#[derive(Default)]
struct State {
    host: Option<Host>,
    out: Option<Output>,
    size: (u32, u32),
    density: f32,
}

// The app is not `Send` (shared `Rc` text and image stores): all calls come from the one Android UI thread.
thread_local! {
    static STATE: Rc<RefCell<State>> = Rc::new(RefCell::new(State::default()));
}

/// The state of this (the UI) thread.
fn state() -> Rc<RefCell<State>> {
    STATE.with(Rc::clone)
}

fn ms(nanos: jlong) -> f64 {
    nanos as f64 / 1_000_000.0
}

fn with_host(f: impl FnOnce(&mut Host) -> i32) -> jint {
    state().borrow_mut().host.as_mut().map_or(0, f)
}

/// `Native.create(tv: Boolean, width: Int, height: Int, density: Float)`: a new app for the next surface.
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_swiftly_rustshell_Native_create(
    _env: JNIEnv,
    _class: JClass,
    tv: jboolean,
    width: jint,
    height: jint,
    density: jfloat,
) {
    init_logging();
    info!("create: tv {tv}, {width}x{height}, density {density}");
    let size = (width.max(1) as u32, height.max(1) as u32);
    let cell = state();
    let mut st = cell.borrow_mut();
    st.size = size;
    st.density = density;
    st.host = Some(
        match LIVE
            .load(std::sync::atomic::Ordering::Relaxed)
            .then(swiftly_desktop::live::Core::open)
        {
            Some(Ok(core)) => Host::new_live(tv != 0, size, density, Arc::new(core)),
            Some(Err(e)) => {
                error!("real app did not start ({e}), demo instead");
                Host::new(tv != 0, size, density)
            }
            None => Host::new(tv != 0, size, density),
        },
    );
}

/// `Native.surfaceChanged(surface: Surface, width: Int, height: Int, density: Float): Int`.
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_swiftly_rustshell_Native_surfaceChanged(
    env: JNIEnv,
    _class: JClass,
    surface: JObject,
    width: jint,
    height: jint,
    density: jfloat,
) -> jint {
    let (w, h) = (width.max(1) as u32, height.max(1) as u32);
    let cell = state();
    let mut st = cell.borrow_mut();
    st.size = (w, h);
    st.density = density;
    info!("surfaceChanged {w}x{h} density {density}");
    // SAFETY: `env` and `surface` are the live JNI environment and `android.view.Surface` of this call; `from_surface`
    // acquires its own reference to the window, which the `NativeWindow` releases on drop.
    let window =
        unsafe { NativeWindow::from_surface(env.get_raw().cast(), surface.as_raw().cast()) };
    let Some(window) = window.map(Arc::new) else {
        error!("ANativeWindow_fromSurface returned null");
        return 0;
    };
    match st.out.as_mut() {
        Some(Output::Gpu(g)) if g.window.ptr() == window.ptr() => g.resize(w, h),
        Some(o) if o.window().ptr() == window.ptr() => {
            if let Output::Cpu(c) = o {
                *c = match Cpu::new(Arc::clone(&c.window), w, h) {
                    Ok(n) => n,
                    Err(e) => {
                        error!("cpu resize: {e}");
                        return 0;
                    }
                };
            }
        }
        _ => st.out = Some(Output::open(window, w, h)),
    }
    st.host
        .as_mut()
        .map_or(0, |host| host.resize((w, h), density))
        | crate::host::FLAG_WANTS_FRAME
}

/// `Native.surfaceDestroyed()`: drop the GPU state before Android takes the window away.
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_swiftly_rustshell_Native_surfaceDestroyed(
    _env: JNIEnv,
    _class: JClass,
) {
    info!("surfaceDestroyed");
    state().borrow_mut().out = None;
}

/// `Native.insets(left, top, right, bottom: Int): Int` in pixels.
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_swiftly_rustshell_Native_insets(
    _env: JNIEnv,
    _class: JClass,
    l: jint,
    t: jint,
    r: jint,
    b: jint,
) -> jint {
    with_host(|h| h.set_insets_px(l as f32, t as f32, r as f32, b as f32))
}

/// `Native.touch(phase: Int, x: Float, y: Float, eventTimeMs: Long): Int`.
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_swiftly_rustshell_Native_touch(
    _env: JNIEnv,
    _class: JClass,
    phase: jint,
    x: jfloat,
    y: jfloat,
    event_ms: jlong,
) -> jint {
    with_host(|h| h.touch(phase.clamp(0, 3) as u8, x, y, event_ms as f64))
}

/// `Native.key(code: Int, down: Boolean, repeat: Boolean, unicode: Int, shift: Boolean, eventTimeMs: Long): Int`.
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_swiftly_rustshell_Native_key(
    _env: JNIEnv,
    _class: JClass,
    code: jint,
    down: jboolean,
    repeat: jboolean,
    unicode: jint,
    shift: jboolean,
    event_ms: jlong,
) -> jint {
    with_host(|h| {
        h.key(
            code,
            down != 0,
            repeat != 0,
            unicode.max(0) as u32,
            shift != 0,
            event_ms as f64,
        )
    })
}

/// `Native.back(eventTimeMs: Long): Int`; the result has `FLAG_BACK_UNHANDLED` when the system may leave the app.
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_swiftly_rustshell_Native_back(
    _env: JNIEnv,
    _class: JClass,
    event_ms: jlong,
) -> jint {
    with_host(|h| h.back(event_ms as f64))
}

/// `Native.text(kind: Int, text: String): Int` from the Kotlin `InputConnection`.
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_swiftly_rustshell_Native_text(
    mut env: JNIEnv,
    _class: JClass,
    kind: jint,
    text: JString,
) -> jint {
    let Some(kind) = TextKind::from_code(kind) else {
        return 0;
    };
    let s: String = if text.is_null() {
        String::new()
    } else {
        env.get_string(&text).map(Into::into).unwrap_or_default()
    };
    with_host(|h| h.text(kind, &s))
}

/// `Native.frame(frameTimeNanos: Long): Int`: draws one frame; `FLAG_WANTS_FRAME` asks Kotlin for the next.
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_swiftly_rustshell_Native_frame(
    _env: JNIEnv,
    _class: JClass,
    frame_nanos: jlong,
) -> jint {
    let cell = state();
    let mut st = cell.borrow_mut();
    let State { host, out, .. } = &mut *st;
    let (Some(host), Some(gpu)) = (host.as_mut(), out.as_mut()) else {
        info!("frame without surface or host");
        return 0;
    };
    let (list, mut more) = host.frame(ms(frame_nanos));
    if !gpu.draw(host, &list) {
        more = true;
    }
    host.frame_flags(more)
}
