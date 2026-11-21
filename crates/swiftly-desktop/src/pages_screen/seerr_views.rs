//! The Seerr pages drawn from the core's screens (`swiftly_vm::seerr_io`): the title page with its request sheet, "Meine
//! Anfragen", the search block with the discover rails and the home block. Every word, state and count comes from the
//! core's `info()` records; this file only draws them and names the taps. Component names follow the design's part table
//! (`SeerrMark`, `SeerrTile`, `SeasonPickerRow`, `QuotaLine`, `PrimaryButton`, `RequestRow`, `ArrivalBanner`,
//! `AttentionLine`).

use super::*;
use crate::home::Form;
use swiftly_design::tokens::desktop;
use swiftly_vm::{
    BadgeKind, ListLoad, PrimaryKind, RowWork, SeerrBadge, SeerrHomeInfo, SeerrPrimary,
    SeerrRequestRow, SeerrRequestsInfo, SeerrSearchInfo, SeerrSeasonRowInfo, SeerrSheetInfo,
    SeerrTileCard, SeerrTitleInfo, SheetPhase, TitleLoad,
};

/// Which section of the core's Home block to draw (the two sit in the Home row order like any other row).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum HomePart {
    /// "<Titel> ist da" (a stack when several) and the manager's line.
    Arrival,
    /// "Meine Anfragen".
    Requests,
}

/// The Seerr hit behind a tile (what the shell opens a title page with).
pub(crate) fn hit_of(c: &SeerrTileCard) -> SeerrHit {
    SeerrHit {
        id: c.tmdb,
        art: c.art.clone(),
        title: c.title.clone(),
        year: c.year,
        poster_path: c.poster.clone(),
        backdrop_path: None,
        state: SeerrState::Opened,
    }
}

fn badge_colour(kind: BadgeKind) -> swiftly_design::Colour {
    match kind {
        BadgeKind::Waits | BadgeKind::Failed | BadgeKind::Declined => color::STATE_WARNING,
        BadgeKind::Fetching | BadgeKind::Partial | BadgeKind::Searching => {
            crate::look_glow::accent()
        }
        BadgeKind::Available => color::TEXT_PRIMARY,
        BadgeKind::Requestable | BadgeKind::Soon | BadgeKind::Blocked => color::TEXT_SECONDARY,
    }
}

/// `SeerrMark`: the short status word in a capsule (uppercase 10 semibold on the state's colour).
pub(crate) fn seerr_mark(k: &Kit, b: &SeerrBadge) -> Node {
    let c = badge_colour(b.kind);
    Node::hstack(
        Align::Center,
        Some(4.0),
        vec![txt(
            k.cx,
            &b.word.to_uppercase(),
            swiftly_design::TextStyle {
                size: 10.0,
                weight: 600,
                tracking: 1.0,
                ..k.lk.small
            },
            color::SURFACE_BASE,
            Some(1),
        )],
    )
    .padding(ins(3.0, 8.0, 3.0, 8.0))
    .background(Node::rect(color(c), 8.0), Alignment::CENTER)
}

/// A bar for a running download (0...1).
fn progress_bar(p: f32, w: f32) -> Node {
    let fill = Node::rect(color(crate::look_glow::accent()), 2.0).frame(
        Some((w * p.clamp(0.0, 1.0)).max(2.0)),
        Some(4.0),
        Alignment::LEADING,
    );
    Node::rect(color(color::SURFACE_CONTROL), 2.0)
        .frame(Some(w), Some(4.0), Alignment::LEADING)
        .overlay(fill, Alignment::LEADING)
}

/// `SeerrTile` of the core's card: the picture at 45 %, the status capsule bottom left, title, "2019 · Serie".
pub(crate) fn seerr_tile_card(k: &Kit, t: &SeerrTileCard, key: &str) -> Node {
    let (w, h) = (150.0, 225.0);
    let round = if t.art == "person" { 75.0 } else { 10.0 };
    let mut img = k
        .art
        .node_for(
            remote(t.poster.as_deref(), swiftly_vm::ImageKind::Poster, 342, 513).as_ref(),
            false,
            &t.title,
            w,
            h,
            round,
        )
        .opacity(0.45, swiftly_ui::Motion::Instant);
    if let Some(b) = &t.badge {
        img = img.overlay(
            seerr_mark(k, b).padding(ins(0.0, 8.0, 8.0, 0.0)),
            Alignment::BOTTOM_LEADING,
        );
    }
    let kind = match t.art.as_str() {
        "tv" => "Serie",
        "person" => "Person",
        "collection" => "Sammlung",
        _ => "Film",
    };
    let sub = t
        .year
        .map_or(kind.to_owned(), |y| format!("{y} \u{b7} {kind}"));
    let n = Node::vstack(
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
                        &t.title,
                        weight(k.lk.tile, 13.0, 500),
                        color::TEXT_SECONDARY,
                        Some(1),
                    )
                    .frame(Some(w), None, Alignment::LEADING),
                    txt(
                        k.cx,
                        &sub,
                        weight(k.lk.small, 12.0, 400),
                        color::TEXT_TERTIARY,
                        Some(1),
                    )
                    .frame(Some(w), None, Alignment::LEADING),
                ],
            ),
        ],
    )
    .key(key)
    .a11y_label(swiftly_ui::a11y::Role::Button, t.announcement.clone());
    if t.art == "person" || t.art == "collection" {
        n
    } else {
        n.on_tap(Action::from(key))
            .hover_scale(swiftly_ui::feel::HOVER_TILE_SCALE)
            .press_style(PressStyle::Button)
    }
}

/// The tiles in rows of `per`, keys `{prefix}:{index}`.
pub(crate) fn seerr_card_grid(k: &Kit, tiles: &[SeerrTileCard], per: usize, prefix: &str) -> Node {
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
                    .map(|(i, t)| seerr_tile_card(k, t, &format!("{prefix}:{}", r * per + i)))
                    .collect(),
            )
        })
        .collect();
    Node::vstack(Align::Start, Some(20.0), rows)
}

fn sub_heading(k: &Kit, text: &str) -> Node {
    txt(
        k.cx,
        text,
        weight(k.lk.body, 15.0, 600),
        color::TEXT_SECONDARY,
        Some(1),
    )
}

/// The search block "Noch nicht auf deinem Server": the core's groups of dimmed tiles, or the offline line with its retry,
/// or the "Auch nicht bei Seerr" line. Keys `seerr-{group}:{index}`. Draws nothing when the core has nothing to say.
pub(crate) fn search_block(
    k: &Kit,
    info: &SeerrSearchInfo,
    per: usize,
    alone: bool,
) -> Option<Node> {
    let edge = k.lk.edge;
    let top = if alone { 30.0 } else { 40.0 };
    let mut kids: Vec<Node> = Vec::new();
    if info.groups.iter().any(|g| !g.tiles.is_empty()) {
        kids.push(
            Node::hstack(
                Align::Center,
                Some(8.0),
                vec![
                    txt(
                        k.cx,
                        &info.block_title,
                        weight(k.lk.rail, 22.0, 700),
                        color::TEXT_PRIMARY,
                        Some(1),
                    ),
                    Node::spacer(),
                    txt(
                        k.cx,
                        &info.count.to_string(),
                        weight(k.lk.small, 13.0, 500),
                        color::TEXT_TERTIARY,
                        Some(1),
                    ),
                ],
            )
            .padding(ins(top, edge, 0.0, edge)),
        );
        let many = info.groups.len() > 1;
        for (gi, g) in info.groups.iter().enumerate() {
            if g.tiles.is_empty() {
                continue;
            }
            let mut col = Vec::new();
            if many {
                col.push(sub_heading(k, &g.title));
            }
            col.push(seerr_card_grid(k, &g.tiles, per, &format!("seerr-{gi}")));
            kids.push(
                Node::vstack(Align::Start, Some(12.0), col).padding(ins(16.0, edge, 0.0, edge)),
            );
        }
    } else if let Some(e) = &info.error {
        // One calm box, one way out (`SearchView.offlineBox`): the line, then the retry under it.
        kids.push(
            Node::vstack(
                Align::Start,
                Some(12.0),
                vec![
                    txt(
                        k.cx,
                        e,
                        weight(k.lk.body, 15.0, 400),
                        color::TEXT_SECONDARY,
                        Some(3),
                    )
                    .padding(ins(13.0, 14.0, 13.0, 14.0))
                    .background(
                        Node::rect(color(color::SURFACE_CONTROL), 12.0),
                        Alignment::CENTER,
                    ),
                    txt(
                        k.cx,
                        "Erneut versuchen",
                        weight(k.lk.body, 15.0, 500),
                        crate::look_glow::accent(),
                        Some(1),
                    )
                    .key("seerr-retry")
                    .on_tap(Action::from("seerr-retry")),
                ],
            )
            .padding(ins(top, edge, 0.0, edge)),
        );
    } else if let Some(line) = &info.nothing_line {
        kids.push(
            txt(
                k.cx,
                line,
                weight(k.lk.body, 15.0, 400),
                color::TEXT_TERTIARY,
                Some(2),
            )
            .padding(ins(top, edge, 0.0, edge)),
        );
    }
    (!kids.is_empty()).then(|| Node::vstack(Align::Start, Some(0.0), kids))
}

/// The discover rails of the empty search page (`DiscoverView`): a heading and a row of tiles each, keys `rail-{r}:{i}`.
pub(crate) fn discover_rails(k: &Kit, rails: &swiftly_vm::SeerrDiscoverRails) -> Option<Node> {
    let kids: Vec<Node> = rails
        .rails
        .iter()
        .enumerate()
        .filter(|(_, r)| !r.tiles.is_empty())
        .map(|(ri, r)| {
            let tiles: Vec<Node> = r
                .tiles
                .iter()
                .enumerate()
                .map(|(i, t)| seerr_tile_card(k, t, &format!("rail-{ri}:{i}")))
                .collect();
            crate::detail_screen::segment(
                k,
                &format!("rail-{ri}"),
                &r.title,
                tiles,
                16.0,
                225.0 + 8.0 + 36.0,
            )
        })
        .collect();
    (!kids.is_empty())
        .then(|| Node::vstack(Align::Start, Some(26.0), kids).padding(ins(30.0, 0.0, 0.0, 0.0)))
}

// ---- the title page and its sheet ---------------------------------------------------------------------------------

/// The button of the title page's head: the library page's white 280 x 56 button with a plus for a request. A status
/// (asked for, being fetched) is not a button: it reads as a quiet line on an area instead of offering a second request.
fn head_button(k: &Kit, p: &SeerrPrimary) -> Option<Node> {
    match p.kind {
        PrimaryKind::Hidden => None,
        PrimaryKind::Request | PrimaryKind::Locked => {
            let on = p.enabled;
            let row = Node::hstack(
                Align::Center,
                Some(10.0),
                vec![
                    k.icons
                        .node("plus", 18.0, false, color(color::SURFACE_BASE)),
                    txt(
                        k.cx,
                        &p.text,
                        weight(k.lk.body, 17.0, 600),
                        color::SURFACE_BASE,
                        Some(1),
                    ),
                ],
            )
            .frame(
                Some(desktop::DETAIL_PRIMARY_WIDTH),
                Some(desktop::DETAIL_BUTTON_HEIGHT),
                Alignment::CENTER,
            )
            .background(
                Node::rect(color(color::TEXT_PRIMARY), 10.0),
                Alignment::CENTER,
            )
            .key("primary");
            Some(if on {
                row.on_tap(Action::from("primary"))
                    .hover_surface(rgba(color::SURFACE_BASE, 0.12), 10.0)
                    .press_style(PressStyle::Button)
            } else {
                row.opacity(0.5, swiftly_ui::Motion::Instant)
            })
        }
        PrimaryKind::Requested | PrimaryKind::Busy => Some(
            txt(
                k.cx,
                &p.text,
                weight(k.lk.body, 15.0, 400),
                color::TEXT_SECONDARY,
                Some(2),
            )
            .padding(ins(13.0, 14.0, 13.0, 14.0))
            .background(
                Node::rect(color(color::SURFACE_CONTROL), 10.0),
                Alignment::CENTER,
            ),
        ),
    }
}

/// One season of the request sheet (`MacSeasonLine`): title and episode count, and at the end the tick (a season that can
/// be asked for) or its state in a word (already there, waiting, ...). A season that cannot be asked for stays quiet.
fn season_picker_row(k: &Kit, r: &SeerrSeasonRowInfo, key: &str) -> Node {
    let fg = if r.selectable {
        color::TEXT_PRIMARY
    } else {
        color::TEXT_TERTIARY
    };
    let mut kids = vec![txt(
        k.cx,
        &r.title,
        weight(k.lk.body, 15.0, 400),
        fg,
        Some(1),
    )];
    if let Some(e) = &r.episodes {
        kids.push(txt(
            k.cx,
            &format!("\u{b7} {e}"),
            weight(k.lk.small, 13.0, 400),
            color::TEXT_TERTIARY,
            Some(1),
        ));
    }
    kids.push(Node::spacer());
    if r.selectable {
        let (glyph, tint) = if r.selected {
            ("check-square.fill", crate::look_glow::accent())
        } else {
            ("square", color::TEXT_TERTIARY)
        };
        kids.push(k.icons.node(glyph, 17.0, !r.selected, color(tint)));
    } else {
        let word = if r.badge.word.is_empty() {
            &r.badge.line
        } else {
            &r.badge.word
        };
        kids.push(txt(
            k.cx,
            word,
            weight(k.lk.small, 13.0, 400),
            color::TEXT_TERTIARY,
            Some(1),
        ));
    }
    let n = Node::hstack(Align::Center, Some(10.0), kids)
        .padding(ins(0.0, SHEET_SIDE, 0.0, SHEET_SIDE))
        .frame(Some(SHEET_WIDTH), Some(SHEET_ROW), Alignment::LEADING)
        .key(key);
    if r.selectable {
        n.on_tap(Action::from(key))
            .hover_surface(Color::new(1.0, 1.0, 1.0, 0.05), 0.0)
    } else {
        n
    }
}

