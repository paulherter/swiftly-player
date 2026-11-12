//! Keyboard: the shortcut registry (Cmd on the Mac, Ctrl on Windows and Linux), mnemonics for the menu bar, and the
//! platform-standard navigation keys (Esc and the mouse Back button go back, Home/End/PageUp/PageDown scroll, typing starts
//! a search).
//!
//! **Menu bar decision: in-window.** A native bar needs `muda`; on Linux muda is GTK 3 only (a second toolkit next to winit
//! and wgpu, and it cannot draw on a Wayland surface we own), on Windows it is an `HMENU` that eats Alt and F10 before
//! the app sees them and cannot be styled to the Mac's flat look, and neither is testable headless. So the engine draws
//! the bar itself ([`MenuBar`]) as a row of titles that open the same popover panels as every other menu
//! (`crate::popover`), driven by the same registry. The Mac build keeps AppKit's own bar and uses this data to fill it.

use swiftly_motion::Os;

/// A key without its modifiers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Key {
    /// A letter, digit or sign, lower case.
    Char(char),
    /// F1 to F12.
    F(u8),
    /// Return.
    Enter,
    /// Esc.
    Escape,
    /// Backspace.
    Backspace,
    /// Delete.
    Delete,
    /// Tab.
    Tab,
    /// Space bar.
    Space,
    /// Left arrow.
    Left,
    /// Right arrow.
    Right,
    /// Up arrow.
    Up,
    /// Down arrow.
    Down,
    /// Home.
    Home,
    /// End.
    End,
    /// Page up.
    PageUp,
    /// Page down.
    PageDown,
    /// The browser/mouse Back button.
    MouseBack,
    /// The browser/mouse Forward button.
    MouseForward,
}

/// A key press with the modifiers that were down.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Chord {
    /// The key.
    pub key: Key,
    /// Control.
    pub ctrl: bool,
    /// Windows key / Cmd.
    pub meta: bool,
    /// Shift.
    pub shift: bool,
    /// Alt / Option.
    pub alt: bool,
}

impl Chord {
    /// A key with no modifiers.
    pub fn plain(key: Key) -> Chord {
        Chord {
            key,
            ctrl: false,
            meta: false,
            shift: false,
            alt: false,
        }
    }
}

/// A shortcut as declared: `primary` is Cmd on the Mac and Ctrl elsewhere.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Shortcut {
    /// The key.
    pub key: Key,
    /// Cmd on macOS, Ctrl on Windows and Linux.
    pub primary: bool,
    /// Shift.
    pub shift: bool,
    /// Alt / Option.
    pub alt: bool,
}

impl Shortcut {
    /// Parses "Cmd+Shift+G", "Ctrl+I", "Alt+Left", "Esc", "F5", "Return": `Cmd`, `Ctrl` and `Primary` all mean the primary
    /// modifier (the Mac code says Cmd, the Windows convention says Ctrl; one declaration serves both).
    pub fn parse(s: &str) -> Option<Shortcut> {
        let mut sc = Shortcut {
            key: Key::Escape,
            primary: false,
            shift: false,
            alt: false,
        };
        let mut key = None;
        for part in s.split('+') {
            match part.trim().to_lowercase().as_str() {
                "cmd" | "ctrl" | "primary" | "command" | "control" => sc.primary = true,
                "shift" => sc.shift = true,
                "alt" | "option" | "opt" => sc.alt = true,
                other => key = Some(parse_key(other)?),
            }
        }
        sc.key = key?;
        Some(sc)
    }

    /// Whether `chord` triggers this shortcut on `os`.
    pub fn matches(&self, chord: &Chord, os: Os) -> bool {
        let (primary_down, other_down) = if os == Os::MacOs {
            (chord.meta, chord.ctrl)
        } else {
            (chord.ctrl, chord.meta)
        };
        chord.key == self.key
            && primary_down == self.primary
            && !other_down
            && chord.shift == self.shift
            && chord.alt == self.alt
    }

