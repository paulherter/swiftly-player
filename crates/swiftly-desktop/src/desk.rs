//! Desktop-only chrome shared by the tab screens: shortcut hints, the tile context menu as an anchored popover (the Mac's
//! `TileMenuMac`), and the two history arrows of the 52 pt strip (`NavArrows`). Numbers live in `swiftly_ui::feel` and
//! `swiftly_design::tokens::desktop`; the sources are `mac-spec/A-home-library-search-navigation.md` sections 2, 5, 9.

use crate::home::{self, Form};
use crate::tile_menu::{self, Cx as TCx, Entry};
use swiftly_design::tokens::colour;
use swiftly_layout::{Align, Alignment, EdgeInsets, Point};
use swiftly_motion::Os;
use swiftly_render::{Color, DrawList};
use swiftly_ui::components::color;
use swiftly_ui::popover::{
    self, Anchor, MenuController, MenuEntry, MenuItem, MenuKey, MenuOutcome,
};
use swiftly_ui::{Action, Cx, Env, Node, Ui, feel};
use swiftly_vm::Tile;

/// 0 = the running OS; 1 = Mac glyphs, 2 = Ctrl text (set by [`force_hint_os`]).
static HINT_OS: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);

/// Makes every shortcut hint of this process read like `os`. Only the Mac-made frame goldens use it, so they hold on
/// Windows and Linux too, where the real hints say "Ctrl+1" instead of the Mac glyph (that text is correct there).
pub fn force_hint_os(os: Os) {
    HINT_OS.store(
        if os == Os::MacOs { 1 } else { 2 },
        std::sync::atomic::Ordering::Relaxed,
    );
}

fn hint_os() -> Os {
    match HINT_OS.load(std::sync::atomic::Ordering::Relaxed) {
        1 => Os::MacOs,
        2 => Os::Linux,
        _ => Os::current(),
    }
}

/// The shortcut text of "Cmd+`key`": "Ctrl+1" on Windows and Linux, the Mac glyphs on the Mac.
pub fn hint(key: &str) -> String {
    hint_for(hint_os(), key, false)
}

/// Same for "Cmd+Shift+`key`".
pub fn hint_shift(key: &str) -> String {
    hint_for(hint_os(), key, true)
}

/// The text of a shortcut for `os`.
pub fn hint_for(os: Os, key: &str, shift: bool) -> String {
    if os == Os::MacOs {
        format!("{}\u{2318}{key}", if shift { "\u{21E7}" } else { "" })
    } else {
        format!("Ctrl+{}{key}", if shift { "Shift+" } else { "" })
    }
}

/// Prefix of the actions of the context menu rows.
const ROW: &str = "ctxm.";

/// The open tile context menu of one screen: the entries come from [`tile_menu::entries`] (the Mac's eleven), drawn as a
/// small anchored panel with the Mac's shortcuts.
#[derive(Clone, Default, PartialEq)]
pub struct TileMenu {
    ctl: MenuController,
    id: Option<String>,
    entries: Vec<Entry>,
}

/// What a tap or key on the menu decided.
#[derive(Debug, PartialEq, Eq)]
pub enum Pick {
    /// The row `index` of the entries of title `id` was chosen.
    Row(String, usize),
    /// The menu closed without a choice.
    Closed,
}

impl TileMenu {
    /// Whether the menu is showing.
    pub fn is_open(&self) -> bool {
        self.ctl.is_open()
    }

    /// Opens the menu of `tile` at window point `p` (a right click) or under a keyboard focus. False when the title has no
    /// menu.
    pub fn open(&mut self, tile: &Tile, host: &TCx, p: Point, keyboard: bool) -> bool {
        let entries = tile_menu::entries(Form::Desktop, host, Some(tile));
        if entries.is_empty() {
            return false;
        }
        let rows = tile_rows(&entries, tile, host, ROW);
        self.ctl.open(rows, Anchor::Pointer(p), 0.0, keyboard);
        self.id = Some(tile.id.clone());
        self.entries = entries;
        true
    }

    /// The entry behind row `index` of the open menu.
    pub fn entry(&self, index: usize) -> Option<&Entry> {
        self.entries.get(index)
    }

