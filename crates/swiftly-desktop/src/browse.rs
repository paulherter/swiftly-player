//! What the Library and Search screens share: sizes per form factor, the grid tile, the bottom sheet (sort, filter and
//! tile menus), the search field, the page chrome around a body, and the scripted server behind `--demo library|search`
//! (a `MockTransport`, no network). Numbers come from the Swift `Theme`, `PosterTile`, `ValuePill`, `SelectionSheet`,
//! `SearchField` and `SheetModifier`; the per-screen differences are noted in the code and
//! `search-screen.md`.

use crate::art;
use crate::home::{self, Bar, Form, fill_frame, ins, rgba, text};
use futures_executor::ThreadPool;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;
use swiftly_design::tokens::{colour, desktop, touch, tv};
use swiftly_jellyfin::ServerKind;
use swiftly_l10n::Locale;
use swiftly_layout::{Align, Alignment, EdgeInsets, Size};
use swiftly_library::MemoryStore;
use swiftly_net::{ErrorKind, MockTransport};
use swiftly_render::Color;
use swiftly_ui::components::{color, focus_id};
use swiftly_ui::icons::Icons;
use swiftly_ui::{Action, Cx, Env, FocusLook, Idiom, ImageId, Node, Paint};
use swiftly_vm::{AccountRef, Badge, Clock, Host, Sleeper, Spawner, Tile};

/// The address the offline states name.
pub const SERVER: &str = "tv.example.test";

/// What the scripted server does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scenario {
    /// Answers with titles.
    Ready,
    /// Not asked yet (library only): the status stays `Loading`.
    Loading,
    /// Every request fails.
    Offline,
    /// The server answers with nothing.
    Empty,
    /// Worst-case data (`break-ui`): 10,000 titles, very long, Arabic, Japanese and emoji names, missing posters, huge
    /// numbers.
    Worst,
}

struct Pool(ThreadPool);
impl Spawner for Pool {
    fn spawn(&self, task: Pin<Box<dyn Future<Output = ()> + Send>>) {
        self.0.spawn_ok(task);
    }
}
struct FixedClock;
impl Clock for FixedClock {
    fn now(&self) -> f64 {
        1000.0
    }
}
/// Sleeps by blocking a pool thread (the pool has two; the debounce is 0.3 s).
pub struct ThreadSleeper;
impl Sleeper for ThreadSleeper {
    fn sleep(&self, seconds: f64) -> Pin<Box<dyn Future<Output = ()> + Send>> {
        Box::pin(async move { std::thread::sleep(Duration::from_secs_f64(seconds)) })
    }
}

/// A host over a small thread pool and an in-memory store.
///
/// # Panics
/// If the thread pool cannot be created.
pub fn host() -> Host {
    let pool = ThreadPool::builder().pool_size(2).create();
    Host {
        spawner: Arc::new(Pool(pool.unwrap_or_else(|e| panic!("thread pool: {e}")))),
        clock: Arc::new(FixedClock),
        store: Arc::new(MemoryStore::new()),
        locale: Locale::parse("de"),
        device_name: "Demo".into(),
        client_version: "0.0.0".into(),
        cache: None,
    }
}

/// The account the demos sign in with.
pub fn account() -> AccountRef {
    AccountRef {
        base_url: format!("https://{SERVER}"),
        user_id: "demo-user".into(),
        token: "DEMO".into(),
        server_kind: ServerKind::Jellyfin,
        device_id: "demo-device".into(),
        plex_machine_id: None,
        plex_account_token: None,
    }
}

const TITLES: [&str; 14] = [
    "Nordlicht",
    "Sommerregen",
    "Die Brücke",
    "Der Weg zurück",
    "Stilles Wasser",
    "Letzte Ausfahrt",
    "Papierschiffe",
    "Das andere Ufer",
    "Winterlicht",
    "Halbe Wahrheit",
    "Ein ruhiger Ort",
    "Fremde Küste",
    "Goldener Herbst",
    "Nachtzug",
];

/// A title a real library can hold, for the `Worst` scenario: the longest realistic names, right-to-left and CJK
/// scripts, emoji (also a joined family), one letter, a name with a colon and a year.
pub fn worst_title(i: usize) -> &'static str {
    const WORST: [&str; 9] = [
        "Die unglaubliche und wahre Geschichte des außergewöhnlichen Herrn Bartholomäus von und zu Hohenlohe-Schillingsfürst, Teil 3: Die Rückkehr des Königs der Nacht (Director's Cut)",
        "مسلسل الحياة الجميلة في القرية الصغيرة الجزء الثاني",
        "千と千尋の神隠し ~ スタジオジブリ作品 完全版",
        "👨‍👩‍👧‍👦 Familienbande 🎬🍿",
        "M",
        "Pirates of the Caribbean: Dead Men Tell No Tales — Extended Version (2017) [2160p HDR]",
        "Ñandú & Çiğdem: Ångström’s Œuvre",
        "Supercalifragilisticexpialidocious-Zwischenmahlzeitenverordnungsentwurf",
        "ภาพยนตร์เรื่องยาวเกี่ยวกับการเดินทางข้ามประเทศไทย",
    ];
    WORST[i % WORST.len()]
}

