//! The Search screen of the shared Rust UI, drawn from `SearchVm` parts for `touch`, `desktop` and `tv`: field, results
//! grouped (Serien, Filme), recents, empty and offline states. Differences from the Swift screens:
//!
//! The text field is the shared one (`swiftly_ui::field` over `swiftly_text::TextEditor`): caret and selection,
//! composition, paste, undo. The per-OS bridges (system keyboard, IME inset, screen reader) are in

use crate::browse::{self, Art, Metrics, Scenario};
use crate::home::{Bar, Form, empty_state, fill_frame, ins, text};
use crate::hub::HubSlotExt;
use crate::net::AppTransport;
use std::rc::Rc;
use std::sync::Arc;
use swiftly_design::tokens::{colour, touch, tv};
use swiftly_layout::{Align, Alignment, Axis, EdgeInsets};
use swiftly_library::MemoryKeyValue;
use swiftly_render::{Color, DrawList, RgbaImage};
use swiftly_text::{Clipboard, TextEditor, TextInputEvent};
use swiftly_ui::a11y::A11yNode;
use swiftly_ui::components::{color, focus_id};
use swiftly_ui::field::{FieldState, FieldView};
use swiftly_ui::icons::Icons;
use swiftly_ui::{Action, Cx, Env, FocusLook, Node, Paint, Ui, UiEvent, tuning};
use swiftly_vm::{
    SearchGroup, SearchIntent, SearchKind, SearchResultsPart, SearchStatus, SearchStatusPart,
    SearchVm,
};

/// The placeholder of the field (`SearchField.placeholder`).
pub const PLACEHOLDER: &str = "Filme, Serien, Folgen";

#[derive(Clone, PartialEq)]
struct Parts {
    status: Arc<SearchStatusPart>,
    results: Arc<SearchResultsPart>,
    recents: Arc<Vec<String>>,
    text: String,
    field: FieldView,
    bar: Bar,
    pictures: u64,
    menu: crate::desk::TileMenu,
    /// What Seerr knows and the own server does not (empty when nothing is connected).
    seerr: Vec<swiftly_vm::SeerrTile>,
}

struct Ctx {
    art: Art,
    icons: Icons,
    /// The pictures of the Seerr tiles (TMDB addresses through the same hub).
    seerr_art: crate::detail_screen::Art,
}

/// Fills the width only (`fill_frame` also takes all the height).
fn wide(n: Node, align: Alignment) -> Node {
    n.flex_frame(swiftly_layout::FlexFrame {
        max_w: Some(f32::INFINITY),
        align: Some(align),
        ..swiftly_layout::FlexFrame::default()
    })
}

fn st(size: f32, weight: u16) -> swiftly_design::TextStyle {
    swiftly_design::TextStyle {
        size,
        weight,
        tracking: 0.0,
        uppercase: false,
    }
}

fn section_title(cx: &Cx, m: &Metrics, s: &str, tracking: f32) -> Node {
    // tv: `Theme.rail` 44 bold.
    let style = if m.form == Form::Tv {
        st(44.0, 700)
    } else if m.form == Form::Desktop {
        // Mac `category` and `group`: `Theme.section` 22 bold; blocks track -0.484, group titles -0.2.
        swiftly_design::TextStyle {
            tracking,
            ..st(22.0, 700)
        }
    } else {
        st(17.0, 600)
    };
    text(
        cx,
        s,
        style,
        colour::FONT,
        Some(1),
        swiftly_text::Align::Start,
    )
}

/// "Über Seerr anfragen" with its count and the tiles (`SearchView`): 40 below the library's groups (30 when there are
/// none), the grid 18 under the heading.
fn seerr_block(
    cx: &Cx,
    env: &Env,
    m: &Metrics,
    ctx: &Ctx,
    tiles: &[swiftly_vm::SeerrTile],
    alone: bool,
) -> Node {
    let kit = crate::detail_screen::Kit {
        cx,
        env,
        lk: crate::detail_screen::look(env),
        art: &ctx.seerr_art,
        icons: &ctx.icons,
    };
    let per = browse::grid(m, env.size.w).columns;
    Node::vstack(
        Align::Start,
        Some(0.0),
        vec![
            Node::hstack(
                Align::Center,
                Some(8.0),
                vec![
                    section_title(cx, m, "Über Seerr anfragen", -0.484),
                    Node::spacer(),
                    browse::count_mark(cx, tiles.len() as i64, false),
                ],
            )
            .padding(ins(if alone { 30.0 } else { 40.0 }, m.edge, 0.0, m.edge)),
            crate::pages_screen::seerr_grid(&kit, tiles, per, "seerr")
                .padding(ins(18.0, m.edge, 0.0, m.edge)),
        ],
    )
}

fn recents_block(cx: &Cx, m: &Metrics, ctx: &Ctx, recents: &[String]) -> Node {
    let tv = m.form == Form::Tv;
    let (word_size, icon, row_h) = if tv {
        (30.0, 30.0, 72.0)
    } else {
        (15.0, 20.0, 44.0)
    };
    let mut rows = vec![
        Node::hstack(
            Align::Center,
            Some(8.0),
            vec![
                section_title(cx, m, "Zuletzt gesucht", -0.484),
                Node::spacer(),
                text(
                    cx,
                    if tv { "Verlauf löschen" } else { "Löschen" },
                    st(if tv { 30.0 } else { 13.0 }, 500),
                    colour::FONT_VERY_QUIET,
                    Some(1),
                    swiftly_text::Align::End,
                )
                .frame(None, Some(44.0), Alignment::CENTER)
                .key("recents.clear")
                .on_tap(Action::from("recents.clear")),
            ],
        )
        .padding(ins(18.0, m.edge, 0.0, m.edge)),
    ];
    for (i, word) in recents.iter().enumerate() {
        let row = Node::hstack(
            Align::Center,
            Some(12.0),
            vec![
                ctx.icons
                    .node("clock-counter-clockwise", icon, true, color(colour::FONT))
                    .frame(Some(icon), None, Alignment::CENTER),
                text(
                    cx,
                    word,
                    st(word_size, 600),
                    colour::FONT,
                    Some(1),
                    swiftly_text::Align::Start,
                ),
                Node::spacer(),
            ],
        )
        .padding(EdgeInsets::symmetric(m.edge, 0.0))
        .frame(None, Some(row_h), Alignment::LEADING);
        rows.push(
            fill_frame(row, Alignment::LEADING)
                .key(format!("recent:{i}").as_str())
                .on_tap(Action::from(format!("recent:{i}").as_str())),
        );
        if i + 1 < recents.len() {
            rows.push(
                Node::rect(color(colour::LINE), 0.0)
                    .frame(None, Some(1.0), Alignment::CENTER)
                    .padding(ins(0.0, m.edge + 34.0, 0.0, 0.0)),
            );
        }
    }
    Node::vstack(Align::Start, Some(0.0), rows)
}

