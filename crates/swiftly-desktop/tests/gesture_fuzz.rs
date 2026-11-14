//! Seeded gesture fuzz over the whole app (`--demo app`, the scripted demo server): random sequences of pointer moves,
//! presses (left, right), wheel (lines, points), keys (Tab, Esc, Enter, arrows, Ctrl chords, typing), touch, window
//! resizes and scale changes, with a frame (layout + draw + screen-reader tree) after every event. No window.
//!
//! A panic or a hang prints the seed, the idiom and the shortest event list that still fails (shrunk by removing
//! chunks), so the failure replays with `SWIFTLY_FUZZ_SEED=<seed> SWIFTLY_FUZZ_SEQS=1`.
//!
//! Knobs (environment): `SWIFTLY_FUZZ_SEQS` sequences per idiom (default 24), `SWIFTLY_FUZZ_LEN` events per
//! sequence (default 150), `SWIFTLY_FUZZ_SEED` first seed (default 1), `SWIFTLY_FUZZ_THREADS` (default 4),
//! `SWIFTLY_FUZZ_EXTREME=1` also tiny and huge windows, `SWIFTLY_FUZZ_SYSTEM_FONTS=1` the fonts of the machine
//! (as the real app), `SWIFTLY_FUZZ_NO_GPU=1` no offscreen wgpu draw.

#![allow(clippy::unwrap_used)]

use std::collections::{BTreeMap, HashMap};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use swiftly_desktop::player_screen::PlayerKey;
use swiftly_desktop::shell::{Command, Ime, Shell};
use swiftly_desktop::wheel::{WheelDelta, WheelPhase};
use swiftly_desktop::window_rules::{self, Action, Ctx};
use swiftly_text::{EditKey, Mods, TextInputEvent};
use swiftly_ui::a11y::A11yNode;
use swiftly_ui::shortcuts::ScrollKey;
use swiftly_ui::{Cx, Dir, Idiom, NavKey};
use winit::keyboard::{Key, ModifiersState, NamedKey};

static COVERAGE: Mutex<BTreeMap<String, u64>> = Mutex::new(BTreeMap::new());

/// splitmix64: tiny, seeded, the same on every machine.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n.max(1)
    }
    fn unit(&mut self) -> f32 {
        (self.next() >> 40) as f32 / (1u64 << 24) as f32
    }
    fn range(&mut self, lo: f32, hi: f32) -> f32 {
        lo + (hi - lo) * self.unit()
    }
    fn pick<'a, T>(&mut self, v: &'a [T]) -> &'a T {
        &v[self.below(v.len() as u64) as usize]
    }
}

/// One thing the user (or the window system) does. Pointer targets are fractions of the window, node targets pick a
/// node of the screen reader tree by fraction, so a shortened list still means the same kind of action.
#[derive(Clone, Debug)]
enum Ev {
    Move(f32, f32),
    MoveToNode(f32),
    Press,
    Release,
    Click,
    ClickNode(f32),
    RightClick,
    RightClickNode(f32),
    CursorLeft,
    Wheel(WheelDelta, Option<WheelPhase>),
    Nav(NavKey, bool),
    Command(Command),
    Key(Key, ModifiersState),
    Typed(String),
    Ime(Ime),
    Edit(TextInputEvent),
    Finger(u8, f32, f32),
    Resize(u32, u32, f32),
    Wait,
}

#[derive(Clone, Debug)]
struct Step {
    dt: f64,
    ev: Ev,
}

fn ctrl() -> ModifiersState {
    if cfg!(target_os = "macos") {
        ModifiersState::SUPER
    } else {
        ModifiersState::CONTROL
    }
}