    /// The text of the shortcut for a menu: "Ctrl+Shift+G" on Windows and Linux, "\u{21E7}\u{2318}G" on the Mac.
    pub fn display(&self, os: Os) -> String {
        let name = key_name(self.key);
        if os == Os::MacOs {
            let mut s = String::new();
            if self.alt {
                s.push('\u{2325}');
            }
            if self.shift {
                s.push('\u{21E7}');
            }
            if self.primary {
                s.push('\u{2318}');
            }
            s + &name
        } else {
            let mut parts = Vec::new();
            if self.primary {
                parts.push("Ctrl".to_owned());
            }
            if self.alt {
                parts.push("Alt".to_owned());
            }
            if self.shift {
                parts.push("Shift".to_owned());
            }
            parts.push(name);
            parts.join("+")
        }
    }
}

fn parse_key(s: &str) -> Option<Key> {
    Some(match s {
        "esc" | "escape" => Key::Escape,
        "return" | "enter" => Key::Enter,
        "backspace" => Key::Backspace,
        "delete" | "del" => Key::Delete,
        "tab" => Key::Tab,
        "space" => Key::Space,
        "left" => Key::Left,
        "right" => Key::Right,
        "up" => Key::Up,
        "down" => Key::Down,
        "home" => Key::Home,
        "end" => Key::End,
        "pageup" => Key::PageUp,
        "pagedown" => Key::PageDown,
        f if f.len() > 1 && f.starts_with('f') && f[1..].chars().all(|c| c.is_ascii_digit()) => {
            Key::F(f[1..].parse().ok()?)
        }
        c if c.chars().count() == 1 => Key::Char(c.chars().next()?),
        _ => return None,
    })
}

fn key_name(k: Key) -> String {
    match k {
        Key::Char(c) => c.to_uppercase().to_string(),
        Key::F(n) => format!("F{n}"),
        Key::Enter => "Return".into(),
        Key::Escape => "Esc".into(),
        Key::Backspace => "Backspace".into(),
        Key::Delete => "Delete".into(),
        Key::Tab => "Tab".into(),
        Key::Space => "Space".into(),
        Key::Left => "Left".into(),
        Key::Right => "Right".into(),
        Key::Up => "Up".into(),
        Key::Down => "Down".into(),
        Key::Home => "Home".into(),
        Key::End => "End".into(),
        Key::PageUp => "PgUp".into(),
        Key::PageDown => "PgDn".into(),
        Key::MouseBack => "Back".into(),
        Key::MouseForward => "Forward".into(),
    }
}

/// The shortcut table of a screen or the app: shortcut to a caller's command `A`.
#[derive(Clone, Debug)]
pub struct Registry<A> {
    entries: Vec<(Shortcut, A)>,
}

impl<A> Default for Registry<A> {
    fn default() -> Self {
        Registry {
            entries: Vec::new(),
        }
    }
}

impl<A: Clone + PartialEq> Registry<A> {
    /// An empty registry.
    pub fn new() -> Registry<A> {
        Registry::default()
    }
    /// Adds `shortcut` for `command`. Returns false (and adds nothing) when the shortcut is taken by another command.
    pub fn add(&mut self, shortcut: &str, command: A) -> bool {
        let Some(sc) = Shortcut::parse(shortcut) else {
            return false;
        };
        if self.entries.iter().any(|(s, a)| *s == sc && *a != command) {
            return false;
        }
        self.entries.push((sc, command));
        true
    }
    /// The command a key press triggers on `os`.
    pub fn lookup(&self, chord: &Chord, os: Os) -> Option<&A> {
        self.entries
            .iter()
            .find(|(s, _)| s.matches(chord, os))
            .map(|(_, a)| a)
    }
    /// The display text of the shortcut of `command` on `os`, for menus.
    pub fn display_for(&self, command: &A, os: Os) -> Option<String> {
        self.entries
            .iter()
            .find(|(_, a)| a == command)
            .map(|(s, _)| s.display(os))
    }
}

/// A scrolling key of the page.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrollKey {
    /// To the top.
    Home,
    /// To the end.
    End,
    /// One page up.
    PageUp,
    /// One page down.
    PageDown,
    /// One line up (arrow with no focus target).
    LineUp,
    /// One line down.
    LineDown,
}

