//! The parts of the window that sit beside the draw loop: the single-instance lock and its inbox, links and files that
//! arrive (command line, second launch, drag and drop), the scripted wheel run and the input-to-present timer.
//! `app.rs` holds one [`Extras`] and calls it at a few well-defined points, so this logic stays out of the loop.

use crate::cli::Options;
use crate::deep_link::{self, Launch};
use crate::latency::{self, InputLatency};
use crate::shell::Shell;
use crate::single_instance::{self, HandOver, Role};
use crate::wheel::{WheelDelta, WheelPhase};
use std::path::Path;
use std::time::{Duration, Instant};
use winit::event::WindowEvent;
use winit::window::Window;

/// The application id every platform identifies the app by: the Wayland `app_id` and the X11 `WM_CLASS` (so the shell finds
/// the `.desktop` file and its icon), the Windows AppUserModelID. It equals the desktop file's id
/// (`Distribution/desktop/de.paulherter.swiftly.player.desktop`).
pub const APP_ID: &str = "de.paulherter.swiftly.player";

/// The product's name in the window title, taskbar, process description and installer. The logo itself says only "Swiftly".
pub const PRODUCT_NAME: &str = "Swiftly Player";

const ICON_256: &[u8] = include_bytes!("../assets/app-icon-256.png");
const ICON_64: &[u8] = include_bytes!("../assets/app-icon-64.png");

/// The embedded logo picture (`small`: 64 px, otherwise 256 px) as straight-alpha RGBA with its size; `None` when it
/// cannot be decoded.
fn icon_rgba(small: bool) -> Option<(Vec<u8>, u32, u32)> {
    let mut reader =
        png::Decoder::new(std::io::Cursor::new(if small { ICON_64 } else { ICON_256 }))
            .read_info()
            .ok()?;
    let mut buf = vec![0; reader.output_buffer_size()?];
    let info = reader.next_frame(&mut buf).ok()?;
    buf.truncate(info.buffer_size());
    let rgba = match info.color_type {
        png::ColorType::Rgba => buf,
        png::ColorType::Rgb => buf
            .as_chunks::<3>()
            .0
            .iter()
            .flat_map(|p| [p[0], p[1], p[2], 255])
            .collect(),
        _ => return None,
    };
    Some((rgba, info.width, info.height))
}

/// The Swiftly logo as a window icon (`small`: the 64 px picture for the title bar and taskbar corner; otherwise the large
/// one). `None` when the embedded picture cannot be decoded.
pub fn window_icon(small: bool) -> Option<winit::window::Icon> {
    let (rgba, w, h) = icon_rgba(small)?;
    winit::window::Icon::from_rgba(rgba, w, h).ok()
}

/// Both logo sizes for the Wayland toplevel icon (the compositor takes the one that fits its panel).
#[cfg(all(
    unix,
    not(any(target_os = "macos", target_os = "ios", target_os = "android"))
))]
pub fn toplevel_pictures() -> Vec<crate::toplevel_icon::Picture> {
    [true, false]
        .into_iter()
        .filter_map(icon_rgba)
        .filter(|(_, w, h)| w == h)
        .map(|(rgba, side, _)| crate::toplevel_icon::Picture { side, rgba })
        .collect()
}

/// What the helper threads send into the event loop.
#[derive(Debug)]
pub enum Event {
    /// A scripted wheel event; `at` is when the sender produced it.
    Wheel {
        /// Arrival stamp.
        at: Instant,
        /// The delta.
        delta: WheelDelta,
        /// The phase.
        phase: Option<WheelPhase>,
    },
    /// A second launch handed over its arguments.
    Launch(Vec<String>),
}

/// How an [`Event`] gets into the loop (a closure over the event-loop proxy); `false` when the loop is gone.
pub type Send2Loop = Box<dyn Fn(Event) -> bool + Send>;

/// Single instance, launches and latency of one window.
pub struct Extras {
    latency: Option<InputLatency>,
    primary: Option<single_instance::Primary>,
    launch: Vec<Launch>,
    /// Links from the command line, waiting for the shell to exist.
    start_links: Vec<deep_link::DeepLink>,
    run_script: bool,
    quit_after: Option<f64>,
    cursor_set: bool,
    period_ms: f64,
}

impl Extras {
    /// Sets up from the options. `None`: another instance runs, this launch's arguments were handed over, and the
    /// process should exit.
    pub fn new(opts: &Options) -> Option<Extras> {
        if let Some(q) = opts.quit_after {
            crate::quit_guard::arm(q);
        }
        let mut primary = None;
        if opts.single_instance {
            let dir = single_instance::default_dir();
            match single_instance::acquire(&dir) {
                Ok(Role::Primary(p)) => primary = Some(p),
                Ok(Role::Secondary) => {
                    let args: Vec<String> = std::env::args().skip(1).collect();
                    match single_instance::hand_over(&dir, &args, Duration::from_secs(3)) {
                        Ok(HandOver::Delivered) => {
                            eprintln!(
                                "swiftly-desktop: already running, handed over {} argument(s)",
                                args.len()
                            );
                            return None;
                        }
                        Ok(HandOver::Waiting) => {
                            eprintln!(
                                "swiftly-desktop: already running (slow to answer), left {} argument(s) in its inbox",
                                args.len()
                            );
                            return None;
                        }
                        // The old instance was dying: this one is the app now and opens its own arguments.
                        Ok(HandOver::TakeOver(p)) => {
                            eprintln!(
                                "swiftly-desktop: the running instance was gone, taking over"
                            );
                            primary = Some(p);
                        }
                        Err(e) => eprintln!(
                            "swiftly-desktop: already running, but handing over failed ({e}); starting anyway"
                        ),
                    }
                }
                Err(e) => eprintln!(
                    "swiftly-desktop: single instance lock unavailable ({e}); starting anyway"
                ),
            }
        }
        Some(Extras {
            latency: opts.stats.then(InputLatency::default),
            primary,
            launch: opts.launch.clone(),
            start_links: Vec::new(),
            run_script: opts.latency,
            quit_after: opts.quit_after,
            cursor_set: false,
            period_ms: 1000.0 / 60.0,
        })
    }