const SHEET_WIDTH: f32 = 420.0;
const SHEET_SIDE: f32 = 24.0;
const SHEET_ROW: f32 = 44.0;
const SHEET_LIST_MAX: f32 = 264.0;
/// The soft edge of the season list, in points (the Mac's 22).
const SHEET_FADE: f32 = 22.0;

/// One fading edge of the season list: strips of the card's colour, opaque at the edge, nothing when the list does not
/// go on that way.
fn sheet_fade(on: bool, top: bool) -> Node {
    const BANDS: usize = 11;
    let strips: Vec<Node> = (0..BANDS)
        .map(|i| {
            // `top`: the first strip is at the edge and opaque; the bottom edge is the same list upside down.
            let a = 1.0 - i as f32 / BANDS as f32;
            Node::rect(
                rgba(color::SURFACE_CONTROL, if on { a * a } else { 0.0 }),
                0.0,
            )
            .frame(
                Some(SHEET_WIDTH),
                Some(SHEET_FADE / BANDS as f32),
                Alignment::CENTER,
            )
        })
        .collect();
    let strips = if top {
        strips
    } else {
        strips.into_iter().rev().collect()
    };
    Node::vstack(Align::Start, Some(0.0), strips)
}

/// A row of the sheet with a label at the start and something at the end, 44 high (`adminRow` / `choice`).
fn sheet_line(k: &Kit, label: &str, end: Vec<Node>, key: &str) -> Node {
    let mut kids = vec![txt(
        k.cx,
        label,
        weight(k.lk.body, 15.0, 400),
        color::TEXT_PRIMARY,
        Some(1),
    )];
    kids.push(Node::spacer());
    kids.extend(end);
    Node::hstack(Align::Center, Some(8.0), kids)
        .padding(ins(0.0, SHEET_SIDE, 0.0, SHEET_SIDE))
        .frame(Some(SHEET_WIDTH), Some(SHEET_ROW), Alignment::LEADING)
        .key(key)
}

/// The request sheet (`MacRequestSheetContent`): a 420 wide card with the heading at 24 / 24 / 12, the seasons to tick
/// (a series), the administrator's 4K switch and quality / folder menus, the quota line, "Abbrechen" and the one action.
/// Every height comes from the row count, so nothing moves while the sheet slides in. Keys `sheet:season:N`, `sheet:4k`,
/// `sheet:quality`, `sheet:folder`, `sheet:confirm`, `sheet-close`.
fn request_sheet(k: &Kit, s: &SeerrSheetInfo, list_scroll: (bool, bool)) -> Node {
    let (w, h) = (k.env.size.w, k.env.size.h);
    let side = |n: Node, top: f32, bottom: f32| n.padding(ins(top, SHEET_SIDE, bottom, SHEET_SIDE));
    let mut kids = vec![side(
        txt(
            k.cx,
            &s.title,
            weight(k.lk.rail, 20.0, 600),
            color::TEXT_PRIMARY,
            Some(2),
        )
        .frame(
            Some(SHEET_WIDTH - 2.0 * SHEET_SIDE),
            None,
            Alignment::LEADING,
        ),
        24.0,
        if s.rows.is_empty() { 6.0 } else { 12.0 },
    )];
    let rows: Vec<Node> = s
        .rows
        .iter()
        .map(|r| season_picker_row(k, r, &format!("sheet:season:{}", r.number)))
        .collect();
    if !rows.is_empty() {
        let height = (rows.len() as f32 * SHEET_ROW + 12.0).min(SHEET_LIST_MAX);
        kids.push(
            Node::scroll(
                Axis::Vertical,
                None,
                Node::vstack(Align::Start, Some(0.0), rows).padding(ins(6.0, 0.0, 6.0, 0.0)),
            )
            .key("sheet-list")
            .frame(Some(SHEET_WIDTH), Some(height), Alignment::TOP_LEADING)
            // The edges fade only where the list goes on (`seasonList`'s mask).
            .overlay(sheet_fade(list_scroll.0, true), Alignment::TOP_LEADING)
            .overlay(sheet_fade(list_scroll.1, false), Alignment::BOTTOM_LEADING),
        );
    }
    if let Some(t) = &s.four_k {
        kids.push(
            sheet_line(
                k,
                &t.label,
                vec![crate::forms::toggle_switch_mac(t.on)],
                "sheet:4k",
            )
            .on_tap(Action::from("sheet:4k")),
        );
    }
    for (row, key) in [(&s.quality, "sheet:quality"), (&s.folder, "sheet:folder")] {
        if let Some(c) = row {
            let end = vec![
                txt(
                    k.cx,
                    &c.value,
                    weight(k.lk.small, 13.0, 400),
                    color::TEXT_SECONDARY,
                    Some(1),
                ),
                k.icons
                    .node("caret-up-down", 11.0, false, color(color::TEXT_TERTIARY)),
            ];
            let n = sheet_line(k, &c.label, end, key);
            kids.push(if c.options.is_empty() {
                n
            } else {
                n.on_tap(Action::from(key))
                    .hover_surface(Color::new(1.0, 1.0, 1.0, 0.05), 0.0)
            });
        }
    }
    // The quota line's space is always there: it fills in without moving the buttons.
    let mut notes = vec![
        txt(
            k.cx,
            s.quota_line.as_deref().unwrap_or(" "),
            weight(k.lk.small, 13.0, 500),
            if s.quota_warning {
                color::STATE_WARNING
            } else {
                color::TEXT_TERTIARY
            },
            Some(2),
        )
        .frame(
            Some(SHEET_WIDTH - 2.0 * SHEET_SIDE),
            None,
            Alignment::LEADING,
        ),
    ];
    if let Some(e) = &s.error {
        notes.push(
            txt(
                k.cx,
                e,
                weight(k.lk.small, 13.0, 500),
                color::STATE_WARNING,
                Some(3),
            )
            .frame(
                Some(SHEET_WIDTH - 2.0 * SHEET_SIDE),
                None,
                Alignment::LEADING,
            ),
        );
    }
    kids.push(side(
        Node::vstack(Align::Start, Some(6.0), notes),
        12.0,
        20.0,
    ));
    let half = (SHEET_WIDTH - 2.0 * SHEET_SIDE - 10.0) / 2.0;
    let cancel = txt(
        k.cx,
        "Abbrechen",
        weight(k.lk.body, 14.0, 500),
        color::TEXT_PRIMARY,
        Some(1),
    )
    .frame(Some(half), Some(44.0), Alignment::CENTER)
    .background(
        Node::rect(color(color::SURFACE_RAISED), 10.0),
        Alignment::CENTER,
    )
    .key("sheet-close-button")
    .on_tap(Action::from("sheet-close"))
    .hover_surface(rgba(color::TEXT_PRIMARY, 0.08), 10.0)
    .press_style(PressStyle::Button);
    let on = s.primary.enabled && s.primary.kind != PrimaryKind::Busy;
    let confirm = txt(
        k.cx,
        &s.primary.text,
        weight(k.lk.body, 15.0, 600),
        if on {
            color::SURFACE_BASE
        } else {
            color::TEXT_TERTIARY
        },
        Some(1),
    )
    .frame(Some(half), Some(44.0), Alignment::CENTER)
    .background(
        Node::rect(
            color(if on {
                color::TEXT_PRIMARY
            } else {
                color::SURFACE_RAISED
            }),
            10.0,
        ),
        Alignment::CENTER,
    )
    .key("sheet:confirm");
    let confirm = if on {
        confirm
            .on_tap(Action::from("sheet:confirm"))
            .hover_surface(rgba(color::SURFACE_BASE, 0.12), 10.0)
            .press_style(PressStyle::Button)
    } else {
        confirm
    };
    kids.push(side(
        Node::hstack(Align::Center, Some(10.0), vec![cancel, confirm]),
        0.0,
        SHEET_SIDE,
    ));
    let card = Node::vstack(Align::Start, Some(0.0), kids)
        .frame(Some(SHEET_WIDTH), None, Alignment::TOP_LEADING)
        .background(
            Node::flexible()
                .paint(Paint::Fill {
                    color: color(color::SURFACE_CONTROL),
                    radius: 16.0,
                })
                .paint(Paint::Stroke {
                    color: color(color::SURFACE_FOCUS),
                    width: 1.0,
                    radius: 16.0,
                }),
            Alignment::CENTER,
        )
        .key("seerr-sheet");
    let catcher = Node::rect(Color::new(0.0, 0.0, 0.0, 0.45), 0.0)
        .on_tap_silent(Action::from("sheet-close"))
        .key("sheet-catcher");
    Node::zstack(Alignment::CENTER, vec![catcher, card]).frame(Some(w), Some(h), Alignment::CENTER)
}

/// `SeasonStatusRow`: the seasons of a title page with the status word; a free one opens the sheet.
fn season_status_row(k: &Kit, r: &SeerrSeasonRowInfo) -> Node {
    let key = format!("season:{}", r.number);
    let mut kids = vec![txt(
        k.cx,
        &r.title,
        weight(k.lk.body, 14.0, 500),
        color::TEXT_PRIMARY,
        Some(1),
    )];
    if let Some(e) = &r.episodes {
        kids.push(txt(
            k.cx,
            &format!("\u{b7} {e}"),
            weight(k.lk.small, 12.0, 400),
            color::TEXT_TERTIARY,
            Some(1),
        ));
    }
    kids.push(Node::spacer());
    kids.push(seerr_mark(k, &r.badge));
    let n = Node::hstack(Align::Center, Some(10.0), kids)
        .padding(ins(0.0, 14.0, 0.0, 14.0))
        .frame(Some(520.0), Some(40.0), Alignment::LEADING)
        .background(
            Node::rect(color(color::SURFACE_CONTROL), 10.0),
            Alignment::CENTER,
        )
        .key(key.as_str());
    if r.missing || r.selectable {
        n.on_tap(Action::from(key.as_str()))
            .hover_surface(rgba(color::TEXT_PRIMARY, 0.08), 10.0)
    } else {
        n
    }
}

/// The episodes of a title the server does not have, listed like a library series page lists them: the season chips
/// (`eps-season:N`, only with more than one season), then per episode the Mac `EpisodeRow` (still 160 x 90, "N. Name",
/// runtime and day, three lines of story). The rows come with the page's first answer from the core
/// (`SeerrSeasonRowInfo::episode_list`); a missing still is a quiet field of the same size, never a stand-in picture.
fn episodes_block(k: &Kit, i: &SeerrTitleInfo, picked: Option<i64>) -> Option<Node> {
    let current = i.episode_season(picked)?;
    let edge = k.lk.edge;
    let mut kids = vec![
        crate::detail_screen::rail_title(k, "Folgen")
            .frame(
                Some((k.env.size.w - 2.0 * edge).max(40.0)),
                None,
                Alignment::LEADING,
            )
            .padding(ins(0.0, edge, 0.0, edge)),
    ];
    let listed: Vec<&SeerrSeasonRowInfo> = i
        .seasons
        .iter()
        .filter(|s| !s.episode_list.is_empty())
        .collect();
    if listed.len() > 1 {
        let chips: Vec<Node> = listed
            .iter()
            .map(|s| {
                let key = format!("eps-season:{}", s.number);
                let (fg, bg) = if s.number == current.number {
                    (color::SURFACE_BASE, color::TEXT_PRIMARY)
                } else {
                    (color::TEXT_SECONDARY, color::SURFACE_CONTROL)
                };
                txt(k.cx, &s.title, weight(k.lk.small, 13.0, 600), fg, Some(1))
                    .padding(ins(7.0, 14.0, 7.0, 14.0))
                    .background(Node::rect(color(bg), 16.0), Alignment::CENTER)
                    .a11y(swiftly_ui::a11y::A11yNode::new(
                        "",
                        swiftly_ui::a11y::Role::Button,
                        format!("Folgen {}", s.title),
                    ))
                    .key(key.as_str())
                    .on_tap(Action::from(key.as_str()))
            })
            .collect();
        kids.push(Node::hstack(Align::Center, Some(8.0), chips).padding(ins(0.0, edge, 0.0, edge)));
    }
    let rows: Vec<Node> = current
        .episode_list
        .iter()
        .map(|e| {
            let still = match e.still.as_deref() {
                Some(url) => k.art.node_for(
                    remote(Some(url), swiftly_vm::ImageKind::Backdrop, 300, 169).as_ref(),
                    true,
                    &format!("episode:{}:{}", current.number, e.number),
                    160.0,
                    90.0,
                    10.0,
                ),
                None => Node::rect(color(color::SURFACE_CONTROL), 10.0).frame(
                    Some(160.0),
                    Some(90.0),
                    Alignment::CENTER,
                ),
            };
            crate::series_screen::mac_episode_row(
                k,
                still,
                &format!("{}. {}", e.number, e.title),
                &e.meta,
                false,
                e.overview.as_deref(),
                None,
            )
            .key(format!("episode:{}:{}", current.number, e.number).as_str())
        })
        .collect();
    kids.push(Node::vstack(Align::Start, Some(6.0), rows).padding(ins(0.0, edge - 10.0, 0.0, 0.0)));
    Some(Node::vstack(Align::Start, Some(12.0), kids).padding(ins(28.0, 0.0, 0.0, 0.0)))
}