    /// The panel and its catcher for the top of the page, or `None` when closed.
    pub fn overlay(&self, cx: &Cx, env: &Env) -> Option<Node> {
        self.ctl.overlay(cx, env)
    }

    /// A tap that came from the UI: a row, or the catcher outside (closes).
    pub fn tap(&mut self, a: &Action) -> Option<Pick> {
        if !self.ctl.is_open() {
            return None;
        }
        if *a == popover::DISMISS {
            self.close();
            return Some(Pick::Closed);
        }
        let i =
            (0..self.entries.len()).find(|i| *a == Action::from(format!("{ROW}{i}").as_str()))?;
        let id = self.id.clone().unwrap_or_default();
        self.close();
        Some(Pick::Row(id, i))
    }

    /// A key for the open menu.
    pub fn key(&mut self, key: MenuKey, now: f64) -> Option<Pick> {
        let id = self.id.clone().unwrap_or_default();
        match self.ctl.key(key, now) {
            MenuOutcome::Activate(a) => {
                let i = (0..self.entries.len())
                    .find(|i| a == Action::from(format!("{ROW}{i}").as_str()))?;
                self.close();
                Some(Pick::Row(id, i))
            }
            MenuOutcome::Close => {
                self.close();
                Some(Pick::Closed)
            }
            _ => None,
        }
    }

    /// Closes the menu.
    pub fn close(&mut self) {
        self.ctl.close();
        self.id = None;
    }
}

/// The two history arrows (`NavArrows`, Mac `MacComponents.swift:888`): two 30 x 28 buttons 2 apart at the left edge (20),
/// vertically centred in the 52 pt strip, chevrons 16/500, hover surface radius 6, disabled ones at 35 %.
pub struct NavArrows {
    ui: Ui<(bool, bool)>,
}

/// Where the arrows sit: `(x, y, w, h)` in window points (`MainView.swift:154`: the content column starts after the 220 pt sidebar and its 1 pt edge, the pair sits 20 pt in and is
/// centred in the 52 pt row: 241, 12).
pub const ARROWS_RECT: [f32; 4] = [241.0, 12.0, 62.0, 28.0];

fn arrow(
    icons: &swiftly_ui::icons::Icons,
    name: &str,
    label: &str,
    key: &str,
    enabled: bool,
) -> Node {
    let c = Color::new(1.0, 1.0, 1.0, 1.0);
    let hover = Color::new(1.0, 1.0, 1.0, feel::HOVER_SURFACE_ALPHA);
    let n = icons
        .node(name, 16.0, true, c)
        .frame(Some(30.0), Some(28.0), Alignment::CENTER);
    let n = n
        .hover_surface(hover, 6.0)
        .a11y(swiftly_ui::a11y::A11yNode::new(
            "",
            swiftly_ui::a11y::Role::Button,
            label,
        ));
    let n = n.key(key).tooltip(label);
    if enabled {
        n.on_tap(Action::from(key))
    } else {
        n.opacity(0.35, feel::hover()).disabled(false)
    }
}

impl NavArrows {
    /// Arrows for `env`: back and forward enabled as `(can_back, can_forward)` says.
    pub fn new(env: Env, cx: Cx) -> NavArrows {
        let icons = swiftly_ui::icons::Icons::new(&cx, env.scale);
        let ui = Ui::new(
            move |p: &(bool, bool), _env: &Env, _cx: &Cx| {
                let row = Node::hstack(
                    Align::Center,
                    Some(2.0),
                    vec![
                        arrow(&icons, "caret-left", "Zur\u{fc}ck", "nav.back", p.0),
                        arrow(&icons, "caret-right", "Vorw\u{e4}rts", "nav.forward", p.1),
                    ],
                );
                home::fill_frame(
                    row.padding(home::ins(ARROWS_RECT[1], ARROWS_RECT[0], 0.0, 0.0)),
                    Alignment::TOP_LEADING,
                )
            },
            (false, false),
            env,
            cx,
        );
        NavArrows { ui }
    }

