//! The platform-free core of the iOS / tvOS shell. The Swift host delivers raw events in points (touches, remote
//! presses, text from the `UITextInput` bridge, insets, appearance) and a frame clock; every call returns a bit set
//! (`FLAG_*`). Only one call goes the other way: the haptics seam, a closure the host installs.

use std::collections::BTreeMap;

use swiftly_desktop::shell::{Command, Ime, Shell};
use swiftly_layout::Size;
use swiftly_render::DrawList;
use swiftly_ui::{Cx, Dir, Env, Idiom, Insets, NavKey};

/// Another frame is wanted (animation, glide, held touch).
pub const FLAG_WANTS_FRAME: i32 = 1;
/// A text field has focus: the host shows the keyboard (hides it when clear).
pub const FLAG_WANTS_TEXT: i32 = 2;
/// The event changed the picture: the host should draw.
pub const FLAG_CHANGED: i32 = 4;
/// `menu` only: nothing consumed it, so the system may handle it (leave the app).
pub const FLAG_BACK_UNHANDLED: i32 = 8;

/// The tvOS canvas in points; every Apple TV is 1920x1080 points whatever its pixel size.
pub const TV_CANVAS: (f32, f32) = (1920.0, 1080.0);

/// Haptic kinds the seam can carry (the Swift side maps them to `UIFeedbackGenerator`s).
pub mod haptic {
    /// Selection changed (`UISelectionFeedbackGenerator`).
    pub const SELECTION: i32 = 1;
    /// Light impact.
    pub const LIGHT: i32 = 2;
    /// Success notification.
    pub const SUCCESS: i32 = 3;
}

/// Which device form the host runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Form {
    /// iPhone (`touch` form, 390x844-class points).
    Phone,
    /// iPad (`touch` form, larger window).
    Pad,
    /// Apple TV (`tv` form, 1920x1080 points, focus engine).
    Tv,
}

impl Form {
    /// From the host's integer (0 phone, 1 pad, 2 tv).
    pub fn from_code(code: i32) -> Option<Form> {
        Some(match code {
            0 => Form::Phone,
            1 => Form::Pad,
            2 => Form::Tv,
            _ => return None,
        })
    }

    fn idiom(self) -> Idiom {
        match self {
            Form::Phone => Idiom::Phone,
            Form::Pad => Idiom::Pad,
            Form::Tv => Idiom::Tv,
        }
    }
}

/// What the keyboard bridge (`UITextInput`) reports.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextKind {
    /// `insertText` with no marked text: final text.
    Commit,
    /// `setMarkedText`: the whole composition run, replacing the previous one.
    Preedit,
    /// `unmarkText` without text, or the field lost the keyboard.
    Cancel,
    /// `deleteBackward`.
    Backspace,
    /// Return key.
    Submit,
    /// The whole field is replaced by this text (tvOS system text entry).
    Replace,
}

impl TextKind {
    /// From the host's integer (0 commit, 1 preedit, 2 cancel, 3 backspace, 4 submit).
    pub fn from_code(code: i32) -> Option<TextKind> {
        Some(match code {
            0 => TextKind::Commit,
            1 => TextKind::Preedit,
            2 => TextKind::Cancel,
            3 => TextKind::Backspace,
            4 => TextKind::Submit,
            5 => TextKind::Replace,
            _ => return None,
        })
    }
}

/// A touch phase.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    /// Finger down.
    Down,
    /// Finger moved.
    Move,
    /// Finger up.
    Up,
    /// Touch cancelled by the system.
    Cancel,
}

impl Phase {
    /// From the host's integer (0 down, 1 move, 2 up, 3 cancel).
    pub fn from_code(code: i32) -> Option<Phase> {
        Some(match code {
            0 => Phase::Down,
            1 => Phase::Move,
            2 => Phase::Up,
            3 => Phase::Cancel,
            _ => return None,
        })
    }
}

