//! The platform-independent core of the Android shell. Kotlin delivers raw events (touch, key, text, insets, back) and
//! a frame clock; every call returns a bit set (`FLAG_*`) so the Kotlin side knows whether to ask for another frame
//! and whether to show or hide the soft keyboard. No call goes from Rust back into Kotlin.

use swiftly_desktop::shell::{Command, Shell};
use swiftly_render::DrawList;
use swiftly_text::{EditKey, Mods, TextInputEvent};
use swiftly_ui::{Cx, Dir, Idiom, Insets, NavKey};

/// Another frame is wanted (animation, glide, held touch).
pub const FLAG_WANTS_FRAME: i32 = 1;
/// A text field has focus: Kotlin shows the soft keyboard (hides it when clear).
pub const FLAG_WANTS_TEXT: i32 = 2;
/// The event changed the picture: Kotlin posts a frame.
pub const FLAG_CHANGED: i32 = 4;
/// `back` only: nothing consumed it, so the system may handle it (leave the app).
pub const FLAG_BACK_UNHANDLED: i32 = 8;

/// Android `KeyEvent` codes the shell understands.
pub mod keycode {
    /// `KEYCODE_BACK`.
    pub const BACK: i32 = 4;
    /// `KEYCODE_DPAD_UP`.
    pub const DPAD_UP: i32 = 19;
    /// `KEYCODE_DPAD_DOWN`.
    pub const DPAD_DOWN: i32 = 20;
    /// `KEYCODE_DPAD_LEFT`.
    pub const DPAD_LEFT: i32 = 21;
    /// `KEYCODE_DPAD_RIGHT`.
    pub const DPAD_RIGHT: i32 = 22;
    /// `KEYCODE_DPAD_CENTER`.
    pub const DPAD_CENTER: i32 = 23;
    /// `KEYCODE_TAB`.
    pub const TAB: i32 = 61;
    /// `KEYCODE_SPACE`.
    pub const SPACE: i32 = 62;
    /// `KEYCODE_ENTER`.
    pub const ENTER: i32 = 66;
    /// `KEYCODE_DEL` (Backspace).
    pub const DEL: i32 = 67;
    /// `KEYCODE_BUTTON_A`.
    pub const BUTTON_A: i32 = 96;
    /// `KEYCODE_BUTTON_B`.
    pub const BUTTON_B: i32 = 97;
    /// `KEYCODE_ESCAPE`.
    pub const ESCAPE: i32 = 111;
    /// `KEYCODE_FORWARD_DEL`.
    pub const FORWARD_DEL: i32 = 112;
    /// `KEYCODE_MOVE_HOME`.
    pub const MOVE_HOME: i32 = 122;
    /// `KEYCODE_MOVE_END`.
    pub const MOVE_END: i32 = 123;
    /// `KEYCODE_NUMPAD_ENTER`.
    pub const NUMPAD_ENTER: i32 = 160;
}

/// What the soft keyboard (the Kotlin `InputConnection`) reports.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextKind {
    /// `commitText`: final text.
    Commit,
    /// `setComposingText`: text under composition (the whole run, replacing the previous one).
    Preedit,
    /// `finishComposingText` without text, or the field lost the keyboard.
    Cancel,
    /// `deleteSurroundingText(1, 0)` or a Backspace key.
    Backspace,
    /// The action key (`performEditorAction`: Done, Search, Go).
    Submit,
}

impl TextKind {
    /// From the Kotlin side's integer (0 commit, 1 preedit, 2 cancel, 3 backspace, 4 submit).
    pub fn from_code(code: i32) -> Option<TextKind> {
        Some(match code {
            0 => TextKind::Commit,
            1 => TextKind::Preedit,
            2 => TextKind::Cancel,
            3 => TextKind::Backspace,
            4 => TextKind::Submit,
            _ => return None,
        })
    }
}

/// How a key code acts while no text field has focus.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyAction {
    /// Into the shared focus engine.
    Nav(NavKey),
    /// Back one page.
    Back,
    /// Nothing for this shell.
    None,
}