    /// What a screen reader gets for the two arrows.
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.ui.a11y_nodes()
    }

    /// A new window size.
    pub fn set_env(&mut self, env: Env) {
        self.ui.set_env(env);
    }

    /// Whether `(x, y)` is on an arrow.
    pub fn hits(x: f32, y: f32) -> bool {
        let r = ARROWS_RECT;
        x >= r[0] && x <= r[0] + r[2] && y >= r[1] && y <= r[1] + r[3]
    }

    /// The pointer moved (hover, tooltip).
    pub fn pointer(&mut self, x: f32, y: f32, now: f64) {
        self.ui.pointer_move(x, y, now);
    }

    /// The pointer is away.
    pub fn leave(&mut self, now: f64) {
        self.ui.pointer_leave(now);
    }

    /// A click at `(x, y)`: `Some(true)` for back, `Some(false)` for forward.
    pub fn click(&mut self, x: f32, _y: f32, _now: f64) -> Option<bool> {
        // Two 30 pt buttons 2 apart: the geometry decides, the `Ui` only draws and tracks hover.
        Some(x < ARROWS_RECT[0] + 31.0)
    }

    /// The arrows over the page at `now`, with what the history allows.
    pub fn frame(&mut self, can: (bool, bool), now: f64) -> (DrawList, bool) {
        self.ui.set_parts(can);
        let list = self.ui.frame(now);
        (list, self.ui.needs_frame())
    }
}

/// `colour/reason`, for the callers that dim.
pub fn ground() -> Color {
    color(colour::REASON)
}

/// Padding helper kept next to the arrows: insets of `top` and `leading` only.
pub fn pad(top: f32, leading: f32) -> EdgeInsets {
    home::ins(top, leading, 0.0, 0.0)
}

/// A page of the sidebar's "Meins" group that is not a tab.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Go {
    /// The watchlist.
    Watchlist,
    /// The downloads page.
    Downloads,
    /// A tab row of the sidebar was tapped (while a page is pushed the sidebar still belongs to the tabs).
    Tab(usize),
}

/// What the account card at the bottom left of the sidebar shows.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub enum Card {
    /// The demo app (no account, no server): the sample account of the demo data.
    #[default]
    Demo,
    /// The signed-in account of the real app.
    Account {
        /// The user name.
        name: String,
        /// The server's host, without the scheme.
        server: String,
    },
    /// The real app without an account (signing in): the card says nothing.
    Hidden,
}

impl Card {
    /// The card for a stored account: the user's name and the server address without `http(s)://`.
    pub fn account(name: &str, server: &str) -> Card {
        let host = server
            .trim()
            .trim_start_matches("https://")
            .trim_start_matches("http://")
            .trim_end_matches('/');
        Card::Account {
            name: name.trim().to_owned(),
            server: host.to_owned(),
        }
    }

    /// The avatar letter: the first letter of the name, upper case ("S" when there is none).
    pub fn initial(&self) -> String {
        let name = match self {
            Card::Account { name, .. } => name.as_str(),
            _ => "Swiftly",
        };
        name.chars()
            .find(|c| c.is_alphanumeric())
            .map_or_else(|| "S".to_owned(), |c| c.to_uppercase().collect())
    }
}

