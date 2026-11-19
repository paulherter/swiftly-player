//! The window: winit event loop, wgpu surface (FIFO present), input translation, frame pacing by `RedrawRequested`.
//!
//! Pacing: a frame is drawn only when something asked for it. An input event that changes the picture asks for one;
//! a frame that reports "wants another" (animation, glide, held touch, scripted run) asks for the next. Nothing
//! asked: the loop sleeps (`ControlFlow::Wait`), so an idle window costs no CPU or GPU.

use crate::cli::Options;
use crate::shell::{Command, Ime, Shell};
use crate::stats::FrameStats;
use crate::wheel::{WheelDelta, WheelPhase};
use std::sync::Arc;
use std::time::{Duration, Instant};
use swiftly_render::{Color, DrawList, GpuContext, WgpuRenderer};
use swiftly_ui::{Dir, NavKey};
use winit::application::ApplicationHandler;
use winit::dpi::LogicalSize;
use winit::event::{
    ElementState, Ime as WinitIme, MouseButton, MouseScrollDelta, TouchPhase, WindowEvent,
};
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop, EventLoopProxy};
use winit::keyboard::{Key, ModifiersState, NamedKey};
use winit::window::{Window, WindowId};

/// What the event loop carries besides window events: the screen-reader adapter's requests.
#[derive(Debug)]
enum UserEvent {
    Access(accesskit_winit::Event),
    /// Second launches and the scripted wheel run (see `window_extras`).
    Extra(crate::window_extras::Event),
    /// A button of the system's media widgets or a headset was pressed (sent from the system's thread).
    Media,
    /// The player's engine has something new (a picture, a property, an end): see `Running::video_wake`.
    Video,
}

impl From<accesskit_winit::Event> for UserEvent {
    fn from(e: accesskit_winit::Event) -> UserEvent {
        UserEvent::Access(e)
    }
}

/// The ground colour behind everything (`colour::REASON`).
const CLEAR: Color = Color {
    r: 0.0627451,
    g: 0.0627451,
    b: 0.0627451,
    a: 1.0,
};

/// The ground behind the player: the film's own black.
const PLAYER_GROUND: Color = Color {
    r: 0.0,
    g: 0.0,
    b: 0.0,
    a: 1.0,
};

enum Acquired {
    /// An image to draw into; `true`: the surface no longer fits the window, fit it again AFTER this image is presented
    /// (wgpu refuses to configure a surface while one of its images is still out).
    Frame(wgpu::SurfaceTexture, bool),
    /// Nothing to draw now: the window is hidden, covered or minimised. Windows sends no `Occluded(false)` and no
    /// resize when it comes back, so the loop asks again after [`RETRY_MS`].
    Later,
    /// Ask again at once (the surface was just refitted).
    Retry,
}

/// How long to wait before asking a covered window or a failing surface for an image again.
/// How old the held picture of the interface may get while a film plays and only its engine wakes the window: the pace
/// of the idle poll, so a clock, a progress bar or an end of file never wait longer than that.
const VIDEO_UI_PERIOD_MS: f64 = 250.0;

const RETRY_MS: f64 = 100.0;

/// The wgpu side of the window.
struct Gpu {
    instance: wgpu::Instance,
    window: Arc<Window>,
    surface: wgpu::Surface<'static>,
    ctx: GpuContext,
    renderer: WgpuRenderer,
    config: wgpu::SurfaceConfiguration,
    /// Set by the driver callback when the device is gone (driver reset, GPU removed): everything is built again.
    lost: Arc<std::sync::atomic::AtomicBool>,
    /// The video layer under the UI; `None` = the player screen copies frames into the image page (CPU path).
    video: Option<crate::frame_surface::GpuVideoHost>,
    /// Milliseconds the last `draw` spent recording and submitting the picture, and handing the image to the swap chain.
    last_render_ms: f64,
    last_present_ms: f64,
    /// Same, for what `draw` does before the renderer (view, video sync, window corner).
    last_prelude_ms: f64,
    /// `SWIFTLY_DESKTOP_TRACE_GPU=1`: wait for the graphics hardware after every picture, to see how long it really runs
    /// (the swap-chain refit of the next resize otherwise waits for it unseen). Slows the app down; measuring only.
    probe_gpu: bool,
    last_gpu_ms: f64,
    last_draw_ms: f64,
}

impl Gpu {
    fn new(
        event_loop: &ActiveEventLoop,
        window: Arc<Window>,
        opts_dump: bool,
    ) -> Result<Gpu, String> {
        let build = |backends: wgpu::Backends| -> Result<_, String> {
            let mut desc = wgpu::InstanceDescriptor::new_with_display_handle(Box::new(
                event_loop.owned_display_handle(),
            ));
            // The standard wgpu switch (`WGPU_BACKEND=dx12`) still picks the graphics API, for measuring one against another.
            desc.backends = wgpu::Backends::from_env().unwrap_or(backends);
            let instance = wgpu::Instance::new(desc);
            let surface = instance
                .create_surface(Arc::clone(&window))
                .map_err(|e| format!("create_surface: {e}"))?;
            let ctx = pollster::block_on(GpuContext::from_instance(&instance, Some(&surface)))
                .map_err(|e| e.to_string())?;
            Ok((instance, surface, ctx))
        };
        let all = wgpu::Backends::VULKAN
            | wgpu::Backends::DX12
            | wgpu::Backends::METAL
            | wgpu::Backends::GL;
        // Vulkan first only when the Windows video GPU way is asked for (it shares images with the engine through Vulkan's
        // Win32 memory export); DX12 and the rest stay as the way out. Every other case tries all backends, as before.
        let (instance, surface, ctx) = if swiftly_render::vulkan_first() {
            build(wgpu::Backends::VULKAN).or_else(|e| {
                eprintln!(
                    "swiftly-desktop: no Vulkan adapter for the window ({e}); trying the others"
                );
                build(all)
            })?
        } else {
            build(all)?
        };
        let size = window.inner_size();
        let mut config = ctx
            .surface_config(&surface, size.width.max(1), size.height.max(1))
            .ok_or("the adapter cannot present to this window")?;
        if opts_dump
            && ctx
                .adapter()
                .get_texture_format_features(config.format)
                .allowed_usages
                .contains(wgpu::TextureUsages::COPY_SRC)
            && surface
                .get_capabilities(ctx.adapter())
                .usages
                .contains(wgpu::TextureUsages::COPY_SRC)
        {
            config.usage |= wgpu::TextureUsages::COPY_SRC;
        }
        config.present_mode = wgpu::PresentMode::Fifo;
        config.desired_maximum_frame_latency = 1;
        if cfg!(target_os = "linux") {
            // Rounded window corners need an alpha channel the compositor reads (premultiplied, what the renderer writes).
            if surface
                .get_capabilities(ctx.adapter())
                .alpha_modes
                .contains(&wgpu::CompositeAlphaMode::PreMultiplied)
            {
                config.alpha_mode = wgpu::CompositeAlphaMode::PreMultiplied;
            }
        }
        surface.configure(ctx.device(), &config);
        let renderer = WgpuRenderer::new(&ctx, config.format).map_err(|e| e.to_string())?;
        // wgpu panics on an error nobody caught (that ended the app without a word); log it and carry on instead.
        let seen = Arc::new(std::sync::atomic::AtomicU32::new(0));
        ctx.device()
            .on_uncaptured_error(Arc::new(move |e: wgpu::Error| {
                if seen.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 20 {
                    eprintln!("swiftly-desktop: wgpu error: {e}");
                    crate::crash::note_error("wgpu error", &e.to_string());
                }
            }));
        let lost = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = Arc::clone(&lost);
        ctx.device()
            .set_device_lost_callback(move |reason, message| {
                if reason != wgpu::DeviceLostReason::Destroyed {
                    crate::crash::note_error("gpu device lost", &message);
                    flag.store(true, std::sync::atomic::Ordering::SeqCst);
                }
            });
        #[cfg(all(feature = "mpv", any(target_os = "linux", windows)))]
        crate::dmabuf_import::announce(&ctx);
        let video =
            crate::frame_surface::GpuVideoHost::new(ctx.device().limits().max_texture_dimension_2d);
        Ok(Gpu {
            video,
            instance,
            window,
            surface,
            ctx,
            renderer,
            config,
            lost,
            last_render_ms: 0.0,
            last_present_ms: 0.0,
            last_prelude_ms: 0.0,
            probe_gpu: std::env::var_os("SWIFTLY_DESKTOP_TRACE_GPU").is_some(),
            last_gpu_ms: 0.0,
            last_draw_ms: 0.0,
        })
    }

    fn resize(&mut self, w: u32, h: u32) {
        // A size past the device limit is a validation error, which would be an uncaught wgpu panic.
        let max = self.ctx.device().limits().max_texture_dimension_2d.max(1);
        self.config.width = w.clamp(1, max);
        self.config.height = h.clamp(1, max);
        self.surface.configure(self.ctx.device(), &self.config);
    }

    fn device_lost(&self) -> bool {
        self.lost.load(std::sync::atomic::Ordering::SeqCst)
    }

    fn acquire(&mut self) -> Acquired {
        use wgpu::CurrentSurfaceTexture as C;
        match self.surface.get_current_texture() {
            C::Success(f) => Acquired::Frame(f, false),
            // Still usable: draw it, then fit the surface to the window (`resize` while the image is out is an error).
            C::Suboptimal(f) => Acquired::Frame(f, true),
            C::Occluded | C::Timeout | C::Validation => Acquired::Later,
            C::Outdated => {
                let s = self.window.inner_size();
                self.resize(s.width, s.height);
                Acquired::Retry
            }
            C::Lost => match self.instance.create_surface(Arc::clone(&self.window)) {
                Ok(s) => {
                    self.surface = s;
                    let size = self.window.inner_size();
                    self.resize(size.width, size.height);
                    Acquired::Retry
                }
                Err(_) => Acquired::Later,
            },
        }
    }