fn gen_event(r: &mut Rng, extreme: bool) -> Ev {
    let named = [
        NamedKey::F11,
        NamedKey::Enter,
        NamedKey::Escape,
        NamedKey::Space,
        NamedKey::ArrowUp,
        NamedKey::ArrowDown,
        NamedKey::ArrowLeft,
        NamedKey::ArrowRight,
        NamedKey::Tab,
        NamedKey::Home,
        NamedKey::End,
        NamedKey::PageUp,
        NamedKey::PageDown,
        NamedKey::Backspace,
        NamedKey::Delete,
        NamedKey::BrowserBack,
        NamedKey::BrowserForward,
        NamedKey::MediaPlayPause,
        NamedKey::MediaTrackNext,
    ];
    let chars = [
        "1", "2", "3", "4", "5", "0", "f", "F", ",", "[", "]", "p", "P", "m", "g", "h", "j", "k",
        "t", "-", "=", "+", "a", "c", "v", "x", "z", "y", "q", "w", "ä", "😀",
    ];
    let mods = [
        ModifiersState::empty(),
        ModifiersState::empty(),
        ModifiersState::SHIFT,
        ctrl(),
        ctrl(),
        ctrl() | ModifiersState::SHIFT,
        ModifiersState::ALT,
        ctrl() | ModifiersState::ALT,
    ];
    let texts = [
        "a",
        "Breaking",
        "ä ö ü",
        "",
        " ",
        "\u{301}",
        "Привет",
        "😀😀",
        "x".repeat(200).leak(),
        "\t",
    ];
    match r.below(100) {
        0..=17 => Ev::Move(r.unit(), r.unit()),
        18..=22 => Ev::MoveToNode(r.unit()),
        23..=27 => Ev::Press,
        28..=32 => Ev::Release,
        33..=40 => Ev::Click,
        41..=52 => Ev::ClickNode(r.unit()),
        53..=55 => Ev::RightClick,
        56..=58 => Ev::RightClickNode(r.unit()),
        59..=60 => Ev::CursorLeft,
        61..=69 => {
            let phase = [
                None,
                Some(WheelPhase::Started),
                Some(WheelPhase::Moved),
                Some(WheelPhase::Moved),
                Some(WheelPhase::Ended),
                Some(WheelPhase::Cancelled),
            ];
            let ph = *r.pick(&phase);
            let (x, y) = (r.range(-4.0, 4.0), r.range(-6.0, 6.0));
            if r.below(2) == 0 {
                Ev::Wheel(
                    WheelDelta::Lines(if r.below(3) == 0 { x } else { 0.0 }, y.round()),
                    ph,
                )
            } else {
                Ev::Wheel(WheelDelta::Points(x * 20.0, y * 40.0), ph)
            }
        }
        70..=77 => {
            let k = *r.pick(&[
                NavKey::Arrow(Dir::Up),
                NavKey::Arrow(Dir::Down),
                NavKey::Arrow(Dir::Left),
                NavKey::Arrow(Dir::Right),
                NavKey::Tab,
                NavKey::ShiftTab,
                NavKey::Enter,
                NavKey::Escape,
            ]);
            Ev::Nav(k, r.below(5) != 0)
        }
        78..=79 => Ev::Command(match r.below(8) {
            0 | 1 => Command::Back,
            2 => Command::Forward,
            3 => Command::Scroll(*r.pick(&[
                ScrollKey::Home,
                ScrollKey::End,
                ScrollKey::PageUp,
                ScrollKey::PageDown,
                ScrollKey::LineUp,
            ])),
            _ => Command::Forward,
        }),
        80..=87 => {
            let key = if r.below(2) == 0 {
                Key::Named(*r.pick(&named))
            } else {
                Key::Character((*r.pick(&chars)).into())
            };
            Ev::Key(key, *r.pick(&mods))
        }
        88..=90 => Ev::Typed((*r.pick(&texts)).to_owned()),
        91 => Ev::Ime(match r.below(3) {
            0 => Ime::Preedit((*r.pick(&texts)).to_owned(), Some((0, r.below(4) as usize))),
            1 => Ime::Commit((*r.pick(&texts)).to_owned()),
            _ => Ime::Cancel,
        }),
        92..=93 => {
            let m = Mods {
                shift: r.below(2) == 0,
                word: r.below(2) == 0,
                line: r.below(2) == 0,
            };
            Ev::Edit(match r.below(8) {
                0 => TextInputEvent::Key(
                    *r.pick(&[
                        EditKey::Left,
                        EditKey::Right,
                        EditKey::Home,
                        EditKey::End,
                        EditKey::Delete,
                    ]),
                    m,
                ),
                1 => TextInputEvent::SelectAll,
                2 => TextInputEvent::Copy,
                3 => TextInputEvent::Cut,
                4 => TextInputEvent::Paste,
                5 => TextInputEvent::Undo,
                6 => TextInputEvent::Redo,
                _ => TextInputEvent::Text((*r.pick(&texts)).to_owned()),
            })
        }
        94..=95 => Ev::Finger(r.below(4) as u8, r.unit(), r.unit()),
        96..=98 => {
            let scale = *r.pick(&[1.0, 1.0, 1.25, 1.5, 2.0, 3.0, 0.75]);
            let (w, h) = if extreme && r.below(3) == 0 {
                (r.range(1.0, 4000.0) as u32, r.range(1.0, 2500.0) as u32)
            } else {
                (r.range(900.0, 2800.0) as u32, r.range(560.0, 1700.0) as u32)
            };
            Ev::Resize(w, h, scale)
        }
        _ => Ev::Wait,
    }
}

