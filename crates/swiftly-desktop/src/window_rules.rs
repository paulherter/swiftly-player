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
        Key::Named(NamedKey::MediaTrackNext) if ctx.player_open => {
            return Some(Action::Player(PlayerKey::Right));
        }
        Key::Named(NamedKey::MediaTrackPrevious) if ctx.player_open => {
            return Some(Action::Player(PlayerKey::Left));
        }
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
        Key::Character(c) => match c.to_lowercase().as_str() {
            m @ ("f" | "t" | "m" | "g" | "h" | "j" | "k" | "+" | "=" | "-") if !repeat => m
                .chars()
                .next()
                .map(|ch| Action::Player(PlayerKey::Char(ch))),
            _ => None,
        },
        _ => None,
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

/// Carries out an action. Returns whether it was used (a redraw is due).
pub fn apply(action: Action, window: &Window, shell: &mut Shell, now: f64) -> bool {
    match action {
        Action::ToggleFullscreen => {
            window.set_fullscreen(toggled(window.fullscreen()));
            true
        }
        Action::LeaveFullscreen => {
            window.set_fullscreen(None);
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
        assert_eq!(
            resolve(&ch("-"), none, false, PLAYER),
            Some(Action::Player(PlayerKey::Char('-')))
        );
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
            Some(Action::Player(PlayerKey::Right))
        );
    }

    #[test]
    fn the_minimum_size_and_theme_are_fixed() {
        assert_eq!(MIN_SIZE, (900.0, 560.0));
        assert_eq!(THEME, Theme::Dark);
    }
}