/// `json` with the demo titles swapped for `worst_title`s and every third poster dropped (`Worst` scenario).
pub fn worstify(json: &str) -> String {
    let mut out = json.to_owned();
    for (k, t) in TITLES.iter().enumerate() {
        out = out.replace(&format!("\"{t}\""), &format!("\"{}\"", worst_title(k)));
    }
    let key = "\"ImageTags\":{\"Primary\":\"";
    let mut res = String::with_capacity(out.len());
    let mut rest = out.as_str();
    let mut n = 0_usize;
    while let Some(at) = rest.find(key) {
        res.push_str(&rest[..at]);
        let tail = &rest[at + key.len()..];
        let end = tail.find("\"}").map_or(tail.len(), |e| e + 2);
        if n % 3 != 2 {
            res.push_str(key);
            res.push_str(&tail[..end]);
        } else {
            res.push_str("\"ImageTags\":{}");
        }
        n += 1;
        rest = &tail[end..];
    }
    res.push_str(rest);
    res
}

fn item(i: usize, series: bool) -> String {
    let name = TITLES[i % TITLES.len()];
    let user = match i % 6 {
        1 => r#""UserData":{"Played":true,"IsFavorite":true}"#.to_owned(),
        2 => r#""UserData":{"Played":true}"#.to_owned(),
        3 => format!(
            r#""UserData":{{"PlaybackPositionTicks":{},"PlayedPercentage":{}.0,"Played":false}}"#,
            (i as u64 + 2) * 3_000_000_000_u64,
            20 + (i * 13) % 60
        ),
        _ => r#""UserData":{"Played":false}"#.to_owned(),
    };
    let kind = if series { "Series" } else { "Movie" };
    format!(
        r#"{{"Id":"x{i}","Name":"{name}","Type":"{kind}","ProductionYear":{},"ChildCount":3,"RunTimeTicks":54000000000,"ImageTags":{{"Primary":"p-x{i}"}},{user}}}"#,
        2008 + i % 16
    )
}

/// `count` titles as a Jellyfin list answer.
pub fn list(count: usize, series: bool) -> String {
    let items: Vec<String> = (0..count).map(|i| item(i, series || i % 5 == 4)).collect();
    format!(
        r#"{{"Items":[{}],"TotalRecordCount":{count}}}"#,
        items.join(",")
    )
}

/// The scripted server: `count` titles for `/Items`, or the failure/empty answers.
pub fn transport(scenario: Scenario, count: usize, series: bool) -> MockTransport {
    let views = r#"{"Items":[{"Id":"lib-movies","Name":"Filme","Type":"CollectionFolder","CollectionType":"movies"},{"Id":"lib-shows","Name":"Serien","Type":"CollectionFolder","CollectionType":"tvshows"}],"TotalRecordCount":2}"#;
    match scenario {
        Scenario::Offline => ["UserViews", "/Items"]
            .iter()
            .fold(MockTransport::new(), |m, p| {
                m.route_error(p, ErrorKind::Network { code: -1009 })
            }),
        Scenario::Empty => MockTransport::new().route("UserViews", 200, views).route(
            "/Items",
            200,
            &list(0, series),
        ),
        Scenario::Worst => MockTransport::new().route("UserViews", 200, views).route(
            "/Items",
            200,
            &worstify(&list(10_000, series))
                .replace("\"ChildCount\":3", "\"ChildCount\":12345")
                .replace("\"ProductionYear\":20", "\"ProductionYear\":99"),
        ),
        _ => MockTransport::new().route("UserViews", 200, views).route(
            "/Items",
            200,
            &list(count, series),
        ),
    }
}

// ---- sizes ---------------------------------------------------------------------------------------------------------

/// Sizes of the grid pages per form factor (`Theme` of each Swift app).
#[derive(Clone, Copy)]
pub struct Metrics {
    /// The form factor.
    pub form: Form,
    /// Page edge.
    pub edge: f32,
    /// Smallest gap between two tiles.
    pub gap: f32,
    /// Gap between two rows (`Theme.gridRowGap`).
    pub row_gap: f32,
    /// Tile width: the target for flexible tiles (touch), the fixed width otherwise.
    pub tile_w: f32,
    /// Tile height of the fixed layouts.
    pub tile_h: f32,
    /// Tile corner.
    pub corner: f32,
    /// Title style under a tile.
    pub title: swiftly_design::TextStyle,
    /// Second line style.
    pub small: swiftly_design::TextStyle,
    /// Width taken away by the sidebar.
    pub side: f32,
    /// Distance of the content from the top of the page.
    pub top: f32,
}

