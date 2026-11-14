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
const DEVICE_ROW: &str = "ctxd.";

/// The open tile context menu of one screen: the entries come from [`tile_menu::entries`] (the Mac's eleven), drawn as a
/// small anchored panel with the Mac's shortcuts.
#[derive(Clone, Default, PartialEq)]
pub struct TileMenu {
    ctl: MenuController,
    id: Option<String>,
    entries: Vec<Entry>,
    /// The devices of an open "Abspielen auf \u{2026}" list: id and name, in row order.
    devices: Vec<(String, String)>,
}

/// What a tap or key on the menu decided.
#[derive(Debug, PartialEq, Eq)]
pub enum Pick {
    /// The row `index` of the entries of title `id` was chosen.
    Row(String, usize),
    /// The device `.1` of the open device list of title `.0` was chosen.
    Device(String, String),
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

    /// Opens the device list of "Abspielen auf \u{2026}" for `title` at window point `p`.
    pub fn open_devices(
        &mut self,
        title: &str,
        devices: &[(String, String)],
        p: Point,
        keyboard: bool,
    ) {
        let rows = devices
            .iter()
            .enumerate()
            .map(|(i, (_, name))| {
                popover::MenuEntry::Item(popover::MenuItem::new(
                    Action::from(format!("{DEVICE_ROW}{i}").as_str()),
                    name.clone(),
                ))
            })
            .collect();
        self.ctl.open(rows, Anchor::Pointer(p), 0.0, keyboard);
        self.id = Some(title.to_owned());
        self.entries = Vec::new();
        self.devices = devices.to_vec();
    }

    /// The device behind an activated row action of the device list.
    fn device_of(&self, a: &Action) -> Option<(String, String)> {
        let i = (0..self.devices.len())
            .find(|i| *a == Action::from(format!("{DEVICE_ROW}{i}").as_str()))?;
        Some((
            self.id.clone().unwrap_or_default(),
            self.devices[i].0.clone(),
        ))
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
        if let Some((title, device)) = self.device_of(a) {
            self.close();
            return Some(Pick::Device(title, device));
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
                if let Some((title, device)) = self.device_of(&a) {
                    self.close();
                    return Some(Pick::Device(title, device));
                }
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
        self.devices.clear();
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

/// Which strip a message belongs to. The Mac stacks them at the bottom centre of the content, 10 pt apart, in this order
/// from the top: what went wrong with the group (`SharedError`), then what a tile menu or a start failed to do
/// (`TileMessageStrip`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Strip {
    /// A failure of the shared session (the Mac's `SharedError`).
    Shared,
    /// What a menu action or a start failed to do (`TileMessageStrip`).
    Tile,
}

/// The short messages at the bottom centre of the content (the Mac's `SharedError` and `TileMessageStrip`, both drawn as a
/// `HintStrip`): a capsule 34 high on `raised` with a 1 px `margin` border, 20 pt above the bottom edge, at most one per
/// [`Strip`], stacked 10 pt apart. A click on one or four seconds withdraws that one. They show what failed where no
/// screen of its own can say it (a title whose plan the server refused).
pub struct HintBar {
    ui: Ui<Vec<(Strip, String)>>,
    /// The strips in view with the time each appeared (ms).
    strips: Vec<(Strip, String, f64)>,
}

/// How long a strip stays, in ms (`TileMessageStrip`: 4 s).
pub const HINT_MS: f64 = 4000.0;

fn strip_key(s: Strip) -> &'static str {
    match s {
        Strip::Shared => "hint.shared",
        Strip::Tile => "hint",
    }
}

impl HintBar {
    /// A strip for a content area of `env`.
    pub fn new(env: Env, cx: Cx) -> HintBar {
        let ui = Ui::new(
            move |p: &Vec<(Strip, String)>, env: &Env, cx: &Cx| {
                let lk = crate::detail_screen::look(env);
                let kids: Vec<Node> = p
                    .iter()
                    .map(|(kind, m)| {
                        crate::detail_screen::txt(
                            cx,
                            m,
                            crate::detail_screen::weight(lk.body, 15.0, 400),
                            colour::FONT,
                            Some(1),
                        )
                        .padding(home::ins(0.0, 14.0, 0.0, 14.0))
                        .frame(None, Some(34.0), Alignment::CENTER)
                        .background(
                            Node::rect(color(colour::RAISED), 17.0).paint(
                                swiftly_ui::Paint::Stroke {
                                    color: color(colour::MARGIN),
                                    width: 1.0,
                                    radius: 17.0,
                                },
                            ),
                            Alignment::CENTER,
                        )
                        .key(strip_key(*kind))
                        .appear_from(0.97, 0.0)
                        .exit_to(0.97, 0.0)
                    })
                    .collect();
                home::fill_frame(
                    Node::vstack(Align::Center, Some(10.0), kids)
                        .padding(home::ins(0.0, 0.0, 20.0, 0.0)),
                    Alignment::BOTTOM,
                )
            },
            Vec::new(),
            env,
            cx,
        );
        HintBar {
            ui,
            strips: Vec::new(),
        }
    }