    fn draw(
        &mut self,
        frame: wgpu::SurfaceTexture,
        list: &DrawList,
        shell: &Shell,
        dump: Option<&std::path::Path>,
    ) -> Result<(), String> {
        let draw_began = Instant::now();
        let view = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        let size = (frame.texture.width(), frame.texture.height());
        if let Some(host) = &self.video {
            host.sync(&shell.video(), &mut self.renderer);
        }
        let round = self.config.alpha_mode == wgpu::CompositeAlphaMode::PreMultiplied;
        self.renderer.set_window_corner(if round {
            crate::window_rules::window_corner_px(
                self.window.scale_factor() as f32,
                self.window.fullscreen().is_some(),
                self.window.is_maximized(),
            )
        } else {
            0.0
        });
        // The player's ground is black like the Mac's: the letterbox, and the whole window once the controls are gone.
        let ground = if shell.player_open() {
            PLAYER_GROUND
        } else {
            CLEAR
        };
        let render_began = Instant::now();
        self.last_prelude_ms = render_began.duration_since(draw_began).as_secs_f64() * 1000.0;
        shell.with_sources(|src| self.renderer.draw(list, &view, size, ground, src));
        self.last_render_ms = render_began.elapsed().as_secs_f64() * 1000.0;
        if self.probe_gpu {
            let gpu_began = Instant::now();
            let _ = self.ctx.device().poll(wgpu::PollType::wait_indefinitely());
            self.last_gpu_ms = gpu_began.elapsed().as_secs_f64() * 1000.0;
        }
        // The readback copies the very texture that is presented next: what the swapchain shows.
        let dumped = dump.map(|path| {
            crate::dump::dump_texture(&self.ctx, &frame.texture, self.config.format, path)
        });
        self.window.pre_present_notify();
        let present_began = Instant::now();
        self.ctx.queue().present(frame);
        self.last_present_ms = present_began.elapsed().as_secs_f64() * 1000.0;
        self.last_draw_ms = draw_began.elapsed().as_secs_f64() * 1000.0;
        dumped.unwrap_or(Ok(()))
    }
}

struct Running {
    window: Arc<Window>,
    gpu: Gpu,
    shell: Shell,
    /// The previous frame asked for this one (continuous animation), as opposed to an input event.
    continuous: bool,
    /// The redraw was asked by the idle poll of the real app (not by input): it presents only if the picture changed.
    idle_poll: bool,
    /// The engine woke the window since the last frame (a new picture or a property of the film), and nothing else did
    /// (`other`): the frame may reuse the last built picture of the interface and only bring the video up to date.
    video_wake: bool,
    /// Something other than the engine asked for a frame (input, a window event, another view model's answer).
    other: bool,
    /// The last built picture of the interface while a film plays and nothing animates, and when it was built (ms).
    held: Option<(DrawList, f64)>,
    /// Fingerprint of the last picture an idle poll looked at.
    last_fp: Option<u64>,
    size_px: (u32, u32),
    scale: f32,
    /// The screen-reader adapter (UI Automation on Windows, AT-SPI on Linux).
    adapter: accesskit_winit::Adapter,
    /// A screen reader is connected: the tree is rebuilt and published after frames.
    a11y_active: bool,
    /// Centres of the published nodes (window points), to turn a reader's Click into a tap.
    a11y_centres: std::collections::HashMap<u64, (f32, f32)>,
    /// When the tree was last published (ms), to thin it out while an animation runs.
    a11y_at: f64,
    /// What the window told the input method (open only over a text field, password purpose, caret rectangle).
    ime: crate::ime::ImeSync,
    /// The cursor is hidden with the player's controls.
    cursor_hidden: bool,
    /// The system's media widgets (SMTC, MPRIS); only in the real app.
    media: Option<crate::media_keys::MediaSync<crate::os_media::OsMedia>>,
    /// Addresses whose activation token the compositor has not answered yet (`browser_open`).
    opening: crate::browser_open::Waiting<winit::event_loop::AsyncRequestSerial>,
}

/// The native window handle SMTC needs (`None` off Windows).
fn hwnd_of(window: &Window) -> Option<*mut std::ffi::c_void> {
    use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};
    match window.window_handle().ok()?.as_raw() {
        RawWindowHandle::Win32(h) => Some(h.hwnd.get() as *mut std::ffi::c_void),
        _ => None,
    }
}

impl Running {
    /// Opens an address in the browser with this window's activation token, so an already running browser comes to
    /// the front (Wayland/X11, see `browser_open`); where there is no token the opener starts at once.
    fn open_url(&mut self, url: String, now_ms: f64) {
        #[cfg(target_os = "linux")]
        if std::env::var_os("SWIFTLY_NO_BROWSER").is_none() {
            use winit::platform::startup_notify::WindowExtStartupNotify;
            if let Ok(serial) = self.window.request_activation_token() {
                self.opening.add(serial, url, now_ms);
                return;
            }
        }
        let _ = now_ms;
        let _ = crate::signin_flows::open_url(&url);
    }

    /// Publishes the tree of the screen in front when a screen reader is connected.
    fn publish_tree(&mut self) {
        let (title, nodes) = self.shell.a11y_nodes();
        let scale = self.scale;
        let centres = &mut self.a11y_centres;
        self.adapter.update_if_active(|| {
            let built = crate::a11y_bridge::build(title, &nodes, scale);
            *centres = built.centres;
            built.update
        });
    }
}

struct App {
    proxy: EventLoopProxy<UserEvent>,
    opts: Options,
    start: Instant,
    /// Total time the scripted shots took (see [`App::now`]).
    shot_pause: Duration,
    run: Option<Running>,
    stats: Option<FrameStats>,
    mods: ModifiersState,
    failure: Option<String>,
    verbose_events: bool,
    /// Frames presented so far, and whether `--dump-frame` has been written.
    frames_drawn: u32,
    dumped: bool,
    touch_next: usize,
    /// `--script`: the steps still to run, and the frame a step asked to dump.
    script: Option<crate::script::Script>,
    /// The `anchor` step's point (window points) for `move-from`.
    script_anchor: Option<(f64, f64)>,
    shot: Option<std::path::PathBuf>,
    /// Single instance, launches, input-to-present timer.
    extras: crate::window_extras::Extras,
    /// The window edge the pointer is on (drag to resize), `None` inside or when maximised / fullscreen.
    edge: Option<winit::window::ResizeDirection>,
    /// The last press on the toolbar row, for the double click that maximises.
    last_drag_press: Option<Instant>,
    /// A script step is running: its presses are not the real button, so no window drag may follow them (the system
    /// would wait in its move/size loop for a release that never comes, and the window could not close).
    synthetic: bool,
    /// The loop was asked to stop and the system's move/size loop (if any) has been told to end.
    quit_noted: bool,
    /// The pointer in physical pixels.
    cursor_px: (f64, f64),
    /// No surface image could be had: draw again at this time (ms).
    retry_at: Option<f64>,
    /// Immediate retries in a row.
    retries: u8,
    /// A scale change happened: the title bar's dark mode is set again with the resize that follows it (Windows
    /// resets it while it moves the window to the new scale).
    retheme: bool,
    /// Time from a `Resized` event to the frame presented at that size (printed with `SWIFTLY_DESKTOP_TRACE=1`).
    resize_latency: crate::resize_latency::ResizeLatency,
    /// A resize asked for a redraw that has not run yet (the fallback draws when it never comes).
    resize_fallback: crate::window_rules::ResizeFallback,
    /// `SWIFTLY_RESIZE_BENCH`: the window drags itself, for the nested compositor of the live checks.
    resize_bench: Option<crate::resize_latency::ResizeBench>,
    /// The last step of the bench was asked for at this time (ms); the summary follows after a pause.
    bench_done_at: Option<f64>,
    /// Keeps the Wayland toplevel icon alive (the compositor needs its buffers as long as the window shows it).
    #[cfg(all(
        unix,
        not(any(target_os = "macos", target_os = "ios", target_os = "android"))
    ))]
    toplevel_icon: Option<crate::toplevel_icon::Held>,
}

impl App {
    /// The app clock in ms. Time spent writing a scripted `shot` (a 4K readback plus PNG encode, 200 to 350 ms) is left
    /// out, so a series of shots shows consecutive frames of an animation and not one frame per 300 ms of it.
    fn now(&self) -> f64 {
        (self.start.elapsed().saturating_sub(self.shot_pause)).as_secs_f64() * 1000.0
    }

    /// The wall-clock instant of the app-clock time `ms` (see [`App::now`]): every wake-up deadline goes through here.
    fn instant_of(&self, ms: f64) -> Instant {
        wall_deadline(self.start, self.shot_pause, ms)
    }

