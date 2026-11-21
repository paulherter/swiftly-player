//! The real Home screen of the shared Rust UI, drawn from `HomeVm` parts (status, rails, tiles) for the three form
//! factors: `touch` (header + tab bar), `desktop` (sidebar) and `tv` (top bar, focus). Layout numbers come from the
//! Swift `HomeView` / `Theme` and the `.isd` tokens.

use crate::art;
use crate::home_data::{self, Scenario};
use crate::hub::{HubSlot, HubSlotExt, ImageHub, remote_node};
use crate::net::AppTransport;
use std::cell::RefCell;
use std::collections::HashSet;
use std::rc::Rc;
use std::sync::Arc;
use swiftly_design::tokens::{desktop, touch, tv};
use swiftly_design::tokens_generated::color;
use swiftly_design::tokens_generated::desktop as dsk;
use swiftly_images::Priority;
use swiftly_layout::{Align, Alignment, Axis, EdgeInsets, FlexFrame, Size};
use swiftly_render::{CORNER_REACH, Color, DrawList, LinearGradient, RgbaImage};
use swiftly_text::TextStyle;
use swiftly_ui::components::{color, focus_id};
use swiftly_ui::icons::{Icons, SPOKES};
use swiftly_ui::{Action, Cx, Env, FocusLook, Idiom, ImageId, Node, Paint, Ui, UiEvent, tuning};
use swiftly_vm::{
    HomeIntent, HomeVm, ImageKind, Rail, RailKind, RailsPart, Status, StatusPart, Tile,
};

/// The tv page edge (`TVSpec.edgePage`); the `.isd` has no token for it.
const TV_EDGE: f32 = 80.0;
/// The tv tile corner (`components::tile_card`, scaled from the touch radius).
const TV_CORNER: f32 = 18.0;
/// Height of the progress bar at the bottom edge of a tile (`ProgressBar`).
const BAR_HEIGHT: f32 = 4.0;
/// Pull distance that starts a refresh on touch (the `refreshable` threshold).
pub const PULL_TO_REFRESH: f32 = 80.0;
/// The tabs of the bar (`Region.name`: Start, Filme, Serien, Suche).
pub const TABS: [&str; 4] = ["Start", "Filme", "Serien", "Suche"];

/// The three layouts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Form {
    /// Phone and tablet.
    Touch,
    /// Windows, Linux, Mac window.
    Desktop,
    /// Television.
    Tv,
}

impl Form {
    /// The layout for an idiom.
    pub fn of(idiom: Idiom) -> Form {
        match idiom {
            Idiom::Phone | Idiom::Pad => Form::Touch,
            Idiom::Desktop => Form::Desktop,
            Idiom::Tv => Form::Tv,
        }
    }
}

/// Sizes of one form factor.
struct Metrics {
    edge: f32,
    rails_spacing: f32,
    tile_spacing: f32,
    poster: Size,
    landscape: Size,
    corner: f32,
    rail: swiftly_design::TextStyle,
    tile: swiftly_design::TextStyle,
    small: swiftly_design::TextStyle,
    /// Gap between a tile image and its text.
    text_gap: f32,
    /// Gap between a rail header and its row.
    header_gap: f32,
}

fn metrics(form: Form, pad: bool) -> Metrics {
    match form {
        Form::Touch => Metrics {
            // `Theme.margin(wide:)`, `railsWidth(wide:)` (132, height x 1.5), `railsLandscapeWidth(wide:)` (280 x 158).
            edge: if pad {
                touch::EDGE_PAGE_WIDE
            } else {
                touch::EDGE_SPACING
            },
            rails_spacing: touch::RAILS_SPACING,
            tile_spacing: touch::TILE_SPACING,
            poster: if pad {
                Size::new(132.0, 198.0)
            } else {
                Size::new(touch::TILE_WIDTH, touch::TILE_HEIGHT)
            },
            landscape: Size::new(touch::HERO_ROW_WIDTH, touch::HERO_ROW_HEIGHT),
            corner: touch::CORNER_TILE,
            rail: touch::text::RAIL,
            tile: touch::text::TILE,
            small: touch::text::SMALL,
            text_gap: tuning::TILE_TITLE_GAP,
            header_gap: tuning::RAIL_HEADER_GAP,
        },
        Form::Desktop => Metrics {
            edge: dsk::SPACE_PAGE,
            rails_spacing: dsk::SPACE_RAIL_GAP,
            tile_spacing: dsk::SPACE_TILE_GAP,
            poster: Size::new(dsk::SIZE_POSTER_WIDTH, dsk::SIZE_POSTER_HEIGHT),
            // 16:9 of 280 pt as SwiftUI lays it out (159 pt in the parity render, the token says 158).
            landscape: Size::new(dsk::SIZE_LANDSCAPE_WIDTH, 159.0),
            corner: dsk::RADIUS_TILE,
            rail: dsk::TEXT_HEADING_SECTION,
            tile: dsk::TEXT_LABEL_TILE,
            small: dsk::TEXT_CAPTION_SMALL,
            text_gap: tuning::TILE_TITLE_GAP,
            header_gap: tuning::RAIL_HEADER_GAP,
        },
        Form::Tv => Metrics {
            edge: TV_EDGE,
            rails_spacing: tv::RAILS_SPACING,
            tile_spacing: tv::TILE_SPACING,
            poster: Size::new(tv::POSTER_WIDTH, tv::POSTER_HEIGHT),
            landscape: Size::new(tv::LANDSCAPE_WIDTH, tv::LANDSCAPE_HEIGHT),
            corner: TV_CORNER,
            rail: tv::text::RAIL,
            tile: tv::text::TILE,
            small: swiftly_design::TextStyle {
                uppercase: false,
                tracking: 0.0,
                ..tv::text::GROUP
            },
            text_gap: tuning::TILE_TITLE_GAP,
            header_gap: tv::RAILS_HEADER_PADDING - tuning::FOCUS_HEADROOM_PT,
        },
    }
}

pub(crate) fn ins(top: f32, leading: f32, bottom: f32, trailing: f32) -> EdgeInsets {
    EdgeInsets {
        top,
        leading,
        bottom,
        trailing,
    }
}

pub(crate) fn fill_frame(n: Node, align: Alignment) -> Node {
    n.flex_frame(FlexFrame {
        max_w: Some(f32::INFINITY),
        max_h: Some(f32::INFINITY),
        align: Some(align),
        ..FlexFrame::default()
    })
}

pub(crate) fn text(
    cx: &Cx,
    s: &str,
    st: swiftly_design::TextStyle,
    c: swiftly_design::Colour,
    lines: Option<usize>,
    align: swiftly_text::Align,
) -> Node {
    Node::text(cx, s, &TextStyle::from(st), color(c), lines, align)
}

/// `text` with tabular figures (SwiftUI `.monospacedDigit()`): for time, progress and counters that change while they are
/// on screen, so the digits do not jitter.
pub(crate) fn tabular_text(
    cx: &Cx,
    s: &str,
    st: swiftly_design::TextStyle,
    c: swiftly_design::Colour,
    lines: Option<usize>,
    align: swiftly_text::Align,
) -> Node {
    Node::text(
        cx,
        s,
        &TextStyle::from(st).with_tabular(),
        color(c),
        lines,
        align,
    )
}

pub(crate) fn rgba(c: swiftly_design::Colour, alpha: f32) -> Color {
    Color::new(c.r, c.g, c.b, alpha)
}

/// The pictures the demo stands in for server images.
struct Art {
    posters: Vec<ImageId>,
    landscapes: Vec<ImageId>,
}

impl Art {
    fn pick(&self, landscape: bool, id: &str) -> Option<ImageId> {
        let set = if landscape {
            &self.landscapes
        } else {
            &self.posters
        };
        let h = id.bytes().fold(7_usize, |a, b| {
            a.wrapping_mul(31).wrapping_add(usize::from(b))
        });
        set.get(h % set.len().max(1)).copied()
    }
}

/// What the view reads. Replaced whenever the vm publishes a new part or one of the small UI values moves.
#[derive(Clone, PartialEq)]
struct Parts {
    /// The Downloads page is in front (the sidebar marks it).
    downloads: bool,
    /// A panel (profile, settings) is open: the account card is the selected entry, no page row is.
    settings: bool,
    card: crate::desk::Card,
    /// The offer row of the sidebar.
    offer: Option<crate::desk::Offer>,
    /// The "Meins" rows that exist (Merkliste, Downloads).
    mine: (bool, bool),
    glow: (crate::look_glow::Glow, u16),
    status: Arc<StatusPart>,
    /// The page is still `Loading` but says so as trouble (see [`waiting_trouble`]): the error page with a busy button.
    waiting: Option<swiftly_vm::LoadFailure>,
    rails: Arc<RailsPart>,
    /// The tab in front (0 = Start).
    tab: usize,
    /// How far the page has scrolled, as the header strength in eighths (`BlurHeader.border`).
    header: u8,
    /// Spinner spokes shown while the finger pulls (0 to 12).
    pulled: u8,
    /// Spinner phase while a reload runs (0 to 11); `None` when no reload runs.
    spin: Option<u8>,
    /// The focused tile key on tv (the hero follows it).
    focus: Option<u64>,
    /// The open tile menu, devices list or download sheet.
    sheet: Sheet,
    /// The values the download sheet shows.
    load: crate::load_panel::LoadSpec,
    /// Changes when a real picture arrives or fades (see `ImageHub::stamp`).
    pictures: u64,
    /// The right-click menu of a tile (desktop).
    menu: crate::desk::TileMenu,
    /// The rail the pointer is over (desktop: its paging arrows show) and whether it can page left and right.
    rail_hover: Option<(String, bool, bool)>,
    /// The genre chips row above the rails (desktop; empty: none).
    chips: Vec<String>,
    /// Count of account switches whose rails stagger in (0: none yet); a new count gives every row a new identity so
    /// it appears again (`AccountTransition.swift:311-315`).
    stagger: u32,
    /// The old account's rows are leaving (the tap on an account, until the account changed).
    rails_out: bool,
    /// The support card at the end of the rails: the hours watched (`None`: no card; `MacSupportCard`).
    support: Option<i64>,
    /// The core's Seerr block above the rails: "<Titel> ist da", "Wartet auf dich", "Angefragt" (`None`: nothing to draw;
    /// `Pending`: the reserve of the last start's room, invisible).
    seerr: Option<swiftly_vm::SeerrHomeInfo>,
    /// Where the Seerr sections stand among the rails (the user's Home order, from the core).
    seerr_places: Vec<(swiftly_library::SeerrSection, usize)>,
}

/// What a tap on the Seerr block above the rails means, decided from the core's block of the moment.
#[derive(Debug, Clone, PartialEq)]
enum SeerrTap {
    /// The click or select on a closed stack: the core opens it.
    Expand,
    /// "Weniger anzeigen": the core closes it.
    Collapse,
    /// The X on a card: hide this request's arrival for good.
    Dismiss(i64),
    /// "Abspielen" on a film that arrived: play this library item.
    Play(String),
    /// "Abspielen" on a series that arrived, or a click on a card: that library item's page.
    Open(String),
    /// "Wartet auf dich".
    Attention,
    /// A tile of the "Angefragt" rail: that title's Seerr page.
    Title(swiftly_seerr::models::SeerrHit),
}

impl SeerrTap {
    /// `is(key)` tells whether the tapped control has that key.
    fn of(info: &swiftly_vm::SeerrHomeInfo, is: &dyn Fn(&str) -> bool) -> Option<SeerrTap> {
        // The reserve of a block that has not answered is blank and untouchable.
        if info.state != swiftly_vm::SeerrHomeState::Shown {
            return None;
        }
        if info.arrivals.len() > 1 {
            if is("arrival-expand") && !info.arrivals_expanded {
                return Some(SeerrTap::Expand);
            }
            if is("arrival-collapse") && info.arrivals_expanded {
                return Some(SeerrTap::Collapse);
            }
        }
        for a in &info.arrivals {
            let id = a.request_id;
            if is(&format!("arrival-dismiss:{id}")) {
                return Some(SeerrTap::Dismiss(id));
            }
            if is(&format!("arrival-play:{id}")) {
                return Some(if a.art == "tv" {
                    SeerrTap::Open(a.library_id.clone())
                } else {
                    SeerrTap::Play(a.library_id.clone())
                });
            }
            if is(&format!("arrival-open:{id}")) {
                return Some(SeerrTap::Open(a.library_id.clone()));
            }
        }
        if info.attention.is_some() && is("attention") {
            return Some(SeerrTap::Attention);
        }
        info.rail
            .iter()
            .enumerate()
            .find(|(i, _)| is(&format!("home-seerr:{i}")))
            .map(|(_, t)| SeerrTap::Title(crate::pages_screen::seerr_views::hit_of(t)))
    }
}

/// What a tap on the support card asks of the suite.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SupportTap {
    /// "Unterstützen": the supporter web page.
    Open,
    /// "Nicht jetzt": hide the card for 30 days.
    Snooze,
}

/// The support card (`MacSupportCard`, `MacSupport.swift:160`): the hours watched from two hours on, the ask, and two
/// buttons; a 18 pt padded `groupsArea` card of at most 480 pt, at the page's edge.
fn support_card(cx: &Cx, hours: i64) -> Node {
    use swiftly_support::SupportCopy;
    let words = |c: SupportCopy| c.de.to_owned();
    const W: f32 = dsk::SIZE_FORM_WIDTH + 60.0;
    let inner = W - 36.0;
    let mut lines = Vec::new();
    if hours >= SupportCopy::CARD_MINIMUM_HOURS {
        lines.push(
            text(
                cx,
                &words(SupportCopy::CARD_WATCHED_HOURS).replace("%lld", &hours.to_string()),
                dsk::TEXT_LABEL_ROW_TITLE,
                color::TEXT_PRIMARY,
                Some(2),
                swiftly_text::Align::Start,
            )
            .frame(Some(inner), None, Alignment::LEADING),
        );
    }
    lines.push(
        text(
            cx,
            &words(SupportCopy::CARD_ASK),
            dsk::TEXT_BODY_DEFAULT,
            color::TEXT_SECONDARY,
            Some(3),
            swiftly_text::Align::Start,
        )
        .frame(Some(inner), None, Alignment::LEADING),
    );
    let button = |label: String, key: &str, primary: bool| {
        let (fg, bg) = if primary {
            (color::SURFACE_BASE, color::TEXT_PRIMARY)
        } else {
            (color::TEXT_PRIMARY, color::SURFACE_CONTROL)
        };
        text(
            cx,
            &label,
            dsk::TEXT_LABEL_ROW_TITLE,
            fg,
            Some(1),
            swiftly_text::Align::Center,
        )
        .frame(
            Some((inner - 10.0) / 2.0),
            Some(desktop::PRIMARY_BUTTON_HEIGHT),
            Alignment::CENTER,
        )
        .background(Node::rect(color(bg), desktop::CORNER), Alignment::CENTER)
        .key(key)
        .on_tap(Action::from(key))
    };
    let buttons = Node::hstack(
        Align::Start,
        Some(10.0),
        vec![
            button(words(SupportCopy::CARD_SUPPORT), "support:open", true),
            button(words(SupportCopy::NOT_NOW), "support:snooze", false),
        ],
    );
    Node::vstack(
        Align::Start,
        Some(0.0),
        vec![
            Node::vstack(Align::Start, Some(4.0), lines),
            buttons.padding(ins(16.0, 0.0, 0.0, 0.0)),
        ],
    )
    .padding(ins(18.0, 18.0, 18.0, 18.0))
    .background(
        Node::rect(color(color::SURFACE_GROUP), dsk::RADIUS_CARD),
        Alignment::CENTER,
    )
    .padding(ins(0.0, dsk::SPACE_PAGE, 0.0, 0.0))
}

/// The tile menu sheet. The entries are computed once, when the sheet opens: the rows on show and the entry a tap
/// carries out are this one list, so they cannot differ (also not for a tile beyond the row's prepared window).
#[derive(Clone, Debug, PartialEq)]
struct MenuSheet {
    id: String,
    /// The tile that was clicked sits in the Continue Watching row.
    cw: bool,
    tile: Option<Tile>,
    cx: crate::tile_menu::Cx,
    entries: Vec<crate::tile_menu::Entry>,
}

/// The sheet over the Home page.
#[derive(Clone, Debug, PartialEq, Default)]
enum Sheet {
    #[default]
    None,
    Menu(Box<MenuSheet>),
    Devices(String),
    Load(String),
}

/// What the chrome (header, tab bar, sidebar, top bar) needs: the tab in front and the header strength in eighths.
/// Shared with the Library and Search screens.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Bar {
    /// The tab in front (0 = Start).
    pub tab: usize,
    /// How far the page has scrolled, as the header strength in eighths.
    pub header: u8,
    /// The Downloads page is in front: the sidebar marks "Downloads" instead of a tab.
    pub downloads: bool,
    /// A panel (profile, settings) is open: the account card at the bottom left is selected, no page row is. It is part
    /// of the view's input so the retained page behind the panel is rebuilt when the panel opens or closes.
    pub settings: bool,
    /// What the account card shows (part of the view's input, so a new account rebuilds the sidebar).
    pub card: crate::desk::Card,
    /// The row for what plays on another device or what a group offers (`OfferingRow`).
    pub offer: Option<crate::desk::Offer>,
    /// Which "Meins" rows exist: (Merkliste, Downloads), from the settings (`Region.mineGroup`). Both gone: no heading.
    pub mine: (bool, bool),
    /// The look's glow behind the page and how far the page has scrolled (see [`crate::look_glow`]).
    pub glow: (crate::look_glow::Glow, u16),
}

impl Parts {
    fn bar(&self) -> Bar {
        Bar {
            tab: self.tab,
            header: self.header,
            downloads: self.downloads,
            settings: self.settings,
            card: self.card.clone(),
            offer: self.offer.clone(),
            mine: self.mine,
            glow: self.glow,
        }
    }
}

/// What the view needs besides the parts.
struct Ctx {
    hub: HubSlot,
    art: Rc<Art>,
    /// The pictures of the Seerr block (TMDB posters through the same hub).
    seerr_art: crate::detail_screen::Art,
    icons: Icons,
    vm: HomeVm<AppTransport>,
}

// ---- tiles ---------------------------------------------------------------------------------------------------------

/// The Mac's fixed rail geometry (`HomeView.swift:542`): title 16 + 2 + line 15 plus 1 = 34.
const DESKTOP_TEXT_BLOCK: f32 = 34.0;
/// Room above and below a desktop rail row so the hover scale is not clipped (`LazyHStack` vertical 4).
const DESKTOP_RAIL_PAD: f32 = 4.0;

fn text_block_height(cx: &Cx, m: &Metrics) -> f32 {
    let line = |st: swiftly_design::TextStyle| {
        cx.measure_text(
            "Ag",
            &TextStyle::from(st),
            Some(1),
            swiftly_layout::Proposal::NIL,
        )
        .h
    };
    line(m.tile) + 2.0 + line(m.small)
}

/// The Mac progress bar of a poster: 4 pt flush at the bottom inside the picture's rounded mask, so the lower corners
/// follow the rounding (`MacComponents.swift:373`). `share` 0...1.
pub(crate) fn progress_bar(width: f32, corner: f32, share: f32) -> Node {
    let share = share.clamp(0.0, 1.0);
    let strip = |w: f32, color: Color| {
        // A rounded rectangle tall enough for the smoothed corner (two corner zones, a shorter one would count as a
        // capsule and stay circular; whole points, so the corner lands on the same pixels), bottom aligned, cut to the bottom 4 pt: exactly the tile's lower edge.
        let full = Node::rect(color, corner).frame(
            Some(width),
            Some((2.0 * CORNER_REACH * corner).ceil()),
            Alignment::BOTTOM_LEADING,
        );
        Node::zstack(Alignment::BOTTOM_LEADING, vec![full])
            .frame(Some(w), Some(BAR_HEIGHT), Alignment::BOTTOM_LEADING)
            .clipped()
    };
    Node::zstack(
        Alignment::BOTTOM_LEADING,
        vec![
            strip(width, Color::new(1.0, 1.0, 1.0, 0.30)),
            strip(width * share, color(crate::look_glow::accent())),
        ],
    )
}

