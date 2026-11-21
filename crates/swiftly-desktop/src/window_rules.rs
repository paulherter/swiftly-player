//! Window behaviour rules of the desktop shell: which key does what (shortcuts of the Mac app with Ctrl instead of Cmd),
//! fullscreen, the minimum size and the theme. Pure decisions are in [`resolve`] (tested); [`apply`] carries them out.
//!
//! Decisions, with the reasons, are in the comments below.

use crate::player_screen::PlayerKey;
use crate::shell::Shell;
use winit::keyboard::{Key, ModifiersState, NamedKey};
use winit::window::{Fullscreen, Theme, Window};

/// Smallest inner size (points); below this the layouts do not fit.
pub const MIN_SIZE: (f64, f64) = (900.0, 560.0);

/// Whether a press may hand the mouse to the system (a move or resize drag of the window). A script's press is no real
/// button: the system would wait in its own modal loop for a release that never comes, and that loop does not return to
/// the app, not even to quit. So only a real press starts a system drag.
pub fn system_drag_allowed(synthetic: bool) -> bool {
    !synthetic
}

/// Smallest inner size of the phone, pad and tv forms (development windows of the other layouts).
pub const MIN_SIZE_SMALL: (f64, f64) = (360.0, 360.0);

/// The only theme there is. The design has no light variant, so the title bar is told to be dark whatever the system
/// is set to (a light title bar over a dark window looks broken).
pub const THEME: Theme = Theme::Dark;

/// The colour a window shows where the app has drawn nothing (0xRRGGBB): the page ground, `surface.base`. It is taken
/// from the generated token, never typed in, so it cannot stay behind when the ground changes (the Windows window
/// showed the old `#101010` for half a second before the first frame while the ground was already `#0A0A0B`).
pub const GROUND_RGB: u32 = swiftly_design::tokens_generated::color::SURFACE_BASE.rgba8 >> 8;

/// What the app knows that decides a key.
#[derive(Clone, Copy, Debug, Default)]
pub struct Ctx {
    /// The window is fullscreen.
    pub fullscreen: bool,
    /// The player is open.
    pub player_open: bool,
    /// A text field has focus (typing wins over single-key shortcuts).
    pub text_focus: bool,
}

/// A decision of [`resolve`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Action {
    /// Go to a tab (0 Start, 1 Filme, 2 Serien, 3 Suche).
    Tab(usize),
    /// Open the settings page.
    Settings,
    /// A menu-bar command (Ctrl+4 "cmd.watchlist", Ctrl+5, Ctrl+[ and ], Ctrl+Shift+P).
    Command(&'static str),
    /// Enter or leave borderless fullscreen.
    ToggleFullscreen,
    /// Leave fullscreen (Esc).
    LeaveFullscreen,
    /// A key of the player.
    Player(PlayerKey),
}

/// The key that carries shortcuts: Cmd on the Mac, Ctrl elsewhere.
fn shortcut_held(mods: ModifiersState) -> bool {
    if cfg!(target_os = "macos") {
        mods.super_key()
    } else {
        mods.control_key()
    }
}