/// The Siri Remote / game-pad presses (`UIPress.PressType`) the tv form understands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Press {
    /// Up arrow / swipe up.
    Up,
    /// Down.
    Down,
    /// Left.
    Left,
    /// Right.
    Right,
    /// Select (click).
    Select,
    /// Menu (Back).
    Menu,
    /// Play/Pause.
    PlayPause,
}

impl Press {
    /// From the host's integer (0 up, 1 down, 2 left, 3 right, 4 select, 5 menu, 6 play/pause).
    pub fn from_code(code: i32) -> Option<Press> {
        Some(match code {
            0 => Press::Up,
            1 => Press::Down,
            2 => Press::Left,
            3 => Press::Right,
            4 => Press::Select,
            5 => Press::Menu,
            6 => Press::PlayPause,
            _ => return None,
        })
    }
}

/// Two-finger pinch recogniser (the multi-touch seam). The shared UI has one pinch consumer, the player's fill/fit
/// toggle (`PlayerScreen::pinch`), which the `Suite` does not route yet; the result is kept for it.
#[derive(Debug, Default)]
struct Pinch {
    start: Option<f64>,
    last: f64,
}

fn dist(a: (f32, f32), b: (f32, f32)) -> f64 {
    f64::from((a.0 - b.0).hypot(a.1 - b.1))
}

/// The iOS shell core: one `suite` app per layer.
pub struct Host {
    shell: Shell,
    form: Form,
    scale: f32,
    size_px: (u32, u32),
    safe: Insets,
    reduce_motion: bool,
    dark: bool,
    origin: Option<f64>,
    last_ms: f64,
    /// Active touches by id, in points, in order of arrival.
    touches: BTreeMap<u64, (f32, f32)>,
    order: Vec<u64>,
    /// The touch the shell sees (the first one down); `None` while a pinch owns the fingers.
    primary: Option<u64>,
    pinch: Pinch,
    pinches: Vec<f64>,
    haptics: Option<Box<dyn Fn(i32)>>,
}

/// Where the app draws and at what scale: the touch form fills the layer at the screen scale, the tv form fits the
/// 1920x1080 canvas to the layer width.
pub fn scale_for(form: Form, size_px: (u32, u32), screen_scale: f32) -> f32 {
    if form == Form::Tv {
        (size_px.0 as f32 / TV_CANVAS.0).max(0.01)
    } else {
        screen_scale.max(0.5)
    }
}

impl Host {
    /// A host for a layer of `size_px` at `screen_scale` pixels per point (ignored by the tv form).
    pub fn new(form: Form, size_px: (u32, u32), screen_scale: f32) -> Host {
        Host::with_cx(form, size_px, screen_scale, Cx::new())
    }

    /// As [`Host::new`] with an explicit context (`Cx::deterministic()` for goldens).
    pub fn with_cx(form: Form, size_px: (u32, u32), screen_scale: f32, cx: Cx) -> Host {
        let scale = scale_for(form, size_px, screen_scale);
        Host::around(
            form,
            size_px,
            scale,
            Shell::new_suite(size_px, scale, cx, form.idiom()),
        )
    }

    /// The real app: sign-in, accounts, the network and the player over the platform engine (`live::Core`).
    pub fn new_live(
        form: Form,
        size_px: (u32, u32),
        screen_scale: f32,
        core: std::sync::Arc<swiftly_desktop::live::Core>,
    ) -> Host {
        let scale = scale_for(form, size_px, screen_scale);
        Host::around(
            form,
            size_px,
            scale,
            Shell::new_live(size_px, scale, Cx::new(), form.idiom(), core),
        )
    }

    fn around(form: Form, size_px: (u32, u32), scale: f32, shell: Shell) -> Host {
        Host {
            shell,
            form,
            scale,
            size_px,
            safe: Insets::default(),
            reduce_motion: false,
            dark: true,
            origin: None,
            last_ms: 0.0,
            touches: BTreeMap::new(),
            order: Vec::new(),
            primary: None,
            pinch: Pinch::default(),
            pinches: Vec::new(),
            haptics: None,
        }
    }

    /// The form this host runs.
    pub fn form(&self) -> Form {
        self.form
    }

    /// The shell, for the renderer.
    pub fn shell(&self) -> &Shell {
        &self.shell
    }

