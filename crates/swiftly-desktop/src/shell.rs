//! The window-independent core of the desktop shell: pointer, wheel and key input in, draw lists out. The winit loop
//! (`app.rs`) and the headless renderer (`headless.rs`) both drive it, so the tests need no window.

use crate::demo::Demo;
use crate::wheel::{Touch, Wheel, WheelDelta, WheelPhase};
use swiftly_layout::Size;
use swiftly_render::{DrawList, Sources};
use swiftly_ui::{Cx, Env, Idiom, tuning};

/// A command from the keyboard or mouse buttons.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Command {
    /// Go back one page (Esc, Backspace, Alt+Left, Cmd+[, mouse back button, the on-screen back button).
    Back,
    /// Quit the app.
    Quit,
    /// Go forward (mouse forward button, Alt+Right). Screens that keep a forward stack take it; the others ignore it.
    Forward,
    /// Home, End, Page up or Page down with no text field focused: scrolls the page in front.
    Scroll(swiftly_ui::shortcuts::ScrollKey),
    /// The Delete key with no text field focused: removes the selected downloads in edit mode.
    Delete,
}

/// An IME event as the shell sees it (mapped from winit's `Ime`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ime {
    /// Composition started or the text under composition changed (text, cursor byte range).
    Preedit(String, Option<(usize, usize)>),
    /// Text was committed.
    Commit(String),
    /// Composition ended without text.
    Cancel,
}

/// The shell core.
pub struct Shell {
    demo: Demo,
    home: Option<crate::home::HomeScreen>,
    suite: Option<crate::suite::Suite>,
    idiom: Idiom,
    wheel: Wheel,
    cursor: (f32, f32),
    finger: Option<u64>,
    pressed: bool,
    scale: f32,
    safe: swiftly_ui::Insets,
    size_pt: (f32, f32),
    last_now: f64,
    auto: Option<crate::autoplay::Autoplay>,
    /// Wheel notches in flight (vertical and horizontal) and where the pointer was.
    notch: (swiftly_motion::NotchGlide, swiftly_motion::NotchGlide),
    /// Until when (ms) line wheel events count as a precision touchpad's.
    precise_until: f64,
    /// Shift is held: a vertical wheel turns sideways (AppKit does this for every app on the Mac).
    shift: bool,
}

fn env_for(size_px: (u32, u32), scale: f32) -> Env {
    env_with(size_px, scale, Idiom::Desktop)
}

fn env_with(size_px: (u32, u32), scale: f32, idiom: Idiom) -> Env {
    let s = scale.max(0.5);
    Env::new(
        Size::new(size_px.0 as f32 / s, size_px.1 as f32 / s),
        s,
        idiom,
    )
}

impl Shell {
    /// A shell for a surface of `size_px` pixels at `scale` pixels per point.
    pub fn new(size_px: (u32, u32), scale: f32, cx: Cx) -> Shell {
        let env = env_for(size_px, scale);
        Shell {
            size_pt: (env.size.w, env.size.h),
            home: None,
            suite: None,
            idiom: Idiom::Desktop,
            demo: Demo::new(env, cx),
            wheel: Wheel::new(tuning::HYSTERESIS_PT),
            cursor: (0.0, 0.0),
            finger: None,
            pressed: false,
            scale,
            safe: swiftly_ui::Insets::default(),
            last_now: 0.0,
            auto: None,
            notch: Default::default(),
            precise_until: f64::NEG_INFINITY,
            shift: false,
        }
    }

    /// A shell showing the Home screen over a scripted server (`--demo home`).
    pub fn new_home(
        size_px: (u32, u32),
        scale: f32,
        cx: Cx,
        scenario: crate::home_data::Scenario,
    ) -> Shell {
        let mut s = Shell::new(size_px, scale, Cx::deterministic());
        s.home = Some(crate::home::HomeScreen::new(
            env_for(size_px, scale),
            cx,
            scenario,
        ));
        s
    }

    /// The whole app (`--demo app`): all tabs and the title pages over the scripted server, in the layout of `idiom`.
    pub fn new_suite(size_px: (u32, u32), scale: f32, cx: Cx, idiom: Idiom) -> Shell {
        Shell::new_suite_state(size_px, scale, cx, idiom, crate::home_data::Scenario::Ready)
    }