fn gen_steps(seed: u64, len: usize, extreme: bool) -> Vec<Step> {
    let mut r = Rng(seed.wrapping_mul(0x2545_F491_4F6C_DD1D) ^ 0xDEAD_BEEF);
    (0..len)
        .map(|_| {
            let dt = match r.below(40) {
                0..=3 => 0.0,
                4..=7 => r.range(300.0, 3000.0) as f64,
                // The window was busy (a blocked vsync, a drag of the title bar, sleep and resume).
                8 => r.range(5_000.0, 600_000.0) as f64,
                // Event stamps and frame stamps are taken at different moments; the clock may step back a little.
                9..=10 => -(r.range(0.0, 20.0) as f64),
                _ => r.range(1.0, 40.0) as f64,
            };
            Step {
                dt,
                ev: gen_event(&mut r, extreme),
            }
        })
        .collect()
}

fn flatten(n: &A11yNode, out: &mut Vec<[f32; 4]>) {
    if let Some(b) = n.bounds
        && b[2] > 0.0
        && b[3] > 0.0
    {
        out.push(b);
    }
    for c in &n.children {
        flatten(c, out);
    }
}

/// The app as the winit loop drives it, minus the window.
struct Rig {
    shell: Shell,
    size_px: (u32, u32),
    scale: f32,
    now: f64,
    fullscreen: bool,
    pressed_count: usize,
    gpu: Option<OffscreenGpu>,
}

thread_local! {
    static GPU: std::rc::Rc<Option<swiftly_render::GpuContext>> = std::rc::Rc::new(
        if std::env::var_os("SWIFTLY_FUZZ_NO_GPU").is_some() { None } else { swiftly_render::GpuContext::headless().ok() },
    );
}

/// The real wgpu renderer drawing into a texture of the window's size, as the swap-chain image would be.
struct OffscreenGpu {
    ctx: std::rc::Rc<Option<swiftly_render::GpuContext>>,
    renderer: swiftly_render::WgpuRenderer,
    texture: Option<(wgpu::Texture, (u32, u32))>,
}

impl OffscreenGpu {
    fn new() -> Option<OffscreenGpu> {
        let ctx = GPU.with(std::rc::Rc::clone);
        let renderer = swiftly_render::WgpuRenderer::new(
            ctx.as_ref().as_ref()?,
            wgpu::TextureFormat::Bgra8UnormSrgb,
        )
        .ok()?;
        Some(OffscreenGpu {
            ctx,
            renderer,
            texture: None,
        })
    }