    fn redraw(&mut self, event_loop: &ActiveEventLoop) {
        let entered = Instant::now();
        let now_ms = self.now();
        if self.verbose_events {
            eprintln!("swiftly-desktop: redraw at {now_ms:.1} ms");
        }
        self.resize_fallback.drawn();
        let retried = self.retry_at.take().is_some();
        self.run_script(event_loop, now_ms);
        self.note_quit(event_loop);
        let Some(run) = self.run.as_mut() else { return };
        // Windows resets the dark title bar after some DPI changes and winit's `set_theme` does not repeat it.
        crate::win_dark::ensure(&run.window);
        // The driver took the device away (reset, GPU removed): build surface, device and renderer again.
        if run.gpu.device_lost() {
            match Gpu::new(
                event_loop,
                Arc::clone(&run.window),
                self.opts.dump_frame.is_some() || self.opts.script.is_some(),
            ) {
                Ok(g) => {
                    run.gpu = g;
                    run.last_fp = None;
                }
                Err(e) => {
                    self.failure = Some(format!("gpu lost and not recoverable: {e}"));
                    event_loop.exit();
                    return;
                }
            }
        }
        let size = run.window.inner_size();
        if size.width == 0 || size.height == 0 {
            return;
        }
        // The player's fullscreen button, double-click, F and Esc ask the window; the cursor hides with the controls.
        let full = run.window.fullscreen().is_some();
        run.shell.set_fullscreen(full);
        for e in run.shell.take_effects() {
            match e {
                crate::effects::Effect::OpenUrl(url) => run.open_url(url, now_ms),
                other => crate::effects::perform(&other),
            }
        }
        for url in run.opening.expired(now_ms) {
            let _ = crate::signin_flows::open_url(&url);
        }
        // The system's media widgets: tell them what plays, and let their buttons drive the player.
        if let Some(m) = run.media.as_mut() {
            m.update(run.shell.now_playing().as_ref(), now_ms);
            for intent in m.intents() {
                run.shell.player_intent(intent, now_ms);
            }
        }
        if run.shell.take_fullscreen_request() {
            crate::window_rules::set_fullscreen(&run.window, run.window.fullscreen().is_none());
        }
        let hide = run.shell.cursor_hidden();
        if hide != run.cursor_hidden {
            run.cursor_hidden = hide;
            run.window.set_cursor_visible(!hide);
        }
        let scale = run.window.scale_factor() as f32;
        let size_changed = (size.width, size.height) != run.size_px;
        // Where the milliseconds of this frame go (printed with `SWIFTLY_DESKTOP_TRACE=1`).
        let (mut t_refit, mut t_shell) = (0.0f64, 0.0f64);
        let redraw_began = Instant::now();
        let t_head = redraw_began.duration_since(entered).as_secs_f64() * 1000.0;
        if size_changed || (scale - run.scale).abs() > f32::EPSILON {
            run.size_px = (size.width, size.height);
            run.scale = scale;
            let refit_began = Instant::now();
            run.gpu.resize(size.width, size.height);
            t_refit = refit_began.elapsed().as_secs_f64() * 1000.0;
            if size_changed {
                self.resize_latency.configure_cost(t_refit);
            }
            let shell_began = Instant::now();
            run.shell.resize(run.size_px, scale);
            t_shell = shell_began.elapsed().as_secs_f64() * 1000.0;
        }
        // The idle poll of the real app only looks: build the picture, and present nothing when it equals the last one
        // (acquiring and presenting a swap-chain image four times a second cost 4.7 % of a core on a Windows machine).
        let announce_began = Instant::now();
        if let Some(host) = &run.gpu.video {
            host.announce(&run.shell.video(), run.size_px);
        }
        let t_announce = announce_began.elapsed().as_secs_f64() * 1000.0;
        let mut pre: Option<(DrawList, bool)> = None;
        if std::mem::take(&mut run.idle_poll) && self.shot.is_none() {
            // The same clock as every other frame: a wall-clock time here ran ahead of it by the shots' pause.
            let (list, more) = run.shell.frame(now_ms);
            let fp = fingerprint(&list);
            if !more && run.last_fp == Some(fp) {
                return;
            }
            run.last_fp = Some(fp);
            pre = Some((list, more));
        } else {
            run.last_fp = None;
        }
        let acquire_began = Instant::now();
        let acquired = run.gpu.acquire();
        let t_acquire = acquire_began.elapsed().as_secs_f64() * 1000.0;
        if size_changed {
            self.resize_latency.acquire_wait(t_acquire);
        }
        let (frame, refit) = match acquired {
            Acquired::Frame(f, refit) => {
                self.retries = 0;
                (f, refit)
            }
            Acquired::Retry if self.retries < 3 => {
                self.retries += 1;
                run.window.request_redraw();
                return;
            }
            Acquired::Retry | Acquired::Later => {
                if self.stats.is_some() || self.verbose_events {
                    eprintln!(
                        "swiftly-desktop: no surface image now (window covered or surface busy), asking again"
                    );
                }
                self.retry_at = Some(now_ms + RETRY_MS);
                return;
            }
        };
        // The clock is read after the (vsync-blocking) acquire, so frame times are vsync-aligned.
        let began = Instant::now();
        let now = began
            .duration_since(self.start)
            .saturating_sub(self.shot_pause)
            .as_secs_f64()
            * 1000.0;
        let layout_began = Instant::now();
        // A film plays and only its engine woke the window: the interface did not change, so the last built picture of it
        // is drawn again over the new video picture instead of laying out and painting the whole tree at the video's
        // rate. The interface is built anew when anything else asked, when it animates, and at the idle poll's pace
        // (a clock, a progress bar, an end of file arrive through the same wake).
        let reuse = run.video_wake
            && !run.other
            && !run.continuous
            && !retried
            && !size_changed
            && pre.is_none()
            && self.shot.is_none()
            && self.opts.dump_frame.is_none()
            && self.resize_bench.is_none()
            && run
                .held
                .as_ref()
                .is_some_and(|(_, at)| now - *at < VIDEO_UI_PERIOD_MS && now >= *at);
        let mut built_at = now;
        let (list, more) = match pre.take() {
            Some(p) => p,
            None if reuse => match run.held.take() {
                Some((list, at)) => {
                    built_at = at;
                    // The interface is the old one, the video picture must not be: without this the host drops the
                    // video layer in this draw (no live player seen) and the picture stands still.
                    run.shell.player_video_step();
                    (list, false)
                }
                None => run.shell.frame(now),
            },
            None => {
                crate::stats::UI_BUILDS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                run.shell.frame(now)
            }
        };
        run.video_wake = false;
        run.other = false;
        let t_layout = layout_began.elapsed().as_secs_f64() * 1000.0;
        self.frames_drawn += 1;
        while let Some(&(at, code, x, y)) = self.opts.touch_script.get(self.touch_next)
            && at <= self.frames_drawn
        {
            self.touch_next += 1;
            run.shell.finger_id(0, code, (x, y), now);
        }
        let shot = self.shot.take();
        let dump = shot.as_deref().or_else(|| {
            (self.opts.dump_frame.as_deref())
                .filter(|_| !self.dumped && self.frames_drawn >= self.opts.after_frames.max(1))
        });
        let draw_began = Instant::now();
        let drawn = run.gpu.draw(frame, &list, &run.shell, dump);
        run.held = (!more && run.shell.player_open()).then_some((list, built_at));
        if shot.is_some() {
            self.shot_pause += draw_began.elapsed();
        }
        match drawn {
            Ok(()) if shot.is_some() => {
                crate::script::trace(&format!(
                    "shot {}",
                    shot.as_deref()
                        .map_or(String::new(), |p| p.display().to_string())
                ));
            }
            Ok(()) if dump.is_some() => {
                self.dumped = true;
                if self.opts.exit_after_dump {
                    event_loop.exit();
                }
            }
            Ok(()) => {}
            Err(e) => {
                self.failure = Some(format!("dump-frame: {e}"));
                event_loop.exit();
            }
        }
        if self.verbose_events {
            // What a live resize shows: the size the frame was made at against the window's size right after it was handed over.
            let now_size = run.window.inner_size();
            eprintln!(
                "swiftly-desktop: presented {}x{} at {now:.1} ms, window now {}x{}{}",
                run.size_px.0,
                run.size_px.1,
                now_size.width,
                now_size.height,
                if (now_size.width, now_size.height) == run.size_px {
                    ""
                } else {
                    " STALE"
                }
            );
            eprintln!(
                "swiftly-desktop: frame cost ms: {} refit {t_refit:.1}, layout of the shell {t_shell:.1}, wait for image {t_acquire:.1}, frame {t_layout:.1}, head {t_head:.1}, video announce {t_announce:.1}, draw prelude {:.1}, render {:.1}, gpu {:.1}, present {:.1}, draw total {:.1}, redraw so far {:.1}",
                if size_changed { "RESIZE" } else { "same size" },
                run.gpu.last_prelude_ms,
                run.gpu.last_render_ms,
                run.gpu.last_gpu_ms,
                run.gpu.last_present_ms,
                run.gpu.last_draw_ms,
                redraw_began.elapsed().as_secs_f64() * 1000.0
            );
        }
        if refit {
            let s = run.window.inner_size();
            run.gpu.resize(s.width, s.height);
            run.window.request_redraw();
        }
        // The frame for the size the window has now: the resize that asked for it is answered.
        let at_window_size = {
            let s = run.window.inner_size();
            (s.width, s.height) == run.size_px
        };
        // The app clock (`App::now`), read through the fields while `run` is borrowed.
        let presented_at = self
            .start
            .elapsed()
            .saturating_sub(self.shot_pause)
            .as_secs_f64()
            * 1000.0;
        if at_window_size
            && let Some(ms) = self.resize_latency.presented(presented_at)
            && self.verbose_events
        {
            eprintln!("swiftly-desktop: resize shown {ms:.1} ms after the Resized event");
        }
        self.extras.presented();
        let cpu_ms = began.elapsed().as_secs_f64() * 1000.0;
        if size_changed {
            self.resize_latency.frame_cost(cpu_ms);
        }
        if let Some(s) = self.stats.as_mut() {
            s.record(now, cpu_ms, run.continuous);
            s.why(run.shell.frame_reason(), more);
        }
        run.continuous = more;
        // The input method opens only over a text field, and its candidate window follows the caret.
        run.ime.sync(&run.window, run.shell.ime_state());
        run.shell.set_maximized(run.window.is_maximized());
        if run.shell.quit_asked() {
            event_loop.exit();
        }
        // A connected screen reader gets the new tree when the picture settles, and every 150 ms while it moves.
        if run.a11y_active && (!more || now - run.a11y_at >= 150.0) {
            run.a11y_at = now;
            run.publish_tree();
        }
        // A pending dump keeps the frames coming even when the picture is still.
        if more || (self.opts.dump_frame.is_some() && !self.dumped) {
            run.window.request_redraw();
        }
    }

    fn command(&mut self, event_loop: &ActiveEventLoop, cmd: Command) {
        if cmd == Command::Quit {
            event_loop.exit();
            return;
        }
        let now = self.now();
        if let Some(run) = self.run.as_mut() {
            run.shell.command(cmd, now);
            run.window.request_redraw();
        }
    }

    /// Carries out what the last click asked of the window: move (a double click maximises), minimise, maximise, close.
    fn window_actions(&mut self, event_loop: &ActiveEventLoop) {
        use crate::desk::WinAction as W;
        let now_ms = self.now();
        let Some(run) = self.run.as_mut() else { return };
        let Some(action) = run.shell.take_window_action() else {
            return;
        };
        let toggle = |w: &Window| w.set_maximized(!w.is_maximized());
        match action {
            W::Minimize => run.window.set_minimized(true),
            W::ToggleMaximize => toggle(&run.window),
            W::Close => event_loop.exit(),
            W::MoveWindow => {
                if crate::window_rules::system_drag_allowed(self.synthetic) {
                    let _ = run.window.drag_window();
                }
                run.shell.release_stale(now_ms);
            }
            W::DragMove => {
                let double = self
                    .last_drag_press
                    .is_some_and(|t| t.elapsed() < Duration::from_millis(400));
                if double {
                    self.last_drag_press = None;
                    toggle(&run.window);
                } else {
                    self.last_drag_press = Some(Instant::now());
                    if crate::window_rules::system_drag_allowed(self.synthetic) {
                        let _ = run.window.drag_window();
                    }
                    // Windows runs the move in its own loop and eats the button release.
                    run.shell.release_stale(now_ms);
                }
            }
        }
    }