    /// The demo app with every screen in the scripted server state `state`.
    pub fn new_suite_state(
        size_px: (u32, u32),
        scale: f32,
        cx: Cx,
        idiom: Idiom,
        state: crate::home_data::Scenario,
    ) -> Shell {
        let mut s = Shell::new(size_px, scale, Cx::deterministic());
        s.idiom = idiom;
        s.suite = Some(crate::suite::Suite::with_state(
            env_with(size_px, scale, idiom),
            cx,
            state,
        ));
        s
    }

    /// The real app: stored account or sign-in flow, real network.
    pub fn new_live(
        size_px: (u32, u32),
        scale: f32,
        cx: Cx,
        idiom: Idiom,
        core: std::sync::Arc<crate::live::Core>,
    ) -> Shell {
        let mut s = Shell::new(size_px, scale, Cx::deterministic());
        s.idiom = idiom;
        s.suite = Some(crate::suite::Suite::new_live(
            env_with(size_px, scale, idiom),
            cx,
            core,
        ));
        s
    }

    /// The app, when `--demo app` runs.
    pub fn suite_mut(&mut self) -> Option<&mut crate::suite::Suite> {
        self.suite.as_mut()
    }

    /// A `swiftly://` link from the OS: routed by the suite of the real app; the demo has nowhere to send it.
    pub fn open_link(&mut self, link: crate::deep_link::DeepLink, now: f64) {
        if let Some(s) = self.suite.as_mut() {
            s.open_link(link, now);
        }
    }

    /// What a screen reader gets for the screen in front: its title and nodes in window points.
    pub fn a11y_nodes(&self) -> (&'static str, Vec<swiftly_ui::a11y::A11yNode>) {
        match (&self.suite, &self.home) {
            (Some(s), _) => s.a11y_nodes(),
            (None, Some(h)) => ("Start", h.a11y_nodes()),
            (None, None) => ("Swiftly", self.demo.a11y_nodes()),
        }
    }

    /// A tap at a window point, as a finger or a click makes it (a screen reader activating a node).
    pub fn tap_at(&mut self, p: (f32, f32), now: f64) {
        let px = (f64::from(p.0 * self.scale), f64::from(p.1 * self.scale));
        self.cursor_moved(px, now);
        self.primary_button(true, now);
        self.primary_button(false, now + 30.0);
    }

    /// Fills the image page (see `Suite::fill_image_page`); how many blocks fitted.
    pub fn fill_image_page(&self) -> usize {
        self.suite.as_ref().map_or(0, |s| s.fill_image_page())
    }

    /// The window fullscreen state, for the player.
    pub fn set_fullscreen(&mut self, on: bool) {
        if let Some(s) = &mut self.suite {
            s.player_set_fullscreen(on);
        }
    }

    /// What the screens asked the host to do outside the window (open an address), once.
    pub fn take_effects(&mut self) -> Vec<crate::effects::Effect> {
        crate::effects::take()
    }

    /// The player asked the window to toggle fullscreen (read once).
    pub fn take_fullscreen_request(&mut self) -> bool {
        self.suite
            .as_mut()
            .is_some_and(|s| s.player_fullscreen_request())
    }

    /// The cursor should be hidden (player with hidden controls).
    pub fn cursor_hidden(&self) -> bool {
        self.suite
            .as_ref()
            .is_some_and(|s| s.player_cursor_hidden())
    }

    /// Whether the player is open over the app.
    pub fn player_open(&self) -> bool {
        self.suite.as_ref().is_some_and(|s| s.player_open())
    }

    /// A key of the player (Space, arrows, letters); `false` when no player is open or the key is not used.
    pub fn player_key(&mut self, key: crate::player_screen::PlayerKey, now: f64) -> bool {
        self.suite.as_mut().is_some_and(|s| s.player_key(key, now))
    }

    /// The window is closing: a running player pauses and reports position and stop first. Whether one was open.
    pub fn window_closing(&mut self, now: f64) -> bool {
        self.suite
            .as_mut()
            .is_some_and(|s| s.player_window_closing(now))
    }