    /// Pixels per point in use.
    pub fn scale(&self) -> f32 {
        self.scale
    }

    /// Installs the haptics seam: the host maps `haptic::*` codes to feedback generators.
    pub fn set_haptics(&mut self, f: Box<dyn Fn(i32)>) {
        self.haptics = Some(f);
    }

    fn haptic(&self, kind: i32) {
        if let Some(f) = &self.haptics {
            f(kind);
        }
    }

    fn rel(&mut self, clock_s: f64) -> f64 {
        let ms = clock_s * 1000.0;
        let o = *self.origin.get_or_insert(ms);
        let t = (ms - o).max(self.last_ms);
        self.last_ms = t;
        t
    }

    fn flags(&self, changed: bool) -> i32 {
        let mut f = 0;
        if self.shell.wants_frame() {
            f |= FLAG_WANTS_FRAME;
        }
        if self.shell.wants_text() {
            f |= FLAG_WANTS_TEXT;
        }
        if changed {
            f |= FLAG_CHANGED;
        }
        f
    }

    /// The environment of the suite with the appearance settings applied (the shell builds its own without them).
    fn apply_env(&mut self) {
        let size = self.shell.size_pt();
        let mut env = Env::new(Size::new(size.0, size.1), self.scale, self.form.idiom());
        env.safe = self.safe;
        env.reduce_motion = self.reduce_motion;
        if let Some(s) = self.shell.suite_mut() {
            s.set_env(env);
        }
    }

    /// The layer changed size or the screen scale changed.
    pub fn resize(&mut self, size_px: (u32, u32), screen_scale: f32) -> i32 {
        self.size_px = size_px;
        self.scale = scale_for(self.form, size_px, screen_scale);
        self.shell.resize(size_px, self.scale);
        self.shell.set_safe(self.safe, size_px);
        self.apply_env();
        self.flags(true)
    }

    /// Safe-area insets in points (top, left, bottom, right). The tv form ignores them: the 1920x1080 canvas is the
    /// title-safe design already.
    pub fn set_insets(&mut self, top: f32, left: f32, bottom: f32, right: f32) -> i32 {
        if self.form == Form::Tv {
            return self.flags(false);
        }
        self.safe = Insets {
            top,
            leading: left,
            bottom,
            trailing: right,
        };
        self.shell.set_safe(self.safe, self.size_px);
        self.apply_env();
        self.flags(true)
    }

    /// Dark/light and Reduce Motion. The Rust UI has a dark palette only today, so `dark` is recorded for the day a
    /// light palette exists; Reduce Motion reaches `Env.reduce_motion` (curves become linear 0.14 s).
    pub fn set_appearance(&mut self, dark: bool, reduce_motion: bool) -> i32 {
        self.dark = dark;
        self.reduce_motion = reduce_motion;
        self.apply_env();
        self.flags(true)
    }

    /// Whether the system is in dark mode (recorded).
    pub fn dark(&self) -> bool {
        self.dark
    }

    /// Whether Reduce Motion is on.
    pub fn reduce_motion(&self) -> bool {
        self.reduce_motion
    }