/// The Mac's result tiles (`SearchView.SearchPoster`): 120 x 180, 16 between tiles, 20 between rows, name 14/600.
/// Touch and tv keep their own grids.
fn result_metrics(m: Metrics) -> Metrics {
    if m.form != Form::Desktop {
        return m;
    }
    Metrics {
        tile_w: 120.0,
        tile_h: 180.0,
        row_gap: 20.0,
        gap: 16.0,
        title: swiftly_design::TextStyle {
            size: 14.0,
            weight: 600,
            tracking: 0.0,
            uppercase: false,
        },
        ..m
    }
}

/// The adaptive grid of the Mac (`GridItem(.adaptive(minimum: 120), spacing: 16)`): tiles start at the left edge and
/// are never spread apart. Touch and tv use the shared grid.
fn result_grid(m: &Metrics, page_w: f32) -> browse::Grid {
    let mut g = browse::grid(m, page_w);
    if m.form == Form::Desktop {
        g.gap = m.gap;
    }
    g
}

fn group_node(
    cx: &Cx,
    m: &Metrics,
    ctx: &Ctx,
    g: &SearchGroup,
    grid: browse::Grid,
    first_key: usize,
    title_shown: bool,
) -> (Node, usize) {
    let title = if g.kind == SearchKind::Series {
        "Serien"
    } else {
        "Filme"
    };
    let rows: Vec<Node> = g
        .tiles
        .chunks(grid.columns)
        .enumerate()
        .map(|(r, chunk)| {
            let cells = chunk
                .iter()
                .enumerate()
                .map(|(c, t)| {
                    browse::grid_tile(
                        cx,
                        &ctx.icons,
                        m,
                        &ctx.art,
                        t,
                        &grid,
                        &format!("h:{}", first_key + r * grid.columns + c),
                    )
                })
                .collect();
            Node::hstack(Align::Start, Some(grid.gap), cells)
        })
        .collect();
    let node = Node::vstack(
        Align::Start,
        Some(0.0),
        vec![
            // Mac group title: 30 above, 12 below (`SearchView.group`).
            section_title(cx, m, title, -0.2).padding(ins(30.0, m.edge, 12.0, m.edge)),
            Node::vstack(Align::Start, Some(m.row_gap), rows)
                .padding(ins(0.0, m.edge, 10.0, m.edge)),
        ]
        .into_iter()
        .skip(usize::from(!title_shown))
        .collect(),
    );
    (node, g.tiles.len())
}

fn body(cx: &Cx, env: &Env, p: &Parts, ctx: &Ctx) -> Node {
    let m = result_metrics(browse::metrics(env));
    let w = env.size.w;
    if m.form == Form::Tv {
        return tv_body(cx, &m, p, ctx);
    }
    let mut col: Vec<Node> = Vec::new();
    let tv = m.form == Form::Tv;
    if m.form == Form::Desktop {
        col.push(browse::heading(cx, &m, "Suche"));
    }
    let field = if m.form == Form::Desktop {
        browse::search_field_desktop(cx, &ctx.icons, &p.field)
    } else {
        browse::search_field(cx, &ctx.icons, &p.field, tv)
    };
    let field = if m.form == Form::Touch {
        field
    } else {
        field.frame(
            Some(if tv {
                760.0
            } else if m.form == Form::Desktop {
                520.0
            } else {
                700.0
            }),
            None,
            Alignment::LEADING,
        )
    };
    col.push(wide(field, Alignment::LEADING).padding(ins(
        match m.form {
            Form::Touch => 4.0,
            Form::Desktop => 14.0,
            Form::Tv => 0.0,
        },
        m.edge,
        // The Mac field has nothing under it: the blocks below bring their own gap (`SearchView.swift` group 30).
        if m.form == Form::Desktop { 0.0 } else { 16.0 },
        m.edge,
    )));
    let term = p.results.query.clone();
    let typed = p.text.trim();
    let hint = || {
        Node::vstack(
            Align::Center,
            Some(if tv { 20.0 } else { 8.0 }),
            vec![
                ctx.icons.node(
                    "magnifying-glass",
                    if tv { 88.0 } else { 44.0 },
                    true,
                    color(colour::FONT),
                ),
                text(
                    cx,
                    "Filme, Serien und Folgen durchsuchen",
                    st(if tv { 30.0 } else { 15.0 }, 400),
                    colour::FONT_QUIET,
                    Some(1),
                    swiftly_text::Align::Center,
                ),
            ],
        )
        .padding(ins(70.0, 0.0, 0.0, 0.0))
        .frame(None, None, Alignment::TOP)
    };
    let nothing = |recents: &[String]| {
        let mut v = vec![
            empty_state(
                cx,
                &ctx.icons,
                "magnifying-glass",
                &format!(
                    "Nichts gefunden zu \u{201E}{}\u{201C}",
                    if term.is_empty() { typed } else { &term }
                ),
                "Auf deinem Server steht dazu nichts. Manchmal ist es nur ein Buchstabe.",
                "",
            )
            .padding(ins(24.0, 0.0, 0.0, 0.0)),
        ];
        if !recents.is_empty() {
            v.push(recents_block(cx, &m, ctx, recents));
        }
        Node::vstack(Align::Start, Some(0.0), v)
    };
    match p.status.status {
        SearchStatus::Idle | SearchStatus::SignedOut => {
            col.push(if p.recents.is_empty() {
                wide(hint(), Alignment::TOP)
            } else {
                recents_block(cx, &m, ctx, &p.recents)
            });
        }
        SearchStatus::Searching if p.results.groups.is_empty() => {
            let g = result_grid(&m, w);
            col.push(
                browse::grid_placeholder(&m, &g, 2)
                    .padding(ins(12.0, m.edge, 0.0, m.edge))
                    .reveal_as("search.loading"),
            );
        }
        SearchStatus::Offline => col.push(
            empty_state(
                cx,
                &ctx.icons,
                "hard-drive-x",
                "Server ist abgetaucht",
                &format!(
                    "{} antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                    crate::desk::card().server_name()
                ),
                "Erneut versuchen",
            )
            .padding(ins(24.0, 0.0, 0.0, 0.0)),
        ),
        // With Seerr tiles to show the library's empty state stays away (the block below is what the search found).
        SearchStatus::Empty if !p.seerr.is_empty() => {}
        SearchStatus::Empty => col.push(nothing(&p.recents)),
        _ => {
            let mut n = 0;
            for g in &p.results.groups {
                let (node, used) = group_node(cx, &m, ctx, g, result_grid(&m, w), n, true);
                n += used;
                col.push(node);
            }
        }
    }
    if !p.seerr.is_empty() && m.form != Form::Tv {
        col.push(seerr_block(
            cx,
            env,
            &m,
            ctx,
            &p.seerr,
            p.results.groups.is_empty(),
        ));
    }
    let bottom = if m.form == Form::Touch {
        touch::STRIP_HEIGHT + env.safe.bottom + 12.0
    } else {
        24.0
    };
    let top = m.top;
    let column = Node::vstack(Align::Start, Some(0.0), col).padding(ins(top, 0.0, bottom, 0.0));
    fill_frame(
        Node::scroll(Axis::Vertical, None, column).key("search-scroll"),
        Alignment::TOP_LEADING,
    )
}

