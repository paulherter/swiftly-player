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
use swiftly_model::{Item, Person};
use swiftly_render::{Color, DrawList, RgbaImage};
use swiftly_seerr::models::{SeerrDetail, SeerrHit, SeerrPerson, SeerrSeason, SeerrState};
use swiftly_ui::components::color;
use swiftly_ui::icons::Icons;
use swiftly_ui::interact::PressStyle;
use swiftly_ui::popover::{self, Anchor, MenuEntry, MenuItem};
use swiftly_ui::{Action, Cx, Env, Node, Paint};
use swiftly_vm::{
    DiscoverPart, PersonDetail, PersonPart, PersonVm, PlaylistPart, PlaylistVm, SeerrEffect,
    SeerrIntent, SeerrPart, SeerrTile, SeerrVm, Tile, TileFacts,
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

#[derive(Clone, PartialEq)]
enum Body {
    Person(PersonPart),
    Playlist(PlaylistPart),
    Grid {
        name: String,
        tiles: Vec<Tile>,
        loading: bool,
        failed: bool,
        pills: Option<(String, String)>,
        empty: Option<(String, String)>,
    },
    Discover(DiscoverPart),
    Seerr(Box<SeerrPart>),
}

#[derive(Clone, PartialEq)]
struct Data {
    body: Body,
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
fn empty_state(k: &Kit, icon: &str, title: &str, text: &str, action: Option<(&str, &str)>) -> Node {
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
fn backdrop(k: &Kit, id: &str, w: f32, h: f32, bw: f32) -> Node {
    let img = k.art.node(true, id, bw, h, 0.0);
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

fn person_page(k: &Kit, p: &PersonPart) -> Node {
    let w = k.env.size.w;
    let edge = k.lk.edge;
    // Hero 260: portrait 88 and the name block bottom-left (left 36, bottom 22), the first title's landscape at the right.
    let portrait = k.art.node(false, &p.name, 88.0, 88.0, 44.0);
    let mut id = vec![txt(
        k.cx,
        &p.name,
        weight(k.lk.rail, 30.0, 700),
        colour::FONT,
        Some(1),
    )];
    for l in [&p.born_line, &p.place].into_iter().flatten() {
        id.push(txt(
            k.cx,
            l,
            weight(k.lk.small, 12.0, 400),
            colour::FONT_QUIET,
            Some(1),
        ));
    }
    let block = Node::hstack(
        Align::End,
        Some(16.0),
        vec![portrait, Node::vstack(Align::Start, Some(2.0), id)],
    )
    .padding(ins(0.0, edge, 22.0, 0.0));
    let first = p.titles.first().map_or("", |t| t.id.as_str());
    let hero = fill_frame(block, Alignment::BOTTOM_LEADING)
        .frame(Some(w), Some(260.0), Alignment::BOTTOM_LEADING)
        .background(
            backdrop(k, first, w, 260.0, 260.0 * 1.62),
            Alignment::TOP_LEADING,
        );
    let mut body = Vec::new();
    if let Some(r) = &p.role_line {
        body.push(
            txt(
                k.cx,
                r,
                weight(k.lk.body, 13.0, 500),
                colour::MARK_ACCENT,
                Some(1),
            )
            .padding(ins(0.0, edge, 0.0, 0.0)),
        );
    }
    if let Some(bio) = &p.biography {
        let lines = if p.biography_expanded { None } else { Some(4) };
        let t = Node::text(
            k.cx,
            bio,
            &swiftly_text::TextStyle {
                line_height: swiftly_text::LineHeight::Points(15.0 * 1.21 + 3.0),
                ..swiftly_text::TextStyle::from(weight(k.lk.body, 15.0, 400))
            },
            color(colour::FONT_QUIET),
            lines,
            swiftly_text::Align::Start,
        )
        .frame(Some(700.0), None, Alignment::LEADING);
        let toggle = if p.biography_expanded {
            "Weniger"
        } else {
            "Mehr"
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
        body.push(
            Node::vstack(Align::Start, Some(6.0), vec![t, more]).padding(ins(0.0, edge, 0.0, 0.0)),
        );
    }
    if !p.titles.is_empty() {
        let tiles: Vec<Tile> = p.titles.iter().map(tile_of).collect();
        body.push(tile_rail(k, "titles", &p.rail_title, &tiles, false));
    }
    if !p.requestable.is_empty() {
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
    Node::vstack(
        Align::Start,
        Some(0.0),
        vec![
            hero,
            Node::vstack(Align::Start, Some(26.0), body).padding(ins(26.0, 0.0, 0.0, 0.0)),
        ],
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
    pills: Option<&(String, String)>,
    empty: Option<&(String, String)>,
) -> Node {
    let mut kids = vec![header(k, name, None)];
    if let Some((f, s)) = pills {
        // `FilterBox` 44: two pills, 8 apart; each opens a 190 wide list.
        let pill = |label: &str, key: &str| {
            Node::hstack(
                Align::Center,
                Some(6.0),
                vec![
                    txt(
                        k.cx,
                        label,
                        weight(k.lk.body, 14.0, 500),
                        colour::FONT,
                        Some(1),
                    ),
                    k.icons
                        .node("caret-down", 11.0, true, color(colour::FONT_QUIET)),
                ],
            )
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
                vec![pill(f, "pill:filter"), pill(s, "pill:sort")],
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
        let (t, x) = empty.cloned().unwrap_or_else(|| {
            (
                "Nichts in diesem Genre".into(),
                "In diesem Genre gibt es auf deinem Server gerade keine Filme und Serien.".into(),
            )
        });
        empty_state(k, "tag", &t, &x, None)
    } else {
        grid(k, tiles, "tile").padding(ins(20.0, 0.0, 0.0, 0.0))
    });
    Node::vstack(Align::Start, Some(0.0), kids).padding(ins(58.0, 0.0, 0.0, 0.0))
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
fn seerr_tile(k: &Kit, t: &SeerrTile, key: &str) -> Node {
    let (w, h) = (150.0, 225.0);
    let mut img = k
        .art
        .node(false, &t.hit.title, w, h, 10.0)
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
    let rows: Vec<Node> = d
        .tiles
        .chunks(per)
        .enumerate()
        .map(|(r, c)| {
            Node::hstack(
                Align::Start,
                Some(16.0),
                c.iter()
                    .enumerate()
                    .map(|(i, t)| seerr_tile(k, t, &format!("seerr:{}", r * per + i)))
                    .collect(),
            )
        })
        .collect();
    Node::vstack(
        Align::Start,
        Some(0.0),
        vec![
            header(k, "Über Seerr anfragen", Some(count)),
            Node::vstack(Align::Start, Some(20.0), rows).padding(ins(18.0, k.lk.edge, 0.0, 0.0)),
        ],
    )
    .padding(ins(58.0, 0.0, 0.0, 0.0))
}

fn seerr_page(k: &Kit, p: &SeerrPart) -> Node {
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
            &p.button_text,
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
            backdrop(k, &p.hit.title, w, 350.0, 350.0 * 1.62),
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
            "Seerr antwortet nicht.",
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
                image: None,
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
        Body::Person(p) => (person_page(&k, p), p.name.clone()),
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
        Body::Seerr(p) => (seerr_page(&k, p), p.hit.title.clone()),
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
    let mut page = fill_frame(scroll, Alignment::TOP_LEADING)
        .overlay(top_bar(&k, &title, sx.header), Alignment::TOP);
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
                        let bio = "Mara Brandt wuchs an der Küste auf und stand mit siebzehn zum ersten Mal vor der Kamera. Seitdem spielt sie vor allem Frauen, die zwischen Pflicht und Heimweh wählen müssen. Für „Nordlicht“ lernte sie ein halbes Jahr lang, ein Lotsenboot zu steuern.";
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
            Kind::Genre | Kind::Collection => grid.1 = tiles,
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
            body: Self::body(kind, &person, &playlist, &seerr, &grid),
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
        };
        s.refresh();
        s
    }

    fn body(
        kind: Kind,
        person: &Option<PersonVm>,
        playlist: &Option<PlaylistVm>,
        seerr: &Option<SeerrVm>,
        grid: &(String, Vec<Tile>, bool, bool),
    ) -> Body {
        match kind {
            Kind::Person => Body::Person(
                person
                    .as_ref()
                    .map(|v| v.part().clone())
                    .unwrap_or_else(|| unreachable!("person page without model")),
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
                name: "Nordlicht-Reihe".into(),
                tiles: grid.1.clone(),
                loading: grid.2,
                failed: grid.3,
                pills: Some(("Alle".into(), "Jahr".into())),
                empty: Some((
                    "Hier ist noch nichts".into(),
                    "Sobald in dieser Sammlung etwas liegt, taucht es hier auf.".into(),
                )),
            },
            Kind::SeerrSearch => Body::Discover(
                seerr
                    .as_ref()
                    .map(|v| v.discover().clone())
                    .unwrap_or_else(|| unreachable!("seerr page without model")),
            ),
            Kind::SeerrDetail => seerr.as_ref().and_then(|v| v.page().cloned()).map_or_else(
                || {
                    Body::Discover(
                        seerr
                            .as_ref()
                            .map(|v| v.discover().clone())
                            .unwrap_or_else(|| unreachable!()),
                    )
                },
                |p| Body::Seerr(Box::new(p)),
            ),
        }
    }

    fn refresh(&mut self) {
        let d = Data {
            body: Self::body(
                self.kind,
                &self.person,
                &self.playlist,
                &self.seerr,
                &self.grid,
            ),
        };
        self.host.set_data(d);
        self.host.sync();
    }

    /// The page kind.
    pub fn kind(&self) -> Kind {
        self.kind
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

    /// Back: pops the page.
    pub fn back(&mut self, now: f64) -> bool {
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
            } else if is("press") {
                self.roll += 1;
                let fx = self
                    .seerr
                    .as_mut()
                    .map(|v| v.handle(SeerrIntent::Press { roll: self.roll }))
                    .unwrap_or_default();
                self.effects(fx);
            } else if is("pill:filter") || is("pill:sort") {
                let (key, names): (&str, &[&str]) = if is("pill:filter") {
                    ("filter", &["Alle", "Angefangen", "Merkliste", "Ungesehen"])
                } else {
                    ("sort", &["Name", "Zuletzt", "Bewertung", "Jahr"])
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
                                .checked(i == 0),
                        )
                    })
                    .collect();
                self.host.sx.menu.open(
                    items,
                    Anchor::Button(rect),
                    swiftly_ui::feel::DROPDOWN_WIDTH,
                    false,
                );
            } else if is("retry") || is("refresh") {
                self.log.push("retry".into());
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
            self.host.pop(now);
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
    pub fn a11y_nodes(&mut self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.host.ui().a11y_nodes()
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
        r
    }

    /// An animation needs another frame.
    pub fn wants_frame(&self) -> bool {
        self.host.wants_frame()
    }

    /// A new window size or scale.
    pub fn set_env(&mut self, env: Env) {
        self.host.set_env(env);
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