    fn input_changed(&mut self) {
        if let Some(run) = self.run.as_mut() {
            run.other = true;
            run.window.request_redraw();
        }
    }
}

impl ApplicationHandler<UserEvent> for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.run.is_some() {
            return;
        }
        crate::win_shell::set_app_user_model_id();
        let attrs = Window::default_attributes()
            .with_title(crate::window_extras::PRODUCT_NAME)
            .with_window_icon(crate::window_extras::window_icon(false))
            .with_decorations(self.opts.form != swiftly_ui::Idiom::Desktop)
            .with_inner_size(LogicalSize::new(
                f64::from(self.opts.size.0),
                f64::from(self.opts.size.1),
            ))
            .with_min_inner_size({
                let m = if self.opts.form == swiftly_ui::Idiom::Desktop {
                    crate::window_rules::MIN_SIZE
                } else {
                    crate::window_rules::MIN_SIZE_SMALL
                };
                LogicalSize::new(m.0, m.1)
            })
            // Linux: the rounded corners are cut by the renderer, so the window must be allowed to be transparent.
            .with_transparent(
                cfg!(target_os = "linux") && self.opts.form == swiftly_ui::Idiom::Desktop,
            )
            // The screen-reader adapter must exist before the window is shown.
            .with_visible(false);
        // The shell matches the window to its launcher by this id: the taskbar then shows the app's icon and its name
        // (without it Wayland sent no `app_id` and the taskbar showed a generic icon and the binary's name).
        #[cfg(target_os = "linux")]
        let attrs = winit::platform::wayland::WindowAttributesExtWayland::with_name(
            attrs,
            crate::window_extras::APP_ID,
            "swiftly-player",
        );
        // `--offscreen`: far outside every monitor and never activated (winit shows it with SW_SHOWNOACTIVATE), so
        // it cannot take focus or cover anything of the user's.
        #[cfg(target_os = "windows")]
        let attrs = {
            use winit::platform::windows::WindowAttributesExtWindows;
            attrs.with_taskbar_icon(crate::window_extras::window_icon(true))
        };
        let attrs = if self.opts.offscreen {
            attrs
                .with_active(false)
                .with_position(winit::dpi::PhysicalPosition::new(-12000, -12000))
        } else {
            attrs
        };
        let window = match event_loop.create_window(attrs) {
            Ok(w) => Arc::new(w),
            Err(e) => {
                self.failure = Some(format!("window: {e}"));
                event_loop.exit();
                return;
            }
        };
        // Wayland: winit has no window icon there, so a run without an installed desktop file (the unpacked tar.gz) set
        // none; the compositor takes it through xdg-toplevel-icon-v1 where it offers that.
        #[cfg(all(
            unix,
            not(any(target_os = "macos", target_os = "ios", target_os = "android"))
        ))]
        {
            self.toplevel_icon =
                crate::toplevel_icon::apply(&window, &crate::window_extras::toplevel_pictures());
            if std::env::var_os("SWIFTLY_TRACE").is_some() {
                eprintln!(
                    "swiftly-desktop: toplevel icon set: {}",
                    self.toplevel_icon.is_some()
                );
            }
        }
        // The first rectangle never leaves the work area (a 1440x900 default on a 1280x800 screen) and is centred.
        #[cfg(target_os = "windows")]
        if !self.opts.offscreen {
            crate::win_shell::place_in_work_area(
                &window,
                if self.opts.form == swiftly_ui::Idiom::Desktop {
                    crate::window_rules::MIN_SIZE
                } else {
                    crate::window_rules::MIN_SIZE_SMALL
                },
            );
            crate::win_shell::set_taskbar_identity(&window);
        }
        #[cfg(target_os = "windows")]
        if self.opts.form == swiftly_ui::Idiom::Desktop {
            // winit always keeps WS_CAPTION (needed for Aero Snap and the shadow); the look is frameless because
            // WM_NCCALCSIZE gives the whole window to the client area. The thick frame and the drop shadow stay.
            use winit::platform::windows::{CornerPreference, WindowExtWindows};
            window.set_undecorated_shadow(true);
            // A frameless popup-style window is not rounded by Windows 11 on its own (the Mac window is): ask for it.
            window.set_corner_preference(CornerPreference::Round);
        }
        // A strip that opens while the window is dragged larger shows the theme's ground, never white.
        #[cfg(target_os = "windows")]
        crate::win_backdrop::set(&window, 0x10_10_10);
        let adapter = accesskit_winit::Adapter::with_event_loop_proxy(
            event_loop,
            &window,
            self.proxy.clone(),
        );
        window.set_visible(true);
        // The input method stays closed until a text field has the keyboard (`crate::ime::ImeSync` opens it after the
        // frame); `WindowEvent::Ime` is routed to `Shell::ime`.
        window.set_ime_allowed(false);
        if !self.opts.offscreen {
            window.focus_window();
        }
        window.set_theme(Some(crate::window_rules::THEME));
        {
            let proxy = self.proxy.clone();
            self.extras.started(&window, move |e| {
                proxy.send_event(UserEvent::Extra(e)).is_ok()
            });
        }
        let gpu = match Gpu::new(
            event_loop,
            Arc::clone(&window),
            self.opts.dump_frame.is_some() || self.opts.script.is_some(),
        ) {
            Ok(g) => g,
            Err(e) => {
                self.failure = Some(format!("gpu: {e}"));
                event_loop.exit();
                return;
            }
        };
        let size = window.inner_size();
        let scale = window.scale_factor() as f32;
        let period_ms = window
            .current_monitor()
            .and_then(|m| m.refresh_rate_millihertz())
            .map_or(1000.0 / 60.0, |mhz| 1_000_000.0 / f64::from(mhz));
        if self.opts.stats || self.verbose_events {
            let info = gpu.ctx.adapter_info();
            eprintln!(
                "swiftly-desktop: {} ({:?}, {:?}), {}x{} px at {scale}x, surface format {:?}, {:?}, latency {}, refresh period {period_ms:.2} ms",
                info.name,
                info.backend,
                info.device_type,
                size.width,
                size.height,
                gpu.config.format,
                gpu.config.present_mode,
                gpu.config.desired_maximum_frame_latency
            );
        }
        if self.opts.stats {
            self.stats = Some(FrameStats::new(period_ms, self.now()));
        }
        let mut shell = match self.opts.home {
            _ if self.opts.live => match crate::live::Core::open() {
                Ok(core) => Shell::new_live(
                    (size.width, size.height),
                    scale,
                    crate::frame_surface::app_cx(),
                    self.opts.form,
                    std::sync::Arc::new(core),
                ),
                Err(e) => {
                    self.failure = Some(e);
                    event_loop.exit();
                    return;
                }
            },
            _ if self.opts.app => Shell::new_suite_state(
                (size.width, size.height),
                scale,
                crate::frame_surface::app_cx(),
                self.opts.form,
                self.opts
                    .app_state
                    .unwrap_or(crate::home_data::Scenario::Ready),
            ),
            Some(scenario) => Shell::new_home(
                (size.width, size.height),
                scale,
                crate::frame_surface::app_cx(),
                scenario,
            ),
            None => Shell::new(
                (size.width, size.height),
                scale,
                crate::frame_surface::app_cx(),
            ),
        };
        if self.opts.autoplay {
            shell.enable_autoplay();
        }
        let now = self.now();
        self.extras.deliver_start(&mut shell, now);
        window.request_redraw();
        // A picture that finishes while the app is idle asks for a frame (the idle poll only looks four times a second,
        // and not at all while the last picture shows nothing new).
        {
            let proxy = self.proxy.clone();
            swiftly_images::loader::set_arrival_waker(std::sync::Arc::new(move || {
                let _ = proxy.send_event(UserEvent::Media);
            }));
        }
        {
            let proxy = self.proxy.clone();
            crate::live_play::set_video_waker(std::sync::Arc::new(move || {
                let _ = proxy.send_event(UserEvent::Video);
            }));
        }
        let media = (self.opts.live && !self.opts.offscreen)
            .then(|| {
                let proxy = self.proxy.clone();
                crate::os_media::OsMedia::open(hwnd_of(&window), move || {
                    let _ = proxy.send_event(UserEvent::Media);
                })
            })
            .flatten()
            .map(crate::media_keys::MediaSync::new);
        self.run = Some(Running {
            window,
            gpu,
            shell,
            continuous: false,
            idle_poll: false,
            last_fp: None,
            size_px: (size.width, size.height),
            scale,
            adapter,
            a11y_active: false,
            a11y_centres: std::collections::HashMap::new(),
            a11y_at: 0.0,
            ime: crate::ime::ImeSync::default(),
            cursor_hidden: false,
            media,
            opening: crate::browser_open::Waiting::default(),
            video_wake: false,
            other: false,
            held: None,
        });
    }

    fn user_event(&mut self, _event_loop: &ActiveEventLoop, event: UserEvent) {
        let now = self.now();
        if let UserEvent::Video = event {
            crate::stats::VIDEO_WAKES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            if let Some(run) = self.run.as_mut() {
                run.video_wake = true;
                run.window.request_redraw();
            }
            return;
        }
        if let Some(run) = self.run.as_mut() {
            run.other = true;
        }
        let ev = match event {
            UserEvent::Access(ev) => ev,
            UserEvent::Media | UserEvent::Video => {
                if let Some(run) = self.run.as_ref() {
                    run.window.request_redraw();
                }
                return;
            }
            UserEvent::Extra(ev) => {
                if let Some(run) = self.run.as_mut()
                    && self.extras.handle(ev, &run.window, &mut run.shell, now)
                {
                    run.window.request_redraw();
                }
                return;
            }
        };
        let Some(run) = self.run.as_mut() else { return };
        match ev.window_event {
            accesskit_winit::WindowEvent::InitialTreeRequested => {
                run.a11y_active = true;
                run.publish_tree();
            }
            accesskit_winit::WindowEvent::AccessibilityDeactivated => run.a11y_active = false,
            accesskit_winit::WindowEvent::ActionRequested(req) => {
                if let crate::a11y_bridge::Wanted::Click(id) = crate::a11y_bridge::wanted(&req)
                    && let Some(&at) = run.a11y_centres.get(&id)
                {
                    run.shell.tap_at(at, now);
                    run.window.request_redraw();
                }
            }
        }
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        self.extras.arrived(&event);
        if !matches!(event, WindowEvent::RedrawRequested)
            && let Some(run) = self.run.as_mut()
        {
            run.other = true;
        }
        let now = self.now();
        if self.verbose_events
            && matches!(
                event,
                WindowEvent::MouseWheel { .. }
                    | WindowEvent::MouseInput { .. }
                    | WindowEvent::CursorMoved { .. }
                    | WindowEvent::Focused(_)
                    | WindowEvent::CursorEntered { .. }
                    | WindowEvent::CursorLeft { .. }
            )
        {
            eprintln!("swiftly-desktop: {now:.0} ms {event:?}");
        }
        if let Some(run) = self.run.as_mut() {
            run.adapter.process_event(&run.window, &event);
        }
        match event {
            WindowEvent::DroppedFile(path) => self.extras.dropped(&path),
            #[cfg(target_os = "linux")]
            WindowEvent::ActivationTokenDone { serial, token } => {
                if let Some(url) = self.run.as_mut().and_then(|run| run.opening.done(&serial)) {
                    let _ = crate::signin_flows::open_url_with(&url, Some(&token.into_raw()));
                }
            }
            // Dark only by design (no light variant in the design): the title bar stays dark whatever the system says.
            WindowEvent::ThemeChanged(_) => {
                if let Some(run) = &self.run {
                    run.window.set_theme(Some(crate::window_rules::THEME));
                }
            }
            WindowEvent::CloseRequested => {
                // A running player reports its position and stop before the process ends; the report is a task on
                // the runtime, so give it a moment.
                if let Some(run) = self.run.as_mut()
                    && run.shell.window_closing(now)
                {
                    std::thread::sleep(std::time::Duration::from_millis(800));
                }
                event_loop.exit();
            }
            WindowEvent::RedrawRequested => {
                if self.verbose_events {
                    eprintln!("swiftly-desktop: RedrawRequested at {now:.0} ms");
                }
                self.redraw(event_loop);
            }
            WindowEvent::Resized(_) | WindowEvent::ScaleFactorChanged { .. } => {
                if matches!(event, WindowEvent::ScaleFactorChanged { .. }) {
                    self.retheme = true;
                }
                // The window the system resized for the new scale must stay inside the work area (Windows).
                #[cfg(target_os = "windows")]
                if let Some(run) = &self.run
                    && !self.opts.offscreen
                {
                    crate::win_shell::keep_in_work_area(
                        &run.window,
                        if self.opts.form == swiftly_ui::Idiom::Desktop {
                            crate::window_rules::MIN_SIZE
                        } else {
                            crate::window_rules::MIN_SIZE_SMALL
                        },
                    );
                }
                if self.retheme
                    && let Some(run) = &self.run
                {
                    // Dark only by design, also after the window moved to another scale (the title bar went light).
                    run.window.set_theme(Some(crate::window_rules::THEME));
                    self.retheme = matches!(event, WindowEvent::ScaleFactorChanged { .. });
                    crate::win_dark::ensure(&run.window);
                }
                if self.verbose_events {
                    eprintln!("swiftly-desktop: Resized event at {now:.1} ms");
                }
                if matches!(event, WindowEvent::Resized(_)) {
                    self.resize_latency.resized(now);
                }
                if self.verbose_events {
                    eprintln!(
                        "swiftly-desktop: Resized handler head {:.1} ms (event at {now:.1}, handler now {:.1})",
                        (self.now() - now).max(0.0),
                        self.now()
                    );
                }
                // Live resize, the same on every OS: the event only asks for a redraw, and `RedrawRequested` fits the surface
                // and the layout to the newest size and draws once. A drag queues one event per step; a frame per step refits
                // the swap chain every time (wgpu waits for the device and builds a new one: 0.6 ms on Linux, 18-80 ms on
                // Windows) and queues a frame behind each. Linux: winit holds `RedrawRequested` until the compositor's frame
                // callback of the last frame arrived, so one frame is in flight (a frame per configure made KWin queue
                // hundreds of frames, seconds behind the pointer). Windows: the resize queues a `WM_PAINT` that the system's
                // size loop delivers as `RedrawRequested`. Every event after a frame at the window's size is skipped.
                let current = self.run.as_ref().is_some_and(|run| {
                    let s = run.window.inner_size();
                    crate::window_rules::resize_is_stale(
                        (s.width, s.height),
                        run.size_px,
                        run.window.scale_factor() as f32,
                        run.scale,
                        matches!(event, WindowEvent::ScaleFactorChanged { .. }),
                    )
                });
                if self.run.is_some() && !current {
                    if crate::window_rules::resize_draws_in_event(
                        crate::resize_latency::inline_resize_frames(),
                    ) {
                        self.redraw(event_loop);
                    } else if let Some(run) = &self.run {
                        // The next `RedrawRequested` draws the newest size once (scale changes too); if it never comes,
                        // `about_to_wait` draws after `RESIZE_FALLBACK_MS`.
                        self.resize_fallback.asked(now);
                        run.window.request_redraw();
                    }
                }
            }
            WindowEvent::Occluded(hidden) => {
                if self.verbose_events {
                    eprintln!("swiftly-desktop: Occluded({hidden})");
                }
                if !hidden {
                    self.input_changed();
                }
            }
            WindowEvent::ModifiersChanged(m) => {
                self.mods = m.state();
                if let Some(run) = self.run.as_mut() {
                    run.shell.set_shift(self.mods.shift_key());
                }
            }
            WindowEvent::KeyboardInput { event, .. } => {
                let text = event.text.as_ref().map(|t| t.as_str());
                let pressed = event.state == ElementState::Pressed;
                self.key_input(
                    event_loop,
                    &event.logical_key,
                    text,
                    pressed,
                    event.repeat,
                    now,
                );
            }
            WindowEvent::CursorMoved { position, .. } => {
                self.pointer_moved(position.x, position.y, now);
            }
            WindowEvent::Focused(true) => {
                if let Some(run) = self.run.as_mut() {
                    crate::win_dark::ensure(&run.window);
                    run.shell.window_activated();
                }
            }
            WindowEvent::Focused(false) => {
                // Focus lost with a button down (alt-tab, a dialog): its release goes elsewhere.
                if let Some(run) = self.run.as_mut() {
                    run.shell.release_stale(now);
                }
            }
            WindowEvent::CursorLeft { .. } => {
                if let Some(run) = self.run.as_mut() {
                    run.shell.cursor_left(now);
                }
                self.input_changed();
            }
            WindowEvent::MouseInput { state, button, .. } => match button {
                MouseButton::Left => {
                    self.primary_pressed(event_loop, state == ElementState::Pressed, now)
                }
                MouseButton::Right if state == ElementState::Pressed => {
                    if let Some(run) = self.run.as_mut() {
                        run.shell.secondary_button(now);
                    }
                    self.input_changed();
                }
                MouseButton::Back if state == ElementState::Pressed => {
                    self.command(event_loop, Command::Back);
                }
                MouseButton::Forward if state == ElementState::Pressed => {
                    self.command(event_loop, Command::Forward);
                }
                _ => {}
            },
            WindowEvent::MouseWheel { delta, phase, .. } => {
                let Some(run) = self.run.as_mut() else { return };
                if self.verbose_events {
                    eprintln!(
                        "swiftly-desktop: MouseWheel {delta:?} {phase:?} blocked_by_press={}",
                        run.shell.wheel_blocked()
                    );
                }
                let d = match delta {
                    MouseScrollDelta::LineDelta(x, y) => WheelDelta::Lines(x, y),
                    MouseScrollDelta::PixelDelta(p) => {
                        let s = f64::from(run.scale);
                        WheelDelta::Points((p.x / s) as f32, (p.y / s) as f32)
                    }
                };
                let phase = match phase {
                    TouchPhase::Started => WheelPhase::Started,
                    TouchPhase::Moved => WheelPhase::Moved,
                    TouchPhase::Ended => WheelPhase::Ended,
                    TouchPhase::Cancelled => WheelPhase::Cancelled,
                };
                run.shell.wheel(d, Some(phase), now);
                self.input_changed();
            }
            WindowEvent::Touch(t) => {
                if let Some(run) = self.run.as_mut() {
                    let code = match t.phase {
                        TouchPhase::Started => 0,
                        TouchPhase::Moved => 1,
                        TouchPhase::Ended => 2,
                        TouchPhase::Cancelled => 3,
                    };
                    run.shell
                        .finger_id(t.id, code, (t.location.x, t.location.y), now);
                }
                self.input_changed();
            }
            WindowEvent::Ime(ime) => {
                let ev = match ime {
                    WinitIme::Preedit(text, cursor) => Ime::Preedit(text, cursor),
                    WinitIme::Commit(text) => Ime::Commit(text),
                    WinitIme::Enabled | WinitIme::Disabled => Ime::Cancel,
                };
                if let Some(run) = self.run.as_mut()
                    && run.shell.ime(&ev)
                {
                    self.input_changed();
                }
            }
            _ => {}
        }
    }

    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        let now = self.now();
        self.note_quit(event_loop);
        let mut wake: Option<f64> = None;
        if let Some(s) = self.stats.as_mut() {
            if let Some(line) = s.report(now) {
                eprintln!("{line}");
            }
            wake = Some(s.next_report_ms());
        }
        // A script that only waits lets the app idle until the pause ends, as the real app does between inputs.
        if let Some(script) = self.script.as_ref().filter(|s| s.pending())
            && let Some(r) = self.run.as_ref()
        {
            match script
                .sleeping_until()
                .filter(|&t| t > now && self.shot.is_none())
            {
                Some(t) => wake = Some(wake.map_or(t, |w| w.min(t))),
                None => r.window.request_redraw(),
            }
        }
        // A resize asked for a redraw that never came (a frame callback the compositor did not answer, a swallowed `WM_PAINT`):
        // draw the newest size once by hand.
        if self.resize_fallback.take_due(now) && self.run.is_some() {
            if self.verbose_events || self.stats.is_some() {
                eprintln!(
                    "swiftly-desktop: resize redraw lost, drawing after {} ms",
                    crate::window_rules::RESIZE_FALLBACK_MS
                );
            }
            self.redraw(event_loop);
        }
        if let Some(at) = self.resize_fallback.wake_at() {
            wake = Some(wake.map_or(at, |w| w.min(at)));
        }
        // The synthetic drag (`SWIFTLY_RESIZE_BENCH`): one step of the window size per interval, then the summary.
        if let Some(bench) = self.resize_bench.as_mut()
            && let Some(r) = self.run.as_ref()
        {
            let s = r.window.inner_size();
            if let Some((w, h)) = bench.due(now, (s.width, s.height)) {
                // Wayland sends no `Resized` event for a size the window asked for itself: the step is the start.
                self.resize_latency.resized(now);
                let _ = r
                    .window
                    .request_inner_size(winit::dpi::PhysicalSize::new(w, h));
                if bench.finished() {
                    self.bench_done_at = Some(now);
                }
            }
            if let Some(at) = bench.next_at() {
                wake = Some(wake.map_or(at, |w| w.min(at)));
            }
        }
        if let Some(done) = self.bench_done_at {
            let report_at =
                done + crate::resize_latency::ResizeBench::settle().as_secs_f64() * 1000.0;
            if now >= report_at {
                self.bench_done_at = None;
                if let Some(line) = self.resize_latency.summary() {
                    eprintln!("swiftly-desktop: {line}");
                }
            } else {
                wake = Some(wake.map_or(report_at, |w| w.min(report_at)));
            }
        }
        if let Some(limit) = self.opts.quit_after {
            let at = limit * 1000.0;
            if now >= at {
                event_loop.exit();
                return;
            }
            wake = Some(wake.map_or(at, |w| w.min(at)));
        }
        // The real app answers network results: when idle it looks again four times a second, not every vsync.
        if let Some(at) = self.retry_at {
            if now >= at {
                self.retry_at = None;
                if let Some(r) = self.run.as_ref() {
                    r.window.request_redraw();
                }
            } else {
                wake = Some(wake.map_or(at, |w| w.min(at)));
            }
        }
        if self
            .run
            .as_ref()
            .is_some_and(|r| !r.continuous && r.shell.live_idle(now))
        {
            thread_local! { static LAST_POLL: std::cell::Cell<f64> = const { std::cell::Cell::new(0.0) }; }
            if now - LAST_POLL.with(std::cell::Cell::get) >= 250.0 {
                LAST_POLL.with(|c| c.set(now));
                if let Some(r) = self.run.as_mut() {
                    r.idle_poll = true;
                    r.window.request_redraw();
                }
            }
            let next = LAST_POLL.with(std::cell::Cell::get) + 250.0;
            wake = Some(wake.map_or(next, |w| w.min(next)));
        }
        event_loop.set_control_flow(match wake {
            // The deadlines are app-clock times: mapped without the shots' pause they lay in the past once the pause
            // passed 250 ms, and the loop woke at once forever (a busy loop of 35 % of a core while a film played).
            Some(ms) => ControlFlow::WaitUntil(self.instant_of(ms)),
            None => ControlFlow::Wait,
        });
    }
}

