//! The pages the Mac has besides film and series: Person with filmography, Playlist, Genre, Collection and the Seerr search
//! block and detail page (`PersonView`, `PlaylistPage`, `GenreView`, `MacCollection`, `SeerrTileAndPage`; spec
//! the Mac detail, series and people pages). Drawn from `PersonVm`, `PlaylistVm`
//! and `SeerrVm` parts for the desktop form; one screen type with one `Kind` per page, pushed over a transparent root like
//! the Detail screen.

use crate::detail_screen::{
    Art, Kit, Pushed, UiState, fill_frame, ground, ins, look, menu_key, rgba, tile_rail, top_bar,
    txt, txt_center, weight, wide,
};
use crate::home_data::Scenario;
use std::rc::Rc;
use swiftly_design::tokens::colour;
use swiftly_l10n::Locale;
use swiftly_layout::{Align, Alignment, Axis, Point, Rect};
use swiftly_library::library_filter::Sorting;
use swiftly_library::{LibraryFilter, ShelfSource};
use swiftly_model::{Item, Person};
use swiftly_render::{Color, DrawList, RgbaImage};
use swiftly_seerr::models::{SeerrDetail, SeerrHit, SeerrPerson, SeerrSeason, SeerrState};
use swiftly_ui::components::color;
use swiftly_ui::icons::Icons;
use swiftly_ui::interact::PressStyle;
use swiftly_ui::popover::{self, Anchor, MenuEntry, MenuItem};
use swiftly_ui::{Action, Cx, Env, Node, Paint};
use swiftly_vm::{
    DiscoverPart, LibraryIntent, LibrarySpec, LibraryStatus, LibraryVm, PersonDetail, PersonPart,
    PersonVm, PlaylistPart, PlaylistVm, SeerrEffect, SeerrIntent, SeerrPart, SeerrTile, SeerrVm,
    Tile, TileFacts,
};

/// Which page a screen shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// A person and their titles on the server.
    Person,
    /// A playlist.
    Playlist,
    /// A genre: its titles, no filter or sort row.
    Genre,
    /// A collection: title, filter and sort pills, grid.
    Collection,
    /// The "Über Seerr anfragen" block of the search.
    SeerrSearch,
    /// A Seerr title with its request flow.
    SeerrDetail,
}

/// The pictures and tiles of a live person page (the demo page draws placeholders from the ids instead).
#[derive(Clone, PartialEq, Default)]
pub struct PersonArt {
    /// The portrait: the cast tile's picture at first, the sharp one when the person has loaded.
    pub portrait: Option<swiftly_vm::ImageRef>,
    /// The banner picture of the first title with a landscape picture.
    pub banner: Option<swiftly_vm::ImageRef>,
    /// The filmography as tiles with their pictures.
    pub tiles: Vec<Tile>,
    /// Seerr's titles of the person that the own server does not have (the Mac's `requestRail`).
    pub requests: Vec<SeerrTile>,
}

/// A tap on a cast tile: what the person page opens with (the Mac's `PersonRoute`).
#[derive(Clone, Debug, PartialEq)]
pub struct PersonTap {
    /// Person id.
    pub id: String,
    /// Name.
    pub name: String,
    /// The role in the title the tap came from.
    pub role: Option<String>,
    /// The cast tile's picture.
    pub image: Option<swiftly_vm::ImageRef>,
    /// The title the tap came from (shown above the role).
    pub origin: Option<String>,
}

/// The running load of a live person page.
struct PersonLive {
    rx: Option<crate::login_screen::Pending<crate::live_person::Loaded>>,
    client: crate::live::Client,
    id: String,
    locale: Locale,
    /// What a retry loads again (the Mac's `DisturbHint(retry: load)`).
    core: std::sync::Arc<crate::live::Core>,
    account: swiftly_vm::AccountRef,
}

/// The running load of a live genre, collection or playlist page: the titles (`None`: the server did not answer).
struct GridLive {
    rx: Option<crate::login_screen::Pending<Option<Vec<Item>>>>,
    client: crate::live::Client,
    locale: Locale,
}

/// What the two pills of a collection page say (`SelectionButton` with the chosen value).
#[derive(Clone, PartialEq)]
struct Pills {
    filter: String,
    sort: String,
    /// The sorting's symbol (`Sorting.symbol` on the Mac).
    sort_icon: &'static str,
}

/// The empty state of a grid page: heading, text, and the way out as (label, action).
type EmptyNote = (String, String, Option<(String, String)>);

/// The symbol of a sorting (`Sorting.symbol`, `LibraryView.swift`): the Mac's SF symbols as their Phosphor twins.
fn sorting_icon(s: Sorting) -> &'static str {
    match s {
        Sorting::Name => "text-aa",
        Sorting::Latest => "clock",
        Sorting::Rating => "star",
        Sorting::Erscheinung => "calendar-blank",
    }
}

/// The filters a collection page offers: for shows the same three as on the iPhone, else all four
/// (`CollectionDetailPage.filter`).
pub fn collection_filters(art: Option<&str>) -> Vec<(LibraryFilter, &'static str)> {
    crate::library_screen::FILTERS
        .iter()
        .copied()
        .filter(|(f, _)| art != Some("tvshows") || *f != LibraryFilter::Unwatched)
        .collect()
}

/// The shelf behind a live collection page: the library view model with a collection as its source
/// (`LibraryView(collection:)` with its own `LibraryModel`, never remembered).
struct Shelf {
    vm: LibraryVm<crate::net::AppTransport>,
    art: Option<String>,
    /// The tile a "load more" was asked for last (one ask per last row).
    asked: Option<String>,
    /// The grid version the page shows.
    shown: u64,
}

#[derive(Clone, PartialEq)]
enum Body {
    Person(PersonPart, Box<PersonArt>),
    Playlist(PlaylistPart),
    Grid {
        name: String,
        tiles: Vec<Tile>,
        loading: bool,
        failed: bool,
        pills: Option<Pills>,
        empty: Option<EmptyNote>,
    },
    Discover(DiscoverPart),
    Seerr(Box<SeerrPart>),
}

#[derive(Clone, PartialEq)]
struct Data {
    body: Body,
    /// Seerr's address for the "does not answer" text of the Seerr title page.
    address: String,
}

/// A tile of a model item (title, year); the picture comes from the hub or the demo art.
fn tile_of(i: &Item) -> Tile {
    Tile {
        id: i.id.clone(),
        title: i.name.clone(),
        subtitle: i.production_year.map(|y| y.to_string()),
        progress: None,
        image: None,
        badges: Vec::new(),
        remaining: None,
        facts: TileFacts {
            kind: i.type_.clone(),
            name: i.name.clone(),
            year: i.production_year.map(|y| y as i32),
            ..TileFacts::default()
        },
    }
}

fn header(k: &Kit, title: &str, right: Option<Node>) -> Node {
    let t = txt(
        k.cx,
        title,
        weight(k.lk.rail, 30.0, 700),
        colour::FONT,
        Some(1),
    );
    let mut row = vec![t];
    if let Some(r) = right {
        row.push(Node::spacer());
        row.push(r);
    }
    Node::hstack(Align::Center, Some(12.0), row).padding(ins(0.0, k.lk.edge, 0.0, k.lk.edge))
}

/// The poster grid: 150 wide, 16 apart, rows 20 apart (`adaptive(150)`).
fn grid(k: &Kit, tiles: &[Tile], prefix: &str) -> Node {
    let per = (((k.env.size.w - 2.0 * k.lk.edge + 16.0) / (k.lk.poster.w + 16.0)).floor() as usize)
        .max(1);
    let rows: Vec<Node> = tiles
        .chunks(per)
        .enumerate()
        .map(|(r, c)| {
            Node::hstack(
                Align::Start,
                Some(16.0),
                c.iter()
                    .enumerate()
                    .map(|(i, t)| {
                        crate::detail_screen::poster_tile(
                            k,
                            t,
                            &format!("{prefix}:{}", r * per + i),
                            false,
                        )
                    })
                    .collect(),
            )
        })
        .collect();
    Node::vstack(Align::Start, Some(20.0), rows).padding(ins(0.0, k.lk.edge, 0.0, 0.0))
}

/// `GridPlaceholder`: 6 x 2 rects.
fn placeholders(k: &Kit) -> Node {
    let row = || {
        Node::hstack(
            Align::Start,
            Some(16.0),
            (0..6)
                .map(|_| {
                    Node::rect(color(colour::AREA), 10.0).frame(
                        Some(k.lk.poster.w),
                        Some(k.lk.poster.h),
                        Alignment::CENTER,
                    )
                })
                .collect(),
        )
    };
    Node::vstack(Align::Start, Some(20.0), vec![row(), row()])
        .padding(ins(0.0, k.lk.edge, 0.0, 0.0))
}

/// `EmptyState`: disc 78, symbol, title, text (max 262), the quiet accent action.
pub(crate) fn empty_state(
    k: &Kit,
    icon: &str,
    title: &str,
    text: &str,
    action: Option<(&str, &str)>,
) -> Node {
    let disc = k
        .icons
        .node(icon, 44.0, true, color(colour::FONT_QUIET))
        .frame(Some(78.0), Some(78.0), Alignment::CENTER)
        .background(Node::rect(color(colour::AREA), 39.0), Alignment::CENTER);
    let mut kids = vec![
        disc,
        txt_center(k.cx, title, weight(k.lk.rail, 17.0, 600), colour::FONT, 2),
        txt_center(
            k.cx,
            text,
            weight(k.lk.body, 15.0, 400),
            colour::FONT_QUIET,
            3,
        )
        .frame(Some(262.0), None, Alignment::CENTER),
    ];
    if let Some((label, a)) = action {
        kids.push(
            txt_center(
                k.cx,
                label,
                weight(k.lk.body, 15.0, 500),
                colour::MARK_ACCENT,
                1,
            )
            .frame(None, Some(44.0), Alignment::CENTER)
            .key(a)
            .on_tap(Action::from(a)),
        );
    }
    wide(
        Node::vstack(Align::Center, Some(10.0), kids),
        Alignment::CENTER,
    )
    .padding(ins(80.0, 0.0, 0.0, 0.0))
}

fn primary(k: &Kit, label: &str, icon: Option<&str>, w: f32, key: &str, on: bool) -> Node {
    let (fg, bg) = if on {
        (colour::REASON, colour::FONT)
    } else {
        (colour::FONT_VERY_QUIET, colour::AREA)
    };
    let mut kids = Vec::new();
    if let Some(i) = icon {
        kids.push(k.icons.node(i, 17.0, true, color(fg)));
    }
    kids.push(txt(k.cx, label, weight(k.lk.body, 17.0, 600), fg, Some(1)));
    let n = Node::hstack(Align::Center, Some(9.0), kids)
        .frame(Some(w), Some(48.0), Alignment::CENTER)
        .background(Node::rect(color(bg), 10.0), Alignment::CENTER)
        .key(key);
    if on {
        n.on_tap(Action::from(key))
            .hover_surface(rgba(colour::REASON, 0.12), 10.0)
            .press_style(PressStyle::Button)
    } else {
        n
    }
}

