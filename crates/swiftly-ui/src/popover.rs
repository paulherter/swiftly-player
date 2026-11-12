//! Menus and popovers: the right-click context menu at the pointer, the More menu, the season picker and other dropdowns
//! anchored to their button. A small raised panel like the Mac's `leap` panels (not a bottom sheet), with keyboard
//! navigation (arrows, Home, End, Return, Esc, type-to-select) and the Mac's insert transition (scale 0.94 about the
//! corner that touches the button, plus opacity, `snappy(0.22)`).
//!
//! Screens own one [`MenuController`] in their state. `open` it from a `UiEvent::Secondary` (anchor: the pointer), a long
//! press or a tap on a button (anchor: the button's rect); route keys to `key` while `is_open`; put `overlay` on top of
//! the page; act on `UiEvent::Tap` with an item's action or on [`DISMISS`].

use crate::anim::Motion;
use crate::components::color;
use crate::cx::Cx;
use crate::env::Env;
use crate::feel;
use crate::view::{Action, Node, Paint};
use swiftly_design::tokens::colour;
use swiftly_layout::{Align, Alignment, EdgeInsets, Point, Rect, Size};
use swiftly_motion::catalogue::Id;
use swiftly_render::{Color, ShadowStyle};
use swiftly_text::TextStyle;

/// What a tap on the dimming catcher behind the panel (a click outside) reports.
pub const DISMISS: Action = Action(0x706f_705f_6469_736d);

/// One row of a menu.
#[derive(Clone, Debug, PartialEq)]
pub struct MenuItem {
    /// Reported as `UiEvent::Tap` when the row is chosen.
    pub action: Action,
    /// The text.
    pub label: String,
    /// The shortcut shown at the right edge ("Ctrl+D"), already formatted for the OS.
    pub shortcut: Option<String>,
    /// Greyed out and skipped by the keyboard.
    pub enabled: bool,
    /// Red text (remove, delete).
    pub destructive: bool,
    /// A check mark in front (the current choice in a dropdown).
    pub checked: bool,
}

impl MenuItem {
    /// A plain enabled row.
    pub fn new(action: impl Into<Action>, label: impl Into<String>) -> MenuItem {
        MenuItem {
            action: action.into(),
            label: label.into(),
            shortcut: None,
            enabled: true,
            destructive: false,
            checked: false,
        }
    }
    /// With a shortcut label.
    #[must_use]
    pub fn shortcut(mut self, s: impl Into<String>) -> MenuItem {
        self.shortcut = Some(s.into());
        self
    }
    /// Greyed out.
    #[must_use]
    pub fn disabled(mut self) -> MenuItem {
        self.enabled = false;
        self
    }
    /// Red.
    #[must_use]
    pub fn destructive(mut self) -> MenuItem {
        self.destructive = true;
        self
    }
    /// With a check mark.
    #[must_use]
    pub fn checked(mut self, on: bool) -> MenuItem {
        self.checked = on;
        self
    }
}

/// A row or a divider.
#[derive(Clone, Debug, PartialEq)]
pub enum MenuEntry {
    /// A row.
    Item(MenuItem),
    /// A hairline between groups.
    Separator,
}

/// A keyboard key a menu understands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MenuKey {
    /// Highlight the previous row (wraps).
    Up,
    /// Highlight the next row (wraps).
    Down,
    /// First row.
    Home,
    /// Last row.
    End,
    /// Choose the highlighted row.
    Enter,
    /// Close.
    Escape,
    /// A typed character: jumps to the next row starting with it.
    Char(char),
}

/// What a key did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MenuOutcome {
    /// Nothing changed.
    None,
    /// The highlight moved to this entry index.
    Highlight(usize),
    /// A row was chosen: report this action and close.
    Activate(Action),
    /// Close without a choice.
    Close,
}

/// Where a menu hangs.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Anchor {
    /// At the pointer (right click): the top left corner sits on the pointer, flipping at the window edges.
    Pointer(Point),
    /// Under (or above) a button: leading edges aligned, flipping to the trailing edge or upwards when it does not fit.
    Button(Rect),
}

/// Where the panel goes and which corner it grows out of.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Placement {
    /// The panel's frame in window points.
    pub rect: Rect,
    /// The corner touching the anchor, in the panel's unit square: the pivot of the insert transition.
    pub pivot: (f32, f32),
}