/// The title page of a title that is not on the server (`SeerrDetailView`): head with backdrop, state line, one primary
/// button, the seasons with their status, the cast, the suggestions; the request sheet lies over it.
pub(crate) fn title_page(
    k: &Kit,
    i: &SeerrTitleInfo,
    address: &str,
    episode_season: Option<i64>,
    overview_open: bool,
    list_scroll: (bool, bool),
) -> (Node, Option<Node>) {
    let edge = k.lk.edge;
    match i.load {
        TitleLoad::Loading => {
            return (
                Node::vstack(
                    Align::Start,
                    Some(0.0),
                    vec![
                        txt(
                            k.cx,
                            &i.title,
                            weight(k.lk.rail, 30.0, 700),
                            color::TEXT_SECONDARY,
                            Some(1),
                        )
                        .padding(ins(150.0, edge, 0.0, edge)),
                    ],
                ),
                None,
            );
        }
        TitleLoad::Offline | TitleLoad::Failed | TitleLoad::Unavailable => {
            let (head, text) = if i.load == TitleLoad::Unavailable {
                ("Seerr ist nicht verbunden".to_owned(), String::new())
            } else {
                (
                    "Seerr antwortet gerade nicht".to_owned(),
                    i.error
                        .clone()
                        .unwrap_or_else(|| format!("{address} antwortet nicht.")),
                )
            };
            return (
                empty_state(
                    k,
                    "hard-drive-x",
                    &head,
                    &text,
                    Some(("Erneut versuchen", "retry")),
                ),
                None,
            );
        }
        TitleLoad::Content => {}
    }
    // The head is the library detail page's own (`detail_screen::hero`): title 44, details line, chips of a fixed height,
    // the white 280 x 56 button and the description in their own places, stacked in a normal flow (`DetailHeadBlock`).
    let head = crate::detail_screen::Head {
        id: format!("seerr:{}", i.tmdb),
        image: remote(
            i.backdrop.as_deref().or(i.poster.as_deref()),
            swiftly_vm::ImageKind::Backdrop,
            1280,
            720,
        ),
        title: i.title.clone(),
        secondary: i.secondary_line.clone(),
        overview: i.overview.clone().filter(|t| !t.is_empty()),
        ..Default::default()
    };
    let mut chips = Vec::new();
    if let Some(r) = i.rating.filter(|r| *r > 0.0) {
        chips.push(crate::detail_screen::mark(
            k,
            Some(("star.fill", color(color::TEXT_PRIMARY))),
            &format!("{r:.1}"),
            color::TEXT_PRIMARY,
            600,
            Color::new(1.0, 1.0, 1.0, 0.08),
        ));
    }
    if let Some(b) = &i.badge {
        let c = badge_colour(b.kind);
        chips.push(crate::detail_screen::mark(
            k,
            Some((b.symbol.as_str(), color(c))),
            &b.line,
            c,
            600,
            rgba(c, 0.15),
        ));
    }
    let mut buttons = vec![
        Node::hstack(Align::Center, Some(8.0), chips)
            .frame(None, Some(26.0), Alignment::LEADING)
            .padding(ins(14.0, 0.0, 0.0, 0.0)),
    ];
    let mut action = Vec::new();
    if let Some(b) = head_button(k, &i.primary) {
        action.push(b);
    }
    buttons.push(
        Node::hstack(Align::Center, Some(16.0), action)
            .frame(
                None,
                Some(desktop::DETAIL_BUTTON_HEIGHT),
                Alignment::LEADING,
            )
            .padding(ins(20.0, 0.0, 0.0, 0.0)),
    );
    if let Some(d) = crate::detail_screen::description(k, &head, overview_open) {
        buttons.push(d.padding(ins(36.0, 0.0, 0.0, 0.0)));
    }
    let hero = if k.lk.form == Form::Touch {
        let below =
            Node::vstack(Align::Start, Some(0.0), buttons).padding(ins(16.0, edge, 0.0, edge));
        Node::vstack(
            Align::Start,
            Some(0.0),
            vec![crate::detail_screen::hero(k, &head, Vec::new()), below],
        )
    } else {
        crate::detail_screen::hero(k, &head, buttons)
    };
    let mut kids = vec![hero];
    // Under the head the rows stack as the library page's do (`bottom_stack`: 36 below the head, the look's gap between).
    let mut rows = Vec::new();
    if !i.seasons.is_empty() {
        let list: Vec<Node> = i.seasons.iter().map(|r| season_status_row(k, r)).collect();
        rows.push(Node::vstack(Align::Start, Some(6.0), list).padding(ins(0.0, edge, 0.0, 0.0)));
    }
    if let Some(block) = episodes_block(k, i, episode_season) {
        rows.push(block);
    }
    if !i.cast.is_empty() {
        let cast: Vec<swiftly_vm::CastTile> = i
            .cast
            .iter()
            .enumerate()
            .map(|(n, c)| swiftly_vm::CastTile {
                id: format!("c{n}"),
                name: c.name.clone(),
                role: c.role.clone(),
                image: remote(c.image.as_deref(), swiftly_vm::ImageKind::Poster, 185, 185),
            })
            .collect();
        rows.push(crate::detail_screen::cast_rail(k, &cast));
    }
    if !i.similar.is_empty() {
        let tiles: Vec<Node> = i
            .similar
            .iter()
            .enumerate()
            .map(|(n, t)| seerr_tile_card(k, t, &format!("similar:{n}")))
            .collect();
        rows.push(crate::detail_screen::segment(
            k,
            "similar",
            "Ähnliche Titel",
            tiles,
            16.0,
            225.0 + 8.0 + 36.0,
        ));
    }
    if !rows.is_empty() {
        kids.push(crate::detail_screen::bottom_stack(k, rows, 36.0));
    }
    let sheet =
        (i.sheet.phase != SheetPhase::Closed).then(|| request_sheet(k, &i.sheet, list_scroll));
    let stack = Node::vstack(Align::Start, Some(0.0), kids);
    // The mood colour scrolls with the page under the head and the rows, as on the library page.
    let tones = k.art.tones_for(head.image.as_ref(), &head.id);
    let page = if tones.is_empty() || k.lk.form != Form::Desktop {
        stack
    } else {
        let total = crate::detail_screen::HERO_DESKTOP + swiftly_images::mood::RUN_OUT as f32;
        stack.background(
            crate::detail_screen::mood_strips(
                &tones,
                crate::detail_screen::HERO_DESKTOP,
                (0.0, total),
                0.0,
                k.env.size.w,
                |_| 1.0,
            ),
            Alignment::TOP_LEADING,
        )
    };
    (page, sheet)
}

// ---- "Meine Anfragen" -----------------------------------------------------------------------------------------------

/// `RequestRow`: poster, title with year, the state line with a bar while it downloads, the detail, "Zurückziehen".
fn request_row(k: &Kit, r: &SeerrRequestRow, index: usize, admin: bool) -> Node {
    let key = format!("row:{index}");
    let poster = k
        .art
        .node_for(
            remote(r.poster.as_deref(), swiftly_vm::ImageKind::Poster, 185, 278).as_ref(),
            false,
            &r.title,
            60.0,
            90.0,
            8.0,
        )
        .frame(Some(60.0), Some(90.0), Alignment::CENTER);
    let head = r
        .year
        .map_or(r.title.clone(), |y| format!("{} ({y})", r.title));
    let mut col = vec![
        txt(
            k.cx,
            &head,
            weight(k.lk.body, 16.0, 600),
            color::TEXT_PRIMARY,
            Some(1),
        ),
        txt(
            k.cx,
            &r.badge.line,
            weight(k.lk.small, 13.0, 500),
            badge_colour(r.badge.kind),
            Some(1),
        ),
    ];
    if let Some(p) = r.badge.progress {
        col.push(progress_bar(p, 240.0));
    }
    let detail = if admin {
        let art = if r.art == "tv" { "Serie" } else { "Film" };
        let parts: Vec<&str> = [Some(art), r.detail.as_deref(), r.requested_by.as_deref()]
            .into_iter()
            .flatten()
            .collect();
        Some(parts.join(" \u{b7} "))
    } else {
        r.detail.clone()
    };
    if let Some(d) = &detail {
        col.push(txt(
            k.cx,
            d,
            weight(k.lk.small, 12.0, 400),
            color::TEXT_TERTIARY,
            Some(2),
        ));
    }
    if let Some(t) = &r.work_text {
        col.push(txt(
            k.cx,
            t,
            weight(k.lk.small, 12.0, 400),
            if r.work == RowWork::Failed {
                color::STATE_WARNING
            } else {
                color::TEXT_SECONDARY
            },
            Some(2),
        ));
    }
    let mut row = vec![
        poster,
        Node::vstack(Align::Start, Some(4.0), col).frame(Some(420.0), None, Alignment::LEADING),
        Node::spacer(),
    ];
    if admin && r.work != RowWork::Working {
        for (on, label, verb, warn) in [
            (r.can_approve, "Freigeben", "approve", false),
            (r.can_decline, "Ablehnen", "decline", true),
            (r.can_retry, "Nochmal", "retry", false),
        ] {
            if on {
                row.push(verb_pill(k, label, &format!("{verb}:{}", r.id), warn));
            }
        }
    }
    if !admin && r.can_withdraw && r.work != RowWork::Working {
        let wk = format!("withdraw:{}", r.id);
        row.push(
            txt(
                k.cx,
                "Zurückziehen",
                weight(k.lk.body, 14.0, 500),
                crate::look_glow::accent(),
                Some(1),
            )
            .padding(ins(8.0, 12.0, 8.0, 12.0))
            .key(wk.as_str())
            .on_tap(Action::from(wk.as_str())),
        );
    }
    Node::hstack(Align::Center, Some(16.0), row)
        .padding(ins(10.0, 14.0, 10.0, 14.0))
        .background(
            Node::rect(color(color::SURFACE_CONTROL), 12.0),
            Alignment::CENTER,
        )
        .key(key.as_str())
        .on_tap(Action::from(key.as_str()))
        .hover_surface(rgba(color::TEXT_PRIMARY, 0.06), 12.0)
        .a11y_label(
            swiftly_ui::a11y::Role::Button,
            format!("{}, {}", r.title, r.badge.line),
        )
}

/// "Meine Anfragen" (`RequestsView`): the filter pills with counts, the rows, or the empty state.
pub(crate) fn requests_page(
    k: &Kit,
    i: &SeerrRequestsInfo,
    tabs: &[HubTab],
    over: &(AdminPane, CardState),
) -> (Node, Option<Node>) {
    let edge = k.lk.edge;
    let mut kids = vec![
        header(
            k,
            "Meine Anfragen",
            i.quota_summary.as_ref().map(|q| {
                txt(
                    k.cx,
                    q,
                    weight(k.lk.small, 13.0, 500),
                    color::TEXT_SECONDARY,
                    Some(1),
                )
            }),
        )
        .padding(ins(58.0, 0.0, 0.0, 0.0)),
    ];
    if !tabs.is_empty() {
        kids.push(capsules(k, &tab_items(tabs), "hub"));
    }
    if i.load == ListLoad::Content || !i.rows.is_empty() {
        let pills: Vec<Node> = i
            .pills
            .iter()
            .enumerate()
            .map(|(n, p)| {
                let key = format!("pill:{n}");
                let (fg, bg) = if p.selected {
                    (color::SURFACE_BASE, color::TEXT_PRIMARY)
                } else {
                    (color::TEXT_SECONDARY, color::SURFACE_CONTROL)
                };
                txt(
                    k.cx,
                    &format!("{} {}", p.title, p.count),
                    weight(k.lk.small, 13.0, 600),
                    fg,
                    Some(1),
                )
                .padding(ins(7.0, 14.0, 7.0, 14.0))
                .background(Node::rect(color(bg), 16.0), Alignment::CENTER)
                .key(key.as_str())
                .on_tap(Action::from(key.as_str()))
            })
            .collect();
        kids.push(
            Node::hstack(Align::Center, Some(8.0), pills).padding(ins(14.0, edge, 0.0, edge)),
        );
    }
    match i.load {
        ListLoad::Idle | ListLoad::Loading if i.rows.is_empty() => kids.push(
            txt(
                k.cx,
                "Lade …",
                weight(k.lk.body, 15.0, 400),
                color::TEXT_TERTIARY,
                Some(1),
            )
            .padding(ins(24.0, edge, 0.0, edge)),
        ),
        ListLoad::Offline | ListLoad::Failed => kids.push(empty_state(
            k,
            "hard-drive-x",
            "Seerr antwortet gerade nicht",
            i.error.as_deref().unwrap_or(""),
            Some(("Erneut versuchen", "retry")),
        )),
        _ if i.rows.is_empty() => kids.push(empty_state(
            k,
            "tray",
            "Noch nichts angefragt",
            "Was du bei Seerr anfragst, steht hier mit seinem Stand.",
            None,
        )),
        _ => kids.push(
            Node::vstack(
                Align::Start,
                Some(10.0),
                i.rows
                    .iter()
                    .enumerate()
                    .map(|(n, r)| request_row(k, r, n, false))
                    .collect(),
            )
            .padding(ins(16.0, edge, 0.0, edge)),
        ),
    }
    let sheet = match over {
        (AdminPane::Decline { title, .. }, _) => Some(decline_sheet(k, title)),
        (AdminPane::Request(id), card) => Some(request_card_sheet(k, card, *id)),
        (AdminPane::List, _) => None,
    };
    (Node::vstack(Align::Start, Some(0.0), kids), sheet)
}