    /// What the system's media widgets show (`None` when no player plays).
    pub fn now_playing(&self) -> Option<crate::media_keys::NowPlaying> {
        self.suite.as_ref().and_then(|s| s.now_playing())
    }

    /// A button of the system's media widgets: an intent for the player.
    pub fn player_intent(&mut self, intent: swiftly_vm::PlayerIntent, now: f64) {
        if let Some(s) = self.suite.as_mut() {
            s.player_intent(intent, now);
        }
    }

    /// Shortcut: switch to a tab (0 Start, 1 Filme, 2 Serien, 3 Suche).
    pub fn goto_tab(&mut self, n: usize, now: f64) -> bool {
        self.suite.as_mut().is_some_and(|s| s.goto_tab(n, now))
    }

    /// Shortcut: open the settings page.
    pub fn open_settings(&mut self, now: f64) -> bool {
        self.suite.as_mut().is_some_and(|s| s.open_settings(now))
    }

    /// Whether typed text goes into a text field right now.
    pub fn wants_text(&self) -> bool {
        self.suite.as_ref().is_some_and(|s| s.wants_text())
    }

    /// The Home screen, when `--demo home` runs.
    pub fn home_mut(&mut self) -> Option<&mut crate::home::HomeScreen> {
        self.home.as_mut()
    }

    /// Renders a list of whichever screen runs with the software renderer.
    pub fn render_software(&self, list: &DrawList) -> swiftly_render::RgbaImage {
        if let Some(s) = &self.suite {
            return s.render_software(list);
        }
        match &self.home {
            Some(h) => h.render_software(list),
            None => self.demo.render_software(list),
        }
    }

    /// Turns on the built-in scripted run (`--autoplay`): wheel flings, a tap that opens a detail page, back.
    pub fn enable_autoplay(&mut self) {
        self.auto = Some(crate::autoplay::Autoplay::new(self.size_pt));
    }

    /// The demo.
    pub fn demo(&self) -> &Demo {
        &self.demo
    }

    /// The demo, for tests and the headless script.
    pub fn demo_mut(&mut self) -> &mut Demo {
        &mut self.demo
    }

    /// Pixels per point.
    pub fn scale(&self) -> f32 {
        self.scale
    }

    /// Window size in points.
    pub fn size_pt(&self) -> (f32, f32) {
        self.size_pt
    }

    /// The surface changed size or scale.
    pub fn resize(&mut self, size_px: (u32, u32), scale: f32) {
        let mut env = env_with(size_px, scale, self.idiom);
        env.safe = self.safe;
        self.scale = scale;
        self.size_pt = (env.size.w, env.size.h);
        self.demo.set_env(env);
        if let Some(s) = &mut self.suite {
            s.set_env(env);
        }
        if let Some(h) = &mut self.home {
            h.set_env(env);
        }
    }

    /// Safe-area insets in points (system bars, cut-outs); applied to the next and every later `resize`.
    pub fn set_safe(&mut self, safe: swiftly_ui::Insets, size_px: (u32, u32)) {
        self.safe = safe;
        self.resize(size_px, self.scale);
    }

    /// The pointer moved to a physical position. A pressed button drags (a scroll or the pan of a back swipe).
    pub fn cursor_moved(&mut self, px: (f64, f64), now: f64) {
        let p = (px.0 as f32 / self.scale, px.1 as f32 / self.scale);
        self.cursor = p;
        self.wheel.set_cursor(p.0, p.1);
        if !self.pressed
            && let Some(s) = &mut self.suite
        {
            s.player_pointer(p.0, p.1, now);
            s.pointer_move(p.0, p.1, now);
        }
        if self.pressed {
            match (&mut self.suite, &mut self.home) {
                (Some(s), _) => s.touch_move(p.0, p.1, now),
                (None, Some(h)) => h.touch_move(p.0, p.1, now),
                (None, None) => self.demo.touch_move(p.0, p.1, now),
            }
        }
    }