thread_local! {
    static CARD: std::cell::RefCell<Card> = const { std::cell::RefCell::new(Card::Demo) };
    static GO: std::cell::Cell<Option<Go>> = const { std::cell::Cell::new(None) };
    static DOWNLOADS_FRONT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static SETTINGS_FRONT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static LIST_CHANGES: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// A page changed what Start shows (Merkliste added or removed, watched state, a finished playback): the suite
/// refetches Start the next time it is in front (the Mac's `watchlistChanged` and the Start reload on return).
pub fn note_list_change() {
    LIST_CHANGES.with(|c| c.set(c.get() + 1));
}

/// How many list changes have been noted so far.
pub fn list_changes() -> u64 {
    LIST_CHANGES.with(std::cell::Cell::get)
}

/// The app tells the sidebars that the Downloads page is in front: on the Mac Downloads is a section of its own, so its
/// row is the active one and the tab behind it is not.
pub fn set_downloads_front(on: bool) {
    DOWNLOADS_FRONT.with(|d| d.set(on));
}

/// The app tells the sidebars that a panel (profile, settings) is open: the profile row at the bottom left is the
/// selected one and no page row is.
pub fn set_settings_front(on: bool) {
    SETTINGS_FRONT.with(|d| d.set(on));
}

/// The app tells the sidebars what the account card shows.
pub fn set_card(card: Card) {
    CARD.with(|c| {
        if *c.borrow() != card {
            *c.borrow_mut() = card;
        }
    });
}

/// What the account card shows now.
pub fn card() -> Card {
    CARD.with(|c| c.borrow().clone())
}

/// Whether a panel is open (the sidebar highlights the profile row).
pub fn settings_front() -> bool {
    SETTINGS_FRONT.with(|d| d.get())
}

/// Whether the Downloads page is in front (the sidebar highlights "Downloads").
pub fn downloads_front() -> bool {
    DOWNLOADS_FRONT.with(|d| d.get())
}

/// Called for every tap of a tab screen: the sidebar rows of "Meins" raise a request the app reads.
pub fn note_tap(a: &Action) {
    if *a == Action::from("go:watchlist") {
        GO.with(|g| g.set(Some(Go::Watchlist)));
    } else if *a == Action::from("go:downloads") {
        GO.with(|g| g.set(Some(Go::Downloads)));
    } else if let Some(i) = (0..4).find(|i| *a == Action::from(format!("tab:{i}").as_str())) {
        GO.with(|g| g.set(Some(Go::Tab(i))));
    }
}

/// The page the sidebar asked for since the last call.
pub fn take_go() -> Option<Go> {
    GO.with(|g| g.take())
}

/// The rows of a tile menu with the Mac's shortcuts; row `i` reports the action `"{prefix}{i}"`.
pub fn tile_rows(entries: &[Entry], tile: &Tile, host: &TCx, prefix: &str) -> Vec<MenuEntry> {
    entries
        .iter()
        .enumerate()
        .map(|(i, e)| {
            let mut item = MenuItem::new(
                Action::from(format!("{prefix}{i}").as_str()),
                tile_menu::label(e, host, Some(tile)),
            );
            match e {
                Entry::Play => item = item.shortcut("\u{21B5}"),
                Entry::Remember => item = item.shortcut(hint("D")),
                Entry::Watched => item = item.shortcut(hint_shift("G")),
                Entry::Info => item = item.shortcut(hint("I")),
                Entry::Remove => item = item.destructive(),
                _ => {}
            }
            MenuEntry::Item(item)
        })
        .collect()
}

/// What a key did to an open [`Pop`].
#[derive(Debug, PartialEq)]
pub enum PopKey {
    /// Nothing for the screen to do.
    None,
    /// Closed without a choice.
    Closed,
    /// A row was chosen: feed this action to the tap handler.
    Pick(Action),
}

/// An anchored popover a screen owns (filter, sort and title menus, right click on a tile). The rows report plain actions,
/// so the screen's tap handler is the same one the bottom sheet uses.
#[derive(Clone, Default, PartialEq)]
pub struct Pop {
    ctl: MenuController,
}

impl Pop {
    /// Whether the popover shows.
    pub fn is_open(&self) -> bool {
        self.ctl.is_open()
    }

    /// Opens `rows` at `anchor`.
    pub fn open(&mut self, rows: Vec<MenuEntry>, anchor: Anchor, min_width: f32) {
        self.ctl.open(rows, anchor, min_width, false);
    }

    /// Opens `(action, label, checked)` rows under a button.
    pub fn open_list(&mut self, rows: &[(String, String, bool)], button: [f32; 4], min_width: f32) {
        let rows = rows
            .iter()
            .map(|(a, l, c)| {
                MenuEntry::Item(MenuItem::new(Action::from(a.as_str()), l.as_str()).checked(*c))
            })
            .collect();
        self.open(
            rows,
            Anchor::Button(swiftly_layout::Rect::new(
                button[0], button[1], button[2], button[3],
            )),
            min_width,
        );
    }

    /// Closes it.
    pub fn close(&mut self) {
        self.ctl.close();
    }

    /// The panel and its catcher for the top of the page.
    pub fn overlay(&self, cx: &Cx, env: &Env) -> Option<Node> {
        self.ctl.overlay(cx, env)
    }

    /// A tap on the catcher outside the panel: closes. True when it was that.
    pub fn dismissed(&mut self, a: &Action) -> bool {
        if self.ctl.is_open() && *a == popover::DISMISS {
            self.ctl.close();
            true
        } else {
            false
        }
    }

    /// A navigation key for the open popover.
    pub fn key(&mut self, key: swiftly_ui::NavKey, down: bool, now: f64) -> PopKey {
        use swiftly_ui::{Dir, NavKey};
        if !down || !self.ctl.is_open() {
            return PopKey::None;
        }
        let k = match key {
            NavKey::Arrow(Dir::Up) => MenuKey::Up,
            NavKey::Arrow(Dir::Down) => MenuKey::Down,
            NavKey::Enter => MenuKey::Enter,
            NavKey::Escape => MenuKey::Escape,
            _ => return PopKey::None,
        };
        match self.ctl.key(k, now) {
            MenuOutcome::Activate(a) => PopKey::Pick(a),
            MenuOutcome::Close => PopKey::Closed,
            _ => PopKey::None,
        }
    }
}

/// What the window controls and the drag zone ask the window to do.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WinAction {
    /// Minimise.
    Minimize,
    /// Maximise, or restore when it is maximised.
    ToggleMaximize,
    /// Close (quit).
    Close,
    /// Start moving the window (a press on the toolbar row); a second press within the double-click time maximises.
    DragMove,
}