// ---- the home block -------------------------------------------------------------------------------------------------

/// `ArrivalBanner` ("<Titel> ist da" with Abspielen and X), `AttentionLine` ("Wartet auf dich") and the "Angefragt" rail
/// of the home page; `None` when the core says to draw nothing. Keys `arrival-play`, `arrival-dismiss`,
/// `attention`, `home-seerr:{i}`. `width` is the room of the page (the banner and the line fill it, edges included).
pub(crate) fn home_block(
    k: &Kit,
    i: &SeerrHomeInfo,
    width: f32,
    part: HomePart,
    tv: bool,
) -> Option<Node> {
    // `Pending`: the core's blank content of the last start's shape, laid out like the real block but invisible and
    // untouchable, so the rails below stand where they stay when the answer comes (it fades in over the same room).
    let pending = match i.state {
        swiftly_vm::SeerrHomeState::Hidden => return None,
        swiftly_vm::SeerrHomeState::Pending => true,
        swiftly_vm::SeerrHomeState::Shown => false,
    };
    let edge = k.lk.edge;
    let inner = (width - 2.0 * edge).max(0.0);
    let mut kids: Vec<Node> = Vec::new();
    // The arrivals in the core's stack order, the front card first (`arrivals`; `arrival` alone when a host fills only it).
    let cards: Vec<&swiftly_vm::SeerrArrival> = if part == HomePart::Arrival {
        if i.arrivals.is_empty() {
            i.arrival.iter().collect()
        } else {
            i.arrivals.iter().collect()
        }
    } else {
        Vec::new()
    };
    if !cards.is_empty() {
        kids.push(arrival_stack(
            k,
            &cards,
            i.arrivals_expanded,
            inner,
            edge,
            pending,
            tv,
        ));
    }
    if part == HomePart::Arrival
        && let Some(a) = &i.attention
    {
        kids.push(quiet(
            arrival_control(
                Node::hstack(
                    Align::Center,
                    Some(10.0),
                    vec![
                        txt(
                            k.cx,
                            &a.title,
                            weight(k.lk.body, 15.0, 600),
                            color::TEXT_PRIMARY,
                            Some(1),
                        ),
                        txt(
                            k.cx,
                            &a.detail,
                            weight(k.lk.body, 14.0, 400),
                            color::TEXT_SECONDARY,
                            Some(1),
                        ),
                    ],
                )
                .frame(Some((inner - 32.0).max(0.0)), None, Alignment::LEADING)
                .padding(ins(12.0, 16.0, 12.0, 16.0))
                .background(
                    Node::rect(color(color::SURFACE_CONTROL), 12.0),
                    Alignment::CENTER,
                )
                .padding(ins(0.0, edge, 0.0, edge)),
                "attention",
                12.0,
                tv,
            ),
            pending,
        ));
    }
    if part == HomePart::Requests && !i.rail.is_empty() {
        let tiles: Vec<Node> = i
            .rail
            .iter()
            .enumerate()
            .map(|(n, t)| seerr_tile_card(k, t, &format!("home-seerr:{n}")))
            .collect();
        kids.push(quiet(
            crate::detail_screen::segment(
                k,
                "home-seerr",
                &i.rail_title,
                tiles,
                16.0,
                225.0 + 8.0 + 36.0,
            ),
            pending,
        ));
    }
    (!kids.is_empty()).then(|| {
        Node::vstack(Align::Start, Some(18.0), kids).opacity(1.0, swiftly_ui::feel::reveal())
    })
}

/// A part of the reserve that has no skeleton: takes its room, shows nothing, cannot be touched or read.
fn quiet(n: Node, pending: bool) -> Node {
    if pending {
        n.opacity(0.0, swiftly_ui::Motion::Instant)
            .disabled(true)
            .a11y_hidden()
    } else {
        n
    }
}

/// How many cards peek out below the front one while the stack is closed, and how far each is drawn in on both sides.
const PEEKS: usize = 2;
const PEEK_INSET: f32 = 14.0;
const PEEK_HEIGHT: f32 = 6.0;
const PEEK_GAP: f32 = 2.0;
/// One card is its cover (66) and the card's 12 above and below; the open list's gap and the height of "Weniger anzeigen".
const ARRIVAL_CARD_H: f32 = 90.0;
const OPEN_GAP: f32 = 8.0;
const OPEN_FOOTER_H: f32 = 32.0;

/// A focusable, clickable control: pointer and touch tap it, the TV's focus engine selects it.
fn arrival_control(n: Node, key: &str, radius: f32, tv: bool) -> Node {
    let n = n.key(key).on_tap(Action::from(key));
    if tv {
        n.focusable(
            swiftly_ui::components::focus_id(key),
            Some(swiftly_ui::FocusLook::tile(radius)),
        )
    } else {
        n
    }
}

/// One "ist da" card: cover and words (the body: a click or select opens the title, or opens the stack when it is
/// closed), the count of a closed stack, Abspielen and the X. `skeleton`: the same shape as calm placeholders, for the
/// room that is reserved while Seerr has not answered (same sizes as the real card, so nothing moves when it arrives).
fn arrival_card(
    k: &Kit,
    a: &swiftly_vm::SeerrArrival,
    inner: f32,
    badge: Option<usize>,
    body_key: &str,
    skeleton: bool,
    tv: bool,
) -> Node {
    let tone = crate::detail_screen::rgba(color::TEXT_PRIMARY, 0.10);
    let bar =
        |w: f32, h: f32| Node::rect(tone, h / 2.0).frame(Some(w), Some(h), Alignment::LEADING);
    let text_w = (inner - 330.0).clamp(80.0, 520.0);
    let id = a.request_id;
    let (poster, words, tail): (Node, Node, Vec<Node>) = if skeleton {
        (
            Node::rect(tone, 6.0).frame(Some(44.0), Some(66.0), Alignment::CENTER),
            Node::vstack(
                Align::Start,
                Some(10.0),
                vec![bar(text_w * 0.55, 14.0), bar(text_w * 0.35, 12.0)],
            )
            .frame(Some(text_w), None, Alignment::LEADING),
            vec![
                Node::rect(tone, 10.0).frame(Some(96.0), Some(34.0), Alignment::CENTER),
                Node::rect(tone, 16.0).frame(Some(32.0), Some(32.0), Alignment::CENTER),
            ],
        )
    } else {
        let poster = k
            .art
            .node_for(
                remote(a.poster.as_deref(), swiftly_vm::ImageKind::Poster, 185, 278).as_ref(),
                false,
                &a.title,
                44.0,
                66.0,
                6.0,
            )
            .frame(Some(44.0), Some(66.0), Alignment::CENTER);
        let words = txt(
            k.cx,
            &a.line,
            weight(k.lk.body, 16.0, 600),
            color::TEXT_PRIMARY,
            Some(2),
        )
        .frame(Some(text_w), None, Alignment::LEADING);
        let mut tail = Vec::new();
        if let Some(n) = badge {
            tail.push(
                txt(
                    k.cx,
                    &n.to_string(),
                    weight(k.lk.body, 13.0, 600),
                    color::TEXT_SECONDARY,
                    Some(1),
                )
                .padding(ins(4.0, 10.0, 4.0, 10.0))
                .background(
                    Node::rect(crate::detail_screen::rgba(color::TEXT_PRIMARY, 0.10), 999.0),
                    Alignment::CENTER,
                ),
            );
        }
        tail.push(arrival_control(
            txt(
                k.cx,
                "Abspielen",
                weight(k.lk.body, 14.0, 600),
                color::SURFACE_BASE,
                Some(1),
            )
            .padding(ins(8.0, 16.0, 8.0, 16.0))
            .background(
                Node::rect(color(color::TEXT_PRIMARY), 10.0),
                Alignment::CENTER,
            ),
            &format!("arrival-play:{id}"),
            10.0,
            tv,
        ));
        tail.push(arrival_control(
            k.icons
                .node("x", 16.0, true, color(color::TEXT_SECONDARY))
                .frame(Some(32.0), Some(32.0), Alignment::CENTER)
                .a11y_label(swiftly_ui::a11y::Role::Button, "Ausblenden"),
            &format!("arrival-dismiss:{id}"),
            16.0,
            tv,
        ));
        (poster, words, tail)
    };
    let body = Node::hstack(Align::Center, Some(14.0), vec![poster, words]);
    let body = if skeleton {
        body
    } else {
        let body = arrival_control(body, body_key, 14.0, tv);
        if body_key == "arrival-expand" {
            body.a11y_label(swiftly_ui::a11y::Role::Button, "Alle Meldungen anzeigen")
        } else {
            body
        }
    };
    let mut row = vec![body, Node::spacer()];
    row.extend(tail);
    Node::hstack(Align::Center, Some(14.0), row)
        .frame(Some((inner - 28.0).max(0.0)), None, Alignment::LEADING)
        .padding(ins(12.0, 16.0, 12.0, 12.0))
        .background(
            Node::rect(color(color::SURFACE_CONTROL), 14.0),
            Alignment::CENTER,
        )
}

/// The arrivals as the core's `ArrivalDeck` says: one card is a plain banner; several are a notification stack, closed
/// (the front card with the others peeking out below, a click or select opens it) or open (every card as a list and
/// "Weniger anzeigen"). Every card has its own X and Abspielen; a card click opens the title. While Seerr has not
/// answered (`pending`) the room holds skeleton cards of the same shape, and the real cards fade in over it.
fn arrival_stack(
    k: &Kit,
    cards: &[&swiftly_vm::SeerrArrival],
    expanded: bool,
    inner: f32,
    edge: f32,
    pending: bool,
    tv: bool,
) -> Node {
    let stacked = cards.len() > 1;
    let open = expanded && stacked;
    let motion =
        |lag: f64| swiftly_ui::feel::of_delayed(swiftly_motion::catalogue::Id::ArrivalStack, lag);
    // One room, every part at a place of its own that it moves to with the Mac's spring (`ArrivalMotion.spring`): the
    // cards open into a list, a closed card lets the ones below slide up, and the room itself grows and shrinks, so the
    // rows under it move with it and never jump. Each card follows the one above by a breath.
    let card_at = |index: usize, y: f32, body_key: &str, badge: Option<usize>| {
        let a = cards[index];
        let lag = 0.03 * index.min(4) as f64;
        arrival_card(k, a, inner, badge, body_key, pending, tv)
            .key(format!("arrival-card:{}", a.request_id).as_str())
            .offset(0.0, y, motion(lag))
            .opacity(1.0, motion(lag))
            .appear_from(1.0, 0.0)
            .appear_after_first_build()
            .exit_to(0.97, 0.0)
    };
    let step = ARRIVAL_CARD_H + OPEN_GAP;
    let mut layers: Vec<Node> = Vec::new();
    let height = if open {
        for (i, a) in cards.iter().copied().enumerate() {
            layers.push(card_at(
                i,
                i as f32 * step,
                &format!("arrival-open:{}", a.request_id),
                None,
            ));
        }
        let y = cards.len() as f32 * step;
        if !pending {
            layers.push(
                arrival_control(
                    txt(
                        k.cx,
                        "Weniger anzeigen",
                        weight(k.lk.body, 13.0, 600),
                        color::TEXT_SECONDARY,
                        Some(1),
                    )
                    .padding(ins(6.0, 14.0, 6.0, 14.0))
                    .background(
                        Node::rect(crate::detail_screen::rgba(color::TEXT_PRIMARY, 0.10), 999.0),
                        Alignment::CENTER,
                    ),
                    "arrival-collapse",
                    999.0,
                    tv,
                )
                .frame(
                    Some((inner - 28.0).max(0.0)),
                    Some(OPEN_FOOTER_H),
                    Alignment::CENTER,
                )
                .padding(ins(0.0, 14.0, 0.0, 0.0))
                .key("arrival-collapse-slot")
                .offset(0.0, y, motion(0.0))
                .opacity(1.0, motion(0.0))
                .appear_from(1.0, 0.0)
                .appear_after_first_build()
                .exit_to(1.0, 0.0),
            );
        }
        if pending {
            y - OPEN_GAP
        } else {
            y + OPEN_FOOTER_H
        }
    } else {
        let front = cards[0];
        let body_key = if stacked {
            "arrival-expand".to_owned()
        } else {
            format!("arrival-open:{}", front.request_id)
        };
        layers.push(card_at(0, 0.0, &body_key, stacked.then_some(cards.len())));
        // The peeks: cards behind the front one, lifted toward the text colour (dark on dark disappears) and drawn in
        // one step each. Only this room is laid out, so the rows below stand at the same place for any count.
        let peeks = (cards.len() - 1).min(PEEKS);
        for depth in 1..=peeks {
            let shade = if pending { 0.06 } else { 0.10 } * depth as f32;
            let y = ARRIVAL_CARD_H + PEEK_GAP + (depth - 1) as f32 * (PEEK_HEIGHT + PEEK_GAP);
            layers.push(
                Node::rect(color(color::SURFACE_CONTROL), 8.0)
                    .overlay(
                        Node::rect(crate::detail_screen::rgba(color::TEXT_PRIMARY, shade), 8.0),
                        Alignment::CENTER,
                    )
                    .frame(
                        Some((inner - 28.0 - 2.0 * PEEK_INSET * depth as f32).max(0.0)),
                        Some(PEEK_HEIGHT),
                        Alignment::CENTER,
                    )
                    .padding(ins(0.0, 14.0 + PEEK_INSET * depth as f32, 0.0, 0.0))
                    .key(format!("arrival-peek:{depth}").as_str())
                    .offset(0.0, y, motion(0.0))
                    .opacity(1.0, motion(0.0))
                    .appear_from(1.0, 0.0)
                    .appear_after_first_build()
                    .exit_to(1.0, 0.0),
            );
        }
        ARRIVAL_CARD_H + peeks as f32 * (PEEK_GAP + PEEK_HEIGHT)
    };
    let mut column = Node::zstack(Alignment::TOP_LEADING, layers)
        .animated_frame(None, Some(height), Alignment::TOP_LEADING, motion(0.0))
        .clipped()
        // The same node open or closed (its key never changes), so its height can move.
        .key("arrival-stack");
    if stacked && !pending && !open {
        // A click on the closed stack anywhere opens it; the buttons of the front card keep their own taps.
        column = column.on_tap(Action::from("arrival-expand"));
    }
    let column = column.padding(ins(0.0, edge, 0.0, edge));
    if pending {
        column
            .key("arrival-skeleton")
            .exit_to(1.0, 0.0)
            .opacity(1.0, swiftly_ui::feel::reveal())
    } else {
        column.reveal_as("arrival-cards")
    }
}