/// Maps an Android key code to the focus engine (D-pad, remote select, game-pad A) or to Back (Escape, game-pad B;
/// the system Back key is delivered through `back()` by the Kotlin back dispatcher instead).
pub fn map_key(code: i32, shift: bool) -> KeyAction {
    use keycode as k;
    match code {
        k::DPAD_UP => KeyAction::Nav(NavKey::Arrow(Dir::Up)),
        k::DPAD_DOWN => KeyAction::Nav(NavKey::Arrow(Dir::Down)),
        k::DPAD_LEFT => KeyAction::Nav(NavKey::Arrow(Dir::Left)),
        k::DPAD_RIGHT => KeyAction::Nav(NavKey::Arrow(Dir::Right)),
        k::DPAD_CENTER | k::ENTER | k::NUMPAD_ENTER | k::SPACE | k::BUTTON_A => {
            KeyAction::Nav(NavKey::Enter)
        }
        k::TAB if shift => KeyAction::Nav(NavKey::ShiftTab),
        k::TAB => KeyAction::Nav(NavKey::Tab),
        k::ESCAPE | k::BUTTON_B | k::BACK => KeyAction::Back,
        _ => KeyAction::None,
    }
}

/// The TV canvas in tv-points (a 1080p tvOS screen at 1x); the same on every Android TV, whatever its density.
pub const TV_CANVAS: (f32, f32) = (1920.0, 1080.0);

/// Where the app draws on a surface of `size_px`: the pixel rectangle `(x, y, w, h)` and the pixels per point.
/// Phone form: the whole surface at the device density (dp, so 390x844-class layouts at density 3.0). TV form: the
/// 1920x1080 canvas scaled to fit and centred (letterbox when the aspect is not 16:9), ignoring the density.
pub fn stage(tv: bool, size_px: (u32, u32), density: f32) -> ((u32, u32, u32, u32), f32) {
    if !tv {
        return ((0, 0, size_px.0, size_px.1), density);
    }
    let s = (size_px.0 as f32 / TV_CANVAS.0)
        .min(size_px.1 as f32 / TV_CANVAS.1)
        .max(0.01);
    let w = ((TV_CANVAS.0 * s).round() as u32).clamp(1, size_px.0.max(1));
    let h = ((TV_CANVAS.1 * s).round() as u32).clamp(1, size_px.1.max(1));
    (
        (
            (size_px.0.saturating_sub(w)) / 2,
            (size_px.1.saturating_sub(h)) / 2,
            w,
            h,
        ),
        s,
    )
}

/// The Android shell core: one `suite` app per surface.
pub struct Host {
    shell: Shell,
    idiom: Idiom,
    /// The Kotlin clock value of the first event; all times handed to the shell are relative to it.
    origin_ms: Option<f64>,
    last_ms: f64,
    /// The pixel rectangle the app draws into (see [`stage`]).
    stage: (u32, u32, u32, u32),
}

impl Host {
    /// A host for a surface of `size_px` at `density` pixels per dp. `tv` selects the Android TV form (D-pad,
    /// header tabs, focus); otherwise the touch form.
    pub fn new(tv: bool, size_px: (u32, u32), density: f32) -> Host {
        let idiom = if tv { Idiom::Tv } else { Idiom::Phone };
        let (rect, scale) = stage(tv, size_px, density);
        Host {
            shell: Shell::new_suite((rect.2, rect.3), scale, Cx::new(), idiom),
            idiom,
            origin_ms: None,
            last_ms: 0.0,
            stage: rect,
        }
    }

    /// The real app (`swiftly-desktop --app`): sign-in, accounts, the network, the player over Media3.
    pub fn new_live(
        tv: bool,
        size_px: (u32, u32),
        density: f32,
        core: std::sync::Arc<swiftly_desktop::live::Core>,
    ) -> Host {
        let idiom = if tv { Idiom::Tv } else { Idiom::Phone };
        let (rect, scale) = stage(tv, size_px, density);
        Host {
            shell: Shell::new_live((rect.2, rect.3), scale, Cx::new(), idiom, core),
            idiom,
            origin_ms: None,
            last_ms: 0.0,
            stage: rect,
        }
    }

    /// The form this host runs.
    pub fn idiom(&self) -> Idiom {
        self.idiom
    }

    /// The shell, for the renderer.
    pub fn shell(&self) -> &Shell {
        &self.shell
    }