    fn draw(&mut self, shell: &Shell, list: &swiftly_render::DrawList, size_px: (u32, u32)) {
        let ctx = self.ctx.as_ref().as_ref().unwrap();
        let size = (size_px.0.clamp(1, 7680), size_px.1.clamp(1, 4320));
        if self.texture.as_ref().is_none_or(|(_, s)| *s != size) {
            let t = ctx.device().create_texture(&wgpu::TextureDescriptor {
                label: Some("fuzz target"),
                size: wgpu::Extent3d {
                    width: size.0,
                    height: size.1,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Bgra8UnormSrgb,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
                view_formats: &[],
            });
            self.texture = Some((t, size));
        }
        let view = self
            .texture
            .as_ref()
            .unwrap()
            .0
            .create_view(&wgpu::TextureViewDescriptor::default());
        shell.with_sources(|src| {
            self.renderer
                .draw(list, &view, size, swiftly_render::Color::BLACK, src)
        });
        self.renderer.wait().unwrap();
    }
}

impl Rig {
    fn new(idiom: Idiom, size_px: (u32, u32), scale: f32) -> Rig {
        Rig {
            shell: Shell::new_suite(
                size_px,
                scale,
                if std::env::var_os("SWIFTLY_FUZZ_SYSTEM_FONTS").is_some() {
                    Cx::new()
                } else {
                    Cx::deterministic()
                },
                idiom,
            ),
            size_px,
            scale,
            now: 0.0,
            fullscreen: false,
            pressed_count: 0,
            gpu: OffscreenGpu::new(),
        }
    }

    fn pt(&self, fx: f32, fy: f32) -> (f64, f64) {
        // Physical pixels; a little outside the window too.
        let (w, h) = (self.size_px.0 as f32, self.size_px.1 as f32);
        (
            f64::from(fx * w * 1.04 - w * 0.02),
            f64::from(fy * h * 1.04 - h * 0.02),
        )
    }

    fn nodes(&self) -> Vec<[f32; 4]> {
        let (_, nodes) = self.shell.a11y_nodes();
        let mut v = Vec::new();
        for n in &nodes {
            flatten(n, &mut v);
        }
        v
    }

    fn node_px(&self, f: f32) -> Option<(f64, f64)> {
        let v = self.nodes();
        if v.is_empty() {
            return None;
        }
        let b = v[((f * v.len() as f32) as usize).min(v.len() - 1)];
        Some((
            f64::from((b[0] + b[2] / 2.0) * self.scale),
            f64::from((b[1] + b[3] / 2.0) * self.scale),
        ))
    }