// ---- the page screen's side of it ---------------------------------------------------------------------------------

/// What a page of the new Seerr screens holds.
pub(crate) struct Side {
    pub(crate) desk: crate::seerr_desk::Desk,
    pub(crate) title: Option<std::sync::Arc<crate::seerr_desk::Title>>,
    /// The count of answers the page last drew.
    pub(crate) seen: u64,
    /// The season chip picked for the episode list (`None`: the first season that has episodes).
    pub(crate) episode_season: Option<i64>,
    /// The administrator page's own state (unused on the other pages).
    pub(crate) admin: AdminUi,
    /// The page was pushed over the settings screen: its "Server" tab can slide back to the server page there.
    pub(crate) server_tab: bool,
    /// The "Server" tab was tapped, once (the shell slides this page away).
    pub(crate) want_server: bool,
}

/// One tab of the management page: where it leads, its text, whether it is the one shown.
pub(crate) type HubTab = (crate::management_hub::Dest, String, bool);

fn tab_items(tabs: &[HubTab]) -> Vec<(String, bool)> {
    tabs.iter().map(|(_, t, on)| (t.clone(), *on)).collect()
}

impl Side {
    /// The management page's tab row with `selected` on: the core's sections this form draws (the Server tab only when
    /// the settings screen lies below); empty for a single section.
    pub(crate) fn hub_tabs(&self, selected: crate::management_hub::Dest) -> Vec<HubTab> {
        let Some(entry) = self.desk.entry() else {
            return Vec::new();
        };
        let tabs: Vec<HubTab> = crate::management_hub::tabs(&entry, selected)
            .into_iter()
            .filter(|t| self.server_tab || t.0 != crate::management_hub::Dest::Server)
            .collect();
        if tabs.len() < 2 { Vec::new() } else { tabs }
    }
}

impl PageScreen {
    /// The Seerr title page of the core's screens: asks the title at once; the request sheet opens over it.
    pub fn seerr_live(
        env: Env,
        cx: Cx,
        w: &crate::live::Wiring,
        hit: SeerrHit,
    ) -> Option<PageScreen> {
        let desk = crate::seerr_desk::Desk::stored(&w.core)?;
        let title = desk.title(&hit.art, hit.id);
        let t = std::sync::Arc::clone(&title);
        desk.run(async move {
            let _ = t.load().await;
        });
        let mut s = PageScreen::new(env, cx, Kind::SeerrTitle, Scenario::Loading);
        s.locale = w.core.host().locale;
        s.side = Some(Side {
            desk,
            title: Some(title),
            seen: 0,
            episode_season: None,
            admin: AdminUi::default(),
            server_tab: false,
            want_server: false,
        });
        s.refresh();
        Some(s)
    }

    /// "Meine Anfragen" over the stored Seerr session; `None` when Seerr is not connected.
    pub fn requests_live(env: Env, cx: Cx, w: &crate::live::Wiring) -> Option<PageScreen> {
        let desk = crate::seerr_desk::Desk::stored(&w.core)?;
        desk.load_requests();
        let mut s = PageScreen::new(env, cx, Kind::Requests, Scenario::Loading);
        s.locale = w.core.host().locale;
        s.side = Some(Side {
            desk,
            title: None,
            seen: 0,
            episode_season: None,
            admin: AdminUi::default(),
            server_tab: false,
            want_server: false,
        });
        s.refresh();
        Some(s)
    }

    /// "Verwaltung" over the stored Seerr session: reads the queue and the problems at once; `None` when Seerr is not
    /// connected.
    pub fn admin_live(env: Env, cx: Cx, w: &crate::live::Wiring) -> Option<PageScreen> {
        PageScreen::admin_live_on(env, cx, w, false)
    }

    /// The same, on the reports tab when `issues`.
    pub fn admin_live_on(
        env: Env,
        cx: Cx,
        w: &crate::live::Wiring,
        issues: bool,
    ) -> Option<PageScreen> {
        let desk = crate::seerr_desk::Desk::stored(&w.core)?;
        desk.load_admin();
        let mut s = PageScreen::new(env, cx, Kind::SeerrAdmin, Scenario::Loading);
        s.locale = w.core.host().locale;
        let ui = AdminUi::default();
        if issues {
            ui.set_tab(swiftly_vm::AdminTab::Issues);
        }
        s.side = Some(Side {
            desk,
            title: None,
            seen: 0,
            episode_season: None,
            admin: ui,
            server_tab: false,
            want_server: false,
        });
        s.refresh();
        Some(s)
    }

    /// The body of a page of the core's Seerr screens.
    pub(super) fn side_body(&self) -> Option<Body> {
        let side = self.side.as_ref()?;
        Some(match self.kind {
            Kind::SeerrAdmin => Body::Admin(Box::new(
                side.admin.body(side.desk.admin(), |on| side.hub_tabs(on)),
            )),
            Kind::SeerrTitle => {
                Body::Title(Box::new(side.title.as_ref()?.info()), side.episode_season)
            }
            _ => Body::Requests(
                Box::new(side.desk.lists().requests()),
                side.hub_tabs(crate::management_hub::Dest::Requests),
                Box::new(side.admin.pane()),
            ),
        })
    }

    /// The page was pushed over the settings screen (its "Server" tab leads back to the server page there).
    pub fn set_server_tab(&mut self, on: bool) {
        if let Some(s) = self.side.as_mut() {
            s.server_tab = on;
        }
    }

    /// The "Server" tab was tapped, once (the shell slides this page away and the settings screen shows the server).
    pub fn take_server_open(&mut self) -> bool {
        self.side
            .as_mut()
            .is_some_and(|s| std::mem::take(&mut s.want_server))
    }

    /// A call of the core's Seerr screens is out or an answer has not been drawn yet.
    pub(super) fn side_busy(&self) -> bool {
        self.side
            .as_ref()
            .is_some_and(|s| s.desk.busy() || s.desk.changed() != s.seen)
    }

    /// The taps of the Seerr pages; `true` when the tap was one of theirs.
    pub(super) fn side_tap(&mut self, a: &Action) -> bool {
        let is = |s: &str| *a == Action::from(s);
        if let Some(side) = self.side.as_mut()
            && matches!(self.kind, Kind::SeerrAdmin | Kind::Requests)
        {
            use crate::management_hub::Dest;
            let on = if self.kind == Kind::Requests {
                Dest::Requests
            } else if side.admin.tab_is(swiftly_vm::AdminTab::Issues) {
                Dest::Reports
            } else {
                Dest::Queue
            };
            for (n, (dest, _, _)) in side.hub_tabs(on).iter().enumerate() {
                if is(&format!("hub:{n}")) {
                    match dest {
                        Dest::Server => side.want_server = true,
                        Dest::Queue => side.admin.set_tab(swiftly_vm::AdminTab::Requests),
                        Dest::Reports => side.admin.set_tab(swiftly_vm::AdminTab::Issues),
                        Dest::Requests => {}
                    }
                    return true;
                }
            }
        }
        let Some(side) = self.side.as_ref() else {
            return false;
        };
        let desk = side.desk.clone();
        if self.kind == Kind::SeerrAdmin {
            return side.admin.tap(&desk, a);
        }
        if self.kind == Kind::Requests {
            let lists = std::sync::Arc::clone(desk.lists());
            let info = lists.requests();
            if is("retry") {
                desk.load_requests();
                return true;
            }
            for (n, p) in info.pills.iter().enumerate() {
                if is(&format!("pill:{n}")) {
                    let _ = lists.select_pill(p.pill);
                    return true;
                }
            }
            // An open card (and its sure-question) takes its own taps: verbs, close, decline.
            if side.admin.pane().0 != AdminPane::List && side.admin.tap(&desk, a) {
                return true;
            }
            for (n, r) in info.rows.iter().enumerate() {
                if is(&format!("withdraw:{}", r.id)) {
                    let id = r.id;
                    desk.run(async move {
                        let _ = lists.withdraw(id).await;
                    });
                    return true;
                }
                // The Mac opens the request's card here (`RequestDetailView`), not the title page.
                if is(&format!("row:{n}")) {
                    side.admin.open_mine(&desk, r.id);
                    return true;
                }
            }
            return false;
        }
        let Some(title) = side.title.clone() else {
            return false;
        };
        let info = title.info();
        let open = |title: std::sync::Arc<crate::seerr_desk::Title>, season: Option<i64>| {
            let _ = title.open_sheet(season);
            let t = std::sync::Arc::clone(&title);
            desk.run(async move {
                let _ = t.load_sheet().await;
            });
        };
        if is("overview") {
            self.host.sx.overview_open = !self.host.sx.overview_open;
        } else if is("primary") {
            open(title, None);
        } else if is("retry") {
            desk.run(async move {
                let _ = title.load().await;
            });
        } else if is("sheet-close") {
            let _ = title.close_sheet();
        } else if is("sheet:confirm") {
            desk.run(async move {
                let _ = title.confirm().await;
            });
        } else if is("sheet:quality") || is("sheet:folder") {
            let quality = is("sheet:quality");
            let key = if quality {
                "sheet:quality"
            } else {
                "sheet:folder"
            };
            let row = if quality {
                info.sheet.quality.as_ref()
            } else {
                info.sheet.folder.as_ref()
            };
            if let Some(row) = row {
                let rect = self
                    .host
                    .ui()
                    .frame_of(key)
                    .map_or(Rect::new(0.0, 0.0, 420.0, 44.0), |f| {
                        Rect::new(f[0], f[1], f[2], f[3])
                    });
                let items = row
                    .options
                    .iter()
                    .enumerate()
                    .map(|(n, o)| {
                        popover::MenuEntry::Item(
                            popover::MenuItem::new(
                                Action::from(format!("{key}:{n}").as_str()),
                                o.name.as_str(),
                            )
                            .checked(o.id == row.selected),
                        )
                    })
                    .collect();
                self.host
                    .sx
                    .menu
                    .open(items, popover::Anchor::Button(rect), 280.0, false);
            }
        } else if let Some((quality, id)) = [
            ("quality", &info.sheet.quality),
            ("folder", &info.sheet.folder),
        ]
        .into_iter()
        .find_map(|(which, row)| {
            row.as_ref()?
                .options
                .iter()
                .enumerate()
                .find(|(n, _)| is(&format!("sheet:{which}:{n}")))
                .map(|(_, o)| (which == "quality", o.id.clone()))
        }) {
            self.host.sx.menu.close();
            if quality {
                if let Ok(id) = id.parse::<i64>() {
                    let _ = title.choose_quality(id);
                }
            } else {
                let _ = title.choose_folder(id);
            }
        } else if is("sheet:4k") {
            let on = info.sheet.four_k.as_ref().is_some_and(|t| t.on);
            let _ = title.set_four_k(!on);
        } else if let Some(n) = info
            .sheet
            .rows
            .iter()
            .map(|r| r.number)
            .find(|n| is(&format!("sheet:season:{n}")))
        {
            let _ = title.toggle(n);
        } else if let Some(n) = info
            .seasons
            .iter()
            .map(|r| r.number)
            .find(|n| is(&format!("eps-season:{n}")))
        {
            // Only which season's episodes show; no call, the rows are all there already.
            if let Some(s) = self.side.as_mut() {
                s.episode_season = Some(n);
            }
        } else if let Some(n) = info
            .seasons
            .iter()
            .map(|r| r.number)
            .find(|n| is(&format!("season:{n}")))
        {
            open(title, Some(n));
        } else if let Some(c) = info
            .cast
            .iter()
            .enumerate()
            .find(|(n, _)| is(&format!("person:c{n}")))
            .map(|(_, c)| c)
        {
            // The same open-person rule as every host: a Seerr cast tile has no library id, only the TMDB one.
            let seerr = c.person_ref();
            self.person_tapped = Some(super::PersonTap {
                id: String::new(),
                name: c.name.clone(),
                role: c.role.clone(),
                image: super::remote(
                    seerr.image.as_deref(),
                    swiftly_vm::ImageKind::Poster,
                    185,
                    185,
                ),
                origin: Some(info.title.clone()),
                tmdb: Some(seerr.tmdb),
            });
        } else if let Some(t) = info
            .similar
            .iter()
            .enumerate()
            .find(|(n, _)| is(&format!("similar:{n}")))
            .map(|(_, t)| t)
        {
            self.seerr_tapped = Some(hit_of(t));
        } else {
            return false;
        }
        true
    }
}