/// A cheap fingerprint of a picture: equal pictures hash equal.
fn fingerprint(list: &DrawList) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    format!("{list:?}").hash(&mut h);
    h.finish()
}

impl App {
    /// The pointer is at `(x, y)` physical pixels (a window event or a script step).
    fn pointer_moved(&mut self, x: f64, y: f64, now: f64) {
        let over_player = self.run.as_mut().is_some_and(|run| {
            run.shell.cursor_moved((x, y), now);
            let size = run.window.inner_size();
            let frameless = self.opts.form == swiftly_ui::Idiom::Desktop
                && run.window.fullscreen().is_none()
                && !run.window.is_maximized();
            self.cursor_px = (x, y);
            self.edge = if frameless {
                resize_edge(x, y, size.width, size.height, 6.0 * f64::from(run.scale))
            } else {
                None
            };
            let icon = match self.edge {
                Some(d) => resize_icon(d),
                None => crate::window_extras::cursor_icon(run.shell.cursor_kind()),
            };
            run.window.set_cursor(icon);
            run.shell.player_open()
        });
        // A drag of the player's bare background moves the window (the press is handed to the window manager).
        if let Some(run) = self.run.as_mut()
            && run.shell.peek_window_action() == Some(crate::desk::WinAction::MoveWindow)
        {
            run.shell.take_window_action();
            // A fullscreen window stays where it is; only a normal or maximised one is moved.
            if run.window.fullscreen().is_none() {
                if crate::window_rules::system_drag_allowed(self.synthetic) {
                    let _ = run.window.drag_window();
                }
                // The compositor runs the move and eats the button release.
                run.shell.release_stale(now);
            }
        }
        if over_player {
            self.input_changed();
        } else {
            self.input_changed_if_pressed();
        }
    }