/// Maps a pressed key to an action, or `None` to let the normal key handling go on.
pub fn resolve(key: &Key, mods: ModifiersState, repeat: bool, ctx: Ctx) -> Option<Action> {
    let plain = !(mods.control_key() || mods.alt_key() || mods.super_key());
    match key {
        Key::Named(NamedKey::F11) if !repeat => return Some(Action::ToggleFullscreen),
        Key::Named(NamedKey::Enter) if mods.alt_key() && !mods.control_key() && !repeat => {
            return Some(Action::ToggleFullscreen);
        }
        // The version list of the Play button on the title page in front (the Mac's "Fassung wählen…", Option-Return
        // there; Alt+Enter is fullscreen here, so the list takes the Menu key, Shift+F10 and Ctrl+Enter). The page answers
        // only when it has versions to offer; otherwise the key goes on.
        Key::Named(NamedKey::ContextMenu) if !repeat && !ctx.player_open && !ctx.text_focus => {
            return Some(Action::Command("cmd.versions"));
        }
        Key::Named(NamedKey::F10)
            if mods.shift_key()
                && !mods.control_key()
                && !mods.alt_key()
                && !repeat
                && !ctx.player_open
                && !ctx.text_focus =>
        {
            return Some(Action::Command("cmd.versions"));
        }
        Key::Named(NamedKey::Enter)
            if mods.control_key()
                && !mods.alt_key()
                && !repeat
                && !ctx.player_open
                && !ctx.text_focus =>
        {
            return Some(Action::Command("cmd.versions"));
        }
        // Esc leaves fullscreen, but only when no player is open (there it steps back in the player) and nothing is typed.
        Key::Named(NamedKey::Escape)
            if plain && ctx.fullscreen && !ctx.player_open && !ctx.text_focus =>
        {
            return Some(Action::LeaveFullscreen);
        }
        // Keyboard and headset media keys (global ones arrive through the system media controls).
        Key::Named(NamedKey::MediaPlayPause | NamedKey::MediaPlay | NamedKey::MediaPause)
            if ctx.player_open && !repeat =>
        {
            return Some(Action::Player(PlayerKey::Space));
        }
        // One rule with the system's media keys (`PlaybackHub`): next is the next episode, previous does nothing.
        Key::Named(NamedKey::MediaTrackNext) if ctx.player_open => {
            return Some(Action::Player(PlayerKey::NextEpisode));
        }
        Key::Named(NamedKey::MediaTrackPrevious) if ctx.player_open => return None,
        _ => {}
    }
    if shortcut_held(mods) && !mods.alt_key() {
        if let Key::Character(c) = key
            && !ctx.player_open
        {
            return match c.to_lowercase().as_str() {
                "1" => Some(Action::Tab(0)),
                "2" => Some(Action::Tab(1)),
                "3" => Some(Action::Tab(2)),
                "f" => Some(Action::Tab(3)),
                "," => Some(Action::Settings),
                "4" => Some(Action::Command("cmd.watchlist")),
                "5" => Some(Action::Command("cmd.downloads")),
                "[" => Some(Action::Command("cmd.back")),
                "]" => Some(Action::Command("cmd.forward")),
                "p" if mods.shift_key() => Some(Action::Command("cmd.profile")),
                // The shortcuts of the tile menu rows; they act only while such a menu is open.
                "d" if !mods.shift_key() => Some(Action::Command("tile.remember")),
                "g" if mods.shift_key() => Some(Action::Command("tile.watched")),
                "i" if !mods.shift_key() => Some(Action::Command("tile.info")),
                _ => None,
            };
        }
        return None;
    }
    if !plain || !ctx.player_open || ctx.text_focus {
        return None;
    }
    // The player's own keys, as on the Mac: Space, arrows, M mute, F fullscreen, G/H subtitle delay, J/K audio delay.
    match key {
        Key::Named(NamedKey::Space) if !repeat => Some(Action::Player(PlayerKey::Space)),
        Key::Named(NamedKey::ArrowLeft) => Some(Action::Player(PlayerKey::Left)),
        Key::Named(NamedKey::ArrowRight) => Some(Action::Player(PlayerKey::Right)),
        Key::Named(NamedKey::ArrowUp) => Some(Action::Player(PlayerKey::Up)),
        Key::Named(NamedKey::ArrowDown) => Some(Action::Player(PlayerKey::Down)),
        // Return starts the offer that is showing (`PlayerScreen.swift:656`).
        Key::Named(NamedKey::Enter) if !repeat => Some(Action::Player(PlayerKey::Enter)),
        Key::Named(NamedKey::ContextMenu) if !repeat => Some(Action::Player(PlayerKey::Context)),
        Key::Character(c) => match c.to_lowercase().as_str() {
            m @ ("f" | "t" | "m" | "g" | "h" | "j" | "k") if !repeat => m
                .chars()
                .next()
                .map(|ch| Action::Player(PlayerKey::Char(ch))),
            _ => None,
        },
        _ => None,
    }
}