/// One tile as `Tile` in `HomeView`: image with corner and edge, the progress bar flush at the bottom, name and the quiet
/// line under it. The Swift home tile draws no badges; the line is `continueWatchingRow` on the continue rail.
#[allow(clippy::too_many_arguments)]
fn tile_node(
    cx: &Cx,
    m: &Metrics,
    form: Form,
    art: &Art,
    hub: &HubSlot,
    icons: &Icons,
    tile: &Tile,
    landscape: bool,
    continue_rail: bool,
    key: &str,
) -> Node {
    let size = if landscape { m.landscape } else { m.poster };
    let hub = hub.borrow().clone();
    // Only the Continue Watching row plays on a tap (`resume:`); every other tile opens its page (`tile:`), also when the
    // same title is in the Continue Watching row too: the action says which row was tapped, the title's id cannot.
    let tap = Action::from(
        format!(
            "{}:{}",
            if continue_rail { "resume" } else { "tile" },
            tile.id
        )
        .as_str(),
    );
    // With the image hub (the real app) a title without a picture is the tile ground and the symbol of its kind, never
    // generated art (`NetworkImage` with `symbolText`); `art` is the demo's stand-in when there is no hub.
    let symbol = crate::detail_screen::tile_character_icon(
        tile.facts.kind.as_deref(),
        tile.facts.series_id.as_deref(),
    );
    let image = match (hub, tile.image.as_ref()) {
        (Some(hub), _) => {
            let back = Node::rect(color(color::SURFACE_CONTROL), m.corner)
                .pixel_snapped()
                .frame(Some(size.w), Some(size.h), Alignment::CENTER);
            back.overlay(
                remote_node(
                    hub.slot(tile.image.as_ref(), size.w, size.h, Priority::Visible),
                    size.w,
                    size.h,
                    m.corner,
                    || icons.node(symbol, 22.0, true, color(color::TEXT_PRIMARY)),
                ),
                Alignment::CENTER,
            )
            .pixel_snapped()
        }
        (None, _) => match art.pick(landscape, &tile.id) {
            Some(id) => Node::image(id, size.w, size.h, m.corner),
            None => Node::rect(color(color::SURFACE_CONTROL), m.corner).frame(
                Some(size.w),
                Some(size.h),
                Alignment::CENTER,
            ),
        },
    };
    let mut image = image.paint(Paint::Stroke {
        color: color(color::BORDER_TILE),
        width: 1.0,
        radius: m.corner,
    });
    // The progress bar lives inside the tile's mask (`MacComponents.swift:373`): a strip of the rounded picture, so the lower
    // corners follow the tile's rounding. It exists on the Continue Watching rail only ("Nächste Folge" has none).
    if form == Form::Desktop
        && continue_rail
        && let Some(share) = tile.progress.filter(|p| *p > 0.0)
    {
        let bar = progress_bar(size.w, m.corner, share);
        image = image.overlay(bar, Alignment::BOTTOM_LEADING);
    }
    if form != Form::Desktop
        && let Some(share) = tile.progress.filter(|p| *p > 0.0)
    {
        // The same bar as the desktop: a strip of the rounded picture, never a square-cornered rectangle.
        image = image.overlay(
            progress_bar(size.w, m.corner, share),
            Alignment::BOTTOM_LEADING,
        );
    }
    if form == Form::Desktop {
        // The picture with its progress bar scales to 1.04 (easeOut 0.12, `hover()` curve), the text does not move: the bar
        // belongs to the tile (`MacComponents.swift:373`, inside the mask the scale is applied to), so it scales last.
        image = image.hover_scale(swiftly_ui::feel::HOVER_TILE_SCALE);
        // Tab reaches the picture and shows the accent ring around it, not around title and year (the Mac's focus ring
        // is the picture's outline); Enter on it does what a click on the tile does.
        image = image
            .on_tap(tap)
            .focusable(focus_id(key), None)
            .focus_ring(color(crate::look_glow::accent()), m.corner);
    }
    // The menu action says which row was clicked: the Continue Watching row has the entry that removes a title from it,
    // the same title in another row has not.
    let menu = if continue_rail { "cmenu" } else { "menu" };
    let line = if continue_rail {
        tile.remaining.as_ref().or(tile.subtitle.as_ref())
    } else {
        tile.subtitle.as_ref()
    };
    let mut lines = vec![
        text(
            cx,
            &tile.title,
            m.tile,
            color::TEXT_PRIMARY,
            Some(1),
            swiftly_text::Align::Start,
        )
        .frame(
            Some(size.w),
            None,
            swiftly_ui::components::natural_edge(&tile.title),
        ),
    ];
    if let Some(sub) = line {
        lines.push(
            text(
                cx,
                sub,
                m.small,
                color::TEXT_TERTIARY,
                Some(1),
                swiftly_text::Align::Start,
            )
            .frame(
                Some(size.w),
                None,
                swiftly_ui::components::natural_edge(sub),
            ),
        );
    }
    let mut n = Node::vstack(
        Align::Start,
        Some(m.text_gap),
        vec![image, Node::vstack(Align::Start, Some(2.0), lines)],
    )
    .key(key)
    .on_tap(tap)
    .on_long_press(Action::from(format!("{menu}:{}", tile.id).as_str()));
    if form == Form::Tv {
        n = n.focusable(focus_id(key), Some(FocusLook::tile(m.corner)));
    }
    if form == Form::Desktop {
        // Right click opens the menu (the touch long press stays); the focus ring sits on the picture above.
        n = n
            .on_secondary(Action::from(format!("{menu}:{}", tile.id).as_str()))
            .on_hover_rest(Action::from(format!("rest:{}", tile.id).as_str()));
    }
    n
}

fn tile_key(rail: &str, i: usize) -> String {
    format!("{rail}:{i}")
}

/// One paging arrow of a rail (`PagingRail`): 34 x 34, area-coloured, radius 8, `at` pt from the top of the row, 6 pt
/// from its side; it fades in and out with the hover.
fn paging_arrow(
    icons: &Icons,
    asset: &str,
    label: &str,
    key: &str,
    trailing: bool,
    at: f32,
) -> Node {
    paging_arrow_inset(icons, asset, label, key, trailing, at, 6.0)
}

/// [`paging_arrow`] with its own distance `inset` from the side (the player's episode strip keeps 12 pt).
pub(crate) fn paging_arrow_inset(
    icons: &Icons,
    asset: &str,
    label: &str,
    key: &str,
    trailing: bool,
    at: f32,
    inset: f32,
) -> Node {
    let icon = icons
        .node(asset, 15.0, false, color(color::TEXT_PRIMARY))
        .frame(Some(34.0), Some(34.0), Alignment::CENTER);
    let b = icon
        .background(
            Node::rect(color(color::SURFACE_CONTROL), 8.0),
            Alignment::CENTER,
        )
        .hover_surface(
            Color::new(1.0, 1.0, 1.0, swiftly_ui::feel::HOVER_SURFACE_ALPHA),
            8.0,
        )
        .a11y(swiftly_ui::a11y::A11yNode::new(
            "",
            swiftly_ui::a11y::Role::Button,
            label,
        ))
        .key(key)
        .on_tap(Action::from(key))
        .appear_from(1.0, 0.0)
        .exit_to(1.0, 0.0)
        .opacity(1.0, swiftly_ui::feel::arrow());
    let pad = if trailing {
        ins(at, 0.0, 0.0, inset)
    } else {
        ins(at, inset, 0.0, 0.0)
    };
    fill_frame(
        b.padding(pad),
        if trailing {
            Alignment::TOP_TRAILING
        } else {
            Alignment::TOP_LEADING
        },
    )
}

#[allow(clippy::too_many_arguments)]
fn rail_node(
    cx: &Cx,
    m: &Metrics,
    form: Form,
    pad: bool,
    ctx: &Ctx,
    rails: &Arc<RailsPart>,
    index: usize,
    hover: &Option<(String, bool, bool)>,
) -> Node {
    let rail: &Rail = &rails.rails[index];
    let landscape = rail
        .tiles
        .first()
        .and_then(|t| t.image.as_ref())
        .is_some_and(|i| i.kind == ImageKind::Backdrop);
    let continue_rail = rail.kind == RailKind::ContinueWatching;
    let size = if landscape { m.landscape } else { m.poster };
    let block = if form == Form::Desktop {
        DESKTOP_TEXT_BLOCK
    } else {
        text_block_height(cx, m)
    };
    let slot = Size::new(size.w, size.h + m.text_gap + block);
    let headroom = match form {
        Form::Tv => tuning::FOCUS_HEADROOM_PT,
        Form::Desktop => DESKTOP_RAIL_PAD,
        Form::Touch => 0.0,
    };
    let (hub2, icons2) = (Rc::clone(&ctx.hub), ctx.icons.clone());
    let (cx2, art2, rails2, vm2) = (
        cx.clone(),
        Rc::clone(&ctx.art),
        Arc::clone(rails),
        ctx.vm.clone(),
    );
    let mm = metrics(form, pad);
    let item = move |i: usize| {
        let rail = &rails2.rails[index];
        let tile = rail
            .tiles
            .get(i)
            .cloned()
            .or_else(|| vm2.tiles(&rail.id, i, 1).into_iter().next());
        match tile {
            Some(t) => tile_node(
                &cx2,
                &mm,
                form,
                &art2,
                &hub2,
                &icons2,
                &t,
                landscape,
                continue_rail,
                &tile_key(&rail.id, i),
            ),
            None => Node::fixed(slot.w, slot.h),
        }
    };
    let strip = Node::lazy_stack(
        Axis::Horizontal,
        m.tile_spacing,
        rail.count as usize,
        slot,
        m.edge,
        m.edge,
        item,
    )
    .padding(ins(headroom, 0.0, headroom, 0.0));
    let step = size.w + m.tile_spacing;
    let row = Node::scroll(
        Axis::Horizontal,
        (form == Form::Touch && tuning::RAIL_SNAPS).then_some(step),
        strip,
    )
    .key(format!("rail-row:{}", rail.id).as_str())
    .frame(None, Some(slot.h + 2.0 * headroom), Alignment::TOP_LEADING);
    let header = text(
        cx,
        &rail.title,
        m.rail,
        color::TEXT_PRIMARY,
        Some(1),
        swiftly_text::Align::Start,
    )
    .a11y(
        swiftly_ui::a11y::A11yNode::new("", swiftly_ui::a11y::Role::Heading, rail.title.as_str())
            .with_level(2),
    )
    .padding(ins(0.0, m.edge, 0.0, m.edge));
    let (header, row) = if form == Form::Desktop {
        // Mac `RailTitle`: 28 high, "Alle \u{203a}" 15/500 at the right on the rails that link to a library; paging
        // arrows 34 x 34 over the image rows while the pointer is over the rail.
        let link =
            matches!(rail.kind, RailKind::NewMovies | RailKind::NewSeries) || rail.is_library();
        let title = text(
            cx,
            &rail.title,
            m.rail,
            color::TEXT_PRIMARY,
            Some(1),
            swiftly_text::Align::Start,
        )
        .a11y(
            swiftly_ui::a11y::A11yNode::new(
                "",
                swiftly_ui::a11y::Role::Heading,
                rail.title.as_str(),
            )
            .with_level(2),
        );
        let mut parts = vec![title, Node::spacer()];
        if link {
            parts.push(
                text(
                    cx,
                    "Alle \u{203a}",
                    swiftly_design::TextStyle {
                        size: 15.0,
                        weight: 500,
                        tracking: 0.0,
                        uppercase: false,
                    },
                    color::TEXT_TERTIARY,
                    Some(1),
                    swiftly_text::Align::End,
                )
                .frame(None, Some(28.0), Alignment::CENTER),
            );
        }
        // One button: the whole title row is the click area (`Button(action: header) { RailTitle(... all: true) }`).
        let mut head = Node::hstack(Align::Center, Some(8.0), parts)
            .padding(ins(0.0, m.edge, 0.0, m.edge))
            .frame(None, Some(28.0), Alignment::LEADING);
        if link {
            head = head
                .a11y(swiftly_ui::a11y::A11yNode::new(
                    "",
                    swiftly_ui::a11y::Role::Button,
                    format!("Alle anzeigen: {}", rail.title).as_str(),
                ))
                .key(format!("all:{}", rail.id).as_str())
                .on_tap(Action::from(format!("all:{}", rail.id).as_str()));
        }
        let mut row = row;
        // Both overlay slots always exist so the scroll view keeps its identity (and offset) when the arrows come and go.
        let (show, left, right) = match hover {
            Some((hovered, l, r)) if *hovered == rail.id => (true, *l, *r),
            _ => (false, false, false),
        };
        {
            let arrow = |asset: &str, label: &str, key: String, trailing: bool| {
                paging_arrow(
                    &ctx.icons,
                    asset,
                    label,
                    &key,
                    trailing,
                    headroom + size.h / 2.0 - 17.0,
                )
            };
            let none = || Node::fixed(0.0, 0.0);
            row = row.overlay(
                if show && left {
                    arrow(
                        "caret-left",
                        "Zur\u{fc}ckbl\u{e4}ttern",
                        format!("page.l:{}", rail.id),
                        false,
                    )
                } else {
                    none()
                },
                Alignment::TOP_LEADING,
            );
            row = row.overlay(
                if show && right {
                    arrow(
                        "caret-right",
                        "Weiterbl\u{e4}ttern",
                        format!("page.r:{}", rail.id),
                        true,
                    )
                } else {
                    none()
                },
                Alignment::TOP_TRAILING,
            );
        }
        (head, row)
    } else {
        (header, row)
    };
    let n = Node::vstack(Align::Start, Some(m.header_gap), vec![header, row])
        .key(format!("rail:{}", rail.id).as_str());
    let n = if form == Form::Desktop {
        n.on_hover(Action::from(format!("rail:{}", rail.id).as_str()))
    } else {
        n
    };
    if form == Form::Tv {
        n.focus_scope(swiftly_ui::ScopeSpec::section(focus_id(
            format!("rail:{}", rail.id).as_str(),
        )))
    } else {
        n
    }
}

// ---- states --------------------------------------------------------------------------------------------------------

pub(crate) fn load_field(w: f32, h: f32, radius: f32) -> Node {
    // `LoadField`: opacity 0.5 to 1 with `easeInOut(0.9)` forever, none under Reduce Motion (`MacComponents.swift:506-523`).
    Node::rect(color(color::SURFACE_CONTROL), radius)
        .frame(Some(w), Some(h), Alignment::CENTER)
        .appear_from(1.0, swiftly_ui::feel::PULSE_LOW)
        .opacity(1.0, swiftly_ui::feel::pulse())
}

/// Rows of paging rails with no rail of their own use this id for the hover and the arrows.
const CHIPS_RAIL: &str = "chips";
/// One page of the chips: three pieces of 120 (`PagingRail(widthJePiece: 120)`, `stepRange` 3).
const CHIPS_STEP: f32 = 3.0 * 120.0;

/// The genre chips (`HomeView.genreChips`): a paging rail of capsules 34 high on a 42 frame, side 14, 13/500 white on
/// white 8 % with the margin hairline, a tile spacing apart, scrolling sideways with arrows while the pointer is over
/// it. A tap reports `genre:<name>`.
fn chips_row(
    cx: &Cx,
    m: &Metrics,
    icons: &Icons,
    chips: &[String],
    hover: &Option<(String, bool, bool)>,
) -> Node {
    let items: Vec<Node> = chips
        .iter()
        .map(|g| {
            let label = text(
                cx,
                g,
                swiftly_design::TextStyle {
                    size: 13.0,
                    weight: 500,
                    tracking: 0.0,
                    uppercase: false,
                },
                color::TEXT_PRIMARY,
                Some(1),
                swiftly_text::Align::Center,
            );
            label
                .padding(EdgeInsets::symmetric(14.0, 0.0))
                .frame(None, Some(34.0), Alignment::CENTER)
                .background(
                    Node::rect(Color::new(1.0, 1.0, 1.0, 0.08), 17.0),
                    Alignment::CENTER,
                )
                .paint(Paint::Stroke {
                    color: color(color::SURFACE_FOCUS),
                    width: 1.0,
                    radius: 17.0,
                })
                .hover_surface(
                    Color::new(1.0, 1.0, 1.0, swiftly_ui::feel::HOVER_SURFACE_ALPHA),
                    17.0,
                )
                .a11y(swiftly_ui::a11y::A11yNode::new(
                    "",
                    swiftly_ui::a11y::Role::Button,
                    g.as_str(),
                ))
                .key(format!("genre:{g}").as_str())
                .on_tap(Action::from(format!("genre:{g}").as_str()))
        })
        .collect();
    let strip = Node::hstack(Align::Center, Some(m.tile_spacing), items)
        .padding(ins(4.0, m.edge, 4.0, m.edge));
    let mut row = Node::scroll(Axis::Horizontal, None, strip)
        .key(format!("rail-row:{CHIPS_RAIL}").as_str())
        .frame(None, Some(42.0), Alignment::TOP_LEADING);
    let (show, left, right) = match hover {
        Some((h, l, r)) if h == CHIPS_RAIL => (true, *l, *r),
        _ => (false, false, false),
    };
    let none = || Node::fixed(0.0, 0.0);
    row = row.overlay(
        if show && left {
            paging_arrow(
                icons,
                "caret-left",
                "Zur\u{fc}ckbl\u{e4}ttern",
                &format!("page.l:{CHIPS_RAIL}"),
                false,
                4.0,
            )
        } else {
            none()
        },
        Alignment::TOP_LEADING,
    );
    row = row.overlay(
        if show && right {
            paging_arrow(
                icons,
                "caret-right",
                "Weiterbl\u{e4}ttern",
                &format!("page.r:{CHIPS_RAIL}"),
                true,
                4.0,
            )
        } else {
            none()
        },
        Alignment::TOP_TRAILING,
    );
    row.key(format!("rail:{CHIPS_RAIL}").as_str())
        .on_hover(Action::from(format!("rail:{CHIPS_RAIL}").as_str()))
}

/// `RailsPlaceholder`: a title bar and four tiles in their final shape.
fn rails_placeholder(m: &Metrics, landscape: bool) -> Node {
    let size = if landscape { m.landscape } else { m.poster };
    let tiles = (0..4)
        .map(|_| load_field(size.w, size.h, m.corner))
        .collect();
    let row = Node::hstack(Align::Start, Some(m.tile_spacing), tiles)
        .padding(ins(0.0, m.edge, 0.0, 0.0))
        .frame(None, Some(size.h), Alignment::TOP_LEADING)
        .clipped();
    Node::vstack(
        Align::Start,
        Some(m.header_gap),
        vec![
            load_field(148.0, 18.0, 4.0).padding(ins(0.0, m.edge, 0.0, 0.0)),
            fill_frame(row, Alignment::TOP_LEADING).frame(
                None,
                Some(size.h),
                Alignment::TOP_LEADING,
            ),
        ],
    )
}

/// `EmptyState`: disc 120 with the symbol (52 pt), heading, text, quiet button; spacings 24 / 8 / 24.
pub(crate) fn empty_state(
    cx: &Cx,
    icons: &Icons,
    asset: &str,
    heading: &str,
    body: &str,
    button: &str,
) -> Node {
    empty_state_with(cx, icons, asset, heading, body, button, false)
}

/// [`empty_state`] with a busy button: the label is quiet and takes no tap (the page is trying again).
fn empty_column(
    cx: &Cx,
    icons: &Icons,
    asset: &str,
    heading: &str,
    body: &str,
    button: &str,
    busy: bool,
) -> Node {
    let disc = icons
        .node(asset, touch::EMPTY_SYMBOL, true, color(color::TEXT_PRIMARY))
        .frame(
            Some(touch::EMPTY_DISC),
            Some(touch::EMPTY_DISC),
            Alignment::CENTER,
        )
        .background(
            Node::rect(color(color::SURFACE_CONTROL), touch::EMPTY_DISC / 2.0),
            Alignment::CENTER,
        );
    Node::vstack(
        Align::Center,
        Some(0.0),
        vec![
            disc.padding(ins(0.0, 0.0, 24.0, 0.0)),
            text(
                cx,
                heading,
                touch::text::SUBPAGE,
                color::TEXT_PRIMARY,
                Some(2),
                swiftly_text::Align::Center,
            )
            .padding(ins(0.0, 0.0, 8.0, 0.0)),
            text(
                cx,
                body,
                touch::text::BODY,
                color::TEXT_SECONDARY,
                None,
                swiftly_text::Align::Center,
            )
            .frame(Some(touch::EMPTY_TEXT_WIDTH), None, Alignment::CENTER)
            .padding(ins(0.0, 0.0, 24.0, 0.0)),
            if button.is_empty() {
                Node::fixed(0.0, 0.0)
            } else if busy {
                text(
                    cx,
                    button,
                    touch::text::CATEGORY,
                    color::TEXT_SECONDARY,
                    Some(1),
                    swiftly_text::Align::Center,
                )
                .padding(EdgeInsets::symmetric(16.0, 0.0))
                .frame(None, Some(44.0), Alignment::CENTER)
                .key("retry-busy")
            } else {
                text(
                    cx,
                    button,
                    touch::text::CATEGORY,
                    crate::look_glow::accent(),
                    Some(1),
                    swiftly_text::Align::Center,
                )
                .padding(EdgeInsets::symmetric(16.0, 0.0))
                .frame(None, Some(44.0), Alignment::CENTER)
                .key("retry")
                .on_tap(RETRY)
            },
        ],
    )
}

fn empty_state_with(
    cx: &Cx,
    icons: &Icons,
    asset: &str,
    heading: &str,
    body: &str,
    button: &str,
    busy: bool,
) -> Node {
    fill_frame(
        empty_column(cx, icons, asset, heading, body, button, busy),
        Alignment::CENTER,
    )
}