    /// The keyboard path of `app.rs`, event by event.
    fn key(&mut self, key: &Key, mods: ModifiersState) {
        let now = self.now;
        let text_mods = mods;
        let shortcut = if cfg!(target_os = "macos") {
            mods.super_key()
        } else {
            mods.control_key()
        };
        if (!(mods.control_key() || mods.super_key() || mods.alt_key()) || shortcut)
            && self.shell.wants_text()
        {
            let text = match key {
                Key::Named(NamedKey::Backspace) => Some("\u{8}".to_owned()),
                Key::Named(NamedKey::Enter) => Some("\n".to_owned()),
                Key::Named(NamedKey::Escape) => Some("\u{1b}".to_owned()),
                Key::Named(NamedKey::Space) => Some(" ".to_owned()),
                Key::Character(c) => Some(c.to_string()),
                _ => None,
            };
            if let Some(t) = text
                && self.shell.text_key(&t)
            {
                return;
            }
        }
        let ctx = Ctx {
            fullscreen: self.fullscreen,
            player_open: self.shell.player_open(),
            text_focus: self.shell.wants_text(),
        };
        if let Some(action) = window_rules::resolve(key, text_mods, false, ctx) {
            let used = match action {
                Action::ToggleFullscreen => {
                    self.fullscreen = !self.fullscreen;
                    true
                }
                Action::LeaveFullscreen => {
                    self.fullscreen = false;
                    true
                }
                Action::Tab(n) => self.shell.goto_tab(n, now),
                Action::Settings => self.shell.open_settings(now),
                Action::Command(c) => self.shell.run_command(c, now),
                Action::Player(k) => self.shell.player_key(k, now),
            };
            if used {
                return;
            }
        }
        let plain = !(mods.alt_key() || mods.super_key() || mods.control_key());
        let nav = match key {
            Key::Named(NamedKey::ArrowUp) => Some(NavKey::Arrow(Dir::Up)),
            Key::Named(NamedKey::ArrowDown) => Some(NavKey::Arrow(Dir::Down)),
            Key::Named(NamedKey::ArrowLeft) => Some(NavKey::Arrow(Dir::Left)),
            Key::Named(NamedKey::ArrowRight) => Some(NavKey::Arrow(Dir::Right)),
            Key::Named(NamedKey::Tab) if mods.shift_key() => Some(NavKey::ShiftTab),
            Key::Named(NamedKey::Tab) => Some(NavKey::Tab),
            Key::Named(NamedKey::Enter | NamedKey::Space) => Some(NavKey::Enter),
            _ => None,
        };
        if let (Some(k), true) = (nav, plain) {
            self.shell.nav_key(k, true, now);
            self.shell.nav_key(k, false, now);
            return;
        }
        let ctrl_or_cmd = mods.control_key() || mods.super_key();
        let cmd = match key {
            Key::Named(NamedKey::Escape | NamedKey::Backspace | NamedKey::BrowserBack) => {
                Some(Command::Back)
            }
            Key::Named(NamedKey::ArrowLeft) if mods.alt_key() => Some(Command::Back),
            Key::Named(NamedKey::ArrowRight | NamedKey::BrowserForward)
                if mods.alt_key() || !ctrl_or_cmd =>
            {
                Some(Command::Forward)
            }
            Key::Named(
                n @ (NamedKey::Home | NamedKey::End | NamedKey::PageUp | NamedKey::PageDown),
            ) if !ctrl_or_cmd && !mods.alt_key() => Some(Command::Scroll(match n {
                NamedKey::Home => ScrollKey::Home,
                NamedKey::End => ScrollKey::End,
                NamedKey::PageUp => ScrollKey::PageUp,
                _ => ScrollKey::PageDown,
            })),
            _ => None,
        };
        if let Some(c) = cmd {
            self.shell.command(c, now);
        }
    }

    /// Which screen is in front, for the coverage report.
    fn seen(&mut self) -> String {
        let player = self.shell.player_open();
        let Some(s) = self.shell.suite_mut() else {
            return "none".into();
        };
        if player {
            return "player".into();
        }
        let top = s.top_kind().unwrap_or("-");
        let form = s.form_open().map_or(String::new(), |f| format!("+{f}"));
        format!("t{}:{top}{form}", s.tab())
    }