/// What a key press means for the app, before any screen shortcut.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Intent {
    /// Go back one page: Esc, Backspace, the mouse Back button, Alt+Left (Windows, Linux), Cmd+[ (Mac).
    Back,
    /// Go forward: the mouse Forward button, Alt+Right, Cmd+].
    Forward,
    /// Scroll the page.
    Scroll(ScrollKey),
    /// Typing with nothing focused starts a search with this text.
    TypeToSearch(String),
    /// Quit: Ctrl+Q / Cmd+Q, Alt+F4 is the window manager's.
    Quit,
}

/// The platform-standard meaning of `chord`. `typing_target` is true while a text field has focus (then plain characters
/// belong to it and are never type-to-search); `text` is the typed text of the event, if any.
pub fn intent(chord: &Chord, text: Option<&str>, typing_target: bool, os: Os) -> Option<Intent> {
    let primary = if os == Os::MacOs {
        chord.meta
    } else {
        chord.ctrl
    };
    let nothing = !chord.ctrl && !chord.meta && !chord.alt;
    match chord.key {
        Key::MouseBack => return Some(Intent::Back),
        Key::MouseForward => return Some(Intent::Forward),
        Key::Escape if nothing && !chord.shift => return Some(Intent::Back),
        Key::Backspace if nothing && !typing_target => return Some(Intent::Back),
        Key::Left if chord.alt && !primary => return Some(Intent::Back),
        Key::Right if chord.alt && !primary => return Some(Intent::Forward),
        Key::Char('[') if primary => return Some(Intent::Back),
        Key::Char(']') if primary => return Some(Intent::Forward),
        Key::Char('q') if primary => return Some(Intent::Quit),
        Key::Char('w') if primary && os != Os::MacOs => return Some(Intent::Quit),
        Key::Home if nothing && !typing_target => return Some(Intent::Scroll(ScrollKey::Home)),
        Key::End if nothing && !typing_target => return Some(Intent::Scroll(ScrollKey::End)),
        Key::PageUp if nothing => return Some(Intent::Scroll(ScrollKey::PageUp)),
        Key::PageDown if nothing => return Some(Intent::Scroll(ScrollKey::PageDown)),
        Key::Space if nothing && !typing_target => {
            let k = if chord.shift {
                ScrollKey::PageUp
            } else {
                ScrollKey::PageDown
            };
            return Some(Intent::Scroll(k));
        }
        _ => {}
    }
    if typing_target || !nothing {
        return None;
    }
    let t = text?;
    (t.chars().count() == 1 && t.chars().all(|c| !c.is_control() && !c.is_whitespace()))
        .then(|| Intent::TypeToSearch(t.to_owned()))
}

/// One menu of the in-window bar. A `&` in the title marks the mnemonic letter ("&File" shows "File", Alt+F opens it).
#[derive(Clone, Debug, PartialEq)]
pub struct BarMenu {
    /// Title with an optional `&`.
    pub title: String,
    /// The entries of the panel, in the shared popover format.
    pub entries: Vec<crate::popover::MenuEntry>,
}

impl BarMenu {
    /// The mnemonic letter (lower case) and the title without the `&`.
    pub fn mnemonic(&self) -> (Option<char>, String) {
        match self.title.find('&') {
            Some(i) => {
                let letter = self.title[i + 1..]
                    .chars()
                    .next()
                    .map(|c| c.to_ascii_lowercase());
                let mut shown = self.title.clone();
                shown.remove(i);
                (letter, shown)
            }
            None => (None, self.title.clone()),
        }
    }
}

/// What the keyboard did to the bar.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BarOutcome {
    /// Not for the bar.
    None,
    /// The bar took focus (Alt alone, F10): show the mnemonic underlines.
    Focused,
    /// Open this menu.
    Open(usize),
    /// Leave the bar.
    Left,
}

/// The keyboard state of the in-window menu bar (Windows rules: Alt alone focuses it, Alt+letter opens a menu, Esc leaves,
/// Left and Right move between menus).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MenuBar {
    /// The menus in order.
    pub menus: Vec<BarMenu>,
    /// The focused menu title, while the bar has keyboard focus.
    pub focused: Option<usize>,
    alt_pending: bool,
}

impl MenuBar {
    /// A bar of `menus`.
    pub fn new(menus: Vec<BarMenu>) -> MenuBar {
        MenuBar {
            menus,
            ..MenuBar::default()
        }
    }

