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
use swiftly_design::tokens::{colour, desktop, touch, tv};
use swiftly_images::Priority;
use swiftly_layout::{Align, Alignment, Axis, EdgeInsets, FlexFrame, Size};
use swiftly_render::{Color, DrawList, LinearGradient, RgbaImage};
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
            edge: desktop::EDGE_SPACING,
            rails_spacing: desktop::RAILS_SPACING,
            tile_spacing: desktop::TILE_SPACING,
            poster: Size::new(desktop::TILE_WIDTH, desktop::TILE_HEIGHT),
            // 16:9 of 280 pt as SwiftUI lays it out (159 pt in the parity render, the token says 158).
            landscape: Size::new(desktop::LANDSCAPE_WIDTH, 159.0),
            corner: desktop::CORNER_TILE,
            rail: desktop::text::SECTION,
            tile: desktop::text::TILE,
            small: desktop::text::SMALL,
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
    const W: f32 = desktop::FORM_WIDTH + 60.0;
    let inner = W - 36.0;
    let mut lines = Vec::new();
    if hours >= SupportCopy::CARD_MINIMUM_HOURS {
        lines.push(
            text(
                cx,
                &words(SupportCopy::CARD_WATCHED_HOURS).replace("%lld", &hours.to_string()),
                desktop::text::LIST_TITLE,
                colour::FONT,
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
            desktop::text::BODY,
            colour::FONT_QUIET,
            Some(3),
            swiftly_text::Align::Start,
        )
        .frame(Some(inner), None, Alignment::LEADING),
    );
    let button = |label: String, key: &str, primary: bool| {
        let (fg, bg) = if primary {
            (colour::REASON, colour::FONT)
        } else {
            (colour::FONT, colour::AREA)
        };
        text(
            cx,
            &label,
            desktop::text::LIST_TITLE,
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
        Node::rect(color(colour::GROUPS_AREA), desktop::CORNER_CARD),
        Alignment::CENTER,
    )
    .padding(ins(0.0, desktop::EDGE_SPACING, 0.0, 0.0))
}

/// The sheet over the Home page.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
enum Sheet {
    #[default]
    None,
    Menu(String),
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
        // A rounded rectangle as tall as two corner radii, bottom aligned, cut to the bottom 4 pt: exactly the tile's lower edge.
        let full = Node::rect(color, corner).frame(
            Some(width),
            Some(2.0 * corner),
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
            strip(width * share, color(colour::MARK_ACCENT)),
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
            let back = Node::rect(color(colour::AREA), m.corner)
                .pixel_snapped()
                .frame(Some(size.w), Some(size.h), Alignment::CENTER);
            back.overlay(
                remote_node(
                    hub.slot(tile.image.as_ref(), size.w, size.h, Priority::Visible),
                    size.w,
                    size.h,
                    m.corner,
                    || icons.node(symbol, 22.0, true, color(colour::FONT)),
                ),
                Alignment::CENTER,
            )
            .pixel_snapped()
        }
        (None, _) => match art.pick(landscape, &tile.id) {
            Some(id) => Node::image(id, size.w, size.h, m.corner),
            None => Node::rect(color(colour::AREA), m.corner).frame(
                Some(size.w),
                Some(size.h),
                Alignment::CENTER,
            ),
        },
    };
    let mut image = image.paint(Paint::Stroke {
        color: color(colour::TILE_BORDER),
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
        let share = share.clamp(0.0, 1.0);
        let bar = Node::zstack(
            Alignment::BOTTOM_LEADING,
            vec![
                Node::rect(Color::new(1.0, 1.0, 1.0, 0.30), 0.0).frame(
                    Some(size.w),
                    Some(BAR_HEIGHT),
                    Alignment::CENTER,
                ),
                Node::rect(color(colour::MARK_ACCENT), 0.0).frame(
                    Some(size.w * share),
                    Some(BAR_HEIGHT),
                    Alignment::CENTER,
                ),
            ],
        );
        image = image.overlay(bar, Alignment::BOTTOM_LEADING);
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
            .focus_ring(color(colour::MARK_ACCENT), m.corner);
    }
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
            colour::FONT,
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
                colour::FONT_VERY_QUIET,
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
    .on_long_press(Action::from(format!("menu:{}", tile.id).as_str()));
    if form == Form::Tv {
        n = n.focusable(focus_id(key), Some(FocusLook::tile(m.corner)));
    }
    if form == Form::Desktop {
        // Right click opens the menu (the touch long press stays); the focus ring sits on the picture above.
        n = n
            .on_secondary(Action::from(format!("menu:{}", tile.id).as_str()))
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
    let icon = icons.node(asset, 15.0, false, color(colour::FONT)).frame(
        Some(34.0),
        Some(34.0),
        Alignment::CENTER,
    );
    let b = icon
        .background(Node::rect(color(colour::AREA), 8.0), Alignment::CENTER)
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
        colour::FONT,
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
            colour::FONT,
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
                    colour::FONT_VERY_QUIET,
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
    Node::rect(color(colour::AREA), radius)
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
                colour::FONT,
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
                    color: color(colour::MARGIN),
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
    let disc = icons
        .node(asset, touch::EMPTY_SYMBOL, true, color(colour::FONT))
        .frame(
            Some(touch::EMPTY_DISC),
            Some(touch::EMPTY_DISC),
            Alignment::CENTER,
        )
        .background(
            Node::rect(color(colour::AREA), touch::EMPTY_DISC / 2.0),
            Alignment::CENTER,
        );
    let column = Node::vstack(
        Align::Center,
        Some(0.0),
        vec![
            disc.padding(ins(0.0, 0.0, 24.0, 0.0)),
            text(
                cx,
                heading,
                touch::text::SUBPAGE,
                colour::FONT,
                Some(2),
                swiftly_text::Align::Center,
            )
            .padding(ins(0.0, 0.0, 8.0, 0.0)),
            text(
                cx,
                body,
                touch::text::BODY,
                colour::FONT_QUIET,
                None,
                swiftly_text::Align::Center,
            )
            .frame(Some(touch::EMPTY_TEXT_WIDTH), None, Alignment::CENTER)
            .padding(ins(0.0, 0.0, 24.0, 0.0)),
            if button.is_empty() {
                Node::fixed(0.0, 0.0)
            } else {
                text(
                    cx,
                    button,
                    touch::text::CATEGORY,
                    colour::MARK_ACCENT,
                    Some(1),
                    swiftly_text::Align::Center,
                )
                .padding(EdgeInsets::symmetric(16.0, 0.0))
                .frame(None, Some(44.0), Alignment::CENTER)
                .key("retry")
                .on_tap(RETRY)
            },
        ],
    );
    fill_frame(column, Alignment::CENTER)
}

const RETRY: &str = "home.retry";

// ---- chrome --------------------------------------------------------------------------------------------------------

fn wordmark(cx: &Cx, label: &str, size: swiftly_design::TextStyle) -> Node {
    text(
        cx,
        label,
        size,
        colour::FONT,
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
pub(crate) const BAR_SINCE: f32 = desktop::CONTENT_TOP + 33.0 - desktop::TOOLBAR_HEIGHT;
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
        .map(|(at, a)| (at, rgba(colour::REASON, a * op)))
        .collect();
    Node::rect(rgba(colour::REASON, 0.0), 0.0)
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
        rgba(colour::FONT, s),
        Some(1),
        swiftly_text::Align::Start,
    )
    .padding(EdgeInsets {
        top: 0.0,
        leading: 20.0 + ARROWS_WIDTH + 12.0,
        bottom: 0.0,
        trailing: 16.0,
    })
    .frame(None, Some(desktop::TOOLBAR_HEIGHT), Alignment::LEADING);
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
        colour::REASON,
        &[(0.0, 0.97), (0.45, 0.78), (1.0, 0.0)],
        (s * 3.0).min(1.0),
        width,
        h,
    );
    let history = ramp(
        colour::REASON,
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
    let line = Node::rect(rgba(colour::LINE, colour::LINE.a * s), 0.0).frame(
        Some(width),
        Some(1.0),
        Alignment::CENTER,
    );
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
    let profile = Node::rect(color(colour::AREA), 999.0)
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

/// The icon of a tab and whether it has a filled asset (`Region.filledAsset`).
fn tab_icon(i: usize) -> (&'static str, bool) {
    match i {
        0 => ("house.fill", false),
        1 => ("film-strip.fill", false),
        2 => ("cards-three.fill", false),
        _ => ("magnifying-glass", true),
    }
}

pub(crate) fn tab_bar(cx: &Cx, env: &Env, p: &Bar, icons: &Icons) -> Node {
    let tabs = TABS
        .iter()
        .enumerate()
        .map(|(i, name)| {
            let c = if i == p.tab {
                colour::MARK_ACCENT
            } else {
                colour::FONT_VERY_QUIET
            };
            let (asset, outlined) = tab_icon(i);
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
    let line = Node::rect(color(colour::LINE), 0.0).frame(None, Some(1.0), Alignment::TOP);
    fill_frame(row, Alignment::TOP_LEADING)
        .frame(
            None,
            Some(touch::STRIP_HEIGHT + env.safe.bottom),
            Alignment::TOP_LEADING,
        )
        .background(
            Node::rect(rgba(colour::REASON, 0.94), 0.0),
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

/// The Mac `Sidebar`: 220 wide on the `area` colour, a hairline on its right, the wordmark, the four places with their
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
            (colour::MARK_ACCENT, colour::MARK_ACCENT)
        } else {
            (colour::FONT_QUIET, colour::FONT)
        };
        let style = swiftly_design::TextStyle {
            size: 14.0,
            weight: if active { 600 } else { 500 },
            ..desktop::text::BAR_TITLE
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
                colour::FONT_VERY_QUIET,
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
                Node::rect(rgba(colour::MARK_ACCENT, 0.12), 8.0),
                Alignment::CENTER,
            );
        }
        n.hover_surface(hot, swiftly_ui::feel::SIDEBAR_HOVER_RADIUS)
            .press_style(swiftly_ui::PressStyle::Row)
            .focusable(focus_id(action), None)
            .focus_ring(color(colour::MARK_ACCENT), 8.0)
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
            let (asset, outlined) = tab_icon(i);
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
            colour::FONT_VERY_QUIET,
            Some(1),
            swiftly_text::Align::Start,
        )
        .padding(ins(20.0, 20.0, 4.0, 20.0)),
    ];
    if p.mine.0 {
        mine.push(row(
            p.tab == 4 && !p.downloads && !p.settings,
            "Merkliste",
            "bookmark-simple.fill",
            false,
            None,
            "go:watchlist",
            "Merkliste",
        ));
    }
    if p.mine.1 {
        // The Mac's filled asset (`Region.filledAsset`).
        mine.push(row(
            p.downloads,
            "Downloads",
            "arrow-circle-down.fill",
            false,
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
                colour::REASON,
                Some(1),
                swiftly_text::Align::Center,
            )
        };
        // The signed-in user's picture (`userImageURL()`), the initial only while there is none.
        let face = crate::hub::avatar_node(hub, p.card.picture(), 28.0, letter)
            .frame(Some(28.0), Some(28.0), Alignment::CENTER)
            .background(
                Node::rect(color(colour::MARK_ACCENT), 14.0),
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
            colour::FONT,
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
                colour::FONT_VERY_QUIET,
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
                icons.node("gear", 16.0, false, color(colour::FONT_VERY_QUIET)),
            ],
        )
        .padding(EdgeInsets::symmetric(10.0, 0.0))
        .frame(None, Some(48.0), Alignment::LEADING);
        let mut selected =
            fill_frame(content, Alignment::LEADING).frame(None, Some(48.0), Alignment::LEADING);
        if p.settings {
            selected = selected.background(
                Node::rect(rgba(colour::MARK_ACCENT, 0.12), 8.0),
                Alignment::CENTER,
            );
        }
        selected
            .hover_surface(hot, swiftly_ui::feel::SIDEBAR_HOVER_RADIUS)
            .press_style(swiftly_ui::PressStyle::Row)
            .focusable(focus_id("profile"), None)
            .focus_ring(color(colour::MARK_ACCENT), 8.0)
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
            // `Color.clear.frame(height: signalHeight)`, then the 26 pt wordmark 4 pt below it.
            icons
                .wordmark(26.0, color(colour::FONT), color(colour::MARK_ACCENT))
                .a11y(swiftly_ui::a11y::A11yNode::new(
                    "",
                    swiftly_ui::a11y::Role::Image,
                    "Swiftly",
                ))
                .padding(ins(
                    desktop::SIGNAL_HEIGHT + 4.0,
                    20.0,
                    92.0 - 44.0 - 26.0 - 2.0,
                    20.0,
                )),
            Node::vstack(Align::Start, Some(2.0), top).padding(ins(0.0, 10.0, 0.0, 10.0)),
            Node::vstack(Align::Start, Some(2.0), mine).padding(ins(0.0, 10.0, 0.0, 10.0)),
            Node::spacer(),
            offer_row(cx, p.offer.as_ref(), icons),
            footer,
        ],
    );
    let hairline = Node::rect(color(colour::LINE), 0.0).frame(Some(1.0), None, Alignment::TRAILING);
    fill_frame(column, Alignment::TOP_LEADING)
        .frame(Some(desktop::SIDEBAR_WIDTH), None, Alignment::TOP_LEADING)
        .flex_frame(FlexFrame {
            max_h: Some(f32::INFINITY),
            align: Some(Alignment::TOP_LEADING),
            ..FlexFrame::default()
        })
        .background(Node::rect(color(colour::AREA), 0.0), Alignment::CENTER)
        .overlay(
            fill_frame(hairline, Alignment::TRAILING),
            Alignment::TRAILING,
        )
}