/// Places a panel of `size` for `anchor` inside `bounds`, keeping [`feel::MENU_EDGE_MARGIN`] to the window edge.
pub fn place(anchor: Anchor, size: Size, bounds: Rect) -> Placement {
    let m = feel::MENU_EDGE_MARGIN;
    let (min_x, max_x) = (bounds.x + m, bounds.x + bounds.w - m);
    let (min_y, max_y) = (bounds.y + m, bounds.y + bounds.h - m);
    let (mut x, mut y, mut px, mut py);
    match anchor {
        Anchor::Pointer(p) => {
            (x, y, px, py) = (p.x, p.y, 0.0, 0.0);
            if x + size.w > max_x {
                x = p.x - size.w;
                px = 1.0;
            }
            if y + size.h > max_y {
                y = p.y - size.h;
                py = 1.0;
            }
        }
        Anchor::Button(r) => {
            (x, y, px, py) = (r.x, r.y + r.h + feel::MENU_GAP, 0.0, 0.0);
            if x + size.w > max_x {
                x = r.x + r.w - size.w;
                px = 1.0;
            }
            if y + size.h > max_y && r.y - feel::MENU_GAP - size.h >= min_y {
                y = r.y - feel::MENU_GAP - size.h;
                py = 1.0;
            }
        }
    }
    x = x.clamp(min_x, (max_x - size.w).max(min_x));
    y = y.clamp(min_y, (max_y - size.h).max(min_y));
    Placement {
        rect: Rect::new(x, y, size.w, size.h),
        pivot: (px, py),
    }
}

/// The keyboard state of an open menu.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MenuState {
    /// The highlighted entry (index into the entries).
    pub highlighted: Option<usize>,
    typed: String,
    typed_at: f64,
}

/// Silence (ms) after which type-to-select starts a new prefix. Source: AppKit menus use about one second, estimated.
pub const TYPE_RESET_MS: f64 = 1000.0;

impl MenuState {
    /// The first enabled row highlighted (what keyboard-opening a menu does).
    pub fn first(entries: &[MenuEntry]) -> MenuState {
        MenuState {
            highlighted: step(entries, None, 1),
            ..MenuState::default()
        }
    }

    /// A key at `now` ms. Disabled rows and separators are skipped; Up and Down wrap.
    pub fn key(&mut self, entries: &[MenuEntry], key: MenuKey, now: f64) -> MenuOutcome {
        let moved = |s: &mut MenuState, to: Option<usize>| match to {
            Some(i) if Some(i) != s.highlighted => {
                s.highlighted = Some(i);
                MenuOutcome::Highlight(i)
            }
            _ => MenuOutcome::None,
        };
        match key {
            MenuKey::Down => {
                let to = step(entries, self.highlighted, 1);
                moved(self, to)
            }
            MenuKey::Up => {
                let to = step(entries, self.highlighted, -1);
                moved(self, to)
            }
            MenuKey::Home => {
                let to = step(entries, None, 1);
                moved(self, to)
            }
            MenuKey::End => {
                let to = step(entries, None, -1);
                moved(self, to)
            }
            MenuKey::Enter => match self.highlighted.and_then(|i| entries.get(i)) {
                Some(MenuEntry::Item(it)) if it.enabled => MenuOutcome::Activate(it.action),
                _ => MenuOutcome::None,
            },
            MenuKey::Escape => MenuOutcome::Close,
            MenuKey::Char(c) => {
                if now - self.typed_at > TYPE_RESET_MS {
                    self.typed.clear();
                }
                self.typed_at = now;
                self.typed.extend(c.to_lowercase());
                let start = self
                    .highlighted
                    .map_or(0, |i| i + usize::from(self.typed.chars().count() == 1));
                let n = entries.len();
                let hit = (0..n).map(|k| (start + k) % n.max(1)).find(|&i| {
                    matches!(&entries[i], MenuEntry::Item(it) if it.enabled
                        && it.label.to_lowercase().starts_with(&self.typed))
                });
                moved(self, hit)
            }
        }
    }
}

/// The next enabled row from `from` in `dir` (1 or -1), wrapping; from `None` it starts at the first (or last) row.
fn step(entries: &[MenuEntry], from: Option<usize>, dir: i32) -> Option<usize> {
    let n = entries.len() as i32;
    if n == 0 {
        return None;
    }
    let mut i = match from {
        Some(i) => i as i32,
        None if dir > 0 => -1,
        None => n,
    };
    for _ in 0..n {
        i = (i + dir).rem_euclid(n);
        if matches!(&entries[i as usize], MenuEntry::Item(it) if it.enabled) {
            return Some(i as usize);
        }
    }
    None
}

fn row_style() -> TextStyle {
    TextStyle::new(13.0, 400)
}

