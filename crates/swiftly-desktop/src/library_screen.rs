//! The Library grid screen (Movies, Series, one genre) of the shared Rust UI, drawn from `LibraryVm` parts for `touch`,
//! `desktop` and `tv`. Differences from the Swift screens are noted in the code.

use crate::browse::{self, Art, Grid, Metrics, Scenario, SheetRow};
use crate::home::{Bar, Form, TABS, empty_state, fill_frame, ins};
use crate::hub::HubSlotExt;
use crate::load_panel::{self, LoadSpec};
use crate::net::AppTransport;
use crate::tile_menu::{self, Cx as TCx, Entry};
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::Arc;
use swiftly_design::tokens::{colour, desktop, touch};
use swiftly_layout::{Align, Alignment, Axis};
use swiftly_library::library_filter::Sorting;
use swiftly_library::{LibraryFilter, MemoryKeyValue, RememberGenre, ShelfSource, SortingExt};
use swiftly_render::{Color, DrawList, RgbaImage};
use swiftly_rules::alphabet_index::{AlphabetIndex, Entry as IndexEntry};
use swiftly_ui::components::color;
use swiftly_ui::icons::Icons;
use swiftly_ui::{Action, Cx, Env, Node, Ui, UiEvent};
use swiftly_vm::{
    GridPart, LibraryIntent, LibraryList, LibrarySpec, LibraryStatus, LibraryStatusPart, LibraryVm,
    Tile, TileRequest,
};

thread_local! {
    /// `ScrollRemember.state`: scroll offsets of library pages, kept while the page is gone (Detail on top, bar switch).
    static REMEMBER: RefCell<HashMap<String, f64>> = RefCell::new(HashMap::new());
}

/// Width of the letter strip (`AlphabetRail.width`).
const RAIL_WIDTH: f32 = 22.0;
/// Strips only appear for long lists (`LibraryView.shownAlphabet`).
const RAIL_MIN_TITLES: usize = 40;

/// The sort orders in the menu (`Sorting.allCases`) and their labels.
pub const SORTINGS: [(Sorting, &str); 4] = [
    (Sorting::Name, "Nach Name"),
    (Sorting::Latest, "Zuletzt"),
    (Sorting::Rating, "Bewertung"),
    (Sorting::Erscheinung, "Jahr"),
];
/// The filters in the menu (`LibraryFilter.allCases`) and their labels.
pub const FILTERS: [(LibraryFilter, &str); 4] = [
    (LibraryFilter::All, "Alle"),
    (LibraryFilter::Begun, "Angefangen"),
    (LibraryFilter::Watchlist, "Merkliste"),
    (LibraryFilter::Unwatched, "Ungesehen"),
];

/// The kinds of the Merkliste pill (`RememberGenre.allCases`) and their labels.
pub const KINDS: [(RememberGenre, &str); 3] = [
    (RememberGenre::All, "Alle"),
    (RememberGenre::Movies, "Filme"),
    (RememberGenre::SeriesList, "Serien"),
];

/// What the page shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Kind {
    /// The movies of the library (tab "Filme").
    Movies,
    /// The series (tab "Serien").
    Series,
    /// One genre page, titled with the genre.
    Genre(String),
    /// The watchlist ("Merkliste"): the movies grid on its own page with the watchlist filter.
    Watchlist,
}

impl Kind {
    fn title(&self) -> &str {
        match self {
            Kind::Movies => "Filme",
            Kind::Series => "Serien",
            Kind::Genre(g) => g,
            Kind::Watchlist => "Merkliste",
        }
    }
    fn tab(&self) -> usize {
        match self {
            Kind::Watchlist => 4,
            _ => {
                usize::from(!matches!(self, Kind::Movies)) + 1
                    - usize::from(matches!(self, Kind::Genre(_)))
            }
        }
    }
}

/// The open sheet.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Open {
    None,
    Sort,
    Filter,
    /// The kind pill of the Merkliste (Alle, Filme, Serien).
    Kind,
    Menu(String),
    /// The title menu: libraries, collections, playlists.
    Section,
    /// "Abspielen auf …" of a tile.
    Devices(String),
    /// The download sheet of a tile.
    Load(String),
}

#[derive(Clone, PartialEq)]
struct Parts {
    status: Arc<LibraryStatusPart>,
    grid: Arc<GridPart>,
    bar: Bar,
    open: Open,
    favourites: Vec<String>,
    /// The kind the Merkliste shows.
    kind: RememberGenre,
    mcx: TCx,
    load: LoadSpec,
    list: Option<LibraryList>,
    cards: Vec<Tile>,
    /// The posters of the collection cards without a picture of their own (`CollectionMosaic`).
    mosaics: Arc<HashMap<String, Vec<swiftly_vm::ImageRef>>>,
    rail: Option<RailPart>,
    pictures: u64,
    pop: crate::desk::Pop,
}

/// What the letter strip draws.
#[derive(Clone, PartialEq)]
struct RailPart {
    shown: Vec<IndexEntry>,
    lit: Option<String>,
    row: f32,
    top: f32,
    height: f32,
}

struct Ctx {
    art: Art,
    icons: Icons,
    title: String,
}

