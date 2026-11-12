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
}

impl Gpu {
    fn new(
        event_loop: &ActiveEventLoop,
        window: Arc<Window>,
        opts_dump: bool,
    ) -> Result<Gpu, String> {
        let mut desc = wgpu::InstanceDescriptor::new_with_display_handle(Box::new(
            event_loop.owned_display_handle(),
        ));
        desc.backends = wgpu::Backends::VULKAN
            | wgpu::Backends::DX12
            | wgpu::Backends::METAL
            | wgpu::Backends::GL;
        let instance = wgpu::Instance::new(desc);
        let surface = instance
            .create_surface(Arc::clone(&window))
            .map_err(|e| format!("create_surface: {e}"))?;
        let ctx = pollster::block_on(GpuContext::from_instance(&instance, Some(&surface)))
            .map_err(|e| e.to_string())?;
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
        let view = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        let size = (frame.texture.width(), frame.texture.height());
        if let Some(host) = &self.video {
            host.sync(&shell.video(), &mut self.renderer);
        }
        shell.with_sources(|src| self.renderer.draw(list, &view, size, CLEAR, src));
        // The readback copies the very texture that is presented next: what the swapchain shows.
        let dumped = dump.map(|path| {
            crate::dump::dump_texture(&self.ctx, &frame.texture, self.config.format, path)
        });
        self.window.pre_present_notify();
        self.ctx.queue().present(frame);
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
    run: Option<Running>,
    stats: Option<FrameStats>,
    mods: ModifiersState,
    failure: Option<String>,
    verbose_events: bool,
    /// Frames presented so far, and whether `--dump-frame` has been written.
    frames_drawn: u32,
    dumped: bool,
    touch_next: usize,
    /// Single instance, launches, input-to-present timer.
    extras: crate::window_extras::Extras,
    /// The window edge the pointer is on (drag to resize), `None` inside or when maximised / fullscreen.
    edge: Option<winit::window::ResizeDirection>,
    /// The last press on the toolbar row, for the double click that maximises.
    last_drag_press: Option<Instant>,
    /// The pointer in physical pixels.
    cursor_px: (f64, f64),
    /// No surface image could be had: draw again at this time (ms).
    retry_at: Option<f64>,
    /// Immediate retries in a row.
    retries: u8,
}

impl App {
    fn now(&self) -> f64 {
        self.start.elapsed().as_secs_f64() * 1000.0
    }