    fn rel(&mut self, clock_ms: f64) -> f64 {
        let o = *self.origin_ms.get_or_insert(clock_ms);
        let t = (clock_ms - o).max(self.last_ms);
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

    /// The surface changed size or the density changed.
    pub fn resize(&mut self, size_px: (u32, u32), density: f32) -> i32 {
        let (rect, scale) = stage(self.idiom == Idiom::Tv, size_px, density);
        self.stage = rect;
        self.shell.resize((rect.2, rect.3), scale);
        self.flags(true)
    }

    /// The pixel rectangle `(x, y, w, h)` of the surface the app draws into; the rest is letterbox.
    pub fn stage_px(&self) -> (u32, u32, u32, u32) {
        self.stage
    }

    /// System bar and cut-out insets in pixels (left, top, right, bottom). The soft keyboard is not an inset yet.
    /// The TV form ignores them: it is the fixed tv-point canvas and Android TV already keeps windows inside overscan.
    pub fn set_insets_px(&mut self, left: f32, top: f32, right: f32, bottom: f32) -> i32 {
        if self.idiom == Idiom::Tv {
            return self.flags(false);
        }
        let s = self.shell.scale().max(0.5);
        let safe = Insets {
            top: top / s,
            leading: left / s,
            bottom: bottom / s,
            trailing: right / s,
        };
        self.shell.set_safe(safe, (self.stage.2, self.stage.3));
        self.flags(true)
    }

    /// The primary pointer. `phase` is 0 down, 1 move, 2 up, 3 cancel; `clock_ms` is the event time.
    pub fn touch(&mut self, phase: u8, x: f32, y: f32, clock_ms: f64) -> i32 {
        let now = self.rel(clock_ms);
        let (ox, oy) = (self.stage.0 as f32, self.stage.1 as f32);
        self.shell
            .finger(phase, (f64::from(x - ox), f64::from(y - oy)), now);
        self.flags(true)
    }

    /// A key event. `unicode` is `KeyEvent.getUnicodeChar()` (0 for none). Text fields take typed characters,
    /// Backspace, Return and caret keys first; otherwise D-pad and friends go to the focus engine.
    pub fn key(
        &mut self,
        code: i32,
        down: bool,
        repeat: bool,
        unicode: u32,
        shift: bool,
        clock_ms: f64,
    ) -> i32 {
        use keycode as k;
        let now = self.rel(clock_ms);
        if down && self.shell.wants_text() {
            let edit = match code {
                k::DPAD_LEFT => Some(EditKey::Left),
                k::DPAD_RIGHT => Some(EditKey::Right),
                k::MOVE_HOME => Some(EditKey::Home),
                k::MOVE_END => Some(EditKey::End),
                k::FORWARD_DEL => Some(EditKey::Delete),
                _ => None,
            };
            if let Some(key) = edit
                && self.shell.text_event(&TextInputEvent::Key(
                    key,
                    Mods {
                        shift,
                        word: false,
                        line: false,
                    },
                ))
            {
                return self.flags(true);
            }
            let text = match code {
                k::DEL => Some("\u{8}".to_owned()),
                k::ENTER | k::NUMPAD_ENTER => Some("\n".to_owned()),
                k::ESCAPE => Some("\u{1b}".to_owned()),
                k::SPACE => Some(" ".to_owned()),
                _ => char::from_u32(unicode)
                    .filter(|c| !c.is_control())
                    .map(String::from),
            };
            if let Some(t) = text
                && self.shell.text_key(&t)
            {
                return self.flags(true);
            }
        }
        match map_key(code, shift) {
            KeyAction::Nav(nav) => {
                // Arrows repeat while held, select does not.
                let changed = if repeat && matches!(nav, NavKey::Enter) {
                    false
                } else {
                    self.shell.nav_key(nav, down, now)
                };
                self.flags(changed)
            }
            KeyAction::Back if down && !repeat && code != k::BACK => {
                let changed = self.shell.command(Command::Back, now);
                self.flags(changed)
            }
            _ => self.flags(false),
        }
    }

    /// The system Back (button, gesture or TV remote). Returns the flags, plus `FLAG_BACK_UNHANDLED` when the app is
    /// at its first page and the system may leave it.
    pub fn back(&mut self, clock_ms: f64) -> i32 {
        let now = self.rel(clock_ms);
        let handled = self.shell.command(Command::Back, now);
        self.flags(handled) | if handled { 0 } else { FLAG_BACK_UNHANDLED }
    }

    /// Text from the soft keyboard (the Kotlin `InputConnection`).
    pub fn text(&mut self, kind: TextKind, text: &str) -> i32 {
        use swiftly_desktop::shell::Ime;
        let used = match kind {
            TextKind::Commit => self.shell.ime(&Ime::Commit(text.to_owned())),
            TextKind::Preedit => self.shell.ime(&Ime::Preedit(
                text.to_owned(),
                Some((text.len(), text.len())),
            )),
            TextKind::Cancel => self.shell.ime(&Ime::Cancel),
            TextKind::Backspace => self.shell.text_key("\u{8}"),
            TextKind::Submit => self.shell.text_key("\n"),
        };
        self.flags(used)
    }

    /// One frame at the Choreographer time `clock_ms`: the quads and whether another frame is wanted.
    pub fn frame(&mut self, clock_ms: f64) -> (DrawList, bool) {
        let now = self.rel(clock_ms);
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

    fn frames(h: &mut Host, from_ms: f64, n: u32) -> bool {
        let mut more = true;
        for i in 0..n {
            more = h.frame(from_ms + f64::from(i) * 16.0).1;
        }
        more
    }

    #[test]
    fn tv_stage_ignores_density_and_letterboxes() {
        for density in [1.0, 1.33, 2.0, 3.0] {
            assert_eq!(
                stage(true, (1920, 1080), density),
                ((0, 0, 1920, 1080), 1.0)
            );
        }
        assert_eq!(stage(true, (3840, 2160), 2.0), ((0, 0, 3840, 2160), 2.0));
        let (rect, s) = stage(true, (1280, 720), 1.0);
        assert_eq!(rect, (0, 0, 1280, 720));
        assert!((s - 2.0 / 3.0).abs() < 1e-6);
        // 21:9 panel: pillarbox, content stays 16:9.
        assert_eq!(stage(true, (2560, 1080), 2.0), ((320, 0, 1920, 1080), 1.0));
        // Phone: dp based, whole surface.
        assert_eq!(stage(false, (1170, 2532), 3.0), ((0, 0, 1170, 2532), 3.0));
        let h = Host::new(true, (1920, 1080), 2.0);
        assert_eq!(h.shell().size_pt(), (1920.0, 1080.0));
        let p = Host::new(false, (1170, 2532), 3.0);
        assert_eq!(p.shell().size_pt(), (390.0, 844.0));
    }

    #[test]
    fn dpad_maps_to_the_focus_engine() {
        assert_eq!(
            map_key(keycode::DPAD_DOWN, false),
            KeyAction::Nav(NavKey::Arrow(Dir::Down))
        );
        assert_eq!(
            map_key(keycode::DPAD_CENTER, false),
            KeyAction::Nav(NavKey::Enter)
        );
        assert_eq!(
            map_key(keycode::TAB, true),
            KeyAction::Nav(NavKey::ShiftTab)
        );
        assert_eq!(map_key(keycode::BUTTON_B, false), KeyAction::Back);
        assert_eq!(map_key(9999, false), KeyAction::None);
    }

    #[test]
    fn text_kinds_decode() {
        assert_eq!(TextKind::from_code(1), Some(TextKind::Preedit));
        assert_eq!(TextKind::from_code(9), None);
    }

    #[test]
    fn tv_form_takes_dpad_and_settles() {
        let mut h = Host::new(true, (1920, 1080), 2.0);
        assert_eq!(h.idiom(), Idiom::Tv);
        frames(&mut h, 1000.0, 4);
        let f = h.key(keycode::DPAD_RIGHT, true, false, 0, false, 1100.0);
        assert_ne!(f & FLAG_CHANGED, 0);
        h.key(keycode::DPAD_RIGHT, false, false, 0, false, 1110.0);
        assert!(!frames(&mut h, 1200.0, 120), "the focus move settles");
    }

    #[test]
    fn touch_form_scrolls_and_backs_out() {
        let mut h = Host::new(false, (1080, 2400), 2.75);
        assert_eq!(h.idiom(), Idiom::Phone);
        frames(&mut h, 0.0, 4);
        h.touch(0, 500.0, 1500.0, 100.0);
        for i in 1..=8 {
            h.touch(1, 500.0, 1500.0 - 60.0 * i as f32, 100.0 + 16.0 * i as f64);
        }
        h.touch(2, 500.0, 1020.0, 240.0);
        frames(&mut h, 260.0, 1);
        assert!(!frames(&mut h, 300.0, 300), "the glide settles");
        // First page: Back is not ours, the system may leave.
        assert_ne!(h.back(5000.0) & FLAG_BACK_UNHANDLED, 0);
    }

    #[test]
    fn insets_reach_the_layout_without_panicking() {
        let mut h = Host::new(false, (1080, 2400), 2.5);
        let f = h.set_insets_px(0.0, 120.0, 0.0, 80.0);
        assert_ne!(f & FLAG_CHANGED, 0);
        let (list, _) = h.frame(10.0);
        assert!(!list.quads().is_empty());
    }
}