/// Breeze draws its window corners with a 5 dp radius plus a soft outline, and KDE offers no way to read what the active
/// decoration uses (no key in `breezerc`, no protocol; KDecoration3 hands the radius to KWin only). So the radius is a
/// per-OS fit of what a real Breeze window shows: the area its top-left corner leaves uncovered (`Werkzeuge/desktop-live/
/// corner-probe.sh`, KCalc in a private nested KWin, Plasma 6.8) equals that of a circle of 8.6 px at scale 1, 11.5 px at
/// 1.5 and 14.0 px at 2, which is `3.2 + 5.4 * scale`; the renderer's soft edge shows about 0.7 px less than its radius
/// (an app corner of 11 px measured 10.7 px by the same area), so the base is 3.9. Windows 11 keeps the radius DWM gives the window (8 px at 100 %,
/// asked for with `CornerPreference::Round`).
pub const WINDOW_CORNER_BASE_PX: f32 = 3.9;
/// The part of the corner radius that grows with the scale, in points (see [`WINDOW_CORNER_BASE_PX`]).
pub const WINDOW_CORNER_PT: f32 = 5.4;

/// The corner radius in device pixels for a window at `scale`: none when it fills the screen (fullscreen or maximised) or
/// the platform draws the corners itself (anything but Linux).
pub fn window_corner_px(scale: f32, fullscreen: bool, maximized: bool) -> f32 {
    if cfg!(target_os = "linux") && !fullscreen && !maximized {
        (WINDOW_CORNER_BASE_PX + WINDOW_CORNER_PT * scale).round()
    } else {
        0.0
    }
}

/// Whether a `Resized` event needs no frame of its own: the window is already at the size and scale of the last frame
/// (an earlier event of the same drag was drawn for it). A scale change always draws.
pub fn resize_is_stale(
    window_px: (u32, u32),
    drawn_px: (u32, u32),
    scale: f32,
    drawn_scale: f32,
    scale_event: bool,
) -> bool {
    !scale_event && window_px == drawn_px && (scale - drawn_scale).abs() <= f32::EPSILON
}

/// Whether a `Resized` event draws its frame inside the event (`true`) or only asks for a redraw (`false`). One rule for every OS.
/// A drag makes one event per step, and every step would refit the swap chain (a new one per size; 0.6 ms on Linux, 18-80 ms on
/// Windows) and queue a frame, so the frames fall behind the pointer. The frame goes through `RedrawRequested` instead, which
/// draws the newest size once: Linux waits there for the compositor's frame callback (one frame in flight), Windows gets it
/// from the `WM_PAINT` the resize itself queues, inside the system's size loop. A scale change goes the same way (the window is
/// resized with it, and the redraw fits surface and layout to scale and size together). `inline` is the `SWIFTLY_RESIZE_INLINE`
/// switch that brings the old frame-per-event behaviour back, to measure against: the only inline draw path left.
pub fn resize_draws_in_event(inline: bool) -> bool {
    inline
}

/// A redraw that was asked for by a resize but has not run yet, and the fallback for the case that it never runs (a frame
/// callback the compositor never answers, a `WM_PAINT` the size loop swallowed): after `RESIZE_FALLBACK_MS` the app draws once
/// by itself. During a drag every redraw clears it within a frame, so it only fires when a redraw was really lost.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ResizeFallback {
    asked_at: Option<f64>,
}

/// How long a resize may wait for its `RedrawRequested` before the app draws the newest size itself.
pub const RESIZE_FALLBACK_MS: f64 = 250.0;

impl ResizeFallback {
    /// A resize asked for a redraw at `now` (ms). An earlier ask that is still open keeps its time: the wait counts from the first.
    pub fn asked(&mut self, now: f64) {
        self.asked_at.get_or_insert(now);
    }

    /// A redraw ran (any reason): nothing is pending any more.
    pub fn drawn(&mut self) {
        self.asked_at = None;
    }

    /// Whether the fallback draw is due at `now`; taking it clears the ask, so it fires once per lost redraw.
    pub fn take_due(&mut self, now: f64) -> bool {
        match self.asked_at {
            Some(at) if now - at >= RESIZE_FALLBACK_MS => {
                self.asked_at = None;
                true
            }
            _ => false,
        }
    }

    /// When the event loop must wake for the fallback (ms), if a redraw is pending.
    pub fn wake_at(&self) -> Option<f64> {
        self.asked_at.map(|at| at + RESIZE_FALLBACK_MS)
    }
}

/// The fullscreen state to ask for when toggling from `current`.
pub fn toggled(current: Option<Fullscreen>) -> Option<Fullscreen> {
    if current.is_some() {
        None
    } else {
        Some(Fullscreen::Borderless(None))
    }
}