/// The metrics of `env`.
pub fn metrics(env: &Env) -> Metrics {
    let form = Form::of(env.idiom);
    let pad = env.idiom == Idiom::Pad;
    match form {
        Form::Touch => Metrics {
            form,
            edge: if pad {
                touch::EDGE_PAGE_WIDE
            } else {
                touch::EDGE_SPACING
            },
            gap: touch::TILE_SPACING,
            row_gap: 32.0,
            tile_w: if pad { 124.0 } else { 104.0 },
            tile_h: 0.0,
            corner: touch::CORNER_TILE,
            title: touch::text::TILE,
            small: touch::text::SMALL,
            side: 0.0,
            top: env.safe.top + 58.0 + 8.0,
        },
        Form::Desktop => Metrics {
            form,
            edge: desktop::EDGE_SPACING,
            gap: 16.0,
            row_gap: 24.0,
            tile_w: desktop::TILE_WIDTH,
            tile_h: desktop::TILE_HEIGHT,
            corner: desktop::CORNER_TILE,
            title: desktop::text::TILE,
            small: desktop::text::SMALL,
            side: desktop::SIDEBAR_WIDTH,
            top: desktop::CONTENT_TOP,
        },
        Form::Tv => Metrics {
            form,
            edge: 80.0,
            gap: tv::TILE_SPACING,
            row_gap: 58.0,
            tile_w: tv::POSTER_WIDTH,
            tile_h: tv::POSTER_HEIGHT,
            corner: 18.0,
            title: tv::text::TILE,
            small: tv::text::SMALL,
            side: 0.0,
            top: tv::CONTENT_TOP,
        },
    }
}

/// The grid geometry for the width the page has: columns, tile size, gap.
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Grid {
    /// Columns.
    pub columns: usize,
    /// Tile width.
    pub w: f32,
    /// Tile image height.
    pub h: f32,
    /// Gap between two tiles in a row.
    pub gap: f32,
}

/// `Theme.columns` (flexible tiles on touch) and the Mac/tv rule (fixed tiles spread to both edges).
pub fn grid(m: &Metrics, page_w: f32) -> Grid {
    let usable = (page_w - m.side - 2.0 * m.edge).max(m.tile_w);
    if m.form == Form::Touch {
        let n = (((usable + m.gap) / (m.tile_w + m.gap)).floor() as usize).max(2);
        let w = (usable - (n - 1) as f32 * m.gap) / n as f32;
        Grid {
            columns: n,
            w,
            h: (w * 1.5).round(),
            gap: m.gap,
        }
    } else {
        let n = (((usable + m.gap) / (m.tile_w + m.gap)).floor() as usize).max(1);
        let gap = if m.form == Form::Tv {
            m.gap
        } else if n > 1 {
            m.gap.max((usable - n as f32 * m.tile_w) / (n - 1) as f32)
        } else {
            0.0
        };
        Grid {
            columns: n,
            w: m.tile_w,
            h: m.tile_h,
            gap,
        }
    }
}

/// Height of the two text lines under a tile.
pub fn text_height(cx: &Cx, m: &Metrics) -> f32 {
    let line = |st: swiftly_design::TextStyle| {
        cx.measure_text(
            "Ag",
            &swiftly_text::TextStyle::from(st),
            Some(1),
            swiftly_layout::Proposal::NIL,
        )
        .h
    };
    line(m.title) + 2.0 + line(m.small)
}

/// The pictures standing in for server images.
pub struct Art {
    posters: Vec<ImageId>,
    /// The image hub, attached by the screen's `with_images`; without one every picture is demo art.
    pub hub: crate::hub::HubSlot,
}

impl Art {
    /// Adds the poster set to `cx`.
    pub fn new(cx: &Cx) -> Art {
        Art {
            posters: art::posters(cx),
            hub: std::rc::Rc::new(std::cell::RefCell::new(None)),
        }
    }
    fn pick(&self, id: &str) -> Option<ImageId> {
        let h = id.bytes().fold(7_usize, |a, b| {
            a.wrapping_mul(31).wrapping_add(usize::from(b))
        });
        self.posters.get(h % self.posters.len().max(1)).copied()
    }
}

/// The Mac `TileBadge` in the top right corner of a poster: a checkmark (watched), "N offen" (a series that was started)
/// or "N Staffeln" (a series nobody started); 10/600 white on `reason` 78 %, radius 8, 6 pt from the edges.
pub(crate) fn tile_mark(cx: &Cx, icons: &Icons, tile: &Tile) -> Option<Node> {
    let mut parts = Vec::new();
    let label = if tile.badges.contains(&Badge::Watched) {
        parts.push(icons.node("check", 10.0, true, color(colour::FONT)));
        None
    } else {
        tile.badges.iter().find_map(|b| match b {
            Badge::Unplayed { count } => Some(format!("{count} offen")),
            Badge::Seasons { count: 1 } => Some("1 Staffel".to_owned()),
            Badge::Seasons { count } => Some(format!("{count} Staffeln")),
            _ => None,
        })
    };
    if let Some(l) = &label {
        parts.push(text(
            cx,
            l,
            style(10.0, 600),
            colour::FONT,
            Some(1),
            swiftly_text::Align::Start,
        ));
    }
    if parts.is_empty() {
        return None;
    }
    let side = if label.is_none() { 5.0 } else { 6.0 };
    Some(
        Node::hstack(Align::Center, Some(3.0), parts)
            .padding(EdgeInsets::symmetric(side, 3.0))
            .background(
                Node::rect(rgba(colour::REASON, 0.78), 8.0),
                Alignment::CENTER,
            )
            .padding(EdgeInsets::all(6.0)),
    )
}