    /// One key of the keyboard: the window's `KeyboardInput` and the script's `key` step both come through here, so a
    /// script cannot reach a key path the real keyboard does not.
    fn key_input(
        &mut self,
        event_loop: &ActiveEventLoop,
        key: &Key,
        text: Option<&str>,
        pressed: bool,
        repeat: bool,
        now: f64,
    ) {
        // A focused text field takes typed text, Backspace, Return and Esc before any shortcut.
        if pressed
            && (!(self.mods.control_key() || self.mods.super_key() || self.mods.alt_key())
                || edit_event(key, self.mods).is_some())
            && self.run.as_ref().is_some_and(|r| r.shell.wants_text())
        {
            if let Some(ev) = edit_event(key, self.mods)
                && let Some(run) = self.run.as_mut()
                && run.shell.text_event(&ev)
            {
                self.input_changed();
                return;
            }
            let text = match key {
                Key::Named(NamedKey::Backspace) => Some("\u{8}".to_owned()),
                Key::Named(NamedKey::Enter) => Some("\n".to_owned()),
                Key::Named(NamedKey::Escape) => Some("\u{1b}".to_owned()),
                Key::Named(NamedKey::Space) => Some(" ".to_owned()),
                _ => text.map(str::to_owned),
            };
            if let (Some(t), Some(run)) = (text, self.run.as_mut())
                && run.shell.text_key(&t)
            {
                self.input_changed();
                return;
            }
        }
        // Window rules: F11 and Alt+Enter fullscreen, Esc out of fullscreen, Ctrl shortcuts of the Mac app,
        // the player's own keys (Space, arrows, M, F, G/H/J/K) and the media keys.
        if pressed && let Some(run) = self.run.as_mut() {
            let ctx = crate::window_rules::Ctx {
                fullscreen: run.window.fullscreen().is_some(),
                player_open: run.shell.player_open(),
                text_focus: run.shell.wants_text(),
            };
            if let Some(action) = crate::window_rules::resolve(key, self.mods, repeat, ctx)
                && crate::window_rules::apply(action, &run.window, &mut run.shell, now)
            {
                crate::script::trace(&format!("key {key:?} used as {action:?}"));
                self.input_changed();
                return;
            }
        }
        // Arrows, Tab and Enter go to the shared focus engine (arrows repeat, Enter does not).
        let plain = !(self.mods.alt_key() || self.mods.super_key() || self.mods.control_key());
        let nav = match key {
            Key::Named(NamedKey::ArrowUp) => Some(NavKey::Arrow(Dir::Up)),
            Key::Named(NamedKey::ArrowDown) => Some(NavKey::Arrow(Dir::Down)),
            Key::Named(NamedKey::ArrowLeft) => Some(NavKey::Arrow(Dir::Left)),
            Key::Named(NamedKey::ArrowRight) => Some(NavKey::Arrow(Dir::Right)),
            Key::Named(NamedKey::Tab) if self.mods.shift_key() => Some(NavKey::ShiftTab),
            Key::Named(NamedKey::Tab) => Some(NavKey::Tab),
            Key::Named(NamedKey::Enter | NamedKey::Space) => Some(NavKey::Enter),
            _ => None,
        };
        if let (Some(k), true) = (nav, plain) {
            let repeats = matches!(k, NavKey::Enter);
            if !(repeat && repeats) {
                let down = pressed;
                if let Some(run) = self.run.as_mut()
                    && run.shell.nav_key(k, down, now)
                {
                    self.input_changed();
                }
            }
            return;
        }
        if !pressed || repeat {
            return;
        }
        let ctrl_or_cmd = self.mods.control_key() || self.mods.super_key();
        let cmd = match key {
            Key::Named(NamedKey::Escape | NamedKey::Backspace | NamedKey::BrowserBack) => {
                Some(Command::Back)
            }
            Key::Named(NamedKey::Delete) if !ctrl_or_cmd && !self.mods.alt_key() => {
                Some(Command::Delete)
            }
            Key::Named(NamedKey::ArrowLeft) if self.mods.alt_key() => Some(Command::Back),
            Key::Named(NamedKey::ArrowRight | NamedKey::BrowserForward)
                if self.mods.alt_key() || !ctrl_or_cmd =>
            {
                Some(Command::Forward)
            }
            Key::Named(
                n @ (NamedKey::Home | NamedKey::End | NamedKey::PageUp | NamedKey::PageDown),
            ) if !ctrl_or_cmd && !self.mods.alt_key() => {
                use swiftly_ui::shortcuts::ScrollKey as S;
                Some(Command::Scroll(match n {
                    NamedKey::Home => S::Home,
                    NamedKey::End => S::End,
                    NamedKey::PageUp => S::PageUp,
                    _ => S::PageDown,
                }))
            }
            Key::Character(c) if c.as_str() == "[" && self.mods.super_key() => Some(Command::Back),
            Key::Character(c) if ctrl_or_cmd && matches!(c.as_str(), "q" | "w") => {
                Some(Command::Quit)
            }
            _ => None,
        };
        if let Some(cmd) = cmd {
            self.command(event_loop, cmd);
        }
    }