/// One window call of a fullscreen change.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FullscreenStep {
    /// Leave the maximised state (before going fullscreen).
    Unmaximize,
    /// Borderless fullscreen on the current monitor.
    Enter,
    /// Back to a normal window.
    Leave,
    /// Maximise again (after leaving fullscreen).
    Maximize,
}

/// Whether the window was maximised when it went fullscreen, so leaving can maximise it again.
static MAXIMIZED_BEFORE_FULLSCREEN: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// The window calls that enter (`on`) or leave fullscreen, and whether to remember "was maximised" afterwards.
///
/// On Windows a window that stays maximised under fullscreen keeps `WS_MAXIMIZE`, and its client area is then cut to the
/// monitor's work area (the taskbar stays out of it): 1280x752 content in a 1280x800 window, with a grey strip at the
/// bottom, and leaving fullscreen lands on the full monitor under the taskbar. So fullscreen starts from a normal
/// window and leaving maximises again.
pub fn fullscreen_steps(
    on: bool,
    maximized: bool,
    was_maximized: bool,
    windows: bool,
) -> (Vec<FullscreenStep>, bool) {
    if on {
        if windows && maximized {
            (
                vec![FullscreenStep::Unmaximize, FullscreenStep::Enter],
                true,
            )
        } else {
            (vec![FullscreenStep::Enter], false)
        }
    } else if windows && was_maximized {
        (vec![FullscreenStep::Leave, FullscreenStep::Maximize], false)
    } else {
        (vec![FullscreenStep::Leave], false)
    }
}

/// Enters or leaves fullscreen (the one place that does it; the previous maximised state is restored on the way out).
pub fn set_fullscreen(window: &Window, on: bool) {
    use std::sync::atomic::Ordering::Relaxed;
    if on == window.fullscreen().is_some() {
        return;
    }
    let (steps, remember) = fullscreen_steps(
        on,
        window.is_maximized(),
        MAXIMIZED_BEFORE_FULLSCREEN.load(Relaxed),
        cfg!(target_os = "windows"),
    );
    MAXIMIZED_BEFORE_FULLSCREEN.store(remember, Relaxed);
    for step in steps {
        match step {
            FullscreenStep::Unmaximize => window.set_maximized(false),
            FullscreenStep::Enter => window.set_fullscreen(Some(Fullscreen::Borderless(None))),
            FullscreenStep::Leave => window.set_fullscreen(None),
            FullscreenStep::Maximize => window.set_maximized(true),
        }
    }
}