/// One title of a grid: image with corner and edge, progress bar, watched mark, name and the quiet line. `key` is the
/// focus key on tv; a tap reports `tile:<id>`, a long press `menu:<id>`.
#[allow(clippy::too_many_arguments)]
/// Design name: PosterCell
pub fn grid_tile(
    cx: &Cx,
    icons: &Icons,
    m: &Metrics,
    art: &Art,
    tile: &Tile,
    g: &Grid,
    key: &str,
) -> Node {
    grid_tile_with(cx, icons, m, art, tile, g, key, None)
}

/// `CollectionMosaic` (`MacCollection.swift`): the placeholder poster of a collection without a picture of its own,
/// made of the posters of its first titles with 2 pt gaps. One title fills the field, two sit side by side, from three
/// on it is a 2 x 2 grid (the last row may hold one). No posters yet: one field with the film symbol.
fn mosaic_node(
    hub: &crate::hub::ImageHub,
    images: &[swiftly_vm::ImageRef],
    w: f32,
    h: f32,
    corner: f32,
) -> Node {
    const GAP: f32 = 2.0;
    let rows: Vec<&[swiftly_vm::ImageRef]> = match images.len() {
        0 => vec![&[]],
        1 | 2 => vec![images],
        _ => vec![&images[..2], &images[2..images.len().min(4)]],
    };
    let row_h = (h - (rows.len() as f32 - 1.0) * GAP) / rows.len() as f32;
    let cells = rows
        .iter()
        .map(|row| {
            let n = row.len().max(1) as f32;
            let cell_w = (w - (n - 1.0) * GAP) / n;
            let cells = if row.is_empty() {
                vec![hub.node(None, cell_w, row_h, 0.0)]
            } else {
                row.iter()
                    .map(|i| hub.node(Some(i), cell_w, row_h, 0.0))
                    .collect()
            };
            Node::hstack(Align::Start, Some(GAP), cells)
        })
        .collect();
    // The Mac clips the whole mosaic as one rounded card (`clipShape(RoundedRectangle)`), the cells themselves are square.
    Node::vstack(Align::Start, Some(GAP), cells)
        .frame(Some(w), Some(h), Alignment::TOP_LEADING)
        .clipped_rounded(corner)
}

/// [`grid_tile`] with the mosaic of a collection card without a picture (`Some`: the posters found so far).
#[allow(clippy::too_many_arguments)]
pub fn grid_tile_with(
    cx: &Cx,
    icons: &Icons,
    m: &Metrics,
    art: &Art,
    tile: &Tile,
    g: &Grid,
    key: &str,
    mosaic: Option<&[swiftly_vm::ImageRef]>,
) -> Node {
    let hub = art.hub.borrow().clone();
    let image = match (hub, tile.image.as_ref()) {
        (Some(hub), _) if mosaic.is_some() => {
            mosaic_node(&hub, mosaic.unwrap_or_default(), g.w, g.h, m.corner)
        }
        // No picture: the ground and the symbol of the kind (`Theme.area`, `tileCharacter`), never demo art.
        (Some(hub), _) => hub.node_with_symbol(
            tile.image.as_ref(),
            g.w,
            g.h,
            m.corner,
            crate::detail_screen::tile_character_icon(
                tile.facts.kind.as_deref(),
                tile.facts.series_id.as_deref(),
            ),
        ),
        (None, _) => match art.pick(&tile.id) {
            Some(id) => Node::image(id, g.w, g.h, m.corner),
            None => Node::rect(color(colour::AREA), m.corner).frame(
                Some(g.w),
                Some(g.h),
                Alignment::CENTER,
            ),
        },
    };
    let mut image = image.paint(Paint::Stroke {
        color: color(colour::TILE_BORDER),
        width: 1.0,
        radius: m.corner,
    });
    if let Some(mark) = tile_mark(cx, icons, tile) {
        image = image.overlay(mark, Alignment::TOP_TRAILING);
    }
    if let Some(share) = tile.progress.filter(|p| *p > 0.0) {
        let bar = if m.form == Form::Desktop {
            home::progress_bar(g.w, m.corner, share)
        } else {
            let share = share.clamp(0.0, 1.0);
            Node::zstack(
                Alignment::BOTTOM_LEADING,
                vec![
                    Node::rect(Color::new(1.0, 1.0, 1.0, 0.30), 0.0).frame(
                        Some(g.w),
                        Some(4.0),
                        Alignment::CENTER,
                    ),
                    Node::rect(color(colour::MARK_ACCENT), 0.0).frame(
                        Some(g.w * share),
                        Some(4.0),
                        Alignment::CENTER,
                    ),
                ],
            )
        };
        image = image.overlay(bar, Alignment::BOTTOM_LEADING);
    }
    if m.form == Form::Desktop {
        image = image.hover_scale(swiftly_ui::feel::HOVER_TILE_SCALE);
    }
    let tv = m.form == Form::Tv;
    let mut lines = vec![
        text(
            cx,
            &tile.title,
            m.title,
            colour::FONT,
            Some(1),
            swiftly_text::Align::Start,
        )
        .frame(
            Some(g.w),
            if tv { Some(34.0) } else { None },
            swiftly_ui::components::natural_edge(&tile.title),
        ),
    ];
    if let Some(sub) = tile.subtitle.as_ref().filter(|_| !tv) {
        lines.push(
            text(
                cx,
                sub,
                m.small,
                colour::FONT_VERY_QUIET,
                Some(1),
                swiftly_text::Align::Start,
            )
            .frame(Some(g.w), None, swiftly_ui::components::natural_edge(sub)),
        );
    }
    // The focus ring sits on the picture, not around title and year (the Mac's focus outline).
    let image = if m.form == Form::Desktop {
        image
            .on_tap(Action::from(format!("tile:{}", tile.id).as_str()))
            .focusable(focus_id(key), None)
            .focus_ring(color(colour::MARK_ACCENT), m.corner)
    } else {
        image
    };
    let mut n = Node::vstack(
        Align::Start,
        Some(if tv { 18.0 } else { 8.0 }),
        vec![image, Node::vstack(Align::Start, Some(2.0), lines)],
    )
    .key(key)
    .on_tap(Action::from(format!("tile:{}", tile.id).as_str()))
    .on_long_press(Action::from(format!("menu:{}", tile.id).as_str()));
    if m.form == Form::Tv {
        n = n.focusable(focus_id(key), Some(FocusLook::tile(m.corner)));
    }
    if m.form == Form::Desktop {
        n = n.on_secondary(Action::from(format!("menu:{}", tile.id).as_str()));
    }
    n
}