    /// A new content size.
    pub fn set_env(&mut self, env: Env) {
        self.ui.set_env(env);
    }

    fn publish(&mut self) {
        self.strips.sort_by_key(|s| s.0);
        self.ui.set_parts(
            self.strips
                .iter()
                .map(|(k, t, _)| (*k, t.clone()))
                .collect(),
        );
    }

    /// Shows `text` in the tile strip from `now` (a new text replaces the one in view and restarts the four seconds).
    pub fn show(&mut self, text: &str, now: f64) {
        self.show_in(Strip::Tile, text, now);
    }

    /// Shows `text` in `strip` from `now`.
    pub fn show_in(&mut self, strip: Strip, text: &str, now: f64) {
        self.strips.retain(|s| s.0 != strip);
        self.strips.push((strip, text.to_owned(), now));
        self.publish();
    }

    /// Withdraws every strip.
    pub fn dismiss(&mut self) {
        self.strips.clear();
        self.publish();
    }

    /// Withdraws the strip at `(x, y)` (content points); whether there was one.
    pub fn tap(&mut self, x: f32, y: f32) -> bool {
        let hit = self
            .strips
            .iter()
            .map(|s| s.0)
            .find(|k| self.hits_strip(*k, x, y));
        let Some(kind) = hit else { return false };
        self.strips.retain(|s| s.0 != kind);
        self.publish();
        true
    }

    /// The text in the tile strip.
    pub fn text(&self) -> Option<&str> {
        self.text_in(Strip::Tile)
    }

    /// The text in `strip`.
    pub fn text_in(&self, strip: Strip) -> Option<&str> {
        self.strips
            .iter()
            .find(|s| s.0 == strip)
            .map(|s| s.1.as_str())
    }

    fn hits_strip(&self, kind: Strip, x: f32, y: f32) -> bool {
        self.ui
            .frame_of(strip_key(kind))
            .is_some_and(|f| x >= f[0] && x <= f[0] + f[2] && y >= f[1] && y <= f[1] + f[3])
    }

    /// Whether `(x, y)` (content points) is on a strip.
    pub fn hits(&self, x: f32, y: f32) -> bool {
        self.strips.iter().any(|s| self.hits_strip(s.0, x, y))
    }

    /// The strips over the content at `now`, and whether they still want frames.
    pub fn frame(&mut self, now: f64) -> (DrawList, bool) {
        if self.strips.iter().any(|s| now - s.2 >= HINT_MS) {
            self.strips.retain(|s| now - s.2 < HINT_MS);
            self.publish();
        }
        let list = self.ui.frame(now);
        (list, self.ui.needs_frame() || !self.strips.is_empty())
    }
}

/// The shell's "Fassung wählen" (`.versionChoice` on the Mac's `MainView`, a confirmation dialog): a title with several
/// versions asks which one to start, wherever the play came from (a tile menu, a row, the player's next title). A card
/// centred over the window on a dim ground: the heading, one row per version (`versionLabel`) and "Abbrechen".
pub struct VersionDialog {
    ui: Ui<Option<Vec<String>>>,
    labels: Option<Vec<String>>,
}

/// What a click on the version dialog meant.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VersionClick {
    /// The version in this row.
    Pick(usize),
    /// "Abbrechen", or a click beside the card.
    Cancel,
    /// On the card but on nothing that acts.
    Inside,
}