/// The size of the panel for `entries`: as wide as the longest row plus the shortcut column, at least
/// `min_width` (190 for dropdowns).
pub fn panel_size(cx: &Cx, entries: &[MenuEntry], min_width: f32) -> Size {
    let style = row_style();
    let mut text = cx.text.borrow_mut();
    let mut widest = 0.0_f32;
    let mut height = 0.0_f32;
    for e in entries {
        match e {
            MenuEntry::Separator => height += SEPARATOR_HEIGHT,
            MenuEntry::Item(it) => {
                height += feel::MENU_ROW_HEIGHT;
                let l = text.layout(&it.label, &style, None, Some(1), swiftly_text::Align::Start);
                let k = it.shortcut.as_ref().map_or(0.0, |s| {
                    text.layout(s, &style, None, Some(1), swiftly_text::Align::Start)
                        .width()
                });
                // The row always keeps the gap (a spacer) between label and shortcut column.
                widest = widest.max(l.width() + k + SHORTCUT_GAP);
            }
        }
    }
    let w = (widest + 2.0 * (ROW_PAD + PANEL_PAD) + CHECK_COLUMN).max(min_width);
    Size::new(w, height + 2.0 * PANEL_PAD)
}

const PANEL_PAD: f32 = 6.0;
const ROW_PAD: f32 = 10.0;
const CHECK_COLUMN: f32 = 18.0;
const SHORTCUT_GAP: f32 = 24.0;
const SEPARATOR_HEIGHT: f32 = 9.0;

fn quiet() -> Color {
    color(colour::FONT_QUIET)
}

/// The panel: rows on a raised rounded rectangle with a hairline and the shared panel shadow.
pub fn panel_node(cx: &Cx, entries: &[MenuEntry], state: &MenuState, size: Size) -> Node {
    let style = row_style();
    let rows: Vec<Node> = entries
        .iter()
        .enumerate()
        .map(|(i, e)| match e {
            MenuEntry::Separator => Node::rect(color(colour::MARGIN), 0.0)
                .frame(None, Some(1.0), Alignment::CENTER)
                .padding(EdgeInsets {
                    top: 4.0,
                    leading: ROW_PAD,
                    bottom: 4.0,
                    trailing: ROW_PAD,
                })
                .key(1000 + i),
            MenuEntry::Item(it) => item_row(cx, &style, it, state.highlighted == Some(i)).key(i),
        })
        .collect();
    let (a, blur, dy) = feel::PANEL_SHADOW;
    let back = Node::flexible()
        .paint(Paint::Shadow {
            style: ShadowStyle {
                color: Color::new(0.0, 0.0, 0.0, a),
                dx: 0.0,
                dy,
                blur,
                spread: 0.0,
            },
            radius: feel::MENU_RADIUS,
        })
        .paint(Paint::Fill {
            color: color(colour::RAISED),
            radius: feel::MENU_RADIUS,
        })
        .paint(Paint::Stroke {
            color: color(colour::MARGIN),
            width: 1.0,
            radius: feel::MENU_RADIUS,
        });
    Node::vstack(Align::Start, Some(0.0), rows)
        .padding(EdgeInsets {
            top: PANEL_PAD,
            leading: PANEL_PAD,
            bottom: PANEL_PAD,
            trailing: PANEL_PAD,
        })
        .background(back, Alignment::CENTER)
        .frame(Some(size.w), Some(size.h), Alignment::TOP_LEADING)
}

fn item_row(cx: &Cx, style: &TextStyle, it: &MenuItem, highlighted: bool) -> Node {
    let ink = if !it.enabled {
        color(colour::FONT_VERY_QUIET)
    } else if it.destructive {
        color(colour::ERROR)
    } else {
        color(colour::FONT)
    };
    let check = if it.checked {
        Node::text(
            cx,
            "\u{2713}",
            style,
            ink,
            Some(1),
            swiftly_text::Align::Start,
        )
    } else {
        Node::spacer()
    }
    .frame(Some(CHECK_COLUMN), None, Alignment::LEADING);
    let mut cells = vec![
        check,
        // The panel is measured to fit the label: it never shrinks to an ellipsis because the spacer shares the row.
        Node::text(
            cx,
            &it.label,
            style,
            ink,
            Some(1),
            swiftly_text::Align::Start,
        )
        .fixed_size(true, false),
        Node::spacer_min(SHORTCUT_GAP),
    ];
    if let Some(s) = &it.shortcut {
        cells.push(
            Node::text(cx, s, style, quiet(), Some(1), swiftly_text::Align::End)
                .fixed_size(true, false),
        );
    }
    let row = Node::hstack(Align::Center, Some(0.0), cells)
        .padding(EdgeInsets {
            top: 0.0,
            leading: ROW_PAD - 4.0,
            bottom: 0.0,
            trailing: ROW_PAD,
        })
        .frame(None, Some(feel::MENU_ROW_HEIGHT), Alignment::LEADING);
    let mut row = row.hover_surface(
        Color::new(1.0, 1.0, 1.0, feel::HOVER_SURFACE_ALPHA),
        feel::SIDEBAR_HOVER_RADIUS,
    );
    row = row.selected(highlighted && it.enabled);
    if it.enabled {
        row = row
            .on_tap(it.action)
            .press_style(crate::interact::PressStyle::Row);
    } else {
        row = row.disabled(false);
    }
    row
}

