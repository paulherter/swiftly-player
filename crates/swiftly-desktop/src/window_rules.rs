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
    /// A menu-bar command (Ctrl+4 "cmd.watchlist", Ctrl+5, Ctrl+[ and ], Ctrl+Shift+P, Ctrl+0).
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
                "0" => Some(Action::Command("cmd.window")),
                "p" if mods.shift_key() => Some(Action::Command("cmd.profile")),
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

/// Corner radius of the window outline in points on Linux, where a frameless window has no corners of its own: the radius
/// of KDE's Breeze window decoration, so the window is as round as every other KDE window (Dolphin, Spotify, Discord) and
/// not as round as a Mac window. Measured on the real KDE desktop at scale 1.5 (alpha of a window capture, circle fit of
/// the four corners): Dolphin 8.6 to 9.5 device pixels = 5.7 to 6.3 pt, against 11.2 to 11.5 for this window at the
/// former 8 pt. Breeze has no setting for it (no key in `breezerc` or the decoration's config), so the measured 6 pt is
/// the value. Windows 11 keeps the radius DWM gives the window (8 px at 100 %, asked for with `CornerPreference::Round`).
pub const WINDOW_CORNER_PT: f32 = 6.0;

/// The corner radius in device pixels for a window at `scale`: none when it fills the screen (fullscreen or maximised) or
/// the platform draws the corners itself (anything but Linux).
pub fn window_corner_px(scale: f32, fullscreen: bool, maximized: bool) -> f32 {
    if cfg!(target_os = "linux") && !fullscreen && !maximized {
        (WINDOW_CORNER_PT * scale).round()
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
            if linux { 9.0 } else { 0.0 }
        );
        assert_eq!(window_corner_px(1.5, true, false), 0.0);
        assert_eq!(window_corner_px(1.5, false, true), 0.0);
    }

    use super::*;

    /// The Breeze radius is 6 pt: 6 px at scale 1, 9 at 1.5, 12 at 2. Windows 11 rounds the window itself (DWM, 8 px at
    /// 100 %), so the renderer cuts nothing there; macOS never reaches this code.
    #[test]
    fn the_window_corner_is_the_breeze_radius_on_linux_and_dwm_s_own_on_windows() {
        let (one, one_and_a_half, two) = (
            window_corner_px(1.0, false, false),
            window_corner_px(1.5, false, false),
            window_corner_px(2.0, false, false),
        );
        if cfg!(target_os = "linux") {
            assert_eq!((one, one_and_a_half, two), (6.0, 9.0, 12.0));
        } else {
            assert_eq!((one, one_and_a_half, two), (0.0, 0.0, 0.0));
        }
        assert!((WINDOW_CORNER_PT - 6.0).abs() < f32::EPSILON);
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
    fn the_minimum_size_and_theme_are_fixed() {
        assert_eq!(MIN_SIZE, (900.0, 560.0));
        assert_eq!(THEME, Theme::Dark);
    }
}