/// The heading of the dialog (the Mac's literal).
pub const VERSION_TITLE: &str = "Fassung wählen";

impl VersionDialog {
    /// A dialog for a window of `env`.
    pub fn new(env: Env, cx: Cx) -> VersionDialog {
        let ui = Ui::new(
            move |p: &Option<Vec<String>>, env: &Env, cx: &Cx| {
                let lk = crate::detail_screen::look(env);
                let Some(labels) = p else {
                    return Node::spacer().frame(Some(0.0), Some(0.0), Alignment::CENTER);
                };
                let row = |text: &str, key: String, accent: bool| {
                    crate::detail_screen::wide(
                        crate::detail_screen::txt(
                            cx,
                            text,
                            crate::detail_screen::weight(lk.body, lk.body.size, 600),
                            if accent {
                                colour::MARK_ACCENT
                            } else {
                                colour::FONT
                            },
                            Some(1),
                        )
                        .padding(home::ins(0.0, 16.0, 0.0, 16.0))
                        .frame(None, Some(40.0), Alignment::LEADING),
                        Alignment::LEADING,
                    )
                    .key(key.as_str())
                    .a11y(swiftly_ui::a11y::A11yNode::new(
                        key.as_str(),
                        swiftly_ui::a11y::Role::Button,
                        text,
                    ))
                };
                let mut kids = vec![
                    crate::detail_screen::txt(
                        cx,
                        VERSION_TITLE,
                        crate::detail_screen::weight(lk.body, lk.body.size + 2.0, 600),
                        colour::FONT,
                        Some(1),
                    )
                    .padding(home::ins(0.0, 16.0, 8.0, 16.0)),
                ];
                for (i, l) in labels.iter().enumerate() {
                    kids.push(row(l, format!("ver:{i}"), false));
                }
                kids.push(row("Abbrechen", "ver:cancel".to_owned(), true));
                let card = Node::vstack(Align::Start, Some(2.0), kids)
                    .padding(home::ins(8.0, 8.0, 8.0, 8.0))
                    .frame(Some(420.0), None, Alignment::TOP_LEADING)
                    .background(
                        Node::rect(color(colour::RAISED), 16.0).paint(swiftly_ui::Paint::Stroke {
                            color: color(colour::MARGIN),
                            width: 1.0,
                            radius: 16.0,
                        }),
                        Alignment::CENTER,
                    )
                    .key("ver:card")
                    .a11y(swiftly_ui::a11y::A11yNode::new(
                        "ver:card",
                        swiftly_ui::a11y::Role::Dialog,
                        VERSION_TITLE,
                    ))
                    .appear_from(0.97, 0.0);
                home::fill_frame(card, Alignment::CENTER).background(
                    Node::rect(Color::new(0.0, 0.0, 0.0, 0.35), 0.0),
                    Alignment::CENTER,
                )
            },
            None,
            env,
            cx,
        );
        VersionDialog { ui, labels: None }
    }

    /// A new window size.
    pub fn set_env(&mut self, env: Env) {
        self.ui.set_env(env);
    }

    /// Opens the dialog over `labels` (one per version), or closes it with `None`.
    pub fn set(&mut self, labels: Option<Vec<String>>) {
        self.labels = labels.clone();
        self.ui.set_parts(labels);
    }

    /// Whether the dialog is open.
    pub fn is_open(&self) -> bool {
        self.labels.is_some()
    }

    /// What a screen reader gets: the dialog, its heading and one button per version and "Abbrechen"; nothing when closed.
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        if self.is_open() {
            self.ui.a11y_nodes()
        } else {
            Vec::new()
        }
    }

    /// What a click at `(x, y)` meant; `None` when the dialog is closed.
    pub fn click(&self, x: f32, y: f32) -> Option<VersionClick> {
        let labels = self.labels.as_ref()?;
        let inside = |key: &str| {
            self.ui
                .frame_of(key)
                .is_some_and(|f| x >= f[0] && x <= f[0] + f[2] && y >= f[1] && y <= f[1] + f[3])
        };
        if let Some(i) = (0..labels.len()).find(|i| inside(&format!("ver:{i}"))) {
            return Some(VersionClick::Pick(i));
        }
        Some(if inside("ver:cancel") || !inside("ver:card") {
            VersionClick::Cancel
        } else {
            VersionClick::Inside
        })
    }

    /// The dialog over the window at `now`, and whether it still wants frames.
    pub fn frame(&mut self, now: f64) -> (DrawList, bool) {
        let list = self.ui.frame(now);
        (list, self.ui.needs_frame())
    }
}