    /// The pointer left the window: an open press is cancelled.
    pub fn cursor_left(&mut self, now: f64) {
        if let Some(s) = &mut self.suite {
            s.player_pointer_left(now);
            s.pointer_leave(now);
        }
        if self.pressed {
            self.pressed = false;
            match (&mut self.suite, &mut self.home) {
                (Some(s), _) => s.touch_cancel(now),
                (None, Some(h)) => h.touch_cancel(now),
                (None, None) => self.demo.touch_cancel(now),
            }
        }
    }

    /// The window became the active one: Start fetches rows older than the grace period again.
    pub fn window_activated(&mut self) {
        if let Some(s) = self.suite.as_mut() {
            s.window_activated();
        }
    }

    /// A press whose release the OS swallowed (window drag, focus lost with the button down) is cancelled.
    pub fn release_stale(&mut self, now: f64) {
        if self.pressed && self.finger.is_none() {
            self.pressed = false;
            match (&mut self.suite, &mut self.home) {
                (Some(s), _) => s.touch_cancel(now),
                (None, Some(h)) => h.touch_cancel(now),
                (None, None) => self.demo.touch_cancel(now),
            }
        }
    }

    /// The primary mouse button (or a touch-screen finger) went down or up at the current position.
    pub fn primary_button(&mut self, down: bool, now: f64) {
        let (x, y) = self.cursor;
        if down && self.pressed {
            // A press while one is still open: its release never came (a window drag or a focus change swallowed
            // it). Drop the stale press, or this one is ignored and the pointer stays dead until the next release.
            self.release_stale(now);
        }
        if down && !self.pressed {
            self.pressed = true;
            match (&mut self.suite, &mut self.home) {
                (Some(s), _) => s.touch_down(x, y, now),
                (None, Some(h)) => h.touch_down(x, y, now),
                (None, None) => self.demo.touch_down(x, y, now),
            }
        } else if !down && self.pressed {
            self.pressed = false;
            match (&mut self.suite, &mut self.home) {
                (Some(s), _) => s.touch_up(x, y, now),
                (None, Some(h)) => h.touch_up(x, y, now),
                (None, None) => self.demo.touch_up(x, y, now),
            }
        }
    }

    /// The secondary (right) mouse button went down at the current position: opens a context menu where there is one.
    pub fn secondary_button(&mut self, now: f64) -> bool {
        let (x, y) = self.cursor;
        self.suite
            .as_mut()
            .is_some_and(|s| s.secondary_click(x, y, now))
    }

    /// Runs a menu-bar command or a Ctrl shortcut ("cmd.settings", "cmd.back", ...).
    pub fn run_command(&mut self, cmd: &str, now: f64) -> bool {
        self.suite.as_mut().is_some_and(|s| s.run_command(cmd, now))
    }

    /// The window action the last input asked for (move, minimise, maximise, close).
    pub fn take_window_action(&mut self) -> Option<crate::desk::WinAction> {
        self.suite.as_mut().and_then(|s| s.take_window_action())
    }

    /// The window action the last input asked for, left in place.
    pub fn peek_window_action(&self) -> Option<crate::desk::WinAction> {
        self.suite.as_ref().and_then(|s| s.peek_window_action())
    }

    /// The window is (no longer) maximised.
    pub fn set_maximized(&mut self, on: bool) {
        if let Some(s) = &mut self.suite {
            s.set_maximized(on);
        }
    }

    /// The window should close.
    pub fn quit_asked(&self) -> bool {
        self.suite.as_ref().is_some_and(|s| s.quit_asked())
    }

    /// The cursor the node under the pointer asks for.
    pub fn cursor_kind(&mut self) -> swiftly_ui::Cursor {
        self.suite
            .as_mut()
            .map_or(swiftly_ui::Cursor::Arrow, |s| s.cursor())
    }

    /// A touch-screen finger (single touch). `phase` is 0 down, 1 move, 2 up, 3 cancel.
    pub fn finger(&mut self, phase: u8, px: (f64, f64), now: f64) {
        self.finger_id(0, phase, px, now);
    }