/// The page backdrop: a picture right aligned, run out to the ground at the left and the foot (`Backdrop`).
fn backdrop(
    k: &Kit,
    image: Option<&swiftly_vm::ImageRef>,
    id: &str,
    w: f32,
    h: f32,
    bw: f32,
) -> Node {
    let img = k.art.node_for(image, true, id, bw, h, 0.0);
    let n = (h / 6.0).ceil() as usize;
    let bands: Vec<Node> = (0..n)
        .map(|i| {
            let ym = (i as f32 + 0.5) * 6.0;
            let v = crate::detail_screen::curve_at(&crate::detail_screen::BACKDROP_V, ym / h);
            let stops = crate::detail_screen::BACKDROP_H
                .iter()
                .map(|&(x, a)| (x, rgba(colour::REASON, 1.0 - a * v)))
                .collect();
            Node::rect(Color::CLEAR, 0.0)
                .paint(Paint::Stops {
                    stops,
                    vertical: false,
                    radius: 0.0,
                })
                .frame(Some(bw), Some(6.0), Alignment::CENTER)
        })
        .collect();
    let covered = img.overlay(
        Node::vstack(Align::Start, Some(0.0), bands),
        Alignment::TOP_LEADING,
    );
    Node::hstack(Align::Start, Some(0.0), vec![Node::spacer(), covered]).frame(
        Some(w),
        Some(h),
        Alignment::TOP_LEADING,
    )
}

/// The height of the person page's header (`PersonView.headerHeight`) and of its backdrop (`headerHeight * 1.62`).
const PERSON_BACKDROP_HEIGHT: f32 = 260.0 * 1.62;
/// How far the page tone runs: the header plus 260 (`LinearGradient([color.audio, reason])`).
const PERSON_TONE_HEIGHT: f32 = 260.0 + 260.0;

fn person_page(k: &Kit, p: &PersonPart, art: &PersonArt) -> Node {
    let w = k.env.size.w;
    let edge = k.lk.edge;
    // Hero 260: portrait 88 and the name block bottom-left (left 36, bottom 22), the first title's landscape at the right.
    let portrait = k
        .art
        .node_for(art.portrait.as_ref(), false, &p.name, 88.0, 88.0, 44.0);
    // `Theme.titleLarge` (30 bold) with the page-title letter spacing; the block is `readWidth` wide.
    let mut id = vec![
        Node::text(
            k.cx,
            &p.name,
            &swiftly_text::TextStyle {
                tracking: -0.5, // `Theme.lockTitle` on the Mac
                ..swiftly_text::TextStyle::from(weight(k.lk.rail, 30.0, 700))
            },
            color(colour::FONT),
            Some(1),
            swiftly_text::Align::Start,
        )
        .frame(Some(700.0), None, Alignment::LEADING),
    ];
    // Birthday and place keep two lines from the start (`PersonView`: the height stands, the text fades in), so the
    // block does not jump when the person arrives.
    for l in [&p.born_line, &p.place] {
        id.push(
            match l {
                Some(l) => txt(
                    k.cx,
                    l,
                    weight(k.lk.small, 12.0, 400),
                    colour::FONT_QUIET,
                    Some(1),
                ),
                None => Node::fixed(0.0, 0.0),
            }
            .frame(None, Some(16.0), Alignment::LEADING),
        );
    }
    let block = Node::hstack(
        Align::End,
        Some(16.0),
        vec![portrait, Node::vstack(Align::Start, Some(6.0), id)],
    )
    .padding(ins(0.0, edge, 22.0, 0.0));
    let first = p.titles.first().map_or("", |t| t.id.as_str());
    // `PersonView.hero`: `Backdrop(url:, height: headerHeight * 1.62)` in a header of 260: the picture is `max(62 % page,
    // 520)` wide, 421 high, runs on below the header and fades out to the left and at the foot (`BackdropsFade`). What it
    // fades into is the page's own ground, the banner's tone running into the plain ground (see the page background below).
    let tones = k.art.tones_for(art.banner.as_ref(), first);
    let top = crate::detail_screen::mood_sampler(&tones, 260.0)(0.5, 0.0);
    let ground = color(colour::REASON);
    let sample = move |_x: f32, y: f32| {
        let t = (y / PERSON_TONE_HEIGHT).clamp(0.0, 1.0);
        let mix = |a: f32, b: f32| a + (b - a) * t;
        Color::new(
            mix(top.r, ground.r),
            mix(top.g, ground.g),
            mix(top.b, ground.b),
            1.0,
        )
    };
    let bw = (w * 0.62).max(520.0).min(w);
    let hues = tones
        .iter()
        .fold(0u64, |a, t| a.rotate_left(7) ^ t.to_bits());
    let backdrop_key = format!(
        "person-backdrop:{first}:{}:{hues:x}",
        (bw / w * 1000.0).round()
    );
    let hero = fill_frame(block, Alignment::BOTTOM_LEADING)
        .frame(Some(w), Some(260.0), Alignment::BOTTOM_LEADING)
        .background(
            crate::detail_screen::faded_backdrop(
                k,
                art.banner.as_ref(),
                first,
                w,
                bw,
                PERSON_BACKDROP_HEIGHT,
                &sample,
                backdrop_key,
            ),
            Alignment::TOP_LEADING,
        );
    let mut body = Vec::new();
    // The role and the biography are one block, 10 apart (`roleRow`).
    let mut about = Vec::new();
    if let Some(r) = &p.role_line {
        about.push(txt(
            k.cx,
            r,
            weight(k.lk.body, 13.0, 500),
            colour::MARK_ACCENT,
            Some(1),
        ));
    }
    if let Some(bio) = &p.biography {
        let lines = if p.biography_expanded { None } else { Some(4) };
        let bio_style = swiftly_text::TextStyle {
            line_height: swiftly_text::LineHeight::Points(15.0 * 1.21 + 3.0),
            ..swiftly_text::TextStyle::from(weight(k.lk.body, 15.0, 400))
        };
        // `withAnimation(Theme.leap) { toggleBiography() }`: the frame follows the text's height to its new value.
        let height =
            k.cx.text
                .borrow_mut()
                .layout(
                    bio,
                    &bio_style,
                    Some(700.0),
                    lines,
                    swiftly_text::Align::Start,
                )
                .height();
        let t = Node::text(
            k.cx,
            bio,
            &bio_style,
            color(colour::FONT_QUIET),
            lines,
            swiftly_text::Align::Start,
        )
        .animated_frame(
            Some(700.0),
            Some(height),
            Alignment::TOP_LEADING,
            swiftly_ui::feel::leap(),
        )
        .clipped()
        .key("bio-text");
        let toggle = if p.biography_expanded {
            "Weniger"
        } else {
            p.biography_toggle.as_str()
        };
        let more = txt(
            k.cx,
            toggle,
            weight(k.lk.body, 15.0, 500),
            colour::MARK_ACCENT,
            Some(1),
        )
        .key("bio-toggle")
        .on_tap(Action::from("bio-toggle"));
        about.push(Node::vstack(Align::Start, Some(6.0), vec![t, more]));
    }
    if !about.is_empty() {
        body.push(Node::vstack(Align::Start, Some(10.0), about).padding(ins(0.0, edge, 0.0, 0.0)));
    }
    if !p.titles.is_empty() {
        let tiles: Vec<Tile> = if art.tiles.is_empty() {
            p.titles.iter().map(tile_of).collect()
        } else {
            art.tiles.clone()
        };
        body.push(tile_rail(k, "titles", &p.rail_title, &tiles, false));
    }
    if !art.requests.is_empty() {
        let tiles: Vec<Node> = art
            .requests
            .iter()
            .enumerate()
            .map(|(i, t)| seerr_tile(k, t, &format!("request:{i}")))
            .collect();
        body.push(crate::detail_screen::segment(
            k,
            "requestable",
            &p.requestable_title,
            tiles,
            16.0,
            225.0 + 8.0 + 36.0,
        ));
    } else if !p.requestable.is_empty() {
        let tiles: Vec<Tile> = p
            .requestable
            .iter()
            .map(|t| Tile {
                id: t.clone(),
                title: t.clone(),
                subtitle: None,
                progress: None,
                image: None,
                badges: Vec::new(),
                remaining: None,
                facts: TileFacts::default(),
            })
            .collect();
        body.push(tile_rail(
            k,
            "requestable",
            &p.requestable_title,
            &tiles,
            false,
        ));
    }
    if let Some(e) = &p.empty_text {
        body.push(
            txt(
                k.cx,
                e,
                weight(k.lk.body, 15.0, 400),
                colour::FONT_QUIET,
                Some(2),
            )
            .padding(ins(0.0, edge, 0.0, edge)),
        );
    }
    if p.disrupted && p.titles.is_empty() {
        body.push(empty_state(
            k,
            "hard-drive-x",
            "Server ist abgetaucht",
            "Die Titel kommen gerade nicht an.",
            Some(("Erneut versuchen", "retry")),
        ));
    }
    // The page tone runs on under the hero and fades into the ground (`LinearGradient([color.audio, reason])`, the hero's
    // height plus 260): the banner's own hue at the top, the plain ground where the rails start.
    let page = Node::vstack(
        Align::Start,
        Some(0.0),
        vec![
            hero,
            Node::vstack(Align::Start, Some(26.0), body).padding(ins(26.0, 0.0, 0.0, 0.0)),
        ],
    );
    if tones.is_empty() {
        return page;
    }
    page.background(
        crate::detail_screen::gradient(
            [0.5, 0.0],
            [0.5, 1.0],
            top,
            color(colour::REASON),
            w,
            PERSON_TONE_HEIGHT,
        )
        .key("person-mood"),
        Alignment::TOP_LEADING,
    )
}

fn playlist_page(k: &Kit, p: &PlaylistPart) -> Node {
    let count = p.count.map(|n| {
        txt(
            k.cx,
            &n.to_string(),
            weight(k.lk.small, 13.0, 500),
            colour::FONT_VERY_QUIET,
            Some(1),
        )
        .a11y_label(swiftly_ui::a11y::Role::Text, format!("{n} Titel"))
    });
    let mut kids = vec![header(k, &p.title, count)];
    kids.push(
        primary(
            k,
            "Abspielen",
            Some("play.fill"),
            200.0,
            "play",
            !p.shown.is_empty(),
        )
        .padding(ins(14.0, k.lk.edge, 0.0, 0.0)),
    );
    let tiles: Vec<Tile> = p.shown.iter().map(tile_of).collect();
    kids.push(if p.loading {
        placeholders(k)
            .padding(ins(22.0, 0.0, 0.0, 0.0))
            .reveal_as("page.loading")
    } else if p.disrupted {
        empty_state(
            k,
            "hard-drive-x",
            "Server ist abgetaucht",
            "Der Server antwortet nicht. Läuft er noch, oder hängt das WLAN?",
            Some(("Erneut versuchen", "retry")),
        )
    } else if let Some(e) = &p.empty {
        empty_state(
            k,
            "film-strip",
            &e.headline,
            &e.text,
            Some((e.button.as_str(), "refresh")),
        )
    } else {
        grid(k, &tiles, "entry").padding(ins(22.0, 0.0, 0.0, 0.0))
    });
    Node::vstack(Align::Start, Some(0.0), kids).padding(ins(58.0, 0.0, 0.0, 0.0))
}