/// One of the three buttons.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WinButton {
    /// Minimise.
    Min,
    /// Maximise or restore.
    Max,
    /// Close.
    Close,
}

/// Height of the toolbar row the window controls and the drag zone live in (`Theme.toolbarHeight`).
pub const TOOLBAR_H: f32 = 52.0;
/// A window button: 40 x 32, 2 apart, 8 from the right edge, centred in the 52 pt row.
const BTN: (f32, f32, f32, f32) = (40.0, 32.0, 2.0, 8.0);

/// The window buttons in the toolbar row at the top right (the window has no system frame): flat glyphs in the Mac's
/// toolbar-button look, white 6 % hover surface (radius 8), close turns `error` on hover.
pub struct WindowControls {
    ui: Ui<bool>,
    maximized: bool,
    width: f32,
}

fn glyph_box(stroke: Color, offset: f32) -> Node {
    Node::rect(Color::new(0.0, 0.0, 0.0, 0.0), 2.0)
        .paint(swiftly_ui::Paint::Stroke {
            color: stroke,
            width: 1.3,
            radius: 2.0,
        })
        .frame(Some(10.0), Some(10.0), Alignment::CENTER)
        .padding(EdgeInsets {
            top: offset,
            leading: 0.0,
            bottom: 0.0,
            trailing: offset,
        })
}

fn button(icons: &swiftly_ui::icons::Icons, which: WinButton, maximized: bool) -> Node {
    let white = Color::new(1.0, 1.0, 1.0, 1.0);
    let (name, label, key) = match which {
        WinButton::Min => ("Minimieren", "Minimieren", "win.min"),
        WinButton::Max => (
            if maximized {
                "Wiederherstellen"
            } else {
                "Maximieren"
            },
            "Maximieren",
            "win.max",
        ),
        WinButton::Close => ("Schlie\u{df}en", "Schlie\u{df}en", "win.close"),
    };
    let _ = label;
    let glyph = match which {
        WinButton::Min => icons.node("minus", 14.0, true, white),
        WinButton::Close => icons.node("x", 14.0, true, white),
        WinButton::Max if maximized => Node::zstack(
            Alignment::CENTER,
            vec![glyph_box(white, -1.5), glyph_box(white, 1.5)],
        ),
        WinButton::Max => glyph_box(white, 0.0),
    };
    let hover = if which == WinButton::Close {
        color(colour::ERROR)
    } else {
        Color::new(1.0, 1.0, 1.0, feel::HOVER_SURFACE_ALPHA)
    };
    glyph
        .frame(Some(BTN.0), Some(BTN.1), Alignment::CENTER)
        .hover_surface(hover, 8.0)
        .press_style(swiftly_ui::PressStyle::Row)
        .a11y(swiftly_ui::a11y::A11yNode::new(
            "",
            swiftly_ui::a11y::Role::Button,
            name,
        ))
        .tooltip(name)
        .key(key)
}