    /// The primary button went down or up (a window event or a script step).
    fn primary_pressed(&mut self, event_loop: &ActiveEventLoop, pressed: bool, now: f64) {
        crate::script::trace(&format!(
            "primary {pressed} at {:?} edge {:?}",
            self.cursor_px, self.edge
        ));
        // The window edge starts the system's resize, except for a script's press: it has no real button to follow.
        if pressed
            && crate::window_rules::system_drag_allowed(self.synthetic)
            && let (Some(d), Some(run)) = (self.edge, self.run.as_ref())
        {
            let _ = run.window.drag_resize_window(d);
            return;
        }
        if let Some(run) = self.run.as_mut() {
            run.shell.primary_button(pressed, now);
        }
        self.window_actions(event_loop);
        self.input_changed();
    }

    /// The loop was asked to stop (`exit`): once, tell the system's move/size loop to end if one runs (a press on the window
    /// edge or the title bar: that loop sits inside the window's message handling and never returns to this loop until the
    /// button is released, so `exit` alone would wait for it) and start the clock after which the process is ended with
    /// code 0 whatever else keeps the loop from returning.
    fn note_quit(&mut self, event_loop: &ActiveEventLoop) {
        if !event_loop.exiting() || self.quit_noted {
            return;
        }
        self.quit_noted = true;
        crate::script::trace("quit asked");
        if let Some(run) = self.run.as_ref() {
            crate::win_shell::cancel_modal_loop(&run.window);
        }
        crate::quit_guard::quit_asked();
    }

    /// Runs the script steps that are due (`--script`). Every step goes through the window's own input path.
    fn run_script(&mut self, event_loop: &ActiveEventLoop, now: f64) {
        use crate::script::Step;
        // A shot asked for is still to be drawn: the script waits for that frame.
        if self.shot.is_some() {
            return;
        }
        let open = self.run.as_ref().is_some_and(|r| r.shell.player_open());
        let Some(script) = self.script.as_mut() else {
            return;
        };
        let nodes = self.run.as_ref().map(|r| r.shell.a11y_nodes().1);
        let has = |text: &str| {
            nodes
                .as_ref()
                .is_some_and(|n| find_label(n, text).is_some())
        };
        let due = script.due_with(now, open, &has);
        self.synthetic = true;
        let ran = !due.is_empty();
        for step in due {
            match step {
                Step::Key(name) => {
                    // The real keyboard path, press and release, exactly as a key event of the window arrives.
                    let key = match name.to_ascii_lowercase().as_str() {
                        "space" => Key::Named(NamedKey::Space),
                        "left" => Key::Named(NamedKey::ArrowLeft),
                        "right" => Key::Named(NamedKey::ArrowRight),
                        "up" => Key::Named(NamedKey::ArrowUp),
                        "down" => Key::Named(NamedKey::ArrowDown),
                        "enter" => Key::Named(NamedKey::Enter),
                        "escape" => Key::Named(NamedKey::Escape),
                        "tab" => Key::Named(NamedKey::Tab),
                        _ => continue,
                    };
                    crate::script::trace(&format!("script key {name}"));
                    self.key_input(event_loop, &key, None, true, false, now);
                    self.key_input(event_loop, &key, None, false, false, now + 30.0);
                }
                Step::Move(fx, fy) => {
                    if let Some(size) = self.run.as_ref().map(|r| r.window.inner_size()) {
                        self.pointer_moved(
                            fx * f64::from(size.width),
                            fy * f64::from(size.height),
                            now,
                        );
                    }
                }
                Step::MoveLabel(text) => {
                    let at = self.run.as_ref().and_then(|r| {
                        let (_, nodes) = r.shell.a11y_nodes();
                        find_label(&nodes, &text).map(|b| {
                            let s = f64::from(r.scale);
                            (
                                f64::from(b[0] + b[2] / 2.0) * s,
                                f64::from(b[1] + b[3] / 2.0) * s,
                            )
                        })
                    });
                    match at {
                        Some((x, y)) => self.pointer_moved(x, y, now),
                        None => {
                            let mut names = Vec::new();
                            if let Some(r) = self.run.as_ref() {
                                collect_labels(&r.shell.a11y_nodes().1, &mut names);
                            }
                            eprintln!(
                                "swiftly-desktop: script: no control named {text:?}; known: {names:?}"
                            );
                        }
                    }
                }
                Step::Anchor(text) => {
                    self.script_anchor = self.run.as_ref().and_then(|r| {
                        let (_, nodes) = r.shell.a11y_nodes();
                        find_label(&nodes, &text)
                            .map(|b| (f64::from(b[0] + b[2] / 2.0), f64::from(b[1] + b[3] / 2.0)))
                    });
                    if self.script_anchor.is_none() {
                        eprintln!("swiftly-desktop: script: no control named {text:?} to anchor");
                    }
                }
                Step::MoveFrom(dx, dy) => {
                    if let (Some((ax, ay)), Some(scale)) = (
                        self.script_anchor,
                        self.run.as_ref().map(|r| f64::from(r.scale)),
                    ) {
                        self.pointer_moved((ax + dx) * scale, (ay + dy) * scale, now);
                    }
                }
                Step::Type(text) => {
                    if let Some(run) = self.run.as_mut()
                        && run.shell.ime(&Ime::Commit(text))
                    {
                        self.input_changed();
                    }
                }
                Step::Down => self.primary_pressed(event_loop, true, now),
                Step::RightClick => {
                    crate::script::trace("script right click");
                    if let Some(run) = self.run.as_mut() {
                        run.shell.secondary_button(now);
                    }
                    self.input_changed();
                }
                Step::Up => {
                    crate::script::trace("script click");
                    self.primary_pressed(event_loop, false, now);
                }
                Step::Wheel(dy) => {
                    if let Some(run) = self.run.as_mut() {
                        run.shell.wheel(WheelDelta::Lines(0.0, dy), None, now);
                    }
                    self.input_changed();
                }
                Step::Shift(on) => {
                    if let Some(run) = self.run.as_mut() {
                        run.shell.set_shift(on);
                    }
                }
                Step::Resize(w, h) => {
                    if let Some(run) = self.run.as_ref() {
                        let _ = run.window.request_inner_size(LogicalSize::new(w, h));
                    }
                }
                Step::Fullscreen => {
                    if let Some(run) = self.run.as_ref() {
                        crate::window_rules::set_fullscreen(
                            &run.window,
                            run.window.fullscreen().is_none(),
                        );
                    }
                }
                Step::FillImages => {
                    let n = self.run.as_ref().map_or(0, |r| r.shell.fill_image_page());
                    crate::script::trace(&format!("fill-images: {n} blocks"));
                }
                Step::Shot(path) => self.shot = Some(std::path::PathBuf::from(path)),
                Step::Mark(tag) => crate::script::trace(&format!("mark {tag}")),
                Step::Toast(text) => {
                    if let Some(s) = self.run.as_mut().and_then(|r| r.shell.suite_mut()) {
                        s.show_hint(&text, now);
                    }
                    self.input_changed();
                }
                Step::Labels(filter) => {
                    if let Some(r) = self.run.as_ref() {
                        let (title, nodes) = r.shell.a11y_nodes();
                        eprintln!("swiftly-desktop: labels: window {title:?}");
                        print_labels(&nodes, &filter);
                    }
                }
                Step::Quit => event_loop.exit(),
                Step::Wait(_) | Step::UntilPlayer(_) | Step::UntilLabel(..) => {}
            }
        }
        self.synthetic = false;
        // Only a step that ran changed something. Asking for another frame every time made a script run (a wait, an
        // `until` that polls) draw at the display's rate for good, whatever was on screen.
        if ran {
            self.input_changed();
        }
    }
}

/// The named nodes with role and frame, for the script's `labels` step.
fn print_labels(nodes: &[swiftly_ui::a11y::A11yNode], filter: &str) {
    for n in nodes {
        if !n.label.is_empty()
            && n.label.contains(filter)
            && let Some(b) = n.bounds
        {
            eprintln!(
                "swiftly-desktop: labels: {:?} {:?} x={:.1} y={:.1} w={:.1} h={:.1}",
                n.label, n.role, b[0], b[1], b[2], b[3]
            );
        }
        print_labels(&n.children, filter);
    }
}

/// Every named node, for the script's "no such control" message.
fn collect_labels(nodes: &[swiftly_ui::a11y::A11yNode], out: &mut Vec<String>) {
    for n in nodes {
        if !n.label.is_empty() {
            out.push(n.label.clone());
        }
        collect_labels(&n.children, out);
    }
}

/// The frame (window points) of the first node whose name contains `text`. A `text` that starts with `#` is a stable
/// test key instead: the node whose key is exactly the rest (`#btn-decline-confirm`), however its words read.
fn find_label(nodes: &[swiftly_ui::a11y::A11yNode], text: &str) -> Option<[f32; 4]> {
    if let Some(key) = text.strip_prefix('#') {
        fn by_key(nodes: &[swiftly_ui::a11y::A11yNode], key: &str) -> Option<[f32; 4]> {
            nodes.iter().find_map(|n| {
                if n.key == key {
                    n.bounds
                } else {
                    by_key(&n.children, key)
                }
            })
        }
        return by_key(nodes, key);
    }
    // An exact name wins ("Anfragen" is the button, not the link "Meine Anfragen" that also contains it); otherwise the
    // smallest match: a container may carry the words of its children, the control itself is what a script means.
    fn smallest(
        nodes: &[swiftly_ui::a11y::A11yNode],
        text: &str,
        exact: bool,
        best: &mut Option<[f32; 4]>,
    ) {
        for n in nodes {
            if (if exact {
                n.label == text
            } else {
                n.label.contains(text)
            }) && let Some(b) = n.bounds
                && best.is_none_or(|o| b[2] * b[3] < o[2] * o[3])
            {
                *best = Some(b);
            }
            smallest(&n.children, text, exact, best);
        }
    }
    let mut best = None;
    smallest(nodes, text, true, &mut best);
    if best.is_none() {
        smallest(nodes, text, false, &mut best);
    }
    best
}