/// The open state of one menu a screen owns.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MenuController {
    open: Option<Open>,
}

#[derive(Clone, Debug, PartialEq)]
struct Open {
    entries: Vec<MenuEntry>,
    state: MenuState,
    anchor: Anchor,
    min_width: f32,
}

impl MenuController {
    /// A closed menu.
    pub fn new() -> MenuController {
        MenuController::default()
    }
    /// Whether a menu is showing (keys go to [`key`](Self::key), the rest of the page is blocked by the catcher).
    pub fn is_open(&self) -> bool {
        self.open.is_some()
    }
    /// Opens a menu. `keyboard` highlights the first row at once (opened from the keyboard); a pointer-opened menu starts
    /// without a highlight until the first arrow key or hover.
    pub fn open(
        &mut self,
        entries: Vec<MenuEntry>,
        anchor: Anchor,
        min_width: f32,
        keyboard: bool,
    ) {
        let state = if keyboard {
            MenuState::first(&entries)
        } else {
            MenuState::default()
        };
        self.open = Some(Open {
            entries,
            state,
            anchor,
            min_width,
        });
    }
    /// Closes the menu.
    pub fn close(&mut self) {
        self.open = None;
    }
    /// A key for the open menu; closes it on a choice or Esc. The outcome says what the screen must do.
    pub fn key(&mut self, key: MenuKey, now: f64) -> MenuOutcome {
        let Some(o) = self.open.as_mut() else {
            return MenuOutcome::None;
        };
        let out = o.state.key(&o.entries, key, now);
        if matches!(out, MenuOutcome::Activate(_) | MenuOutcome::Close) {
            self.open = None;
        }
        out
    }
    /// The highlighted entry index.
    pub fn highlighted(&self) -> Option<usize> {
        self.open.as_ref().and_then(|o| o.state.highlighted)
    }
    /// The overlay for the window, or `None` when closed: a catcher over the whole window (a tap reports [`DISMISS`])
    /// and the panel at its [`Placement`], growing out of its corner.
    pub fn overlay(&self, cx: &Cx, env: &Env) -> Option<Node> {
        let o = self.open.as_ref()?;
        let size = panel_size(cx, &o.entries, o.min_width);
        let bounds = Rect::new(0.0, 0.0, env.size.w, env.size.h);
        let at = place(o.anchor, size, bounds);
        // A menu opened at the pointer is the system's (`.contextMenu`): it appears at once and fades out after a choice
        // (`NativeFade`). One anchored to a button is the app's own panel: it grows out of the button's corner with `leap`.
        let native = matches!(o.anchor, Anchor::Pointer(_));
        let panel = panel_node(cx, &o.entries, &o.state, size);
        let panel = if native {
            let fade = Motion::of(Id::NativeFade);
            panel.scaled(1.0, fade).exit_to(1.0, 0.0).opacity(1.0, fade)
        } else {
            let leap = feel::leap();
            panel
                .scaled(1.0, leap)
                .appear_from(feel::PANEL_EXPAND_SCALE, 0.0)
                .exit_to(feel::PANEL_EXPAND_SCALE, 0.0)
                .opacity(1.0, leap)
        };
        let panel = panel
            .scale_about(at.pivot.0, at.pivot.1)
            .key("menu-panel")
            .padding(EdgeInsets {
                top: at.rect.y,
                leading: at.rect.x,
                bottom: 0.0,
                trailing: 0.0,
            });
        let catcher = Node::rect(Color::new(0.0, 0.0, 0.0, 0.0), 0.0)
            .on_tap_silent(DISMISS)
            .on_secondary(DISMISS)
            .key("menu-catcher");
        Some(
            Node::zstack(Alignment::TOP_LEADING, vec![catcher, panel])
                .frame(Some(env.size.w), Some(env.size.h), Alignment::TOP_LEADING)
                .key("menu-overlay"),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entries() -> Vec<MenuEntry> {
        vec![
            MenuEntry::Item(MenuItem::new("play", "Abspielen")),
            MenuEntry::Item(MenuItem::new("info", "Info").shortcut("Ctrl+I")),
            MenuEntry::Separator,
            MenuEntry::Item(MenuItem::new("gone", "Entfernen").disabled()),
            MenuEntry::Item(MenuItem::new("del", "Aus der Liste entfernen").destructive()),
        ]
    }

    #[test]
    fn keys_skip_separators_and_disabled_rows_and_wrap() {
        let e = entries();
        let mut s = MenuState::default();
        assert_eq!(s.key(&e, MenuKey::Down, 0.0), MenuOutcome::Highlight(0));
        assert_eq!(s.key(&e, MenuKey::Down, 0.0), MenuOutcome::Highlight(1));
        assert_eq!(
            s.key(&e, MenuKey::Down, 0.0),
            MenuOutcome::Highlight(4),
            "skips the divider and the disabled row"
        );
        assert_eq!(
            s.key(&e, MenuKey::Down, 0.0),
            MenuOutcome::Highlight(0),
            "wraps"
        );
        assert_eq!(s.key(&e, MenuKey::Up, 0.0), MenuOutcome::Highlight(4));
        assert_eq!(s.key(&e, MenuKey::Home, 0.0), MenuOutcome::Highlight(0));
        assert_eq!(s.key(&e, MenuKey::End, 0.0), MenuOutcome::Highlight(4));
        assert_eq!(
            s.key(&e, MenuKey::Enter, 0.0),
            MenuOutcome::Activate(Action::from("del"))
        );
        assert_eq!(s.key(&e, MenuKey::Escape, 0.0), MenuOutcome::Close);
    }

    #[test]
    fn typing_jumps_to_the_row_with_that_prefix_and_restarts_after_silence() {
        let e = entries();
        let mut s = MenuState::default();
        assert_eq!(
            s.key(&e, MenuKey::Char('i'), 0.0),
            MenuOutcome::Highlight(1)
        );
        assert_eq!(
            s.key(&e, MenuKey::Char('n'), 100.0),
            MenuOutcome::None,
            "\"in\" is still Info"
        );
        assert_eq!(
            s.key(&e, MenuKey::Char('a'), 2000.0),
            MenuOutcome::Highlight(4),
            "a new prefix: Aus der Liste"
        );
        assert_eq!(
            s.key(&e, MenuKey::Char('e'), 5000.0),
            MenuOutcome::None,
            "the disabled Entfernen never matches"
        );
    }

    #[test]
    fn a_pointer_menu_flips_at_the_window_edges() {
        let bounds = Rect::new(0.0, 0.0, 800.0, 600.0);
        let size = Size::new(200.0, 150.0);
        let a = place(Anchor::Pointer(Point::new(100.0, 100.0)), size, bounds);
        assert_eq!((a.rect.x, a.rect.y, a.pivot), (100.0, 100.0, (0.0, 0.0)));
        let b = place(Anchor::Pointer(Point::new(700.0, 550.0)), size, bounds);
        assert_eq!((b.rect.x, b.rect.y, b.pivot), (500.0, 400.0, (1.0, 1.0)));
        assert!(b.rect.x + b.rect.w <= 792.0 && b.rect.y + b.rect.h <= 592.0);
    }

    #[test]
    fn a_button_menu_hangs_below_flips_to_the_trailing_edge_and_goes_up_when_needed() {
        let bounds = Rect::new(0.0, 0.0, 800.0, 600.0);
        let size = Size::new(190.0, 200.0);
        let below = place(
            Anchor::Button(Rect::new(100.0, 50.0, 120.0, 34.0)),
            size,
            bounds,
        );
        assert_eq!(
            (below.rect.x, below.rect.y, below.pivot),
            (100.0, 88.0, (0.0, 0.0))
        );
        let right = place(
            Anchor::Button(Rect::new(700.0, 50.0, 90.0, 34.0)),
            size,
            bounds,
        );
        assert_eq!(
            (right.rect.x, right.pivot.0),
            (600.0, 1.0),
            "aligned to the button's trailing edge"
        );
        let up = place(
            Anchor::Button(Rect::new(100.0, 500.0, 120.0, 34.0)),
            size,
            bounds,
        );
        assert_eq!((up.rect.y, up.pivot.1), (296.0, 1.0));
    }
}