    /// A key went down. `Alt+letter` opens a matching mnemonic at once; while the bar has focus, Left and Right move,
    /// Down and Return open, a letter opens by mnemonic and Esc leaves.
    pub fn key_down(&mut self, chord: &Chord) -> BarOutcome {
        if chord.alt && !chord.ctrl && !chord.meta {
            if let Key::Char(c) = chord.key {
                self.alt_pending = false;
                return self.open_mnemonic(c);
            }
            self.alt_pending = false;
        }
        if let Some(f) = self.focused {
            let n = self.menus.len().max(1);
            match chord.key {
                Key::Left => {
                    let i = (f + n - 1) % n;
                    self.focused = Some(i);
                    return BarOutcome::Focused;
                }
                Key::Right => {
                    let i = (f + 1) % n;
                    self.focused = Some(i);
                    return BarOutcome::Focused;
                }
                Key::Down | Key::Enter | Key::Space => return BarOutcome::Open(f),
                Key::Escape => {
                    self.focused = None;
                    return BarOutcome::Left;
                }
                Key::Char(c) if !chord.ctrl && !chord.meta => return self.open_mnemonic(c),
                _ => {}
            }
        }
        if chord.key == Key::F(10) && !chord.ctrl && !chord.meta && !chord.alt {
            return self.focus_first();
        }
        BarOutcome::None
    }

    /// Alt went down on its own (arm it: released without another key, it focuses the bar).
    pub fn alt_down(&mut self) {
        self.alt_pending = true;
    }

    /// Alt came up. Alt pressed and released alone focuses the bar (or leaves it).
    pub fn alt_up(&mut self) -> BarOutcome {
        if !std::mem::take(&mut self.alt_pending) {
            return BarOutcome::None;
        }
        if self.focused.is_some() {
            self.focused = None;
            BarOutcome::Left
        } else {
            self.focus_first()
        }
    }

    fn focus_first(&mut self) -> BarOutcome {
        if self.menus.is_empty() {
            return BarOutcome::None;
        }
        self.focused = Some(0);
        BarOutcome::Focused
    }