/// `TilePlaceholder`s in their final shape: `rows` rows of the grid.
pub fn grid_placeholder(m: &Metrics, g: &Grid, rows: usize) -> Node {
    let row = || {
        let tiles = (0..g.columns)
            .map(|_| home::load_field(g.w, g.h, m.corner))
            .collect();
        Node::hstack(Align::Start, Some(g.gap), tiles)
    };
    Node::vstack(
        Align::Start,
        Some(m.row_gap),
        (0..rows).map(|_| row()).collect(),
    )
}

fn style(size: f32, weight: u16) -> swiftly_design::TextStyle {
    swiftly_design::TextStyle {
        size,
        weight,
        tracking: 0.0,
        uppercase: false,
    }
}

/// `ValuePill`: a capsule on the area colour with an 11 pt symbol and a 13 pt label, 30 high. On tv (`tv`) the
/// `CapsuleStyle`: 22 pt symbol at 60 %, 26 semibold label, 24 side padding, 56 high, white 10 % (white when focused).
pub fn value_pill(
    cx: &Cx,
    icons: &Icons,
    asset: &str,
    label: &str,
    action: &str,
    tv: bool,
) -> Node {
    if tv {
        let n = Node::hstack(
            Align::Center,
            Some(12.0),
            vec![
                icons.node(asset, 22.0, true, rgba(colour::FONT, 0.6)),
                text(
                    cx,
                    label,
                    style(26.0, 600),
                    colour::FONT,
                    Some(1),
                    swiftly_text::Align::Start,
                ),
            ],
        )
        .padding(EdgeInsets::symmetric(24.0, 0.0))
        .frame(None, Some(56.0), Alignment::CENTER)
        .background(
            Node::rect(Color::new(1.0, 1.0, 1.0, 0.10), 999.0).paint(Paint::FocusFill {
                color: Color::WHITE,
                radius: 999.0,
            }),
            Alignment::CENTER,
        )
        .key(action)
        .on_tap(Action::from(action));
        return n.focusable(focus_id(action), Some(FocusLook::tile(999.0)));
    }
    Node::hstack(
        Align::Center,
        Some(6.0),
        vec![
            icons.node(asset, 11.0, true, color(colour::FONT)),
            text(
                cx,
                label,
                style(13.0, 500),
                colour::FONT,
                Some(1),
                swiftly_text::Align::Start,
            ),
        ],
    )
    .padding(EdgeInsets::symmetric(12.0, 0.0))
    .frame(None, Some(30.0), Alignment::CENTER)
    .background(Node::rect(color(colour::AREA), 15.0), Alignment::CENTER)
    .key(action)
    .on_tap(Action::from(action))
}

/// The Mac's popup pill (`Chip(caret: true)` under `SelectionButton`): an optional 14 pt symbol, the 13 pt semibold
/// value and an 11 pt caret, 7 apart, 12 on the sides, 30 high, all in the quiet text colour on the area colour.
pub fn popup_chip(cx: &Cx, icons: &Icons, asset: Option<&str>, label: &str, action: &str) -> Node {
    let mut kids = Vec::new();
    if let Some(asset) = asset {
        kids.push(icons.node(asset, 14.0, true, color(colour::FONT_QUIET)));
    }
    kids.push(text(
        cx,
        label,
        style(13.0, 600),
        colour::FONT_QUIET,
        Some(1),
        swiftly_text::Align::Start,
    ));
    kids.push(icons.node("caret-down", 11.0, true, color(colour::FONT_QUIET)));
    Node::hstack(Align::Center, Some(7.0), kids)
        .padding(EdgeInsets::symmetric(12.0, 0.0))
        .frame(None, Some(30.0), Alignment::CENTER)
        .background(Node::rect(color(colour::AREA), 15.0), Alignment::CENTER)
        .key(action)
        .on_tap(Action::from(action))
}