    /// The window exists: reads the real refresh rate, opens what the command line asked for, starts the inbox watcher
    /// and the scripted wheel run.
    pub fn started(
        &mut self,
        window: &Window,
        send: impl Fn(Event) -> bool + Send + Clone + 'static,
    ) {
        if let Some(mhz) = window
            .current_monitor()
            .and_then(|m| m.refresh_rate_millihertz())
        {
            self.period_ms = 1_000_000.0 / f64::from(mhz);
        }
        for l in std::mem::take(&mut self.launch) {
            match l {
                Launch::Link(link) => self.start_links.push(link),
                file => eprintln!("swiftly-desktop: {}", deep_link::open(&file)),
            }
        }
        if let Some(p) = self.primary.take() {
            let send = send.clone();
            p.watch(move |args| send(Event::Launch(args)));
        }
        if self.run_script {
            let rounds = self.quit_after.map_or(10, |q| (q - 3.0).max(1.0) as u32);
            std::thread::spawn(move || {
                // Let the window settle first.
                std::thread::sleep(Duration::from_millis(1500));
                let t0 = Instant::now();
                for (t, delta, phase) in latency::script(rounds) {
                    let due = t0 + Duration::from_secs_f64(t / 1000.0);
                    std::thread::sleep(due.saturating_duration_since(Instant::now()));
                    if !send(Event::Wheel {
                        at: Instant::now(),
                        delta,
                        phase,
                    }) {
                        return;
                    }
                }
            });
        }
    }

    /// The shell exists: hands it the links the command line carried.
    pub fn deliver_start(&mut self, shell: &mut Shell, now: f64) {
        for link in std::mem::take(&mut self.start_links) {
            shell.open_link(link, now);
        }
    }

    /// An event from a helper thread. Returns whether a redraw is due.
    pub fn handle(&mut self, ev: Event, window: &Window, shell: &mut Shell, now: f64) -> bool {
        match ev {
            Event::Wheel { at, delta, phase } => {
                if !self.cursor_set {
                    self.cursor_set = true;
                    let s = window.inner_size();
                    shell.cursor_moved((f64::from(s.width) / 2.0, f64::from(s.height) / 2.0), now);
                }
                if let Some(l) = &mut self.latency {
                    l.mark(at);
                }
                shell.wheel(delta, phase, now);
                true
            }
            Event::Launch(args) => {
                for l in deep_link::parse_args(args) {
                    match l {
                        Launch::Link(link) => shell.open_link(link, now),
                        file => {
                            eprintln!("swiftly-desktop: second launch: {}", deep_link::open(&file))
                        }
                    }
                }
                window.set_minimized(false);
                window.focus_window();
                true
            }
        }
    }

    /// A window event arrived (called first thing, so the stamp is as early as the app can make it).
    pub fn arrived(&mut self, event: &WindowEvent) {
        if let Some(l) = &mut self.latency
            && matches!(
                event,
                WindowEvent::MouseWheel { .. }
                    | WindowEvent::MouseInput { .. }
                    | WindowEvent::Touch(_)
            )
        {
            l.mark(Instant::now());
        }
    }

    /// A file was dropped on the window.
    pub fn dropped(&self, path: &Path) {
        eprintln!(
            "swiftly-desktop: dropped file: {}",
            deep_link::open(&Launch::File(path.to_path_buf()))
        );
    }

    /// A frame was presented.
    pub fn presented(&mut self) {
        if let Some(l) = &mut self.latency {
            l.presented(Instant::now());
        }
    }

    /// The report for the end of the run, when latency was measured.
    pub fn report(&self) -> Option<String> {
        self.latency
            .as_ref()
            .filter(|_| self.run_script)
            .map(|l| l.report(self.period_ms))
    }
}

/// The window cursor for what the pointer is over (`Ui::cursor`).
pub fn cursor_icon(c: swiftly_ui::Cursor) -> winit::window::CursorIcon {
    use swiftly_ui::Cursor as C;
    use winit::window::CursorIcon as I;
    match c {
        C::Arrow => I::Default,
        C::Pointer => I::Pointer,
        C::Text => I::Text,
        C::ResizeH => I::EwResize,
        C::ResizeV => I::NsResize,
        C::Grab => I::Grab,
        _ => I::NotAllowed,
    }
}