/// The server notice over stored rows (the same block as the full-page one, `Trouble.copy`, in the rows' flow): the page
/// shows what it stored and the server does not answer. Only for the two "does not answer" failures; a refused sign-in or
/// an unreadable answer have their own page. `busy`: a retry is running, the button waits.
fn server_notice(
    cx: &Cx,
    icons: &Icons,
    server: &str,
    failure: swiftly_vm::LoadFailure,
    busy: bool,
) -> Option<Node> {
    use swiftly_vm::{FailKind, LoadFailure};
    if !matches!(
        failure,
        LoadFailure::Offline | LoadFailure::Failed(FailKind::Server)
    ) {
        return None;
    }
    let (title, body) = failure.copy(server);
    let button = if busy {
        "Moment\u{2026}"
    } else {
        "Erneut versuchen"
    };
    Some(
        empty_column(cx, icons, "hard-drive-x", title, &body, button, busy)
            .flex_frame(FlexFrame {
                max_w: Some(f32::INFINITY),
                align: Some(Alignment::CENTER),
                ..FlexFrame::default()
            })
            .padding(ins(8.0, 0.0, 0.0, 0.0))
            .key("server-notice"),
    )
}

const RETRY: &str = "home.retry";

/// How long a Start page that shows nothing waits before it says the server is not answering (the answer may still
/// come and fill the page). A refused connection says so at once; a server that drops packets or never replies says
/// nothing, and grey skeletons for the transport's whole timeout look like a hang.
pub const SILENT_AFTER_MS: f64 = 5000.0;

/// Whether a `Loading` Start page without rails draws the error page with a busy button instead of skeletons: at once
/// after "Erneut versuchen" (with the words of the failure it was pressed on), and on a cold start once
/// [`SILENT_AFTER_MS`] have passed. `loading_from` is the page's own stopwatch; it restarts whenever the page is not
/// waiting. `holding` (the Seerr rows are awaited on a healthy server) never counts as silence.
fn waiting_trouble(
    status: Status,
    has_rails: bool,
    holding: bool,
    retrying: Option<swiftly_vm::LoadFailure>,
    loading_from: &mut Option<f64>,
    now: f64,
) -> Option<swiftly_vm::LoadFailure> {
    if status != Status::Loading || has_rails {
        *loading_from = None;
        return None;
    }
    let from = *loading_from.get_or_insert(now);
    if let Some(failure) = retrying {
        return Some(failure);
    }
    (!holding && now - from >= SILENT_AFTER_MS).then_some(swiftly_vm::LoadFailure::Offline)
}

// ---- chrome --------------------------------------------------------------------------------------------------------

fn wordmark(cx: &Cx, label: &str, size: swiftly_design::TextStyle) -> Node {
    text(
        cx,
        label,
        size,
        color::TEXT_PRIMARY,
        Some(1),
        swiftly_text::Align::Start,
    )
}

/// Steps of the desktop toolbar strength (`Bar::header` on desktop runs 0...`BAR_STEPS`, finer than the touch eighths so the
/// 26 pt fade-in does not stair-step).
pub(crate) const BAR_STEPS: u8 = 64;

/// The Mac `StateBar` strength for a scroll `offset`: 0 until `since`, then 1 over `over` pt, as 0...`BAR_STEPS`.
/// Page bars start at `CONTENT_TOP + 33 - TOOLBAR_HEIGHT` = 39 and fade over 26 pt; `DetailHeader` over 74 + 42.
pub(crate) fn bar_strength(offset: f32, since: f32, over: f32) -> u8 {
    (((offset - since) / over).clamp(0.0, 1.0) * f32::from(BAR_STEPS)).round() as u8
}

/// The Mac page bars' scroll offset where the small title starts to fade in.
pub(crate) const BAR_SINCE: f32 = dsk::SPACE_CONTENT_TOP + 33.0 - dsk::SIZE_TOOLBAR_HEIGHT;
/// Width reserved for the back/forward arrows in the bar (`NavArrows.width`).
pub(crate) const ARROWS_WIDTH: f32 = 62.0;

/// `HeaderBackdrop`: the soft edge glow under the toolbar, a gradient of the ground colour (`reason`) 150 pt high, eased
/// 0.97 at the top to 0 at the foot, no blur and no line, at `min(1, strength * 3)` opacity (`strength` 0...1).
/// Design name: HeaderBackdrop
/// Height (pt) of the toolbar glow.
const BACKDROP_HEIGHT: f32 = 150.0;
/// The Mac's ten sample points of the glow (position 0...1, alpha).
const BACKDROP_CURVE: [(f32, f32); 10] = [
    (0.0, 0.97),
    (0.15, 0.93),
    (0.30, 0.87),
    (0.45, 0.78),
    (0.58, 0.64),
    (0.70, 0.46),
    (0.80, 0.29),
    (0.88, 0.15),
    (0.94, 0.06),
    (1.0, 0.0),
];
/// Segments the glow is drawn in: with the ten corners of the Mac curve the 8-bit ramp showed visible bands (slope jumps
/// at every corner); a monotone cubic through the same points in this many short linear pieces has no visible corner.
const BACKDROP_PIECES: usize = 96;

/// The glow's stops: [`BACKDROP_CURVE`] interpolated with a monotone cubic (Fritsch-Carlson, so it never overshoots) and
/// cut into [`BACKDROP_PIECES`] equal pieces.
pub(crate) fn backdrop_stops() -> Vec<(f32, f32)> {
    let p = &BACKDROP_CURVE;
    let n = p.len();
    let secant: Vec<f32> = (0..n - 1)
        .map(|i| (p[i + 1].1 - p[i].1) / (p[i + 1].0 - p[i].0))
        .collect();
    let mut m = vec![0.0_f32; n];
    m[0] = secant[0];
    m[n - 1] = secant[n - 2];
    for i in 1..n - 1 {
        m[i] = if secant[i - 1] * secant[i] <= 0.0 {
            0.0
        } else {
            (secant[i - 1] + secant[i]) / 2.0
        };
    }
    for i in 0..n - 1 {
        if secant[i] == 0.0 {
            m[i] = 0.0;
            m[i + 1] = 0.0;
            continue;
        }
        let (a, b) = (m[i] / secant[i], m[i + 1] / secant[i]);
        let r = a * a + b * b;
        if r > 9.0 {
            let t = 3.0 / r.sqrt();
            m[i] = t * a * secant[i];
            m[i + 1] = t * b * secant[i];
        }
    }
    (0..=BACKDROP_PIECES)
        .map(|k| {
            let x = k as f32 / BACKDROP_PIECES as f32;
            let i = (0..n - 1).rev().find(|&i| x >= p[i].0).unwrap_or(0);
            let h = p[i + 1].0 - p[i].0;
            let t = ((x - p[i].0) / h).clamp(0.0, 1.0);
            let (t2, t3) = (t * t, t * t * t);
            let y = (2.0 * t3 - 3.0 * t2 + 1.0) * p[i].1
                + (t3 - 2.0 * t2 + t) * h * m[i]
                + (-2.0 * t3 + 3.0 * t2) * p[i + 1].1
                + (t3 - t2) * h * m[i + 1];
            (x, y.clamp(0.0, 1.0))
        })
        .collect()
}

pub(crate) fn header_backdrop(strength: f32) -> Node {
    const HEIGHT: f32 = BACKDROP_HEIGHT;
    let op = (strength * 3.0).clamp(0.0, 1.0);
    if op <= 0.0 {
        return Node::fixed(0.0, 0.0);
    }
    // One node with the whole ramp: the renderer lays the seams between its pieces on whole device pixels. Ninety-six
    // separate rectangles in a stack had fractional heights (1.5625 pt), so at a scale of 1.5 most seams ran through a
    // device pixel, which two half-covering bands paint too dark: a dark line every second row.
    let stops: Vec<(f32, Color)> = backdrop_stops()
        .into_iter()
        .map(|(at, a)| (at, rgba(color::SURFACE_BASE, a * op)))
        .collect();
    Node::rect(rgba(color::SURFACE_BASE, 0.0), 0.0)
        .paint(Paint::Stops {
            stops,
            vertical: true,
            radius: 0.0,
        })
        .flex_frame(FlexFrame {
            max_w: Some(f32::INFINITY),
            align: Some(Alignment::TOP),
            ..FlexFrame::default()
        })
        .frame(None, Some(HEIGHT), Alignment::TOP)
}

/// `StateBar`: the toolbar zone of a scrolling Mac page: the backdrop glow plus the small page title (14 semibold, 94 pt
/// from the left: 20 + the arrows' 62 + 12), fading in as the large title scrolls out (`strength` 0...`BAR_STEPS`).
/// Design name: StateBar
pub(crate) fn state_bar(cx: &Cx, title: &str, strength: u8) -> Node {
    let s = f32::from(strength) / f32::from(BAR_STEPS);
    let name = Node::text(
        cx,
        title,
        &TextStyle::from(swiftly_design::TextStyle {
            size: 14.0,
            weight: 600,
            tracking: 0.0,
            uppercase: false,
        }),
        rgba(color::TEXT_PRIMARY, s),
        Some(1),
        swiftly_text::Align::Start,
    )
    .padding(EdgeInsets {
        top: 0.0,
        leading: 20.0 + ARROWS_WIDTH + 12.0,
        bottom: 0.0,
        trailing: 16.0,
    })
    .frame(None, Some(dsk::SIZE_TOOLBAR_HEIGHT), Alignment::LEADING);
    let name = name.flex_frame(FlexFrame {
        max_w: Some(f32::INFINITY),
        align: Some(Alignment::LEADING),
        ..FlexFrame::default()
    });
    header_backdrop(s).overlay(name, Alignment::TOP)
}

/// Blur radius (pt) of the system ultra-thin dark material under the touch headers (`Blur.style`). Estimated: UIKit
/// does not publish it; a blur of 20 pt with the 8 % white of `Theme.surfaceTranslucent` is what the Swift chips use.
pub(crate) const MATERIAL_BLUR: f32 = 20.0;

/// A vertical ramp of `colour` through `stops` (position 0...1, alpha), `opacity` multiplied in: one linear gradient per
/// pair of stops, since a gradient here has two colours.
pub(crate) fn ramp(
    colour: swiftly_design::Colour,
    stops: &[(f32, f32)],
    opacity: f32,
    w: f32,
    h: f32,
) -> Node {
    let mut bands = Vec::new();
    for pair in stops.windows(2) {
        let (a, b) = (pair[0], pair[1]);
        let band_h = (b.0 - a.0) * h;
        if band_h <= 0.0 {
            continue;
        }
        let (ca, cb) = (rgba(colour, a.1 * opacity), rgba(colour, b.1 * opacity));
        bands.push(
            Node::rect(ca, 0.0)
                .paint(Paint::Linear {
                    gradient: LinearGradient {
                        start: ca,
                        end: cb,
                        from: [0.5, 0.0],
                        to: [0.5, 1.0],
                    },
                    radius: 0.0,
                })
                .frame(Some(w), Some(band_h), Alignment::CENTER),
        );
    }
    Node::vstack(Align::Start, Some(0.0), bands)
}

/// The touch header under title bars (`BlurHeader` / `DetailHeader`): `HeaderBlur` (material blur that fades out toward
/// the foot, strength squared, plus a ground gradient 0.97 / 0.78 / 0 at three times the strength) and `HeaderHistory`
/// (nine-step ground fall-off), 17 pt longer than the bar (`gift`). `eighths` is the scroll strength 0...8.
/// Design name: BlurHeader
pub(crate) fn glass_ground(width: f32, height: f32, eighths: u8, history_floor: f32) -> Node {
    let s = f32::from(eighths) / 8.0;
    let gift = 17.0;
    let h = height + gift;
    let mut layers = Vec::new();
    let blur = MATERIAL_BLUR * s * s;
    if blur >= 1.0 {
        // The Swift mask (`Blur(fullUntil: 0.3)`): 1 to 30 %, 0.45 at 65 %, 0 at the foot, linear between. Seven bands sample
        // it at their centres (the mask scales the blend; here it scales the radius, which the glass paint cannot mix).
        let third = 0.35 / 3.0;
        for (span, k) in [
            (0.3, 1.0),
            (third, 0.908),
            (third, 0.725),
            (third, 0.542),
            (third, 0.375),
            (third, 0.225),
            (third, 0.075),
        ] {
            layers.push(
                Node::rect(Color::new(0.0, 0.0, 0.0, 0.0), 0.0)
                    .paint(Paint::Blur {
                        blur: blur * k,
                        tint: Color::new(0.0, 0.0, 0.0, 0.0),
                        radius: 0.0,
                    })
                    .frame(Some(width), Some(span * h), Alignment::CENTER),
            );
        }
    }
    let blur_stack = Node::vstack(Align::Start, Some(0.0), layers);
    let ground = ramp(
        color::SURFACE_BASE,
        &[(0.0, 0.97), (0.45, 0.78), (1.0, 0.0)],
        (s * 3.0).min(1.0),
        width,
        h,
    );
    let history = ramp(
        color::SURFACE_BASE,
        &[
            (0.0, 1.0),
            (0.30, 0.96),
            (0.48, 0.86),
            (0.62, 0.70),
            (0.73, 0.52),
            (0.82, 0.34),
            (0.89, 0.19),
            (0.95, 0.09),
            (1.0, 0.0),
        ],
        history_floor + (1.0 - history_floor) * s,
        width,
        h,
    );
    let line = Node::rect(
        rgba(color::BORDER_HAIRLINE, color::BORDER_HAIRLINE.a * s),
        0.0,
    )
    .frame(Some(width), Some(1.0), Alignment::CENTER);
    // The hairline sits at the bar's foot, `gift` above the end of the gradient.
    let line = line.padding(ins(height - 1.0, 0.0, 0.0, 0.0));
    Node::fixed(width, h)
        .background(history, Alignment::TOP_LEADING)
        .background(ground, Alignment::TOP_LEADING)
        .background(blur_stack, Alignment::TOP_LEADING)
        .overlay(line, Alignment::TOP_LEADING)
}

pub(crate) fn header(cx: &Cx, env: &Env, p: &Bar, title: &str) -> Node {
    let height = env.safe.top + 44.0 + 12.0;
    let profile = Node::rect(color(color::SURFACE_CONTROL), 999.0)
        .frame(Some(32.0), Some(32.0), Alignment::CENTER)
        .key("profile")
        .on_tap(Action::from("profile"));
    let row = Node::hstack(
        Align::Center,
        Some(0.0),
        vec![
            wordmark(cx, title, touch::text::TITLE_LARGE),
            Node::spacer(),
            profile,
        ],
    )
    .padding(ins(
        env.safe.top,
        touch::EDGE_SPACING,
        12.0,
        touch::EDGE_SPACING,
    ))
    .frame(None, Some(height), Alignment::TOP_LEADING);
    row.background(
        glass_ground(env.size.w, height, p.header, 0.0),
        Alignment::TOP_LEADING,
    )
}

/// The sidebar's Merkliste row: the Mac draws `bookmark.fill` in both states (`MainView.swift`, `Region.symbol`; its
/// `tabAsset` has no outline/filled pair for it), only the colour tells selected from idle. The other rows are the tab
/// icon set A, outline idle and filled selected ([`tab_icon`]).
const WATCHLIST_ICON: &str = "bookmark-simple.fill";

/// The icon of a tab and whether it is drawn with a stroke weight: tab icons A (design/icons/mapping.json), outline
/// while idle and the filled variant while selected.
fn tab_icon(i: usize, selected: bool) -> (&'static str, bool) {
    let (outline, filled) = match i {
        0 => ("tab-home", "tab-home.fill"),
        1 => ("tab-movies", "tab-movies.fill"),
        2 => ("tab-series", "tab-series.fill"),
        _ => ("tab-search", "tab-search.fill"),
    };
    if selected {
        (filled, false)
    } else {
        (outline, true)
    }
}

pub(crate) fn tab_bar(cx: &Cx, env: &Env, p: &Bar, icons: &Icons) -> Node {
    let tabs = TABS
        .iter()
        .enumerate()
        .map(|(i, name)| {
            let c = if i == p.tab {
                crate::look_glow::accent()
            } else {
                color::TEXT_TERTIARY
            };
            let (asset, outlined) = tab_icon(i, i == p.tab);
            let column = Node::vstack(
                Align::Center,
                Some(3.0),
                vec![
                    icons.node(asset, 24.0, outlined, color(c)).frame(
                        None,
                        Some(touch::TAB_ICON_HEIGHT),
                        Alignment::CENTER,
                    ),
                    text(
                        cx,
                        name,
                        touch::text::BADGE,
                        c,
                        Some(1),
                        swiftly_text::Align::Center,
                    ),
                ],
            );
            fill_frame(column, Alignment::TOP)
                .a11y(
                    swiftly_ui::a11y::A11yNode::new("", swiftly_ui::a11y::Role::Tab, *name)
                        .with_selected(i == p.tab),
                )
                .key(format!("tab:{i}").as_str())
                .on_tap(Action::from(format!("tab:{i}").as_str()))
        })
        .collect();
    let row = Node::hstack(Align::Start, Some(0.0), tabs)
        .padding(ins(8.0, 0.0, 0.0, 0.0))
        .frame(
            None,
            Some(touch::STRIP_HEIGHT + env.safe.bottom),
            Alignment::TOP_LEADING,
        );
    let line =
        Node::rect(color(color::BORDER_HAIRLINE), 0.0).frame(None, Some(1.0), Alignment::TOP);
    fill_frame(row, Alignment::TOP_LEADING)
        .frame(
            None,
            Some(touch::STRIP_HEIGHT + env.safe.bottom),
            Alignment::TOP_LEADING,
        )
        .background(
            Node::rect(rgba(color::SURFACE_BASE, 0.94), 0.0),
            Alignment::CENTER,
        )
        .overlay(line, Alignment::TOP)
}

/// Turns the text and image paints of `n` into ones that follow hover and focus: quiet at rest, `hot` when hovered.
pub(crate) fn quiet_to_hot(
    mut n: Node,
    rest: swiftly_design::Colour,
    hot: swiftly_design::Colour,
) -> Node {
    n.paint = n
        .paint
        .into_iter()
        .map(|p| match p {
            Paint::Text {
                text,
                style,
                lines,
                align,
                ..
            } => Paint::FocusText {
                text,
                style,
                rest: color(rest),
                focused: color(hot),
                lines,
                align,
            },
            Paint::Image { image, radius, .. } => Paint::FocusImage {
                image,
                rest: color(rest),
                focused: color(hot),
                radius,
            },
            other => other,
        })
        .collect();
    n
}