fn grid_page(
    k: &Kit,
    name: &str,
    tiles: &[Tile],
    loading: bool,
    failed: bool,
    pills: Option<&Pills>,
    empty: Option<&EmptyNote>,
) -> Node {
    let mut kids = vec![header(k, name, None)];
    if let Some(Pills {
        filter: f,
        sort: s,
        sort_icon,
    }) = pills
    {
        // `FilterBox` 44: two pills, 8 apart; each opens a 190 wide list.
        let pill = |label: &str, key: &str, icon: Option<&str>| {
            let mut row = Vec::new();
            if let Some(icon) = icon {
                row.push(k.icons.node(icon, 14.0, true, color(colour::FONT_QUIET)));
            }
            row.extend(vec![
                txt(
                    k.cx,
                    label,
                    weight(k.lk.body, 14.0, 500),
                    colour::FONT,
                    Some(1),
                ),
                k.icons
                    .node("caret-down", 11.0, true, color(colour::FONT_QUIET)),
            ]);
            Node::hstack(Align::Center, Some(6.0), row)
                .padding(ins(0.0, 14.0, 0.0, 12.0))
                .frame(None, Some(34.0), Alignment::CENTER)
                .background(Node::rect(color(colour::AREA), 10.0), Alignment::CENTER)
                .key(key)
                .on_tap(Action::from(key))
        };
        kids.push(
            Node::hstack(
                Align::Center,
                Some(8.0),
                vec![
                    pill(f, "pill:filter", None),
                    pill(s, "pill:sort", Some(sort_icon)),
                ],
            )
            .padding(ins(10.0, k.lk.edge, 0.0, 0.0)),
        );
    }
    kids.push(if loading {
        placeholders(k)
            .padding(ins(20.0, 0.0, 0.0, 0.0))
            .reveal_as("page.loading")
    } else if failed {
        empty_state(
            k,
            "hard-drive-x",
            "Server ist abgetaucht",
            "Der Server antwortet nicht. Läuft er noch, oder hängt das WLAN?",
            Some(("Erneut versuchen", "retry")),
        )
    } else if tiles.is_empty() {
        let (t, x, button) = empty.cloned().unwrap_or_else(|| {
            (
                "Nichts in diesem Genre".into(),
                "In diesem Genre gibt es auf deinem Server gerade keine Filme und Serien.".into(),
                None,
            )
        });
        let icon = if empty.is_some() {
            if button.as_ref().is_some_and(|(_, a)| a == "reset-filter") {
                "funnel"
            } else {
                "tray"
            }
        } else {
            "tag"
        };
        empty_state(
            k,
            icon,
            &t,
            &x,
            button.as_ref().map(|(l, a)| (l.as_str(), a.as_str())),
        )
    } else {
        grid(k, tiles, "tile").padding(ins(20.0, 0.0, 0.0, 0.0))
    });
    Node::vstack(Align::Start, Some(0.0), kids).padding(ins(58.0, 0.0, 0.0, 0.0))
}

/// A TMDB picture as the hub loads it (`hit.poster(width: 342)`, `hit.backdrop(width: 1280)`).
fn remote(
    address: Option<&str>,
    kind: swiftly_vm::ImageKind,
    w: u32,
    h: u32,
) -> Option<swiftly_vm::ImageRef> {
    address.map(|a| swiftly_vm::ImageRef {
        address: a.to_owned(),
        kind,
        wanted_width: w,
        wanted_height: h,
    })
}

/// The Seerr tiles in rows of `per`, keys `{prefix}:{index}` (the search block and the person page use it).
pub(crate) fn seerr_grid(k: &Kit, tiles: &[SeerrTile], per: usize, prefix: &str) -> Node {
    let per = per.max(1);
    let rows: Vec<Node> = tiles
        .chunks(per)
        .enumerate()
        .map(|(r, c)| {
            Node::hstack(
                Align::Start,
                Some(16.0),
                c.iter()
                    .enumerate()
                    .map(|(i, t)| seerr_tile(k, t, &format!("{prefix}:{}", r * per + i)))
                    .collect(),
            )
        })
        .collect();
    Node::vstack(Align::Start, Some(20.0), rows)
}

fn state_colour(s: SeerrState) -> swiftly_design::Colour {
    match s {
        SeerrState::WaitsSharing => colour::ORIGINAL_WARNING,
        SeerrState::Loads | SeerrState::PartWayPresent => colour::MARK_ACCENT,
        SeerrState::Present => colour::FONT,
        _ => colour::FONT_QUIET,
    }
}

/// `SeerrTile`: picture at 45 %, a status capsule bottom left, title 13 medium, "2019 · Serie" 12 very quiet.
pub(crate) fn seerr_tile(k: &Kit, t: &SeerrTile, key: &str) -> Node {
    let (w, h) = (150.0, 225.0);
    let mut img = k
        .art
        .node_for(
            remote(t.poster.as_deref(), swiftly_vm::ImageKind::Poster, 342, 513).as_ref(),
            false,
            &t.hit.title,
            w,
            h,
            10.0,
        )
        .opacity(0.45, swiftly_ui::Motion::Instant);
    if let Some(word) = &t.short_word {
        let c = state_colour(t.hit.state);
        let icon = match t.hit.state {
            SeerrState::WaitsSharing => "clock",
            SeerrState::Loads => "arrow-circle-down",
            _ => "circle-half",
        };
        let cap = Node::hstack(
            Align::Center,
            Some(4.0),
            vec![
                k.icons.node(icon, 10.0, false, color(colour::REASON)),
                txt(
                    k.cx,
                    &word.to_uppercase(),
                    swiftly_design::TextStyle {
                        size: 10.0,
                        weight: 600,
                        tracking: 1.0,
                        ..k.lk.small
                    },
                    colour::REASON,
                    Some(1),
                ),
            ],
        )
        .padding(ins(3.0, 6.0, 3.0, 8.0))
        .background(Node::rect(color(c), 8.0), Alignment::CENTER)
        .padding(ins(0.0, 8.0, 8.0, 0.0));
        img = img.overlay(cap, Alignment::BOTTOM_LEADING);
    }
    let kind = if t.hit.art == "tv" { "Serie" } else { "Film" };
    let sub = t
        .hit
        .year
        .map_or(kind.to_owned(), |y| format!("{y} \u{b7} {kind}"));
    Node::vstack(
        Align::Start,
        Some(8.0),
        vec![
            img,
            Node::vstack(
                Align::Start,
                Some(1.0),
                vec![
                    txt(
                        k.cx,
                        &t.hit.title,
                        weight(k.lk.tile, 13.0, 500),
                        colour::FONT_QUIET,
                        Some(1),
                    )
                    .frame(Some(w), None, Alignment::LEADING),
                    txt(
                        k.cx,
                        &sub,
                        weight(k.lk.small, 12.0, 400),
                        colour::FONT_VERY_QUIET,
                        Some(1),
                    )
                    .frame(Some(w), None, Alignment::LEADING),
                ],
            ),
        ],
    )
    .key(key)
    .on_tap(Action::from(key))
    .a11y_label(
        swiftly_ui::a11y::Role::Button,
        format!("{}, {}", t.hit.title, t.announcement),
    )
    .hover_scale(swiftly_ui::feel::HOVER_TILE_SCALE)
    .press_style(PressStyle::Button)
}

fn discover_page(k: &Kit, d: &DiscoverPart) -> Node {
    let count = txt(
        k.cx,
        &d.tiles.len().to_string(),
        weight(k.lk.small, 13.0, 500),
        colour::FONT_VERY_QUIET,
        Some(1),
    );
    let per = (((k.env.size.w - 2.0 * k.lk.edge + 16.0) / 166.0).floor() as usize).max(1);
    let grid = seerr_grid(k, &d.tiles, per, "seerr");
    Node::vstack(
        Align::Start,
        Some(0.0),
        vec![
            header(k, "Über Seerr anfragen", Some(count)),
            grid.padding(ins(18.0, k.lk.edge, 0.0, 0.0)),
        ],
    )
    .padding(ins(58.0, 0.0, 0.0, 0.0))
}

/// The season list of a series request (`SeerrDetailView.seasonList`): rows of 38 (checkbox, name, "· episodes"), as tall as
/// its rows at most 380 and 320 wide, raised with a hairline and no shadow. It floats on the page (`season_overlay`).
fn season_panel(k: &Kit, p: &SeerrPart) -> Node {
    let rows: Vec<Node> = p
        .seasons
        .iter()
        .map(|r| {
            let key = format!("season:{}", r.number);
            let on = r.selected;
            let fg = if r.requestable {
                colour::FONT
            } else {
                colour::FONT_VERY_QUIET
            };
            let (glyph, tint) = if !r.requestable {
                ("check-circle", colour::FONT_VERY_QUIET)
            } else if on {
                ("check-square.fill", colour::MARK_ACCENT)
            } else {
                ("square", colour::FONT_VERY_QUIET)
            };
            let mut kids = vec![
                k.icons
                    .node(glyph, 17.0, !on && r.requestable, color(tint))
                    .frame(Some(22.0), None, Alignment::CENTER),
                txt(k.cx, &r.title, weight(k.lk.body, 14.0, 500), fg, Some(1)),
            ];
            if let Some(e) = r.episodes.as_ref().or(r.note.as_ref()) {
                kids.push(txt(
                    k.cx,
                    &format!("\u{b7} {e}"),
                    weight(k.lk.small, 12.0, 400),
                    colour::FONT_VERY_QUIET,
                    Some(1),
                ));
            }
            let n = Node::hstack(Align::Center, Some(10.0), kids)
                .padding(ins(0.0, 14.0, 0.0, 14.0))
                .frame(Some(320.0), Some(38.0), Alignment::LEADING)
                .key(key.as_str());
            if r.requestable {
                n.on_tap(Action::from(key.as_str()))
                    .hover_surface(rgba(colour::FONT, 0.08), 8.0)
            } else {
                n
            }
        })
        .collect();
    let height = (38.0 * p.seasons.len() as f32).clamp(38.0, 380.0);
    let list = Node::vstack(Align::Start, Some(0.0), rows);
    Node::scroll(Axis::Vertical, None, list)
        .frame(Some(320.0), Some(height), Alignment::TOP_LEADING)
        .background(
            Node::flexible()
                .paint(Paint::Fill {
                    color: color(colour::RAISED),
                    radius: 12.0,
                })
                .paint(Paint::Stroke {
                    color: color(colour::MARGIN),
                    width: 1.0,
                    radius: 12.0,
                }),
            Alignment::CENTER,
        )
        .appear_from(swiftly_ui::feel::PANEL_EXPAND_SCALE, 0.0)
        .exit_to(swiftly_ui::feel::PANEL_EXPAND_SCALE, 0.0)
        .scaled(1.0, swiftly_ui::feel::leap())
        .opacity(1.0, swiftly_ui::feel::leap())
        .scale_about(0.0, 0.0)
        .key("season-panel")
}