    /// A touch event of finger `id` (winit touch id). The first finger drives the interface (drag scroll with momentum,
    /// taps, rubber band: the same path as a pressed pointer); further fingers are ignored until it lifts, so a resting
    /// palm or a second finger never moves the page. A finger down also catches a running scroll.
    pub fn finger_id(&mut self, id: u64, phase: u8, px: (f64, f64), now: f64) {
        let p = (px.0 as f32 / self.scale, px.1 as f32 / self.scale);
        match phase {
            0 => {
                if self.finger.is_some() {
                    return;
                }
                self.finger = Some(id);
                // A finger has no hover: put the pointer there without hover effects, then press.
                self.cursor = p;
                self.wheel.set_cursor(p.0, p.1);
                self.primary_button(true, now);
            }
            1 if self.finger == Some(id) => self.cursor_moved(px, now),
            2 if self.finger == Some(id) => {
                self.cursor_moved(px, now);
                self.primary_button(false, now);
                self.finger = None;
                if let Some(s) = &mut self.suite {
                    s.pointer_leave(now);
                }
            }
            3 if self.finger == Some(id) => {
                self.finger = None;
                self.cursor_left(now);
            }
            _ => {}
        }
    }

    /// Whether a wheel event would be dropped now because the shell believes a button is held (for the trace).
    pub fn wheel_blocked(&self) -> bool {
        self.pressed
    }

    /// Shift went down or up. With it held, a vertical wheel scrolls sideways: AppKit turns Shift + wheel into a horizontal
    /// scroll for every app, Windows and Linux leave that to the app.
    pub fn set_shift(&mut self, on: bool) {
        self.shift = on;
    }

    /// `delta` as the scroll views get it: with Shift held a vertical wheel (or touchpad) delta becomes the horizontal
    /// one. A delta that already moves sideways stays as it is.
    fn shifted(&self, delta: WheelDelta) -> WheelDelta {
        let (WheelDelta::Lines(x, y) | WheelDelta::Points(x, y)) = delta;
        if !self.shift || y.abs() <= x.abs() {
            return delta;
        }
        match delta {
            WheelDelta::Lines(..) => WheelDelta::Lines(y, 0.0),
            WheelDelta::Points(..) => WheelDelta::Points(y, 0.0),
        }
    }

    /// A wheel or touchpad scroll event. Ignored while a button is held.
    pub fn wheel(&mut self, delta: WheelDelta, phase: Option<WheelPhase>, now: f64) {
        if self.pressed {
            return;
        }
        // Over the player's volume control the wheel sets the volume and nothing else moves.
        let (dy, precise) = match delta {
            WheelDelta::Lines(_, y) => (y, false),
            WheelDelta::Points(_, y) => (y, true),
        };
        let (cx, cy) = self.cursor;
        if let Some(s) = &mut self.suite
            && s.player_wheel(cx, cy, dy, precise, now)
        {
            return;
        }
        let delta = self.shifted(delta);
        // A mouse wheel notch moves the view under the pointer by the OS's profile (Windows 100 px, Linux viewport^(2/3)),
        // clamped, with no rubber band; a touchpad keeps the Mac's momentum model below.
        if let (WheelDelta::Lines(dx, dy), Some(s)) =
            (delta, self.suite.as_mut().filter(|s| s.wheel_direct()))
        {
            let n = swiftly_motion::ScrollTuning::for_os(swiftly_motion::Os::current())
                .notch(f64::from(self.size_pt.1)) as f32;
            // winit: a notch away from the user is positive (content moves down); the engine adds to the offset. A notch is
            // not a jump: it becomes a glide of the OS's smoothing time (never shorter than 150 ms) that new notches retarget.
            let _ = s;
            let ms = swiftly_motion::ScrollTuning::for_os(swiftly_motion::Os::current())
                .notch_smoothing_ms;
            // Windows also delivers a precision touchpad (and its OS inertia) as fractional wheel lines. That stream is
            // already shaped by the OS: apply it 1:1, clamped (no rubber band on Windows or Linux), and never smooth it a second time.
            if self.is_precise(dx, dy, now) {
                self.notch.0.cancel();
                self.notch.1.cancel();
                let (px, py) = (-dx * n, -dy * n);
                swiftly_ui::set_precise_wheel(true);
                let (x, y) = self.cursor;
                if let Some(s) = self.suite.as_mut() {
                    s.wheel_scroll(x, y, px, py, now);
                }
                swiftly_ui::set_precise_wheel(false);
                return;
            }
            if dy != 0.0 {
                self.notch.0.push(f64::from(-dy * n), now, ms);
            }
            if dx != 0.0 {
                self.notch.1.push(f64::from(-dx * n), now, ms);
            }
            return;
        }
        let mut out = Vec::new();
        self.wheel.event(delta, phase, now, &mut out);
        self.apply_wheel(&out, now);
    }