/// The Mac `Sidebar`: 220 wide on `surface.group`, a hairline on its right, no wordmark (the rows start `SPACE_SIDEBAR_TOP`
/// from the top), the four places with their
/// shortcut hints, "Meins" (Merkliste, Downloads) and the account footer (no "Profil" row). Rows are 32 high, icon 18,
/// label 14 (semibold and accent when active), corner 8; rest `fontQuiet`, hover white with a white 6 % surface, active
/// accent on accent 12 %.
pub(crate) fn sidebar(cx: &Cx, p: &Bar, icons: &Icons, hub: &crate::hub::HubSlot) -> Node {
    let hot = Color::new(1.0, 1.0, 1.0, swiftly_ui::feel::HOVER_SURFACE_ALPHA);
    let row = |active: bool,
               name: &str,
               asset: &str,
               outlined: bool,
               hint: Option<String>,
               action: &str,
               tip: &str| {
        let (rest, hover_c) = if active {
            (crate::look_glow::accent(), crate::look_glow::accent())
        } else {
            (color::TEXT_SECONDARY, color::TEXT_PRIMARY)
        };
        let style = swiftly_design::TextStyle {
            size: 14.0,
            weight: if active { 600 } else { 500 },
            ..dsk::TEXT_LABEL_BAR_TITLE
        };
        let mut cells = vec![
            quiet_to_hot(
                icons.node(asset, 18.0, outlined, color(rest)),
                rest,
                hover_c,
            )
            .frame(Some(18.0), None, Alignment::CENTER),
            // Priority 1: the label is offered its room before the spacer shares it (else a 9-letter label was cut to
            // "Downlo..." although the row is 200 wide).
            quiet_to_hot(
                text(cx, name, style, rest, Some(1), swiftly_text::Align::Start),
                rest,
                hover_c,
            )
            .layout_priority(1.0),
            Node::spacer(),
        ];
        if let Some(h) = hint {
            let st = swiftly_design::TextStyle {
                size: 11.0,
                weight: 500,
                tracking: 0.0,
                uppercase: false,
            };
            cells.push(text(
                cx,
                &h,
                st,
                color::TEXT_TERTIARY,
                Some(1),
                swiftly_text::Align::End,
            ));
        }
        let content = Node::hstack(Align::Center, Some(10.0), cells)
            .padding(EdgeInsets::symmetric(10.0, 0.0))
            .frame(None, Some(desktop::ROW_HEIGHT), Alignment::LEADING);
        let mut n = fill_frame(content, Alignment::LEADING).frame(
            None,
            Some(desktop::ROW_HEIGHT),
            Alignment::LEADING,
        );
        if active {
            n = n.background(
                Node::rect(rgba(crate::look_glow::accent(), 0.12), 8.0),
                Alignment::CENTER,
            );
        }
        n.hover_surface(hot, swiftly_ui::feel::SIDEBAR_HOVER_RADIUS)
            .press_style(swiftly_ui::PressStyle::Row)
            .focusable(focus_id(action), None)
            .focus_ring(color(crate::look_glow::accent()), 8.0)
            .a11y(
                swiftly_ui::a11y::A11yNode::new("", swiftly_ui::a11y::Role::Tab, name)
                    .with_selected(active),
            )
            .tooltip(tip)
            .key(action)
            .on_tap(Action::from(action))
    };
    let hints = [
        crate::desk::hint("1"),
        crate::desk::hint("2"),
        crate::desk::hint("3"),
        crate::desk::hint("F"),
    ];
    let tips = ["Start", "Filme", "Serien", "Suche"];
    let top: Vec<Node> = (0..TABS.len())
        .map(|i| {
            let (asset, outlined) = tab_icon(i, i == p.tab && !p.downloads && !p.settings);
            row(
                i == p.tab && !p.downloads && !p.settings,
                TABS[i],
                asset,
                outlined,
                Some(hints[i].clone()),
                format!("tab:{i}").as_str(),
                tips[i],
            )
        })
        .collect();
    let mut mine = vec![
        text(
            cx,
            "Meins",
            swiftly_design::TextStyle {
                size: 12.0,
                weight: 600,
                tracking: 0.0,
                uppercase: false,
            },
            color::TEXT_TERTIARY,
            Some(1),
            swiftly_text::Align::Start,
        )
        .padding(ins(20.0, 20.0, 4.0, 20.0)),
    ];
    if p.mine.0 {
        mine.push(row(
            p.tab == 4 && !p.downloads && !p.settings,
            "Merkliste",
            WATCHLIST_ICON,
            false,
            None,
            "go:watchlist",
            "Merkliste",
        ));
    }
    if p.mine.1 {
        // Tab icon A: outline idle, filled while selected.
        mine.push(row(
            p.downloads,
            "Downloads",
            if p.downloads {
                "tab-downloads.fill"
            } else {
                "tab-downloads"
            },
            !p.downloads,
            None,
            "go:downloads",
            "Downloads",
        ));
    }
    if !(p.mine.0 || p.mine.1) {
        // Neither section exists: no heading either.
        mine.clear();
    }
    let footer = {
        // Avatar circle 28, name 13/600, server 11 very quiet, gear 16 at the right; row 48 with 10 around.
        // The demo app shows its sample account; the real app shows the signed-in one, and nothing while signing in.
        let (name, server) = match &p.card {
            crate::desk::Card::Demo => ("Swiftly".to_owned(), Some(home_data::SERVER.to_owned())),
            crate::desk::Card::Account { name, server, .. } => {
                (name.clone(), Some(server.clone()).filter(|s| !s.is_empty()))
            }
            crate::desk::Card::Hidden => ("Konto".to_owned(), None),
        };
        let letter = || {
            text(
                cx,
                &p.card.initial(),
                swiftly_design::TextStyle {
                    size: 13.0,
                    weight: 600,
                    tracking: 0.0,
                    uppercase: false,
                },
                color::SURFACE_BASE,
                Some(1),
                swiftly_text::Align::Center,
            )
        };
        // The signed-in user's picture (`userImageURL()`), the initial only while there is none.
        let face = crate::hub::avatar_node(hub, p.card.picture(), 28.0, letter)
            .frame(Some(28.0), Some(28.0), Alignment::CENTER)
            .background(
                Node::rect(color(crate::look_glow::accent()), 14.0),
                Alignment::CENTER,
            );
        let mut lines = vec![text(
            cx,
            &name,
            swiftly_design::TextStyle {
                size: 13.0,
                weight: 600,
                tracking: 0.0,
                uppercase: false,
            },
            color::TEXT_PRIMARY,
            Some(1),
            swiftly_text::Align::Start,
        )];
        if let Some(server) = &server {
            lines.push(text(
                cx,
                server,
                swiftly_design::TextStyle {
                    size: 11.0,
                    weight: 400,
                    tracking: 0.0,
                    uppercase: false,
                },
                color::TEXT_TERTIARY,
                Some(1),
                swiftly_text::Align::Start,
            ));
        }
        let who = Node::vstack(Align::Start, Some(0.0), lines).layout_priority(1.0);
        let content = Node::hstack(
            Align::Center,
            Some(10.0),
            vec![
                face,
                who,
                Node::spacer(),
                icons.node("gear", 16.0, false, color(color::TEXT_TERTIARY)),
            ],
        )
        .padding(EdgeInsets::symmetric(10.0, 0.0))
        .frame(None, Some(48.0), Alignment::LEADING);
        let mut selected =
            fill_frame(content, Alignment::LEADING).frame(None, Some(48.0), Alignment::LEADING);
        if p.settings {
            selected = selected.background(
                Node::rect(rgba(crate::look_glow::accent(), 0.12), 8.0),
                Alignment::CENTER,
            );
        }
        selected
            .hover_surface(hot, swiftly_ui::feel::SIDEBAR_HOVER_RADIUS)
            .press_style(swiftly_ui::PressStyle::Row)
            .focusable(focus_id("profile"), None)
            .focus_ring(color(crate::look_glow::accent()), 8.0)
            .a11y(
                swiftly_ui::a11y::A11yNode::new("", swiftly_ui::a11y::Role::Button, "Konto")
                    .with_selected(p.settings),
            )
            .tooltip("Einstellungen")
            .key("profile")
            .on_tap(Action::from("profile"))
            .padding(ins(0.0, 10.0, 10.0, 10.0))
    };
    let column = Node::vstack(
        Align::Start,
        Some(2.0),
        vec![
            // No wordmark: the first row starts `SPACE_SIDEBAR_TOP` from the sidebar's top edge, right under the
            // window buttons area (the traffic lights on the Mac, the top edge on Windows and Linux).
            Node::vstack(Align::Start, Some(2.0), top).padding(ins(
                dsk::SPACE_SIDEBAR_TOP,
                10.0,
                0.0,
                10.0,
            )),
            Node::vstack(Align::Start, Some(2.0), mine).padding(ins(0.0, 10.0, 0.0, 10.0)),
            Node::spacer(),
            offer_row(cx, p.offer.as_ref(), icons),
            footer,
        ],
    );
    let hairline =
        Node::rect(color(color::BORDER_HAIRLINE), 0.0).frame(Some(1.0), None, Alignment::TRAILING);
    fill_frame(column, Alignment::TOP_LEADING)
        .frame(Some(dsk::SIZE_SIDEBAR_WIDTH), None, Alignment::TOP_LEADING)
        .flex_frame(FlexFrame {
            max_h: Some(f32::INFINITY),
            align: Some(Alignment::TOP_LEADING),
            ..FlexFrame::default()
        })
        // The Mac's `Theme.groupsArea`: `surface.group`, one step below the controls (it was `surface.control`, lighter
        // than the Mac's sidebar).
        .background(
            Node::rect(color(color::SURFACE_GROUP), 0.0),
            Alignment::CENTER,
        )
        .overlay(
            fill_frame(hairline, Alignment::TRAILING),
            Alignment::TRAILING,
        )
}

/// The offer row above the account card (`OfferingRow`): a capsule 40 high in accent at 18 % over `reason`, the icon, the
/// title (13 medium) with what runs under it (12, very quiet), and from two entries a counter capsule in accent. It
/// sits `BADGE_EDGE` from the sidebar's edges; a click reports `go:offer`. Empty when nothing is on offer.
fn offer_row(cx: &Cx, offer: Option<&crate::desk::Offer>, icons: &Icons) -> Node {
    let Some(o) = offer else {
        return Node::fixed(0.0, 0.0);
    };
    let st = |size: f32, weight: u16| swiftly_design::TextStyle {
        size,
        weight,
        tracking: 0.0,
        uppercase: false,
    };
    let accent = color(crate::look_glow::accent());
    let mut cells = vec![
        icons
            .node(&o.symbol, 17.0, true, accent)
            .frame(Some(20.0), None, Alignment::CENTER)
            .padding(EdgeInsets {
                top: 0.0,
                leading: 0.0,
                bottom: 0.0,
                trailing: 10.0,
            }),
        Node::vstack(
            Align::Start,
            Some(1.0),
            vec![
                text(
                    cx,
                    &o.title,
                    // `Theme.tileTitleText`: 13 medium (semibold made "Hier weiterschauen" 2 pt too wide for the row).
                    st(13.0, 500),
                    crate::look_glow::accent(),
                    Some(1),
                    swiftly_text::Align::Start,
                )
                .key("offer-title"),
                text(
                    cx,
                    &o.under,
                    st(12.0, 400),
                    color::TEXT_TERTIARY,
                    Some(1),
                    swiftly_text::Align::Start,
                )
                .key("offer-under"),
            ],
        )
        .layout_priority(1.0),
        // No minimum: the default 8 pt of a spacer was taken off the title's room before it was asked (the title was cut
        // to "Hier..." with room to spare).
        Node::spacer_min(0.0),
    ];
    if o.count > 1 {
        cells.push(
            text(
                cx,
                &o.count.to_string(),
                st(10.0, 600),
                color::SURFACE_BASE,
                Some(1),
                swiftly_text::Align::Center,
            )
            .padding(EdgeInsets::symmetric(6.0, 0.0))
            .frame(None, Some(20.0), Alignment::CENTER)
            .flex_frame(FlexFrame {
                min_w: Some(20.0),
                align: Some(Alignment::CENTER),
                ..FlexFrame::default()
            })
            .background(Node::rect(accent, 10.0), Alignment::CENTER)
            .padding(EdgeInsets {
                top: 0.0,
                leading: 10.0,
                bottom: 0.0,
                trailing: 0.0,
            }),
        );
    }
    let trailing = if o.count > 1 { 10.0 } else { 14.0 };
    let capsule = Node::hstack(Align::Center, Some(0.0), cells)
        .padding(EdgeInsets {
            top: 0.0,
            leading: 14.0,
            bottom: 0.0,
            trailing,
        })
        .frame(None, Some(desktop::BADGE_HEIGHT), Alignment::LEADING)
        .background(
            Node::rect(color(color::SURFACE_BASE), 999.0),
            Alignment::CENTER,
        )
        .background(
            Node::rect(rgba(crate::look_glow::accent(), 0.18), 999.0),
            Alignment::CENTER,
        );
    let label = if o.count > 1 {
        o.title.clone()
    } else {
        format!("{}, {}", o.title, o.under)
    };
    capsule
        .hover_surface(
            Color::new(1.0, 1.0, 1.0, swiftly_ui::feel::HOVER_SURFACE_ALPHA),
            999.0,
        )
        .press_style(swiftly_ui::PressStyle::Button)
        .a11y(swiftly_ui::a11y::A11yNode::new(
            "",
            swiftly_ui::a11y::Role::Button,
            &label,
        ))
        .key("go:offer")
        .on_tap(Action::from("go:offer"))
        .padding(ins(
            0.0,
            desktop::BADGE_EDGE,
            desktop::BADGE_EDGE,
            desktop::BADGE_EDGE,
        ))
}

/// One tab of the tv bar (`TabStyle`): 30 semibold, 28 side padding, 68 high; resting `fontQuiet`, open `font` with a 4 high
/// accent line (left/right 28, bottom 2), focused a white capsule with `reason` text.
fn tv_tab(cx: &Cx, i: usize, name: &str, selected: bool) -> Node {
    let rest = if selected {
        color::TEXT_PRIMARY
    } else {
        color::TEXT_SECONDARY
    };
    let mut label = Node::text(
        cx,
        name,
        &TextStyle::from(tv::text::BUTTON),
        color(rest),
        Some(1),
        swiftly_text::Align::Center,
    );
    label.paint = label
        .paint
        .into_iter()
        .map(|p| match p {
            Paint::Text {
                text,
                style,
                lines,
                align,
                ..
            } => Paint::FocusText {
                text,
                style,
                rest: color(rest),
                focused: color(color::SURFACE_BASE),
                lines,
                align,
            },
            other => other,
        })
        .collect();
    let mut n = label
        .padding(EdgeInsets::symmetric(tv::TAB_PADDING, 0.0))
        .frame(None, Some(tv::TAB_HEIGHT), Alignment::CENTER)
        .background(
            Node::rect(Color::new(1.0, 1.0, 1.0, 0.0), 999.0).paint(Paint::FocusFill {
                color: Color::WHITE,
                radius: 999.0,
            }),
            Alignment::CENTER,
        );
    if selected {
        let line = Node::rect(color(crate::look_glow::accent()), 999.0)
            .frame(None, Some(4.0), Alignment::BOTTOM)
            .padding(ins(0.0, tv::TAB_PADDING, 2.0, tv::TAB_PADDING));
        n = n.overlay(fill_frame(line, Alignment::BOTTOM), Alignment::BOTTOM);
    }
    let key = format!("tab:{i}");
    let mut n = n
        .key(key.as_str())
        .on_tap(Action::from(key.as_str()))
        .focusable(focus_id(key.as_str()), Some(FocusLook::tile(999.0)));
    if selected {
        n = n.default_focus();
    }
    n
}

/// The tv `HeaderBar`: 80 side edge, 60 from the top, 68 high; the tabs 8 apart, the profile circle (60) on the right.
/// Not drawn: the wordmark, the supporter heart, the takeover badge.
pub(crate) fn header_bar(cx: &Cx, p: &Bar, initial: &str) -> Node {
    let mut tabs: Vec<Node> = TABS
        .iter()
        .enumerate()
        .map(|(i, name)| tv_tab(cx, i, name, i == p.tab))
        .collect();
    tabs.push(Node::spacer());
    let face = text(
        cx,
        initial,
        tv::text::BUTTON,
        color::TEXT_PRIMARY,
        Some(1),
        swiftly_text::Align::Center,
    )
    .frame(Some(60.0), Some(60.0), Alignment::CENTER)
    .background(
        Node::rect(color(color::SURFACE_CONTROL), 30.0),
        Alignment::CENTER,
    )
    .key("profile")
    .on_tap(Action::from("profile"))
    .focusable(
        focus_id("profile"),
        Some(FocusLook::tile(30.0).scaled(tuning::FOCUS_SCALE_SMALL)),
    );
    tabs.push(face);
    Node::hstack(Align::Center, Some(8.0), tabs)
        .padding(ins(60.0, TV_EDGE, 0.0, TV_EDGE))
        .frame(None, Some(60.0 + tv::TAB_HEIGHT), Alignment::TOP_LEADING)
}

/// The activity spinner of a pull to refresh (`UIRefreshControl`): 12 spokes, `pulled` of them shown while the finger
/// pulls, all of them with a bright head that turns while a reload runs.
fn spinner(icons: &Icons, p: &Parts) -> Node {
    let size = 20.0;
    let mut spokes = Vec::new();
    for k in 0..SPOKES {
        let alpha = match p.spin {
            Some(head) => {
                let behind = (usize::from(head) + SPOKES - k) % SPOKES;
                1.0 - behind as f32 / SPOKES as f32 * 0.85
            }
            None if k < usize::from(p.pulled) => 0.85,
            None => continue,
        };
        spokes.push(icons.spoke(k, size, rgba(color::TEXT_SECONDARY, alpha)));
    }
    // Always a node of the same shape, so the tree (and the scroll state under it) does not change when it comes and goes.
    Node::zstack(Alignment::CENTER, spokes).frame(Some(size), Some(size), Alignment::CENTER)
}

// ---- tv hero -------------------------------------------------------------------------------------------------------

/// The tvOS `heroZone`: the focused title's backdrop on the trailing side fading into the ground, and its name,
/// second line and the time left at the leading edge (`HeaderInfo`). Not drawn: the description (not in `HomeVm`
/// tiles), the 250 ms image switch delay and the radial `HeaderShadow` spot.
fn hero(cx: &Cx, m: &Metrics, ctx: &Ctx, tile: Option<&Tile>) -> Node {
    let ground = color::SURFACE_BASE;
    let clear = rgba(ground, 0.0);
    let backdrop_w = 1280.0;
    let hub = ctx.hub.borrow().clone();
    let image = if let Some(hub) = hub {
        // Without a picture the backdrop is empty (the page ground), not demo art.
        let img = tile.and_then(|t| t.image.as_ref());
        remote_node(
            hub.slot(img, backdrop_w, tv::HERO_HEIGHT, Priority::Visible),
            backdrop_w,
            tv::HERO_HEIGHT,
            0.0,
            || Node::fixed(backdrop_w, tv::HERO_HEIGHT),
        )
    } else {
        match tile.and_then(|t| ctx.art.pick(true, &t.id)) {
            Some(id) => Node::image(id, backdrop_w, tv::HERO_HEIGHT, 0.0),
            None => Node::fixed(backdrop_w, tv::HERO_HEIGHT),
        }
    };
    let side = Node::rect(clear, 0.0)
        .paint(Paint::Linear {
            gradient: LinearGradient {
                start: color(ground),
                end: clear,
                from: [0.0, 0.5],
                to: [0.45, 0.5],
            },
            radius: 0.0,
        })
        .frame(Some(backdrop_w), Some(tv::HERO_HEIGHT), Alignment::CENTER);
    let foot = Node::rect(clear, 0.0)
        .paint(Paint::Linear {
            gradient: LinearGradient {
                start: clear,
                end: color(ground),
                from: [0.5, 0.55],
                to: [0.5, 1.0],
            },
            radius: 0.0,
        })
        .frame(Some(backdrop_w), Some(tv::HERO_HEIGHT), Alignment::CENTER);
    let backdrop = image
        .overlay(side, Alignment::TOP_LEADING)
        .overlay(foot, Alignment::TOP_LEADING);
    let mut info = Vec::new();
    if let Some(t) = tile {
        info.push(text(
            cx,
            &t.title,
            tv::text::PLAYER_TITLE,
            color::TEXT_PRIMARY,
            Some(1),
            swiftly_text::Align::Start,
        ));
        if t.facts.kind.as_deref() == Some("Episode") {
            info.push(
                text(
                    cx,
                    &t.facts.name,
                    swiftly_design::TextStyle {
                        size: 30.0,
                        weight: 600,
                        ..tv::text::BODY
                    },
                    color::TEXT_SECONDARY,
                    Some(1),
                    swiftly_text::Align::Start,
                )
                .padding(ins(8.0, 0.0, 0.0, 0.0)),
            );
        }
        if let Some(line) = t.remaining.as_ref().or(t.subtitle.as_ref()) {
            info.push(
                text(
                    cx,
                    line,
                    tv::text::BODY,
                    color::TEXT_SECONDARY,
                    Some(1),
                    swiftly_text::Align::Start,
                )
                .padding(ins(tv::DETAILS_PADDING, 0.0, 0.0, 0.0)),
            );
        }
    }
    let info = Node::vstack(Align::Start, Some(0.0), info)
        .frame(Some(900.0), None, Alignment::TOP_LEADING)
        .padding(ins(tv::CONTENT_TOP, m.edge, 0.0, 0.0));
    let right = Node::hstack(Align::Start, Some(0.0), vec![Node::spacer(), backdrop]).frame(
        None,
        Some(tv::HERO_HEIGHT),
        Alignment::TOP_LEADING,
    );
    fill_frame(right, Alignment::TOP_LEADING)
        .frame(None, Some(tv::HERO_HEIGHT), Alignment::TOP_LEADING)
        .overlay(info, Alignment::TOP_LEADING)
}

// ---- the page ------------------------------------------------------------------------------------------------------