/// What a tap on the Discord card meant.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CardTap {
    /// "Discord beitreten": open the invitation and close the card.
    Join,
    /// The X: close the card.
    Close,
}

/// The hint about the Discord after a few finished titles (`RootView.swift:110`, `DiscordHint`): a 320 pt card at the
/// bottom right of the content, 20 pt in, `raised` with a 1 px `margin` border, title and X, two lines of text and the
/// primary button. The Mac shows it 1.5 s after the player closed and never while a player is open.
pub struct DiscordCard {
    ui: Ui<bool>,
    open: bool,
}

/// Delay between the player closing and the card showing, in ms (`RootView.swift:87`).
pub const DISCORD_CARD_DELAY_MS: f64 = 1500.0;

impl DiscordCard {
    /// A card for a content area of `env`.
    pub fn new(env: Env, cx: Cx) -> DiscordCard {
        let icons = swiftly_ui::icons::Icons::new(&cx, env.scale);
        let ui = Ui::new(
            move |p: &bool, env: &Env, cx: &Cx| {
                let lk = crate::detail_screen::look(env);
                let txt = crate::detail_screen::txt;
                let weight = crate::detail_screen::weight;
                let mut kids = Vec::new();
                if *p {
                    let title = txt(
                        cx,
                        "Swiftly hat einen Discord",
                        weight(lk.body, 17.0, 600),
                        colour::FONT,
                        Some(1),
                    );
                    let close = icons
                        .node("x", 12.0, true, color(colour::FONT_QUIET))
                        .frame(Some(24.0), Some(24.0), Alignment::CENTER)
                        .hover_surface(Color::new(1.0, 1.0, 1.0, feel::HOVER_SURFACE_ALPHA), 6.0)
                        .a11y(swiftly_ui::a11y::A11yNode::new(
                            "",
                            swiftly_ui::a11y::Role::Button,
                            "Schlie\u{00DF}en",
                        ))
                        .key("discord-x")
                        .on_tap(Action::from("discord-x"));
                    let head = Node::hstack(
                        Align::Center,
                        Some(8.0),
                        vec![crate::detail_screen::wide(title, Alignment::LEADING), close],
                    );
                    let body = txt(
                        cx,
                        "Da kannst du Fragen stellen und Fehler melden. Neue Builds stehen da auch zuerst.",
                        weight(lk.body, 14.0, 400),
                        colour::FONT_QUIET,
                        Some(3),
                    );
                    let join = Node::hstack(
                        Align::Center,
                        Some(9.0),
                        vec![
                            icons.node("chats", 17.0, true, color(colour::REASON)),
                            txt(
                                cx,
                                "Discord beitreten",
                                weight(lk.body, 17.0, 600),
                                colour::REASON,
                                Some(1),
                            ),
                        ],
                    )
                    .frame(Some(288.0), Some(48.0), Alignment::CENTER)
                    .background(Node::rect(color(colour::FONT), 10.0), Alignment::CENTER)
                    .hover_surface(Color::new(0.0, 0.0, 0.0, 0.12), 10.0)
                    .key("discord-join")
                    .on_tap(Action::from("discord-join"));
                    kids.push(
                        Node::vstack(
                            Align::Start,
                            Some(10.0),
                            vec![head, body, join.padding(home::ins(4.0, 0.0, 0.0, 0.0))],
                        )
                        .padding(home::ins(16.0, 16.0, 16.0, 16.0))
                        .frame(Some(320.0), None, Alignment::TOP_LEADING)
                        .background(
                            Node::rect(color(colour::RAISED), 16.0).paint(
                                swiftly_ui::Paint::Stroke {
                                    color: color(colour::MARGIN),
                                    width: 1.0,
                                    radius: 16.0,
                                },
                            ),
                            Alignment::CENTER,
                        )
                        .key("discord-card")
                        .appear_from(0.97, 0.0)
                        .exit_to(0.97, 0.0),
                    );
                }
                home::fill_frame(
                    Node::vstack(Align::End, Some(0.0), kids)
                        .padding(home::ins(0.0, 0.0, 20.0, 20.0)),
                    Alignment::BOTTOM_TRAILING,
                )
            },
            false,
            env,
            cx,
        );
        DiscordCard { ui, open: false }
    }