impl App {
    fn input_changed_if_pressed(&mut self) {
        // A moving pointer without a button changes nothing on screen (no hover yet): no redraw.
        if self.run.as_ref().is_some_and(|r| r.shell.wants_frame()) {
            self.input_changed();
        }
    }
}

/// Maps a key (with modifiers) to a text-input event: caret keys, Delete, select all, clipboard, undo. Backspace, Return
/// and typed text go through `Shell::text_key`. On macOS Cmd is the shortcut key and Alt moves by word; elsewhere Ctrl.
fn edit_event(key: &Key, mods: ModifiersState) -> Option<swiftly_text::TextInputEvent> {
    use swiftly_text::{EditKey, Mods, TextInputEvent as E};
    let mac = cfg!(target_os = "macos");
    let shortcut = if mac {
        mods.super_key()
    } else {
        mods.control_key()
    };
    let m = Mods {
        shift: mods.shift_key(),
        word: if mac {
            mods.alt_key()
        } else {
            mods.control_key()
        },
        line: mac && mods.super_key(),
    };
    match key {
        Key::Character(c) if shortcut && !mods.alt_key() => match c.to_lowercase().as_str() {
            "a" => Some(E::SelectAll),
            "c" => Some(E::Copy),
            "x" => Some(E::Cut),
            "v" => Some(E::Paste),
            "z" if mods.shift_key() => Some(E::Redo),
            "z" => Some(E::Undo),
            "y" if !mac => Some(E::Redo),
            _ => None,
        },
        Key::Named(n) if !(shortcut && !mac && matches!(n, NamedKey::Backspace)) => {
            let k = match n {
                NamedKey::ArrowLeft => EditKey::Left,
                NamedKey::ArrowRight => EditKey::Right,
                NamedKey::Home => EditKey::Home,
                NamedKey::End => EditKey::End,
                NamedKey::Delete => EditKey::Delete,
                _ => return None,
            };
            Some(E::Key(k, m))
        }
        _ => None,
    }
}

/// Opens the window and runs until it closes.
pub fn run(opts: Options) -> Result<(), String> {
    // A second launch hands its arguments to the running instance and ends here, before any window exists.
    let Some(extras) = crate::window_extras::Extras::new(&opts) else {
        return Ok(());
    };
    let script = match &opts.script {
        Some(p) => {
            let text =
                std::fs::read_to_string(p).map_err(|e| format!("script {}: {e}", p.display()))?;
            Some(crate::script::Script::new(crate::script::parse(&text)?))
        }
        None => None,
    };
    let event_loop = EventLoop::<UserEvent>::with_user_event()
        .build()
        .map_err(|e| format!("event loop: {e}"))?;
    event_loop.set_control_flow(ControlFlow::Wait);
    let mut app = App {
        proxy: event_loop.create_proxy(),
        extras,
        edge: None,
        last_drag_press: None,
        synthetic: false,
        quit_noted: false,
        cursor_px: (0.0, 0.0),
        opts,
        start: Instant::now(),
        shot_pause: Duration::ZERO,
        run: None,
        stats: None,
        mods: ModifiersState::empty(),
        failure: None,
        verbose_events: std::env::var_os("SWIFTLY_DESKTOP_TRACE").is_some(),
        frames_drawn: 0,
        dumped: false,
        touch_next: 0,
        script,
        script_anchor: None,
        shot: None,
        retry_at: None,
        retries: 0,
        retheme: false,
        resize_latency: crate::resize_latency::ResizeLatency::default(),
        resize_fallback: crate::window_rules::ResizeFallback::default(),
        resize_bench: crate::resize_latency::ResizeBench::from_env(),
        bench_done_at: None,
        #[cfg(all(
            unix,
            not(any(target_os = "macos", target_os = "ios", target_os = "android"))
        ))]
        toplevel_icon: None,
    };
    event_loop
        .run_app(&mut app)
        .map_err(|e| format!("run: {e}"))?;
    if let Some(s) = &app.stats {
        eprintln!("{}", s.totals());
    }
    if let Some(r) = app.extras.report() {
        eprintln!("{r}");
    }
    match app.failure.take() {
        Some(f) => Err(f),
        None => Ok(()),
    }
}

/// Which edge or corner of a `w` x `h` window `(x, y)` is on, within `grab` pixels.
fn resize_edge(
    x: f64,
    y: f64,
    w: u32,
    h: u32,
    grab: f64,
) -> Option<winit::window::ResizeDirection> {
    use winit::window::ResizeDirection as D;
    let (w, h) = (f64::from(w), f64::from(h));
    let (l, r, t, b) = (x < grab, x >= w - grab, y < grab, y >= h - grab);
    match (l, r, t, b) {
        (true, _, true, _) => Some(D::NorthWest),
        (_, true, true, _) => Some(D::NorthEast),
        (true, _, _, true) => Some(D::SouthWest),
        (_, true, _, true) => Some(D::SouthEast),
        (true, ..) => Some(D::West),
        (_, true, ..) => Some(D::East),
        (_, _, true, _) => Some(D::North),
        (.., true) => Some(D::South),
        _ => None,
    }
}

/// The cursor of a resize edge.
fn resize_icon(d: winit::window::ResizeDirection) -> winit::window::CursorIcon {
    use winit::window::CursorIcon as I;
    use winit::window::ResizeDirection as D;
    match d {
        D::North | D::South => I::NsResize,
        D::East | D::West => I::EwResize,
        D::NorthWest | D::SouthEast => I::NwseResize,
        D::NorthEast | D::SouthWest => I::NeswResize,
    }
}

/// The wall-clock instant of app-clock time `ms`, for a clock that started at `start` and has left out `paused`.
fn wall_deadline(start: Instant, paused: Duration, ms: f64) -> Instant {
    start + paused + Duration::from_secs_f64((ms / 1000.0).max(0.0))
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_deadline_of_the_app_clock_stays_ahead_after_shots_paused_it() {
        use super::wall_deadline;
        use std::time::{Duration, Instant};
        let start = Instant::now() - Duration::from_secs(20);
        let paused = Duration::from_millis(900);
        // The app clock reads 20 s - 0.9 s; the next poll is due 250 ms later on that clock.
        let now_app = (start.elapsed() - paused).as_secs_f64() * 1000.0;
        let due = wall_deadline(start, paused, now_app + 250.0);
        assert!(
            due > Instant::now(),
            "a future app-clock deadline must not lie in the past"
        );
        assert!(due <= Instant::now() + Duration::from_millis(260));
        // Without a pause both clocks are one.
        assert_eq!(
            wall_deadline(start, Duration::ZERO, 1500.0),
            start + Duration::from_millis(1500)
        );
    }

    #[cfg(not(target_os = "macos"))]
    use super::edit_event;
    use super::{find_label, resize_edge, resize_icon};
    #[cfg(not(target_os = "macos"))]
    use winit::keyboard::{Key, ModifiersState, NamedKey};
    use winit::window::{CursorIcon, ResizeDirection as D};

    /// A script's `move-label Anfragen` means the button of that exact name, not the smaller link "Meine Anfragen" whose
    /// name contains it; a partial name still finds the smallest control that holds it.
    #[test]
    fn a_label_search_prefers_the_exact_name() {
        use swiftly_ui::a11y::{A11yNode, Role};
        let node = |label: &str, w: f32, h: f32| {
            let mut n = A11yNode::new(label, Role::Button, label);
            n.bounds = Some([0.0, 0.0, w, h]);
            n
        };
        let nodes = vec![
            node("Anfragen", 320.0, 48.0),
            node("Meine Anfragen", 130.0, 38.0),
        ];
        assert_eq!(
            find_label(&nodes, "Anfragen"),
            Some([0.0, 0.0, 320.0, 48.0])
        );
        assert_eq!(find_label(&nodes, "Meine"), Some([0.0, 0.0, 130.0, 38.0]));
        assert_eq!(find_label(&nodes, "Fehlt"), None);
    }

    /// The input layer (Windows/Linux, Ctrl as the shortcut key): Ctrl+A is select all, in either letter case, and Tab
    /// is not a text edit (it moves the keyboard to the next field), so the window handler never types it.
    #[cfg(not(target_os = "macos"))]
    #[test]
    fn ctrl_a_selects_all_and_tab_is_no_text_edit() {
        use swiftly_text::TextInputEvent as E;
        assert!(matches!(
            edit_event(&Key::Character("a".into()), ModifiersState::CONTROL),
            Some(E::SelectAll)
        ));
        assert!(matches!(
            edit_event(
                &Key::Character("A".into()),
                ModifiersState::CONTROL | ModifiersState::SHIFT
            ),
            Some(E::SelectAll)
        ));
        assert!(
            edit_event(&Key::Character("a".into()), ModifiersState::empty()).is_none(),
            "plain a is typed text"
        );
        assert!(edit_event(&Key::Named(NamedKey::Tab), ModifiersState::empty()).is_none());
        assert!(edit_event(&Key::Named(NamedKey::Tab), ModifiersState::SHIFT).is_none());
    }

    #[test]
    fn edges_and_corners_resize_the_inside_does_not() {
        let (w, h, g) = (1440, 900, 6.0);
        assert_eq!(resize_edge(0.0, 450.0, w, h, g), Some(D::West));
        assert_eq!(resize_edge(1439.0, 450.0, w, h, g), Some(D::East));
        assert_eq!(resize_edge(700.0, 2.0, w, h, g), Some(D::North));
        assert_eq!(resize_edge(700.0, 898.0, w, h, g), Some(D::South));
        assert_eq!(resize_edge(1.0, 1.0, w, h, g), Some(D::NorthWest));
        assert_eq!(resize_edge(1438.0, 1.0, w, h, g), Some(D::NorthEast));
        assert_eq!(resize_edge(1.0, 899.0, w, h, g), Some(D::SouthWest));
        assert_eq!(resize_edge(1438.0, 899.0, w, h, g), Some(D::SouthEast));
        assert_eq!(resize_edge(700.0, 450.0, w, h, g), None);
        assert_eq!(
            resize_edge(7.0, 450.0, w, h, g),
            None,
            "just inside the grab zone"
        );
        assert_eq!(resize_icon(D::NorthWest), CursorIcon::NwseResize);
        assert_eq!(resize_icon(D::East), CursorIcon::EwResize);
    }
}