    /// One touch event in points; `id` is stable for the life of the finger. The first finger drives the shared
    /// gesture and scroll engine; a second finger cancels it and starts the pinch recogniser.
    pub fn touch(&mut self, id: u64, phase: Phase, x: f32, y: f32, clock_s: f64) -> i32 {
        let now = self.rel(clock_s);
        let s = f64::from(self.scale);
        let px = |p: (f32, f32)| (f64::from(p.0) * s, f64::from(p.1) * s);
        match phase {
            Phase::Down => {
                if self.touches.insert(id, (x, y)).is_none() {
                    self.order.push(id);
                }
                if self.primary.is_none() && self.touches.len() == 1 {
                    self.primary = Some(id);
                    self.shell.finger(0, px((x, y)), now);
                } else if self.touches.len() == 2 {
                    // The second finger takes the gesture away from the scroll engine.
                    if let Some(p) = self.primary.take() {
                        let at = self.touches.get(&p).copied().unwrap_or((x, y));
                        self.shell.finger(3, px(at), now);
                    }
                    if let [a, b] = self.order[..] {
                        let d = dist(self.touches[&a], self.touches[&b]);
                        self.pinch = Pinch {
                            start: Some(d.max(1.0)),
                            last: d.max(1.0),
                        };
                    }
                }
            }
            Phase::Move => {
                if let Some(t) = self.touches.get_mut(&id) {
                    *t = (x, y);
                }
                if self.primary == Some(id) {
                    self.shell.finger(1, px((x, y)), now);
                } else if self.pinch.start.is_some()
                    && let [a, b] = self.order[..]
                {
                    self.pinch.last = dist(self.touches[&a], self.touches[&b]).max(1.0);
                }
            }
            Phase::Up | Phase::Cancel => {
                self.touches.remove(&id);
                self.order.retain(|o| *o != id);
                if self.primary == Some(id) {
                    self.primary = None;
                    let code = if phase == Phase::Up { 2 } else { 3 };
                    self.shell.finger(code, px((x, y)), now);
                }
                if let Some(start) = self.pinch.start
                    && self.touches.len() < 2
                {
                    self.pinch.start = None;
                    if phase == Phase::Up {
                        self.pinches.push(self.pinch.last / start);
                        self.haptic(haptic::SELECTION);
                    }
                }
            }
        }
        self.flags(true)
    }

    /// The magnifications of the pinches that finished since the last call (out > 1, in < 1). The player's
    /// `PlayerScreen::pinch` is the consumer once the `Suite` routes it.
    pub fn take_pinches(&mut self) -> Vec<f64> {
        std::mem::take(&mut self.pinches)
    }

    /// A Siri Remote / game-pad press (tv form). Select and arrows go to the focus engine, Menu is Back.
    pub fn press(&mut self, press: Press, down: bool, clock_s: f64) -> i32 {
        let now = self.rel(clock_s);
        let nav = match press {
            Press::Up => NavKey::Arrow(Dir::Up),
            Press::Down => NavKey::Arrow(Dir::Down),
            Press::Left => NavKey::Arrow(Dir::Left),
            Press::Right => NavKey::Arrow(Dir::Right),
            Press::Select | Press::PlayPause => NavKey::Enter,
            Press::Menu => {
                if !down {
                    return self.flags(false);
                }
                let handled = self.shell.command(Command::Back, now);
                return self.flags(handled) | if handled { 0 } else { FLAG_BACK_UNHANDLED };
            }
        };
        let changed = self.shell.nav_key(nav, down, now);
        self.flags(changed)
    }

    /// Text from the keyboard bridge.
    pub fn text(&mut self, kind: TextKind, text: &str) -> i32 {
        let used = match kind {
            TextKind::Commit => self.shell.ime(&Ime::Commit(text.to_owned())),
            TextKind::Preedit => self.shell.ime(&Ime::Preedit(
                text.to_owned(),
                Some((text.len(), text.len())),
            )),
            TextKind::Cancel => self.shell.ime(&Ime::Cancel),
            TextKind::Backspace => self.shell.text_key("\u{8}"),
            TextKind::Submit => self.shell.text_key("\n"),
            TextKind::Replace => {
                // Select everything, then the commit overwrites the selection.
                let all = self
                    .shell
                    .text_event(&swiftly_text::TextInputEvent::SelectAll);
                let put = if text.is_empty() {
                    self.shell.text_key("\u{8}")
                } else {
                    self.shell.ime(&Ime::Commit(text.to_owned()))
                };
                all || put
            }
        };
        self.flags(used)
    }

    /// One frame at the display-link time `clock_s`: the quads and whether another frame is wanted.
    pub fn frame(&mut self, clock_s: f64) -> (DrawList, bool) {
        let now = self.rel(clock_s);
        self.shell.frame(now)
    }