fn content(cx: &Cx, env: &Env, form: Form, pad: bool, p: &Parts, ctx: &Ctx) -> Node {
    let m = metrics(form, pad);
    let heading = |s: &str| {
        text(
            cx,
            s,
            dsk::TEXT_TITLE_LARGE,
            color::TEXT_PRIMARY,
            Some(1),
            swiftly_text::Align::Start,
        )
        .padding(ins(0.0, m.edge, 0.0, m.edge))
    };
    if p.tab != 0 {
        // The other places are not built in this screen: only their heading.
        let column = Node::vstack(
            Align::Start,
            Some(0.0),
            vec![heading(TABS[p.tab.min(TABS.len() - 1)])],
        )
        .padding(ins(dsk::SPACE_CONTENT_TOP, 0.0, 0.0, 0.0));
        return fill_frame(column, Alignment::TOP_LEADING);
    }
    let has_rails = !p.rails.rails.is_empty();
    let top = match form {
        Form::Touch => env.safe.top + 58.0 + 8.0,
        Form::Desktop => dsk::SPACE_CONTENT_TOP,
        Form::Tv => 0.0,
    };
    let bottom = match form {
        Form::Touch if pad => 24.0,
        Form::Touch => touch::STRIP_HEIGHT + env.safe.bottom + 12.0,
        Form::Desktop => 40.0,
        Form::Tv => 48.0,
    };
    // Mac: a 30 pt "Start" heading, 22 pt above the first rail.
    let with_heading = |rails: Vec<Node>| -> Node {
        let stack = Node::vstack(Align::Start, Some(m.rails_spacing), rails);
        if form == Form::Desktop {
            if p.chips.is_empty() {
                Node::vstack(Align::Start, Some(22.0), vec![heading("Start"), stack])
            } else {
                // Mac: 22 under the heading, the chips on their 42 frame, then the 40 of the rail spacing.
                Node::vstack(
                    Align::Start,
                    Some(0.0),
                    vec![
                        heading("Start"),
                        chips_row(cx, &m, &ctx.icons, &p.chips, &p.rail_hover)
                            .padding(ins(22.0, 0.0, 0.0, 0.0)),
                        stack.padding(ins(m.rails_spacing, 0.0, 0.0, 0.0)),
                    ],
                )
            }
        } else {
            stack
        }
    };
    if !has_rails {
        return match p.status.status {
            Status::Loading if p.waiting.is_some() => {
                let server = p.card.server_name();
                let (title, body) = p
                    .waiting
                    .unwrap_or(swiftly_vm::LoadFailure::Offline)
                    .copy(&server);
                empty_state_with(
                    cx,
                    &ctx.icons,
                    "hard-drive-x",
                    title,
                    &body,
                    "Moment…",
                    true,
                )
            }
            Status::Loading => {
                let column = with_heading(vec![
                    rails_placeholder(&m, true),
                    rails_placeholder(&m, false),
                ])
                .padding(ins(
                    if form == Form::Tv {
                        tv::CONTENT_TOP + 40.0
                    } else {
                        top
                    },
                    0.0,
                    0.0,
                    0.0,
                ));
                fill_frame(column, Alignment::TOP_LEADING).reveal_as("home.loading")
            }
            Status::Offline => {
                // The words follow the failure and name the account's server (`Trouble.copy(server:)`).
                let server = p.card.server_name();
                let (title, body) = ctx.vm.failure().copy(&server);
                empty_state(
                    cx,
                    &ctx.icons,
                    "hard-drive-x",
                    title,
                    &body,
                    "Erneut versuchen",
                )
            }
            Status::Ready | Status::SignedOut => empty_state(
                cx,
                &ctx.icons,
                "tray",
                "Hier ist noch nichts",
                "Sobald der Server Titel hat, stehen sie hier.",
                "",
            ),
        };
    }
    let mut rails: Vec<Node> = (0..p.rails.rails.len())
        .map(|i| {
            stagger_row(
                rail_node(cx, &m, form, pad, ctx, &p.rails, i, &p.rail_hover),
                i,
                p.stagger,
                p.rails_out,
            )
        })
        .collect();
    // The core's Seerr sections stand in the Home row order like any other row (Settings > Darstellung > Startseite):
    // "Anfrage ist da" (a stack when several arrivals) and "Meine Anfragen". Each is drawn at the index the core names
    // (`HomeVm::seerr_places`); one with nothing to say is not a node at all.
    if let Some(info) = &p.seerr {
        let kit = crate::detail_screen::Kit {
            cx,
            env,
            lk: crate::detail_screen::look(env),
            art: &ctx.seerr_art,
            icons: &ctx.icons,
        };
        let page_w = env.size.w
            - if form == Form::Desktop {
                dsk::SIZE_SIDEBAR_WIDTH
            } else {
                0.0
            };
        let mut put = 0;
        for (section, at) in &p.seerr_places {
            let part = match section {
                swiftly_library::SeerrSection::Arrival => {
                    crate::pages_screen::seerr_views::HomePart::Arrival
                }
                swiftly_library::SeerrSection::Requests => {
                    crate::pages_screen::seerr_views::HomePart::Requests
                }
            };
            if let Some(block) = crate::pages_screen::seerr_views::home_block(
                &kit,
                info,
                page_w,
                part,
                form == Form::Tv,
            ) {
                rails.insert((*at + put).min(rails.len()), block);
                put += 1;
            }
        }
    }
    // A silent server over rows that are already there (the stored page): the rows stay, the server notice stands above
    // them. While a retry runs (`waiting`) the button waits instead of vanishing, so the block keeps its height.
    let notice_busy = p.status.status == Status::Loading && p.waiting.is_some();
    if p.status.status == Status::Offline || notice_busy {
        let failure = p.waiting.unwrap_or_else(|| ctx.vm.failure());
        if let Some(n) = server_notice(cx, &ctx.icons, &p.card.server_name(), failure, notice_busy)
        {
            rails.insert(0, n);
        }
    }
    // At the very end, after the last row; never above the content.
    if let (Some(hours), Form::Desktop) = (p.support, form) {
        rails.push(support_card(cx, hours).reveal_as("home.support"));
    }
    let column = if form == Form::Tv {
        let focused = p.focus.and_then(|f| {
            p.rails.rails.iter().find_map(|r| {
                r.tiles
                    .iter()
                    .enumerate()
                    .find(|(i, _)| focus_id(tile_key(&r.id, *i).as_str()).0 == f)
                    .map(|(_, t)| t)
            })
        });
        let first = p.rails.rails.first().and_then(|r| r.tiles.first());
        let stack = Node::vstack(Align::Start, Some(m.rails_spacing), rails)
            .padding(ins(0.0, 0.0, bottom, 0.0));
        Node::vstack(
            Align::Start,
            Some(0.0),
            vec![hero(cx, &m, ctx, focused.or(first)), stack],
        )
    } else {
        with_heading(rails).padding(ins(top, 0.0, bottom, 0.0))
    };
    fill_frame(
        Node::scroll(Axis::Vertical, None, column).key("home-scroll"),
        Alignment::TOP_LEADING,
    )
    .reveal_as("home.content")
}

/// Row `index` of the rails around an account switch (`RailsEntrance`, `AccountTransition.swift:311-315`). Every row
/// stays one node whatever the state, so its rails keep their scroll position. At rest it is the plain row. `out` (the
/// tap on an account): the row leaves at once and unstaggered, 14 pt low, at 0.96 about its top edge and transparent, on
/// the catalogue's `AccountRowsOut` (easeOut 0.12). A new `epoch` (the account changed) gives the row a new identity: it
/// comes in 14 pt low and at 0.96, rising on the `AccountRows` spring and fading in with `AccountRailsFade` (linear
/// 0.22), each row 0.08 s after the one above (the curves are the catalogue's with the lag as their delay). Appear and
/// exit differ per direction of the declared state, so the engine's one motion per node is enough. Under Reduce Motion
/// the engine keeps only a short fade. `epoch` 0 and not `out`: the plain row.
fn stagger_row(row: Node, index: usize, epoch: u32, out: bool) -> Node {
    use swiftly_accounts::AccountSwitchCurve;
    use swiftly_motion::catalogue::Id;
    let lag = index as f64 * AccountSwitchCurve::RAILS_SEASON;
    let curve = |id: Id| swiftly_ui::feel::of_delayed(id, lag);
    let (rise, mass) = (
        AccountSwitchCurve::RAILS_OFFSET as f32,
        AccountSwitchCurve::RAILS_MASS as f32,
    );
    let leave = swiftly_ui::feel::of(Id::AccountRowsOut);
    let (dy, scale, alpha) = if out {
        (rise, mass, 0.0)
    } else {
        (0.0, 1.0, 1.0)
    };
    let (rise_motion, fade_motion) = if out {
        (leave, leave)
    } else {
        (curve(Id::AccountRows), curve(Id::AccountRailsFade))
    };
    let mut moved = row
        .offset(0.0, dy, rise_motion)
        .scaled(scale, rise_motion)
        .scale_about(0.5, 0.0);
    if epoch > 0 {
        moved = moved.appear_offset(0.0, rise).appear_from(mass, 1.0);
    }
    let mut outer = Node::vstack(
        Align::Start,
        Some(0.0),
        vec![moved.key(format!("rail.stagger.{epoch}.{index}.move").as_str())],
    )
    .opacity(alpha, fade_motion);
    if epoch > 0 {
        outer = outer.appear_from(1.0, 0.0);
    }
    outer.key(format!("rail.stagger.{epoch}.{index}").as_str())
}

fn view(p: &Parts, env: &Env, cx: &Cx, ctx: &Ctx) -> Node {
    ctx.hub.begin_build();
    let form = Form::of(env.idiom);
    let pad = env.idiom == Idiom::Pad;
    let body = content(cx, env, form, pad, p, ctx);
    let page = match form {
        Form::Touch => fill_frame(body, Alignment::TOP_LEADING)
            .overlay(header(cx, env, &p.bar(), "Swiftly"), Alignment::TOP)
            .overlay(
                spinner(&ctx.icons, p).padding(ins(env.safe.top + 44.0, 0.0, 0.0, 0.0)),
                Alignment::TOP,
            )
            .overlay(tab_bar(cx, env, &p.bar(), &ctx.icons), Alignment::BOTTOM),
        Form::Desktop => {
            // The window's top strip fades in over the content with the scroll, like the Swift toolbar zone.
            let strip = state_bar(cx, "Start", p.header);
            let content_side = crate::look_glow::behind(
                fill_frame(body, Alignment::TOP_LEADING).overlay(strip, Alignment::TOP),
                p.glow,
                env.size.w - dsk::SIZE_SIDEBAR_WIDTH,
            );
            Node::hstack(
                Align::Start,
                Some(0.0),
                vec![sidebar(cx, &p.bar(), &ctx.icons, &ctx.hub), content_side],
            )
        }
        Form::Tv => fill_frame(body, Alignment::TOP_LEADING)
            .overlay(header_bar(cx, &p.bar(), "P"), Alignment::TOP),
    };
    let m = crate::browse::metrics(env);
    let mcx = |id: &str| {
        let cw =
            p.rails.rails.iter().any(|r| {
                r.kind == RailKind::ContinueWatching && r.tiles.iter().any(|t| t.id == id)
            });
        crate::tile_menu::rail_cx(cw, false)
    };
    let overlay = match &p.sheet {
        Sheet::None => None,
        Sheet::Menu(menu) => Some(crate::browse::sheet(
            cx,
            &ctx.icons,
            &m,
            menu.tile.as_ref().map_or("", |t| t.title.as_str()),
            &crate::tile_menu::rows_of(&menu.entries, &menu.cx, menu.tile.as_ref()),
            "pick.m.",
            false,
        )),
        Sheet::Devices(id) => Some(crate::browse::sheet(
            cx,
            &ctx.icons,
            &m,
            "Abspielen auf \u{2026}",
            &crate::tile_menu::device_rows(&mcx(id)),
            "pick.d.",
            false,
        )),
        Sheet::Load(_) => Some(crate::load_panel::load_sheet(cx, &ctx.icons, env, &p.load)),
    };
    let page = fill_frame(page, Alignment::TOP_LEADING).background(
        Node::rect(color(color::SURFACE_BASE), 0.0),
        Alignment::CENTER,
    );
    let page = match p.menu.overlay(cx, env) {
        Some(m) => page.overlay(m, Alignment::TOP_LEADING),
        None => page,
    };
    match overlay {
        Some(o) => page.overlay(o, Alignment::BOTTOM),
        None => page,
    }
}

/// The genre a `genre:<name>` tap names, if the name is one of the chips.
fn a_genre(a: &Action, chips: &[String]) -> Option<String> {
    chips
        .iter()
        .find(|g| *a == Action::from(format!("genre:{g}").as_str()))
        .cloned()
}

/// The longest frames keep coming for a removal's answer (ms): the transport gives up after 20 s for the whole call
/// (15 s without data), so the answer or its error lands before. Only a core that never answers runs into this.
const ANSWER_WAIT_MS: f64 = 30_000.0;

/// How long frames keep coming after the answer landed (ms): the page's refresh that follows a "yes" starts a moment
/// later and shows what the server now says.
const ANSWER_SETTLE_MS: f64 = 1_000.0;

/// The Home screen: a UI over a `HomeVm`.
pub struct HomeScreen {
    ui: Ui<Parts>,
    hub: HubSlot,
    vm: HomeVm<AppTransport>,
    asked: HashSet<String>,
    opened: Vec<String>,
    resumed: Vec<String>,
    /// Tiles the pointer rested on for 150 ms (the Mac's `TileWrapper` prefetch hint), in order.
    rested: Vec<String>,
    refreshes: u32,
    /// "Erneut versuchen" was pressed and the answer is not in yet: the words of the failure it was pressed on.
    retrying: Option<swiftly_vm::LoadFailure>,
    /// Since when the page has been `Loading` with nothing to show.
    loading_from: Option<f64>,
    tab: usize,
    now: f64,
    pulling: bool,
    sheet: Sheet,
    load: crate::load_panel::LoadSpec,
    requests: Vec<String>,
    menu: crate::desk::TileMenu,
    /// The open tile menu is the one of a Continue Watching tile.
    menu_cw: bool,
    /// The rail the pointer is over (desktop paging arrows).
    hovered_rail: Option<String>,
    /// The genre chips shown above the rails.
    chips: Vec<String>,
    /// Account switches whose rails stagger in (see `Parts::stagger`).
    stagger: u32,
    /// The old account's rows are leaving (see `Parts::rails_out`).
    rails_out: bool,
    /// Genres whose chip was tapped, oldest first.
    genres: Vec<String>,
    /// Library rows whose heading link was tapped (their ids), oldest first.
    libraries: Vec<String>,
    /// A New-movies (false) or New-series (true) heading link was tapped; the suite hands the order to that library.
    jumped: Option<bool>,
    /// The support card shown (hours watched) and the taps on its buttons, oldest first.
    support: Option<i64>,
    support_taps: Vec<SupportTap>,
    /// The newest hint of the core that was shown (`NoticePart::seq`), so one hint shows once.
    notice_seen: u64,
    /// The core answers a removal off the UI thread and raises a hint when the server refuses it, which nothing else
    /// would draw, and the loop sleeps between inputs: frames keep coming from the first frame that saw a removal
    /// waiting for its answer (this time, ms) until the answer landed and a frame showed it.
    answer_since: Option<f64>,
    /// Frames keep coming until then (ms): a moment after the answer landed.
    answer_due: f64,
    /// The core's Seerr screens behind the block above the rails; none without a Seerr session.
    desk: Option<crate::seerr_desk::Desk>,
    /// The count of Seerr answers the last drawn parts held.
    seerr_seen: u64,
    /// When the page started to wait for the first Seerr answer of a profile that remembers nothing (ms, `self.now`).
    seerr_wait_from: Option<f64>,
    /// The Seerr title that was tapped on the "Angefragt" rail, once.
    seerr_tapped: Option<swiftly_seerr::models::SeerrHit>,
    /// "Wartet auf dich" was tapped, once (the suite opens the administrator page).
    admin_tapped: bool,
}