/// The offer row above the account card (`OfferingRow`): a capsule 40 high in accent at 18 % over `reason`, the icon, the
/// title (13 semibold) with what runs under it (12, very quiet), and from two entries a counter capsule in accent. It
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
    let accent = color(colour::MARK_ACCENT);
    let mut cells = vec![
        icons
            .node(&o.symbol, 17.0, true, accent)
            .frame(Some(20.0), None, Alignment::CENTER),
        Node::vstack(
            Align::Start,
            Some(1.0),
            vec![
                text(
                    cx,
                    &o.title,
                    st(13.0, 600),
                    colour::MARK_ACCENT,
                    Some(1),
                    swiftly_text::Align::Start,
                ),
                text(
                    cx,
                    &o.under,
                    st(12.0, 400),
                    colour::FONT_VERY_QUIET,
                    Some(1),
                    swiftly_text::Align::Start,
                ),
            ],
        )
        .layout_priority(1.0),
        Node::spacer(),
    ];
    if o.count > 1 {
        cells.push(
            text(
                cx,
                &o.count.to_string(),
                st(10.0, 600),
                colour::REASON,
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
            .background(Node::rect(accent, 10.0), Alignment::CENTER),
        );
    }
    let trailing = if o.count > 1 { 10.0 } else { 14.0 };
    let capsule = Node::hstack(Align::Center, Some(10.0), cells)
        .padding(EdgeInsets {
            top: 0.0,
            leading: 14.0,
            bottom: 0.0,
            trailing,
        })
        .frame(None, Some(desktop::BADGE_HEIGHT), Alignment::LEADING)
        .background(Node::rect(color(colour::REASON), 999.0), Alignment::CENTER)
        .background(
            Node::rect(rgba(colour::MARK_ACCENT, 0.18), 999.0),
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
        colour::FONT
    } else {
        colour::FONT_QUIET
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
                focused: color(colour::REASON),
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
        let line = Node::rect(color(colour::MARK_ACCENT), 999.0)
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
        colour::FONT,
        Some(1),
        swiftly_text::Align::Center,
    )
    .frame(Some(60.0), Some(60.0), Alignment::CENTER)
    .background(Node::rect(color(colour::AREA), 30.0), Alignment::CENTER)
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
        spokes.push(icons.spoke(k, size, rgba(colour::FONT_QUIET, alpha)));
    }
    // Always a node of the same shape, so the tree (and the scroll state under it) does not change when it comes and goes.
    Node::zstack(Alignment::CENTER, spokes).frame(Some(size), Some(size), Alignment::CENTER)
}