// ---- tv: the on-screen keyboard card with the results at its right (`TVSearchKeyboard`, `SearchView`) ----

/// Left edge of the right column (`SearchLayout.historyLeft`).
const TV_RIGHT_X: f32 = 620.0;
/// `SearchLayout.keyboardWidth` and `keyboardInset`.
const TV_KEYBOARD: f32 = 460.0;
const TV_INSET: f32 = 16.0;
const TV_KEY: f32 = 64.0;
const TV_KEY_GAP: f32 = 8.0;
const TV_FIELD: f32 = 72.0;
/// `TVSpec.searchColumns`.
const TV_COLUMNS: usize = 5;

/// The letter keys in `SearchKeys` order: A-Z, umlauts, digits, hyphen.
const TV_LETTERS: &str = "ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÜß1234567890-";

/// What typing a letter key adds (`SearchKeys.typed`): a capital at the start of a word, lower case otherwise.
pub fn key_typed(character: &str, term: &str) -> String {
    let starts = term.chars().last().is_none_or(|c| c == ' ' || c == '-');
    let upper = character.to_uppercase();
    let add = if starts && upper.chars().count() == 1 {
        upper
    } else {
        character.to_lowercase()
    };
    format!("{term}{add}")
}

/// A space only after a character that is not a space (`SearchKeys.spaceFits`).
pub fn space_fits(term: &str) -> bool {
    term.chars().last().is_some_and(|c| c != ' ')
}

fn tv_surface(n: Node, radius: f32, key: &str) -> Node {
    n.background(
        Node::rect(Color::new(1.0, 1.0, 1.0, 0.0), radius).paint(Paint::FocusFill {
            color: Color::WHITE,
            radius,
        }),
        Alignment::CENTER,
    )
    .key(key)
    .on_tap(Action::from(key))
    .focusable(
        focus_id(key),
        Some(FocusLook::tile(radius).scaled(tuning::FOCUS_SCALE_SMALL)),
    )
}

fn tv_letter_key(cx: &Cx, ch: &str) -> Node {
    let mut label = text(
        cx,
        ch,
        st(30.0, 600),
        colour::FONT_QUIET,
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
                rest: color(colour::FONT_QUIET),
                focused: color(colour::REASON),
                lines,
                align,
            },
            other => other,
        })
        .collect();
    let n = tv_surface(
        label.frame(Some(TV_KEY), Some(TV_KEY), Alignment::CENTER),
        8.0,
        &format!("key:{ch}"),
    );
    if ch == "A" { n.default_focus() } else { n }
}

/// A key drawn with an icon whose tint follows the focus (quiet at rest, `reason` on the white surface).
#[allow(clippy::too_many_arguments)]
fn tv_icon_key(
    ctx: &Ctx,
    asset: &str,
    pt: f32,
    outlined: bool,
    id: &str,
    w: f32,
    h: f32,
    muted: bool,
) -> Node {
    let rest = if muted {
        colour::FONT_VERY_QUIET
    } else {
        colour::FONT_QUIET
    };
    let mut icon = ctx.icons.node(asset, pt, outlined, color(rest));
    for p in &mut icon.paint {
        if let Paint::Image { image, radius, .. } = *p {
            *p = Paint::FocusImage {
                image,
                rest: color(rest),
                focused: color(colour::REASON),
                radius,
            };
        }
    }
    tv_surface(icon.frame(Some(w), Some(h), Alignment::CENTER), 8.0, id)
}