/// The season list on the page, not in the block (`SeerrDetailView.body`): a catcher below it so a click beside it
/// closes it, the list at the left edge below the request button (`titleHeight + 98 + 182 + button + 10`).
fn season_overlay(k: &Kit, p: &SeerrPart) -> Node {
    let (w, h) = (k.env.size.w, k.env.size.h);
    let catcher = Node::rect(Color::new(0.0, 0.0, 0.0, 0.001), 0.0)
        .on_tap_silent(Action::from("seasons-close"))
        .key("seasons-catcher");
    let top = 44.0 + 98.0 + 182.0 + 56.0 + 10.0;
    let panel = season_panel(k, p).padding(ins(top, k.lk.edge, 0.0, 0.0));
    Node::zstack(Alignment::TOP_LEADING, vec![catcher, panel])
        .frame(Some(w), Some(h), Alignment::TOP_LEADING)
        .key("seasons-overlay")
}

/// The request button's words (`SeerrDetailView.buttonText`): a series names the step, the count is on the button.
fn request_label(p: &SeerrPart) -> String {
    if p.running || !p.hit.is_series() {
        return p.button_text.clone();
    }
    let n = p.seasons.iter().filter(|r| r.selected).count();
    if !p.sheet_open || n == 0 {
        "Staffeln w\u{e4}hlen".to_owned()
    } else {
        format!("{n} Staffeln anfragen")
    }
}

fn seerr_page(k: &Kit, p: &SeerrPart, address: &str) -> Node {
    let (w, edge) = (k.env.size.w, k.lk.edge);
    let c = state_colour(p.state);
    let mut details = vec![txt(
        k.cx,
        &p.secondary_line,
        weight(k.lk.small, 12.0, 400),
        colour::FONT_QUIET,
        Some(1),
    )];
    if let Some(r) = p.rating {
        details.push(Node::hstack(
            Align::Center,
            Some(4.0),
            vec![
                k.icons.node("star.fill", 11.0, false, color(colour::FONT)),
                txt(
                    k.cx,
                    &format!("{r:.1}"),
                    weight(k.lk.small, 13.0, 500),
                    colour::FONT,
                    Some(1),
                ),
            ],
        ));
    }
    details.push(txt(
        k.cx,
        &p.status_word,
        weight(k.lk.small, 13.0, 500),
        c,
        Some(1),
    ));
    let desc = p.description.clone().unwrap_or_default();
    let mut btn = Vec::new();
    if p.can_request {
        btn.push(primary(
            k,
            &request_label(p),
            Some(if p.button_checked { "check" } else { "plus" }),
            320.0,
            "press",
            !p.running,
        ));
    }
    if let Some(e) = &p.error {
        btn.push(
            txt(
                k.cx,
                e,
                weight(k.lk.small, 12.0, 400),
                colour::ORIGINAL_WARNING,
                Some(2),
            )
            .frame(Some(240.0), None, Alignment::LEADING),
        );
    }
    let text = Node::vstack(
        Align::Start,
        Some(0.0),
        vec![
            txt(
                k.cx,
                &p.hit.title,
                weight(k.lk.rail, 30.0, 700),
                colour::FONT,
                Some(1),
            )
            .frame(Some(640.0), Some(42.0), Alignment::LEADING),
            Node::hstack(Align::Center, Some(14.0), details)
                .frame(Some(640.0), Some(20.0), Alignment::LEADING)
                .padding(ins(12.0, 0.0, 0.0, 0.0)),
            txt(
                k.cx,
                &desc,
                weight(k.lk.body, 15.0, 400),
                colour::FONT_QUIET,
                Some(3),
            )
            .frame(Some(640.0), Some(66.0), Alignment::TOP_LEADING)
            .padding(ins(18.0, 0.0, 0.0, 0.0)),
            Node::hstack(Align::Center, Some(12.0), btn)
                .frame(Some(640.0), Some(48.0), Alignment::LEADING)
                .padding(ins(24.0, 0.0, 0.0, 0.0)),
        ],
    )
    .padding(ins(150.0, edge, 0.0, 0.0));
    let hero = fill_frame(text, Alignment::TOP_LEADING)
        .frame(Some(w), Some(350.0), Alignment::TOP_LEADING)
        .background(
            backdrop(
                k,
                remote(
                    p.backdrop.as_deref(),
                    swiftly_vm::ImageKind::Backdrop,
                    1280,
                    720,
                )
                .as_ref(),
                &p.hit.title,
                w,
                350.0,
                350.0 * 1.62,
            ),
            Alignment::TOP_LEADING,
        );
    let mut kids = vec![hero];
    if let Some(n) = &p.note {
        kids.push(
            txt(
                k.cx,
                n,
                weight(k.lk.body, 15.0, 400),
                colour::FONT_QUIET,
                Some(3),
            )
            .padding(ins(13.0, 14.0, 13.0, 14.0))
            .frame(Some(420.0), None, Alignment::LEADING)
            .background(Node::rect(color(colour::AREA), 16.0), Alignment::CENTER)
            .padding(ins(16.0, edge, 0.0, 0.0)),
        );
    }
    if p.disturbed {
        kids.push(empty_state(
            k,
            "hard-drive-x",
            "Server ist abgetaucht",
            &format!("{address} antwortet nicht. L\u{e4}uft er noch, oder h\u{e4}ngt das WLAN?"),
            Some(("Erneut versuchen", "retry")),
        ));
    }
    let mut rails = Vec::new();
    if !p.cast.is_empty() {
        let cast: Vec<swiftly_vm::CastTile> = p
            .cast
            .iter()
            .enumerate()
            .map(|(i, c)| swiftly_vm::CastTile {
                id: format!("c{i}"),
                name: c.name.clone(),
                role: c.role.clone(),
                image: remote(c.image.as_deref(), swiftly_vm::ImageKind::Poster, 185, 185),
            })
            .collect();
        rails.push(crate::detail_screen::cast_rail(k, &cast));
    }
    if !p.similar.is_empty() {
        let tiles: Vec<Node> = p
            .similar
            .iter()
            .enumerate()
            .map(|(i, t)| seerr_tile(k, t, &format!("similar:{i}")))
            .collect();
        rails.push(crate::detail_screen::segment(
            k,
            "similar",
            "Ähnliche Titel",
            tiles,
            16.0,
            225.0 + 8.0 + 36.0,
        ));
    }
    kids.push(Node::vstack(Align::Start, Some(26.0), rails).padding(ins(26.0, 0.0, 0.0, 0.0)));
    Node::vstack(Align::Start, Some(0.0), kids)
}

fn page(d: &Data, sx: &UiState, env: &Env, cx: &Cx, art: &Art, icons: &Icons) -> Node {
    let k = Kit {
        cx,
        env,
        lk: look(env),
        art,
        icons,
    };
    let (content, title) = match &d.body {
        Body::Person(p, a) => (person_page(&k, p, a), p.name.clone()),
        Body::Playlist(p) => (playlist_page(&k, p), p.title.clone()),
        Body::Grid {
            name,
            tiles,
            loading,
            failed,
            pills,
            empty,
        } => (
            grid_page(
                &k,
                name,
                tiles,
                *loading,
                *failed,
                pills.as_ref(),
                empty.as_ref(),
            ),
            name.clone(),
        ),
        Body::Discover(p) => (discover_page(&k, p), "Über Seerr anfragen".to_owned()),
        Body::Seerr(p) => (seerr_page(&k, p, &d.address), p.hit.title.clone()),
    };
    let scroll = Node::scroll(
        Axis::Vertical,
        None,
        wide(
            content.padding(ins(0.0, 0.0, 40.0, 0.0)),
            Alignment::TOP_LEADING,
        ),
    )
    .key("page-scroll");
    // The playlist page draws the look's glow behind its scroll view (`PlaylistPage.swift:105`).
    let scroll = if matches!(d.body, Body::Playlist(_)) {
        crate::look_glow::behind(
            fill_frame(scroll, Alignment::TOP_LEADING),
            sx.glow,
            env.size.w,
        )
    } else {
        scroll
    };
    let mut page = fill_frame(scroll, Alignment::TOP_LEADING)
        .overlay(top_bar(&k, &title, sx.header), Alignment::TOP);
    if let Body::Seerr(p) = &d.body
        && p.sheet_open
        && p.hit.is_series()
    {
        page = page.overlay(season_overlay(&k, p), Alignment::TOP_LEADING);
    }
    if let Some(menu) = sx.menu.overlay(cx, env) {
        page = page.overlay(menu, Alignment::TOP_LEADING);
    }
    ground(page)
}

// ---- demo data --------------------------------------------------------------------------------------------------------

fn item(id: &str, name: &str, kind: &str, year: i64) -> Item {
    Item {
        id: id.into(),
        name: name.into(),
        type_: Some(kind.into()),
        production_year: Some(year),
        ..Item::default()
    }
}

fn demo_items() -> Vec<Item> {
    [
        "Nordlicht",
        "Der Weg zurück",
        "Stille Wasser",
        "Hafenlichter",
        "Die Lotsin",
        "Nebelbank",
        "Letzte Fähre",
        "Salzwind",
        "Kaltes Licht",
        "Das Wrack",
        "Mara",
        "Ebbe",
    ]
    .iter()
    .enumerate()
    .map(|(i, n)| {
        item(
            &format!("t{i}"),
            n,
            if i % 3 == 2 { "Series" } else { "Movie" },
            2010 + i as i64,
        )
    })
    .collect()
}

fn demo_hit(i: usize, state: SeerrState) -> SeerrHit {
    let names = [
        "Nachtschicht",
        "Küstenwache",
        "Der Leuchtturm",
        "Sturmfeuer",
        "Blaue Stunde",
        "Flutwelle",
    ];
    SeerrHit {
        id: 100 + i as i64,
        art: if i.is_multiple_of(2) {
            "tv".into()
        } else {
            "movie".into()
        },
        title: names[i % names.len()].into(),
        year: Some(2015 + i as i64),
        poster_path: None,
        backdrop_path: None,
        state,
    }
}

/// A page screen: a UI over the view model of its kind, pushed over a transparent root.
pub struct PageScreen {
    host: Pushed<Data>,
    kind: Kind,
    person: Option<PersonVm>,
    playlist: Option<PlaylistVm>,
    seerr: Option<SeerrVm>,
    grid: (String, Vec<Tile>, bool, bool),
    log: Vec<String>,
    play_req: Option<crate::live_play::PlayRequest>,
    roll: usize,
    art: PersonArt,
    live: Option<PersonLive>,
    /// The live load of a genre, collection or playlist (`None`: scripted demo data).
    grid_live: Option<GridLive>,
    /// The live collection page's shelf (filter, sort, paging).
    shelf: Option<Shelf>,
    tapped: Option<Tile>,
    /// The Seerr flow of a live page (search block, title page, the person's request rail); none without a session.
    flow: Option<crate::seerr_flow::Flow>,
    /// The Seerr title that was tapped, once.
    seerr_tapped: Option<SeerrHit>,
    /// The person's Seerr filmography was handed to the model.
    films_applied: bool,
    /// The list changes already reloaded for.
    seen_changes: u64,
    locale: Locale,
}