fn label<T: PartialEq + Copy>(all: &[(T, &'static str)], v: T) -> &'static str {
    all.iter().find(|(x, _)| *x == v).map_or("", |(_, l)| l)
}

fn body(cx: &Cx, env: &Env, p: &Parts, ctx: &Ctx) -> Node {
    let m: Metrics = browse::metrics(env);
    let g: Grid = browse::grid(&m, env.size.w);
    let mut col: Vec<Node> = Vec::new();
    // The Merkliste is a page of its own (Mac `WatchlistView`): its title is fixed, no libraries menu, no filter pill (the
    // filter IS the page). The view model's list is the movies library's, so it must not rename the page.
    let watch = p.bar.tab == 4;
    let list = p.list.as_ref().filter(|_| !watch);
    let menu = list.is_some_and(|l| l.is_menu);
    let shown_title = list.map_or(ctx.title.as_str(), |l| l.title.as_str());
    let cards = list.is_some_and(|l| l.cards);
    if menu {
        // `TitleSelection`: the large title is the menu ("Filme \u{2304}"); the compact one lives in the bar.
        let head = Node::hstack(
            Align::Center,
            Some(8.0),
            vec![
                browse::heading(cx, &m, shown_title).padding(ins(0.0, 0.0, 0.0, -m.edge)),
                ctx.icons
                    .node("caret-down", 14.0, true, color(colour::FONT_QUIET)),
            ],
        )
        .padding(ins(
            if m.form == Form::Touch { 4.0 } else { 0.0 },
            0.0,
            0.0,
            0.0,
        ))
        .key("lib.title")
        .on_tap(Action::from("lib.title"));
        col.push(head);
    } else if m.form == Form::Desktop {
        col.push(browse::heading(cx, &m, shown_title));
    }
    let tv = m.form == Form::Tv;
    let controls = Node::hstack(
        Align::Center,
        Some(if tv { 20.0 } else { 8.0 }),
        if cards {
            vec![Node::spacer()]
        } else {
            let mut row = Vec::new();
            if m.form == Form::Desktop {
                // Mac: `SelectionButton` pills with a caret; the filter pill carries no symbol (the Merkliste's has one).
                row.push(if watch {
                    browse::popup_chip(
                        cx,
                        &ctx.icons,
                        Some("squares-four"),
                        label(&KINDS, p.kind),
                        "lib.kind",
                    )
                } else {
                    browse::popup_chip(
                        cx,
                        &ctx.icons,
                        None,
                        label(&FILTERS, p.status.filter),
                        "lib.filter",
                    )
                });
                row.push(browse::popup_chip(
                    cx,
                    &ctx.icons,
                    Some("arrows-down-up"),
                    label(&SORTINGS, p.status.sorting),
                    "lib.sort",
                ));
            } else if watch {
                row.push(browse::value_pill(
                    cx,
                    &ctx.icons,
                    "squares-four",
                    label(&KINDS, p.kind),
                    "lib.kind",
                    tv,
                ));
            } else {
                row.push(browse::value_pill(
                    cx,
                    &ctx.icons,
                    "funnel",
                    label(&FILTERS, p.status.filter),
                    "lib.filter",
                    tv,
                ));
            }
            if m.form != Form::Desktop {
                row.push(browse::value_pill(
                    cx,
                    &ctx.icons,
                    "arrows-down-up",
                    label(&SORTINGS, p.status.sorting),
                    "lib.sort",
                    tv,
                ));
            }
            row.push(Node::spacer());
            row.push(if p.grid.total > 0 && (m.form != Form::Desktop || watch) {
                browse::count_mark(cx, p.grid.total, tv)
            } else {
                Node::fixed(0.0, 0.0)
            });
            row
        },
    )
    .padding(ins(if tv { 0.0 } else { 14.0 }, m.edge, 0.0, m.edge))
    .frame(
        None,
        Some(if tv { 56.0 } else { 30.0 + 14.0 }),
        Alignment::TOP_LEADING,
    );
    col.push(controls);
    // tv: the grid starts `capsuleRailPadding` (48) under the 56 high chip row.
    let grid_pad = ins(if tv { 48.0 } else { 22.0 }, m.edge, 0.0, m.edge);
    match (p.status.status, p.grid.tiles.is_empty()) {
        _ if cards => {
            // Collections and playlists in the same grid with the same tile; the count line stands where the year does.
            let rows: Vec<Node> = p
                .cards
                .chunks(g.columns)
                .enumerate()
                .map(|(r, chunk)| {
                    let cells = chunk
                        .iter()
                        .enumerate()
                        .map(|(c, t)| {
                            let key = format!("c:{}", r * g.columns + c);
                            let mosaic = p.mosaics.get(&t.id).map(Vec::as_slice);
                            browse::grid_tile_with(cx, &ctx.icons, &m, &ctx.art, t, &g, &key, mosaic)
                        })
                        .collect();
                    Node::hstack(Align::Start, Some(g.gap), cells)
                })
                .collect();
            col.push(Node::vstack(Align::Start, Some(m.row_gap), rows).padding(grid_pad).reveal_as("lib.grid"));
        }
        (LibraryStatus::Loading, _) => col.push(browse::grid_placeholder(&m, &g, 2).padding(grid_pad).reveal_as("lib.loading")),
        (LibraryStatus::Offline, true) => col.push(empty_state(
            cx,
            &ctx.icons,
            "hard-drive-x",
            "Server ist abgetaucht",
            &format!("{} antwortet nicht. Läuft er noch, oder hängt das WLAN?", crate::desk::card().server_name()),
            "Erneut versuchen",
        )
        .padding(ins(80.0, 0.0, 0.0, 0.0))),
        // The Merkliste page itself: its filter is the page, so "pick another filter" would make no sense here.
        (_, true) if watch => col.push(
            empty_state(
                cx,
                &ctx.icons,
                "bookmark-simple",
                "Noch nichts gemerkt",
                "Auf jeder Film- und Serienseite steht „Merkliste“ in der Knopfreihe. Was du dort antippst, sammelt sich hier.",
                "Aktualisieren",
            )
            .padding(ins(80.0, 0.0, 0.0, 0.0)),
        ),
        (_, true) => {
            let narrowed = p.status.filter != LibraryFilter::All;
            col.push(
                empty_state(
                    cx,
                    &ctx.icons,
                    if narrowed { "funnel" } else { "tray" },
                    if narrowed { "Nichts gefunden" } else { "Hier ist noch nichts" },
                    &if narrowed {
                        format!("Unter \u{201E}{}\u{201C} liegt gerade nichts. Nimm einen anderen Filter.", label(&FILTERS, p.status.filter))
                    } else {
                        "Sobald in dieser Bibliothek etwas liegt, taucht es hier auf.".to_owned()
                    },
                    if narrowed { "Filter zurücksetzen" } else { "Aktualisieren" },
                )
                .padding(ins(80.0, 0.0, 0.0, 0.0)),
            );
        }
        _ => {
            let tiles = &p.grid.tiles;
            let rows: Vec<Node> = tiles
                .chunks(g.columns)
                .enumerate()
                .map(|(r, chunk)| {
                    let cells = chunk
                        .iter()
                        .enumerate()
                        .map(|(c, t)| browse::grid_tile(cx, &ctx.icons, &m, &ctx.art, t, &g, &format!("t:{}", r * g.columns + c)))
                        .collect();
                    Node::hstack(Align::Start, Some(g.gap), cells)
                })
                .collect();
            col.push(Node::vstack(Align::Start, Some(m.row_gap), rows).padding(grid_pad));
            if p.status.load_more_failed {
                col.push(
                    crate::home::text(cx, "Erneut versuchen", swiftly_design::TextStyle { size: 15.0, weight: 500, tracking: 0.0, uppercase: false }, colour::MARK_ACCENT, Some(1), swiftly_text::Align::Center)
                        .frame(None, Some(44.0), Alignment::CENTER)
                        .key("more")
                        .on_tap(Action::from("more")),
                );
            }
        }
    }
    let bottom = match m.form {
        Form::Touch => touch::STRIP_HEIGHT + env.safe.bottom + 12.0,
        Form::Desktop => 40.0,
        Form::Tv => 48.0,
    };
    let top = m.top;
    let column = Node::vstack(Align::Start, Some(0.0), col).padding(ins(top, 0.0, bottom, 0.0));
    let scroll = fill_frame(
        Node::scroll(Axis::Vertical, None, column).key("lib-scroll"),
        Alignment::TOP_LEADING,
    );
    match &p.rail {
        Some(r) => scroll.overlay(
            rail_node(cx, r, rail_inset(env, &m)),
            Alignment::TOP_TRAILING,
        ),
        None => scroll,
    }
}

/// Distance of the strip from the trailing edge: in the margin, centred (`(edgeSpacing - width) / 2`).
fn rail_inset(env: &Env, m: &Metrics) -> f32 {
    let _ = env;
    ((m.edge - RAIL_WIDTH) / 2.0).max(0.0)
}

/// Where the strip sits on the page: `(x, y, height)`. Mac: under the title and chips (`contentTop + 96`), 24 above the
/// foot; touch: under the chip row, above the tab bar. Not on tv (the focus engine has its own `TVAlphabetRail`).
fn rail_box(env: &Env, m: &Metrics) -> Option<(f32, f32, f32)> {
    let (top, foot) = match m.form {
        Form::Desktop => (m.top + 96.0, 24.0),
        Form::Touch => (m.top + 60.0, touch::STRIP_HEIGHT + env.safe.bottom + 12.0),
        Form::Tv => return None,
    };
    Some((
        env.size.w - rail_inset(env, m) - RAIL_WIDTH,
        top,
        (env.size.h - top - foot).max(0.0),
    ))
}

/// `AlphabetRail`: letters (or years, ratings) in 11/600, the lit one in the accent colour, a dot between the steps of a
/// scale. Mac rows are 17 high and the strip sits at the top of its box; touch spreads over the whole height.
/// Design name: AlphabetRail
fn rail_node(cx: &Cx, r: &RailPart, inset: f32) -> Node {
    let mut col: Vec<Node> = Vec::new();
    for e in &r.shown {
        if e.gap {
            col.push(
                Node::rect(color(colour::FONT_VERY_QUIET), 1.5)
                    .frame(Some(3.0), Some(3.0), Alignment::CENTER)
                    .frame(
                        Some(RAIL_WIDTH),
                        Some(r.row * AlphabetIndex::GAP_SHARE as f32),
                        Alignment::CENTER,
                    ),
            );
        }
        let c = if r.lit.as_deref() == Some(e.letter.as_str()) {
            colour::MARK_ACCENT
        } else {
            colour::FONT_QUIET
        };
        col.push(
            crate::home::text(
                cx,
                &e.label,
                swiftly_design::TextStyle {
                    size: 11.0,
                    weight: 600,
                    tracking: 0.0,
                    uppercase: false,
                },
                c,
                Some(1),
                swiftly_text::Align::Center,
            )
            .frame(Some(RAIL_WIDTH), Some(r.row), Alignment::CENTER),
        );
    }
    let strip = Node::vstack(Align::Center, Some(0.0), col).frame(
        Some(RAIL_WIDTH),
        Some(r.height),
        Alignment::TOP,
    );
    strip.padding(ins(r.top, 0.0, 0.0, inset))
}

fn view(p: &Parts, env: &Env, cx: &Cx, ctx: &Ctx) -> Node {
    ctx.art.hub.begin_build();
    let m = browse::metrics(env);
    let overlay = match &p.open {
        Open::None => None,
        Open::Sort | Open::Filter | Open::Kind | Open::Section | Open::Menu(_)
            if m.form == Form::Desktop =>
        {
            None
        }
        Open::Sort => Some(browse::sheet(
            cx,
            &ctx.icons,
            &m,
            "Sortieren",
            &SORTINGS
                .iter()
                .map(|(s, l)| SheetRow {
                    label: (*l).into(),
                    selected: *s == p.status.sorting,
                })
                .collect::<Vec<_>>(),
            "pick.s.",
            true,
        )),
        Open::Filter => Some(browse::sheet(
            cx,
            &ctx.icons,
            &m,
            "Filtern",
            &FILTERS
                .iter()
                .map(|(f, l)| SheetRow {
                    label: (*l).into(),
                    selected: *f == p.status.filter,
                })
                .collect::<Vec<_>>(),
            "pick.f.",
            true,
        )),
        Open::Kind => Some(browse::sheet(
            cx,
            &ctx.icons,
            &m,
            "Anzeigen",
            &KINDS
                .iter()
                .map(|(k, l)| SheetRow {
                    label: (*l).into(),
                    selected: *k == p.kind,
                })
                .collect::<Vec<_>>(),
            "pick.k.",
            true,
        )),
        Open::Section => p.list.as_ref().map(|l| {
            let rows: Vec<SheetRow> = l
                .entries
                .iter()
                .map(|e| SheetRow {
                    label: e.label.clone(),
                    selected: e.selected,
                })
                .collect();
            let heads: Vec<(usize, String)> = l
                .entries
                .iter()
                .enumerate()
                .filter_map(|(i, e)| e.category.clone().map(|c| (i, c)))
                .collect();
            browse::sheet_with(cx, &ctx.icons, &m, &l.title, &rows, "pick.l.", true, &heads)
        }),
        Open::Menu(id) => {
            let tile = p.grid.tiles.iter().find(|t| &t.id == id);
            let mut mcx = p.mcx.clone();
            mcx.favourite = p.favourites.contains(id);
            Some(browse::sheet(
                cx,
                &ctx.icons,
                &m,
                tile.map_or("", |t| t.title.as_str()),
                &tile_menu::rows(m.form, &mcx, tile),
                "pick.m.",
                false,
            ))
        }
        Open::Devices(_) => Some(browse::sheet(
            cx,
            &ctx.icons,
            &m,
            "Abspielen auf \u{2026}",
            &tile_menu::device_rows(&p.mcx),
            "pick.d.",
            false,
        )),
        Open::Load(_) => Some(load_panel::load_sheet(cx, &ctx.icons, env, &p.load)),
    };
    let page = browse::page(
        cx,
        env,
        &ctx.icons,
        &ctx.art.hub,
        p.bar.clone(),
        &ctx.title,
        body(cx, env, p, ctx),
        overlay,
    );
    match p.pop.overlay(cx, env) {
        Some(o) => page.overlay(o, Alignment::TOP_LEADING),
        None => page,
    }
}

/// Waits for the grid to come back on its own. The Mac shows "Erneut versuchen" and reloads when the window comes
/// back to the front; the desktop has no such moment when the server returns while the window stays in front, so an
/// empty "server unreachable" page asks again after 3 s, 6 s, 12 s, 24 s and then every 30 s. It also stops waiting
/// for the libraries of the account after 8 s (the grid then reads the bare section instead of staying on skeletons).
#[derive(Default)]
struct Recovery {
    /// Since when the page has been offline, and the time of the next retry (ms).
    offline: Option<(f64, f64)>,
    tries: u32,
    /// Since when the screen waits for the libraries (ms), and whether it gave up already.
    offering: Option<f64>,
    gave_up: bool,
}

impl Recovery {
    const OFFERING_WAIT: f64 = 8000.0;

    /// Whether to ask again now.
    fn retry_due(&mut self, offline: bool, now: f64) -> bool {
        if !offline {
            self.offline = None;
            self.tries = 0;
            return false;
        }
        let (_, next) = *self.offline.get_or_insert((now, now + 3000.0));
        if now < next {
            return false;
        }
        self.tries += 1;
        let wait = (3000.0 * f64::from(1_u32 << self.tries.min(3))).min(30_000.0);
        let wait = if self.tries > 3 { 30_000.0 } else { wait };
        self.offline = self.offline.map(|(since, _)| (since, now + wait));
        true
    }

    /// Whether the wait for the libraries has run out (once).
    fn offering_overdue(&mut self, waiting: bool, now: f64) -> bool {
        if !waiting {
            self.offering = None;
            return false;
        }
        let since = *self.offering.get_or_insert(now);
        if self.gave_up || now - since < Self::OFFERING_WAIT {
            return false;
        }
        self.gave_up = true;
        true
    }
}

/// The Library screen: a UI over a `LibraryVm`.
pub struct LibraryScreen {
    ui: Ui<Parts>,
    pop: crate::desk::Pop,
    hub: crate::hub::HubSlot,
    vm: LibraryVm<AppTransport>,
    tab: usize,
    open: Open,
    favourites: Vec<String>,
    load: LoadSpec,
    opened: Vec<String>,
    index: Option<(u64, Sorting, Rc<AlphabetIndex>)>,
    /// The letter under the finger, the last one jumped to (until the grid is there) and the one waiting for its page.
    touched: Option<String>,
    held: Option<(String, f64)>,
    pending: Option<String>,
    top_key: Option<String>,
    /// What the scroll position belongs to (choice, sorting, filter); a change scrolls to the top.
    ident: String,
    returned: bool,
    first_frame: Option<f64>,
    now: f64,
    refreshes: u32,
    /// Quiet retries while the server does not answer, and the wait for the libraries of the account.
    recovery: Recovery,
    auto_retries: u32,
    asked: Option<String>,
    columns: usize,
    /// The kind of the Merkliste page (the pill).
    remember: RememberGenre,
    scenario: Scenario,
    /// The libraries of the account on their way (real app).
    offering: Option<crate::login_screen::Pending<Offered>>,
    /// The posters of collection cards without a picture, as they arrive (real app), and what has arrived.
    mosaic_rx: Option<std::sync::mpsc::Receiver<(String, Vec<swiftly_vm::ImageRef>)>>,
    mosaics: Arc<HashMap<String, Vec<swiftly_vm::ImageRef>>>,
}

impl LibraryScreen {
    /// What a screen reader gets for this screen: the nodes of the current picture.
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.ui.a11y_nodes()
    }

    /// A page of `kind` for `env` over a scripted server in `scenario`.
    ///
    /// # Panics
    /// If the view model cannot be built or does not settle within ten seconds.
    pub fn new(env: Env, cx: Cx, kind: &Kind, scenario: Scenario) -> LibraryScreen {
        let series = matches!(kind, Kind::Series);
        let spec = LibrarySpec {
            source: if series {
                ShelfSource::new(Some("lib-shows"), Some("tvshows"), false, &[])
            } else {
                ShelfSource::new(Some("lib-movies"), Some("movies"), false, &[])
            },
            genre: match kind {
                Kind::Genre(g) => Some(g.clone()),
                _ => None,
            },
            remember_name: None,
        };
        let vm = match crate::live::current() {
            Some(w) => LibraryVm::new(
                Arc::clone(&w.core.net),
                w.core.host(),
                Arc::clone(&w.core.kv),
                live_spec(kind),
                Some(w.account.clone()),
            ),
            None => LibraryVm::new(
                Arc::new(AppTransport::Mock(browse::transport(scenario, 90, series))),
                browse::host(),
                Arc::new(MemoryKeyValue::new()),
                spec,
                Some(browse::account()),
            ),
        }
        .unwrap_or_else(|e| panic!("library vm: {e:?}"));
        // The real app loads once the libraries of this section are known: "All" is those libraries, each title once
        // (the Mac's `LibraryView.source`), so a first load from the bare section would show titles twice.
        let waits_for_offering =
            crate::live::current().is_some() && matches!(kind, Kind::Movies | Kind::Series);
        if scenario != Scenario::Loading && !waits_for_offering {
            vm.send(LibraryIntent::Load);
            if matches!(kind, Kind::Watchlist) {
                vm.set_remember_kind(vm.remembered_kind());
            }
            let started = std::time::Instant::now();
            while matches!(vm.status().status, LibraryStatus::Loading) {
                assert!(
                    started.elapsed().as_secs() < 10,
                    "library vm did not settle"
                );
                std::thread::sleep(std::time::Duration::from_millis(2));
            }
        }
        let ctx = Ctx {
            art: Art::new(&cx),
            icons: Icons::new(&cx, env.scale),
            title: kind.title().to_owned(),
        };
        let tab = kind.tab();
        let parts = Parts {
            status: vm.status(),
            grid: vm.grid(),
            bar: Bar {
                tab,
                header: 0,
                downloads: false,
                settings: false,
                card: crate::desk::Card::Demo,
                offer: None,
                mine: (true, true),
                glow: (crate::look_glow::Glow::default(), 0),
            },
            open: Open::None,
            favourites: Vec::new(),
            kind: RememberGenre::All,
            mcx: tile_menu::rail_cx(false, false),
            load: LoadSpec::demo(""),
            list: None,
            cards: Vec::new(),
            mosaics: Arc::default(),
            rail: None,
            pictures: 0,
            pop: crate::desk::Pop::default(),
        };
        let hub = Rc::clone(&ctx.art.hub);
        let ctx = Rc::new(ctx);
        let ui = Ui::new(
            move |p: &Parts, env: &Env, cx: &Cx| view(p, env, cx, &ctx),
            parts,
            env,
            cx,
        );
        let remember = if matches!(kind, Kind::Watchlist) {
            vm.remembered_kind()
        } else {
            RememberGenre::All
        };
        let mut s = LibraryScreen {
            pop: crate::desk::Pop::default(),
            ui,
            hub,
            vm,
            tab,
            open: Open::None,
            favourites: Vec::new(),
            load: LoadSpec::demo(""),
            opened: Vec::new(),
            index: None,
            touched: None,
            held: None,
            pending: None,
            top_key: None,
            ident: String::new(),
            returned: false,
            first_frame: None,
            now: 0.0,
            refreshes: 0,
            recovery: Recovery::default(),
            auto_retries: 0,
            asked: None,
            columns: 3,
            remember,
            scenario,
            offering: None,
            mosaic_rx: None,
            mosaics: Arc::default(),
        };
        s.offer(kind);
        s.sync();
        s
    }

    /// The demo's libraries: two of this kind, three collections and two playlists, so the title is a menu.
    fn offer(&mut self, kind: &Kind) {
        if let Some(w) = crate::live::current() {
            // Real app: one entry per library of the account (`UserViews` of this kind), each with its view id as the
            // parent of the source, like the Swift title menu.
            if matches!(kind, Kind::Movies | Kind::Series) {
                let (offering, mosaics) = fetch_offering(&w, matches!(kind, Kind::Series));
                self.offering = Some(offering);
                self.mosaic_rx = Some(mosaics);
            }
            return;
        }
        if matches!(kind, Kind::Genre(_)) || self.scenario == Scenario::Loading {
            return;
        }
        let series = matches!(kind, Kind::Series);
        let art = if series { "tvshows" } else { "movies" };
        let lib = |id: &str, name: &str| swiftly_model::Item {
            id: id.into(),
            name: name.into(),
            collection_type: Some(art.into()),
            ..swiftly_model::Item::default()
        };
        let (a, b) = if series {
            ("Serien", "Anime")
        } else {
            ("Filme", "Filme 4K")
        };
        self.vm
            .set_offering(swiftly_playback::section_offering::SectionOffering::new(
                art,
                vec![
                    lib(if series { "lib-shows" } else { "lib-movies" }, a),
                    lib("lib-more", b),
                ],
                3,
                2,
            ));
        let card = |i: usize, name: &str, line: &str| Tile {
            id: format!("card-{i}"),
            title: name.into(),
            subtitle: Some(line.into()),
            progress: None,
            image: None,
            badges: Vec::new(),
            remaining: None,
            facts: swiftly_vm::TileFacts::default(),
        };
        let unit = if series { "Serien" } else { "Filme" };
        self.vm.set_cards(
            vec![
                card(0, "Marvel", &format!("12 {unit}")),
                card(1, "Die Tribute von Panem", &format!("4 {unit}")),
                card(2, "Star Wars", &format!("11 {unit}")),
            ],
            vec![
                card(3, "Wochenende", "6 Titel"),
                card(4, "Mit den Kindern", "9 Titel"),
            ],
        );
    }

    /// The collection cards that show a mosaic and how many posters it has so far, by id (tests).
    #[doc(hidden)]
    pub fn mosaic_counts(&self) -> Vec<(String, usize)> {
        let mut all: Vec<_> = self
            .mosaics
            .iter()
            .map(|(k, v)| (k.clone(), v.len()))
            .collect();
        all.sort();
        all
    }

    /// Starts the Merkliste: both kinds (or the one chosen last), favourites only, loaded now.
    pub fn start_watchlist(&mut self) {
        self.remember = self.vm.remembered_kind();
        self.vm.set_remember_kind(self.remember);
    }

    /// The view model.
    pub fn vm(&self) -> &LibraryVm<AppTransport> {
        &self.vm
    }
    /// Titles opened so far (server ids).
    pub fn opened(&self) -> &[String] {
        &self.opened
    }
    /// How many reloads the user started.
    pub fn refreshes(&self) -> u32 {
        self.refreshes
    }
    /// How many times the screen asked again by itself after the server did not answer.
    pub fn auto_retries(&self) -> u32 {
        self.auto_retries
    }
    /// The scenario of the scripted server.
    pub fn scenario(&self) -> Scenario {
        self.scenario
    }
    /// Whether a sheet (sort, filter or tile menu) is open.
    pub fn sheet_open(&self) -> bool {
        self.open != Open::None || self.pop.is_open()
    }
    /// Opens the sort sheet (`"sort"`), the filter sheet (`"filter"`) or the menu of a tile (its id).
    pub fn show(&mut self, what: &str) {
        self.open = match what {
            "sort" => Open::Sort,
            "filter" => Open::Filter,
            "kind" => Open::Kind,
            id => Open::Menu(id.to_owned()),
        };
    }
    /// The tab the bar shows (changes when a bar entry is tapped).
    pub fn tab(&self) -> usize {
        self.tab
    }
    /// Puts the bar back on a tab (the app switched pages and this page stays behind).
    pub fn set_tab(&mut self, tab: usize) {
        self.tab = tab;
    }
    /// Opens the title menu (libraries, collections, playlists).
    pub fn show_section(&mut self) {
        self.open = Open::Section;
    }
    /// Whether the letter strip is drawn.
    pub fn rail_shown(&self) -> bool {
        self.rail_part().is_some()
    }
    /// The strip entry lit now (the letter, year or rating of the topmost title, or the one touched).
    pub fn rail_lit(&self) -> Option<String> {
        self.touched
            .clone()
            .or_else(|| self.held.as_ref().map(|h| h.0.clone()))
            .or_else(|| self.top_key.clone())
    }
    /// Asks for the first title under a strip entry; scrolls there (animated) once loaded, loading pages on the way.
    pub fn jump_to(&mut self, key: &str) {
        self.pending = Some(key.to_owned());
        self.try_jump();
    }
    /// Forgets nothing: stores the scroll offset for the next visit (`onDisappear`).
    pub fn leave(&mut self) {
        let (ident, y) = (self.ident.clone(), self.offset());
        REMEMBER.with(|m| {
            m.borrow_mut().insert(ident, y);
        });
    }
    /// Every scroll offset in tree order (tests, measuring).
    pub fn scroll_offsets(&self) -> Vec<f64> {
        self.ui.scroll_offsets()
    }
    /// The overlay scroll bar's thumb (window points) and opacity (tests, measuring).
    pub fn scroll_bar(&self) -> Option<(swiftly_layout::Rect, f32)> {
        self.ui.scroll_bar()
    }
    /// Page scroll offset.
    pub fn offset(&self) -> f64 {
        self.ui.scroll_offsets().first().copied().unwrap_or(0.0)
    }

    fn geometry(&self) -> (Metrics, browse::Grid, f32, f32) {
        let env = *self.ui.env();
        let m = browse::metrics(&env);
        let g = browse::grid(&m, env.size.w);
        let row_h = g.h + 8.0 + browse::text_height(self.ui.cx(), &m) + m.row_gap;
        let heading = if m.form == Form::Desktop || self.vm.list().is_some_and(|l| l.is_menu) {
            34.0 * 1.25
        } else {
            0.0
        };
        let controls = if m.form == Form::Tv { 56.0 } else { 44.0 };
        let grid_top = m.top + heading + controls + if m.form == Form::Tv { 48.0 } else { 22.0 };
        (m, g, row_h, grid_top)
    }

    fn rail_part(&self) -> Option<RailPart> {
        let env = *self.ui.env();
        let m = browse::metrics(&env);
        let (_, top, height) = rail_box(&env, &m)?;
        let (_, _, index) = self.index.as_ref()?;
        if self.vm.list().is_some_and(|l| l.cards)
            || index.count < RAIL_MIN_TITLES
            || !index.is_useful()
            || height < 28.0
        {
            return None;
        }
        let compact = (m.form == Form::Desktop).then_some(17.0_f32);
        let slots = (height / compact.unwrap_or(14.0)) as i64;
        let shown = index.condensed(slots.max(2));
        let fitted = height / (AlphabetIndex::rows(&shown) as f32).max(1.0);
        let row = compact.map_or(fitted, |c| c.min(fitted));
        let strip = row * AlphabetIndex::rows(&shown) as f32;
        // Mac: the strip sits centred in its box; touch: it spreads over all of it.
        let top = if compact.is_some() {
            top + (height - strip) / 2.0
        } else {
            top
        };
        Some(RailPart {
            height: strip,
            shown,
            lit: self.rail_lit(),
            row,
            top,
        })
    }

    /// Scrolls to the title a pending strip jump asks for, or loads the next page and waits (`jumpTarget`).
    fn try_jump(&mut self) {
        let Some(key) = self.pending.clone() else {
            return;
        };
        let Some((_, _, index)) = self.index.clone() else {
            return;
        };
        if let Some(i) = self.vm.jump_target(&key, &index) {
            let (m, g, row_h, grid_top) = self.geometry();
            let y = f64::from(grid_top + (i / g.columns) as f32 * row_h - (m.top - 8.0));
            let now = self.now;
            self.ui
                .scroll_first_to(Axis::Vertical, y.max(0.0), true, now);
            self.pending = None;
        } else if self.vm.status().more_available && !self.vm.status().loading_more {
            self.vm.send(LibraryIntent::LoadMore);
        } else if !self.vm.status().more_available {
            self.pending = None;
        }
    }

    fn sync(&mut self) {
        let env = *self.ui.env();
        let m = browse::metrics(&env);
        let g = browse::grid(&m, env.size.w);
        self.columns = g.columns;
        let status = self.vm.status();
        let grid = self.vm.grid();
        // The Swift `onAppear` of a tile in one of the last rows: ask for the next page.
        if status.more_available && !grid.tiles.is_empty() {
            let row_h = g.h + 8.0 + browse::text_height(self.ui.cx(), &m) + m.row_gap;
            let seen = (self.offset() as f32 + env.size.h - m.top - 80.0).max(0.0);
            let last =
                (((seen / row_h).floor() as usize + 1) * g.columns).min(grid.tiles.len()) - 1;
            let id = grid.tiles[last].id.clone();
            if self.asked.as_ref() != Some(&id) {
                self.asked = Some(id.clone());
                self.vm.send(LibraryIntent::Visible {
                    id,
                    columns: g.columns as u32,
                });
            }
        }
        // The strip: rebuilt when the list or its order changed.
        if self
            .index
            .as_ref()
            .is_none_or(|(v, so, _)| *v != grid.version || *so != status.sorting)
        {
            self.index = Some((grid.version, status.sorting, Rc::new(self.vm.alphabet())));
        }
        self.try_jump();
        // The topmost loaded title decides the lit entry.
        if let Some((_, _, index)) = self.index.clone() {
            let (_, g, row_h, grid_top) = self.geometry();
            let first = ((self.offset() as f32 - (grid_top - env.size.h.min(0.0))).max(0.0) / row_h)
                .floor() as usize
                * g.columns;
            if let Some(t) = grid
                .tiles
                .get(first.min(grid.tiles.len().saturating_sub(1)))
            {
                self.top_key = self.vm.key_of(&t.id, &index);
            }
        }
        if let Some((_, since)) = &self.held
            && self.now - since > AlphabetIndex::HOLD_SECONDS as f64 * 1000.0
        {
            self.held = None;
        }
        if self
            .held
            .as_ref()
            .is_some_and(|(k, _)| Some(k) == self.top_key.as_ref())
        {
            self.held = None;
        }
        // Scroll position: a new choice, sorting or filter starts at the top; the first titles of a return restore it.
        let choice = self.vm.list().map(|l| l.choice).unwrap_or_default();
        let ident = format!("{choice}|{:?}|{:?}", status.sorting, status.filter);
        if ident != self.ident {
            let first = self.ident.is_empty();
            self.ident = ident;
            if !first {
                self.ui.jump_first_scroll(Axis::Vertical, 0.0);
                self.returned = true;
            }
        }
        if self.first_frame.is_none() {
            self.first_frame = Some(self.now);
        }
        if !self.returned
            && !grid.tiles.is_empty()
            && self.first_frame.is_some_and(|t| self.now - t >= 60.0)
        {
            let y = REMEMBER
                .with(|m| m.borrow().get(&self.ident).copied())
                .unwrap_or(0.0);
            if y > 1.0 {
                self.returned = self.ui.jump_first_scroll(Axis::Vertical, y);
            } else {
                self.returned = true;
            }
        }
        let header = if self.ui.env().idiom == swiftly_ui::Idiom::Desktop {
            crate::home::bar_strength(self.offset() as f32, crate::home::BAR_SINCE, 26.0)
        } else {
            ((self.offset() as f32 / 30.0).clamp(0.0, 1.0) * 8.0).round() as u8
        };
        self.ui.set_parts(Parts {
            status,
            grid,
            bar: Bar {
                tab: self.tab,
                header,
                downloads: crate::desk::downloads_front(),
                settings: crate::desk::settings_front(),
                card: crate::desk::card(),
                offer: crate::desk::offer(),
                mine: crate::desk::mine(),
                glow: crate::look_glow::bar_state(self.offset()),
            },
            open: self.open.clone(),
            favourites: self.favourites.clone(),
            kind: self.remember,
            mcx: tile_menu::rail_cx(false, false),
            load: self.load.clone(),
            list: self.vm.list(),
            cards: self.vm.cards(),
            mosaics: Arc::clone(&self.mosaics),
            rail: self.rail_part(),
            pictures: self.hub.stamp(),
            pop: self.pop.clone(),
        });
    }

    fn drain(&mut self) {
        for ev in self.ui.take_events() {
            match ev {
                UiEvent::Secondary { action: a, x, y }
                    if Form::of(self.ui.env().idiom) == Form::Desktop =>
                {
                    let grid = self.vm.grid();
                    if let Some(t) = grid
                        .tiles
                        .iter()
                        .find(|t| a == Action::from(format!("menu:{}", t.id).as_str()))
                    {
                        let mcx = tile_menu::rail_cx(false, self.favourites.contains(&t.id));
                        let entries = tile_menu::entries(Form::Desktop, &mcx, Some(t));
                        if !entries.is_empty() {
                            self.open = Open::Menu(t.id.clone());
                            let rows = crate::desk::tile_rows(&entries, t, &mcx, "pick.m.");
                            self.pop.open(
                                rows,
                                swiftly_ui::popover::Anchor::Pointer(swiftly_layout::Point::new(
                                    x, y,
                                )),
                                0.0,
                            );
                        }
                    }
                }
                UiEvent::LongPress(a) | UiEvent::Secondary { action: a, .. } => {
                    let grid = self.vm.grid();
                    if let Some(t) = grid
                        .tiles
                        .iter()
                        .find(|t| a == Action::from(format!("menu:{}", t.id).as_str()))
                    {
                        self.open = Open::Menu(t.id.clone());
                    }
                }
                UiEvent::Tap(a) => {
                    crate::forms::note_tap(&a);
                    self.tapped(&a);
                }
                _ => {}
            }
        }
    }

    /// Desktop: the pill or title opens an anchored popover whose rows report the sheet's `pick.*` actions.
    fn open_popover(&mut self, which: &str) {
        let Some(button) = self.ui.frame_of(which) else {
            return;
        };
        let rows: Vec<(String, String, bool)> = match which {
            "lib.filter" => {
                let cur = self.vm.status().filter;
                FILTERS
                    .iter()
                    .enumerate()
                    .map(|(i, (f, l))| (format!("pick.f.{i}"), (*l).to_owned(), *f == cur))
                    .collect()
            }
            "lib.kind" => {
                let cur = self.remember;
                KINDS
                    .iter()
                    .enumerate()
                    .map(|(i, (k, l))| (format!("pick.k.{i}"), (*l).to_owned(), *k == cur))
                    .collect()
            }
            "lib.sort" => {
                let cur = self.vm.status().sorting;
                SORTINGS
                    .iter()
                    .enumerate()
                    .map(|(i, (s, l))| (format!("pick.s.{i}"), (*l).to_owned(), *s == cur))
                    .collect()
            }
            _ => match self.vm.list() {
                Some(l) => l
                    .entries
                    .iter()
                    .enumerate()
                    .map(|(i, e)| (format!("pick.l.{i}"), e.label.clone(), e.selected))
                    .collect(),
                None => return,
            },
        };
        let width = if which == "lib.title" {
            260.0
        } else {
            swiftly_ui::feel::DROPDOWN_WIDTH
        };
        let below = [button[0], button[1] + 8.0, button[2], button[3]];
        self.pop.open_list(&rows, below, width);
    }

    fn tapped(&mut self, a: &Action) {
        let is = |s: &str| *a == Action::from(s);
        if self.pop.dismissed(a) {
            self.open = Open::None;
            return;
        }
        let desktop = Form::of(self.ui.env().idiom) == Form::Desktop;
        if desktop && (is("lib.filter") || is("lib.sort") || is("lib.kind") || is("lib.title")) {
            let (open, which) = if is("lib.filter") {
                (Open::Filter, "lib.filter")
            } else if is("lib.sort") {
                (Open::Sort, "lib.sort")
            } else if is("lib.kind") {
                (Open::Kind, "lib.kind")
            } else {
                (Open::Section, "lib.title")
            };
            self.open = open;
            self.open_popover(which);
            return;
        }
        if is("sheet.close") {
            self.open = Open::None;
        } else if is("lib.filter") {
            self.open = Open::Filter;
        } else if is("lib.sort") {
            self.open = Open::Sort;
        } else if is("lib.kind") {
            self.open = Open::Kind;
        } else if is("lib.title") {
            self.open = Open::Section;
        } else if is("retry") || is("more") {
            self.refreshes += 1;
            let narrowed = self.vm.status().filter != LibraryFilter::All;
            if narrowed && is("retry") && !self.vm.grid().tiles.is_empty() {
                self.vm.send(LibraryIntent::SetFilter {
                    filter: LibraryFilter::All,
                });
            } else {
                self.vm.send(if is("more") {
                    LibraryIntent::LoadMore
                } else {
                    LibraryIntent::Load
                });
            }
        }
        if self.open == Open::Section
            && let Some(list) = self.vm.list()
        {
            for (i, e) in list.entries.iter().enumerate() {
                if is(&format!("pick.l.{i}")) {
                    self.open = Open::None;
                    self.vm.select(&e.key);
                }
            }
        }
        for (i, (f, _)) in FILTERS.iter().enumerate() {
            if is(&format!("pick.f.{i}")) {
                self.vm.send(LibraryIntent::SetFilter { filter: *f });
                self.open = Open::None;
            }
        }
        for (i, (k, _)) in KINDS.iter().enumerate() {
            if is(&format!("pick.k.{i}")) {
                self.remember = *k;
                self.vm.set_remember_kind(*k);
                self.open = Open::None;
            }
        }
        for (i, (s, _)) in SORTINGS.iter().enumerate() {
            if is(&format!("pick.s.{i}")) {
                self.vm.send(LibraryIntent::SetSorting { sorting: *s });
                self.open = Open::None;
            }
        }
        if let Open::Menu(id) = self.open.clone() {
            let tile = self.vm.grid().tiles.iter().find(|t| t.id == id).cloned();
            let mcx = tile_menu::rail_cx(false, self.favourites.contains(&id));
            self.vm.set_menu_context(mcx.host.clone());
            for (i, e) in tile_menu::entries(Form::of(self.ui.env().idiom), &mcx, tile.as_ref())
                .into_iter()
                .enumerate()
            {
                if !is(&format!("pick.m.{i}")) {
                    continue;
                }
                self.open = Open::None;
                match e {
                    Entry::Play
                    | Entry::FromStart
                    | Entry::Info
                    | Entry::Overview
                    | Entry::ToSeries => self.opened.push(id.clone()),
                    Entry::Watched => {
                        self.vm.send(LibraryIntent::SetWatched {
                            id: id.clone(),
                            on: true,
                        });
                        crate::desk::note_list_change();
                    }
                    Entry::Unwatched => {
                        self.vm.send(LibraryIntent::SetWatched {
                            id: id.clone(),
                            on: false,
                        });
                        crate::desk::note_list_change();
                    }
                    Entry::Remember => {
                        let on = !self.favourites.contains(&id);
                        if on {
                            self.favourites.push(id.clone());
                        } else {
                            self.favourites.retain(|f| f != &id);
                        }
                        self.vm
                            .send(LibraryIntent::SetWatchlist { id: id.clone(), on });
                        crate::desk::note_list_change();
                    }
                    Entry::Load => {
                        self.load = LoadSpec::demo(tile.as_ref().map_or("", |t| t.title.as_str()));
                        self.open = Open::Load(id.clone());
                    }
                    Entry::PlayOn => self.open = Open::Devices(id.clone()),
                    Entry::Together => self.vm.request(TileRequest::Together { id: id.clone() }),
                    Entry::Remove => {}
                }
            }
        }
        if self.open == Open::None {
            self.pop.close();
        }
        if let Open::Devices(id) = self.open.clone() {
            for (i, (device, _)) in self.vm.menu_context().play_on.into_iter().enumerate() {
                if is(&format!("pick.d.{i}")) {
                    self.vm.request(TileRequest::PlayOn {
                        id: id.clone(),
                        device,
                    });
                    self.open = Open::None;
                }
            }
        }
        if let Open::Load(id) = self.open.clone() {
            if is("load.go") || is("load.queue") || is("load.cell") || is("load.clean") {
                self.vm.request(TileRequest::Load { id });
                self.open = Open::None;
            } else if is("load.close") {
                self.open = Open::None;
            }
        }
        for i in 0..TABS.len() {
            if is(&format!("tab:{i}")) {
                self.tab = i;
            }
        }
        for t in self.vm.grid().tiles.iter().chain(self.vm.cards().iter()) {
            if is(&format!("tile:{}", t.id)) {
                self.opened.push(t.id.clone());
            }
        }
    }

    /// One gesture for tap and slide (`DragGesture(minimumDistance: 0)`): the entry under the finger jumps once per new
    /// entry. True when the point is on the strip (or the finger is already sliding along it).
    fn rail_touch(&mut self, x: f32, y: f32) -> bool {
        let env = *self.ui.env();
        let m = browse::metrics(&env);
        let (Some((rx, _, _)), Some(r)) = (rail_box(&env, &m), self.rail_part()) else {
            return false;
        };
        let inside = x >= rx
            && x <= rx + RAIL_WIDTH
            && y >= r.top
            && y <= r.top + r.height
            && self.open == Open::None;
        if !inside && self.touched.is_none() {
            return false;
        }
        let local = f64::from((y - r.top).clamp(0.0, r.height));
        if let Some(e) = AlphabetIndex::entry_at(local, f64::from(r.height), &r.shown) {
            let letter = e.letter.clone();
            if self.touched.as_ref() != Some(&letter) {
                self.touched = Some(letter.clone());
                self.jump_to(&letter);
            }
        }
        true
    }

    /// A new window size or scale.
    pub fn set_env(&mut self, env: Env) {
        self.ui.set_env(env);
    }
    /// The tooltip to draw at `now` (tests).
    pub fn visible_tooltip(&self, now: f64) -> Option<(String, swiftly_layout::Rect)> {
        self.ui.visible_tooltip(now)
    }

    /// The text of the tooltip the last click hid.
    pub fn dismissed_tooltip(&self) -> Option<String> {
        self.ui.dismissed_tooltip()
    }

    /// Keeps a tooltip hidden that a click on the screen before hid.
    pub fn inherit_dismissed_tooltip(&mut self, text: Option<String>) {
        self.ui.inherit_dismissed_tooltip(text);
    }

    /// The pointer moved over the window (no button held): hover, cursor, tooltips.
    pub fn pointer_move(&mut self, x: f32, y: f32, now: f64) {
        self.ui.pointer_move(x, y, now);
        self.drain();
    }

    /// The pointer left the window.
    pub fn pointer_leave(&mut self, now: f64) {
        self.ui.pointer_leave(now);
        self.drain();
    }

    /// A wheel notch of `(dx, dy)` points at `(x, y)`.
    pub fn wheel_scroll(&mut self, x: f32, y: f32, dx: f32, dy: f32, now: f64) -> bool {
        self.ui.wheel_scroll(x, y, dx, dy, now)
    }

    /// Home, End, Page up and down.
    pub fn scroll_key(&mut self, key: swiftly_ui::shortcuts::ScrollKey, now: f64) -> bool {
        self.ui.scroll_key(key, now)
    }

    /// The cursor under the pointer.
    pub fn cursor(&self) -> swiftly_ui::Cursor {
        self.ui.cursor()
    }

    /// A right click on a tile: the tile menu (the same rows as the long press sheet).
    pub fn secondary_click(&mut self, x: f32, y: f32, now: f64) -> bool {
        let hit = self.ui.secondary_click(x, y, now);
        self.drain();
        hit
    }

    /// Arrow, Tab, Enter or Esc on the focus engine; Esc closes a sheet.
    pub fn nav_key(
        &mut self,
        key: swiftly_ui::NavKey,
        down: bool,
        now: f64,
    ) -> swiftly_ui::Outcome {
        if self.pop.is_open() {
            match self.pop.key(key, down, now) {
                crate::desk::PopKey::Pick(a) => self.tapped(&a),
                crate::desk::PopKey::Closed => self.open = Open::None,
                crate::desk::PopKey::None => {}
            }
            return swiftly_ui::Outcome::None;
        }
        let out = self.ui.nav_key(key, down, now);
        self.drain();
        out
    }
    /// A finger goes down.
    pub fn touch_down(&mut self, x: f32, y: f32, now: f64) {
        self.now = now;
        if self.rail_touch(x, y) {
            return;
        }
        self.ui.touch_down(x, y, now);
        self.drain();
    }
    /// The finger moves.
    pub fn touch_move(&mut self, x: f32, y: f32, now: f64) {
        self.now = now;
        if self.touched.is_some() {
            self.rail_touch(x, y);
            return;
        }
        self.ui.touch_move(x, y, now);
        self.drain();
    }
    /// The finger lifts.
    pub fn touch_up(&mut self, x: f32, y: f32, now: f64) {
        self.now = now;
        if let Some(k) = self.touched.take() {
            self.held = Some((k, now));
            return;
        }
        self.ui.touch_up(x, y, now);
        self.drain();
    }
    /// The touch is cancelled.
    pub fn touch_cancel(&mut self, now: f64) {
        if let Some(k) = self.touched.take() {
            self.held = Some((k, now));
        }
        self.ui.touch_cancel(now);
        self.drain();
    }
    /// Asks again when the server did not answer, and stops waiting for slow libraries (see [`Recovery`]).
    fn recover(&mut self, now: f64) {
        let offline = matches!(self.vm.status().status, LibraryStatus::Offline)
            && self.vm.grid().tiles.is_empty();
        if self.recovery.retry_due(offline, now) {
            self.auto_retries += 1;
            self.vm.send(LibraryIntent::Load);
        }
        if self.recovery.offering_overdue(self.offering.is_some(), now) {
            self.vm.send(LibraryIntent::Load);
        }
    }

    /// Takes the libraries of the section when they have arrived and starts the grid on them. The section behind the one
    /// in front calls this too, so its grid is loaded when it is opened (it showed skeleton tiles first).
    fn poll_offering(&mut self) {
        match self.offering.as_ref().map(|p| p.0.try_recv()) {
            Some(Ok((o, collections, playlists))) => {
                self.offering = None;
                let empty = !o.has_inventory();
                self.vm.follow_offering(o);
                self.vm.set_cards(collections, playlists);
                // Nothing of this kind on the account: the grid has no source to follow, it reads the section itself.
                if empty {
                    self.vm.send(LibraryIntent::Load);
                }
            }
            // The libraries could not be read: show the section as it is.
            Some(Err(std::sync::mpsc::TryRecvError::Disconnected)) => {
                self.offering = None;
                self.vm.send(LibraryIntent::Load);
            }
            _ => {}
        }
    }

    /// Whether the libraries of the section are still on their way.
    pub fn awaiting_libraries(&self) -> bool {
        self.offering.is_some()
    }

    /// A frame of the section while another one is in front: it reads what has arrived, it draws nothing.
    pub fn pump(&mut self, now: f64) {
        self.now = now;
        self.poll_offering();
    }

    /// One frame at `now` ms.
    pub fn frame(&mut self, now: f64) -> (DrawList, bool) {
        self.now = now;
        self.hub.frame(now);
        self.recover(now);
        if let Some(rx) = &self.mosaic_rx {
            let mut all = (*self.mosaics).clone();
            let before = all.len();
            let mut changed = false;
            while let Ok((id, images)) = rx.try_recv() {
                changed |= all.get(&id) != Some(&images);
                all.insert(id, images);
            }
            if changed || all.len() != before {
                self.mosaics = Arc::new(all);
            }
        }
        self.poll_offering();
        self.sync();
        let mut list = self.ui.frame(now);
        self.hub.finish(&mut list);
        self.drain();
        let wants = self.wants_frame();
        (list, wants)
    }
    /// The owner the picture hub knows this screen by (see `ImageHub::set_hidden`).
    pub(crate) fn hub_owner(&self) -> crate::hub::HubOwner {
        Rc::downgrade(&self.hub)
    }

    /// Shows the real pictures of the server through `hub` (without it the demo art stays).
    #[must_use]
    pub fn with_images(self, hub: Rc<crate::hub::ImageHub>) -> Self {
        self.hub.attach(hub);
        self
    }

    /// Waits for every picture and applies it (headless goldens).
    pub fn settle_images(&mut self, now: f64) {
        self.hub.settle(now);
    }

    /// Another frame is wanted.
    pub fn wants_frame(&self) -> bool {
        self.hub.busy() || self.ui.needs_frame()
    }
    /// The services the renderers read.
    pub fn cx(&self) -> &Cx {
        self.ui.cx()
    }
    /// Renders a list with the software renderer.
    pub fn render_software(&self, list: &DrawList) -> RgbaImage {
        self.ui.render(list, Color::BLACK)
    }
    /// Focused key on tv.
    pub fn focused(&self) -> Option<swiftly_ui::FocusId> {
        self.ui.focused()
    }
    /// Sidebar width on desktop, for hit tests.
    pub fn sidebar() -> f32 {
        desktop::SIDEBAR_WIDTH
    }
    /// Unused colour helper kept for symmetry with the other screens.
    #[doc(hidden)]
    pub fn ground() -> Color {
        color(colour::REASON)
    }
}

impl Drop for LibraryScreen {
    /// `onDisappear { ScrollRemember.state[rememberKey] = offset }`.
    fn drop(&mut self) {
        self.leave();
    }
}

/// What the title menu of a section is made of: the offering and the cards of its collections and playlists.
type Offered = (
    swiftly_playback::section_offering::SectionOffering,
    Vec<Tile>,
    Vec<Tile>,
);

/// Asks the server for the libraries of the account that hold `series` or movies, and for its collections and video
/// playlists (`AppModel.offeringLoad`: mixed libraries count only where they hold titles of that kind; collections
/// need two titles of the kind, playlists one).
fn fetch_offering(
    w: &crate::live::Wiring,
    series: bool,
) -> (
    crate::login_screen::Pending<Offered>,
    std::sync::mpsc::Receiver<(String, Vec<swiftly_vm::ImageRef>)>,
) {
    use swiftly_library::CollectionDirectory;
    let (tx, rx) = crate::login_screen::Pending::channel();
    let (mosaic_tx, mosaic_rx) = std::sync::mpsc::channel();
    let art = if series { "tvshows" } else { "movies" };
    let client = w.core.client_for(&w.account).ok();
    let locale = w.core.host().locale;
    if let Ok(server) = w.core.server_for(&w.account) {
        w.core.spawn(async move {
            let Ok((views, shares)) = crate::live_server::views_and_shares(&server).await else {
                return;
            };
            let (mut directory, mut playlists) = (None, None);
            if let Some(c) = &client {
                let with_hidden = c.user_views(true).await.unwrap_or_else(|_| views.clone());
                directory = if CollectionDirectory::hidden(&views, &with_hidden) {
                    Some(CollectionDirectory::default())
                } else {
                    swiftly_library::client_ext::collection_directory(c, &with_hidden)
                        .await
                        .ok()
                };
                playlists = swiftly_library::client_ext::playlist_directory(c)
                    .await
                    .ok();
            }
            let offering = swiftly_playback::section_offering::SectionOffering::compose(
                art,
                &views,
                &shares,
                directory.as_ref(),
                playlists.as_ref(),
            );
            let (collections, lists) = client
                .as_ref()
                .map(|c| {
                    swiftly_vm::section_cards(
                        art,
                        directory.as_ref(),
                        playlists.as_ref(),
                        c,
                        locale.clone(),
                    )
                })
                .unwrap_or_default();
            let _ = tx.send((offering, collections, lists));
            // The collections without a picture of their own get the mosaic of their first posters (the Mac's
            // `AppModel.collectionPosters`: first four by year, ascending, in this section's kind).
            if let (Some(c), Some(d)) = (&client, directory.as_ref()) {
                let bare: Vec<_> = d
                    .collections(art)
                    .into_iter()
                    .filter(|col| {
                        !col.item
                            .image_tags
                            .as_ref()
                            .is_some_and(|t| t.contains_key("Primary"))
                    })
                    .collect();
                for col in &bare {
                    let _ = mosaic_tx.send((format!("collection:{}", col.id()), Vec::new()));
                }
                for col in &bare {
                    let source = ShelfSource::new(Some(col.id()), Some(art), true, &[]);
                    let query = swiftly_jellyfin::ItemsQuery {
                        parent_id: Some(col.id().to_owned()),
                        limit: 4,
                        sort_by: Sorting::Erscheinung.input_field().to_owned(),
                        sort_order: source.bearing(Sorting::Erscheinung).to_owned(),
                        recursive: source.recursive(),
                        include_item_types: source.types().into_iter().map(str::to_owned).collect(),
                        ..swiftly_jellyfin::ItemsQuery::default()
                    };
                    if let Ok(found) = c.items(&query).await {
                        let images = swiftly_vm::poster_tiles(&found.items, c, locale.clone())
                            .into_iter()
                            .filter_map(|t| t.image)
                            .collect();
                        let _ = mosaic_tx.send((format!("collection:{}", col.id()), images));
                    }
                }
            }
        });
    }
    (rx, mosaic_rx)
}

fn live_spec(kind: &Kind) -> LibrarySpec {
    let series = matches!(kind, Kind::Series);
    LibrarySpec {
        source: if series {
            ShelfSource::new(None, Some("tvshows"), false, &[])
        } else {
            ShelfSource::new(None, Some("movies"), false, &[])
        },
        genre: match kind {
            Kind::Genre(g) => Some(g.clone()),
            _ => None,
        },
        // Sort and filter are remembered per place like the Mac's `LibraryModel(rememberName:)`.
        remember_name: match kind {
            Kind::Movies => Some("movies".to_owned()),
            Kind::Series => Some("tvshows".to_owned()),
            Kind::Watchlist => Some("merkliste".to_owned()),
            _ => None,
        },
    }
}