    /// A new content size.
    pub fn set_env(&mut self, env: Env) {
        self.ui.set_env(env);
    }

    /// Whether the card is in view.
    pub fn is_open(&self) -> bool {
        self.open
    }

    /// Shows or withdraws the card.
    pub fn set_open(&mut self, open: bool) {
        self.open = open;
        self.ui.set_parts(open);
    }

    /// A click at `(x, y)` (content points): what it hit, if the card is open.
    pub fn click(&self, x: f32, y: f32) -> Option<CardTap> {
        if !self.open {
            return None;
        }
        let on = |key: &str| {
            self.ui
                .frame_of(key)
                .is_some_and(|f| x >= f[0] && x <= f[0] + f[2] && y >= f[1] && y <= f[1] + f[3])
        };
        if on("discord-join") {
            Some(CardTap::Join)
        } else if on("discord-x") {
            Some(CardTap::Close)
        } else {
            None
        }
    }

    /// Whether `(x, y)` is on the card (it swallows the click).
    pub fn hits(&self, x: f32, y: f32) -> bool {
        self.open
            && self
                .ui
                .frame_of("discord-card")
                .is_some_and(|f| x >= f[0] && x <= f[0] + f[2] && y >= f[1] && y <= f[1] + f[3])
    }

    /// The card over the content at `now`, and whether it still wants frames.
    pub fn frame(&mut self, now: f64) -> (DrawList, bool) {
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
    /// The offer row ("Hier weiterschauen", "Gemeinsam schauen", "Läuft gerade") was tapped.
    Offer,
}

/// What the offer row at the bottom of the sidebar says (`OfferingRow`): something plays on another device, a group is
/// open to join, or both. Set by the app, read by every sidebar.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Offer {
    /// The icon: the first device's kind, or the group's.
    pub symbol: String,
    /// "Hier weiterschauen", "Gemeinsam schauen" or, with more than one entry, "Läuft gerade".
    pub title: String,
    /// What is running: the titles and group names in a row.
    pub under: String,
    /// How many entries the picker would have; a counter shows from two.
    pub count: usize,
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
        /// The address of the user's picture (`userImageURL()`, 480 px, with the token); `None` without one.
        picture: Option<String>,
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
            picture: None,
        }
    }

    /// What the page error texts call the server: the account's address, else "Der Server" (`serverAddress ?? "Der
    /// Server"`). The scripted demo names its sample host.
    pub fn server_name(&self) -> String {
        match self {
            Card::Demo => crate::home_data::SERVER.to_owned(),
            Card::Account { server, .. } if !server.is_empty() => server.clone(),
            _ => "Der Server".to_owned(),
        }
    }

    /// The same card with the user's picture address.
    #[must_use]
    pub fn with_picture(self, address: Option<String>) -> Card {
        match self {
            Card::Account { name, server, .. } => Card::Account {
                name,
                server,
                picture: address,
            },
            other => other,
        }
    }

    /// The address of the user's picture, when the card has one.
    pub fn picture(&self) -> Option<&str> {
        match self {
            Card::Account { picture, .. } => picture.as_deref(),
            _ => None,
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

/// Whether the Downloads feature is switched on (`downloadsAn`). Without it the sidebar has no "Downloads" row and no
/// download button shows (`AppModel.swift:228`). The demo app shows them.
pub fn downloads_on() -> bool {
    DOWNLOADS_ON.with(std::cell::Cell::get)
}

/// Sets [`downloads_on`] (the settings switch, and the stored value when the app signs in).
pub fn set_downloads_on(on: bool) {
    DOWNLOADS_ON.with(|d| d.set(on));
}

thread_local! {
    static DOWNLOADS_ON: std::cell::Cell<bool> = const { std::cell::Cell::new(true) };
    static CARD: std::cell::RefCell<Card> = const { std::cell::RefCell::new(Card::Demo) };
    static OFFER: std::cell::RefCell<Option<Offer>> = const { std::cell::RefCell::new(None) };
    static GO: std::cell::Cell<Option<Go>> = const { std::cell::Cell::new(None) };
    static DOWNLOADS_FRONT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static SETTINGS_FRONT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static MINE: std::cell::Cell<(bool, bool)> = const { std::cell::Cell::new((true, true)) };
    static LIST_CHANGES: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
    static HINTS: std::cell::RefCell<Vec<String>> = const { std::cell::RefCell::new(Vec::new()) };
}

/// A screen has something to say that no screen of its own can: the suite shows it in the strip at the bottom of the
/// content (the Mac's `TileMessage.shared.text`), once, on its next frame.
pub fn post_hint(text: String) {
    HINTS.with(|h| h.borrow_mut().push(text));
}

/// The hints posted since the last call, oldest first.
pub fn take_hints() -> Vec<String> {
    HINTS.with(|h| std::mem::take(&mut *h.borrow_mut()))
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

/// The app tells the sidebars which "Meins" rows exist: the Merkliste and the Downloads, each only when its setting is on
/// (`Region.mineGroup(downloads:watchlist:)`).
pub fn set_mine(watchlist: bool, downloads: bool) {
    MINE.with(|m| m.set((watchlist, downloads)));
}

/// The app tells the sidebars what the offer row shows (`None`: no row).
pub fn set_offer(offer: Option<Offer>) {
    OFFER.with(|o| {
        if *o.borrow() != offer {
            *o.borrow_mut() = offer;
        }
    });
}

/// The offer row of the sidebars now.
pub fn offer() -> Option<Offer> {
    OFFER.with(|o| o.borrow().clone())
}

/// The "Meins" rows that exist now: (Merkliste, Downloads).
pub fn mine() -> (bool, bool) {
    MINE.with(std::cell::Cell::get)
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
    } else if *a == Action::from("go:offer") {
        GO.with(|g| g.set(Some(Go::Offer)));
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
            )
            .icon(tile_menu::icon(e, host));
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
    /// Start moving the window from a drag of the bare background (the player); never a double-click maximise.
    MoveWindow,
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
                server: "192.168.122.1:18097".into(),
                picture: None,
            }
        );
        assert_eq!(
            Card::account("Paul", "https://jf.local.example"),
            Card::Account {
                name: "Paul".into(),
                server: "jf.local.example".into(),
                picture: None,
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

#[cfg(test)]
mod version_dialog_a11y_tests {
    use super::*;
    use swiftly_ui::a11y::Role;

    /// The "Fassung wählen" card is a dialog with one button per version and "Abbrechen" for a screen reader.
    #[test]
    fn the_version_choice_is_in_the_accessibility_tree() {
        let env = Env::new(
            swiftly_layout::Size::new(1280.0, 800.0),
            1.0,
            swiftly_ui::Idiom::Desktop,
        );
        let mut d = VersionDialog::new(env, Cx::deterministic());
        let _ = d.frame(0.0);
        assert!(d.a11y_nodes().is_empty(), "closed: nothing");
        d.set(Some(vec!["1080p HEVC".into(), "4K Dolby Vision".into()]));
        let _ = d.frame(100.0);
        let tree = d.a11y_nodes();
        let all: Vec<&swiftly_ui::a11y::A11yNode> = tree.iter().flat_map(|n| n.walk()).collect();
        let dialog = all
            .iter()
            .find(|n| n.role == Role::Dialog)
            .expect("a dialog");
        assert_eq!(dialog.label, VERSION_TITLE);
        for label in ["1080p HEVC", "4K Dolby Vision", "Abbrechen"] {
            assert!(
                all.iter()
                    .any(|n| n.role == Role::Button && n.label == label),
                "{label}: no button"
            );
        }
    }
}