impl WindowControls {
    /// Controls for `env`.
    pub fn new(env: Env, cx: Cx) -> WindowControls {
        let icons = swiftly_ui::icons::Icons::new(&cx, env.scale);
        let ui = Ui::new(
            move |max: &bool, _env: &Env, _cx: &Cx| {
                let row = Node::hstack(
                    Align::Center,
                    Some(BTN.2),
                    vec![
                        button(&icons, WinButton::Min, *max),
                        button(&icons, WinButton::Max, *max),
                        button(&icons, WinButton::Close, *max),
                    ],
                )
                .padding(home::ins((TOOLBAR_H - BTN.1) / 2.0, 0.0, 0.0, BTN.3));
                home::fill_frame(row, Alignment::TOP_TRAILING)
            },
            false,
            env,
            cx,
        );
        WindowControls {
            ui,
            maximized: false,
            width: env.size.w,
        }
    }

    /// A new window size.
    pub fn set_env(&mut self, env: Env) {
        self.width = env.size.w;
        self.ui.set_env(env);
    }

    /// The window is (no longer) maximised: the middle glyph changes.
    pub fn set_maximized(&mut self, on: bool) {
        self.maximized = on;
    }

    fn rect_of(&self, i: usize) -> (f32, f32, f32, f32) {
        let x = self.width - BTN.3 - 3.0 * BTN.0 - 2.0 * BTN.2 + i as f32 * (BTN.0 + BTN.2);
        (x, (TOOLBAR_H - BTN.1) / 2.0, BTN.0, BTN.1)
    }

    /// Which button `(x, y)` is on.
    pub fn hit(&self, x: f32, y: f32) -> Option<WinButton> {
        [WinButton::Min, WinButton::Max, WinButton::Close]
            .into_iter()
            .enumerate()
            .find_map(|(i, b)| {
                let (bx, by, bw, bh) = self.rect_of(i);
                (x >= bx && x < bx + bw && y >= by && y < by + bh).then_some(b)
            })
    }

    /// The pointer moved (hover, tooltip).
    pub fn pointer(&mut self, x: f32, y: f32, now: f64) {
        self.ui.pointer_move(x, y, now);
    }

    /// The pointer left the window.
    pub fn leave(&mut self, now: f64) {
        self.ui.pointer_leave(now);
    }

    /// What a screen reader gets.
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.ui.a11y_nodes()
    }

    /// The buttons at `now`.
    pub fn frame(&mut self, now: f64) -> (DrawList, bool) {
        self.ui.set_parts(self.maximized);
        let list = self.ui.frame(now);
        (list, self.ui.needs_frame())
    }
}

/// The launch curtain (`StartCurtain`, `RootView.swift:43`, `StartAnimation.swift`): the window ground with the Mac's
/// `startanimation.json` (80 frames at 60 fps = 1.333 s, once) in a 520 pt box, held 0.5 s after its end, then faded out
/// with easeOut 0.35 s; a hard stop at 3.5 s. The animation is played by [`crate::lottie::Lottie`] (shape layers with
/// keyframed position and scale). Reduce Motion: the last frame at once, held 0.5 s.
pub struct Curtain {
    ui: Ui<(u8, u32)>,
    start: Option<f64>,
    reduce: bool,
}

/// The animation, in ms (80 frames at 60 fps).
pub const CURTAIN_PLAY_MS: f64 = 80.0 * 1000.0 / 60.0;
/// Hold after the animation.
pub const CURTAIN_AFTER_MS: f64 = 500.0;
/// How long the curtain stays fully opaque, in ms (animation plus the 0.5 s hold).
pub const CURTAIN_HOLD_MS: f64 = CURTAIN_PLAY_MS + CURTAIN_AFTER_MS;
/// The fade out, in ms.
pub const CURTAIN_FADE_MS: f64 = 350.0;
/// The curtain's fade is the catalogued `Curtain` curve: `easeOut(0.35)` (`RootView.swift:44`).
fn curtain_alpha(since_hold_ms: f64) -> f64 {
    swiftly_motion::catalogue::Id::Curtain
        .curve()
        .displacement(since_hold_ms / 1000.0)
}
/// The curtain never stays longer than this (`StartAnimation` hard stop).
pub const CURTAIN_HARD_STOP_MS: f64 = 3500.0;