impl PageScreen {
    /// A page of `kind` over demo data in `scenario` (`Loading`: the loading state; `Offline`: the server did not answer;
    /// `Empty`: nothing there; `Ready`: filled).
    pub fn new(env: Env, cx: Cx, kind: Kind, scenario: Scenario) -> PageScreen {
        let locale = Locale::parse("de");
        let (mut person, mut playlist, mut seerr) = (None, None, None);
        let mut grid = (
            "Drama".to_owned(),
            Vec::new(),
            scenario == Scenario::Loading,
            scenario == Scenario::Offline,
        );
        let mut tiles = demo_items().iter().map(tile_of).collect::<Vec<_>>();
        if scenario == Scenario::Empty {
            tiles.clear();
        }
        match kind {
            Kind::Person => {
                let mut vm = PersonVm::new(
                    locale,
                    Person {
                        id: "p0".into(),
                        name: "Mara Brandt".into(),
                        role: Some("Lotsin".into()),
                        type_: Some("Actor".into()),
                        primary_image_tag: None,
                    },
                    Some("Nordlicht".into()),
                );
                match scenario {
                    Scenario::Loading => {}
                    Scenario::Offline => {
                        vm.loaded(None, None);
                        vm.seerr_loaded(&[]);
                    }
                    Scenario::Empty => {
                        vm.loaded(Some(PersonDetail::default()), Some((Vec::new(), 0)));
                        vm.seerr_loaded(&[]);
                    }
                    Scenario::Ready | Scenario::Worst => {
                        let bio = "Mara Brandt wuchs an der Küste auf und stand mit siebzehn zum ersten Mal vor der Kamera. Seitdem spielt sie vor allem Frauen, die zwischen Pflicht und Heimweh wählen müssen. Für „Nordlicht“ lernte sie ein halbes Jahr lang, ein Lotsenboot zu steuern. Zwischen den Dreharbeiten schreibt sie Hörspiele, die im Radio laufen, und sie unterrichtet jeden Winter eine Woche an einer Schauspielschule im Norden. Sie lebt mit ihrer Familie in Hamburg, fährt im Sommer lieber mit dem Boot als mit dem Auto und sagt von sich, dass sie am liebsten dort arbeitet, wo es nach Salz riecht.";
                        vm.loaded(
                            Some(PersonDetail {
                                born: Some("12. März 1984".into()),
                                places: vec!["Kiel".into()],
                                biography: Some(bio.into()),
                                tmdb_id: Some(7),
                            }),
                            Some((demo_items().into_iter().take(8).collect(), 8)),
                        );
                        vm.seerr_loaded(&[swiftly_vm::RequestableHit {
                            id: "9".into(),
                            title: "Sturmfeuer".into(),
                            already_present: false,
                        }]);
                    }
                }
                person = Some(vm);
            }
            Kind::Playlist => {
                let mut vm = PlaylistVm::new(
                    locale,
                    item("pl1", "Wochenende", "Playlist", 2024),
                    Some("movies".into()),
                );
                match scenario {
                    Scenario::Loading => {}
                    Scenario::Offline => vm.loaded(None),
                    Scenario::Empty => vm.loaded(Some(Vec::new())),
                    Scenario::Ready | Scenario::Worst => {
                        vm.loaded(Some(demo_items().into_iter().take(9).collect()))
                    }
                }
                playlist = Some(vm);
            }
            Kind::Genre => grid.1 = tiles,
            Kind::Collection => {
                "Nordlicht-Reihe".clone_into(&mut grid.0);
                grid.1 = tiles;
            }
            Kind::SeerrSearch | Kind::SeerrDetail => {
                let mut vm = SeerrVm::new(locale);
                let hits: Vec<SeerrHit> = [
                    SeerrState::Opened,
                    SeerrState::WaitsSharing,
                    SeerrState::Loads,
                    SeerrState::PartWayPresent,
                    SeerrState::Opened,
                    SeerrState::Deleted,
                ]
                .iter()
                .enumerate()
                .map(|(i, s)| demo_hit(i, *s))
                .collect();
                if scenario != Scenario::Empty {
                    let _ = vm.handle(SeerrIntent::SearchLoaded {
                        term: "licht".into(),
                        hits: hits.clone(),
                    });
                }
                if kind == Kind::SeerrDetail {
                    let _ = vm.handle(SeerrIntent::Open(hits[0].clone()));
                    let detail = (scenario == Scenario::Ready).then(|| SeerrDetail {
                        description: Some("Auf einer Nachtschicht im Hafen verschwindet ein Container. Die Zöllnerin Ilse folgt der Spur bis in eine Stadt, die sie lange nicht mehr gesehen hat.".into()),
                        genres: vec!["Drama".into(), "Krimi".into()],
                        runtime: Some(118),
                        rating: Some(7.8),
                        seasons: (1..=3).map(|n| SeerrSeason { number: n, episodes: 8, state: if n == 1 { SeerrState::Present } else { SeerrState::Opened } }).collect(),
                        cast: (0..5).map(|i| SeerrPerson { id: i, name: ["Mara Brandt", "Jonas Keller", "Ilse Vogel", "Tom Albers", "Nina Sommer"][i as usize].into(), role: Some("Rolle".into()), image_path: None }).collect(),
                        similar_one: hits[1..4].to_vec(),
                        state: Some(SeerrState::Opened),
                    });
                    let _ = vm.handle(SeerrIntent::DetailLoaded(detail));
                }
                seerr = Some(vm);
            }
        }
        let art = Rc::new(Art::new(&cx));
        let icons = Icons::new(&cx, env.scale);
        let art2 = Rc::clone(&art);
        let data = Data {
            body: Self::body(
                kind,
                &person,
                &playlist,
                seerr.as_ref(),
                &grid,
                &PersonArt::default(),
                false,
                None,
            ),
            address: String::new(),
        };
        let host = Pushed::new(env, cx, data, art, true, move |d, sx, env, cx| {
            page(d, sx, env, cx, &art2, &icons)
        });
        let mut s = PageScreen {
            host,
            kind,
            person,
            playlist,
            seerr,
            grid,
            log: Vec::new(),
            play_req: None,
            roll: 0,
            art: PersonArt::default(),
            live: None,
            grid_live: None,
            shelf: None,
            tapped: None,
            flow: None,
            seerr_tapped: None,
            films_applied: false,
            seen_changes: crate::desk::list_changes(),
            locale: Locale::parse("de"),
        };
        s.refresh();
        s
    }

    /// The person page over the live server (the Mac's `PersonView` with its `PersonController`): name, role and the
    /// cast picture stand from the tap, everything else fades in once `item(person)` and `Items?PersonIds=` answered.
    pub fn person_live(env: Env, cx: Cx, w: &crate::live::Wiring, tap: PersonTap) -> PageScreen {
        let mut s = PageScreen::new(env, cx, Kind::Person, Scenario::Loading);
        let locale = w.core.host().locale;
        s.locale = locale.clone();
        s.flow = crate::seerr_flow::Live::stored(&w.core)
            .map(|b| crate::seerr_flow::Flow::new(b, locale.clone()));
        s.person = Some(PersonVm::new(
            locale.clone(),
            Person {
                id: tap.id.clone(),
                name: tap.name.clone(),
                role: tap.role.clone(),
                type_: Some("Actor".into()),
                primary_image_tag: None,
            },
            tap.origin.clone(),
        ));
        s.art = PersonArt {
            portrait: tap.image.clone(),
            ..PersonArt::default()
        };
        if let Ok(client) = w.core.client_for(&w.account) {
            let rx = crate::live_person::start(&w.core, &w.account, &tap.id);
            s.live = Some(PersonLive {
                rx,
                client,
                id: tap.id,
                locale,
                core: std::sync::Arc::clone(&w.core),
                account: w.account.clone(),
            });
        }
        s.refresh();
        s
    }

    /// A genre page over the live server (`GenreView`): the newest movies and series of the genre
    /// (`model.title(genre:limit: 200)`), the chip's name as the title.
    pub fn genre_live(env: Env, cx: Cx, w: &crate::live::Wiring, name: &str) -> PageScreen {
        let mut s = PageScreen::new(env, cx, Kind::Genre, Scenario::Loading);
        s.grid = (name.to_owned(), Vec::new(), true, false);
        if let Ok(client) = w.core.client_for(&w.account) {
            let (tx, rx) = crate::login_screen::Pending::channel();
            let genre = name.to_owned();
            let c = w.core.client_for(&w.account).ok();
            w.core.spawn(async move {
                let Some(c) = c else {
                    let _ = tx.send(None);
                    return;
                };
                let _ = tx.send(swiftly_library::client_ext::title_genre(&c, &genre, 200).await);
            });
            s.grid_live = Some(GridLive {
                rx: Some(rx),
                client,
                locale: w.core.host().locale,
            });
        } else {
            s.grid.2 = false;
            s.grid.3 = true;
        }
        s.refresh();
        s
    }

    /// A collection page over the live server (`CollectionDetailPage`): a library page with the collection as its
    /// source, the name as the title, the filter and sort pills, sorted by year at first (the Mac's
    /// `shelf.sorting = .erscheinung`). `art` says whether its movies or its shows are meant (`None`: everything in
    /// it). Sort and filter are not remembered.
    pub fn collection_live(
        env: Env,
        cx: Cx,
        w: &crate::live::Wiring,
        id: &str,
        name: &str,
        art: Option<&str>,
    ) -> PageScreen {
        let mut s = PageScreen::new(env, cx, Kind::Collection, Scenario::Loading);
        s.grid = (name.to_owned(), Vec::new(), true, false);
        let spec = LibrarySpec {
            source: ShelfSource::new(Some(id), art, true, &[]),
            genre: None,
            remember_name: None,
        };
        match LibraryVm::new(
            std::sync::Arc::clone(&w.core.net),
            w.core.host(),
            std::sync::Arc::clone(&w.core.kv),
            spec,
            Some(w.account.clone()),
        ) {
            Ok(vm) => {
                vm.send(LibraryIntent::SetSorting {
                    sorting: Sorting::Erscheinung,
                });
                s.shelf = Some(Shelf {
                    vm,
                    art: art.map(str::to_owned),
                    asked: None,
                    shown: 0,
                });
                if let Ok(client) = w.core.client_for(&w.account) {
                    s.grid_live = Some(GridLive {
                        rx: None,
                        client,
                        locale: w.core.host().locale,
                    });
                }
            }
            Err(_) => {
                s.grid.2 = false;
                s.grid.3 = true;
            }
        }
        s.refresh();
        s
    }