    fn apply(&mut self, s: &Step) {
        self.now = (self.now + s.dt).max(0.0);
        let now = self.now;
        match &s.ev {
            Ev::Move(x, y) => {
                let p = self.pt(*x, *y);
                self.shell.cursor_moved(p, now);
                self.shell.cursor_kind();
            }
            Ev::MoveToNode(f) => {
                if let Some(p) = self.node_px(*f) {
                    self.shell.cursor_moved(p, now);
                    self.shell.cursor_kind();
                }
            }
            Ev::Press => self.shell.primary_button(true, now),
            Ev::Release => self.shell.primary_button(false, now),
            Ev::Click => {
                self.shell.primary_button(true, now);
                self.shell.primary_button(false, now + 30.0);
            }
            Ev::ClickNode(f) => {
                if let Some(p) = self.node_px(*f) {
                    self.shell.cursor_moved(p, now);
                    self.shell.primary_button(true, now);
                    self.shell.primary_button(false, now + 30.0);
                }
            }
            Ev::RightClick => {
                self.shell.secondary_button(now);
            }
            Ev::RightClickNode(f) => {
                if let Some(p) = self.node_px(*f) {
                    self.shell.cursor_moved(p, now);
                    self.shell.secondary_button(now);
                }
            }
            Ev::CursorLeft => self.shell.cursor_left(now),
            Ev::Wheel(d, ph) => self.shell.wheel(*d, *ph, now),
            Ev::Nav(k, down) => {
                self.shell.nav_key(*k, *down, now);
            }
            Ev::Command(c) => {
                self.shell.command(c.clone(), now);
            }
            Ev::Key(k, m) => self.key(k, *m),
            Ev::Typed(t) => {
                self.shell.text_key(t);
            }
            Ev::Ime(e) => {
                self.shell.ime(e);
            }
            Ev::Edit(e) => {
                self.shell.text_event(e);
            }
            Ev::Finger(phase, x, y) => {
                let p = self.pt(*x, *y);
                self.shell.finger(*phase, p, now);
            }
            Ev::Resize(w, h, sc) => {
                self.size_px = (*w, *h);
                self.scale = *sc;
                self.shell.resize(self.size_px, self.scale);
            }
            Ev::Wait => {}
        }
        // Layout + draw, then what a screen reader and the input method read after it.
        let (list, _more) = self.shell.frame(now);
        std::hint::black_box(list.quads().len());
        if let Some(g) = &mut self.gpu {
            g.draw(&self.shell, &list, (self.size_px.0, self.size_px.1));
        }
        self.pressed_count += 1;
        if self.pressed_count.is_multiple_of(3) {
            let (title, nodes) = self.shell.a11y_nodes();
            let built = swiftly_desktop::a11y_bridge::build(title, &nodes, self.scale);
            std::hint::black_box(built.centres.len());
        }
        if let Some(a) = self.shell.ime_state().area {
            assert!(a.iter().all(|v| v.is_finite()), "input method area {a:?}");
        }
        // The player's fullscreen button asks the window; the window tells back.
        self.shell.set_fullscreen(self.fullscreen);
        if self.shell.take_fullscreen_request() {
            self.fullscreen = !self.fullscreen;
        }
        let _ = self.shell.cursor_hidden();
        let seen = self.seen();
        COVERAGE
            .lock()
            .unwrap()
            .entry(seen)
            .and_modify(|n| *n += 1)
            .or_insert(1);
    }
}

fn play(idiom: Idiom, seed: u64, steps: &[Step], watch: &Watch) -> Result<(), String> {
    let size = match idiom {
        Idiom::Phone => (390, 844),
        Idiom::Tv => (1920, 1080),
        _ => (1280, 800),
    };
    let mut rig = Rig::new(idiom, size, 1.0);
    for (i, s) in steps.iter().enumerate() {
        watch.begin(format!("seed {seed} {idiom:?} step {i}: {:?}", s.ev));
        let r = catch_unwind(AssertUnwindSafe(|| rig.apply(s)));
        watch.end();
        if let Err(e) = r {
            let msg = e
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| e.downcast_ref::<&str>().map(|s| (*s).to_owned()))
                .unwrap_or_default();
            return Err(format!("panic at step {i} ({:?}): {msg}", s.ev));
        }
    }
    Ok(())
}

/// Aborts the process with the seed when one step takes too long.
struct Watch {
    slots: Arc<Mutex<HashMap<std::thread::ThreadId, (Instant, String)>>>,
}

impl Watch {
    fn new() -> Watch {
        let slots: Arc<Mutex<HashMap<std::thread::ThreadId, (Instant, String)>>> = Arc::default();
        let dog = Arc::clone(&slots);
        let limit = Duration::from_secs(
            std::env::var("SWIFTLY_FUZZ_HANG_S")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(40),
        );
        std::thread::spawn(move || {
            loop {
                std::thread::sleep(Duration::from_secs(1));
                for (at, what) in dog.lock().unwrap().values() {
                    if at.elapsed() > limit {
                        eprintln!("HANG: no progress for {limit:?} in {what}");
                        std::process::abort();
                    }
                }
            }
        });
        Watch { slots }
    }
    fn begin(&self, what: String) {
        self.slots
            .lock()
            .unwrap()
            .insert(std::thread::current().id(), (Instant::now(), what));
    }
    fn end(&self) {
        self.slots
            .lock()
            .unwrap()
            .remove(&std::thread::current().id());
    }
}