// ---- "Verwaltung" ---------------------------------------------------------------------------------------------------

/// A verb of a queue row ("Freigeben", "Ablehnen", "Nochmal"); `warn` paints the declining one in the warning colour.
fn verb_pill(k: &Kit, label: &str, key: &str, warn: bool) -> Node {
    let fg = if warn {
        color::STATE_WARNING
    } else {
        crate::look_glow::accent()
    };
    txt(k.cx, label, weight(k.lk.small, 13.0, 600), fg, Some(1))
        .padding(ins(7.0, 14.0, 7.0, 14.0))
        .background(
            Node::rect(rgba(color::TEXT_PRIMARY, 0.10), 16.0),
            Alignment::CENTER,
        )
        .key(key)
        .on_tap(Action::from(key))
        .a11y_label(swiftly_ui::a11y::Role::Button, label.to_owned())
}

/// A row of capsules `{prefix}:{n}`: the tabs, the filter pills.
fn capsules(k: &Kit, items: &[(String, bool)], prefix: &str) -> Node {
    let pills: Vec<Node> = items
        .iter()
        .enumerate()
        .map(|(n, (text, on))| {
            let key = format!("{prefix}:{n}");
            let (fg, bg) = if *on {
                (color::SURFACE_BASE, color::TEXT_PRIMARY)
            } else {
                (color::TEXT_SECONDARY, color::SURFACE_CONTROL)
            };
            txt(k.cx, text, weight(k.lk.small, 13.0, 600), fg, Some(1))
                .padding(ins(7.0, 14.0, 7.0, 14.0))
                .background(Node::rect(color(bg), 16.0), Alignment::CENTER)
                .key(key.as_str())
                .on_tap(Action::from(key.as_str()))
                .a11y_label(swiftly_ui::a11y::Role::Button, text.clone())
        })
        .collect();
    Node::hstack(Align::Center, Some(8.0), pills).padding(ins(14.0, k.lk.edge, 0.0, k.lk.edge))
}

/// The surface of a dialog card: `fill` with the hairline border.
fn modal_surface(fill: swiftly_design::Colour) -> Node {
    Node::flexible()
        .paint(Paint::Fill {
            color: color(fill),
            radius: 16.0,
        })
        .paint(Paint::Stroke {
            color: color(color::SURFACE_FOCUS),
            width: 1.0,
            radius: 16.0,
        })
}

/// A card in the middle of the page over a dimmed catcher (a tap outside is `sheet-close`).
fn modal_over(k: &Kit, card: Node) -> Node {
    let (w, h) = (k.env.size.w, k.env.size.h);
    let catcher = Node::rect(Color::new(0.0, 0.0, 0.0, 0.45), 0.0)
        .on_tap_silent(Action::from("sheet-close"))
        .key("sheet-catcher");
    Node::zstack(Alignment::CENTER, vec![catcher, card]).frame(Some(w), Some(h), Alignment::CENTER)
}

/// A dialog card with its kids stacked, in the middle of the page.
fn modal(k: &Kit, kids: Vec<Node>) -> Node {
    let card = Node::vstack(Align::Start, Some(12.0), kids)
        .padding(ins(20.0, 20.0, 20.0, 20.0))
        .background(modal_surface(color::SURFACE_RAISED), Alignment::CENTER)
        .key("seerr-sheet");
    modal_over(k, card)
}

/// The pane of the administrator page that lies over the list: nothing, a request's card or the decline question.
#[derive(Clone, PartialEq, Default)]
pub(crate) enum AdminPane {
    #[default]
    List,
    /// A request's card (its lines come from the core when they arrive).
    Request(i64),
    /// "Anfrage ablehnen?" for this request; from the card it goes back to the card (the Mac's sheet lies over it).
    Decline {
        id: i64,
        title: String,
        from_card: bool,
    },
}

/// The card of an open request: being read, read, or not readable (never "Lade ..." for a read that failed).
#[derive(Clone, PartialEq, Default)]
pub(crate) enum CardState {
    #[default]
    Loading,
    Ready(Box<swiftly_vm::SeerrRequestCard>),
    Failed,
}

impl From<Option<swiftly_vm::SeerrRequestCard>> for CardState {
    fn from(read: Option<swiftly_vm::SeerrRequestCard>) -> CardState {
        read.map_or(CardState::Failed, |c| CardState::Ready(Box::new(c)))
    }
}

/// Everything the administrator page draws.
#[derive(Clone, PartialEq)]
pub(crate) struct AdminBody {
    pub(crate) tabs: Vec<swiftly_vm::SeerrTabInfo>,
    pub(crate) tab: swiftly_vm::AdminTab,
    /// The management page's tab row (`management_hub::tabs`); empty for a single section.
    pub(crate) hub: Vec<HubTab>,
    pub(crate) queue: SeerrRequestsInfo,
    pub(crate) issues: swiftly_vm::SeerrIssuesInfo,
    pub(crate) pane: AdminPane,
    pub(crate) card: CardState,
    /// The open problem with its thread (the core keeps which one).
    pub(crate) issue: Option<swiftly_vm::SeerrIssueDetail>,
    /// The reply field under the thread (its text, caret and blink) and whether a reply is on its way.
    pub(crate) reply: swiftly_ui::field::FieldView,
    pub(crate) reply_state: ReplyState,
}

/// The reply under an open problem: being written, or on its way to Seerr (the field and "Senden" wait meanwhile).
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub(crate) enum ReplyState {
    #[default]
    Writing,
    Sending,
}

struct AdminSt {
    tab: Option<swiftly_vm::AdminTab>,
    pane: AdminPane,
    card: CardState,
    /// The open card came from "Meine Anfragen" (its row can withdraw; the queue's cannot).
    mine: bool,
    /// The reply field; one editor, reset when another problem opens or the thread closes.
    reply: swiftly_ui::field::FieldState,
    reply_for: Option<i64>,
    reply_state: ReplyState,
    now: f64,
}

impl Default for AdminSt {
    fn default() -> AdminSt {
        AdminSt {
            tab: None,
            pane: AdminPane::default(),
            card: CardState::Loading,
            mine: false,
            reply: swiftly_ui::field::FieldState::new(swiftly_text::TextEditor::single_line()),
            reply_for: None,
            reply_state: ReplyState::Writing,
            now: 0.0,
        }
    }
}

/// What the page keeps besides the core's states: the tab, the pane over the list and the card of the open request.
#[derive(Clone, Default)]
pub(crate) struct AdminUi {
    st: std::sync::Arc<std::sync::Mutex<AdminSt>>,
}