fn tv_field(cx: &Cx, ctx: &Ctx, term: &str) -> Node {
    let mut row = vec![
        ctx.icons
            .node("magnifying-glass", 28.0, true, color(colour::FONT_QUIET)),
    ];
    let caret = || {
        Node::rect(color(colour::MARK_ACCENT), 0.0).frame(Some(3.0), Some(34.0), Alignment::CENTER)
    };
    if term.is_empty() {
        row.push(Node::hstack(
            Align::Center,
            Some(0.0),
            vec![
                caret(),
                text(
                    cx,
                    "Titel, Serie, Person",
                    st(28.0, 400),
                    colour::FONT_VERY_QUIET,
                    Some(1),
                    swiftly_text::Align::Start,
                )
                .padding(ins(0.0, 4.0, 0.0, 0.0)),
            ],
        ));
    } else {
        // Cut at the front when long so the last letter stays visible.
        let chars: Vec<char> = term.chars().collect();
        let shown: String = if chars.len() > 16 {
            chars[chars.len() - 16..].iter().collect()
        } else {
            term.to_owned()
        };
        row.push(Node::hstack(
            Align::Center,
            Some(0.0),
            vec![
                text(
                    cx,
                    &shown.replace(' ', "\u{00A0}"),
                    st(28.0, 400),
                    colour::FONT,
                    Some(1),
                    swiftly_text::Align::Start,
                ),
                caret(),
            ],
        ));
    }
    row.push(Node::spacer());
    Node::hstack(Align::Center, Some(16.0), row)
        .padding(EdgeInsets::symmetric(16.0, 0.0))
        .frame(
            Some(TV_KEYBOARD - 2.0 * TV_INSET),
            Some(TV_FIELD),
            Alignment::LEADING,
        )
        .background(Node::rect(color(colour::AREA), 8.0), Alignment::CENTER)
}

fn tv_keyboard(cx: &Cx, ctx: &Ctx, term: &str) -> Node {
    let keys_w = TV_KEYBOARD - 2.0 * TV_INSET;
    let letters: Vec<String> = TV_LETTERS.chars().map(String::from).collect();
    let space_muted = !space_fits(term);
    let mut rows: Vec<Node> = Vec::new();
    for r in 0..5 {
        let cells = letters[r * 6..r * 6 + 6]
            .iter()
            .map(|c| tv_letter_key(cx, c))
            .collect();
        rows.push(space_between(cells, keys_w));
    }
    let last_digits = letters[30..36]
        .iter()
        .map(|c| tv_letter_key(cx, c))
        .collect();
    rows.push(space_between(last_digits, keys_w));
    let mut seventh: Vec<Node> = letters[36..41]
        .iter()
        .map(|c| tv_letter_key(cx, c))
        .collect();
    seventh.push(tv_icon_key(
        ctx,
        "space",
        30.0,
        true,
        "key:space",
        TV_KEY,
        TV_KEY,
        space_muted,
    ));
    rows.push(space_between(seventh, keys_w));
    // Delete and microphone: 36 symbols, 72 high, three columns wide each.
    let span3 = 3.0 * TV_KEY + 2.0 * TV_KEY_GAP;
    let bottom = Node::hstack(
        Align::Center,
        Some(keys_w - 2.0 * span3),
        vec![
            tv_icon_key(
                ctx,
                "delete.left",
                36.0,
                true,
                "key:delete",
                span3,
                TV_FIELD,
                false,
            ),
            tv_icon_key(ctx, "mic", 36.0, true, "key:mic", span3, TV_FIELD, false),
        ],
    );
    let keys = Node::vstack(
        Align::Start,
        Some(TV_KEY_GAP),
        vec![Node::vstack(Align::Start, Some(TV_KEY_GAP), rows), bottom],
    );
    Node::vstack(
        Align::Start,
        Some(16.0),
        vec![tv_field(cx, ctx, term), keys],
    )
    .padding(EdgeInsets::all(TV_INSET))
    .frame(Some(TV_KEYBOARD), None, Alignment::TOP_LEADING)
    .background(
        Node::rect(color(colour::GROUPS_AREA), 16.0),
        Alignment::CENTER,
    )
}

/// Keys "space-between" in `w`: the first and last touch the edges.
fn space_between(cells: Vec<Node>, w: f32) -> Node {
    let n = cells.len();
    let gap = if n > 1 {
        (w - n as f32 * TV_KEY) / (n - 1) as f32
    } else {
        0.0
    };
    Node::hstack(Align::Center, Some(gap), cells).frame(Some(w), Some(TV_KEY), Alignment::LEADING)
}

fn tv_note(cx: &Cx, ctx: &Ctx, w: f32, asset: &str, sentence: &str) -> Node {
    Node::vstack(
        Align::Center,
        Some(20.0),
        vec![
            ctx.icons
                .node(asset, 88.0, true, color(colour::FONT_VERY_QUIET)),
            text(
                cx,
                sentence,
                st(30.0, 400),
                colour::FONT_VERY_QUIET,
                None,
                swiftly_text::Align::Center,
            ),
        ],
    )
    .frame(Some(w), None, Alignment::TOP)
}

/// `EmptyState` on tv: symbol 88 very quiet, title `Theme.rail` 44 bold, hint 30 quiet, 20 apart, centred in the column.
fn tv_empty(
    cx: &Cx,
    ctx: &Ctx,
    w: f32,
    asset: &str,
    title: &str,
    hint: &str,
    button: Option<&str>,
) -> Node {
    let mut v = vec![
        ctx.icons
            .node(asset, 88.0, true, color(colour::FONT_VERY_QUIET)),
        text(
            cx,
            title,
            st(44.0, 700),
            colour::FONT,
            Some(2),
            swiftly_text::Align::Center,
        ),
        text(
            cx,
            hint,
            st(30.0, 400),
            colour::FONT_QUIET,
            None,
            swiftly_text::Align::Center,
        ),
    ];
    if let Some(b) = button {
        v.push(
            text(
                cx,
                b,
                tv::text::BUTTON,
                colour::FONT_QUIET,
                Some(1),
                swiftly_text::Align::Center,
            )
            .padding(EdgeInsets::symmetric(tv::TAB_PADDING, 0.0))
            .frame(None, Some(tv::TAB_HEIGHT), Alignment::CENTER)
            .background(
                Node::rect(color(colour::SURFACE_TRANSLUCENT), 999.0),
                Alignment::CENTER,
            )
            .key("retry")
            .on_tap(Action::from("retry"))
            .focusable(focus_id("retry"), Some(FocusLook::tile(999.0))),
        );
    }
    Node::vstack(Align::Center, Some(20.0), v)
        .frame(Some(w), None, Alignment::TOP)
        .padding(ins(70.0, 0.0, 0.0, 0.0))
}