    /// A playlist page over the live server (`PlaylistPage`): its video entries in the playlist's order.
    pub fn playlist_live(
        env: Env,
        cx: Cx,
        w: &crate::live::Wiring,
        id: &str,
        name: &str,
        art: &str,
    ) -> PageScreen {
        let mut s = PageScreen::new(env, cx, Kind::Playlist, Scenario::Loading);
        let locale = w.core.host().locale;
        s.playlist = Some(PlaylistVm::new(
            locale.clone(),
            Item {
                id: id.to_owned(),
                name: name.to_owned(),
                ..Item::default()
            },
            Some(art.to_owned()),
        ));
        if let Ok(client) = w.core.client_for(&w.account) {
            let (tx, rx) = crate::login_screen::Pending::channel();
            let id = id.to_owned();
            let c = w.core.client_for(&w.account).ok();
            w.core.spawn(async move {
                let Some(c) = c else {
                    let _ = tx.send(None);
                    return;
                };
                let _ = tx.send(
                    swiftly_library::client_ext::playlist_entries_video(&c, &id, false)
                        .await
                        .ok(),
                );
            });
            s.grid_live = Some(GridLive {
                rx: Some(rx),
                client,
                locale,
            });
        } else if let Some(p) = s.playlist.as_mut() {
            p.loaded(None);
        }
        s.refresh();
        s
    }

    /// Takes the answer of a genre, collection or playlist load.
    fn poll_grid(&mut self) {
        let Some(l) = self.grid_live.as_mut() else {
            return;
        };
        let Some(rx) = &l.rx else { return };
        let Ok(got) = rx.0.try_recv() else { return };
        l.rx = None;
        match self.kind {
            Kind::Playlist => {
                if let Some(vm) = self.playlist.as_mut() {
                    self.art.tiles = got
                        .as_deref()
                        .map(|items| swiftly_vm::poster_tiles(items, &l.client, l.locale.clone()))
                        .unwrap_or_default();
                    vm.loaded(got);
                }
            }
            _ => match got {
                Some(items) => {
                    let tiles = swiftly_vm::poster_tiles(&items, &l.client, l.locale.clone());
                    self.art.tiles = tiles.clone();
                    self.grid.1 = tiles;
                    self.grid.2 = false;
                }
                None => {
                    self.grid.2 = false;
                    self.grid.3 = true;
                }
            },
        }
    }

    /// Takes what the collection's shelf has loaded: the tiles, the loading and failure states, and asks for the next
    /// page when the last row is near (`shelf.solvesLoadMoreOut`).
    fn poll_shelf(&mut self) {
        let Some(sh) = self.shelf.as_mut() else {
            return;
        };
        let status = sh.vm.status();
        let grid = sh.vm.grid();
        if sh.shown != grid.version {
            sh.shown = grid.version;
            self.art.tiles = grid.tiles.clone();
            self.grid.1 = grid.tiles.clone();
        }
        self.grid.2 = matches!(status.status, LibraryStatus::Loading);
        self.grid.3 = matches!(status.status, LibraryStatus::Offline) && grid.tiles.is_empty();
        if status.more_available && !status.loading_more && !grid.tiles.is_empty() {
            let last = format!("tile:{}", grid.tiles.len() - 1);
            let h = self.host.ui().env().size.h;
            let near = self
                .host
                .ui()
                .frame_of(last.as_str())
                .is_some_and(|f| f[1] < h + 420.0);
            if near && sh.asked.as_ref() != Some(&grid.tiles[grid.tiles.len() - 1].id) {
                sh.asked = Some(grid.tiles[grid.tiles.len() - 1].id.clone());
                sh.vm.send(LibraryIntent::LoadMore);
            }
        }
    }

    /// The pills and the empty state of a live collection page.
    fn shelf_view(&self) -> Option<(Pills, EmptyNote)> {
        let sh = self.shelf.as_ref()?;
        let st = sh.vm.status();
        let label = |f: LibraryFilter| {
            crate::library_screen::FILTERS
                .iter()
                .find(|(g, _)| *g == f)
                .map_or("", |(_, l)| *l)
        };
        let sort = crate::library_screen::SORTINGS
            .iter()
            .find(|(g, _)| *g == st.sorting)
            .map_or("", |(_, l)| *l);
        let narrowed = st.filter != LibraryFilter::All;
        let empty = if narrowed {
            (
                "Nichts gefunden".to_owned(),
                format!(
                    "Unter \u{201E}{}\u{201C} liegt gerade nichts. Nimm einen anderen Filter.",
                    label(st.filter)
                ),
                Some(("Filter zurücksetzen".to_owned(), "reset-filter".to_owned())),
            )
        } else {
            (
                "Hier ist noch nichts".to_owned(),
                "Sobald in dieser Sammlung etwas liegt, taucht es hier auf.".to_owned(),
                Some(("Aktualisieren".to_owned(), "refresh".to_owned())),
            )
        };
        Some((
            Pills {
                filter: label(st.filter).to_owned(),
                sort: sort.to_owned(),
                sort_icon: sorting_icon(st.sorting),
            },
            empty,
        ))
    }

    /// Takes the answer of the live load: the view model gets exactly what the Mac's controller gives it, the page
    /// its pictures.
    fn poll_live(&mut self) {
        // After the player, a state change or a watchlist change the page loads again (`listenRefresh`); what it shows
        // stays until the answer is there.
        let changes = crate::desk::list_changes();
        if changes != self.seen_changes {
            self.seen_changes = changes;
            if let Some(l) = self.live.as_mut()
                && l.rx.is_none()
            {
                l.rx = crate::live_person::start(&l.core, &l.account, &l.id);
                self.films_applied = false;
            }
        }
        let Some(l) = self.live.as_mut() else { return };
        let Some(rx) = &l.rx else { return };
        let Ok(got) = rx.0.try_recv() else { return };
        l.rx = None;
        let Some(vm) = self.person.as_mut() else {
            return;
        };
        vm.loaded(got.detail, got.page);
        // Seerr's filmography comes next when Seerr is connected (the rail waits for it); else the page may say
        // "nothing else".
        match (self.flow.as_mut(), vm.tmdb_id()) {
            (Some(f), Some(id)) => {
                f.ask_films(id);
                self.films_applied = false;
            }
            _ => vm.seerr_loaded(&[]),
        }
        let titles = vm.part().titles.clone();
        self.art.tiles = swiftly_vm::poster_tiles(&titles, &l.client, l.locale.clone());
        self.art.banner = crate::live_person::banner(&titles, &l.client);
        if let Some(p) = crate::live_person::portrait(&l.client, &l.id, got.tag.as_deref()) {
            self.art.portrait = Some(p);
        }
    }

    /// Runs the Seerr timers and replies; hands the person's filmography to the model once it came.
    fn poll_flow(&mut self) {
        let Some(f) = self.flow.as_mut() else { return };
        f.poll(std::time::Instant::now());
        if self.kind != Kind::Person || self.films_applied {
            return;
        }
        let (Some(films), Some(vm)) = (f.films(), self.person.as_mut()) else {
            return;
        };
        self.films_applied = true;
        let hits: Vec<swiftly_vm::RequestableHit> = films
            .iter()
            .map(|h| swiftly_vm::RequestableHit {
                id: h.id.to_string(),
                title: h.title.clone(),
                already_present: h.state.already_present(),
            })
            .collect();
        vm.seerr_loaded(&hits);
        let kept = &vm.part().requestable;
        let shown: Vec<SeerrHit> = films
            .iter()
            .filter(|h| kept.contains(&h.id.to_string()))
            .cloned()
            .collect();
        let mut scratch = SeerrVm::new(self.locale.clone());
        let _ = scratch.handle(SeerrIntent::SearchLoaded {
            term: String::new(),
            hits: shown,
        });
        self.art.requests = scratch.discover().tiles.clone();
    }

    /// The Seerr title that was tapped (a search tile, a suggestion, a request of the person page), once.
    pub fn take_seerr(&mut self) -> Option<SeerrHit> {
        self.seerr_tapped.take()
    }

    /// The Seerr title page over the live Seerr session (the Mac's `SeerrDetailView`): the page asks `detail` as it
    /// opens. `None` when Seerr is not connected.
    pub fn seerr_live(
        env: Env,
        cx: Cx,
        w: &crate::live::Wiring,
        hit: SeerrHit,
    ) -> Option<PageScreen> {
        let backend = crate::seerr_flow::Live::stored(&w.core)?;
        let flow = crate::seerr_flow::Flow::new(backend, w.core.host().locale);
        let mut s = PageScreen::seerr_over(env, cx, flow, hit);
        s.locale = w.core.host().locale;
        Some(s)
    }

    /// The Seerr title page over `flow`, which is asked for the detail of `hit` at once.
    pub(crate) fn seerr_over(
        env: Env,
        cx: Cx,
        mut flow: crate::seerr_flow::Flow,
        hit: SeerrHit,
    ) -> PageScreen {
        let mut s = PageScreen::new(env, cx, Kind::SeerrDetail, Scenario::Loading);
        s.seerr = None;
        flow.open(hit);
        s.flow = Some(flow);
        s.refresh();
        s
    }

    /// The title tile that was tapped on a live person page, once.
    pub fn take_tile(&mut self) -> Option<Tile> {
        self.tapped.take()
    }

    /// Whether a live load is still out.
    pub fn loading(&self) -> bool {
        self.live.as_ref().is_some_and(|l| l.rx.is_some())
    }

    #[allow(clippy::too_many_arguments)]
    fn body(
        kind: Kind,
        person: &Option<PersonVm>,
        playlist: &Option<PlaylistVm>,
        seerr: Option<&SeerrVm>,
        grid: &(String, Vec<Tile>, bool, bool),
        art: &PersonArt,
        live: bool,
        shelf: Option<(Pills, EmptyNote)>,
    ) -> Body {
        match kind {
            Kind::Person => Body::Person(
                person
                    .as_ref()
                    .map(|v| v.part().clone())
                    .unwrap_or_else(|| unreachable!("person page without model")),
                Box::new(art.clone()),
            ),
            Kind::Playlist => Body::Playlist(
                playlist
                    .as_ref()
                    .map(|v| v.part().clone())
                    .unwrap_or_else(|| unreachable!("playlist page without model")),
            ),
            Kind::Genre => Body::Grid {
                name: grid.0.clone(),
                tiles: grid.1.clone(),
                loading: grid.2,
                failed: grid.3,
                pills: None,
                empty: None,
            },
            Kind::Collection => Body::Grid {
                name: grid.0.clone(),
                tiles: grid.1.clone(),
                loading: grid.2,
                failed: grid.3,
                // The pills of the scripted page do nothing; a live page's pills are its shelf's.
                pills: match &shelf {
                    Some((p, _)) => Some(p.clone()),
                    None => (!live).then(|| Pills {
                        filter: "Alle".into(),
                        sort: "Jahr".into(),
                        sort_icon: "calendar-blank",
                    }),
                },
                empty: Some(shelf.map_or_else(
                    || {
                        (
                            "Hier ist noch nichts".into(),
                            "Sobald in dieser Sammlung etwas liegt, taucht es hier auf.".into(),
                            None,
                        )
                    },
                    |(_, e)| e,
                )),
            },
            Kind::SeerrSearch => Body::Discover(
                seerr
                    .map(|v| v.discover().clone())
                    .unwrap_or_else(|| unreachable!("seerr page without model")),
            ),
            Kind::SeerrDetail => seerr.and_then(|v| v.page().cloned()).map_or_else(
                || {
                    Body::Discover(
                        seerr
                            .map(|v| v.discover().clone())
                            .unwrap_or_else(|| unreachable!()),
                    )
                },
                |p| Body::Seerr(Box::new(p)),
            ),
        }
    }