// ---- tv hero -------------------------------------------------------------------------------------------------------

/// The tvOS `heroZone`: the focused title's backdrop on the trailing side fading into the ground, and its name,
/// second line and the time left at the leading edge (`HeaderInfo`). Not drawn: the description (not in `HomeVm`
/// tiles), the 250 ms image switch delay and the radial `HeaderShadow` spot.
fn hero(cx: &Cx, m: &Metrics, ctx: &Ctx, tile: Option<&Tile>) -> Node {
    let ground = colour::REASON;
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
            colour::FONT,
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
                    colour::FONT_QUIET,
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
                    colour::FONT_QUIET,
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
            desktop::text::TITLE_LARGE,
            colour::FONT,
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
        .padding(ins(desktop::CONTENT_TOP, 0.0, 0.0, 0.0));
        return fill_frame(column, Alignment::TOP_LEADING);
    }
    let has_rails = !p.rails.rails.is_empty();
    let top = match form {
        Form::Touch => env.safe.top + 58.0 + 8.0,
        Form::Desktop => desktop::CONTENT_TOP,
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
                env.size.w - desktop::SIDEBAR_WIDTH,
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
    let tiles = || p.rails.rails.iter().flat_map(|r| r.tiles.iter());
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
        Sheet::Menu(id) => {
            let tile = tiles().find(|t| &t.id == id);
            let c = mcx(id);
            Some(crate::browse::sheet(
                cx,
                &ctx.icons,
                &m,
                tile.map_or("", |t| t.title.as_str()),
                &crate::tile_menu::rows(form, &c, tile),
                "pick.m.",
                false,
            ))
        }
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
    let page = fill_frame(page, Alignment::TOP_LEADING)
        .background(Node::rect(color(colour::REASON), 0.0), Alignment::CENTER);
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
    tab: usize,
    now: f64,
    pulling: bool,
    sheet: Sheet,
    load: crate::load_panel::LoadSpec,
    requests: Vec<String>,
    menu: crate::desk::TileMenu,
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
}