    /// The flags after a frame.
    pub fn frame_flags(&self, more: bool) -> i32 {
        self.flags(false) | if more { FLAG_WANTS_FRAME } else { 0 }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::rc::Rc;

    fn frames(h: &mut Host, from_s: f64, n: u32) -> bool {
        let mut more = true;
        for i in 0..n {
            more = h.frame(from_s + f64::from(i) / 120.0).1;
        }
        more
    }

    #[test]
    fn forms_use_their_points() {
        let p = Host::new(Form::Phone, (1170, 2532), 3.0);
        assert_eq!(p.shell().size_pt(), (390.0, 844.0));
        // The tv form fits 1920x1080 points to any layer of 16:9, 4K included.
        for px in [(1920, 1080), (3840, 2160)] {
            let t = Host::new(Form::Tv, px, 2.0);
            assert_eq!(t.shell().size_pt(), (1920.0, 1080.0));
        }
    }

    #[test]
    fn scroll_glide_settles_and_menu_leaves_the_first_page() {
        let mut h = Host::new(Form::Phone, (1170, 2532), 3.0);
        frames(&mut h, 0.0, 4);
        h.touch(1, Phase::Down, 190.0, 600.0, 0.1);
        for i in 1..=8 {
            h.touch(
                1,
                Phase::Move,
                190.0,
                600.0 - 20.0 * i as f32,
                0.1 + 0.008 * f64::from(i),
            );
        }
        h.touch(1, Phase::Up, 190.0, 440.0, 0.17);
        assert!(!frames(&mut h, 0.2, 600), "the glide settles");
        let f = h.press(Press::Menu, true, 9.0);
        assert_ne!(
            f & FLAG_BACK_UNHANDLED,
            0,
            "first page: the system may leave"
        );
    }

    #[test]
    fn two_fingers_make_a_pinch_and_cancel_the_scroll() {
        let mut h = Host::new(Form::Phone, (1170, 2532), 3.0);
        let buzz = Rc::new(Cell::new(0));
        let b = Rc::clone(&buzz);
        h.set_haptics(Box::new(move |k| b.set(k)));
        frames(&mut h, 0.0, 4);
        h.touch(1, Phase::Down, 150.0, 400.0, 1.0);
        h.touch(2, Phase::Down, 240.0, 400.0, 1.01);
        h.touch(1, Phase::Move, 100.0, 400.0, 1.1);
        h.touch(2, Phase::Move, 290.0, 400.0, 1.1);
        h.touch(2, Phase::Up, 290.0, 400.0, 1.2);
        h.touch(1, Phase::Up, 100.0, 400.0, 1.21);
        let p = h.take_pinches();
        assert_eq!(p.len(), 1);
        assert!((p[0] - 190.0 / 90.0).abs() < 1e-9, "spread out: {p:?}");
        assert_eq!(buzz.get(), haptic::SELECTION);
        assert!(h.take_pinches().is_empty());
    }

    #[test]
    fn tv_presses_drive_the_focus_engine() {
        let mut h = Host::new(Form::Tv, (1920, 1080), 1.0);
        frames(&mut h, 0.0, 4);
        let f = h.press(Press::Right, true, 1.0);
        assert_ne!(f & FLAG_CHANGED, 0);
        h.press(Press::Right, false, 1.01);
        assert!(!frames(&mut h, 1.2, 240), "the focus move settles");
    }

    #[test]
    fn reduce_motion_and_insets_reach_the_layout() {
        let mut h = Host::new(Form::Phone, (1170, 2532), 3.0);
        h.set_insets(47.0, 0.0, 34.0, 0.0);
        h.set_appearance(false, true);
        assert!(h.reduce_motion());
        assert!(!h.dark());
        // A resize keeps both.
        h.resize((1179, 2556), 3.0);
        assert!(h.reduce_motion());
        let (list, _) = h.frame(0.5);
        assert!(!list.quads().is_empty());
    }

    #[test]
    fn text_kinds_decode() {
        assert_eq!(TextKind::from_code(1), Some(TextKind::Preedit));
        assert_eq!(TextKind::from_code(9), None);
        assert_eq!(Press::from_code(5), Some(Press::Menu));
        assert_eq!(Form::from_code(2), Some(Form::Tv));
    }
}