impl HomeScreen {
    /// What a screen reader gets for this screen: the nodes of the current picture.
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.ui.a11y_nodes()
    }

    /// A home screen for `env` over a scripted server in `scenario`.
    pub fn new(env: Env, cx: Cx, scenario: Scenario) -> HomeScreen {
        Self::over(env, cx, home_data::home_vm(scenario))
    }

    /// A home screen for `env` over a view model that is already built (tests hand in one over a server of their own).
    pub fn over(env: Env, cx: Cx, vm: HomeVm<AppTransport>) -> HomeScreen {
        let art = Rc::new(Art {
            posters: art::posters(&cx),
            landscapes: art::heroes(&cx),
        });
        let hub: HubSlot = Rc::new(RefCell::new(None));
        let mut seerr_art = crate::detail_screen::Art::new(&cx);
        seerr_art.hub = Rc::clone(&hub);
        let ctx = Ctx {
            hub: Rc::clone(&hub),
            art,
            seerr_art,
            icons: Icons::new(&cx, env.scale),
            vm: vm.clone(),
        };
        let parts = Parts {
            downloads: false,
            settings: false,
            card: crate::desk::Card::Demo,
            offer: None,
            mine: (true, true),
            glow: (crate::look_glow::Glow::default(), 0),
            status: vm.status(),
            waiting: None,
            rails: vm.rails(),
            tab: 0,
            header: 0,
            pulled: 0,
            spin: None,
            focus: None,
            sheet: Sheet::None,
            load: crate::load_panel::LoadSpec::demo(""),
            pictures: 0,
            menu: crate::desk::TileMenu::default(),
            rail_hover: None,
            chips: Vec::new(),
            stagger: 0,
            rails_out: false,
            support: None,
            seerr: None,
            seerr_places: Vec::new(),
        };
        let ui = Ui::new(
            move |p: &Parts, env: &Env, cx: &Cx| view(p, env, cx, &ctx),
            parts,
            env,
            cx,
        );
        let mut s = HomeScreen {
            ui,
            hub,
            vm,
            asked: HashSet::new(),
            opened: Vec::new(),
            resumed: Vec::new(),
            rested: Vec::new(),
            refreshes: 0,
            retrying: None,
            loading_from: None,
            tab: 0,
            now: 0.0,
            pulling: false,
            sheet: Sheet::None,
            load: crate::load_panel::LoadSpec::demo(""),
            requests: Vec::new(),
            menu: crate::desk::TileMenu::default(),
            menu_cw: false,
            hovered_rail: None,
            chips: Vec::new(),
            stagger: 0,
            rails_out: false,
            genres: Vec::new(),
            libraries: Vec::new(),
            jumped: None,
            support: None,
            support_taps: Vec::new(),
            notice_seen: 0,
            answer_since: None,
            answer_due: 0.0,
            desk: None,
            seerr_seen: 0,
            seerr_wait_from: None,
            seerr_tapped: None,
            admin_tapped: false,
        };
        s.sync();
        s
    }

    /// The view model (tests send intents through it).
    pub fn vm(&self) -> &HomeVm<AppTransport> {
        &self.vm
    }

    /// Titles tapped so far (server ids).
    pub fn opened(&self) -> &[String] {
        &self.opened
    }

    /// The Continue-rail tiles tapped since the last call: the app plays them at once.
    pub fn take_resumed(&mut self) -> Vec<String> {
        std::mem::take(&mut self.resumed)
    }

    /// The tiles the pointer rested on since the last call: the title pages behind them are fetched ahead.
    pub fn take_rested(&mut self) -> Vec<String> {
        std::mem::take(&mut self.rested)
    }

    /// How many reloads the user started (pull to refresh, retry).
    pub fn refreshes(&self) -> u32 {
        self.refreshes
    }

    /// The tab in front (0 = Start).
    pub fn tab(&self) -> usize {
        self.tab
    }

    /// Puts the bar back on a tab (the app switched pages and this page stays behind).
    pub fn set_tab(&mut self, tab: usize) {
        self.tab = tab;
    }

    /// A hint the core raised by itself (a removal the server refused) shows once in the strip at the bottom of the
    /// content, like the other screens' hints, and is dismissed in the core.
    fn show_notice(&mut self) {
        let notice = self.vm.notice();
        if let Some(text) = &notice.message
            && notice.seq != self.notice_seen
        {
            self.notice_seen = notice.seq;
            crate::desk::post_hint(text.clone());
            self.vm.send(HomeIntent::DismissNotice);
        }
    }

    /// A hint of the core that no frame has shown yet.
    fn notice_waiting(&self) -> bool {
        let notice = self.vm.notice();
        notice.message.is_some() && notice.seq != self.notice_seen
    }

    /// The core still owes the answer of a removal (and has not owed it for longer than any transport waits).
    fn answer_awaited(&self) -> bool {
        self.vm.removal_pending()
            && self
                .answer_since
                .is_none_or(|since| self.now < since + ANSWER_WAIT_MS)
    }

    /// Called at the end of a frame: notes when the wait for a removal's answer began and when it ended.
    fn note_answer(&mut self) {
        let pending = self.vm.removal_pending();
        match (pending, self.answer_since) {
            (true, None) => self.answer_since = Some(self.now),
            (false, Some(_)) => {
                self.answer_since = None;
                self.answer_due = self.now + ANSWER_SETTLE_MS;
            }
            _ => {}
        }
    }

    fn sync(&mut self) {
        self.hub.frame(self.now);
        self.show_notice();
        let rails = self.vm.rails();
        // A rail that is on screen gets its tile data in full (the Swift `onAppear` of a row).
        for r in &rails.rails {
            if r.tiles.len() < r.count as usize && self.asked.insert(r.id.clone()) {
                self.vm.send(HomeIntent::Visible { rail: r.id.clone() });
            }
        }
        let status = self.vm.status();
        let offset = self.page_offset() as f32;
        let header = if self.ui.env().idiom == Idiom::Desktop {
            bar_strength(offset, BAR_SINCE, 26.0)
        } else {
            ((offset / 30.0).clamp(0.0, 1.0) * 8.0).round() as u8
        };
        let pulled = if self.pulling && offset < 0.0 {
            ((-offset / PULL_TO_REFRESH).clamp(0.0, 1.0) * SPOKES as f32).round() as u8
        } else {
            0
        };
        let spin = (status.refreshing
            || status.status == Status::Loading && !self.vm.rails().rails.is_empty())
        .then(|| ((self.now / (1000.0 / SPOKES as f64)) as u64 % SPOKES as u64) as u8);
        let rail_hover = self.rail_hover_state();
        if let Some(d) = &self.desk {
            d.follow_switches();
            self.seerr_seen = d.changed();
        }
        let mut seerr = self.desk.as_ref().map(|d| d.lists().home());
        // The page is complete when it shows (the core's gate): a profile that remembers nothing waits for the first
        // Seerr answer up to the core's budget, with the loading placeholders; after it the page shows with the
        // reserve of the first guess.
        let mut holding = false;
        if let (Some(info), Some(d)) = (&seerr, &self.desk)
            && info.holds_page
        {
            let from = *self.seerr_wait_from.get_or_insert(self.now);
            if self.now - from >= swiftly_vm::HOME_BUDGET_SECONDS * 1000.0 {
                seerr = Some(d.lists().home_budget_over());
            } else {
                holding = true;
            }
        } else {
            self.seerr_wait_from = None;
        }
        let seerr = seerr.filter(|i| i.state != swiftly_vm::SeerrHomeState::Hidden);
        let rails_have_genre = rails.rails.iter().any(|r| r.is_genre());
        let (status, rails) = if holding {
            (
                Arc::new(StatusPart {
                    status: Status::Loading,
                    preview: false,
                    refreshing: false,
                    version: status.version,
                }),
                Arc::new(RailsPart {
                    version: rails.version,
                    rails: Vec::new(),
                }),
            )
        } else {
            (status, rails)
        };
        if status.status != Status::Loading {
            self.retrying = None;
        }
        self.ui.set_parts(Parts {
            downloads: crate::desk::downloads_front(),
            settings: crate::desk::settings_front(),
            card: crate::desk::card(),
            offer: crate::desk::offer(),
            mine: crate::desk::mine(),
            glow: crate::look_glow::bar_state(offset as f64),
            // Over stored rows a retry in flight also counts (the server notice's button waits).
            waiting: waiting_trouble(
                status.status,
                !rails.rails.is_empty(),
                holding,
                self.retrying,
                &mut self.loading_from,
                self.now,
            )
            .or_else(|| {
                (status.status == Status::Loading && !rails.rails.is_empty())
                    .then_some(self.retrying)
                    .flatten()
            }),
            status,
            rails,
            tab: self.tab,
            header,
            pulled,
            spin,
            focus: self.ui.focused().map(|f| f.0),
            sheet: self.sheet.clone(),
            load: self.load.clone(),
            pictures: self.hub.stamp(),
            menu: self.menu.clone(),
            rail_hover,
            chips: if rails_have_genre {
                Vec::new()
            } else {
                self.chips.clone()
            },
            stagger: self.stagger,
            rails_out: self.rails_out,
            support: self.support,
            seerr_places: if seerr.is_some() {
                self.vm.seerr_places(match Form::of(self.ui.env().idiom) {
                    Form::Tv => swiftly_library::HomeForm::Tv,
                    Form::Desktop => swiftly_library::HomeForm::Desktop,
                    Form::Touch => swiftly_library::HomeForm::Handheld,
                })
            } else {
                Vec::new()
            },
            seerr,
        });
    }

    /// Connects the Seerr block (the iPhone's `SeerrHomeFlow`): it reads at once and again whenever Start comes back.
    pub fn set_seerr(&mut self, desk: crate::seerr_desk::Desk) {
        desk.load_home();
        self.desk = Some(desk);
        self.sync();
    }

    /// Whether the Seerr block is connected.
    pub fn has_seerr(&self) -> bool {
        self.desk.is_some()
    }

    /// Seerr was disconnected: the block goes.
    pub fn clear_seerr(&mut self) {
        if self.desk.take().is_some() {
            self.sync();
        }
    }

    /// Reads the Seerr block again (Start came to the front, pull to refresh, a list change).
    pub fn reload_seerr(&self) {
        if let Some(d) = &self.desk {
            d.load_home();
        }
    }

    /// The Seerr title that was tapped on the "Angefragt" rail, once (the suite opens its page).
    pub fn take_seerr(&mut self) -> Option<swiftly_seerr::models::SeerrHit> {
        self.seerr_tapped.take()
    }

    /// "Wartet auf dich" was tapped, once (the suite opens "Verwaltung").
    pub fn take_admin_open(&mut self) -> bool {
        std::mem::take(&mut self.admin_tapped)
    }

    /// A tap on the Seerr block; `true` when it was one of its controls.
    fn seerr_tap(&mut self, a: &Action) -> bool {
        let Some(d) = self.desk.clone() else {
            return false;
        };
        let Some(tap) = SeerrTap::of(&d.lists().home(), &|k| *a == Action::from(k)) else {
            return false;
        };
        match tap {
            SeerrTap::Dismiss(id) => {
                d.dismiss_arrival(id);
                self.sync();
            }
            SeerrTap::Expand => {
                d.set_arrivals_expanded(true);
                self.sync();
            }
            SeerrTap::Collapse => {
                d.set_arrivals_expanded(false);
                self.sync();
            }
            SeerrTap::Play(item) => self.resumed.push(item),
            SeerrTap::Open(item) => self.opened.push(item),
            SeerrTap::Attention => self.admin_tapped = true,
            SeerrTap::Title(hit) => self.seerr_tapped = Some(hit),
        }
        true
    }

    /// Shows or hides the support card (`SupportModel.cardVisible`): the hours watched when it is due.
    pub fn set_support(&mut self, hours: Option<i64>) {
        if self.support != hours {
            self.support = hours;
            self.sync();
        }
    }

    /// The window-point frame of the control `key` (tests).
    #[doc(hidden)]
    pub fn frame_of(&self, key: &str) -> Option<[f32; 4]> {
        self.ui.frame_of(key)
    }

    /// The tooltip the pointer's rest has earned at `now` (tests).
    #[doc(hidden)]
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

    /// Whether Start has its rails (the page the "Was ist neu" sheet waits for).
    pub fn loaded(&self) -> bool {
        !self.vm.rails().rails.is_empty()
    }

    /// Whether the support card is shown.
    pub fn support_shown(&self) -> bool {
        self.support.is_some()
    }

    /// The oldest tap on a button of the support card, once.
    pub fn take_support_tap(&mut self) -> Option<SupportTap> {
        (!self.support_taps.is_empty()).then(|| self.support_taps.remove(0))
    }

    fn reload(&mut self) {
        self.refreshes += 1;
        self.vm.send(HomeIntent::Load);
        self.reload_seerr();
    }

    /// The tile of a title in any row, also one beyond the row's prepared window (the row draws those from the view
    /// model, so a menu on them must find them there too).
    pub fn tile_of(&self, id: &str) -> Option<Tile> {
        let rails = self.vm.rails();
        rails
            .rails
            .iter()
            .flat_map(|r| r.tiles.iter())
            .find(|t| t.id == id)
            .cloned()
            .or_else(|| {
                rails.rails.iter().find_map(|r| {
                    let at = r.ids.iter().position(|x| x == id)?;
                    self.vm.tiles(&r.id, at, 1).into_iter().next()
                })
            })
    }

    /// The tile a menu action names: `menu:<id>` on a tile of any row, `cmenu:<id>` on one of the Continue Watching
    /// row, and whether it sits in that row. Tiles beyond the row's prepared window count too.
    fn tile_of_action(&self, a: &Action) -> Option<(Tile, bool)> {
        let rails = self.vm.rails();
        for r in &rails.rails {
            let cw = r.kind == RailKind::ContinueWatching;
            let key = |id: &str| {
                Action::from(format!("{}:{id}", if cw { "cmenu" } else { "menu" }).as_str())
            };
            if let Some(t) = r.tiles.iter().find(|t| *a == key(&t.id)) {
                return Some((t.clone(), cw));
            }
            if let Some(at) = r.ids.iter().position(|id| *a == key(id))
                && let Some(t) = self.vm.tiles(&r.id, at, 1).into_iter().next()
            {
                return Some((t, cw));
            }
        }
        None
    }

    /// Opens the touch sheet of title `id`: its entries are computed here, once (see [`MenuSheet`]).
    fn open_sheet(&mut self, id: &str, cw: bool) {
        let tile = self.tile_of(id);
        let favourite = tile
            .as_ref()
            .is_some_and(|t| t.badges.contains(&swiftly_vm::Badge::Favorite));
        let cx = crate::tile_menu::rail_cx(cw, favourite);
        let form = Form::of(self.ui.env().idiom);
        let entries = crate::tile_menu::entries(form, &cx, tile.as_ref());
        self.sheet = Sheet::Menu(Box::new(MenuSheet {
            id: id.to_owned(),
            cw,
            tile,
            cx,
            entries,
        }));
    }

    /// Carries out one entry of a tile menu (the touch sheet or the right-click popover) for title `id`.
    fn run_entry(
        &mut self,
        e: crate::tile_menu::Entry,
        id: &str,
        cw: bool,
        tile: Option<&Tile>,
        favourite: bool,
    ) {
        use crate::tile_menu::Entry;
        match e {
            Entry::Play if cw => self.resumed.push(id.to_owned()),
            Entry::Play | Entry::FromStart | Entry::Info | Entry::Overview | Entry::ToSeries => {
                self.opened.push(id.to_owned())
            }
            // Signed in: the suite reads the live title and opens the add sheet; the demo shows its panel.
            Entry::Load if crate::live::current().is_some() => {
                crate::desk::request_download(id);
            }
            Entry::Load => {
                self.load =
                    crate::load_panel::LoadSpec::demo(tile.map_or("", |t| t.title.as_str()));
                self.sheet = Sheet::Load(id.to_owned());
            }
            Entry::PlayOn => self.sheet = Sheet::Devices(id.to_owned()),
            // The host carries these out (`TileRequest`, played back in the app). "Remember" says which way it was
            // labelled, so the write is what the row promised.
            Entry::Remember => {
                let flag = if favourite { "off" } else { "on" };
                self.requests.push(format!("Remember:{id}:{flag}"));
            }
            Entry::Watched | Entry::Unwatched | Entry::Together => {
                self.requests.push(format!("{e:?}:{id}"));
            }
            // The suite reads the title's place and opens the report sheet over the page.
            Entry::Report => crate::desk::request_report(id, None),
            Entry::Delete => crate::desk::request_delete(id, false),
            // The core takes the title out of the row at once and tells the server in the background.
            Entry::Remove => {
                self.vm.send(HomeIntent::RemoveFromContinue {
                    item_id: id.to_owned(),
                });
            }
        }
    }

    /// The press on a row of the open tile menu, devices list or download sheet.
    fn sheet_tap(&mut self, is: &dyn Fn(&str) -> bool) {
        match self.sheet.clone() {
            Sheet::None => {}
            Sheet::Menu(menu) => {
                if is("sheet.close") {
                    self.sheet = Sheet::None;
                }
                for (i, e) in menu.entries.iter().enumerate() {
                    if !is(&format!("pick.m.{i}")) {
                        continue;
                    }
                    self.sheet = Sheet::None;
                    self.run_entry(
                        e.clone(),
                        &menu.id,
                        menu.cw,
                        menu.tile.as_ref(),
                        menu.cx.favourite,
                    );
                }
            }
            Sheet::Devices(id) => {
                if is("sheet.close") {
                    self.sheet = Sheet::None;
                }
                let targets = crate::tile_menu::rail_cx(false, false).host.play_on;
                for (i, (device, _)) in targets.iter().enumerate() {
                    if is(&format!("pick.d.{i}")) {
                        self.requests.push(format!("PlayOn:{id}:{device}"));
                        self.sheet = Sheet::None;
                    }
                }
            }
            Sheet::Load(_) => {
                if [
                    "load.go",
                    "load.queue",
                    "load.cell",
                    "load.clean",
                    "load.close",
                    "sheet.close",
                ]
                .iter()
                .any(|k| is(k))
                {
                    self.sheet = Sheet::None;
                }
            }
        }
    }

    /// The paging state of the rail the pointer is over: what the arrows may do (left past 4 pt, right before the end
    /// less 4 pt; none when everything fits).
    fn rail_hover_state(&mut self) -> Option<(String, bool, bool)> {
        let id = self.hovered_rail.clone()?;
        let (offset, max, _) = self.ui.scroll_of(format!("rail-row:{id}").as_str())?;
        Some((id, offset > 4.0, offset < max - 4.0))
    }

    /// The pointer moved over the window (no button held): hover, cursor, tooltips, rail arrows.
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

    /// A right click: opens the menu of the tile under the pointer as a popover at the pointer.
    pub fn secondary_click(&mut self, x: f32, y: f32, now: f64) -> bool {
        if self.menu.is_open() {
            self.menu.close();
        }
        let hit = self.ui.secondary_click(x, y, now);
        self.drain();
        hit
    }

    /// The account changed: the rows of this account's rails come in one after the other (14 pt rise, fade, 0.08 s per
    /// row; see `stagger_row`). Call it when the new account's Home is built.
    pub fn begin_rail_stagger(&mut self) {
        self.stagger += 1;
        self.rails_out = false;
    }

    /// The tap on an account: the rows of the old account leave at once, unstaggered (`AccountRowsOut`, easeOut 0.12;
    /// see `stagger_row`). `begin_rail_stagger` brings the new account's rows in; `end_rail_out` brings these back
    /// when the account does not change after all.
    pub fn begin_rail_out(&mut self) {
        self.rails_out = true;
    }

    /// The switch did not happen: the rows of the account that stays come back.
    pub fn end_rail_out(&mut self) {
        self.rails_out = false;
    }

    /// Sets the genre chips (the "genre chips" setting of the Start page).
    pub fn set_chips(&mut self, chips: Vec<String>) {
        self.chips = chips;
    }

    /// The library rows whose "Alle" link was tapped since the last call.
    /// The library the last "Alle \u{203a}" of a new-additions row opened: `Some(true)` series, `Some(false)` movies.
    pub fn take_jump(&mut self) -> Option<bool> {
        self.jumped.take()
    }

    /// The library rows whose "Alle" link was tapped since the last call.
    pub fn take_libraries(&mut self) -> Vec<String> {
        std::mem::take(&mut self.libraries)
    }

    /// The genres whose chip was tapped since the last call.
    pub fn take_genres(&mut self) -> Vec<String> {
        std::mem::take(&mut self.genres)
    }

    /// Whether the right-click menu is open.
    pub fn menu_open(&self) -> bool {
        self.menu.is_open()
    }

    /// A key for the open menu (arrows, Return, Esc). False when none is open.
    pub fn menu_key(&mut self, key: swiftly_ui::popover::MenuKey, now: f64) -> bool {
        if !self.menu.is_open() {
            return false;
        }
        if let Some(pick) = self.menu.key(key, now) {
            self.picked(pick);
        }
        true
    }

    /// The shortcut of `entry` (Ctrl+D, Ctrl+Shift+G, Ctrl+I) while the right-click menu is open. False when it did nothing.
    pub fn menu_shortcut(&mut self, entry: &crate::tile_menu::Entry) -> bool {
        match self.menu.pick_entry(entry) {
            Some(pick) => {
                self.picked(pick);
                true
            }
            None => false,
        }
    }

    fn picked(&mut self, pick: crate::desk::Pick) {
        if let crate::desk::Pick::Row(id, i) = pick {
            // The entry the popover showed on that row (its list was computed when it opened), not a new list.
            if let Some(e) = self.menu.entry(i).cloned() {
                let tile = self.tile_of(&id);
                self.run_entry(e, &id, self.menu_cw, tile.as_ref(), self.menu.favourite());
            }
        }
    }

    fn drain(&mut self) {
        for ev in self.ui.take_events() {
            match &ev {
                UiEvent::Secondary { action, x, y } => {
                    if let Some((t, cw)) = self.tile_of_action(action)
                        && crate::tile_menu::carries(Some(&t))
                    {
                        self.menu_cw = cw;
                        let favourite = t.badges.contains(&swiftly_vm::Badge::Favorite);
                        self.menu.open(
                            &t,
                            &crate::tile_menu::rail_cx(cw, favourite),
                            swiftly_layout::Point::new(*x, *y),
                            false,
                        );
                    }
                    continue;
                }
                UiEvent::HoverChanged { action, entered } => {
                    if *action == Action::from(format!("rail:{CHIPS_RAIL}").as_str()) {
                        if *entered {
                            self.hovered_rail = Some(CHIPS_RAIL.to_owned());
                        } else if self.hovered_rail.as_deref() == Some(CHIPS_RAIL) {
                            self.hovered_rail = None;
                        }
                    }
                    for r in &self.vm.rails().rails {
                        if *action == Action::from(format!("rail:{}", r.id).as_str()) {
                            if *entered {
                                self.hovered_rail = Some(r.id.clone());
                            } else if self.hovered_rail.as_deref() == Some(r.id.as_str()) {
                                self.hovered_rail = None;
                            }
                        }
                    }
                    continue;
                }
                UiEvent::Tap(a) if self.seerr_tap(a) => continue,
                UiEvent::Tap(a) if self.menu.is_open() => {
                    if let Some(pick) = self.menu.tap(a) {
                        self.picked(pick);
                    }
                    continue;
                }
                UiEvent::Tap(a) if *a == Action::from("support:open") => {
                    self.support_taps.push(SupportTap::Open);
                    continue;
                }
                UiEvent::Tap(a) if *a == Action::from("support:snooze") => {
                    self.support_taps.push(SupportTap::Snooze);
                    continue;
                }
                UiEvent::Tap(a) => {
                    let now = self.now;
                    let mut page = None;
                    for dir in [-1.0_f64, 1.0] {
                        let key =
                            format!("page.{}:{CHIPS_RAIL}", if dir < 0.0 { 'l' } else { 'r' });
                        if *a == Action::from(key.as_str()) {
                            self.ui.scroll_key_by(
                                format!("rail-row:{CHIPS_RAIL}").as_str(),
                                dir * f64::from(CHIPS_STEP),
                                now,
                            );
                        }
                    }
                    for r in &self.vm.rails().rails {
                        if *a == Action::from(format!("page.l:{}", r.id).as_str()) {
                            page = Some((r.id.clone(), -1.0));
                        } else if *a == Action::from(format!("page.r:{}", r.id).as_str()) {
                            page = Some((r.id.clone(), 1.0));
                        } else if *a == Action::from(format!("all:{}", r.id).as_str()) {
                            // The heading link: the library of that kind, sorted by "Zuletzt" (the Mac's library jump).
                            if r.is_library() {
                                self.libraries
                                    .push(r.id.trim_start_matches("library:").to_owned());
                            } else {
                                // `AppModel.openLibrary(jump)`: the suite hands the row's order to that library.
                                let series = r.kind == RailKind::NewSeries;
                                self.jumped = Some(series);
                                self.tab = if series { 2 } else { 1 };
                            }
                        }
                    }
                    if let Some(g) = a_genre(a, &self.chips) {
                        self.genres.push(g);
                        continue;
                    }
                    if let Some((id, dir)) = page {
                        // Three tiles per click (3 x (tile + 16)), `reveal` 0.28 s.
                        let m = metrics(Form::of(self.ui.env().idiom), false);
                        let landscape = self
                            .vm
                            .rails()
                            .rails
                            .iter()
                            .find(|r| r.id == id)
                            .and_then(|r| r.tiles.first())
                            .and_then(|t| t.image.as_ref())
                            .is_some_and(|i| i.kind == ImageKind::Backdrop);
                        let w = if landscape { m.landscape.w } else { m.poster.w };
                        self.ui.scroll_key_by(
                            format!("rail-row:{id}").as_str(),
                            dir * 3.0 * f64::from(w + m.tile_spacing),
                            now,
                        );
                        continue;
                    }
                }
                _ => {}
            }
            if let UiEvent::HoverRest(a) = &ev
                && let Some(t) = self
                    .vm
                    .rails()
                    .rails
                    .iter()
                    .flat_map(|r| r.tiles.iter())
                    .find(|t| *a == Action::from(format!("rest:{}", t.id).as_str()))
            {
                // The Mac's `TileWrapper`: after 150 ms of rest the title behind the tile is fetched ahead.
                self.rested.push(t.id.clone());
            }
            if let UiEvent::LongPress(a) = &ev
                && let Some((t, cw)) = self.tile_of_action(a)
                && crate::tile_menu::carries(Some(&t))
            {
                self.menu_cw = cw;
                self.open_sheet(&t.id, cw);
            }
            if let UiEvent::Tap(action) = ev {
                crate::forms::note_tap(&action);
                if self.sheet != Sheet::None {
                    self.sheet_tap(&|s| action == Action::from(s));
                    continue;
                }
                if action == Action::from(RETRY) {
                    self.retrying = Some(self.vm.failure());
                    self.reload();
                }
                for i in 0..=TABS.len() {
                    if action == Action::from(format!("tab:{i}").as_str()) {
                        self.tab = i.min(TABS.len() - 1);
                    }
                }
                for r in &self.vm.rails().rails {
                    for t in &r.tiles {
                        // The Mac's Continue rail resumes at once; the detail page is the info/menu path only. Every
                        // other row opens the page, whatever else its title is in.
                        if r.kind == RailKind::ContinueWatching {
                            if action == Action::from(format!("resume:{}", t.id).as_str()) {
                                self.resumed.push(t.id.clone());
                            }
                        } else if action == Action::from(format!("tile:{}", t.id).as_str()) {
                            self.opened.push(t.id.clone());
                        }
                    }
                }
            }
        }
    }

    /// Whether a tile menu or the download sheet is open.
    pub fn sheet_open(&self) -> bool {
        self.sheet != Sheet::None || self.menu.is_open()
    }

    /// Opens the menu of a tile (tests, long press on the host).
    pub fn show_menu(&mut self, id: &str) {
        let cw =
            self.vm.rails().rails.iter().any(|r| {
                r.kind == RailKind::ContinueWatching && r.tiles.iter().any(|t| t.id == id)
            });
        self.open_sheet(id, cw);
    }

    /// The menu entries the host has to carry out (`"Watched:<id>"` ...), oldest first.
    pub fn take_requests(&mut self) -> Vec<String> {
        std::mem::take(&mut self.requests)
    }

    /// Every scroll offset in tree order: the page first, then the rows (tests, measuring).
    pub fn scroll_offsets(&self) -> Vec<f64> {
        self.ui.scroll_offsets()
    }

    /// The page offset: negative while the finger pulls the page down past its top.
    pub fn page_offset(&self) -> f64 {
        self.ui.scroll_offsets().first().copied().unwrap_or(0.0)
    }

    /// A new window size or scale.
    pub fn set_env(&mut self, env: Env) {
        self.ui.set_env(env);
    }

    /// Arrow, Tab, Enter or Esc on the focus engine.
    pub fn nav_key(
        &mut self,
        key: swiftly_ui::NavKey,
        down: bool,
        now: f64,
    ) -> swiftly_ui::Outcome {
        if self.menu.is_open() {
            if down {
                use swiftly_ui::popover::MenuKey as K;
                let k = match key {
                    swiftly_ui::NavKey::Arrow(swiftly_ui::Dir::Up) => Some(K::Up),
                    swiftly_ui::NavKey::Arrow(swiftly_ui::Dir::Down) => Some(K::Down),
                    swiftly_ui::NavKey::Enter => Some(K::Enter),
                    swiftly_ui::NavKey::Escape => Some(K::Escape),
                    _ => None,
                };
                if let Some(k) = k {
                    self.menu_key(k, now);
                }
            }
            return swiftly_ui::Outcome::None;
        }
        let out = self.ui.nav_key(key, down, now);
        self.drain();
        out
    }

    /// A finger goes down.
    pub fn touch_down(&mut self, x: f32, y: f32, now: f64) {
        self.pulling = true;
        self.ui.touch_down(x, y, now);
        self.drain();
    }

    /// The finger moves.
    pub fn touch_move(&mut self, x: f32, y: f32, now: f64) {
        self.ui.touch_move(x, y, now);
        self.drain();
    }

    /// The finger lifts. On touch, a page pulled past [`PULL_TO_REFRESH`] starts a reload.
    pub fn touch_up(&mut self, x: f32, y: f32, now: f64) {
        let pulled = -self.page_offset() as f32 >= PULL_TO_REFRESH;
        self.pulling = false;
        self.ui.touch_up(x, y, now);
        if pulled && Form::of(self.ui.env().idiom) == Form::Touch {
            self.reload();
        }
        self.drain();
    }

    /// The touch is cancelled.
    pub fn touch_cancel(&mut self, now: f64) {
        self.pulling = false;
        self.ui.touch_cancel(now);
        self.drain();
    }

    /// One frame at `now` ms: the vm's newest parts, then the UI. Returns the quads and whether another is wanted.
    pub fn frame(&mut self, now: f64) -> (DrawList, bool) {
        self.now = now;
        self.sync();
        let mut list = self.ui.frame(now);
        self.hub.finish(&mut list);
        self.drain();
        self.note_answer();
        let wants = self.wants_frame();
        (list, wants)
    }

    /// An animation, a glide, a held touch or the spinner needs another frame, and so does the answer of a removal
    /// that is still on its way (or has landed but no frame showed it yet).
    pub fn wants_frame(&self) -> bool {
        self.ui.needs_frame()
            || self.vm.status().refreshing
            || self.hub.busy()
            || self.answer_awaited()
            || self.notice_waiting()
            || self.now < self.answer_due
            || self
                .desk
                .as_ref()
                .is_some_and(|d| d.busy() || d.changed() != self.seerr_seen)
    }

    /// The owner the picture hub knows this screen by (see `ImageHub::set_hidden`).
    pub(crate) fn hub_owner(&self) -> crate::hub::HubOwner {
        Rc::downgrade(&self.hub)
    }

    /// The services (atlas pages) the renderers read.
    pub fn with_images(self, hub: Rc<ImageHub>) -> Self {
        self.hub.attach(hub);
        self
    }

    /// Waits for every picture of the tiles on screen and applies it (headless goldens).
    pub fn settle_images(&mut self, now: f64) {
        self.hub.settle(now);
    }

    /// The services (atlas pages) the renderers read.
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
}