    /// Whether a line-based wheel event belongs to a precision touchpad: a notch of a plain wheel is a whole number of lines
    /// (WHEEL_DELTA 120 = 1.0), a touchpad sends fractions. The OS inertia that follows a swipe can land on whole numbers
    /// now and then, so the mode holds for a short while after the last fraction.
    fn is_precise(&mut self, dx: f32, dy: f32, now: f64) -> bool {
        // A tail below one hundredth of a line rounds to a whole 0 but is no notch either: only a plain wheel sends whole lines.
        let fractional = |v: f32| v != 0.0 && ((v - v.round()).abs() > 0.01 || v.abs() < 0.5);
        if fractional(dx) || fractional(dy) {
            self.precise_until = now + 250.0;
        }
        now < self.precise_until
    }

    fn apply_wheel(&mut self, out: &[Touch], now: f64) {
        for t in out {
            match *t {
                Touch::Down(x, y) => match (&mut self.suite, &mut self.home) {
                    (Some(s), _) => s.touch_down(x, y, now),
                    (None, Some(h)) => h.touch_down(x, y, now),
                    (None, None) => self.demo.touch_down(x, y, now),
                },
                Touch::Move(x, y) => match (&mut self.suite, &mut self.home) {
                    (Some(s), _) => s.touch_move(x, y, now),
                    (None, Some(h)) => h.touch_move(x, y, now),
                    (None, None) => self.demo.touch_move(x, y, now),
                },
                Touch::Up(x, y) => match (&mut self.suite, &mut self.home) {
                    (Some(s), _) => s.touch_up(x, y, now),
                    (None, Some(h)) => h.touch_up(x, y, now),
                    (None, None) => self.demo.touch_up(x, y, now),
                },
            }
        }
    }

    /// A command. Returns whether it changed something (a redraw is due) or, for `Quit`, always `false`.
    pub fn command(&mut self, cmd: Command, now: f64) -> bool {
        match cmd {
            Command::Back => match &mut self.suite {
                Some(s) => s.back(now),
                None => self.demo.back(now),
            },
            Command::Quit => false,
            // Hooks for the pointer/keyboard engine (`swiftly_ui::Ui::scroll_key`, the search screen): the screens that
            // own a `Ui` forward them; until a screen does, they change nothing.
            Command::Forward => self.suite.as_mut().is_some_and(|s| s.forward(now)),
            Command::Scroll(k) => self.suite.as_mut().is_some_and(|s| s.scroll_key(k, now)),
            Command::Delete => self.suite.as_mut().is_some_and(|s| s.delete_key(now)),
        }
    }

    /// A navigation key (arrows, Tab, Enter, Esc) for the shared focus engine. Returns whether anything changed.
    pub fn nav_key(&mut self, key: swiftly_ui::NavKey, down: bool, now: f64) -> bool {
        let out = match (&mut self.suite, &mut self.home) {
            (Some(s), _) => s.nav_key(key, down, now),
            (None, Some(h)) => h.nav_key(key, down, now),
            (None, None) => self.demo.nav_key(key, down, now),
        };
        out != swiftly_ui::Outcome::None
    }

    /// IME event (preedit, commit, cancel) for the field in front. Returns whether the event was used.
    pub fn ime(&mut self, event: &Ime) -> bool {
        use swiftly_text::TextInputEvent as E;
        let ev = match event {
            Ime::Preedit(text, cursor) => E::Preedit {
                text: text.clone(),
                cursor: *cursor,
            },
            Ime::Commit(text) => E::Commit(text.clone()),
            Ime::Cancel => E::CancelComposition,
        };
        self.suite.as_mut().is_some_and(|s| s.text_event(&ev))
    }

    /// What the system's input method needs now (see `crate::ime`).
    pub fn ime_state(&self) -> crate::ime::ImeState {
        self.suite
            .as_ref()
            .map(|s| s.ime_state())
            .unwrap_or_default()
    }