    fn refresh(&mut self) {
        self.poll_live();
        self.poll_flow();
        self.poll_grid();
        self.poll_shelf();
        let d = Data {
            body: Self::body(
                self.kind,
                &self.person,
                &self.playlist,
                self.flow
                    .as_ref()
                    .map(crate::seerr_flow::Flow::vm)
                    .or(self.seerr.as_ref()),
                &self.grid,
                &self.art,
                self.grid_live.is_some(),
                self.shelf_view(),
            ),
            address: self
                .flow
                .as_ref()
                .map(crate::seerr_flow::Flow::address)
                .unwrap_or_default(),
        };
        self.host.set_data(d);
        self.host.sync();
    }

    /// The page kind.
    pub fn kind(&self) -> Kind {
        self.kind
    }

    /// The name of the page as the window and a screen reader give it, by the Mac's routes (`person`, `genre`,
    /// `collection`, `playlist`, `seerrTitle`): a person page is "Person", not a nameless "Seite".
    pub fn window_title(&self) -> &'static str {
        match self.kind {
            Kind::Person => "Person",
            Kind::Playlist => "Playlist",
            Kind::Genre => "Genre",
            Kind::Collection => "Sammlung",
            Kind::SeerrSearch => "Anfragen",
            Kind::SeerrDetail => "Anfrage",
        }
    }

    /// What the UI asked of the host, as readable lines for tests.
    pub fn log(&self) -> &[String] {
        &self.log
    }

    /// The play request of the last press ("Abspielen" of a playlist), once.
    pub fn take_play(&mut self) -> Option<crate::live_play::PlayRequest> {
        self.play_req.take()
    }

    /// The Seerr model (tests send intents through it).
    pub fn seerr(&mut self) -> Option<&mut SeerrVm> {
        self.seerr.as_mut()
    }

    /// Whether the page is pushed.
    pub fn is_open(&self) -> bool {
        self.host.depth() > 1
    }

    /// Whether the page is fully in.
    pub fn covers(&self) -> bool {
        self.host.covers()
    }

    /// The page below while this one slides (offset, dim).
    pub fn below(&self) -> Option<(f32, f32)> {
        self.host.below()
    }

    /// Pushes the page.
    pub fn open(&mut self, now: f64) {
        self.host.push(now);
    }

    /// Back (Esc): closes the open panel or season list first (the Mac closes only the popover), then pops the page.
    pub fn back(&mut self, now: f64) -> bool {
        let sheet = self
            .flow
            .as_ref()
            .and_then(|f| f.vm().page())
            .is_some_and(|p| p.sheet_open);
        if self.host.sx.menu.is_open() || sheet {
            let _ = self.nav_key(swiftly_ui::NavKey::Escape, true, now);
            return true;
        }
        self.host.pop(now)
    }

    fn effects(&mut self, fx: Vec<SeerrEffect>) {
        for e in fx {
            match e {
                SeerrEffect::Ask { .. } => {
                    if let Some(v) = self.seerr.as_mut() {
                        let _ = v.handle(SeerrIntent::Asked(None));
                    }
                }
                other => self.log.push(format!("seerr {other:?}")),
            }
        }
    }

    /// The Seerr title behind a tapped tile key: `seerr:N` (search block), `similar:N` (suggestions on a Seerr page)
    /// or `request:N` (the person page's rail).
    fn seerr_tile_at(&self, a: &Action) -> Option<SeerrHit> {
        let pick = |prefix: &str, tiles: &[SeerrTile]| {
            tiles
                .iter()
                .enumerate()
                .find(|(i, _)| *a == Action::from(format!("{prefix}:{i}").as_str()))
                .map(|(_, t)| t.hit.clone())
        };
        let vm = self.flow.as_ref()?.vm();
        pick("seerr", &vm.discover().tiles)
            .or_else(|| vm.page().and_then(|p| pick("similar", &p.similar)))
            .or_else(|| pick("request", &self.art.requests))
    }

    /// The season number behind a tapped season row of the request list.
    fn season_at(&self, a: &Action) -> Option<i64> {
        self.flow
            .as_ref()?
            .vm()
            .page()?
            .seasons
            .iter()
            .find(|r| *a == Action::from(format!("season:{}", r.number).as_str()))
            .map(|r| r.number)
    }

    fn drain(&mut self, now: f64) {
        for a in self.host.drain(now) {
            let is = |s: &str| a == Action::from(s);
            if a == popover::DISMISS {
                self.host.sx.menu.close();
            } else if is("bio-toggle") {
                if let Some(v) = self.person.as_mut() {
                    v.toggle_biography();
                }
            } else if is("play") && self.kind == Kind::Playlist {
                if let Some(first) = self.playlist.as_ref().and_then(|v| v.start()) {
                    self.play_req = Some(crate::live_play::PlayRequest {
                        item_id: first.id.clone(),
                        since: 0.0,
                        source_id: None,
                    });
                    self.log.push(format!("play {}", first.id));
                }
            } else if is("seasons-close") {
                // A click beside the floating season list closes it (the Mac's catcher layer).
                if let Some(f) = self.flow.as_mut() {
                    f.send(SeerrIntent::CloseSheet);
                }
            } else if self.kind == Kind::SeerrDetail
                && self.flow.is_some()
                && (is("press") || is("confirm-seasons") || self.season_at(&a).is_some())
            {
                self.roll += 1;
                let roll = self.roll;
                let season = self.season_at(&a);
                if let Some(f) = self.flow.as_mut() {
                    let asking = f
                        .vm()
                        .page()
                        .is_some_and(|p| p.sheet_open && p.hit.is_series());
                    if is("press") && asking {
                        // The Mac's `pressed`: with the list open the button asks with the ticked seasons.
                        f.send(SeerrIntent::ConfirmSeasons);
                    } else if is("press") {
                        f.send(SeerrIntent::Press { roll });
                    } else if is("confirm-seasons") {
                        f.send(SeerrIntent::ConfirmSeasons);
                    } else if let Some(n) = season {
                        f.send(SeerrIntent::ToggleSeason(n));
                    }
                }
            } else if let Some(hit) = self.seerr_tile_at(&a) {
                self.seerr_tapped = Some(hit);
            } else if is("press") {
                self.roll += 1;
                let fx = self
                    .seerr
                    .as_mut()
                    .map(|v| v.handle(SeerrIntent::Press { roll: self.roll }))
                    .unwrap_or_default();
                self.effects(fx);
            } else if is("pill:filter") || is("pill:sort") {
                let sort = is("pill:sort");
                let key = if sort { "sort" } else { "filter" };
                let (names, now_at): (Vec<&str>, usize) = match (&self.shelf, sort) {
                    (Some(sh), true) => {
                        let st = sh.vm.status();
                        (
                            crate::library_screen::SORTINGS
                                .iter()
                                .map(|(_, l)| *l)
                                .collect(),
                            crate::library_screen::SORTINGS
                                .iter()
                                .position(|(g, _)| *g == st.sorting)
                                .unwrap_or(0),
                        )
                    }
                    (Some(sh), false) => {
                        let st = sh.vm.status();
                        let offered = collection_filters(sh.art.as_deref());
                        (
                            offered.iter().map(|(_, l)| *l).collect(),
                            offered
                                .iter()
                                .position(|(g, _)| *g == st.filter)
                                .unwrap_or(0),
                        )
                    }
                    (None, true) => (vec!["Name", "Zuletzt", "Bewertung", "Jahr"], 0),
                    (None, false) => (vec!["Alle", "Angefangen", "Merkliste", "Ungesehen"], 0),
                };
                let rect = self
                    .host
                    .ui()
                    .frame_of(format!("pill:{key}").as_str())
                    .map_or(Rect::new(36.0, 100.0, 80.0, 34.0), |f| {
                        Rect::new(f[0], f[1], f[2], f[3])
                    });
                let items = names
                    .iter()
                    .enumerate()
                    .map(|(i, n)| {
                        MenuEntry::Item(
                            MenuItem::new(Action::from(format!("{key}:{i}").as_str()), *n)
                                .checked(i == now_at),
                        )
                    })
                    .collect();
                self.host.sx.menu.open(
                    items,
                    Anchor::Button(rect),
                    swiftly_ui::feel::DROPDOWN_WIDTH,
                    false,
                );
            } else if let Some(sh) = self.shelf.as_ref().filter(|sh| {
                is("reset-filter")
                    || (0..crate::library_screen::SORTINGS.len()).any(|i| is(&format!("sort:{i}")))
                    || (0..collection_filters(sh.art.as_deref()).len())
                        .any(|i| is(&format!("filter:{i}")))
            }) {
                // A pick in a pill's list: the shelf reloads, the list closes.
                if is("reset-filter") {
                    sh.vm.send(LibraryIntent::SetFilter {
                        filter: LibraryFilter::All,
                    });
                }
                for (i, (sorting, _)) in crate::library_screen::SORTINGS.iter().enumerate() {
                    if is(&format!("sort:{i}")) {
                        sh.vm.send(LibraryIntent::SetSorting { sorting: *sorting });
                    }
                }
                for (i, (filter, _)) in collection_filters(sh.art.as_deref())
                    .into_iter()
                    .enumerate()
                {
                    if is(&format!("filter:{i}")) {
                        sh.vm.send(LibraryIntent::SetFilter { filter });
                    }
                }
                self.host.sx.menu.close();
                self.host.ui().jump_first_scroll(Axis::Vertical, 0.0);
            } else if let Some(t) = self
                .art
                .tiles
                .iter()
                .find(|t| is(&format!("tile:{}", t.id)))
            {
                self.tapped = Some(t.clone());
            } else if (is("retry") || is("refresh")) && self.shelf.is_some() {
                if let Some(sh) = &self.shelf {
                    sh.vm.send(LibraryIntent::Load);
                }
            } else if (is("retry") || is("refresh")) && self.kind == Kind::SeerrDetail {
                // The Mac's `DisturbHint(retry: load)` over Seerr: ask for the detail again.
                let hit = self
                    .flow
                    .as_ref()
                    .and_then(|f| f.vm().page().map(|p| p.hit.clone()));
                if let (Some(f), Some(hit)) = (self.flow.as_mut(), hit) {
                    f.open(hit);
                }
            } else if is("retry") || is("refresh") {
                self.log.push("retry".into());
                self.films_applied = false;
                // A live person page asks the server again.
                if let Some(l) = self.live.as_mut() {
                    l.rx = crate::live_person::start(&l.core, &l.account, &l.id);
                }
            } else {
                self.log.push(format!("tap {}", a.0));
                self.host.sx.menu.close();
            }
        }
        self.refresh();
    }

    /// Arrow, Enter or Esc: a menu takes them first; Esc goes back.
    pub fn nav_key(
        &mut self,
        key: swiftly_ui::NavKey,
        down: bool,
        now: f64,
    ) -> swiftly_ui::Outcome {
        if self.host.sx.menu.is_open() {
            if down && let Some(k) = menu_key(key) {
                if let popover::MenuOutcome::Activate(a) = self.host.sx.menu.key(k, now) {
                    self.host.injected.push(a);
                }
                self.drain(now);
            }
            return swiftly_ui::Outcome::None;
        }
        let out = self.host.ui().nav_key(key, down, now);
        if out == swiftly_ui::Outcome::Back(swiftly_ui::BackOutcome::Pop) {
            // Esc closes the season list first (the Mac's catcher layer), then goes back.
            let sheet = self
                .flow
                .as_ref()
                .and_then(|f| f.vm().page())
                .is_some_and(|p| p.sheet_open);
            if let (true, Some(f)) = (sheet, self.flow.as_mut()) {
                f.send(SeerrIntent::CloseSheet);
            } else {
                self.host.pop(now);
            }
        }
        self.drain(now);
        out
    }

    /// A finger or click goes down.
    pub fn touch_down(&mut self, x: f32, y: f32, now: f64) {
        self.host.ui().touch_down(x, y, now);
        self.drain(now);
    }

    /// The finger moves.
    pub fn touch_move(&mut self, x: f32, y: f32, now: f64) {
        self.host.ui().touch_move(x, y, now);
        self.drain(now);
    }

    /// The finger lifts.
    pub fn touch_up(&mut self, x: f32, y: f32, now: f64) {
        self.host.ui().touch_up(x, y, now);
        self.drain(now);
    }

    /// The touch is cancelled.
    pub fn touch_cancel(&mut self, now: f64) {
        self.host.ui().touch_cancel(now);
        self.drain(now);
    }

    /// What a screen reader gets for this page.
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.host.a11y_nodes()
    }

    /// The pointer moved.
    pub fn pointer_move(&mut self, x: f32, y: f32, now: f64) {
        self.host.ui().pointer_move(x, y, now);
    }

    /// The pointer left the window.
    pub fn pointer_leave(&mut self, now: f64) {
        self.host.ui().pointer_leave(now);
    }

    /// A right click.
    pub fn secondary_click(&mut self, x: f32, y: f32, now: f64) -> bool {
        let took = self.host.ui().secondary_click(x, y, now);
        self.drain(now);
        took
    }

    /// A mouse wheel step.
    pub fn wheel_scroll(&mut self, x: f32, y: f32, dx: f32, dy: f32, now: f64) -> bool {
        self.host.ui().wheel_scroll(x, y, dx, dy, now)
    }

    /// The cursor the node under the pointer asks for.
    pub fn cursor(&mut self) -> swiftly_ui::Cursor {
        self.host.ui().cursor()
    }

    /// The tooltip to draw at `now`.
    pub fn visible_tooltip(&mut self, now: f64) -> Option<(String, Rect)> {
        self.host.ui().visible_tooltip(now)
    }

    /// An anchored panel is open.
    pub fn menu_open(&mut self) -> bool {
        self.host.sx.menu.is_open()
    }

    /// Shows the real pictures of the server through `hub`.
    #[must_use]
    pub fn with_images(self, hub: Rc<crate::hub::ImageHub>) -> Self {
        crate::hub::HubSlotExt::attach(&self.host.hub, hub);
        self
    }

    /// One frame at `now` ms.
    pub fn frame(&mut self, now: f64) -> (DrawList, bool) {
        self.refresh();
        let r = self.host.frame_list(now);
        self.drain(now);
        (
            r.0,
            r.1 || self.loading() || self.flow.as_ref().is_some_and(|f| f.busy()),
        )
    }

    /// An animation needs another frame.
    pub fn wants_frame(&self) -> bool {
        self.host.wants_frame() || self.flow.as_ref().is_some_and(|f| f.busy())
    }

    /// A new window size or scale.
    pub fn set_env(&mut self, env: Env) {
        self.host.set_env(env);
    }

    /// Scrolling by this table instead of the running OS's (goldens that must not depend on the platform).
    pub fn set_scroll_tuning(&mut self, t: swiftly_motion::ScrollTuning) {
        self.host.ui().set_scroll_tuning(t);
    }

    /// Renders a list with the software renderer.
    pub fn render_software(&self, list: &DrawList) -> RgbaImage {
        self.host.render(list)
    }

    /// Scroll offsets of all scroll views.
    pub fn scroll_offsets(&mut self) -> Vec<f64> {
        self.host.ui().scroll_offsets()
    }

    /// The frame of a keyed node, for tests.
    pub fn frame_of(&mut self, key: &str) -> Option<Point> {
        self.host.ui().frame_of(key).map(|f| Point::new(f[0], f[1]))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::seerr_flow::tests::{Script, hit};
    use crate::seerr_flow::{Backend, Flow};
    use std::sync::Arc;

    fn series_detail() -> SeerrDetail {
        SeerrDetail {
            description: Some("Eine Serie.".into()),
            genres: vec!["Drama".into()],
            runtime: None,
            rating: Some(7.5),
            seasons: (1..=2)
                .map(|n| SeerrSeason {
                    number: n,
                    episodes: 8,
                    state: SeerrState::Opened,
                })
                .collect(),
            cast: vec![SeerrPerson {
                id: 1,
                name: "Mara Brandt".into(),
                role: None,
                image_path: Some("/p.jpg".into()),
            }],
            similar_one: vec![hit(9, SeerrState::Opened)],
            state: Some(SeerrState::Opened),
        }
    }

    fn page(detail: Option<SeerrDetail>) -> (PageScreen, Arc<Script>) {
        let script = Arc::new(Script {
            detail,
            ..Script::default()
        });
        let backend = Arc::clone(&script) as Arc<dyn Backend>;
        let flow = Flow::new(backend, Locale::parse("de"));
        let mut tv = hit(5, SeerrState::Opened);
        tv.art = "tv".into();
        let env = Env::new(
            swiftly_layout::Size::new(1280.0, 800.0),
            1.0,
            swiftly_ui::Idiom::Desktop,
        );
        let cx = Cx::deterministic();
        (PageScreen::seerr_over(env, cx, flow, tv), script)
    }

    fn tap(s: &mut PageScreen, key: &str) {
        s.host.injected.push(Action::from(key));
        s.drain(0.0);
        s.refresh();
    }

    #[test]
    fn the_seerr_page_loads_its_detail_and_a_series_asks_for_seasons_first() {
        let (mut s, script) = page(Some(series_detail()));
        s.refresh();
        assert_eq!(*script.calls.lock().unwrap(), vec!["detail tv 5"]);
        let part = s.flow.as_ref().and_then(|f| f.vm().page()).cloned();
        assert!(
            part.as_ref()
                .is_some_and(|p| p.can_request && !p.sheet_open)
        );
        tap(&mut s, "press");
        assert!(
            s.flow
                .as_ref()
                .and_then(|f| f.vm().page())
                .is_some_and(|p| p.sheet_open)
        );
        tap(&mut s, "season:2");
        // The Mac's `pressed`: the request button itself asks with the ticked seasons while the list is open.
        tap(&mut s, "press");
        s.flow.as_mut().map(|f| f.poll(std::time::Instant::now()));
        let calls = script.calls.lock().unwrap().clone();
        assert!(calls.iter().any(|c| c == "ask tv 5 Some([2])"), "{calls:?}");
    }

    #[test]
    fn the_season_list_floats_below_the_button_and_a_click_beside_it_closes_it() {
        let (mut s, _) = page(Some(series_detail()));
        s.refresh();
        s.open(0.0);
        let _ = s.frame(0.0);
        assert!(s.host.ui().frame_of("season-panel").is_none(), "closed");
        tap(&mut s, "press");
        for t in 0..30 {
            let _ = s.frame(16.0 * f64::from(t));
        }
        let panel = s
            .host
            .ui()
            .frame_of("season-panel")
            .expect("the list shows");
        assert!(
            (panel[1] - 390.0).abs() < 1.0 && (panel[2] - 320.0).abs() < 1.0,
            "below the 182 + 56 button row of the block, 320 wide: {panel:?}"
        );
        assert!(
            s.host.ui().frame_of("seasons-catcher").is_some(),
            "a catcher lies below it"
        );
        tap(&mut s, "seasons-close");
        assert!(
            s.flow
                .as_ref()
                .and_then(|f| f.vm().page())
                .is_some_and(|p| !p.sheet_open),
            "a click beside the list closes it"
        );
    }

    #[test]
    fn a_series_request_button_names_the_step_and_counts_the_ticked_seasons() {
        let (mut s, _) = page(Some(series_detail()));
        s.refresh();
        let label = |s: &PageScreen| {
            let p = s
                .flow
                .as_ref()
                .and_then(|f| f.vm().page())
                .cloned()
                .unwrap();
            request_label(&p)
        };
        assert_eq!(label(&s), "Staffeln wählen");
        tap(&mut s, "press");
        assert_eq!(label(&s), "Staffeln wählen", "nothing ticked yet");
        tap(&mut s, "season:2");
        assert_eq!(label(&s), "1 Staffeln anfragen");
    }

    #[test]
    fn a_suggestion_on_the_seerr_page_opens_that_title() {
        let (mut s, _) = page(Some(series_detail()));
        s.refresh();
        tap(&mut s, "similar:0");
        assert_eq!(s.take_seerr().map(|h| h.id), Some(9));
        assert!(s.take_seerr().is_none());
    }

    #[test]
    fn a_failed_detail_names_seerr_and_retry_asks_again() {
        let (mut s, script) = page(None);
        s.refresh();
        assert!(
            s.flow
                .as_ref()
                .and_then(|f| f.vm().page())
                .is_some_and(|p| p.disturbed)
        );
        tap(&mut s, "retry");
        assert_eq!(script.calls.lock().unwrap().len(), 2);
    }

    #[test]
    fn the_persons_request_rail_shows_what_seerr_knows_and_the_own_server_does_not() {
        let script = Arc::new(Script {
            hits: vec![hit(1, SeerrState::Opened), hit(2, SeerrState::Present)],
            ..Script::default()
        });
        let backend = Arc::clone(&script) as Arc<dyn Backend>;
        let env = Env::new(
            swiftly_layout::Size::new(1280.0, 800.0),
            1.0,
            swiftly_ui::Idiom::Desktop,
        );
        let mut s = PageScreen::new(env, Cx::deterministic(), Kind::Person, Scenario::Loading);
        s.flow = Some(Flow::new(backend, Locale::parse("de")));
        if let Some(f) = s.flow.as_mut() {
            f.ask_films(7);
        }
        s.refresh();
        assert_eq!(s.art.requests.len(), 1, "present titles stay out");
        assert_eq!(s.art.requests[0].hit.id, 1);
        tap(&mut s, "request:0");
        assert_eq!(s.take_seerr().map(|h| h.id), Some(1));
    }
}