#[cfg(test)]
mod backdrop_tests {
    use super::*;

    /// The glow over a mid-grey picture at the Linux 4K scale of 1.5: every row must be the ramp's value at that row
    /// (within the noise of the dither), with no dark seam line where two bands meet inside a device pixel.
    #[test]
    fn the_glow_has_no_seam_lines_at_a_fractional_scale() {
        use swiftly_layout::Size;
        let env = Env::new(Size::new(300.0, BACKDROP_HEIGHT), 1.5, Idiom::Desktop);
        let ground = Color::rgb(0.6, 0.6, 0.6);
        let mut ui = Ui::new(
            move |_: &(), _: &Env, _: &Cx| {
                header_backdrop(1.0).background(Node::rect(ground, 0.0), Alignment::TOP)
            },
            (),
            env,
            Cx::deterministic(),
        );
        let list = ui.frame(0.0);
        let img = ui.render(&list, Color::BLACK);
        let rows = (BACKDROP_HEIGHT * 1.5) as usize;
        let stops = backdrop_stops();
        let alpha_at = |t: f32| {
            let i = stops
                .windows(2)
                .position(|w| t >= w[0].0 && t <= w[1].0)
                .unwrap_or(stops.len() - 2);
            let (a, b) = (stops[i], stops[i + 1]);
            a.1 + (b.1 - a.1) * (t - a.0) / (b.0 - a.0)
        };
        let reason = color::SURFACE_BASE.r;
        let mut worst = 0.0_f32;
        for y in 0..rows {
            let a = alpha_at((y as f32 + 0.5) / rows as f32);
            let expect = (0.6 * (1.0 - a) + reason * a) * 255.0;
            let got = f32::from(img.pixel(150, y)[0]);
            worst = worst.max((got - expect).abs());
        }
        assert!(
            worst <= 3.0,
            "a row is {worst} levels off the ramp (seam lines)"
        );
    }

    #[test]
    fn the_glow_ramp_is_smooth_and_keeps_the_mac_end_points() {
        let s = backdrop_stops();
        assert_eq!(s.len(), BACKDROP_PIECES + 1);
        assert!((s[0].1 - 0.97).abs() < 1e-4 && s.last().unwrap().1 == 0.0);
        // Never rises, never leaves 0..1.
        assert!(s.windows(2).all(|w| w[1].1 <= w[0].1 + 1e-6));
        // It passes every Mac sample point closely (the curve is the Mac's, only smoother).
        for (x, y) in BACKDROP_CURVE {
            let k = (x * BACKDROP_PIECES as f32).round() as usize;
            let near = (s[k].0 - x).abs() < 0.02 && (s[k].1 - y).abs() < 0.03;
            assert!(near, "sample ({x}, {y}) vs ({}, {})", s[k].0, s[k].1);
        }
        // Between the sample points it stays close to the Mac's straight pieces (at most 0.04 alpha, 10 of 255 levels).
        let lin = |x: f32| {
            let i = (0..BACKDROP_CURVE.len() - 1)
                .rev()
                .find(|&i| x >= BACKDROP_CURVE[i].0)
                .unwrap_or(0);
            let (a, b) = (BACKDROP_CURVE[i], BACKDROP_CURVE[i + 1]);
            a.1 + (b.1 - a.1) * (x - a.0) / (b.0 - a.0)
        };
        let dev = s
            .iter()
            .map(|(x, y)| (y - lin(*x)).abs())
            .fold(0.0_f32, f32::max);
        assert!(dev < 0.04, "deviation {dev}");
        // No corner: the slope changes by little between neighbouring pieces (the old ten-piece ramp jumped by 0.5 per
        // 1.0 of height at its corners; here the worst jump is under a third of that).
        let slope: Vec<f32> = s
            .windows(2)
            .map(|w| (w[1].1 - w[0].1) / (w[1].0 - w[0].0))
            .collect();
        let worst = slope
            .windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0_f32, f32::max);
        assert!(worst < 0.17, "slope jump {worst}");
        // The old ramp, for the record, was not smooth.
        let old: Vec<f32> = BACKDROP_CURVE
            .windows(2)
            .map(|w| (w[1].1 - w[0].1) / (w[1].0 - w[0].0))
            .collect();
        let old_worst = old
            .windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0_f32, f32::max);
        assert!(
            old_worst > 0.45 && worst < old_worst / 2.0,
            "{old_worst} vs {worst}"
        );
    }
}

#[cfg(test)]
mod progress_bar_tests {
    use super::*;

    const RED: Color = Color::rgb(1.0, 0.0, 0.0);

    fn render(
        w: f32,
        h: f32,
        corner: f32,
        share: Option<f32>,
        scale: f32,
    ) -> swiftly_render::RgbaImage {
        let env = Env::new(Size::new(w, h), scale, Idiom::Desktop);
        let mut ui = Ui::new(
            move |_: &(), _: &Env, _: &Cx| {
                let tile = Node::rect(RED, corner).frame(Some(w), Some(h), Alignment::CENTER);
                let tile = match share {
                    Some(s) => tile.overlay(progress_bar(w, corner, s), Alignment::BOTTOM_LEADING),
                    None => tile,
                };
                fill_frame(tile, Alignment::TOP_LEADING)
            },
            (),
            env,
            Cx::deterministic(),
        );
        let list = ui.frame(0.0);
        ui.render(&list, Color::BLACK)
    }

    /// The bar is a strip of the rounded picture: wherever the picture alone is clear (outside its rounded corner), the picture
    /// with the bar must be clear too, and inside the bar must show.
    #[test]
    fn the_bar_never_pokes_past_the_rounded_corners_of_its_tile() {
        for scale in [1.0_f32, 1.5, 2.0] {
            for corner in [10.0_f32, 12.0, 14.0] {
                for share in [0.3_f32, 0.5, 1.0] {
                    let (w, h) = (160.0, 90.0);
                    let bare = render(w, h, corner, None, scale);
                    let with = render(w, h, corner, Some(share), scale);
                    let (pw, ph) = ((w * scale) as usize, (h * scale) as usize);
                    let mut bar_pixels = 0;
                    for y in (ph - (BAR_HEIGHT * scale) as usize - 1)..ph {
                        for x in 0..pw {
                            let (b, t) = (bare.pixel(x, y), with.pixel(x, y));
                            if b[0] < 8 && b[3] > 0 {
                                // Outside the tile (the clear colour): the bar must not draw here. A smoothed corner
                                // leaves pixels the tile covers by 1 to 3 %; the bar covers them by the same share (its
                                // colour is not the tile's), so a difference under 8 levels is the corner's own edge.
                                let leak = (0..4).map(|c| t[c].abs_diff(b[c])).max().unwrap();
                                assert!(
                                    leak < 8,
                                    "bar pixel outside the corner at ({x},{y}), scale {scale}, corner {corner}, share {share}: {t:?} vs {b:?}"
                                );
                            } else if t != b {
                                bar_pixels += 1;
                            }
                        }
                    }
                    assert!(bar_pixels > 0, "the bar draws inside the tile");
                }
            }
        }
        // A bar that is not clipped by the corners would colour the very corner pixel of the tile.
        let with = render(160.0, 90.0, 12.0, Some(1.0), 1.0);
        assert_eq!(
            with.pixel(0, 89),
            [0, 0, 0, 255],
            "the lower left corner stays clear"
        );
        assert_eq!(
            with.pixel(159, 89),
            [0, 0, 0, 255],
            "the lower right corner stays clear"
        );
        assert_ne!(
            with.pixel(80, 89),
            render(160.0, 90.0, 12.0, None, 1.0).pixel(80, 89)
        );
    }

    /// Every tile draws its bar through [`progress_bar`]: a hand-made rectangle (the track colour `1,1,1,0.30`) in a
    /// tile or episode builder has square corners and pokes out of the rounded picture (the cause of the repeated report).
    #[test]
    fn no_tile_builder_draws_its_own_square_bar() {
        let track = concat!("Color::new(1.0, 1.0, 1.0, ", "0.30)");
        for (name, src) in [
            ("browse.rs", include_str!("browse.rs")),
            ("series_screen.rs", include_str!("series_screen.rs")),
            ("detail_screen.rs", include_str!("detail_screen.rs")),
            ("player_screen.rs", include_str!("player_screen.rs")),
        ] {
            assert!(!src.contains(track), "{name} draws its own progress bar");
        }
        let own = include_str!("home.rs").matches(track).count();
        assert_eq!(own, 1, "home.rs draws the track only inside progress_bar");
    }
}

#[cfg(test)]
mod downloads_row_tests {
    use super::*;
    use swiftly_layout::Size;

    fn names(on: bool) -> Vec<String> {
        crate::desk::set_mine(true, on);
        let env = Env::new(Size::new(1280.0, 800.0), 2.0, swiftly_ui::Idiom::Desktop);
        let mut s = HomeScreen::new(
            env,
            Cx::deterministic(),
            crate::home_data::Scenario::Loading,
        );
        let _ = s.frame(100.0);
        let names = s.a11y_nodes().into_iter().map(|n| n.label).collect();
        crate::desk::set_mine(true, true);
        names
    }

    #[test]
    fn the_sidebar_has_a_downloads_row_only_while_downloads_are_on() {
        assert!(names(true).iter().any(|n| n == "Downloads"));
        assert!(!names(false).iter().any(|n| n == "Downloads"));
    }
}

#[cfg(test)]
mod no_demo_art_tests {
    use super::*;
    use swiftly_images::fixture::FixtureImages;
    use swiftly_images::{Device, ImageLoader};

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

    /// Over the real image hub a title without a picture is the tile ground with the symbol of its kind, not a generated
    /// demo poster; without a hub (the demo) the generated art stays.
    #[test]
    fn a_home_tile_without_a_picture_never_draws_demo_art() {
        let cx = Cx::deterministic();
        let art = Art {
            posters: art::posters(&cx),
            landscapes: art::heroes(&cx),
        };
        let demo: Vec<[f32; 4]> = art
            .posters
            .iter()
            .chain(&art.landscapes)
            .map(|i| i.uv)
            .collect();
        let icons = Icons::new(&cx, 2.0);
        let m = metrics(Form::Desktop, false);
        let tile = Tile {
            id: "t1".into(),
            title: "Ohne Bild".into(),
            subtitle: None,
            progress: None,
            image: None,
            badges: Vec::new(),
            remaining: None,
            facts: swiftly_vm::TileFacts::default(),
        };
        let slot: HubSlot = Rc::new(RefCell::new(None));
        let build = |landscape: bool| {
            let n = tile_node(
                &cx,
                &m,
                Form::Desktop,
                &art,
                &slot,
                &icons,
                &tile,
                landscape,
                false,
                "k",
            );
            let mut found = Vec::new();
            uvs(&n, &mut found);
            found
        };
        assert!(
            build(false).iter().any(|u| demo.contains(u)),
            "the demo keeps its art"
        );
        *slot.borrow_mut() = Some(ImageHub::new(
            Box::new(ImageLoader::new(Arc::new(FixtureImages), None, Device::Mac)),
            &cx,
            2.0,
            Device::Mac,
        ));
        for landscape in [false, true] {
            assert!(
                build(landscape).iter().all(|u| !demo.contains(u)),
                "landscape {landscape}: a generated picture is drawn over the hub"
            );
        }
    }
}

#[cfg(test)]
mod sidebar_tooltip_tests {
    use super::*;
    use swiftly_layout::Size;

    /// The Mac hides a help tag once the row is clicked; it must not come back over the next label while the pointer
    /// stays on the (re-built) row.
    #[test]
    fn a_click_on_a_sidebar_row_hides_its_tooltip_for_good() {
        let env = Env::new(Size::new(1280.0, 800.0), 1.0, swiftly_ui::Idiom::Desktop);
        let mut s = HomeScreen::new(env, Cx::deterministic(), crate::home_data::Scenario::Ready);
        let mut now = 0.0;
        for _ in 0..10 {
            now += 16.0;
            let _ = s.frame(now);
        }
        let f = s.frame_of("tab:1").expect("a sidebar row");
        let (x, y) = (f[0] + f[2] / 2.0, f[1] + f[3] / 2.0);
        s.pointer_move(x, y, now);
        now += 900.0;
        let _ = s.frame(now);
        assert!(s.visible_tooltip(now).is_some(), "the rest earns a tooltip");
        s.touch_down(x, y, now);
        s.touch_up(x, y, now + 40.0);
        for _ in 0..80 {
            now += 16.0;
            let _ = s.frame(now);
            s.pointer_move(x, y, now);
        }
        assert!(
            s.visible_tooltip(now + 2000.0).is_none(),
            "the tooltip stays away after the click"
        );
    }
}