    fn open_mnemonic(&mut self, c: char) -> BarOutcome {
        let c = c.to_ascii_lowercase();
        match self.menus.iter().position(|m| m.mnemonic().0 == Some(c)) {
            Some(i) => {
                self.focused = Some(i);
                BarOutcome::Open(i)
            }
            None => BarOutcome::None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::popover::{MenuEntry, MenuItem};

    fn ctrl(c: char) -> Chord {
        Chord {
            ctrl: true,
            ..Chord::plain(Key::Char(c))
        }
    }
    fn cmd(c: char) -> Chord {
        Chord {
            meta: true,
            ..Chord::plain(Key::Char(c))
        }
    }

    #[test]
    fn one_declaration_is_ctrl_on_windows_and_linux_and_cmd_on_the_mac() {
        let s = Shortcut::parse("Cmd+Shift+G").unwrap();
        let shifted = |c: Chord| Chord { shift: true, ..c };
        assert!(s.matches(&shifted(ctrl('g')), Os::Windows));
        assert!(s.matches(&shifted(ctrl('g')), Os::Linux));
        assert!(
            !s.matches(&shifted(cmd('g')), Os::Windows),
            "the Windows key is not the primary modifier"
        );
        assert!(s.matches(&shifted(cmd('g')), Os::MacOs));
        assert!(
            !s.matches(&ctrl('g'), Os::Windows),
            "shift is part of the shortcut"
        );
        assert_eq!(s.display(Os::Windows), "Ctrl+Shift+G");
        assert_eq!(s.display(Os::MacOs), "\u{21E7}\u{2318}G");
        assert_eq!(
            Shortcut::parse("Ctrl+I").unwrap(),
            Shortcut::parse("Cmd+I").unwrap()
        );
        assert!(Shortcut::parse("Ctrl+").is_none());
    }

    #[test]
    fn the_registry_finds_commands_and_refuses_a_second_owner() {
        let mut r = Registry::new();
        assert!(r.add("Cmd+D", "watchlist"));
        assert!(r.add("Cmd+I", "info"));
        assert!(!r.add("Ctrl+D", "download"), "taken");
        assert_eq!(r.lookup(&ctrl('d'), Os::Windows), Some(&"watchlist"));
        assert_eq!(r.lookup(&cmd('i'), Os::MacOs), Some(&"info"));
        assert_eq!(r.lookup(&cmd('i'), Os::Windows), None);
        assert_eq!(r.display_for(&"info", Os::Linux).as_deref(), Some("Ctrl+I"));
    }

    #[test]
    fn standard_navigation_keys() {
        let w = Os::Windows;
        assert_eq!(
            intent(&Chord::plain(Key::Escape), None, false, w),
            Some(Intent::Back)
        );
        assert_eq!(
            intent(&Chord::plain(Key::MouseBack), None, false, w),
            Some(Intent::Back)
        );
        assert_eq!(
            intent(&Chord::plain(Key::MouseForward), None, false, w),
            Some(Intent::Forward)
        );
        let alt_left = Chord {
            alt: true,
            ..Chord::plain(Key::Left)
        };
        assert_eq!(intent(&alt_left, None, false, w), Some(Intent::Back));
        assert_eq!(
            intent(&cmd('['), None, false, Os::MacOs),
            Some(Intent::Back)
        );
        assert_eq!(
            intent(&Chord::plain(Key::PageDown), None, false, w),
            Some(Intent::Scroll(ScrollKey::PageDown))
        );
        assert_eq!(
            intent(&Chord::plain(Key::End), None, false, w),
            Some(Intent::Scroll(ScrollKey::End))
        );
        assert_eq!(
            intent(&Chord::plain(Key::End), None, true, w),
            None,
            "End moves the caret in a field"
        );
        assert_eq!(intent(&Chord::plain(Key::Backspace), None, true, w), None);
        assert_eq!(intent(&ctrl('q'), None, false, w), Some(Intent::Quit));
        let shift_space = Chord {
            shift: true,
            ..Chord::plain(Key::Space)
        };
        assert_eq!(
            intent(&shift_space, None, false, w),
            Some(Intent::Scroll(ScrollKey::PageUp))
        );
    }

    #[test]
    fn typing_with_nothing_focused_starts_a_search_but_never_inside_a_field_or_with_a_shortcut() {
        let a = Chord::plain(Key::Char('a'));
        assert_eq!(
            intent(&a, Some("a"), false, Os::Linux),
            Some(Intent::TypeToSearch("a".into()))
        );
        assert_eq!(intent(&a, Some("a"), true, Os::Linux), None);
        assert_eq!(intent(&ctrl('a'), Some("a"), false, Os::Linux), None);
        assert_eq!(
            intent(&Chord::plain(Key::Tab), Some("\t"), false, Os::Linux),
            None
        );
    }

    #[test]
    fn the_menu_bar_follows_the_windows_alt_rules() {
        let item = |l: &str| MenuEntry::Item(MenuItem::new(l, l));
        let mut bar = MenuBar::new(vec![
            BarMenu {
                title: "&Datei".into(),
                entries: vec![item("Neu")],
            },
            BarMenu {
                title: "&Ansicht".into(),
                entries: vec![item("Zoom")],
            },
        ]);
        assert_eq!(bar.menus[0].mnemonic(), (Some('d'), "Datei".to_owned()));
        let alt = |c: char| Chord {
            alt: true,
            ..Chord::plain(Key::Char(c))
        };
        assert_eq!(
            bar.key_down(&alt('a')),
            BarOutcome::Open(1),
            "Alt+A opens Ansicht"
        );
        let mut bar2 = bar.clone();
        bar2.focused = None;
        bar2.alt_down();
        assert_eq!(
            bar2.alt_up(),
            BarOutcome::Focused,
            "Alt alone focuses the bar"
        );
        assert_eq!(
            bar2.key_down(&Chord::plain(Key::Right)),
            BarOutcome::Focused
        );
        assert_eq!(bar2.focused, Some(1));
        assert_eq!(bar2.key_down(&Chord::plain(Key::Down)), BarOutcome::Open(1));
        assert_eq!(bar2.key_down(&Chord::plain(Key::Escape)), BarOutcome::Left);
        bar2.alt_down();
        let _ = bar2.key_down(&alt('x'));
        assert_eq!(bar2.alt_up(), BarOutcome::None, "Alt+key is not Alt alone");
    }
}