/// Carries out an action. Returns whether it was used (a redraw is due).
pub fn apply(action: Action, window: &Window, shell: &mut Shell, now: f64) -> bool {
    match action {
        Action::ToggleFullscreen => {
            set_fullscreen(window, window.fullscreen().is_none());
            true
        }
        Action::LeaveFullscreen => {
            set_fullscreen(window, false);
            true
        }
        Action::Tab(n) => shell.goto_tab(n, now),
        Action::Settings => shell.open_settings(now),
        Action::Command(c) => shell.run_command(c, now),
        Action::Player(k) => shell.player_key(k, now),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The window's empty colour is the page ground of `design/tokens.json`, read from the source file itself (not from
    /// the generated copy), and the window code never types a colour in: the old `#101010` stayed in `app.rs` as a literal
    /// when the ground changed to `#0A0A0B`.
    #[test]
    fn the_window_ground_is_the_surface_base_token_everywhere() {
        let json = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../design/tokens.json"
        ))
        .expect("design/tokens.json");
        let at = json.find("\"surface.base\"").expect("surface.base token");
        let rest = &json[at..];
        let dark = rest.find("\"dark\": \"#").expect("dark value") + "\"dark\": \"#".len();
        let hex = u32::from_str_radix(&rest[dark..dark + 6], 16).expect("hex value");
        assert_eq!(
            GROUND_RGB, hex,
            "GROUND_RGB must be surface.base of tokens.json"
        );
        let app = include_str!("app.rs");
        let calls: Vec<&str> = app
            .lines()
            .filter(|l| l.contains("win_backdrop::set("))
            .collect();
        assert!(!calls.is_empty(), "the Windows window sets its ground");
        for l in calls {
            assert!(l.contains("GROUND_RGB"), "a hard-coded window colour: {l}");
        }
    }

    #[test]
    fn the_tile_menu_shortcuts_are_the_macs_with_ctrl() {
        let ctx = Ctx {
            fullscreen: false,
            player_open: false,
            text_focus: false,
        };
        let d = Key::Character("d".into());
        let g = Key::Character("g".into());
        let i = Key::Character("i".into());
        let ctrl = ModifiersState::CONTROL;
        let both = ModifiersState::CONTROL | ModifiersState::SHIFT;
        let command = |a: Option<Action>| match a {
            Some(Action::Command(c)) => Some(c),
            _ => None,
        };
        assert_eq!(
            command(resolve(&d, ctrl, false, ctx)),
            Some("tile.remember")
        );
        assert_eq!(command(resolve(&g, both, false, ctx)), Some("tile.watched"));
        assert_eq!(command(resolve(&i, ctrl, false, ctx)), Some("tile.info"));
        // Without the modifier the letters stay plain keys.
        assert_eq!(resolve(&d, ModifiersState::empty(), false, ctx), None);
        assert_eq!(resolve(&g, ctrl, false, ctx), None);
    }

    #[test]
    fn a_scripted_press_never_starts_a_system_drag() {
        assert!(!super::system_drag_allowed(true));
        assert!(super::system_drag_allowed(false));
    }

    #[test]
    fn fullscreen_from_a_maximised_windows_window_starts_normal_and_leaving_maximises_again() {
        use FullscreenStep::*;
        assert_eq!(
            fullscreen_steps(true, true, false, true),
            (vec![Unmaximize, Enter], true)
        );
        assert_eq!(
            fullscreen_steps(false, false, true, true),
            (vec![Leave, Maximize], false)
        );
        // A normal window, or another platform, only toggles.
        assert_eq!(
            fullscreen_steps(true, false, false, true),
            (vec![Enter], false)
        );
        assert_eq!(
            fullscreen_steps(true, true, false, false),
            (vec![Enter], false)
        );
        assert_eq!(
            fullscreen_steps(false, false, true, false),
            (vec![Leave], false)
        );
    }

    #[test]
    fn a_resize_event_for_a_size_already_drawn_gets_no_frame() {
        assert!(resize_is_stale((1600, 900), (1600, 900), 1.5, 1.5, false));
        assert!(!resize_is_stale((1604, 900), (1600, 900), 1.5, 1.5, false));
        assert!(!resize_is_stale((1600, 900), (1600, 900), 2.0, 1.5, false));
        assert!(!resize_is_stale((1600, 900), (1600, 900), 1.5, 1.5, true));
    }

    #[test]
    fn linux_windows_are_rounded_unless_they_fill_the_screen() {
        let linux = cfg!(target_os = "linux");
        assert_eq!(window_corner_px(1.5, false, false) > 0.0, linux);
        assert_eq!(
            window_corner_px(1.5, false, false),
            if linux { 12.0 } else { 0.0 }
        );
        assert_eq!(window_corner_px(1.5, true, false), 0.0);
        assert_eq!(window_corner_px(1.5, false, true), 0.0);
    }

    /// The Breeze fit is 9 px at scale 1, 12 at 1.5, 15 at 2 (a Breeze window leaves 8.6, 11.5, 14.0 px uncovered). Windows 11 rounds the window itself
    /// (DWM, 8 px at 100 %), so the renderer cuts nothing there; macOS never reaches this code.
    #[test]
    fn the_window_corner_is_the_breeze_radius_on_linux_and_dwm_s_own_on_windows() {
        let (one, one_and_a_half, two) = (
            window_corner_px(1.0, false, false),
            window_corner_px(1.5, false, false),
            window_corner_px(2.0, false, false),
        );
        if cfg!(target_os = "linux") {
            assert_eq!((one, one_and_a_half, two), (9.0, 12.0, 15.0));
        } else {
            assert_eq!((one, one_and_a_half, two), (0.0, 0.0, 0.0));
        }
        assert!((WINDOW_CORNER_PT - 5.4).abs() < f32::EPSILON);
    }

    const PLAYER: Ctx = Ctx {
        fullscreen: false,
        player_open: true,
        text_focus: false,
    };
    const APP: Ctx = Ctx {
        fullscreen: false,
        player_open: false,
        text_focus: false,
    };

    fn ch(s: &str) -> Key {
        Key::Character(s.into())
    }
    fn ctrl() -> ModifiersState {
        if cfg!(target_os = "macos") {
            ModifiersState::SUPER
        } else {
            ModifiersState::CONTROL
        }
    }

    #[test]
    fn fullscreen_on_f11_and_alt_enter() {
        let f11 = Key::Named(NamedKey::F11);
        assert_eq!(
            resolve(&f11, ModifiersState::empty(), false, APP),
            Some(Action::ToggleFullscreen)
        );
        assert_eq!(resolve(&f11, ModifiersState::empty(), true, APP), None);
        let enter = Key::Named(NamedKey::Enter);
        assert_eq!(
            resolve(&enter, ModifiersState::ALT, false, APP),
            Some(Action::ToggleFullscreen)
        );
        assert_eq!(resolve(&enter, ModifiersState::empty(), false, APP), None);
        assert_eq!(toggled(None), Some(Fullscreen::Borderless(None)));
        assert_eq!(toggled(Some(Fullscreen::Borderless(None))), None);
    }

    /// The Play button's version list has a keyboard path that does not collide with Alt+Enter (fullscreen).
    #[test]
    fn the_version_list_opens_on_the_menu_key_shift_f10_and_ctrl_enter() {
        let versions = Some(Action::Command("cmd.versions"));
        let none = ModifiersState::empty();
        assert_eq!(
            resolve(&Key::Named(NamedKey::ContextMenu), none, false, APP),
            versions
        );
        assert_eq!(
            resolve(
                &Key::Named(NamedKey::F10),
                ModifiersState::SHIFT,
                false,
                APP
            ),
            versions
        );
        assert_eq!(resolve(&Key::Named(NamedKey::F10), none, false, APP), None);
        let enter = Key::Named(NamedKey::Enter);
        assert_eq!(
            resolve(&enter, ModifiersState::CONTROL, false, APP),
            versions
        );
        assert_eq!(
            resolve(&enter, ModifiersState::ALT, false, APP),
            Some(Action::ToggleFullscreen),
            "Alt+Enter stays fullscreen"
        );
        // Not while typing and not with a key held down.
        let typing = Ctx {
            text_focus: true,
            ..APP
        };
        assert_eq!(
            resolve(&Key::Named(NamedKey::ContextMenu), none, false, typing),
            None
        );
        assert_eq!(
            resolve(&Key::Named(NamedKey::ContextMenu), none, true, APP),
            None
        );
    }

    #[test]
    fn escape_leaves_fullscreen_only_without_a_player() {
        let esc = Key::Named(NamedKey::Escape);
        let none = ModifiersState::empty();
        let fs = Ctx {
            fullscreen: true,
            ..APP
        };
        assert_eq!(
            resolve(&esc, none, false, fs),
            Some(Action::LeaveFullscreen)
        );
        assert_eq!(
            resolve(
                &esc,
                none,
                false,
                Ctx {
                    player_open: true,
                    ..fs
                }
            ),
            None
        );
        assert_eq!(
            resolve(
                &esc,
                none,
                false,
                Ctx {
                    text_focus: true,
                    ..fs
                }
            ),
            None
        );
        assert_eq!(
            resolve(&esc, none, false, APP),
            None,
            "windowed: Esc is Back, handled elsewhere"
        );
    }

    #[test]
    fn ctrl_shortcuts_of_the_mac_app() {
        assert_eq!(resolve(&ch("1"), ctrl(), false, APP), Some(Action::Tab(0)));
        assert_eq!(resolve(&ch("3"), ctrl(), false, APP), Some(Action::Tab(2)));
        assert_eq!(resolve(&ch("f"), ctrl(), false, APP), Some(Action::Tab(3)));
        assert_eq!(resolve(&ch("F"), ctrl(), false, APP), Some(Action::Tab(3)));
        assert_eq!(
            resolve(&ch(","), ctrl(), false, APP),
            Some(Action::Settings)
        );
        assert_eq!(resolve(&ch("1"), ModifiersState::empty(), false, APP), None);
        assert_eq!(
            resolve(&ch("f"), ctrl(), false, PLAYER),
            None,
            "no tab changes behind the player"
        );
    }

    /// The Mac's menu bar has no counterpart on Windows and Linux, so every item of it must be a key here. The table is
    /// the Mac's "Gehe zu" menu (`SwiftlyApp.swift`, Cmd for Ctrl), item by item.
    #[test]
    fn every_go_to_item_of_the_mac_menu_has_its_ctrl_key() {
        let shift = ctrl() | ModifiersState::SHIFT;
        let table: [(&str, Key, ModifiersState, Action); 10] = [
            ("Start", ch("1"), ctrl(), Action::Tab(0)),
            ("Filme", ch("2"), ctrl(), Action::Tab(1)),
            ("Serien", ch("3"), ctrl(), Action::Tab(2)),
            ("Suche", ch("f"), ctrl(), Action::Tab(3)),
            (
                "Merkliste",
                ch("4"),
                ctrl(),
                Action::Command("cmd.watchlist"),
            ),
            (
                "Downloads",
                ch("5"),
                ctrl(),
                Action::Command("cmd.downloads"),
            ),
            ("Zurück", ch("["), ctrl(), Action::Command("cmd.back")),
            ("Vorwärts", ch("]"), ctrl(), Action::Command("cmd.forward")),
            (
                "Profil wechseln",
                ch("P"),
                shift,
                Action::Command("cmd.profile"),
            ),
            ("Einstellungen", ch(","), ctrl(), Action::Settings),
        ];
        for (item, key, mods, want) in table {
            assert_eq!(resolve(&key, mods, false, APP), Some(want), "{item}");
        }
        // Behind the open player the sections stay where they are, as on the Mac.
        assert_eq!(resolve(&ch("4"), ctrl(), false, PLAYER), None);
        // Cmd-0 only brings back a closed window on the Mac; here closing the window quits, so there is nothing to bring back.
        assert_eq!(resolve(&ch("0"), ctrl(), false, APP), None);
    }

    /// The Mac's "Wiedergabe" menu, item by item: the Mac binds Space, the arrows, T, Up/Down and M as plain keys while
    /// the player is open (the menu only lists them), and Ctrl-Cmd-F for fullscreen; here F, F11 and Alt+Enter.
    #[test]
    fn every_playback_item_of_the_mac_menu_has_its_key() {
        let none = ModifiersState::empty();
        let named = |n| Key::Named(n);
        let table = [
            ("Abspielen/Pause", named(NamedKey::Space), PlayerKey::Space),
            (
                "zurück (own skip length)",
                named(NamedKey::ArrowLeft),
                PlayerKey::Left,
            ),
            (
                "vor (own skip length)",
                named(NamedKey::ArrowRight),
                PlayerKey::Right,
            ),
            ("Ton und Untertitel", ch("t"), PlayerKey::Char('t')),
            ("Vollbild", ch("f"), PlayerKey::Char('f')),
            ("Lauter", named(NamedKey::ArrowUp), PlayerKey::Up),
            ("Leiser", named(NamedKey::ArrowDown), PlayerKey::Down),
            ("Ton aus", ch("m"), PlayerKey::Char('m')),
        ];
        for (item, key, want) in table {
            assert_eq!(
                resolve(&key, none, false, PLAYER),
                Some(Action::Player(want)),
                "{item}"
            );
            assert_eq!(
                resolve(&key, none, false, APP),
                None,
                "{item}: plain keys belong to the page without a player"
            );
            assert_eq!(
                resolve(
                    &key,
                    none,
                    false,
                    Ctx {
                        text_focus: true,
                        ..PLAYER
                    }
                ),
                None,
                "{item}: typing wins"
            );
        }
        // Holding an arrow keeps changing the volume (and skipping), as on the Mac.
        for (key, want) in [
            (NamedKey::ArrowUp, PlayerKey::Up),
            (NamedKey::ArrowDown, PlayerKey::Down),
        ] {
            assert_eq!(
                resolve(&Key::Named(key), none, true, PLAYER),
                Some(Action::Player(want))
            );
        }
        // A held M does not flicker the mute.
        assert_eq!(resolve(&ch("m"), none, true, PLAYER), None);
        // Fullscreen outside the player's own key.
        assert_eq!(
            resolve(&Key::Named(NamedKey::F11), none, false, PLAYER),
            Some(Action::ToggleFullscreen)
        );
        assert_eq!(
            resolve(
                &Key::Named(NamedKey::Enter),
                ModifiersState::ALT,
                false,
                PLAYER
            ),
            Some(Action::ToggleFullscreen)
        );
        // A modifier turns a key into something else (Ctrl+Up is no volume step).
        assert_eq!(
            resolve(&Key::Named(NamedKey::ArrowUp), ctrl(), false, PLAYER),
            None
        );
    }

    #[test]
    fn player_keys_only_while_the_player_is_open_and_nothing_is_typed() {
        let none = ModifiersState::empty();
        let space = Key::Named(NamedKey::Space);
        assert_eq!(
            resolve(&space, none, false, PLAYER),
            Some(Action::Player(PlayerKey::Space))
        );
        assert_eq!(
            resolve(&space, none, true, PLAYER),
            None,
            "holding Space does not flicker pause"
        );
        assert_eq!(resolve(&space, none, false, APP), None);
        assert_eq!(
            resolve(
                &space,
                none,
                false,
                Ctx {
                    text_focus: true,
                    ..PLAYER
                }
            ),
            None
        );
        let right = Key::Named(NamedKey::ArrowRight);
        assert_eq!(
            resolve(&right, none, true, PLAYER),
            Some(Action::Player(PlayerKey::Right)),
            "arrows repeat"
        );
        assert_eq!(
            resolve(&ch("m"), none, false, PLAYER),
            Some(Action::Player(PlayerKey::Char('m')))
        );
        assert_eq!(
            resolve(&ch("F"), none, false, PLAYER),
            Some(Action::Player(PlayerKey::Char('f'))),
            "the player asks for fullscreen itself"
        );
        assert_eq!(
            resolve(&ch("t"), none, false, PLAYER),
            Some(Action::Player(PlayerKey::Char('t')))
        );
        // The Mac's player has no key for "+", "=" or "-".
        assert_eq!(resolve(&ch("-"), none, false, PLAYER), None);
        assert_eq!(resolve(&ch("m"), none, false, APP), None);
    }

    #[test]
    fn media_keys_drive_the_player() {
        let k = Key::Named(NamedKey::MediaPlayPause);
        assert_eq!(
            resolve(&k, ModifiersState::empty(), false, PLAYER),
            Some(Action::Player(PlayerKey::Space))
        );
        assert_eq!(resolve(&k, ModifiersState::empty(), false, APP), None);
        let n = Key::Named(NamedKey::MediaTrackNext);
        assert_eq!(
            resolve(&n, ModifiersState::empty(), false, PLAYER),
            Some(Action::Player(PlayerKey::NextEpisode))
        );
        let p = Key::Named(NamedKey::MediaTrackPrevious);
        assert_eq!(resolve(&p, ModifiersState::empty(), false, PLAYER), None);
        let r = Key::Named(NamedKey::Enter);
        assert_eq!(
            resolve(&r, ModifiersState::empty(), false, PLAYER),
            Some(Action::Player(PlayerKey::Enter))
        );
    }

    #[test]
    fn a_resize_frame_is_drawn_once_per_redraw_on_every_os() {
        // No frame inside the event (a frame per step refits the swap chain and floods the present queue), a scale change
        // included: only the A/B switch for the old behaviour draws there.
        assert!(!resize_draws_in_event(false));
        assert!(resize_draws_in_event(true));
    }

    #[test]
    fn a_lost_redraw_is_drawn_by_the_fallback_once() {
        let mut f = ResizeFallback::default();
        assert_eq!(f.wake_at(), None);
        assert!(!f.take_due(1_000.0), "nothing asked, nothing due");
        f.asked(100.0);
        f.asked(180.0);
        assert_eq!(
            f.wake_at(),
            Some(100.0 + RESIZE_FALLBACK_MS),
            "counts from the first ask"
        );
        assert!(!f.take_due(349.0));
        assert!(f.take_due(350.0));
        assert!(!f.take_due(900.0), "once per lost redraw");
        assert_eq!(f.wake_at(), None);
    }

    #[test]
    fn a_redraw_that_runs_cancels_the_fallback() {
        let mut f = ResizeFallback::default();
        f.asked(0.0);
        f.drawn();
        assert!(!f.take_due(10_000.0));
        // The next resize of the same drag starts a new wait.
        f.asked(10_000.0);
        assert_eq!(f.wake_at(), Some(10_000.0 + RESIZE_FALLBACK_MS));
    }

    #[test]
    fn the_minimum_size_and_theme_are_fixed() {
        assert_eq!(MIN_SIZE, (900.0, 560.0));
        assert_eq!(THEME, Theme::Dark);
    }
}