/// Long words in the middle (`shortened`).
fn shortened(word: &str) -> String {
    let clean = word.trim();
    let c: Vec<char> = clean.chars().collect();
    if c.len() > 32 {
        format!(
            "{}\u{2026}{}",
            c[..14].iter().collect::<String>(),
            c[c.len() - 14..].iter().collect::<String>()
        )
    } else {
        clean.to_owned()
    }
}

fn tv_body(cx: &Cx, m: &Metrics, p: &Parts, ctx: &Ctx) -> Node {
    let w = TV_COLUMNS as f32 * tv::POSTER_WIDTH + (TV_COLUMNS - 1) as f32 * tv::TILE_SPACING;
    let grid = browse::Grid {
        columns: TV_COLUMNS,
        w: tv::POSTER_WIDTH,
        h: tv::POSTER_HEIGHT,
        gap: tv::TILE_SPACING,
    };
    let flat = Metrics { edge: 0.0, ..*m };
    let term = p.results.query.clone();
    let typed = p.text.trim();
    let mut col: Vec<Node> = Vec::new();
    match p.status.status {
        SearchStatus::Idle | SearchStatus::SignedOut => {
            if p.recents.is_empty() {
                col.push(
                    tv_note(
                        cx,
                        ctx,
                        w,
                        "magnifying-glass",
                        "Titel, Serie oder Name. Ab zwei Zeichen wird gesucht.",
                    )
                    .padding(ins(240.0, 0.0, 0.0, 0.0)),
                );
            } else {
                col.push(recents_block(cx, &flat, ctx, &p.recents));
            }
        }
        SearchStatus::Searching if p.results.groups.is_empty() => {
            col.push(browse::grid_placeholder(&flat, &grid, 1))
        }
        SearchStatus::Offline => col.push(tv_empty(
            cx,
            ctx,
            w,
            "hard-drive-x",
            "Server ist abgetaucht",
            &format!(
                "{} antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                crate::desk::card().server_name()
            ),
            Some("Erneut versuchen"),
        )),
        SearchStatus::Empty => {
            col.push(tv_empty(
                cx,
                ctx,
                w,
                "magnifying-glass",
                &format!(
                    "Nichts gefunden zu \u{201E}{}\u{201C}",
                    shortened(if term.is_empty() { typed } else { &term })
                ),
                "Auf deinem Server steht dazu nichts. Manchmal ist es nur ein Buchstabe.",
                None,
            ));
            if !p.recents.is_empty() {
                col.push(
                    recents_block(cx, &flat, ctx, &p.recents).padding(ins(64.0, 0.0, 0.0, 0.0)),
                );
            }
        }
        _ => {
            // Block titles only when more than one block stands there (`SearchGroups.showsTitles`).
            let titles = p
                .results
                .groups
                .iter()
                .filter(|g| !g.tiles.is_empty())
                .count()
                > 1;
            let mut n = 0;
            let mut blocks = Vec::new();
            for g in &p.results.groups {
                let (node, used) = group_node(cx, &flat, ctx, g, grid, n, titles);
                n += used;
                blocks.push(node);
            }
            col.push(Node::vstack(Align::Start, Some(m.row_gap), blocks));
        }
    }
    let right = Node::scroll(
        Axis::Vertical,
        None,
        Node::vstack(Align::Start, Some(0.0), col).padding(ins(0.0, 0.0, 60.0, 0.0)),
    )
    .key("search-scroll")
    .frame(Some(w), None, Alignment::TOP_LEADING);
    let keyboard = tv_keyboard(cx, ctx, &p.text);
    let gap = TV_RIGHT_X - m.edge - TV_KEYBOARD;
    let row = Node::hstack(
        Align::Start,
        Some(gap),
        vec![keyboard, right.frame(Some(w), None, Alignment::TOP_LEADING)],
    );
    fill_frame(
        row.padding(ins(tv::CONTENT_TOP - 60.0 + 60.0, m.edge, 0.0, 0.0)),
        Alignment::TOP_LEADING,
    )
}

fn view(p: &Parts, env: &Env, cx: &Cx, ctx: &Ctx) -> Node {
    ctx.art.hub.begin_build();
    let page = browse::page(
        cx,
        env,
        &ctx.icons,
        &ctx.art.hub,
        p.bar.clone(),
        "Suche",
        body(cx, env, p, ctx),
        None,
    );
    match p.menu.overlay(cx, env) {
        Some(o) => page.overlay(o, Alignment::TOP_LEADING),
        None => page,
    }
}

/// The Search screen: a UI over a `SearchVm`.
pub struct SearchScreen {
    ui: Ui<Parts>,
    hub: crate::hub::HubSlot,
    vm: SearchVm<AppTransport>,
    field: FieldState,
    clip: Box<dyn Clipboard>,
    cx: Cx,
    /// The mouse button is down in the field: moving selects.
    dragging: bool,
    now: f64,
    opened: Vec<String>,
    tab: usize,
    scenario: Scenario,
    menu: crate::desk::TileMenu,
    /// "Abspielen auf \u{2026}" and "Gemeinsam schauen" of the tile menu, for the host.
    requests: Vec<swiftly_vm::TileRequest>,
    /// Where the last right click was (the device list opens there).
    menu_at: swiftly_layout::Point,
    /// The Seerr flow behind the block "Über Seerr anfragen"; none without a Seerr session.
    flow: Option<crate::seerr_flow::Flow>,
    /// The term the flow was last given.
    flow_term: String,
    /// The Seerr tile that was tapped, once.
    seerr_tapped: Option<swiftly_seerr::models::SeerrHit>,
}