impl Curtain {
    /// A curtain for `env`.
    pub fn new(env: Env, cx: Cx) -> Curtain {
        let reduce = env.reduce_motion;
        // Rasterised at the size it is drawn: 520 pt for 1024 composition units.
        let lottie = std::rc::Rc::new(crate::lottie::Lottie::load(
            &cx,
            crate::lottie::START_ANIMATION,
            env.scale * 520.0 / 1024.0,
        ));
        let ui = Ui::new(
            move |p: &(u8, u32), env: &Env, _cx: &Cx| {
                let a = f32::from(p.0) / 255.0;
                let frame = f64::from(p.1) / 100.0;
                let art = match (*lottie).as_ref() {
                    Some(l) => l.node(frame, 520.0),
                    None => Node::fixed(520.0, 520.0),
                }
                .a11y(swiftly_ui::a11y::A11yNode::new(
                    "",
                    swiftly_ui::a11y::Role::Image,
                    "Swiftly",
                ));
                let ground = Node::rect(color(colour::REASON), 0.0).frame(
                    Some(env.size.w),
                    Some(env.size.h),
                    Alignment::CENTER,
                );
                ground
                    .overlay(art, Alignment::CENTER)
                    .opacity(a, swiftly_ui::Motion::Instant)
            },
            (255, 0),
            env,
            cx,
        );
        Curtain {
            ui,
            start: None,
            reduce,
        }
    }

    /// A new window size.
    pub fn set_env(&mut self, env: Env) {
        self.reduce = env.reduce_motion;
        self.ui.set_env(env);
    }

    /// The curtain's alpha at `now` (0 once it is gone).
    pub fn alpha(&mut self, now: f64) -> f32 {
        let t0 = *self.start.get_or_insert(now);
        let e = now - t0;
        // Reduce Motion: the still last frame is held 0.5 s, then the usual fade.
        let hold = if self.reduce {
            CURTAIN_AFTER_MS
        } else {
            CURTAIN_HOLD_MS
        };
        if e <= hold {
            1.0
        } else if e >= (hold + CURTAIN_FADE_MS).min(CURTAIN_HARD_STOP_MS) {
            0.0
        } else {
            curtain_alpha(e - hold) as f32
        }
    }

    /// The animation frame at `now` (the last one under Reduce Motion).
    pub fn frame_at(&self, now: f64) -> f64 {
        if self.reduce {
            return 79.99;
        }
        let e = now - self.start.unwrap_or(now);
        (e / 1000.0 * 60.0).clamp(0.0, 79.99)
    }

    /// The curtain's quads at `now`; `None` once it is gone.
    pub fn frame(&mut self, now: f64) -> Option<DrawList> {
        let a = self.alpha(now);
        if a <= 0.0 {
            return None;
        }
        let f = self.frame_at(now);
        self.ui
            .set_parts(((a * 255.0).round() as u8, (f * 100.0).round() as u32));
        Some(self.ui.frame(now))
    }
}

#[cfg(test)]
mod card_tests {
    use super::Card;

    #[test]
    fn the_card_names_the_account_and_drops_the_scheme() {
        assert_eq!(
            Card::account(" demo ", "http://192.168.122.1:18097/"),
            Card::Account {
                name: "demo".into(),
                server: "192.168.122.1:18097".into()
            }
        );
        assert_eq!(
            Card::account("Paul", "https://jf.local.example"),
            Card::Account {
                name: "Paul".into(),
                server: "jf.local.example".into()
            }
        );
    }

    #[test]
    fn the_avatar_letter_is_the_first_letter_of_the_name() {
        assert_eq!(Card::account("demo", "x").initial(), "D");
        assert_eq!(Card::account("émile", "x").initial(), "É");
        assert_eq!(Card::account("", "x").initial(), "S");
        assert_eq!(Card::account("  _-7", "x").initial(), "7");
        assert_eq!(Card::Demo.initial(), "S");
        assert_eq!(Card::Hidden.initial(), "S");
    }
}