/// Removes chunks of the list while the run still fails.
fn shrink(idiom: Idiom, seed: u64, mut steps: Vec<Step>, watch: &Watch) -> Vec<Step> {
    let mut chunk = steps.len() / 2;
    while chunk >= 1 {
        let mut i = 0;
        while i < steps.len() {
            let mut cut = steps.clone();
            cut.drain(i..(i + chunk).min(steps.len()));
            if !cut.is_empty() && play(idiom, seed, &cut, watch).is_err() {
                steps = cut;
            } else {
                i += chunk;
            }
        }
        chunk /= 2;
    }
    steps
}

fn env_num(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn fuzz(idiom: Idiom) {
    // The default panic hook would interleave messages of the threads; the failure report below carries them.
    let seqs = env_num("SWIFTLY_FUZZ_SEQS", 24);
    let len = env_num("SWIFTLY_FUZZ_LEN", 150) as usize;
    let first = env_num("SWIFTLY_FUZZ_SEED", 1);
    let threads = env_num("SWIFTLY_FUZZ_THREADS", 4) as usize;
    let extreme = std::env::var_os("SWIFTLY_FUZZ_EXTREME").is_some();
    let watch = Arc::new(Watch::new());
    let next = Arc::new(AtomicU64::new(0));
    let done = Arc::new(AtomicUsize::new(0));
    let failures: Arc<Mutex<Vec<String>>> = Arc::default();
    std::thread::scope(|sc| {
        for _ in 0..threads {
            let (watch, next, done, failures) = (
                Arc::clone(&watch),
                Arc::clone(&next),
                Arc::clone(&done),
                Arc::clone(&failures),
            );
            // 1 MiB: the stack of the main thread on Windows, where the winit loop runs.
            std::thread::Builder::new().stack_size(1 << 20).spawn_scoped(sc, move || {
                loop {
                    let n = next.fetch_add(1, Ordering::SeqCst);
                    if n >= seqs {
                        break;
                    }
                    let seed = first + n;
                    let steps = gen_steps(seed, len, extreme);
                    if play(idiom, seed, &steps, &watch).is_err() {
                        let small = shrink(idiom, seed, steps, &watch);
                        let why = play(idiom, seed, &small, &watch).unwrap_err();
                        let mut text = format!("FUZZ FAILURE idiom {idiom:?} seed {seed}: {why}\nshortest list ({} events):\n", small.len());
                        for s in &small {
                            text.push_str(&format!("  +{:.0} ms {:?}\n", s.dt, s.ev));
                        }
                        failures.lock().unwrap().push(text);
                    }
                    done.fetch_add(1, Ordering::SeqCst);
                }
            }).unwrap();
        }
    });
    eprintln!(
        "gesture fuzz {idiom:?}: {} sequences of {len} events from seed {first}",
        done.load(Ordering::SeqCst)
    );
    eprintln!("screens seen (frames): {:?}", COVERAGE.lock().unwrap());
    let f = failures.lock().unwrap();
    assert!(
        f.is_empty(),
        "{} sequences failed:\n{}",
        f.len(),
        f.join("\n")
    );
}

#[test]
fn fuzz_desktop() {
    fuzz(Idiom::Desktop);
}

#[test]
fn fuzz_phone() {
    fuzz(Idiom::Phone);
}

#[test]
fn fuzz_tv() {
    fuzz(Idiom::Tv);
}

#[allow(dead_code)]
fn unused(_: PlayerKey) {}