    fn redraw(&mut self, event_loop: &ActiveEventLoop) {
        let now_ms = self.now();
        self.retry_at = None;
        let Some(run) = self.run.as_mut() else { return };
        // The driver took the device away (reset, GPU removed): build surface, device and renderer again.
        if run.gpu.device_lost() {
            match Gpu::new(
                event_loop,
                Arc::clone(&run.window),
                self.opts.dump_frame.is_some(),
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
            crate::effects::perform(&e);
        }
        // The system's media widgets: tell them what plays, and let their buttons drive the player.
        if let Some(m) = run.media.as_mut() {
            m.update(run.shell.now_playing().as_ref(), now_ms);
            for intent in m.intents() {
                run.shell.player_intent(intent, now_ms);
            }
        }
        if run.shell.take_fullscreen_request() {
            run.window
                .set_fullscreen(crate::window_rules::toggled(run.window.fullscreen()));
        }
        let hide = run.shell.cursor_hidden();
        if hide != run.cursor_hidden {
            run.cursor_hidden = hide;
            run.window.set_cursor_visible(!hide);
        }
        let scale = run.window.scale_factor() as f32;
        if (size.width, size.height) != run.size_px || (scale - run.scale).abs() > f32::EPSILON {
            run.size_px = (size.width, size.height);
            run.scale = scale;
            run.gpu.resize(size.width, size.height);
            run.shell.resize(run.size_px, scale);
        }
        // The idle poll of the real app only looks: build the picture, and present nothing when it equals the last one
        // (acquiring and presenting a swap-chain image four times a second cost 4.7 % of a core on a Windows machine).
        if let Some(host) = &run.gpu.video {
            host.announce(&run.shell.video(), run.size_px);
        }
        let mut pre: Option<(DrawList, bool)> = None;
        if std::mem::take(&mut run.idle_poll) {
            let at = Instant::now().duration_since(self.start).as_secs_f64() * 1000.0;
            let (list, more) = run.shell.frame(at);
            let fp = fingerprint(&list);
            if !more && run.last_fp == Some(fp) {
                return;
            }
            run.last_fp = Some(fp);
            pre = Some((list, more));
        } else {
            run.last_fp = None;
        }
        let (frame, refit) = match run.gpu.acquire() {
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
                if self.stats.is_some() {
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
        let now = began.duration_since(self.start).as_secs_f64() * 1000.0;
        let (list, more) = match pre.take() {
            Some(p) => p,
            None => run.shell.frame(now),
        };
        self.frames_drawn += 1;
        while let Some(&(at, code, x, y)) = self.opts.touch_script.get(self.touch_next)
            && at <= self.frames_drawn
        {
            self.touch_next += 1;
            run.shell.finger_id(0, code, (x, y), now);
        }
        let dump = (self.opts.dump_frame.as_deref())
            .filter(|_| !self.dumped && self.frames_drawn >= self.opts.after_frames.max(1));
        match run.gpu.draw(frame, &list, &run.shell, dump) {
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
        if refit {
            let s = run.window.inner_size();
            run.gpu.resize(s.width, s.height);
            run.window.request_redraw();
        }
        self.extras.presented();
        let cpu_ms = began.elapsed().as_secs_f64() * 1000.0;
        if let Some(s) = self.stats.as_mut() {
            s.record(now, cpu_ms, run.continuous);
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
            W::DragMove => {
                let double = self
                    .last_drag_press
                    .is_some_and(|t| t.elapsed() < Duration::from_millis(400));
                if double {
                    self.last_drag_press = None;
                    toggle(&run.window);
                } else {
                    self.last_drag_press = Some(Instant::now());
                    let _ = run.window.drag_window();
                    // Windows runs the move in its own loop and eats the button release.
                    run.shell.release_stale(now_ms);
                }
            }
        }
    }

    fn input_changed(&mut self) {
        if let Some(run) = &self.run {
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
            // The screen-reader adapter must exist before the window is shown.
            .with_visible(false);
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
        // The first rectangle never leaves the work area (a 1440x900 default on a 1280x800 screen) and is centred.
        #[cfg(target_os = "windows")]
        if !self.opts.offscreen {
            crate::win_shell::place_in_work_area(&window);
            crate::win_shell::set_taskbar_identity(&window);
        }
        #[cfg(target_os = "windows")]
        if self.opts.form == swiftly_ui::Idiom::Desktop {
            // winit always keeps WS_CAPTION (needed for Aero Snap and the shadow); the look is frameless because
            // WM_NCCALCSIZE gives the whole window to the client area. The thick frame and the drop shadow stay.
            use winit::platform::windows::WindowExtWindows;
            window.set_undecorated_shadow(true);
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
            self.opts.dump_frame.is_some(),
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
        if self.opts.stats {
            let info = gpu.ctx.adapter_info();
            eprintln!(
                "swiftly-desktop: {} ({:?}), {}x{} px at {scale}x, surface format {:?}, FIFO, refresh period {period_ms:.2} ms",
                info.name, info.backend, size.width, size.height, gpu.config.format
            );
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
        });
    }

    fn user_event(&mut self, _event_loop: &ActiveEventLoop, event: UserEvent) {
        let now = self.now();
        let ev = match event {
            UserEvent::Access(ev) => ev,
            UserEvent::Media => {
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
            // Dark only by design (no light variant in the design): the title bar stays dark whatever the system says.
            WindowEvent::ThemeChanged(_) => {
                if let Some(run) = &self.run {
                    run.window.set_theme(Some(crate::window_rules::THEME));
                }
            }
            WindowEvent::CloseRequested => event_loop.exit(),
            WindowEvent::RedrawRequested => {
                if self.verbose_events {
                    eprintln!("swiftly-desktop: RedrawRequested at {now:.0} ms");
                }
                self.redraw(event_loop);
            }
            WindowEvent::Resized(_) | WindowEvent::ScaleFactorChanged { .. } => {
                // Live resize: fit the surface and the layout to the new size and present in this same event. Waiting for a
                // later RedrawRequested leaves the old picture stretched (and a black or white strip) for a frame or more.
                if self.run.is_some() {
                    self.redraw(event_loop);
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
            WindowEvent::ModifiersChanged(m) => self.mods = m.state(),
            WindowEvent::KeyboardInput { event, .. } => {
                // A focused text field takes typed text, Backspace, Return and Esc before any shortcut.
                if event.state == ElementState::Pressed
                    && (!(self.mods.control_key() || self.mods.super_key() || self.mods.alt_key())
                        || edit_event(&event.logical_key, self.mods).is_some())
                    && self.run.as_ref().is_some_and(|r| r.shell.wants_text())
                {
                    if let Some(ev) = edit_event(&event.logical_key, self.mods)
                        && let Some(run) = self.run.as_mut()
                        && run.shell.text_event(&ev)
                    {
                        self.input_changed();
                        return;
                    }
                    let text = match &event.logical_key {
                        Key::Named(NamedKey::Backspace) => Some("\u{8}".to_owned()),
                        Key::Named(NamedKey::Enter) => Some("\n".to_owned()),
                        Key::Named(NamedKey::Escape) => Some("\u{1b}".to_owned()),
                        Key::Named(NamedKey::Space) => Some(" ".to_owned()),
                        _ => event.text.as_ref().map(|t| t.to_string()),
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
                if event.state == ElementState::Pressed
                    && let Some(run) = self.run.as_mut()
                {
                    let ctx = crate::window_rules::Ctx {
                        fullscreen: run.window.fullscreen().is_some(),
                        player_open: run.shell.player_open(),
                        text_focus: run.shell.wants_text(),
                    };
                    if let Some(action) = crate::window_rules::resolve(
                        &event.logical_key,
                        self.mods,
                        event.repeat,
                        ctx,
                    ) && crate::window_rules::apply(action, &run.window, &mut run.shell, now)
                    {
                        self.input_changed();
                        return;
                    }
                }
                // Arrows, Tab and Enter go to the shared focus engine (arrows repeat, Enter does not).
                let plain =
                    !(self.mods.alt_key() || self.mods.super_key() || self.mods.control_key());
                let nav = match &event.logical_key {
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
                    if !(event.repeat && repeats) {
                        let down = event.state == ElementState::Pressed;
                        if let Some(run) = self.run.as_mut()
                            && run.shell.nav_key(k, down, now)
                        {
                            self.input_changed();
                        }
                    }
                    return;
                }
                if event.state != ElementState::Pressed || event.repeat {
                    return;
                }
                let ctrl_or_cmd = self.mods.control_key() || self.mods.super_key();
                let cmd = match &event.logical_key {
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
                        n
                        @ (NamedKey::Home | NamedKey::End | NamedKey::PageUp | NamedKey::PageDown),
                    ) if !ctrl_or_cmd && !self.mods.alt_key() => {
                        use swiftly_ui::shortcuts::ScrollKey as S;
                        Some(Command::Scroll(match n {
                            NamedKey::Home => S::Home,
                            NamedKey::End => S::End,
                            NamedKey::PageUp => S::PageUp,
                            _ => S::PageDown,
                        }))
                    }
                    Key::Character(c)
                        if !ctrl_or_cmd
                            && !self.mods.alt_key()
                            && c.chars().count() == 1
                            && c.chars().all(|ch| !ch.is_control() && !ch.is_whitespace()) =>
                    {
                        Some(Command::TypeToSearch(c.to_string()))
                    }
                    Key::Character(c) if c.as_str() == "[" && self.mods.super_key() => {
                        Some(Command::Back)
                    }
                    Key::Character(c) if ctrl_or_cmd && matches!(c.as_str(), "q" | "w") => {
                        Some(Command::Quit)
                    }
                    _ => None,
                };
                if let Some(cmd) = cmd {
                    self.command(event_loop, cmd);
                }
            }
            WindowEvent::CursorMoved { position, .. } => {
                let over_player = self.run.as_mut().is_some_and(|run| {
                    run.shell.cursor_moved((position.x, position.y), now);
                    let size = run.window.inner_size();
                    let frameless = self.opts.form == swiftly_ui::Idiom::Desktop
                        && run.window.fullscreen().is_none()
                        && !run.window.is_maximized();
                    self.cursor_px = (position.x, position.y);
                    self.edge = if frameless {
                        resize_edge(
                            position.x,
                            position.y,
                            size.width,
                            size.height,
                            6.0 * f64::from(run.scale),
                        )
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
                if over_player {
                    self.input_changed();
                } else {
                    self.input_changed_if_pressed();
                }
            }
            WindowEvent::Focused(true) => {
                if let Some(run) = self.run.as_mut() {
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
                    if state == ElementState::Pressed
                        && let (Some(d), Some(run)) = (self.edge, self.run.as_ref())
                    {
                        let _ = run.window.drag_resize_window(d);
                        return;
                    }
                    if let Some(run) = self.run.as_mut() {
                        run.shell
                            .primary_button(state == ElementState::Pressed, now);
                    }
                    self.window_actions(event_loop);
                    self.input_changed();
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
        let mut wake: Option<f64> = None;
        if let Some(s) = self.stats.as_mut() {
            if let Some(line) = s.report(now) {
                eprintln!("{line}");
            }
            wake = Some(s.next_report_ms());
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
            Some(ms) => {
                ControlFlow::WaitUntil(self.start + Duration::from_secs_f64((ms / 1000.0).max(0.0)))
            }
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
    let event_loop = EventLoop::<UserEvent>::with_user_event()
        .build()
        .map_err(|e| format!("event loop: {e}"))?;
    event_loop.set_control_flow(ControlFlow::Wait);
    let mut app = App {
        proxy: event_loop.create_proxy(),
        extras,
        edge: None,
        last_drag_press: None,
        cursor_px: (0.0, 0.0),
        opts,
        start: Instant::now(),
        run: None,
        stats: None,
        mods: ModifiersState::empty(),
        failure: None,
        verbose_events: std::env::var_os("SWIFTLY_DESKTOP_TRACE").is_some(),
        frames_drawn: 0,
        dumped: false,
        touch_next: 0,
        retry_at: None,
        retries: 0,
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

#[cfg(test)]
mod tests {
    #[cfg(not(target_os = "macos"))]
    use super::edit_event;
    use super::{resize_edge, resize_icon};
    #[cfg(not(target_os = "macos"))]
    use winit::keyboard::{Key, ModifiersState, NamedKey};
    use winit::window::{CursorIcon, ResizeDirection as D};

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