impl HomeScreen {
    /// What a screen reader gets for this screen: the nodes of the current picture.
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.ui.a11y_nodes()
    }

    /// A home screen for `env` over a scripted server in `scenario`.
    pub fn new(env: Env, cx: Cx, scenario: Scenario) -> HomeScreen {
        let vm = home_data::home_vm(scenario);
        let art = Rc::new(Art {
            posters: art::posters(&cx),
            landscapes: art::heroes(&cx),
        });
        let hub: HubSlot = Rc::new(RefCell::new(None));
        let ctx = Ctx {
            hub: Rc::clone(&hub),
            art,
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
            tab: 0,
            now: 0.0,
            pulling: false,
            sheet: Sheet::None,
            load: crate::load_panel::LoadSpec::demo(""),
            requests: Vec::new(),
            menu: crate::desk::TileMenu::default(),
            hovered_rail: None,
            chips: Vec::new(),
            stagger: 0,
            rails_out: false,
            genres: Vec::new(),
            libraries: Vec::new(),
            jumped: None,
            support: None,
            support_taps: Vec::new(),
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

    fn sync(&mut self) {
        self.hub.frame(self.now);
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
        self.ui.set_parts(Parts {
            downloads: crate::desk::downloads_front(),
            settings: crate::desk::settings_front(),
            card: crate::desk::card(),
            offer: crate::desk::offer(),
            mine: crate::desk::mine(),
            glow: crate::look_glow::bar_state(offset as f64),
            status,
            rails: self.vm.rails(),
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
            chips: if self.vm.rails().rails.iter().any(|r| r.is_genre()) {
                Vec::new()
            } else {
                self.chips.clone()
            },
            stagger: self.stagger,
            rails_out: self.rails_out,
            support: self.support,
        });
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
    }

    fn tile_of(&self, id: &str) -> Option<Tile> {
        self.vm
            .rails()
            .rails
            .iter()
            .flat_map(|r| r.tiles.iter())
            .find(|t| t.id == id)
            .cloned()
    }

    /// The press on a row of the open tile menu, devices list or download sheet.
    fn sheet_tap(&mut self, is: &dyn Fn(&str) -> bool) {
        use crate::tile_menu::Entry;
        let form = Form::of(self.ui.env().idiom);
        match self.sheet.clone() {
            Sheet::None => {}
            Sheet::Menu(id) => {
                if is("sheet.close") {
                    self.sheet = Sheet::None;
                }
                let tile = self.tile_of(&id);
                let cw = self.vm.rails().rails.iter().any(|r| {
                    r.kind == RailKind::ContinueWatching && r.tiles.iter().any(|t| t.id == id)
                });
                let c = crate::tile_menu::rail_cx(cw, false);
                for (i, e) in crate::tile_menu::entries(form, &c, tile.as_ref())
                    .into_iter()
                    .enumerate()
                {
                    if !is(&format!("pick.m.{i}")) {
                        continue;
                    }
                    self.sheet = Sheet::None;
                    match e {
                        Entry::Play if cw => self.resumed.push(id.clone()),
                        Entry::Play
                        | Entry::FromStart
                        | Entry::Info
                        | Entry::Overview
                        | Entry::ToSeries => self.opened.push(id.clone()),
                        Entry::Load => {
                            self.load = crate::load_panel::LoadSpec::demo(
                                tile.as_ref().map_or("", |t| t.title.as_str()),
                            );
                            self.sheet = Sheet::Load(id.clone());
                        }
                        Entry::PlayOn => self.sheet = Sheet::Devices(id.clone()),
                        // The host carries these out (`TileRequest`, played back in the app).
                        Entry::Watched
                        | Entry::Unwatched
                        | Entry::Remember
                        | Entry::Together
                        | Entry::Remove => self.requests.push(format!("{e:?}:{id}")),
                    }
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

    fn picked(&mut self, pick: crate::desk::Pick) {
        if let crate::desk::Pick::Row(id, i) = pick {
            // The same handler as the sheet rows: the menu is the sheet's list in another frame.
            self.sheet = Sheet::Menu(id);
            self.sheet_tap(&|s| s == format!("pick.m.{i}"));
        }
    }

    fn drain(&mut self) {
        for ev in self.ui.take_events() {
            match &ev {
                UiEvent::Secondary { action, x, y } => {
                    let tile = self
                        .vm
                        .rails()
                        .rails
                        .iter()
                        .flat_map(|r| r.tiles.iter())
                        .find(|t| *action == Action::from(format!("menu:{}", t.id).as_str()))
                        .cloned();
                    if let Some(t) = tile {
                        let cw = self.vm.rails().rails.iter().any(|r| {
                            r.kind == RailKind::ContinueWatching
                                && r.tiles.iter().any(|x| x.id == t.id)
                        });
                        if crate::tile_menu::carries(Some(&t)) {
                            self.menu.open(
                                &t,
                                &crate::tile_menu::rail_cx(cw, false),
                                swiftly_layout::Point::new(*x, *y),
                                false,
                            );
                        }
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
                && let Some(t) = self
                    .vm
                    .rails()
                    .rails
                    .iter()
                    .flat_map(|r| r.tiles.iter())
                    .find(|t| *a == Action::from(format!("menu:{}", t.id).as_str()))
                && crate::tile_menu::carries(Some(t))
            {
                self.sheet = Sheet::Menu(t.id.clone());
            }
            if let UiEvent::Tap(action) = ev {
                crate::forms::note_tap(&action);
                if self.sheet != Sheet::None {
                    self.sheet_tap(&|s| action == Action::from(s));
                    continue;
                }
                if action == Action::from(RETRY) {
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
        self.sheet = Sheet::Menu(id.to_owned());
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
        let wants = self.wants_frame();
        (list, wants)
    }

    /// An animation, a glide, a held touch or the spinner needs another frame.
    pub fn wants_frame(&self) -> bool {
        self.ui.needs_frame() || self.vm.status().refreshing || self.hub.busy()
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
        let reason = colour::REASON.r;
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