    /// A text-input event for the field in front (caret keys, clipboard, undo, select all). Returns whether a field
    /// used it.
    pub fn text_event(&mut self, ev: &swiftly_text::TextInputEvent) -> bool {
        self.suite.as_mut().is_some_and(|s| s.text_event(ev))
    }

    /// A key for the text field in front (`--demo app`): typed text, `"\u{8}"` for Backspace, `"\n"` for Return,
    /// `"\u{1b}"` for Esc. Returns whether the field used it.
    pub fn text_key(&mut self, text: &str) -> bool {
        let Some(s) = self.suite.as_mut().filter(|s| s.wants_text()) else {
            return false;
        };
        match text {
            "\u{8}" => s.backspace(),
            "\n" => s.submit(),
            "\u{1b}" => {
                s.back(self.last_now);
            }
            t if !t.chars().any(char::is_control) => s.type_text(t),
            _ => return false,
        }
        true
    }

    /// One frame at `now` ms: wheel timers, scripted input, navigation, animations. Returns the quads and whether
    /// another frame is wanted without a new event.
    pub fn frame(&mut self, now: f64) -> (DrawList, bool) {
        self.last_now = now;
        // The wheel glide hands out its share of this frame to the page under the pointer.
        let (dy, dx) = (self.notch.0.take(now), self.notch.1.take(now));
        if dy != 0.0 || dx != 0.0 {
            let (x, y) = self.cursor;
            let moved = self
                .suite
                .as_mut()
                .is_some_and(|s| s.wheel_scroll(x, y, dx as f32, dy as f32, now));
            if !moved {
                self.notch.0.cancel();
                self.notch.1.cancel();
            }
        }
        let mut out = Vec::new();
        self.wheel.tick(now, &mut out);
        self.apply_wheel(&out, now);
        if let Some(mut auto) = self.auto.take() {
            auto.run(self, now);
            self.auto = Some(auto);
        }
        let (list, wants) = match (&mut self.suite, &mut self.home) {
            (Some(s), _) => s.frame(now),
            (None, Some(h)) => h.frame(now),
            (None, None) => self.demo.frame(now),
        };
        let more = wants
            || self.wheel.is_active()
            || self.auto.is_some()
            || self.notch.0.is_active()
            || self.notch.1.is_active();
        (list, more)
    }

    /// The real app is idle: it polls a few times a second instead of every vsync.
    pub fn live_idle(&self, now: f64) -> bool {
        self.suite.as_ref().is_some_and(|s| s.live_idle(now))
            && !self.wheel.is_active()
            && self.auto.is_none()
    }

    /// Whether the shell has work that needs frames although no event came in.
    pub fn wants_frame(&self) -> bool {
        self.suite.as_ref().map_or_else(
            || {
                self.home
                    .as_ref()
                    .map_or_else(|| self.demo.wants_frame(), |h| h.wants_frame())
            },
            |s| s.wants_frame(),
        ) || self.wheel.is_active()
            || self.auto.is_some()
            || self.notch.0.is_active()
            || self.notch.1.is_active()
    }

    /// The video hand-over of the services in front (the host with a GPU layer reads and sets it).
    pub fn video(&self) -> std::rc::Rc<std::cell::RefCell<swiftly_ui::VideoHandoff>> {
        let cx = match (&self.suite, &self.home) {
            (Some(s), _) => s.cx(),
            (None, Some(h)) => h.cx(),
            (None, None) => self.demo.cx(),
        };
        std::rc::Rc::clone(&cx.video)
    }

    /// Runs `f` with the atlas pages of the glyphs and images (for the GPU renderer).
    pub fn with_sources<R>(&self, f: impl FnOnce(&Sources) -> R) -> R {
        let cx = match (&self.suite, &self.home) {
            (Some(s), _) => s.cx(),
            (None, Some(h)) => h.cx(),
            (None, None) => self.demo.cx(),
        };
        let ts = cx.text.borrow();
        let im = cx.images.borrow();
        f(&Sources {
            glyphs: Some(&ts.atlas),
            images: Some(&im.page),
        })
    }
}