/// `CountMark`: the total, 13 pt medium, very quiet (tv: `Theme.small`, 24).
pub fn count_mark(cx: &Cx, count: i64, tv: bool) -> Node {
    let st = if tv {
        style(24.0, 400)
    } else {
        style(13.0, 500)
    };
    text(
        cx,
        &count.to_string(),
        st,
        colour::FONT_VERY_QUIET,
        Some(1),
        swiftly_text::Align::End,
    )
}

/// Fills the width only (`fill_frame` also takes all the height).
pub fn wide(n: Node, align: Alignment) -> Node {
    n.flex_frame(swiftly_layout::FlexFrame {
        max_w: Some(f32::INFINITY),
        align: Some(align),
        ..swiftly_layout::FlexFrame::default()
    })
}

/// One row of a sheet.
pub struct SheetRow {
    /// The label.
    pub label: String,
    /// Marked with the check (the value in use).
    pub selected: bool,
}

/// `SheetModifier` + `SelectionSheet`: a dimmed page (black 55 %), a card from the bottom (corner 28, area colour,
/// hairline, a 36 x 5 handle), the title 17/600 and 60 pt rows (check 18, label 17, white and semibold when selected).
/// Rows report `<prefix><index>`; a tap on the scrim reports `sheet.close`. On desktop and tv the card is 600 wide and
/// centred.
/// Design name: SelectionSheet
pub fn sheet(
    cx: &Cx,
    icons: &Icons,
    m: &Metrics,
    title: &str,
    rows: &[SheetRow],
    prefix: &str,
    checks: bool,
) -> Node {
    sheet_with(cx, icons, m, title, rows, prefix, checks, &[])
}

/// [`sheet`] with section headers: `(row index, text)` puts a quiet caption in front of that row (the title menu's
/// "Bibliotheken").
#[allow(clippy::too_many_arguments)]
pub fn sheet_with(
    cx: &Cx,
    icons: &Icons,
    m: &Metrics,
    title: &str,
    rows: &[SheetRow],
    prefix: &str,
    checks: bool,
    headers: &[(usize, String)],
) -> Node {
    let mut list: Vec<Node> = rows
        .iter()
        .enumerate()
        .map(|(i, r)| {
            let c = if r.selected {
                colour::FONT
            } else {
                colour::FONT_QUIET
            };
            let key = format!("{prefix}{i}");
            let mut n = Node::hstack(
                Align::Center,
                Some(14.0),
                vec![
                    if checks {
                        icons
                            .node(
                                "check",
                                17.0,
                                true,
                                if r.selected {
                                    color(colour::FONT)
                                } else {
                                    rgba(colour::FONT, 0.0)
                                },
                            )
                            .frame(Some(18.0), None, Alignment::CENTER)
                    } else {
                        Node::fixed(0.0, 0.0)
                    },
                    text(
                        cx,
                        &r.label,
                        style(17.0, if r.selected { 600 } else { 400 }),
                        c,
                        Some(1),
                        swiftly_text::Align::Start,
                    ),
                    Node::spacer(),
                ],
            )
            .padding(EdgeInsets::symmetric(touch::EDGE_SPACING, 0.0))
            .frame(None, Some(60.0), Alignment::LEADING);
            n = wide(n, Alignment::LEADING)
                .key(key.as_str())
                .on_tap(Action::from(key.as_str()));
            if m.form == Form::Tv {
                n = n.focusable(focus_id(key.as_str()), Some(FocusLook::tile(12.0)));
            }
            n
        })
        .collect();
    for (at, caption) in headers.iter().rev() {
        let h = text(
            cx,
            caption,
            style(13.0, 600),
            colour::FONT_VERY_QUIET,
            Some(1),
            swiftly_text::Align::Start,
        )
        .padding(ins(10.0, touch::EDGE_SPACING, 4.0, touch::EDGE_SPACING));
        list.insert((*at).min(list.len()), wide(h, Alignment::LEADING));
    }
    let handle = Node::rect(Color::new(1.0, 1.0, 1.0, 0.18), 2.5)
        .frame(Some(36.0), Some(5.0), Alignment::CENTER)
        .padding(ins(8.0, 0.0, 0.0, 0.0));
    let head = text(
        cx,
        title,
        style(17.0, 600),
        colour::FONT,
        Some(1),
        swiftly_text::Align::Start,
    )
    .padding(ins(4.0, touch::EDGE_SPACING, 14.0, touch::EDGE_SPACING))
    .frame(None, None, Alignment::LEADING);
    let card_w = (m.form != Form::Touch).then_some(600.0);
    let card = Node::vstack(
        Align::Start,
        Some(0.0),
        vec![
            wide(handle, Alignment::TOP),
            wide(head, Alignment::LEADING),
            Node::vstack(Align::Start, Some(0.0), list),
        ],
    )
    .padding(ins(0.0, 0.0, 24.0, 0.0));
    let card = wide(card, Alignment::TOP_LEADING)
        .frame(card_w, None, Alignment::TOP_LEADING)
        .background(
            Node::rect(color(colour::AREA), 28.0).paint(Paint::Stroke {
                color: color(colour::LINE),
                width: 1.0,
                radius: 28.0,
            }),
            Alignment::CENTER,
        )
        .on_tap_silent(Action::from("sheet.nop"));
    let col = Node::vstack(Align::Center, Some(0.0), vec![Node::spacer(), card]);
    fill_frame(col, Alignment::BOTTOM)
        .background(
            Node::rect(Color::new(0.0, 0.0, 0.0, 0.55), 0.0),
            Alignment::CENTER,
        )
        .on_tap(Action::from("sheet.close"))
}