fn held<T>(m: &std::sync::Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl AdminUi {
    /// The page now: the core's tabs (only those the rights allow), queue and problems, plus this page's pane.
    pub(crate) fn body(
        &self,
        admin: &crate::seerr_desk::Admin,
        hub: impl Fn(crate::management_hub::Dest) -> Vec<HubTab>,
    ) -> AdminBody {
        let tabs = admin.tabs();
        let mut st = held(&self.st);
        let issue = admin.issue_detail(false);
        // Another problem (or none) means a fresh, unfocused field.
        let open = issue.as_ref().map(|d| d.row.id);
        if st.reply_for != open {
            st.reply_for = open;
            st.reply = swiftly_ui::field::FieldState::new(swiftly_text::TextEditor::single_line());
            st.reply_state = ReplyState::Writing;
        }
        let tab = st
            .tab
            .filter(|t| tabs.iter().any(|x| x.tab == *t))
            .or_else(|| tabs.first().map(|t| t.tab))
            .unwrap_or(swiftly_vm::AdminTab::Requests);
        let on = if tab == swiftly_vm::AdminTab::Issues {
            crate::management_hub::Dest::Reports
        } else {
            crate::management_hub::Dest::Queue
        };
        AdminBody {
            tabs,
            tab,
            hub: hub(on),
            queue: admin.requests(),
            issues: admin.issues(),
            pane: st.pane.clone(),
            card: st.card.clone(),
            issue,
            reply: st.reply.view("Antwort schreiben \u{2026}", false, st.now),
            reply_state: st.reply_state,
        }
    }

    /// The clock of the caret's blink (the page's frame time).
    pub(crate) fn set_now(&self, now: f64) {
        held(&self.st).now = now;
    }

    /// The pane over "Meine Anfragen" (the same state the administrator page keeps: one card, one sure-question).
    pub(crate) fn pane(&self) -> (AdminPane, CardState) {
        let st = held(&self.st);
        (st.pane.clone(), st.card.clone())
    }

    /// A row of "Meine Anfragen" opens its card; the card is read from the account's own list so it can withdraw.
    pub(crate) fn open_mine(&self, desk: &crate::seerr_desk::Desk, id: i64) {
        {
            let mut st = held(&self.st);
            st.pane = AdminPane::Request(id);
            st.card = CardState::Loading;
            st.mine = true;
        }
        let slot = std::sync::Arc::clone(&self.st);
        let admin = std::sync::Arc::clone(desk.admin());
        let lists = std::sync::Arc::clone(desk.lists());
        desk.run(async move {
            reread(&slot, &admin, &lists, id, true).await;
        });
    }

    /// Whether the reply field has the keyboard.
    pub(crate) fn wants_text(&self) -> bool {
        let st = held(&self.st);
        st.reply.focused && st.reply_for.is_some()
    }

    /// Takes the keyboard away from the reply field.
    pub(crate) fn blur(&self) {
        let mut st = held(&self.st);
        let now = st.now;
        st.reply.set_focused(false, now);
    }

    /// One text-input event into the reply field: `None` when it has no keyboard, else whether Return was pressed.
    fn feed(&self, ev: &swiftly_text::TextInputEvent) -> Option<bool> {
        let mut st = held(&self.st);
        if !(st.reply.focused && st.reply_for.is_some()) {
            return None;
        }
        if st.reply_state == ReplyState::Sending {
            return Some(false);
        }
        let now = st.now;
        let mut clip = crate::field_book::SystemClipboard;
        Some(st.reply.apply(ev, &mut clip, now).submitted)
    }

    /// One text-input event for the reply field; Return sends. Returns whether the field took it.
    pub(crate) fn edit(
        &self,
        desk: &crate::seerr_desk::Desk,
        ev: &swiftly_text::TextInputEvent,
    ) -> bool {
        let Some(submitted) = self.feed(ev) else {
            return false;
        };
        if submitted {
            self.send(desk);
        }
        true
    }

    /// The text written so far (tests).
    pub(crate) fn reply_text(&self) -> String {
        held(&self.st).reply.editor.text().to_owned()
    }

    /// Posts the written reply through the core; the field clears when it went through (the core's error line shows
    /// otherwise and the text stays for another try).
    pub(crate) fn send(&self, desk: &crate::seerr_desk::Desk) {
        let admin = std::sync::Arc::clone(desk.admin());
        let text = {
            let mut st = held(&self.st);
            let text = st.reply.editor.text().trim().to_owned();
            if text.is_empty() || st.reply_state == ReplyState::Sending {
                return;
            }
            st.reply_state = ReplyState::Sending;
            text
        };
        let slot = std::sync::Arc::clone(&self.st);
        desk.run(async move {
            let out = admin.reply(text).await;
            let mut st = held(&slot);
            st.reply_state = ReplyState::Writing;
            if out.is_some_and(|d| d.error.is_none()) {
                st.reply.editor.set_text("");
            }
        });
    }

    /// Chooses the tab (the management page's tab row).
    pub(crate) fn set_tab(&self, tab: swiftly_vm::AdminTab) {
        held(&self.st).tab = Some(tab);
    }

    /// Whether `tab` is the one chosen (before the first choice: the first of the core's tabs).
    pub(crate) fn tab_is(&self, tab: swiftly_vm::AdminTab) -> bool {
        held(&self.st).tab == Some(tab)
    }

    /// A tap on the administrator page; every decision is the core's call, this only names which one.
    pub(crate) fn tap(&self, desk: &crate::seerr_desk::Desk, a: &Action) -> bool {
        let is = |s: &str| *a == Action::from(s);
        let admin = std::sync::Arc::clone(desk.admin());
        let b = self.body(&admin, |_| Vec::new());
        let mut st = held(&self.st);
        // The verbs of an open card keep the card (it reads again); "Zur\u{fc}ckziehen" is the one that leaves it.
        if let AdminPane::Request(id) = st.pane.clone() {
            let mine = st.mine;
            if is(&format!("approve:{id}")) || is(&format!("retry:{id}")) {
                let approve = is(&format!("approve:{id}"));
                let slot = std::sync::Arc::clone(&self.st);
                let lists = std::sync::Arc::clone(desk.lists());
                desk.run(async move {
                    let _ = if approve {
                        admin.approve(id).await
                    } else {
                        admin.retry(id).await
                    };
                    reread(&slot, &admin, &lists, id, mine).await;
                });
                return true;
            }
            if is(&format!("decline:{id}")) {
                let title = match &st.card {
                    CardState::Ready(c) => c.row.title.clone(),
                    _ => String::new(),
                };
                st.pane = AdminPane::Decline {
                    id,
                    title,
                    from_card: true,
                };
                return true;
            }
            if is(&format!("withdraw:{id}")) {
                st.pane = AdminPane::List;
                st.card = CardState::Loading;
                st.mine = false;
                let lists = std::sync::Arc::clone(desk.lists());
                desk.run(async move {
                    let _ = lists.withdraw(id).await;
                });
                return true;
            }
        }
        if is("reply-field") {
            let now = st.now;
            st.reply.set_focused(true, now);
            return true;
        }
        if is("reply-send") {
            drop(st);
            self.send(desk);
            return true;
        }
        // Any other tap takes the keyboard from the field.
        let now = st.now;
        st.reply.set_focused(false, now);
        if is("retry") {
            desk.run(async move {
                let _ = admin.load_requests().await;
                let _ = admin.load_issues().await;
            });
            return true;
        }
        if is("sheet-close") {
            if let AdminPane::Decline {
                id,
                from_card: true,
                ..
            } = st.pane
            {
                // "Abbrechen" on the sure-question: back to the card under it.
                st.pane = AdminPane::Request(id);
            } else if st.pane != AdminPane::List {
                st.pane = AdminPane::List;
                st.card = CardState::Loading;
                if std::mem::take(&mut st.mine) {
                    // The card may have changed the request: "Meine Anfragen" reads again (the Mac's `changed`).
                    desk.load_requests();
                }
            } else if b.issue.is_some() {
                admin.close_issue();
            }
            return true;
        }
        if is("decline-confirm") {
            if let AdminPane::Decline { id, from_card, .. } = st.pane.clone() {
                // From the card the card stays and reads again; from the list the list shows the verdict.
                let mine = st.mine;
                st.pane = if from_card {
                    AdminPane::Request(id)
                } else {
                    AdminPane::List
                };
                let slot = std::sync::Arc::clone(&self.st);
                let lists = std::sync::Arc::clone(desk.lists());
                desk.run(async move {
                    let _ = admin.decline(id).await;
                    if from_card {
                        reread(&slot, &admin, &lists, id, mine).await;
                    }
                });
            }
            return true;
        }
        if is("issue-resolve") || is("issue-reopen") {
            let resolve = is("issue-resolve");
            desk.run(async move {
                if resolve {
                    let _ = admin.resolve_issue().await;
                } else {
                    let _ = admin.reopen_issue().await;
                }
            });
            return true;
        }
        for (n, t) in b.tabs.iter().enumerate() {
            if is(&format!("tab:{n}")) {
                st.tab = Some(t.tab);
                return true;
            }
        }
        for (n, p) in b.queue.pills.iter().enumerate() {
            if is(&format!("pill:{n}")) {
                let _ = admin.select_pill(p.pill);
                return true;
            }
        }
        for (n, p) in b.issues.pills.iter().enumerate() {
            if is(&format!("ipill:{n}")) {
                let _ = admin.select_issue_pill(p.pill);
                return true;
            }
        }
        for r in &b.issues.rows {
            if is(&format!("issue:{}", r.id)) {
                let id = r.id;
                desk.run(async move {
                    let _ = admin.open_issue(id).await;
                });
                return true;
            }
        }
        for (n, r) in b.queue.rows.iter().enumerate() {
            let id = r.id;
            if is(&format!("approve:{id}")) || is(&format!("retry:{id}")) {
                let approve = is(&format!("approve:{id}"));
                st.pane = AdminPane::List;
                st.card = CardState::Loading;
                desk.run(async move {
                    let _ = if approve {
                        admin.approve(id).await
                    } else {
                        admin.retry(id).await
                    };
                });
                return true;
            }
            if is(&format!("decline:{id}")) {
                st.pane = AdminPane::Decline {
                    id,
                    title: r.title.clone(),
                    from_card: false,
                };
                return true;
            }
            if is(&format!("row:{n}")) {
                st.pane = AdminPane::Request(id);
                st.card = CardState::Loading;
                st.mine = false;
                let slot = std::sync::Arc::clone(&self.st);
                let lists = std::sync::Arc::clone(desk.lists());
                desk.run(async move {
                    reread(&slot, &admin, &lists, id, false).await;
                });
                return true;
            }
        }
        false
    }
}

/// "Anfrage ablehnen?": the sure-question over a request.
fn decline_sheet(k: &Kit, title: &str) -> Node {
    modal(
        k,
        vec![
            modal_text(k, "Anfrage ablehnen?", 20.0, 700, color::TEXT_PRIMARY),
            modal_text(k, title, 15.0, 600, color::TEXT_PRIMARY),
            modal_text(
                k,
                "Wer sie gestellt hat, sieht nur \u{201e}Abgelehnt\u{201c}.",
                13.0,
                400,
                color::TEXT_SECONDARY,
            ),
            modal_button(k, "Ablehnen", "decline-confirm", color::STATE_WARNING),
            modal_button(k, "Abbrechen", "sheet-close", color::TEXT_SECONDARY),
        ],
    )
}

/// Reads the card of request `id` again (from the account's own list or the queue) and keeps it, if that card is still
/// the open one.
async fn reread(
    slot: &std::sync::Mutex<AdminSt>,
    admin: &crate::seerr_desk::Admin,
    lists: &crate::seerr_desk::Lists,
    id: i64,
    mine: bool,
) {
    let read = if mine {
        lists.request_detail(id).await
    } else {
        admin.request_detail(id).await
    };
    let mut st = held(slot);
    if st.pane == AdminPane::Request(id) {
        st.card = CardState::from(read);
    }
}

/// The issue row: what kind of problem, the title, who reported it, and its state.
fn issue_row(k: &Kit, r: &swiftly_vm::SeerrIssueRow) -> Node {
    let key = format!("issue:{}", r.id);
    let place = [
        Some(r.kind_word.as_str()),
        r.place.as_deref(),
        r.time_text.as_deref(),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>()
    .join(" \u{b7} ");
    let who = [r.reporter.as_deref(), Some(r.status_word.as_str())]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(" \u{b7} ");
    let col = vec![
        txt(
            k.cx,
            &r.title,
            weight(k.lk.body, 16.0, 600),
            color::TEXT_PRIMARY,
            Some(1),
        ),
        txt(
            k.cx,
            &place,
            weight(k.lk.small, 13.0, 500),
            crate::look_glow::accent(),
            Some(1),
        ),
        txt(
            k.cx,
            &r.message,
            weight(k.lk.small, 12.0, 400),
            color::TEXT_SECONDARY,
            Some(2),
        ),
        txt(
            k.cx,
            &who,
            weight(k.lk.small, 12.0, 400),
            color::TEXT_TERTIARY,
            Some(1),
        ),
    ];
    Node::hstack(
        Align::Center,
        Some(16.0),
        vec![
            Node::vstack(Align::Start, Some(4.0), col).frame(Some(560.0), None, Alignment::LEADING),
            Node::spacer(),
        ],
    )
    .padding(ins(10.0, 14.0, 10.0, 14.0))
    .background(
        Node::rect(color(color::SURFACE_CONTROL), 12.0),
        Alignment::CENTER,
    )
    .key(key.as_str())
    .on_tap(Action::from(key.as_str()))
    .hover_surface(rgba(color::TEXT_PRIMARY, 0.06), 12.0)
    .a11y_label(
        swiftly_ui::a11y::Role::Button,
        format!("{}, {}", r.title, place),
    )
}

/// The reply field with its "Senden" under the thread (as the Mac's Verwaltung): one line in a calm box, the pill
/// quiet while there is nothing to send or a reply is on its way.
fn reply_row(k: &Kit, b: &AdminBody) -> Node {
    let look = swiftly_ui::field::FieldLook {
        style: swiftly_text::TextStyle::from(weight(k.lk.body, 15.0, 400)),
        text: color(color::TEXT_PRIMARY),
        placeholder: color(color::TEXT_TERTIARY),
        caret: color(color::ACCENT_SELECTION),
        selection: color(color::ACCENT_SELECTION).with_alpha(0.30),
        caret_height: Some(18.0),
    };
    let field = Node::hstack(
        Align::Center,
        Some(0.0),
        vec![
            swiftly_ui::field::field_content(k.cx, &b.reply, &look),
            Node::spacer(),
        ],
    )
    .padding(ins(10.0, 14.0, 10.0, 14.0))
    .frame(Some(330.0), None, Alignment::LEADING)
    .background(
        Node::rect(color(color::SURFACE_CONTROL), 12.0),
        Alignment::CENTER,
    )
    .key("reply-field")
    .on_tap(Action::from("reply-field"))
    .a11y(swiftly_ui::a11y::A11yNode::new(
        "reply-field",
        swiftly_ui::a11y::Role::TextField,
        "Antwort schreiben \u{2026}",
    ));
    let ready = !b.reply.display.text.trim().is_empty() && b.reply_state == ReplyState::Writing;
    let send = txt(
        k.cx,
        "Senden",
        weight(k.lk.small, 13.0, 600),
        if ready {
            color::ACCENT_SELECTION
        } else {
            color::TEXT_TERTIARY
        },
        Some(1),
    )
    .padding(ins(7.0, 14.0, 7.0, 14.0))
    .background(
        Node::rect(rgba(color::TEXT_PRIMARY, 0.10), 16.0),
        Alignment::CENTER,
    )
    .key("reply-send")
    .on_tap(Action::from("reply-send"))
    .a11y_label(swiftly_ui::a11y::Role::Button, "Senden".to_owned());
    Node::hstack(Align::Center, Some(8.0), vec![field, send])
}

/// The width of the request card (the Mac shows `RequestDetailView` in a 480 pt window sheet).
const CARD_WIDTH: f32 = 480.0;
const CARD_SIDE: f32 = 20.0;

/// `RequestDetailView`: the poster (80 x 120) beside the title (20 bold, up to three lines), the kind line (13) and the state
/// line (14 medium, with the bar while it downloads), one card of label / value rows (15; 13 above and below, hairlines from 16)
/// and the verbs the core allows, as full-width buttons. The close button sits top right, as the sheet's X on the Mac.
fn request_card(k: &Kit, c: &swiftly_vm::SeerrRequestCard, id: i64) -> Node {
    let r = &c.row;
    let poster = k
        .art
        .node_for(
            remote(r.poster.as_deref(), swiftly_vm::ImageKind::Poster, 185, 278).as_ref(),
            false,
            &r.title,
            80.0,
            120.0,
            8.0,
        )
        .frame(Some(80.0), Some(120.0), Alignment::CENTER);
    let text_w = CARD_WIDTH - 2.0 * CARD_SIDE - 80.0 - 14.0;
    let art = if r.art == "tv" { "Serie" } else { "Film" };
    let kind = [Some(art), r.detail.as_deref()]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(" \u{b7} ");
    let mut col = vec![
        txt(
            k.cx,
            &r.title,
            weight(k.lk.body, 20.0, 700),
            color::TEXT_PRIMARY,
            Some(3),
        )
        .frame(Some(text_w), None, Alignment::LEADING),
        txt(
            k.cx,
            &kind,
            weight(k.lk.small, 13.0, 400),
            color::TEXT_TERTIARY,
            Some(1),
        )
        .frame(Some(text_w), None, Alignment::LEADING),
        txt(
            k.cx,
            &r.badge.line,
            weight(k.lk.body, 14.0, 500),
            badge_colour(r.badge.kind),
            Some(2),
        )
        .frame(Some(text_w), None, Alignment::LEADING)
        .padding(ins(2.0, 0.0, 0.0, 0.0)),
    ];
    if let Some(p) = r.badge.progress {
        col.push(progress_bar(p, text_w).padding(ins(4.0, 0.0, 0.0, 0.0)));
    }
    let head = Node::hstack(
        Align::Start,
        Some(14.0),
        vec![poster, Node::vstack(Align::Start, Some(4.0), col)],
    )
    .padding(ins(0.0, CARD_SIDE, 0.0, CARD_SIDE));
    let inner = CARD_WIDTH - 2.0 * CARD_SIDE;
    let mut lines = vec![];
    for (n, row) in c.rows.iter().enumerate() {
        if n > 0 {
            lines.push(
                Node::rect(rgba(color::TEXT_PRIMARY, 0.08), 0.0)
                    .frame(Some(inner - 16.0), Some(1.0), Alignment::CENTER)
                    .padding(ins(0.0, 16.0, 0.0, 0.0)),
            );
        }
        lines.push(
            Node::hstack(
                Align::Center,
                Some(12.0),
                vec![
                    txt(
                        k.cx,
                        &row.label,
                        weight(k.lk.body, 15.0, 400),
                        color::TEXT_SECONDARY,
                        Some(2),
                    ),
                    Node::spacer(),
                    txt(
                        k.cx,
                        &row.value,
                        weight(k.lk.body, 15.0, 400),
                        color::TEXT_PRIMARY,
                        Some(3),
                    ),
                ],
            )
            .padding(ins(13.0, 16.0, 13.0, 16.0))
            .frame(Some(inner), None, Alignment::LEADING),
        );
    }
    let mut kids = vec![head];
    if !lines.is_empty() {
        kids.push(
            Node::vstack(Align::Start, Some(0.0), lines)
                .frame(Some(inner), None, Alignment::LEADING)
                .background(
                    Node::rect(color(color::SURFACE_RAISED), 12.0),
                    Alignment::CENTER,
                )
                .padding(ins(0.0, CARD_SIDE, 0.0, CARD_SIDE)),
        );
    }
    let verb = |label: &str, key: String, primary: bool| {
        txt(
            k.cx,
            label,
            weight(k.lk.body, 15.0, 600),
            if primary {
                color::SURFACE_BASE
            } else {
                color::TEXT_PRIMARY
            },
            Some(1),
        )
        .frame(Some(inner), Some(44.0), Alignment::CENTER)
        .background(
            Node::rect(
                color(if primary {
                    color::TEXT_PRIMARY
                } else {
                    color::SURFACE_RAISED
                }),
                10.0,
            ),
            Alignment::CENTER,
        )
        .key(key.as_str())
        .on_tap(Action::from(key.as_str()))
        .hover_surface(
            rgba(
                if primary {
                    color::SURFACE_BASE
                } else {
                    color::TEXT_PRIMARY
                },
                0.10,
            ),
            10.0,
        )
        .press_style(PressStyle::Button)
        .a11y_label(swiftly_ui::a11y::Role::Button, label.to_owned())
        .padding(ins(0.0, CARD_SIDE, 0.0, CARD_SIDE))
    };
    let mut verbs = vec![];
    if r.can_approve {
        verbs.push(verb("Freigeben", format!("approve:{id}"), true));
    }
    if r.can_retry {
        verbs.push(verb("Nochmal", format!("retry:{id}"), true));
    }
    if r.can_decline {
        verbs.push(verb("Ablehnen", format!("decline:{id}"), false));
    }
    if r.can_withdraw {
        verbs.push(verb("Zur\u{fc}ckziehen", format!("withdraw:{id}"), false));
    }
    if !verbs.is_empty() {
        kids.push(Node::vstack(Align::Start, Some(10.0), verbs));
    }
    Node::vstack(Align::Start, Some(18.0), kids).padding(ins(36.0, 0.0, 24.0, 0.0))
}

/// The card over a dimmed catcher: the Mac's sheet background (`area`), the 28 pt close circle top right.
fn request_card_sheet(k: &Kit, card: &CardState, id: i64) -> Node {
    let room = CARD_WIDTH - 2.0 * CARD_SIDE;
    let body = match card {
        CardState::Loading => modal_text(k, "Lade \u{2026}", 15.0, 400, color::TEXT_TERTIARY)
            .frame(Some(room), Some(160.0), Alignment::CENTER),
        // `RequestDetailView`: "Seerr antwortet gerade nicht" over the line that names the request.
        CardState::Failed => Node::vstack(
            Align::Center,
            Some(8.0),
            vec![
                modal_text(
                    k,
                    "Seerr antwortet gerade nicht",
                    17.0,
                    600,
                    color::TEXT_PRIMARY,
                ),
                modal_text(
                    k,
                    "Diese Anfrage l\u{e4}sst sich gerade nicht lesen.",
                    14.0,
                    400,
                    color::TEXT_SECONDARY,
                ),
            ],
        )
        .frame(Some(room), Some(160.0), Alignment::CENTER),
        CardState::Ready(c) => request_card(k, c, id),
    };
    let close = k
        .icons
        .node("x", 12.0, true, color(color::TEXT_SECONDARY))
        .frame(Some(28.0), Some(28.0), Alignment::CENTER)
        .background(
            Node::rect(color(color::SURFACE_RAISED), 14.0),
            Alignment::CENTER,
        )
        .key("sheet-close")
        .on_tap(Action::from("sheet-close"))
        .hover_surface(rgba(color::TEXT_PRIMARY, 0.08), 14.0)
        .press_style(PressStyle::Button)
        .a11y_label(swiftly_ui::a11y::Role::Button, "Schlie\u{df}en".to_owned())
        .padding(ins(12.0, 12.0, 12.0, 12.0));
    let card = Node::zstack(
        Alignment::TOP_TRAILING,
        vec![
            body.frame(Some(CARD_WIDTH), None, Alignment::TOP_LEADING),
            close,
        ],
    )
    .background(modal_surface(color::SURFACE_CONTROL), Alignment::CENTER)
    .key("seerr-sheet");
    modal_over(k, card)
}

fn modal_text(k: &Kit, text: &str, size: f32, w: u16, c: swiftly_design::Colour) -> Node {
    txt(k.cx, text, weight(k.lk.body, size, w), c, Some(4)).frame(
        Some(420.0),
        None,
        Alignment::LEADING,
    )
}

fn modal_button(k: &Kit, label: &str, key: &str, c: swiftly_design::Colour) -> Node {
    // The accessible name is the visible word (the core's, "Ablehnen"); the stable `btn-<key>` is how a live script
    // finds this one button (`move-label #btn-decline-confirm`) when the same word is also a verb on a row under it.
    txt(k.cx, label, weight(k.lk.body, 15.0, 600), c, Some(1))
        .padding(ins(8.0, 12.0, 8.0, 12.0))
        .key(key)
        .on_tap(Action::from(key))
        .a11y(swiftly_ui::a11y::A11yNode::new(
            format!("btn-{key}"),
            swiftly_ui::a11y::Role::Button,
            label,
        ))
}

/// The administrator page: the tabs, the queue or the problems, and the pane that lies over them.
pub(crate) fn admin_page(k: &Kit, b: &AdminBody) -> (Node, Option<Node>) {
    let edge = k.lk.edge;
    let mut kids = vec![header(k, "Verwaltung", None).padding(ins(58.0, 0.0, 0.0, 0.0))];
    if b.tabs.is_empty() {
        kids.push(empty_state(
            k,
            "tray",
            "Nichts zu verwalten",
            "Hier erscheint, worüber du bei Seerr entscheidest.",
            None,
        ));
        return (Node::vstack(Align::Start, Some(0.0), kids), None);
    }
    if !b.hub.is_empty() {
        kids.push(capsules(k, &tab_items(&b.hub), "hub"));
    } else if b.tabs.len() > 1 {
        let items: Vec<(String, bool)> = b
            .tabs
            .iter()
            .map(|t| (format!("{} {}", t.title, t.count), t.tab == b.tab))
            .collect();
        kids.push(capsules(k, &items, "tab"));
    }
    if b.tab == swiftly_vm::AdminTab::Requests {
        let i = &b.queue;
        let pills: Vec<(String, bool)> = i
            .pills
            .iter()
            .map(|p| (format!("{} {}", p.title, p.count), p.selected))
            .collect();
        kids.push(capsules(k, &pills, "pill"));
        match i.load {
            ListLoad::Idle | ListLoad::Loading if i.rows.is_empty() => kids.push(
                txt(
                    k.cx,
                    "Lade …",
                    weight(k.lk.body, 15.0, 400),
                    color::TEXT_TERTIARY,
                    Some(1),
                )
                .padding(ins(24.0, edge, 0.0, edge)),
            ),
            ListLoad::Offline | ListLoad::Failed => kids.push(empty_state(
                k,
                "hard-drive-x",
                "Seerr antwortet gerade nicht",
                i.error.as_deref().unwrap_or(""),
                Some(("Erneut versuchen", "retry")),
            )),
            _ if i.rows.is_empty() => kids.push(empty_state(
                k,
                "check-circle",
                "Nichts zu entscheiden",
                "Neue Anfragen erscheinen hier.",
                None,
            )),
            _ => kids.push(
                Node::vstack(
                    Align::Start,
                    Some(10.0),
                    i.rows
                        .iter()
                        .enumerate()
                        .map(|(n, r)| request_row(k, r, n, true))
                        .collect(),
                )
                .padding(ins(16.0, edge, 0.0, edge)),
            ),
        }
    } else {
        let i = &b.issues;
        let pills: Vec<(String, bool)> = i
            .pills
            .iter()
            .map(|p| (format!("{} {}", p.title, p.count), p.selected))
            .collect();
        kids.push(capsules(k, &pills, "ipill"));
        match i.load {
            ListLoad::Idle | ListLoad::Loading if i.rows.is_empty() => kids.push(
                txt(
                    k.cx,
                    "Lade …",
                    weight(k.lk.body, 15.0, 400),
                    color::TEXT_TERTIARY,
                    Some(1),
                )
                .padding(ins(24.0, edge, 0.0, edge)),
            ),
            ListLoad::Offline | ListLoad::Failed => kids.push(empty_state(
                k,
                "hard-drive-x",
                "Seerr antwortet gerade nicht",
                i.error.as_deref().unwrap_or(""),
                Some(("Erneut versuchen", "retry")),
            )),
            _ if i.rows.is_empty() => kids.push(empty_state(
                k,
                "tray",
                "Keine Probleme",
                "Gemeldete Probleme erscheinen hier.",
                None,
            )),
            _ => kids.push(
                Node::vstack(
                    Align::Start,
                    Some(10.0),
                    i.rows.iter().map(|r| issue_row(k, r)).collect(),
                )
                .padding(ins(16.0, edge, 0.0, edge)),
            ),
        }
    }
    let sheet = match (&b.pane, &b.issue) {
        (AdminPane::Decline { title, .. }, _) => Some(decline_sheet(k, title)),
        (AdminPane::Request(id), _) => Some(request_card_sheet(k, &b.card, *id)),
        (AdminPane::List, Some(d)) => {
            let place = [
                Some(d.row.kind_word.as_str()),
                d.row.place.as_deref(),
                d.row.time_text.as_deref(),
            ]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" \u{b7} ");
            let mut sheet = vec![
                modal_text(k, &d.row.title, 20.0, 700, color::TEXT_PRIMARY),
                modal_text(
                    k,
                    &format!("{place} \u{b7} {}", d.row.status_word),
                    13.0,
                    500,
                    crate::look_glow::accent(),
                ),
            ];
            for m in &d.messages {
                let mut who = if m.by_admin {
                    format!("{} \u{b7} Verwaltung", m.author)
                } else {
                    m.author.clone()
                };
                if let Some(when) = &m.when_text {
                    who = format!("{who} \u{b7} {when}");
                }
                sheet.push(
                    Node::vstack(
                        Align::Start,
                        Some(3.0),
                        vec![
                            modal_text(
                                k,
                                &who,
                                12.0,
                                600,
                                if m.mine {
                                    crate::look_glow::accent()
                                } else {
                                    color::TEXT_SECONDARY
                                },
                            ),
                            modal_text(k, &m.text, 14.0, 400, color::TEXT_PRIMARY),
                        ],
                    )
                    .padding(ins(8.0, 12.0, 8.0, 12.0))
                    .background(
                        Node::rect(color(color::SURFACE_CONTROL), 10.0),
                        Alignment::CENTER,
                    )
                    .key(format!("msg:{}", m.id).as_str()),
                );
            }
            if let Some(e) = &d.error {
                sheet.push(modal_text(k, e, 13.0, 400, color::STATE_WARNING));
            }
            if d.can_reply {
                sheet.push(reply_row(k, b));
            }
            let mut verbs = vec![];
            if d.can_resolve {
                verbs.push(verb_pill(k, "Erledigt", "issue-resolve", false));
            }
            if d.can_reopen {
                verbs.push(verb_pill(k, "Wieder öffnen", "issue-reopen", false));
            }
            if !verbs.is_empty() {
                sheet.push(Node::hstack(Align::Center, Some(8.0), verbs));
            }
            sheet.push(modal_button(
                k,
                "Schließen",
                "sheet-close",
                color::TEXT_SECONDARY,
            ));
            Some(modal(k, sheet))
        }
        _ => None,
    };
    (Node::vstack(Align::Start, Some(0.0), kids), sheet)
}

#[cfg(test)]
mod reply_tests {
    use super::*;

    #[test]
    fn a_card_that_could_not_be_read_is_failed_not_loading() {
        assert!(matches!(CardState::from(None), CardState::Failed));
        assert!(matches!(CardState::default(), CardState::Loading));
    }

    fn open_thread(ui: &AdminUi) {
        let mut st = held(&ui.st);
        st.reply_for = Some(7);
        st.reply.set_focused(true, 0.0);
    }

    #[test]
    fn typed_text_lands_in_the_reply_and_return_asks_to_send() {
        let ui = AdminUi::default();
        assert_eq!(
            ui.feed(&swiftly_text::TextInputEvent::Text("x".into())),
            None
        );
        open_thread(&ui);
        assert!(ui.wants_text());
        assert_eq!(
            ui.feed(&swiftly_text::TextInputEvent::Text("Hallo".into())),
            Some(false)
        );
        assert_eq!(ui.reply_text(), "Hallo");
        let enter = swiftly_text::TextInputEvent::Key(
            swiftly_text::EditKey::Enter,
            swiftly_text::Mods::NONE,
        );
        assert_eq!(ui.feed(&enter), Some(true));
    }

    #[test]
    fn nothing_is_typed_while_a_reply_is_on_its_way() {
        let ui = AdminUi::default();
        open_thread(&ui);
        held(&ui.st).reply_state = ReplyState::Sending;
        assert_eq!(
            ui.feed(&swiftly_text::TextInputEvent::Text("x".into())),
            Some(false)
        );
        assert_eq!(ui.reply_text(), "");
    }

    #[test]
    fn blur_takes_the_keyboard() {
        let ui = AdminUi::default();
        open_thread(&ui);
        ui.blur();
        assert!(!ui.wants_text());
    }
}