#[cfg(test)]
mod notice_tests {
    use super::*;
    use crate::net::HostHttp;
    use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport};

    /// A scripted server that holds the answer of the removal back until the test lets it go.
    struct Gate {
        server: swiftly_net::MockTransport,
        open: std::sync::Mutex<bool>,
        bell: std::sync::Condvar,
    }

    impl Gate {
        fn release(&self) {
            *self.open.lock().unwrap() = true;
            self.bell.notify_all();
        }
    }

    impl HostHttp for Gate {
        fn send(&self, request: HttpRequest) -> Result<HttpResponse, ErrorKind> {
            if request.url.path().ends_with("UserData") {
                let mut open = self.open.lock().unwrap();
                while !*open {
                    open = self.bell.wait(open).unwrap();
                }
            }
            futures_executor::block_on(self.server.send(request))
        }
    }

    fn tile_ids(s: &HomeScreen) -> Vec<String> {
        s.vm()
            .rails()
            .rails
            .iter()
            .filter(|r| r.kind == RailKind::ContinueWatching)
            .flat_map(|r| r.tiles.iter().map(|t| t.id.clone()))
            .collect()
    }

    #[test]
    fn a_refused_removal_shows_the_core_hint_once_and_dismisses_it() {
        // The server refuses the write that takes the title out of Continue Watching.
        let server = home_data::transport(Scenario::Ready)
            .route_error("UserData", ErrorKind::Network { code: -1009 });
        let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
        let mut s = HomeScreen::over(env, Cx::deterministic(), home_data::home_vm_over(server));
        let before = tile_ids(&s);
        let id = before.first().cloned().expect("a continue-watching row");
        let _ = crate::desk::take_hints();
        s.vm().send(HomeIntent::RemoveFromContinue {
            item_id: id.clone(),
        });
        let mut shown = Vec::new();
        let began = std::time::Instant::now();
        while shown.is_empty() && began.elapsed() < std::time::Duration::from_secs(10) {
            let _ = s.frame(0.0);
            shown.extend(crate::desk::take_hints());
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        assert_eq!(shown.len(), 1, "one hint: {shown:?}");
        assert!(shown[0].contains("Entfernen"), "{shown:?}");
        // Dismissed in the core, and not shown a second time by the frames that follow.
        for _ in 0..50 {
            let _ = s.frame(0.0);
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        assert!(s.vm().notice().message.is_none(), "dismissed in the core");
        assert!(crate::desk::take_hints().is_empty(), "shown once");
        assert_eq!(tile_ids(&s), before, "the title is back in its row");
    }

    /// Lets the held answer go and stops the runtime when a test ends (also when it fails): a request that is still
    /// held would keep the runtime from shutting down.
    struct Held {
        gate: Arc<Gate>,
        runtime: Option<tokio::runtime::Runtime>,
    }

    impl Drop for Held {
        fn drop(&mut self) {
            self.gate.release();
            if let Some(runtime) = self.runtime.take() {
                runtime.shutdown_background();
            }
        }
    }

    /// A screen over a server whose answer to the removal waits for `Gate::release`.
    fn held_back(refuse: bool) -> (HomeScreen, Arc<Gate>, Held) {
        let mut server = home_data::transport(Scenario::Ready);
        if refuse {
            server = server.route_error("UserData", ErrorKind::Network { code: -1009 });
        }
        let gate = Arc::new(Gate {
            server,
            open: std::sync::Mutex::new(false),
            bell: std::sync::Condvar::new(),
        });
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .build()
            .expect("runtime");
        let transport = AppTransport::Host(
            Arc::clone(&gate) as Arc<dyn HostHttp>,
            runtime.handle().clone(),
        );
        let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
        let s = HomeScreen::over(
            env,
            Cx::deterministic(),
            home_data::home_vm_through(transport),
        );
        let held = Held {
            gate: Arc::clone(&gate),
            runtime: Some(runtime),
        };
        (s, gate, held)
    }

    /// The loop of the app: a frame whenever one is wanted, nothing while the window sleeps. Returns the time of the
    /// last frame drawn.
    fn run_while_wanted(s: &mut HomeScreen, mut now: f64) -> f64 {
        let mut frames = 0;
        while s.wants_frame() && frames < 5_000 {
            now += 16.0;
            let _ = s.frame(now);
            frames += 1;
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        assert!(frames < 5_000, "the screen never went back to sleep");
        now
    }

    #[test]
    fn frames_keep_coming_for_an_answer_that_arrives_after_the_old_fifteen_seconds() {
        let (mut s, gate, _held) = held_back(true);
        let before = tile_ids(&s);
        let id = before.first().cloned().expect("a continue-watching row");
        let _ = crate::desk::take_hints();
        let _ = s.frame(0.0);
        s.vm().send(HomeIntent::RemoveFromContinue { item_id: id });
        let _ = s.frame(16.0);
        assert!(s.wants_frame(), "the answer is on its way");
        // 25 s later (the transport allows 20) the answer is still outstanding: the loop must not have gone to sleep.
        let _ = s.frame(25_000.0);
        assert!(s.wants_frame(), "still waiting after 25 s");
        assert!(crate::desk::take_hints().is_empty());
        // The refusal lands: the frames that are still wanted show the hint, then the screen sleeps again.
        gate.release();
        let began = std::time::Instant::now();
        while s.wants_frame() && began.elapsed() < std::time::Duration::from_secs(10) {
            let _ = s.frame(25_016.0);
            std::thread::sleep(std::time::Duration::from_millis(2));
            if s.vm().notice().message.is_none() && !s.vm().removal_pending() {
                break;
            }
        }
        let shown = crate::desk::take_hints();
        assert_eq!(shown.len(), 1, "one hint: {shown:?}");
        assert_eq!(tile_ids(&s), before, "the title is back in its row");
        let _ = run_while_wanted(&mut s, 25_016.0);
        assert!(!s.wants_frame(), "idle again");
    }

    #[test]
    fn a_refusal_that_lands_while_no_frame_runs_still_gets_its_frame() {
        let (mut s, gate, _held) = held_back(true);
        let id = tile_ids(&s).first().cloned().expect("a row");
        let _ = crate::desk::take_hints();
        let _ = s.frame(0.0);
        s.vm().send(HomeIntent::RemoveFromContinue { item_id: id });
        let _ = s.frame(16.0);
        gate.release();
        // The answer lands between two frames: the screen says so before the next input has to.
        let began = std::time::Instant::now();
        while s.vm().removal_pending() && began.elapsed() < std::time::Duration::from_secs(10) {
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        assert!(s.wants_frame(), "a hint waits to be drawn");
        let _ = run_while_wanted(&mut s, 16.0);
        assert_eq!(crate::desk::take_hints().len(), 1);
    }

    #[test]
    fn an_accepted_removal_lets_the_screen_sleep_once_the_answer_is_in() {
        let (mut s, gate, _held) = held_back(false);
        let id = tile_ids(&s).first().cloned().expect("a row");
        let _ = crate::desk::take_hints();
        let _ = s.frame(0.0);
        s.vm().send(HomeIntent::RemoveFromContinue { item_id: id });
        let _ = s.frame(16.0);
        assert!(s.wants_frame());
        gate.release();
        let _ = run_while_wanted(&mut s, 16.0);
        assert!(!s.wants_frame());
        assert!(crate::desk::take_hints().is_empty());
    }

    #[test]
    fn a_removal_the_server_accepts_shows_no_hint() {
        let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
        let mut s = HomeScreen::new(env, Cx::deterministic(), Scenario::Ready);
        let id = tile_ids(&s).first().cloned().expect("a row");
        let _ = crate::desk::take_hints();
        s.vm().send(HomeIntent::RemoveFromContinue { item_id: id });
        for _ in 0..100 {
            let _ = s.frame(0.0);
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        assert!(crate::desk::take_hints().is_empty());
    }
}

#[cfg(test)]
mod menu_sheet_tests {
    use super::*;
    use swiftly_layout::Size;
    use swiftly_net::MockTransport;

    /// Thirty films in the new-additions rows (only the first twelve of a row are prepared); `m20` is begun and on the
    /// watchlist, `m5` is plain.
    fn server() -> MockTransport {
        let film = |i: usize| {
            let user = if i == 20 {
                r#""UserData":{"PlaybackPositionTicks":6000000000,"PlayedPercentage":40.0,"Played":false,"IsFavorite":true}"#
            } else {
                r#""UserData":{"Played":false}"#
            };
            format!(
                r#"{{"Id":"m{i}","Name":"Film {i}","Type":"Movie","ProductionYear":2020,"RunTimeTicks":54000000000,"ImageTags":{{"Primary":"p-m{i}"}},{user}}}"#
            )
        };
        let items: Vec<String> = (0..30).map(film).collect();
        let list = format!(r#"{{"Items":[{}],"TotalRecordCount":30}}"#, items.join(","));
        let empty = r#"{"Items":[],"TotalRecordCount":0}"#;
        let views = r#"{"Items":[{"Id":"lib-movies","Name":"Filme","Type":"CollectionFolder","CollectionType":"movies"}],"TotalRecordCount":1}"#;
        MockTransport::new()
            .route("UserViews", 200, views)
            .route("UserItems/Resume", 200, empty)
            .route("Shows/NextUp", 200, empty)
            .route("/Items", 200, &list)
    }

    fn screen() -> (HomeScreen, f64) {
        let env = Env::new(Size::new(1280.0, 1100.0), 1.0, Idiom::Desktop);
        let mut s = HomeScreen::over(env, Cx::deterministic(), home_data::home_vm_over(server()));
        // The rows go back to their first window of twelve tiles, as after an account switch (the core drops the
        // windows; the screen has asked for these rows before and does not ask again).
        s.vm().send(HomeIntent::AccountSwitched {
            account: Some(home_data::account()),
        });
        let began = std::time::Instant::now();
        while !s
            .vm()
            .rails()
            .rails
            .iter()
            .any(|r| r.tiles.len() < r.ids.len())
            && began.elapsed() < std::time::Duration::from_secs(10)
        {
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        for r in s.vm().rails().rails.iter() {
            s.asked.insert(r.id.clone());
        }
        let mut now = 0.0;
        for _ in 0..40 {
            now += 16.0;
            let _ = s.frame(now);
        }
        (s, now)
    }

    /// The title and the labels of the rows on show, in order: the sheet is one node for the screen reader, its label
    /// the title followed by the rows ("Film 20, Fortsetzen, Von vorn, ...").
    fn shown(s: &HomeScreen) -> (String, Vec<String>) {
        let mut flat = Vec::new();
        let nodes = s.ui.a11y_nodes();
        for n in &nodes {
            flat.extend(n.walk());
        }
        let mut rows = 0;
        while s.frame_of(&format!("pick.m.{rows}")).is_some() {
            rows += 1;
        }
        let sheet = flat
            .iter()
            .filter(|n| n.label.split(", ").count() == rows + 1)
            .min_by_key(|n| n.label.len())
            .unwrap_or_else(|| {
                panic!(
                    "no sheet of {rows} rows: {:#?}",
                    flat.iter().map(|n| &n.label).collect::<Vec<_>>()
                )
            });
        let mut parts = sheet.label.split(", ").map(str::to_owned);
        let title = parts.next().unwrap_or_default();
        (title, parts.collect())
    }

    fn tap_row(s: &mut HomeScreen, now: &mut f64, i: usize) {
        let f = s.frame_of(&format!("pick.m.{i}")).expect("a row");
        let (x, y) = (f[0] + f[2] / 2.0, f[1] + f[3] / 2.0);
        s.touch_down(x, y, *now);
        s.touch_up(x, y, *now + 40.0);
        *now += 80.0;
        let _ = s.frame(*now);
    }

    /// Opens the sheet of `id`, taps every row in turn and checks that the action the row names is the one that ran.
    /// Returns the labels of the rows.
    fn every_row_does_what_it_says(s: &mut HomeScreen, now: &mut f64, id: &str) -> Vec<String> {
        s.show_menu(id);
        *now += 16.0;
        let _ = s.frame(*now);
        let (_, labels) = shown(s);
        assert!(!labels.is_empty(), "the sheet of {id} has rows");
        for (i, label) in labels.iter().enumerate() {
            s.show_menu(id);
            *now += 16.0;
            let _ = s.frame(*now);
            let opened = s.opened().len();
            let _ = s.take_requests();
            tap_row(s, now, i);
            let requests = s.take_requests();
            let want = match label.as_str() {
                "Merken" => Some(format!("Remember:{id}:on")),
                "Nicht mehr merken" => Some(format!("Remember:{id}:off")),
                "Als gesehen markieren" => Some(format!("Watched:{id}")),
                "Als ungesehen markieren" => Some(format!("Unwatched:{id}")),
                "Gemeinsam schauen" => Some(format!("Together:{id}")),
                _ => None,
            };
            match want {
                Some(w) => assert_eq!(requests, [w], "the row {i} \"{label}\" of {labels:?}"),
                None => assert!(
                    requests.is_empty(),
                    "the row {i} \"{label}\" of {labels:?} asked for {requests:?}"
                ),
            }
            let opens = matches!(
                label.as_str(),
                "Abspielen" | "Fortsetzen" | "Von vorn" | "Info" | "Zur Übersicht"
            );
            assert_eq!(
                s.opened().len() > opened,
                opens,
                "the row {i} \"{label}\" of {labels:?} opens a page: {opens}"
            );
        }
        labels
    }

    #[test]
    fn a_tile_beyond_the_prepared_window_shows_and_runs_the_same_rows() {
        let (mut s, mut now) = screen();
        let rail = s
            .vm()
            .rails()
            .rails
            .iter()
            .find(|r| r.ids.iter().any(|x| x == "m20"))
            .cloned()
            .expect("a row with the film");
        assert!(
            rail.tiles.len() <= 20 && !rail.tiles.iter().any(|t| t.id == "m20"),
            "m20 is beyond the prepared window ({} tiles; rows {:?})",
            rail.tiles.len(),
            s.vm()
                .rails()
                .rails
                .iter()
                .map(|r| (r.id.clone(), r.count, r.ids.len(), r.tiles.len()))
                .collect::<Vec<_>>()
        );
        s.show_menu("m20");
        let _ = s.frame(now + 16.0);
        let (title, _) = shown(&s);
        assert_eq!(title, "Film 20", "the sheet is titled with the film");
        let labels = every_row_does_what_it_says(&mut s, &mut now, "m20");
        // A begun film on the watchlist: "Von vorn" and "Als ungesehen markieren" are on offer.
        assert!(labels.iter().any(|l| l == "Von vorn"), "{labels:?}");
        assert!(
            labels.iter().any(|l| l == "Als ungesehen markieren"),
            "{labels:?}"
        );
    }

    #[test]
    fn the_remember_row_says_what_it_writes() {
        let (mut s, mut now) = screen();
        // On the watchlist: "Nicht mehr merken" takes the title off (it must not say "Merken" and then remove it).
        let on_list = every_row_does_what_it_says(&mut s, &mut now, "m20");
        assert!(
            on_list.iter().any(|l| l == "Nicht mehr merken"),
            "{on_list:?}"
        );
        assert!(!on_list.iter().any(|l| l == "Merken"), "{on_list:?}");
        // Not on it: "Merken" puts it on.
        let off_list = every_row_does_what_it_says(&mut s, &mut now, "m5");
        assert!(off_list.iter().any(|l| l == "Merken"), "{off_list:?}");
    }
}

#[cfg(test)]
mod seerr_block_tests {
    use super::*;
    use swiftly_vm::{SeerrArrival, SeerrAttention, SeerrHomeInfo, SeerrTileCard};

    fn tile(tmdb: i64, art: &str) -> SeerrTileCard {
        SeerrTileCard {
            announcement: String::new(),
            art: art.into(),
            tmdb,
            title: format!("Titel {tmdb}"),
            year: Some(2024),
            poster: None,
            badge: None,
            media_id: None,
            on_server: false,
        }
    }

    fn info(art: &str) -> SeerrHomeInfo {
        let film = SeerrArrival {
            request_id: 18,
            art: art.into(),
            tmdb: 1001,
            title: "Film".into(),
            poster: None,
            library_id: "lib-1".into(),
            line: "Film ist da".into(),
        };
        SeerrHomeInfo {
            version: 1,
            state: swiftly_vm::SeerrHomeState::Shown,
            shape: swiftly_vm::SeerrHomeShape {
                arrival: true,
                stacked: false,
                deep: false,
                attention: true,
                rail: true,
            },
            memory: "alr".into(),
            holds_page: false,
            show: true,
            arrival: Some(film.clone()),
            arrivals: vec![film],
            arrivals_expanded: false,
            attention: Some(SeerrAttention {
                title: "Wartet auf dich".into(),
                detail: "3 Anfragen".into(),
                count: 3,
            }),
            rail_title: "Angefragt".into(),
            rail: vec![tile(7, "movie"), tile(8, "tv")],
        }
    }

    #[test]
    fn the_reserve_of_a_pending_block_takes_no_tap() {
        let reserve = SeerrHomeInfo::pending("alr");
        assert!(
            reserve.arrival.is_some(),
            "blank parts of the remembered shape"
        );
        assert_eq!(SeerrTap::of(&reserve, &|_| true), None);
    }

    #[test]
    fn the_banner_plays_a_film_and_opens_a_series_page() {
        assert_eq!(
            SeerrTap::of(&info("movie"), &|k| k == "arrival-play:18"),
            Some(SeerrTap::Play("lib-1".into()))
        );
        assert_eq!(
            SeerrTap::of(&info("tv"), &|k| k == "arrival-play:18"),
            Some(SeerrTap::Open("lib-1".into()))
        );
        assert_eq!(
            SeerrTap::of(&info("movie"), &|k| k == "arrival-dismiss:18"),
            Some(SeerrTap::Dismiss(18))
        );
        assert_eq!(
            SeerrTap::of(&info("movie"), &|k| k == "arrival-open:18"),
            Some(SeerrTap::Open("lib-1".into())),
            "a click on the card opens the title"
        );
    }

    /// Three arrivals: the stack opens and closes with the core's state, every card has its own controls.
    #[test]
    fn a_stack_opens_closes_and_every_card_has_its_own_x() {
        let mut i = info("movie");
        let more = |id: i64| SeerrArrival {
            request_id: id,
            library_id: format!("lib-{id}"),
            ..i.arrivals[0].clone()
        };
        i.arrivals = vec![more(18), more(17), more(16)];
        assert_eq!(
            SeerrTap::of(&i, &|k| k == "arrival-expand"),
            Some(SeerrTap::Expand)
        );
        assert_eq!(SeerrTap::of(&i, &|k| k == "arrival-collapse"), None);
        assert_eq!(
            SeerrTap::of(&i, &|k| k == "arrival-dismiss:16"),
            Some(SeerrTap::Dismiss(16))
        );
        i.arrivals_expanded = true;
        assert_eq!(SeerrTap::of(&i, &|k| k == "arrival-expand"), None);
        assert_eq!(
            SeerrTap::of(&i, &|k| k == "arrival-collapse"),
            Some(SeerrTap::Collapse)
        );
        assert_eq!(
            SeerrTap::of(&i, &|k| k == "arrival-open:17"),
            Some(SeerrTap::Open("lib-17".into()))
        );
    }

    #[test]
    fn a_rail_tile_opens_its_seerr_title_and_other_keys_are_not_ours() {
        let Some(SeerrTap::Title(hit)) = SeerrTap::of(&info("movie"), &|k| k == "home-seerr:1")
        else {
            panic!("tile 1 is a title tap");
        };
        assert_eq!((hit.id, hit.art.as_str()), (8, "tv"));
        assert_eq!(SeerrTap::of(&info("movie"), &|k| k == "home-seerr:2"), None);
        assert_eq!(SeerrTap::of(&info("movie"), &|k| k == "tile:abc"), None);
        assert_eq!(
            SeerrTap::of(&info("movie"), &|k| k == "attention"),
            Some(SeerrTap::Attention)
        );
    }

    #[test]
    fn without_a_banner_its_buttons_do_nothing() {
        let mut i = info("movie");
        i.arrival = None;
        i.arrivals.clear();
        assert_eq!(SeerrTap::of(&i, &|k| k == "arrival-play:18"), None);
        assert_eq!(SeerrTap::of(&i, &|k| k == "arrival-dismiss:18"), None);
    }
}

#[cfg(test)]
mod sidebar_icon_fill {
    use super::*;

    fn mac_source() -> Option<String> {
        std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../Sources/macOS/MainView.swift"),
        )
        .ok()
    }

    /// Mac: `.watchlist: "bookmark.fill"` and no tab asset pair for it, so the row is filled idle and selected.
    #[test]
    fn the_watchlist_row_is_filled_like_the_mac_in_both_states() {
        assert!(WATCHLIST_ICON.ends_with(".fill"));
        if let Some(mac) = mac_source() {
            assert!(
                mac.contains(r#"case .watchlist: "bookmark.fill""#),
                "the Mac's Merkliste symbol changed: update WATCHLIST_ICON"
            );
            assert!(
                mac.contains("case .watchlist:  return nil"),
                "the Mac's Merkliste gained a tab asset pair: draw it like the other rows"
            );
        }
    }

    /// Mac `tabAsset(selected:)`: `base` idle, `base.fill` selected, for Start, Filme, Serien and Suche.
    #[test]
    fn the_four_tabs_are_outline_idle_and_filled_selected() {
        for i in 0..TABS.len() {
            let (idle, idle_outlined) = tab_icon(i, false);
            let (on, on_outlined) = tab_icon(i, true);
            assert!(!idle.ends_with(".fill") && idle_outlined, "tab {i} idle");
            assert_eq!(on, format!("{idle}.fill"), "tab {i} selected");
            assert!(!on_outlined, "tab {i} selected");
        }
    }
}

#[cfg(test)]
mod waiting_tests {
    use super::*;
    use swiftly_vm::LoadFailure;

    /// A cold start that gets no answer says so after `SILENT_AFTER_MS`, not before; a page with data, or one that is
    /// not loading, never does, and its stopwatch starts over.
    #[test]
    fn a_silent_cold_start_says_so_after_the_patience() {
        let mut from = None;
        let ask = |status, rails, holding, retry, from: &mut Option<f64>, now| {
            waiting_trouble(status, rails, holding, retry, from, now)
        };
        assert_eq!(
            ask(Status::Loading, false, false, None, &mut from, 100.0),
            None
        );
        assert_eq!(
            ask(Status::Loading, false, false, None, &mut from, 5099.0),
            None
        );
        assert_eq!(
            ask(Status::Loading, false, false, None, &mut from, 5100.0),
            Some(LoadFailure::Offline)
        );
        // Data arrived: no trouble, and the stopwatch is gone.
        assert_eq!(
            ask(Status::Loading, true, false, None, &mut from, 5200.0),
            None
        );
        assert_eq!(from, None);
        // The Seerr rows are awaited on a healthy server: that is not silence.
        assert_eq!(
            ask(Status::Loading, false, true, None, &mut from, 9000.0),
            None
        );
        assert_eq!(
            ask(Status::Loading, false, true, None, &mut from, 20000.0),
            None
        );
    }

    /// "Erneut versuchen" shows the error page at once, with the words of the failure it was pressed on, until the page
    /// leaves `Loading`.
    #[test]
    fn a_retry_keeps_the_error_page_while_it_waits() {
        let mut from = None;
        let denied = LoadFailure::Failed(swiftly_vm::FailKind::Denied);
        assert_eq!(
            waiting_trouble(Status::Loading, false, false, Some(denied), &mut from, 0.0),
            Some(denied)
        );
        assert_eq!(
            waiting_trouble(Status::Offline, false, false, Some(denied), &mut from, 20.0),
            None
        );
    }
}