/// `SearchField`: a 56 high rounded field (corner 10, area colour) with a 17 pt magnifier, the text in 15 pt (the
/// placeholder very quiet), a caret while focused and the clear button (`xmark.circle.fill`, 44 x 44 target).
pub fn search_field(cx: &Cx, icons: &Icons, v: &swiftly_ui::field::FieldView, tv: bool) -> Node {
    // tv: `SearchLayout.fieldHeight` 72, 30 pt text (`Theme.body`) and symbol.
    let (icon, high) = if tv { (30.0, 72.0) } else { (17.0, 56.0) };
    let look = search_look(tv);
    let filled = !v.display.text.is_empty();
    let mut row = vec![icons.node("magnifying-glass", icon, true, color(colour::FONT))];
    row.push(swiftly_ui::field::field_content(cx, v, &look).key("field.text"));
    row.push(Node::spacer());
    if filled {
        row.push(
            icons
                .node("x-circle.fill", 17.0, false, color(colour::FONT_VERY_QUIET))
                .frame(Some(44.0), Some(44.0), Alignment::CENTER)
                .padding(ins(0.0, 0.0, 0.0, -13.0))
                .key("field.clear")
                .on_tap(Action::from("field.clear")),
        );
    }
    Node::hstack(Align::Center, Some(10.0), row)
        .padding(EdgeInsets::symmetric(14.0, 0.0))
        .frame(None, Some(high), Alignment::LEADING)
        .background(Node::rect(color(colour::AREA), 10.0), Alignment::CENTER)
        .key("field")
        .on_tap(Action::from("field.focus"))
}

/// The Mac `SearchView` field (`SearchView.swift:157`): max 520 wide, 40 high, corner 12 on `area`, glass 16 very quiet,
/// text 15; focused: a 1 pt accent border and a 6 pt ring at 35 %, easeOut 0.12.
pub fn search_field_desktop(cx: &Cx, icons: &Icons, v: &swiftly_ui::field::FieldView) -> Node {
    let look = search_look(false);
    let filled = !v.display.text.is_empty();
    let mut row = vec![icons.node(
        "magnifying-glass",
        16.0,
        true,
        color(colour::FONT_VERY_QUIET),
    )];
    row.push(swiftly_ui::field::field_content(cx, v, &look));
    row.push(Node::spacer());
    if filled {
        row.push(
            icons
                .node("x-circle.fill", 16.0, false, color(colour::FONT_VERY_QUIET))
                .frame(Some(28.0), Some(28.0), Alignment::CENTER)
                .cursor(swiftly_ui::Cursor::Arrow)
                .key("field.clear")
                .on_tap(Action::from("field.clear")),
        );
    }
    let on = if v.focused { 1.0 } else { 0.0 };
    let border = Node::rect(Color::new(0.0, 0.0, 0.0, 0.0), 12.0)
        .paint(Paint::Stroke {
            color: color(colour::MARK_ACCENT),
            width: 1.0,
            radius: 12.0,
        })
        .opacity(on, swiftly_ui::feel::hover());
    let ring = Node::rect(Color::new(0.0, 0.0, 0.0, 0.0), 15.0)
        .paint(Paint::Stroke {
            color: color(colour::MARK_ACCENT).with_alpha(0.35),
            width: 6.0,
            radius: 15.0,
        })
        .padding(EdgeInsets {
            top: -3.0,
            leading: -3.0,
            bottom: -3.0,
            trailing: -3.0,
        })
        .opacity(on, swiftly_ui::feel::hover());
    Node::hstack(Align::Center, Some(8.0), row)
        .padding(EdgeInsets::symmetric(12.0, 0.0))
        .frame(None, Some(40.0), Alignment::LEADING)
        .background(Node::rect(color(colour::AREA), 12.0), Alignment::CENTER)
        .overlay(border, Alignment::CENTER)
        .overlay(ring, Alignment::CENTER)
        .cursor(swiftly_ui::Cursor::Text)
        .key("field")
        .on_tap(Action::from("field.focus"))
}

/// Type and colours of the search field's text (also what the candidate window's anchor is measured with).
pub fn search_look(tv: bool) -> swiftly_ui::field::FieldLook {
    swiftly_ui::field::FieldLook {
        style: swiftly_text::TextStyle::from(style(if tv { 30.0 } else { 15.0 }, 400)),
        text: color(colour::FONT),
        placeholder: color(colour::FONT_VERY_QUIET),
        caret: color(colour::MARK_ACCENT),
        selection: color(colour::MARK_ACCENT).with_alpha(0.30),
        caret_height: Some(if tv { 36.0 } else { 20.0 }),
    }
}