impl SearchScreen {
    /// What a screen reader gets for this screen: the nodes of the current picture.
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.ui.a11y_nodes()
    }

    /// A search page for `env` over a scripted server in `scenario` (what the server answers, whatever the term is).
    /// `recents` fills the history.
    ///
    /// # Panics
    /// If the view model cannot be built.
    pub fn new(env: Env, cx: Cx, scenario: Scenario, recents: &[&str]) -> SearchScreen {
        let history = Arc::new(MemoryKeyValue::new());
        let vm = match crate::live::current() {
            Some(w) => SearchVm::new(
                Arc::clone(&w.core.net),
                w.core.host(),
                w.core.sleeper(),
                Arc::clone(&w.core.kv),
                Some(w.account.clone()),
            ),
            None => SearchVm::new(
                Arc::new(AppTransport::Mock(browse::transport(scenario, 9, false))),
                browse::host(),
                Arc::new(browse::ThreadSleeper),
                history,
                Some(browse::account()),
            ),
        }
        .unwrap_or_else(|e| panic!("search vm: {e:?}"));
        for r in recents.iter().rev() {
            vm.send(SearchIntent::Pick {
                term: (*r).to_owned(),
            });
            vm.send(SearchIntent::Remember);
        }
        if !recents.is_empty() {
            Self::settle(&vm);
            vm.send(SearchIntent::Query {
                text: String::new(),
            });
        }
        let touch_idiom = Form::of(env.idiom) == Form::Touch;
        let cx_text = cx.clone();
        let art = Art::new(&cx);
        let mut seerr_art = crate::detail_screen::Art::new(&cx);
        seerr_art.hub = Rc::clone(&art.hub);
        let ctx = Rc::new(Ctx {
            art,
            icons: Icons::new(&cx, env.scale),
            seerr_art,
        });
        let parts = Parts {
            status: vm.status(),
            results: vm.results(),
            recents: vm.recents(),
            text: String::new(),
            field: FieldState::new(TextEditor::single_line()).view(PLACEHOLDER, touch_idiom, 0.0),
            bar: Bar {
                tab: 3,
                header: 0,
                downloads: false,
                settings: false,
                card: crate::desk::Card::Demo,
                offer: None,
                mine: (true, true),
                glow: (crate::look_glow::Glow::default(), 0),
            },
            pictures: 0,
            menu: crate::desk::TileMenu::default(),
            seerr: Vec::new(),
        };
        let hub = Rc::clone(&ctx.art.hub);
        let ui = Ui::new(
            move |p: &Parts, env: &Env, cx: &Cx| view(p, env, cx, &ctx),
            parts,
            env,
            cx,
        );
        let mut s = SearchScreen {
            ui,
            hub,
            vm,
            field: FieldState::new(TextEditor::single_line()),
            clip: Box::new(crate::field_book::SystemClipboard),
            cx: cx_text,
            dragging: false,
            now: 0.0,
            opened: Vec::new(),
            tab: 3,
            scenario,
            menu: crate::desk::TileMenu::default(),
            requests: Vec::new(),
            menu_at: swiftly_layout::Point::new(0.0, 0.0),
            flow: None,
            flow_term: String::new(),
            seerr_tapped: None,
        };
        s.sync();
        s
    }

    /// Polls until the view model is no longer searching.
    ///
    /// # Panics
    /// If it does not settle within ten seconds.
    pub fn settle(vm: &SearchVm<AppTransport>) {
        let started = std::time::Instant::now();
        loop {
            if !matches!(vm.status().status, SearchStatus::Searching) {
                return;
            }
            assert!(started.elapsed().as_secs() < 10, "search vm did not settle");
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
    }

    /// The view model.
    pub fn vm(&self) -> &SearchVm<AppTransport> {
        &self.vm
    }
    /// The text in the field.
    pub fn text(&self) -> &str {
        self.field.editor.text()
    }
    /// The text field state (tests, accessibility).
    pub fn field(&self) -> &FieldState {
        &self.field
    }
    /// The accessibility node of the field.
    pub fn a11y(&self) -> A11yNode {
        self.field.a11y("field", "Suche", PLACEHOLDER)
    }
    /// The system clipboard the shell provides (default: in memory).
    pub fn set_clipboard(&mut self, clip: Box<dyn Clipboard>) {
        self.clip = clip;
    }
    /// One input event for the field (the shell maps winit to it); a changed text starts a new search.
    pub fn text_event(&mut self, ev: &TextInputEvent) -> swiftly_text::Outcome {
        self.field.set_focused(true, self.now);
        let out = self.field.apply(ev, self.clip.as_mut(), self.now);
        if out.text_changed {
            self.query();
        }
        if out.submitted {
            self.submit();
        }
        out
    }
    /// Titles opened so far.
    pub fn opened(&self) -> &[String] {
        &self.opened
    }
    /// The scenario of the scripted server.
    pub fn scenario(&self) -> Scenario {
        self.scenario
    }

    fn query(&mut self) {
        self.vm.send(SearchIntent::Query {
            text: self.field.editor.text().to_owned(),
        });
    }
    /// The tab the bar shows (changes when a bar entry is tapped).
    pub fn tab(&self) -> usize {
        self.tab
    }
    /// Puts the bar back on a tab.
    pub fn set_tab(&mut self, tab: usize) {
        self.tab = tab;
    }
    /// Whether the field has the keyboard (typed text goes into it).
    pub fn wants_text(&self) -> bool {
        self.field.focused
    }
    /// What the input method needs: open while the field has the keyboard, and its candidate window at the caret (or
    /// the composition) in window points.
    pub fn ime_state(&self) -> crate::ime::ImeState {
        let tv = Form::of(self.ui.env().idiom) == Form::Tv;
        let area = self
            .ui
            .frame_of(swiftly_ui::field::CONTENT_KEY)
            .filter(|_| self.field.focused)
            .map(|origin| {
                let view = self.field.view(PLACEHOLDER, false, self.now);
                crate::ime::anchor(
                    origin,
                    swiftly_ui::field::candidate_rect(
                        self.ui.cx(),
                        &view,
                        &browse::search_look(tv),
                    ),
                )
            });
        crate::ime::ImeState {
            allowed: self.field.focused,
            password: self.field.editor.is_password(),
            area,
        }
    }
    /// Gives the keyboard to the field (`SearchView`: `onAppear { inField = true }` and Cmd+F).
    pub fn focus(&mut self) {
        self.field.set_focused(true, self.now);
    }
    /// Takes the keyboard from the field.
    pub fn unfocus(&mut self) {
        self.field.set_focused(false, self.now);
        let _ = self.field.apply(
            &TextInputEvent::CancelComposition,
            self.clip.as_mut(),
            self.now,
        );
    }
    /// Typed characters (the platform's text input calls this).
    pub fn type_text(&mut self, s: &str) {
        let _ = self.text_event(&TextInputEvent::Text(s.to_owned()));
    }
    /// Paste hook: the platform hands over the clipboard text; the editor turns line breaks into spaces.
    pub fn paste(&mut self, s: &str) {
        // The text comes from the caller, so it never touches (or depends on) the system clipboard.
        let system = std::mem::replace(
            &mut self.clip,
            Box::new(swiftly_text::MemoryClipboard::default()),
        );
        self.clip.set_text(s);
        let _ = self.text_event(&TextInputEvent::Paste);
        self.clip = system;
    }
    /// Backspace.
    pub fn backspace(&mut self) {
        let _ = self.text_event(&TextInputEvent::Key(
            swiftly_text::EditKey::Backspace,
            swiftly_text::Mods::NONE,
        ));
    }
    /// Empties the field (the clear button).
    pub fn clear_text(&mut self) {
        let _ = self.text_event(&TextInputEvent::Clear);
    }
    /// Return in the field: remembers the term.
    pub fn submit(&mut self) {
        self.vm.send(SearchIntent::Remember);
    }

    /// Connects the block "Über Seerr anfragen" (the Mac's `model.seerr.searching`): what is typed in the field is
    /// asked of Seerr as well, after its own 300 ms.
    pub fn set_seerr(&mut self, flow: crate::seerr_flow::Flow) {
        self.flow = Some(flow);
    }

    /// Whether the block is connected.
    pub fn has_seerr(&self) -> bool {
        self.flow.is_some()
    }

    /// The Seerr title that was tapped, once (the shell opens its page).
    pub fn take_seerr(&mut self) -> Option<swiftly_seerr::models::SeerrHit> {
        self.seerr_tapped.take()
    }

    /// Hands the typed term to Seerr and takes its answers.
    fn sync_seerr(&mut self) {
        let Some(f) = self.flow.as_mut() else { return };
        let typed = self.field.editor.text().trim().to_owned();
        if typed != self.flow_term {
            self.flow_term = typed.clone();
            f.search(&typed, std::time::Instant::now());
        }
        f.poll(std::time::Instant::now());
    }

    fn sync(&mut self) {
        self.sync_seerr();
        let header = if self.ui.env().idiom == swiftly_ui::Idiom::Desktop {
            crate::home::bar_strength(
                self.ui.scroll_offsets().first().copied().unwrap_or(0.0) as f32,
                crate::home::BAR_SINCE,
                26.0,
            )
        } else {
            ((self.ui.scroll_offsets().first().copied().unwrap_or(0.0) as f32 / 30.0)
                .clamp(0.0, 1.0)
                * 8.0)
                .round() as u8
        };
        self.ui.set_parts(Parts {
            status: self.vm.status(),
            results: self.vm.results(),
            recents: self.vm.recents(),
            text: self.field.editor.text().to_owned(),
            field: self.field.view(
                PLACEHOLDER,
                Form::of(self.ui.env().idiom) == Form::Touch,
                self.now,
            ),
            bar: Bar {
                tab: 3,
                header,
                downloads: crate::desk::downloads_front(),
                settings: crate::desk::settings_front(),
                card: crate::desk::card(),
                offer: crate::desk::offer(),
                mine: crate::desk::mine(),
                glow: crate::look_glow::bar_state(
                    self.ui.scroll_offsets().first().copied().unwrap_or(0.0),
                ),
            },
            pictures: self.hub.stamp(),
            menu: self.menu.clone(),
            seerr: self
                .flow
                .as_ref()
                .map(|f| f.vm().discover().tiles.clone())
                .unwrap_or_default(),
        });
    }

    fn drain(&mut self) {
        for ev in self.ui.take_events() {
            if let UiEvent::Secondary { action, x, y } = &ev {
                let tile = self
                    .vm
                    .results()
                    .groups
                    .iter()
                    .flat_map(|g| g.tiles.iter())
                    .find(|t| *action == Action::from(format!("menu:{}", t.id).as_str()))
                    .cloned();
                if let Some(t) = tile {
                    self.menu_at = swiftly_layout::Point::new(*x, *y);
                    self.menu.open(
                        &t,
                        &crate::tile_menu::context_for(Some(&t)),
                        self.menu_at,
                        false,
                    );
                }
                continue;
            }
            if let UiEvent::Tap(a) = &ev
                && self.menu.is_open()
            {
                match self.menu.tap(a) {
                    Some(crate::desk::Pick::Row(id, i)) => self.picked(&id, i),
                    Some(crate::desk::Pick::Device(id, device)) => {
                        self.requests
                            .push(swiftly_vm::TileRequest::PlayOn { id, device });
                    }
                    _ => {}
                }
                continue;
            }
            if let UiEvent::Tap(a) = ev {
                crate::forms::note_tap(&a);
                let is = |s: &str| a == Action::from(s);
                for i in 0..crate::home::TABS.len() {
                    if is(&format!("tab:{i}")) {
                        self.tab = i;
                    }
                }
                for ch in TV_LETTERS.chars() {
                    if is(&format!("key:{ch}")) {
                        let typed = key_typed(&ch.to_string(), self.field.editor.text());
                        self.field.editor.set_text(&typed);
                        self.query();
                    }
                }
                if is("key:space") && space_fits(self.field.editor.text()) {
                    let _ = self.text_event(&TextInputEvent::Text(" ".into()));
                } else if is("key:delete") {
                    self.backspace();
                }
                if is("field.focus") {
                    self.field.set_focused(true, self.now);
                } else if is("field.clear") {
                    self.clear_text();
                } else if is("recents.clear") {
                    self.vm.send(SearchIntent::ClearRecents);
                } else if is("retry") {
                    self.query();
                }
                for (i, w) in self.vm.recents().iter().enumerate() {
                    if is(&format!("recent:{i}")) {
                        self.field.editor.set_text(w);
                        self.field.set_focused(false, self.now);
                        self.vm.send(SearchIntent::Pick { term: w.clone() });
                    }
                }
                if let Some(f) = &self.flow {
                    for (i, t) in f.vm().discover().tiles.iter().enumerate() {
                        if is(&format!("seerr:{i}")) {
                            self.seerr_tapped = Some(t.hit.clone());
                        }
                    }
                }
                for g in &self.vm.results().groups {
                    for t in &g.tiles {
                        if is(&format!("tile:{}", t.id)) {
                            self.opened.push(t.id.clone());
                            self.vm.send(SearchIntent::Remember);
                        }
                    }
                }
            }
        }
    }

    /// A row of the right-click menu was chosen: the entries that open a title open its page.
    fn picked(&mut self, id: &str, row: usize) {
        use crate::tile_menu::Entry;
        let tile = self
            .vm
            .results()
            .groups
            .iter()
            .flat_map(|g| g.tiles.iter())
            .find(|t| t.id == id)
            .cloned();
        let cx = crate::tile_menu::context_for(tile.as_ref());
        let entries = crate::tile_menu::entries(crate::home::Form::Desktop, &cx, tile.as_ref());
        match entries.get(row) {
            Some(
                Entry::Play | Entry::FromStart | Entry::Info | Entry::Overview | Entry::ToSeries,
            ) => {
                self.opened.push(id.to_owned());
                self.vm.send(SearchIntent::Remember);
            }
            Some(Entry::Together) => self
                .requests
                .push(swiftly_vm::TileRequest::Together { id: id.to_owned() }),
            Some(Entry::PlayOn) => {
                self.menu
                    .open_devices(id, &cx.host.play_on, self.menu_at, false)
            }
            _ => {}
        }
    }

    /// The frame `[x, y, w, h]` of a keyed node (tests).
    pub fn frame_of(&self, key: &str) -> Option<[f32; 4]> {
        self.ui.frame_of(key)
    }

    /// The requests of the tile menu for the host since the last call.
    pub fn take_requests(&mut self) -> Vec<swiftly_vm::TileRequest> {
        std::mem::take(&mut self.requests)
    }

    /// Whether the right-click menu is open.
    pub fn menu_open(&self) -> bool {
        self.menu.is_open()
    }

    /// A right click on a result tile.
    pub fn secondary_click(&mut self, x: f32, y: f32, now: f64) -> bool {
        self.menu.close();
        let hit = self.ui.secondary_click(x, y, now);
        self.drain();
        hit
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

    /// Arrow, Tab, Enter or Esc.
    pub fn nav_key(
        &mut self,
        key: swiftly_ui::NavKey,
        down: bool,
        now: f64,
    ) -> swiftly_ui::Outcome {
        if self.menu.is_open() {
            use swiftly_ui::popover::MenuKey as K;
            let k = match key {
                swiftly_ui::NavKey::Arrow(swiftly_ui::Dir::Up) => Some(K::Up),
                swiftly_ui::NavKey::Arrow(swiftly_ui::Dir::Down) => Some(K::Down),
                swiftly_ui::NavKey::Enter => Some(K::Enter),
                swiftly_ui::NavKey::Escape => Some(K::Escape),
                _ => None,
            };
            if let (Some(k), true) = (k, down) {
                match self.menu.key(k, now) {
                    Some(crate::desk::Pick::Row(id, i)) => self.picked(&id, i),
                    Some(crate::desk::Pick::Device(id, device)) => {
                        self.requests
                            .push(swiftly_vm::TileRequest::PlayOn { id, device });
                    }
                    _ => {}
                }
            }
            return swiftly_ui::Outcome::None;
        }
        let out = self.ui.nav_key(key, down, now);
        self.drain();
        out
    }
    /// Desktop field: a press inside the field puts the caret at the pointer, a drag extends the selection. Returns whether
    /// the press was in the field (the clear button is not).
    fn place_caret(&mut self, x: f32, y: f32, extend: bool) -> bool {
        if Form::of(self.ui.env().idiom) != Form::Desktop {
            return false;
        }
        let Some([fx, fy, fw, fh]) = self.ui.frame_of("field") else {
            return false;
        };
        let Some([tx, ..]) = self.ui.frame_of("field.text") else {
            return false;
        };
        let on_clear = self
            .ui
            .frame_of("field.clear")
            .is_some_and(|[cx, cy, cw, ch]| x >= cx && x <= cx + cw && y >= cy && y <= cy + ch);
        if on_clear || (!extend && (x < fx || x > fx + fw || y < fy || y > fy + fh)) {
            return false;
        }
        let d = self.field.editor.display();
        let style = browse::search_look(false).style;
        let layout = self.cx.text.borrow_mut().layout(
            &d.text,
            &style,
            None,
            None,
            swiftly_text::Align::Start,
        );
        let index = layout
            .hit_test(x - tx, 0.0)
            .min(self.field.editor.text().len());
        self.field.set_focused(true, self.now);
        let _ = self.field.apply(
            &TextInputEvent::SetCaret { index, extend },
            self.clip.as_mut(),
            self.now,
        );
        true
    }
    /// A finger goes down.
    pub fn touch_down(&mut self, x: f32, y: f32, now: f64) {
        self.dragging = self.place_caret(x, y, false);
        self.ui.touch_down(x, y, now);
        self.drain();
    }
    /// The finger moves.
    pub fn touch_move(&mut self, x: f32, y: f32, now: f64) {
        if self.dragging {
            self.place_caret(x, y, true);
        }
        self.ui.touch_move(x, y, now);
        self.drain();
    }
    /// The finger lifts.
    pub fn touch_up(&mut self, x: f32, y: f32, now: f64) {
        self.dragging = false;
        self.ui.touch_up(x, y, now);
        self.drain();
    }
    /// The touch is cancelled.
    pub fn touch_cancel(&mut self, now: f64) {
        self.ui.touch_cancel(now);
        self.drain();
    }
    /// One frame at `now` ms.
    pub fn frame(&mut self, now: f64) -> (DrawList, bool) {
        self.now = now;
        self.hub.frame(now);
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

    /// Another frame is wanted (an animation, or the search is still running).
    pub fn wants_frame(&self) -> bool {
        self.hub.busy()
            || self.ui.needs_frame()
            || self.field.focused
            || self
                .flow
                .as_ref()
                .is_some_and(crate::seerr_flow::Flow::busy)
            || matches!(self.vm.status().status, SearchStatus::Searching)
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
}