/// The chrome around a body: the touch header (`title`) and tab bar, the desktop sidebar and top strip, the tv top bar.
#[allow(clippy::too_many_arguments)]
pub fn page(
    cx: &Cx,
    env: &Env,
    icons: &Icons,
    hub: &crate::hub::HubSlot,
    bar: Bar,
    title: &str,
    body: Node,
    overlay: Option<Node>,
) -> Node {
    let m = metrics(env);
    let page = match m.form {
        Form::Touch => fill_frame(body, Alignment::TOP_LEADING)
            .overlay(home::header(cx, env, &bar, title), Alignment::TOP)
            .overlay(home::tab_bar(cx, env, &bar, icons), Alignment::BOTTOM),
        Form::Desktop => {
            let strip = home::state_bar(cx, title, bar.header);
            let side = crate::look_glow::behind(
                fill_frame(body, Alignment::TOP_LEADING).overlay(strip, Alignment::TOP),
                bar.glow,
                env.size.w - desktop::SIDEBAR_WIDTH,
            );
            Node::hstack(
                Align::Start,
                Some(0.0),
                vec![home::sidebar(cx, &bar, icons, hub), side],
            )
        }
        Form::Tv => fill_frame(body, Alignment::TOP_LEADING)
            .overlay(home::header_bar(cx, &bar, "P"), Alignment::TOP),
    };
    let page = fill_frame(page, Alignment::TOP_LEADING)
        .background(Node::rect(color(colour::REASON), 0.0), Alignment::CENTER);
    match overlay {
        Some(o) => page.overlay(o, Alignment::BOTTOM),
        None => page,
    }
}

/// The page title on desktop and tv (the touch header carries its own): `Theme.titleLarge`.
/// Design name: PageTitle
pub fn heading(cx: &Cx, m: &Metrics, title: &str) -> Node {
    text(
        cx,
        title,
        desktop::text::TITLE_LARGE,
        colour::FONT,
        Some(1),
        swiftly_text::Align::Start,
    )
    .padding(ins(0.0, m.edge, 0.0, m.edge))
}

/// Size of the body width the grid may use.
pub fn body_width(env: &Env, m: &Metrics) -> Size {
    Size::new(env.size.w - m.side, env.size.h)
}

#[cfg(test)]
mod mosaic_tests {
    use super::*;
    use swiftly_images::fixture::FixtureImages;
    use swiftly_images::{Device, ImageLoader};

    #[test]
    fn the_mosaic_is_one_rounded_card_with_square_cells() {
        let cx = Cx::new();
        let hub = crate::hub::ImageHub::new(
            Box::new(ImageLoader::new(Arc::new(FixtureImages), None, Device::Mac)),
            &cx,
            1.0,
            Device::Mac,
        );
        let images: Vec<swiftly_vm::ImageRef> = Vec::new();
        let n = mosaic_node(&hub, &images, 120.0, 180.0, 12.0);
        assert!(
            n.clip && n.clip_radius == 12.0,
            "the card clips its cells with the tile corner"
        );
    }
}

#[cfg(test)]
mod no_demo_art_tests {
    use super::*;
    use crate::hub::HubSlotExt;
    use swiftly_images::fixture::FixtureImages;
    use swiftly_images::{Device, ImageLoader};
    use swiftly_ui::Idiom;

    fn uvs(n: &Node, out: &mut Vec<[f32; 4]>) {
        for p in &n.paint {
            if let Paint::Image { image, .. } = p {
                out.push(image.uv);
            }
        }
        for c in &n.children {
            uvs(c, out);
        }
    }

    fn bare(kind: &str) -> Tile {
        Tile {
            id: "t1".into(),
            title: "Ohne Bild".into(),
            subtitle: None,
            progress: None,
            image: None,
            badges: Vec::new(),
            remaining: None,
            facts: swiftly_vm::TileFacts {
                kind: Some(kind.into()),
                ..Default::default()
            },
        }
    }

    /// A title without a picture is the tile ground and its kind's symbol over the real hub: never one of the generated
    /// demo posters (`Theme.area` + `tileCharacter`).
    #[test]
    fn a_grid_tile_without_a_picture_never_draws_demo_art() {
        let cx = Cx::new();
        let env = Env::new(
            swiftly_layout::Size::new(1280.0, 800.0),
            2.0,
            Idiom::Desktop,
        );
        let m = metrics(&env);
        let g = grid(&m, 1000.0);
        let icons = Icons::new(&cx, env.scale);
        let art = Art::new(&cx);
        let demo: Vec<[f32; 4]> = art.posters.iter().map(|p| p.uv).collect();
        assert!(!demo.is_empty());
        let hub = crate::hub::ImageHub::new(
            Box::new(ImageLoader::new(Arc::new(FixtureImages), None, Device::Mac)),
            &cx,
            2.0,
            Device::Mac,
        );
        art.hub.attach(hub);
        for kind in ["Movie", "Series"] {
            let n = grid_tile(&cx, &icons, &m, &art, &bare(kind), &g, "k");
            let mut found = Vec::new();
            uvs(&n, &mut found);
            assert!(
                found.iter().all(|u| !demo.contains(u)),
                "{kind}: a generated poster is drawn"
            );
        }
    }
}
