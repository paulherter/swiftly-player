//! The Series screen of the shared Rust UI: head like the Detail screen, then the page tabs (the first one is the season
//! picker), the episode list with progress and watched state, cast, similar and extras. Drawn from `SeriesVm` parts
//! for `touch`, `desktop` and `tv`. Differences from the Swift `SeriesView` are noted in the code.

use crate::detail_screen::{
    Art, HERO_DESKTOP, Head, Kit, Pushed, UiState, body_touch, cast_rail, fill_frame, ground, hero,
    hero_buttons, ins, look, menu_key, mood_strips, poster_tile, resume_info, rgba, sheet,
    status_card, tile_rail, top_bar, txt, txt_center, version_sheet, weight, wide,
};
use crate::home::Form;
use crate::home_data::Scenario;
use crate::net::AppTransport;
use crate::title_data;
use std::rc::Rc;
use std::sync::Arc;
use swiftly_design::tokens::{colour, touch, tv};
use swiftly_layout::{Align, Alignment, Axis};
use swiftly_render::{Color, DrawList, RgbaImage};
use swiftly_ui::components::{color, focus_id};
use swiftly_ui::icons::Icons;
use swiftly_ui::popover::{self, Anchor, MenuItem};
use swiftly_ui::{Action, Cx, Env, FocusLook, Node, Paint};
use swiftly_vm::{
    DetailVm, EpisodeRow, EpisodesPart, EpisodesStatus, MorePart, PlayAction, SeasonsPart,
    SeriesButtonPart, SeriesIntent, SeriesVm,
};

#[derive(Clone, PartialEq)]
struct Data {
    head: Head,
    seasons: Arc<SeasonsPart>,
    episodes: Arc<EpisodesPart>,
    more: Arc<MorePart>,
    /// The texts of the More menu (the core's `more_menu`; the sheet of touch lists them).
    menu: Vec<String>,
    /// The version rows (`MediaSource.versionLabel`) and the heading of the choice.
    versions: Vec<String>,
    /// Whether the hero picture's hues are known: the mood backdrop is built from them, and the page must be rebuilt when
    /// they arrive after the page (the view alone never learns about them).
    tones: bool,
}

/// The heading of the version choice on the series page (the Mac's literal "Fassung wählen").
const VERSION_TITLE: &str = "Fassung wählen";

/// A tile for an episode row, so the tile menu knows what it is (the Mac builds the menu from the episode's `Item`).
fn episode_tile(e: &EpisodeRow, series: &str) -> swiftly_vm::Tile {
    swiftly_vm::Tile {
        id: e.id.clone(),
        title: e.title.clone(),
        subtitle: None,
        progress: e.progress,
        image: e.image.clone(),
        badges: if e.watched {
            vec![swiftly_vm::Badge::Watched]
        } else {
            Vec::new()
        },
        remaining: e.remaining.clone(),
        facts: swiftly_vm::TileFacts {
            kind: Some("Episode".into()),
            name: e.title.clone(),
            series_id: Some(series.to_owned()).filter(|s| !s.is_empty()),
            episode_number: e.number.and_then(|n| i32::try_from(n).ok()),
            ..swiftly_vm::TileFacts::default()
        },
    }
}

fn head_of(b: &SeriesButtonPart, directors: Vec<String>) -> Head {
    Head {
        id: b.id.clone(),
        image: b.image.clone(),
        title: b.title.clone(),
        secondary: b.secondary_line.clone(),
        overview: b.overview.clone(),
        directors,
        label: b.label.clone(),
        enabled: b.enabled,
        remaining: b.remaining.clone(),
        progress: b.progress,
        watched: b.watched,
        favorite: b.favorite,
        fav_caption: b.favorite_caption.clone(),
        download: None,
        // The line under the title: Direct Play, rating, age (`DetailView.swift:578`).
        proof: b.proof.visible.then(|| {
            (
                b.proof.direct_play,
                b.proof.hint.clone(),
                b.proof.rating.clone(),
                b.proof.age_rating.clone(),
            )
        }),
        message: b.message.clone(),
        trailer: false,
    }
}

fn episode_size(form: Form) -> (f32, f32) {
    match form {
        Form::Touch => (touch::EPISODE_WIDTH, touch::EPISODE_HEIGHT),
        Form::Desktop => (160.0, 90.0),
        Form::Tv => (320.0, 180.0),
    }
}

/// One episode: still with progress bar or watched check, "N. Name" and the quiet line (`EpisodeRow` of the Swift list).
fn episode_node(k: &Kit, e: &EpisodeRow, key: &str) -> Node {
    let lk = &k.lk;
    let (w, h) = episode_size(lk.form);
    let mut img = k
        .art
        .node_for(e.image.as_ref(), true, &e.id, w, h, lk.corner)
        .paint(Paint::Stroke {
            color: color(colour::TILE_BORDER),
            width: 1.0,
            radius: lk.corner,
        });
    if let Some(p) = e.progress.filter(|p| *p > 0.0 && !e.watched) {
        let bar = Node::zstack(
            Alignment::BOTTOM_LEADING,
            vec![
                Node::rect(Color::new(1.0, 1.0, 1.0, 0.30), 0.0).frame(
                    Some(w),
                    Some(4.0),
                    Alignment::CENTER,
                ),
                Node::rect(color(colour::MARK_ACCENT), 0.0).frame(
                    Some(w * p.clamp(0.0, 1.0)),
                    Some(4.0),
                    Alignment::CENTER,
                ),
            ],
        );
        img = img.overlay(bar, Alignment::BOTTOM_LEADING);
    }
    if e.watched {
        let check = k
            .icons
            .node("check", 12.0, true, color(colour::FONT))
            .frame(Some(22.0), Some(22.0), Alignment::CENTER)
            .background(
                Node::rect(color(colour::SCRIM_BUTTON), 11.0),
                Alignment::CENTER,
            )
            .padding(ins(0.0, 0.0, 6.0, 6.0));
        img = img.overlay(check, Alignment::BOTTOM_TRAILING);
    }
    let name = match e.number {
        Some(n) => format!("{n}. {}", e.title),
        None => e.title.clone(),
    };
    let tcolor = if e.watched {
        colour::FONT_QUIET
    } else {
        colour::FONT
    };
    let second = e
        .remaining
        .clone()
        .or_else(|| e.runtime.clone())
        .unwrap_or_default();
    let text_w = (k.env.size.w - 2.0 * lk.edge - w - 14.0).max(120.0);
    if lk.form == Form::Tv {
        let mut n = Node::vstack(
            Align::Start,
            Some(10.0),
            vec![
                img,
                txt(k.cx, &name, lk.tile, tcolor, Some(1)).frame(Some(w), None, Alignment::LEADING),
                txt(k.cx, &second, lk.small, colour::FONT_VERY_QUIET, Some(1)).frame(
                    Some(w),
                    None,
                    Alignment::LEADING,
                ),
            ],
        )
        .key(key)
        .on_tap(Action::from(format!("episode:{}", e.id).as_str()));
        n = n.focusable(focus_id(key), Some(FocusLook::tile(lk.corner)));
        return n;
    }
    if lk.form == Form::Desktop {
        // Mac `EpisodeRow`: 160 x 90 still, 16 apart, 10 around (the row is 110 high, 820 wide, radius 12); the title 15
        // semibold with the runtime (12 very quiet) and, when watched, `checkmark.circle.fill` 14; the overview 13 quiet,
        // three lines, 5 below. Hover fills the whole row with `groupsArea` (`timeFloat`); a right click opens the menu.
        let mut head = vec![txt(
            k.cx,
            &name,
            weight(lk.body, 15.0, 600),
            colour::FONT,
            Some(2),
        )];
        if !second.is_empty() {
            head.push(txt(
                k.cx,
                &second,
                weight(lk.small, 12.0, 400),
                colour::FONT_VERY_QUIET,
                Some(1),
            ));
        }
        if e.watched {
            head.push(k.icons.node(
                "check-circle.fill",
                14.0,
                false,
                color(colour::FONT_VERY_QUIET),
            ));
        }
        let mut lines = vec![Node::hstack(Align::Center, Some(8.0), head)];
        if let Some(o) = e.overview.as_ref().filter(|o| !o.is_empty()) {
            lines.push(txt(
                k.cx,
                o,
                weight(lk.small, 13.0, 400),
                colour::FONT_QUIET,
                Some(3),
            ));
        }
        // Download and More appear under the pointer (`SeriesView.swift:817`: "a pointer cannot swipe"). They are
        // always in the layout and only faded, so the text does not reflow on hover: 18 wide, 14 apart, 12 from the
        // text, 2 down.
        let quiet = color(colour::FONT_QUIET);
        let hidden = Color::new(quiet.r, quiet.g, quiet.b, 0.0);
        let mut icons = Vec::new();
        if crate::live::current().is_none_or(|w| w.download_button()) {
            icons.push(
                crate::detail_screen::focus_tint(
                    k.icons.node("arrow-circle-down", 18.0, true, quiet),
                    hidden,
                    quiet,
                )
                .key(format!("epload:{}", e.id).as_str())
                .on_tap(Action::from("download"))
                .tooltip("Laden"),
            );
        }
        icons.push(
            crate::detail_screen::focus_tint(
                k.icons.node("dots-three", 18.0, true, quiet),
                hidden,
                quiet,
            )
            .key(format!("epmore:{}", e.id).as_str())
            .on_tap(Action::from(format!("epmenu:{}", e.id).as_str()))
            .tooltip("Mehr"),
        );
        let icon_w = 18.0 * icons.len() as f32 + 14.0 * (icons.len() as f32 - 1.0) + 12.0;
        let icons = Node::hstack(Align::Start, Some(14.0), icons).padding(ins(2.0, 12.0, 0.0, 0.0));
        let text = Node::vstack(Align::Start, Some(5.0), lines).frame(
            Some(820.0 - 20.0 - w - 16.0 - icon_w),
            None,
            Alignment::TOP_LEADING,
        );
        let still = k.art.node_for(e.image.as_ref(), true, &e.id, w, h, 10.0);
        let shown = if e.watched {
            Some(1.0)
        } else {
            e.progress.filter(|p| *p > 0.0)
        };
        let still = match shown {
            Some(p) => {
                let p = p.clamp(0.0, 1.0);
                let bar = Node::zstack(
                    Alignment::BOTTOM_LEADING,
                    vec![
                        Node::rect(Color::new(1.0, 1.0, 1.0, 0.30), 0.0).frame(
                            Some(w),
                            Some(4.0),
                            Alignment::CENTER,
                        ),
                        Node::rect(color(colour::MARK_ACCENT), 0.0).frame(
                            Some(w * p),
                            Some(4.0),
                            Alignment::CENTER,
                        ),
                    ],
                );
                still.overlay(bar, Alignment::BOTTOM_LEADING)
            }
            None => still,
        };
        return Node::hstack(Align::Start, Some(16.0), vec![still, text, icons])
            .padding(ins(10.0, 10.0, 10.0, 10.0))
            .frame(Some(820.0), Some(110.0), Alignment::TOP_LEADING)
            .key(key)
            .on_tap(Action::from(format!("episode:{}", e.id).as_str()))
            .on_secondary(Action::from(format!("tilemenu:{}", e.id).as_str()))
            .hover_surface(color(colour::GROUPS_AREA), 12.0)
            .hoverable()
            .press_style(swiftly_ui::interact::PressStyle::Row);
    }
    let text = Node::vstack(
        Align::Start,
        Some(2.0),
        vec![
            txt(k.cx, &name, weight(lk.body, 15.0, 600), tcolor, Some(2)),
            txt(
                k.cx,
                &second,
                weight(lk.small, 12.0, 400),
                colour::FONT_QUIET,
                Some(1),
            ),
        ],
    )
    .frame(Some(text_w), None, Alignment::LEADING);
    Node::hstack(Align::Center, Some(14.0), vec![img, text])
        .padding(ins(8.0, lk.edge, 8.0, lk.edge))
        .frame(None, None, Alignment::LEADING)
        .key(key)
        .on_tap(Action::from(format!("episode:{}", e.id).as_str()))
}

fn episodes_section(k: &Kit, d: &Data) -> Node {
    let lk = &k.lk;
    let (w, h) = episode_size(lk.form);
    let ep = &d.episodes;
    match ep.status {
        EpisodesStatus::Loading if lk.form == Form::Desktop => {
            // Three placeholder rows: still 160 x 90 and bars 220 x 14 and 90 x 11 (`SeriesView.swift:397`).
            let rows: Vec<Node> = (0..3)
                .map(|_| {
                    let bars = Node::vstack(
                        Align::Start,
                        Some(8.0),
                        vec![
                            Node::rect(color(colour::AREA), 3.0).frame(
                                Some(220.0),
                                Some(14.0),
                                Alignment::CENTER,
                            ),
                            Node::rect(color(colour::AREA), 3.0).frame(
                                Some(90.0),
                                Some(11.0),
                                Alignment::CENTER,
                            ),
                        ],
                    );
                    Node::hstack(
                        Align::Start,
                        Some(16.0),
                        vec![
                            Node::rect(color(colour::AREA), 10.0).frame(
                                Some(w),
                                Some(h),
                                Alignment::CENTER,
                            ),
                            bars,
                        ],
                    )
                    .padding(ins(10.0, 10.0, 10.0, 10.0))
                    .frame(Some(820.0), Some(110.0), Alignment::TOP_LEADING)
                })
                .collect();
            Node::vstack(Align::Start, Some(6.0), rows).padding(ins(0.0, lk.edge - 10.0, 0.0, 0.0))
        }
        EpisodesStatus::Loading => {
            let rows: Vec<Node> = (0..4)
                .map(|_| {
                    Node::rect(color(colour::AREA), lk.corner)
                        .frame(Some(w), Some(h), Alignment::CENTER)
                        .padding(ins(8.0, lk.edge, 8.0, lk.edge))
                })
                .collect();
            Node::vstack(Align::Start, Some(0.0), rows)
        }
        EpisodesStatus::Empty if lk.form == Form::Desktop => txt_center(
            k.cx,
            // `SeriesView.swift:344`: without seasons "Keine Folgen", with them the season is empty.
            if d.seasons.seasons.is_empty() {
                "Keine Folgen"
            } else {
                "Keine Folgen in dieser Staffel"
            },
            weight(lk.body, 15.0, 400),
            colour::FONT_VERY_QUIET,
            1,
        )
        .frame(Some(820.0), Some(200.0), Alignment::TOP)
        .padding(ins(40.0, lk.edge, 0.0, 0.0)),
        EpisodesStatus::Empty => txt(
            k.cx,
            "Keine Folgen in dieser Staffel",
            lk.body,
            colour::FONT_QUIET,
            Some(1),
        )
        .padding(ins(24.0, lk.edge, 24.0, lk.edge)),
        EpisodesStatus::Disturbed if lk.form == Form::Desktop => {
            // `DisturbHint` (`MacComponents.swift`): the symbol, the 20 semibold title, the sentence in very quiet 15 (262
            // wide) and the accent retry 44 high, centred over the page, 40 below the tabs' gap.
            let col = Node::vstack(
                Align::Center,
                Some(0.0),
                vec![
                    k.icons
                        .node("hard-drive-x", 30.0, true, color(colour::FONT_QUIET))
                        .padding(ins(0.0, 0.0, 14.0, 0.0)),
                    txt_center(k.cx, "Server ist abgetaucht", lk.rail, colour::FONT, 1)
                        .padding(ins(0.0, 0.0, 6.0, 0.0)),
                    txt_center(
                        k.cx,
                        &format!(
                            "{} antwortet nicht. L\u{e4}uft er noch, oder h\u{e4}ngt das WLAN?",
                            crate::desk::card().server_name()
                        ),
                        lk.body,
                        colour::FONT_VERY_QUIET,
                        3,
                    )
                    .frame(Some(262.0), None, Alignment::CENTER),
                    txt_center(
                        k.cx,
                        "Erneut versuchen",
                        weight(lk.body, 15.0, 500),
                        colour::MARK_ACCENT,
                        1,
                    )
                    .frame(None, Some(44.0), Alignment::CENTER)
                    .padding(ins(6.0, 0.0, 0.0, 0.0))
                    .key("retry")
                    .on_tap(Action::from("retry-episodes")),
                ],
            );
            col.frame(
                Some((k.env.size.w - 2.0 * lk.edge).max(262.0)),
                None,
                Alignment::TOP,
            )
            .padding(ins(40.0, lk.edge, 0.0, 0.0))
        }
        EpisodesStatus::Disturbed => status_card(
            k,
            "hard-drive-x",
            "Server ist abgetaucht",
            "Die Folgen kommen gerade nicht an.",
            "Erneut versuchen",
            "retry-episodes",
        )
        .frame(None, Some(300.0), Alignment::CENTER),
        EpisodesStatus::Ready => {
            if lk.form == Form::Tv {
                let kids: Vec<Node> = ep
                    .rows
                    .iter()
                    .enumerate()
                    .map(|(i, e)| episode_node(k, e, &format!("ep:{i}")))
                    .collect();
                let strip = Node::hstack(Align::Start, Some(lk.tile_gap), kids).padding(ins(
                    swiftly_ui::tuning::FOCUS_HEADROOM_PT,
                    lk.edge,
                    swiftly_ui::tuning::FOCUS_HEADROOM_PT,
                    lk.edge,
                ));
                Node::scroll(Axis::Horizontal, None, strip)
                    .frame(
                        None,
                        Some(h + 90.0 + 2.0 * swiftly_ui::tuning::FOCUS_HEADROOM_PT),
                        Alignment::TOP_LEADING,
                    )
                    .focus_scope(swiftly_ui::ScopeSpec::section(focus_id("episodes")))
            } else {
                let rows: Vec<Node> = ep
                    .rows
                    .iter()
                    .enumerate()
                    .map(|(i, e)| episode_node(k, e, &format!("ep:{i}")))
                    .collect();
                if lk.form == Form::Desktop {
                    // The list is shifted by -10 so the stills meet the page edge; rows are 6 apart; "Mehr Folgen"
                    // (14 semibold, accent, 12 above and below) follows while the core has more to show.
                    let list = Node::vstack(Align::Start, Some(6.0), rows).padding(ins(
                        0.0,
                        lk.edge - 10.0,
                        0.0,
                        0.0,
                    ));
                    if !ep.more_available {
                        return list;
                    }
                    let more = txt(
                        k.cx,
                        "Mehr Folgen",
                        weight(lk.body, 14.0, 600),
                        colour::MARK_ACCENT,
                        Some(1),
                    )
                    .padding(ins(12.0, lk.edge, 12.0, 0.0))
                    .key("more-episodes")
                    .on_tap(Action::from("more-episodes"))
                    .press_style(swiftly_ui::interact::PressStyle::Button);
                    return Node::vstack(Align::Start, Some(0.0), vec![list, more]);
                }
                Node::vstack(Align::Start, Some(0.0), rows)
            }
        }
    }
}

/// The page tabs (`PageTab`): the first is the season name with a chevron, then Besetzung, Ähnliches, Extras.
/// Design name: PageTab
fn tabs(k: &Kit, d: &Data, sx: &UiState) -> Node {
    let lk = &k.lk;
    let mut labels: Vec<(String, bool)> = vec![(
        d.seasons
            .seasons
            .iter()
            .find(|s| Some(&s.id) == d.seasons.selected.as_ref())
            .map_or_else(|| "Folgen".to_owned(), |s| s.name.clone()),
        d.seasons.seasons.len() > 1,
    )];
    labels.push(("Besetzung".into(), false));
    labels.push(("Ähnliches".into(), false));
    if !d.more.extras.is_empty() {
        labels.push(("Extras".into(), false));
    }
    let mac = lk.form == Form::Desktop;
    let size = if lk.form == Form::Tv {
        34.0
    } else if mac {
        15.0
    } else {
        17.0
    };
    let kids: Vec<Node> = labels
        .iter()
        .enumerate()
        .map(|(i, (s, chevron))| {
            let on = usize::from(sx.tab) == i;
            // `TabButton`: the word turns bright under the pointer as well.
            let lit = on || (mac && sx.hover_tab == Some(i as u8));
            let c = if lit {
                colour::FONT
            } else {
                colour::FONT_QUIET
            };
            let mut row = vec![txt(k.cx, s, weight(lk.rail, size, 600), c, Some(1))];
            if *chevron {
                // Mac: the chevron points up while the season list is open (`chevronOpen`).
                let name = if !mac {
                    "caret-right"
                } else if sx.menu.is_open() {
                    "caret-up"
                } else {
                    "caret-down"
                };
                row.push(
                    k.icons
                        .node(name, if mac { 11.0 } else { size * 0.7 }, true, color(c)),
                );
            }
            let key = format!("tab:{i}");
            let mut n = Node::hstack(Align::Center, Some(5.0), row).frame(
                None,
                Some(if mac { 26.0 } else { 44.0 }),
                Alignment::CENTER,
            );
            if mac {
                // 11 below the word, the open tab carries a 2 pt white line (`TabButton`).
                let line = Node::rect(
                    if on {
                        color(colour::FONT)
                    } else {
                        Color::CLEAR
                    },
                    0.0,
                )
                .frame(None, Some(2.0), Alignment::CENTER);
                n = n
                    .padding(ins(0.0, 0.0, 11.0, 0.0))
                    .overlay(wide(line, Alignment::BOTTOM), Alignment::BOTTOM);
            }
            n = n.key(key.as_str()).on_tap(Action::from(key.as_str()));
            if mac {
                n = n.on_hover(Action::from(format!("tab-hover:{i}").as_str()));
            }
            if lk.form == Form::Tv {
                n = n.focusable(focus_id(key.as_str()), Some(FocusLook::tile(12.0)));
            }
            n
        })
        .collect();
    let row = Node::hstack(
        Align::Center,
        Some(if lk.form == Form::Tv { 48.0 } else { 28.0 }),
        kids,
    );
    if mac {
        // The hairline runs under the whole tab row, 820 wide from the 36 margin.
        let line = Node::rect(color(colour::LINE), 0.0).frame(None, Some(1.0), Alignment::CENTER);
        return Node::vstack(
            Align::Start,
            Some(0.0),
            vec![row, wide(line, Alignment::CENTER)],
        )
        .frame(Some(820.0), None, Alignment::TOP_LEADING)
        .padding(ins(0.0, lk.edge, 0.0, 0.0));
    }
    row.padding(ins(0.0, lk.edge, 0.0, lk.edge))
}

fn page(d: &Data, sx: &UiState, env: &Env, cx: &Cx, art: &Art, icons: &Icons) -> Node {
    let k = Kit {
        cx,
        env,
        lk: look(env),
        art,
        icons,
    };
    let lk = &k.lk;
    let h = &d.head;
    let bottom_pad = match lk.form {
        Form::Touch => 32.0 + env.safe.bottom,
        Form::Desktop => 40.0,
        Form::Tv => 48.0,
    };
    let head = match lk.form {
        Form::Touch => vec![hero(&k, h, vec![]), body_touch(&k, h, sx.overview_open)],
        Form::Desktop => vec![hero(&k, h, hero_buttons(&k, h, sx.overview_open))],
        Form::Tv => vec![hero(&k, h, hero_buttons(&k, h, false))],
    };
    let section = match sx.tab {
        0 => episodes_section(&k, d),
        1 => {
            if d.more.cast.is_empty() {
                if lk.form == Form::Desktop && d.more.similar_loads {
                    // `SeriesView.swift:281`: while the lists still load the area waits empty, 200 high.
                    Node::fixed(0.0, 200.0)
                } else if lk.form == Form::Desktop {
                    txt(
                        cx,
                        "Keine Besetzung hinterlegt.",
                        weight(lk.body, 15.0, 400),
                        colour::FONT_VERY_QUIET,
                        Some(1),
                    )
                    .padding(ins(0.0, lk.edge, 0.0, 0.0))
                    .frame(None, Some(200.0), Alignment::TOP_LEADING)
                } else {
                    Node::fixed(0.0, 0.0)
                }
            } else {
                cast_rail(&k, &d.more.cast)
            }
        }
        // `TitleRail(play: true)`: the extras are posters like the other rails.
        3 if !d.more.extras.is_empty() => tile_rail(
            &k,
            "extras",
            "Extras",
            &d.more.extras,
            lk.form != Form::Desktop,
        ),
        _ if lk.form == Form::Desktop && !d.more.similar.is_empty() => {
            // `LazyVGrid`: tiles 150 wide, 16 apart, rows 20 apart.
            let per = (((env.size.w - 2.0 * lk.edge + 16.0) / (lk.poster.w + 16.0)).floor()
                as usize)
                .max(1);
            let rows: Vec<Node> = d
                .more
                .similar
                .chunks(per)
                .enumerate()
                .map(|(r, c)| {
                    Node::hstack(
                        Align::Start,
                        Some(16.0),
                        c.iter()
                            .enumerate()
                            .map(|(i, t)| {
                                poster_tile(&k, t, &format!("similar:{}", r * per + i), false)
                            })
                            .collect(),
                    )
                })
                .collect();
            Node::vstack(Align::Start, Some(20.0), rows).padding(ins(0.0, lk.edge, 0.0, 0.0))
        }
        _ => {
            if d.more.similar.is_empty() && lk.form == Form::Desktop && d.more.similar_loads {
                Node::fixed(0.0, 200.0)
            } else if d.more.similar.is_empty() && lk.form == Form::Desktop && d.more.similar_failed
            {
                // `DisturbHint(retry: refresh)`.
                status_card(
                    &k,
                    "hard-drive-x",
                    "Das ging schief.",
                    "Der Server antwortet nicht.",
                    "Erneut versuchen",
                    "retry-similar",
                )
                .frame(None, Some(200.0), Alignment::CENTER)
            } else if d.more.similar.is_empty() && lk.form == Form::Desktop {
                txt(
                    cx,
                    "Nichts Ähnliches gefunden",
                    weight(lk.body, 15.0, 400),
                    colour::FONT_VERY_QUIET,
                    Some(1),
                )
                .padding(ins(0.0, lk.edge, 0.0, 0.0))
                .frame(None, Some(200.0), Alignment::TOP_LEADING)
            } else if d.more.similar.is_empty() {
                let s = if d.more.similar_failed {
                    "Das ging schief. Der Server antwortet nicht."
                } else {
                    "Nichts Ähnliches gefunden."
                };
                txt(cx, s, lk.body, colour::FONT_QUIET, Some(2))
                    .padding(ins(0.0, lk.edge, 0.0, lk.edge))
            } else {
                tile_rail(
                    &k,
                    "similar",
                    if lk.form == Form::Desktop {
                        "Ähnliches"
                    } else {
                        "Ähnliche Titel"
                    },
                    &d.more.similar,
                    false,
                )
            }
        }
    };
    let mut kids = head;
    if lk.form != Form::Touch && !d.more.watchers.is_empty() {
        // `WatchersRow`: between the head and the tabs, 34 below the head (`SeriesView.swift:153`).
        kids.push(
            crate::detail_screen::watchers_rail(&k, &d.more.watchers)
                .padding(ins(34.0, 0.0, 0.0, 0.0)),
        );
    }
    let (gap, top) = if lk.form == Form::Desktop {
        (14.0, 34.0)
    } else {
        (12.0, 22.0)
    };
    kids.push(
        Node::vstack(Align::Start, Some(gap), vec![tabs(&k, d, sx), section])
            .padding(ins(top, 0.0, 0.0, 0.0)),
    );
    let mut column = wide(
        Node::vstack(Align::Start, Some(0.0), kids).padding(ins(0.0, 0.0, bottom_pad, 0.0)),
        Alignment::TOP_LEADING,
    );
    let tones = k.art.tones_for(h.image.as_ref(), &h.id);
    if lk.form == Form::Touch && !tones.is_empty() {
        // The mood-colour backdrop of the title pages (`StretchedMood` over `since + 1300`), as on the Detail page.
        let since = if lk.pad { 420.0 } else { 350.0 };
        let total = since + swiftly_images::mood::RUN_OUT as f32;
        column = column.background(
            mood_strips(&tones, since, (0.0, total), 0.0, env.size.w, |_| 1.0),
            Alignment::TOP_LEADING,
        );
    }
    if lk.form == Form::Desktop && !tones.is_empty() {
        let total = HERO_DESKTOP + swiftly_images::mood::RUN_OUT as f32;
        column = column.background(
            mood_strips(&tones, HERO_DESKTOP, (0.0, total), 0.0, env.size.w, |_| 1.0),
            Alignment::TOP_LEADING,
        );
    }
    let scroll = Node::scroll(Axis::Vertical, None, column).key("series-scroll");
    let mut page = fill_frame(scroll, Alignment::TOP_LEADING)
        .overlay(top_bar(&k, &h.title, sx.header), Alignment::TOP);
    if lk.form == Form::Desktop
        && let Some(menu) = sx.menu.overlay(cx, env)
    {
        page = page.overlay(menu, Alignment::TOP_LEADING);
    }
    match sx.sheet {
        1 => {
            let rows: Vec<(String, bool)> = d.menu.iter().map(|s| (s.clone(), false)).collect();
            page = page.overlay(sheet(&k, &h.title, &rows, "menu"), Alignment::CENTER);
        }
        2 => {
            let rows: Vec<(String, bool)> = d.versions.iter().map(|s| (s.clone(), false)).collect();
            page = page.overlay(version_sheet(&k, VERSION_TITLE, &rows), Alignment::CENTER);
        }
        3 => {
            let rows: Vec<(String, bool)> = d
                .seasons
                .seasons
                .iter()
                .map(|s| (s.name.clone(), Some(&s.id) == d.seasons.selected.as_ref()))
                .collect();
            page = page.overlay(
                sheet(&k, "Staffel wählen", &rows, "season"),
                Alignment::CENTER,
            );
        }
        _ => {}
    }
    let _ = (rgba, txt_center, resume_info, wide, tv::BUTTON_HEIGHT);
    ground(page)
}

/// The Series screen: a UI over a `SeriesVm`, pushed from a poster of a list.
pub struct SeriesScreen {
    host: Pushed<Data>,
    vm: SeriesVm<AppTransport>,
    log: Vec<String>,
    play_req: Option<crate::live_play::PlayRequest>,
    /// "Laden" was chosen: the button rect the season sheet grows out of (once, see `take_download`).
    download_req: Option<Option<swiftly_layout::Rect>>,
    person_req: Option<crate::pages_screen::PersonTap>,
    /// The similar tile that was tapped (the Mac's `navigator.openIt(.title)`), once.
    tile_req: Option<swiftly_vm::Tile>,
    message_since: Option<f64>,
    /// Trailer links the core wants opened in the browser, taken by the app.
    web_req: Vec<String>,
    /// The versions of the open choice and the title and second it starts at.
    versions: Vec<swiftly_vm::VersionOption>,
    choose: Option<(String, f64)>,
    /// The More menu as the core lists it.
    menu: Vec<swiftly_vm::MenuEntry>,
    /// The options last sent to the core.
    sent_options: Option<swiftly_vm::SeriesOptions>,
    /// The tile whose menu is open (a similar or extra tile, or an episode).
    tile_id: Option<String>,
    /// "Abspielen auf \u{2026}" and "Gemeinsam schauen" of the tile menu, for the host (`take_requests`).
    requests: Vec<swiftly_vm::TileRequest>,
    /// View models of tile-menu writes, kept until the request has gone out.
    writers: Vec<DetailVm<AppTransport>>,
    /// The list changes already reloaded for (`desk::list_changes`, the Mac's `pagesRefresh`).
    seen_changes: u64,
    /// The season the episode really belongs to, waiting for the seasons to be loaded; `true` once the reader
    /// picked a season themselves (then the fresh one never overrides it).
    fresh_season: Option<(Option<String>, Option<i64>)>,
    picked_season: bool,
    art: Rc<Art>,
}

impl SeriesScreen {
    /// What a screen reader gets for this screen: the nodes of the current picture.
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.host.a11y_nodes()
    }

    /// A series screen for `env` over a scripted server in `scenario`; the list is in front until [`Self::open`].
    pub fn new(env: Env, cx: Cx, scenario: Scenario) -> SeriesScreen {
        Self::with_root(env, cx, scenario, false)
    }

    /// A series screen for the app: the root page is transparent (see `DetailScreen::overlay`).
    pub fn overlay(env: Env, cx: Cx, scenario: Scenario) -> SeriesScreen {
        Self::with_root(env, cx, scenario, true)
    }

    fn with_root(env: Env, cx: Cx, scenario: Scenario, bare: bool) -> SeriesScreen {
        let vm = title_data::series_vm(scenario);
        let art = Rc::new(Art::new(&cx));
        let icons = Icons::new(&cx, env.scale);
        let art2 = Rc::clone(&art);
        let art3 = Rc::clone(&art);
        let data = Self::data(&vm, &[], &[], &art);
        let host = Pushed::new(
            env,
            cx,
            data,
            Rc::clone(&art),
            bare,
            move |d, sx, env, cx| page(d, sx, env, cx, &art2, &icons),
        );
        let mut s = SeriesScreen {
            host,
            vm,
            log: Vec::new(),
            play_req: None,
            download_req: None,
            person_req: None,
            tile_req: None,
            message_since: None,
            web_req: Vec::new(),
            versions: Vec::new(),
            choose: None,
            menu: Vec::new(),
            sent_options: crate::live::current().map(|w| title_data::live_series_options(&w)),
            tile_id: None,
            requests: Vec::new(),
            writers: Vec::new(),
            seen_changes: crate::desk::list_changes(),
            fresh_season: None,
            picked_season: false,
            art: art3,
        };
        s.refresh();
        s
    }

    fn data(
        vm: &SeriesVm<AppTransport>,
        versions: &[swiftly_vm::VersionOption],
        menu: &[swiftly_vm::MenuEntry],
        art: &Art,
    ) -> Data {
        let head = head_of(&vm.button(), vm.directors());
        let tones = !art.tones_for(head.image.as_ref(), &head.id).is_empty();
        Data {
            head,
            seasons: vm.seasons(),
            episodes: vm.episodes(),
            more: vm.more(),
            menu: menu.iter().map(|e| e.text.clone()).collect(),
            versions: versions.iter().map(|v| v.label.clone()).collect(),
            tones,
        }
    }

    fn refresh(&mut self) {
        self.menu = self.vm.more_menu();
        let d = Self::data(&self.vm, &self.versions, &self.menu, &self.art);
        // The Extras tab goes away with the extras: back to the episodes (`SeriesView.swift:251`).
        if self.host.sx.tab == 3 && d.more.extras.is_empty() {
            self.host.sx.tab = 0;
        }
        self.host.set_data(d);
        self.host.sync();
    }

    /// What the core tells the host to do (the Mac's `drainSeries`): play, trailer, browser link, the state notes.
    fn pump_effects(&mut self) {
        use swiftly_vm::{MenuKind, SeriesEffect as E};
        self.pump_fresh_season();
        if let Some(w) = crate::live::current() {
            let options = title_data::live_series_options(&w);
            if self.sent_options.as_ref() != Some(&options) {
                self.sent_options = Some(options.clone());
                self.vm.send(SeriesIntent::Options(options));
            }
            // The Mac's `pagesRefresh`: after the player, a state change or a watchlist change the page loads again.
            let n = crate::desk::list_changes();
            if n != self.seen_changes {
                self.seen_changes = n;
                self.vm.send(SeriesIntent::Refresh);
            }
        }
        for effect in self.vm.take_effects() {
            match effect {
                E::Play(action) => self.launch(action, None),
                E::PlayTrailer { item, .. } => {
                    self.play_req = Some(crate::live_play::PlayRequest {
                        item_id: item.id.clone(),
                        since: 0.0,
                        source_id: None,
                    });
                    self.log.push(format!("play trailer {}", item.id));
                }
                E::OpenWeb(url) => self.web_req.push(url.to_string()),
                // The series' own entries act on the episode that plays next (`SeriesView.moreActions`).
                E::Menu(MenuKind::PlayOn { id, .. }) => {
                    let title = self.next_title();
                    self.requests.push(swiftly_vm::TileRequest::PlayOn {
                        id: title,
                        device: id,
                    });
                }
                E::Menu(MenuKind::Together) => {
                    let id = self.next_title();
                    self.requests.push(swiftly_vm::TileRequest::Together { id });
                }
                E::Menu(MenuKind::Shuffle) => {
                    self.log.push("host menu entry not available here".into());
                }
                E::Menu(_) => {}
                E::StateChanged | E::WatchlistChanged => crate::desk::note_list_change(),
            }
        }
    }

    /// What a press on Play (or a menu entry that plays) does, as the core decides it (`SeriesCore.launch`).
    fn launch(&mut self, action: PlayAction, since: Option<f64>) {
        match action {
            PlayAction::Wait => {}
            PlayAction::Choose {
                item_id,
                since: at,
                versions,
            } => {
                self.choose = Some((item_id, since.unwrap_or(at)));
                self.versions = versions;
                self.log.push("play choose".into());
                self.host.sx.sheet = 2;
            }
            // The list entry has no `MediaSources`: the player fetches and asks itself (as on the Mac).
            PlayAction::Resolve { item_id, since: at } => {
                self.play_req = Some(crate::live_play::PlayRequest {
                    item_id,
                    since: since.unwrap_or(at),
                    source_id: None,
                });
                self.log.push("play resolve".into());
            }
            PlayAction::Start {
                item_id,
                since: at,
                source_id,
            } => {
                self.play_req = Some(crate::live_play::PlayRequest {
                    item_id,
                    since: since.unwrap_or(at),
                    source_id,
                });
                self.log.push("play start".into());
            }
        }
    }

    /// What a press on an episode does: the main button's episode goes through `play_next`, so a pick works when it
    /// lies in another season than the open one (`SeriesCore.episodeAction`).
    fn episode_action(&self, id: &str) -> PlayAction {
        if self.vm.button().next_episode.as_deref() == Some(id) {
            self.vm.play_next(None)
        } else {
            self.vm.play_episode(id, None)
        }
    }

    /// The tile of a similar or extra tile, or of an episode row, by id.
    fn tile_by_id(&self, id: &str) -> Option<swiftly_vm::Tile> {
        let more = self.vm.more();
        more.similar
            .iter()
            .chain(more.extras.iter())
            .find(|t| t.id == id)
            .cloned()
            .or_else(|| {
                let series = self.vm.button().id.clone();
                self.vm
                    .episodes()
                    .rows
                    .iter()
                    .find(|e| e.id == id)
                    .map(|e| episode_tile(e, &series))
            })
    }

    /// The fresh season of the episode that opened this page (`SeasonTarget`): applied as soon as the seasons are known,
    /// unless the reader chose one meanwhile.
    pub fn apply_fresh_season(&mut self, series: &str, id: Option<String>, number: Option<i64>) {
        if self.vm.button().id == series {
            self.fresh_season = Some((id, number));
        }
    }

    fn pump_fresh_season(&mut self) {
        if self.fresh_season.is_none() {
            return;
        }
        let seasons = self.vm.seasons();
        if seasons.seasons.is_empty() {
            return;
        }
        let (id, number) = self.fresh_season.take().unwrap_or_default();
        if self.picked_season {
            return;
        }
        let row = seasons
            .seasons
            .iter()
            .find(|r| id.as_deref() == Some(r.id.as_str()))
            .or_else(|| number.and_then(|n| seasons.seasons.iter().find(|r| r.number == Some(n))));
        if let Some(row) = row
            && seasons.selected.as_deref() != Some(row.id.as_str())
        {
            self.vm
                .send(SeriesIntent::SelectSeason { id: row.id.clone() });
        }
    }

    /// Trailer links of the core for the browser, once.
    pub fn take_web(&mut self) -> Vec<String> {
        std::mem::take(&mut self.web_req)
    }

    /// The view model.
    pub fn vm(&self) -> &SeriesVm<AppTransport> {
        &self.vm
    }

    /// What the UI asked of the host (play, person, tile): readable lines for tests.
    pub fn log(&self) -> &[String] {
        &self.log
    }

    /// Whether the series page is pushed.
    pub fn is_open(&self) -> bool {
        self.host.depth() > 1
    }

    /// Pushes the series page as a tap on a poster does.
    pub fn open(&mut self, now: f64) {
        self.host.push(now);
    }

    /// The title page is fully in and nothing moves (the app then skips drawing the page below).
    pub fn below(&self) -> Option<(f32, f32)> {
        self.host.below()
    }

    /// Whether the page is fully in.
    pub fn covers(&self) -> bool {
        self.host.covers()
    }

    /// Back (Esc): closes the open panel or sheet first (the Mac closes only the popover), then pops the page.
    pub fn back(&mut self, now: f64) -> bool {
        if self.host.sx.menu.is_open() || self.host.sx.sheet != 0 {
            let _ = self.nav_key(swiftly_ui::NavKey::Escape, true, now);
            return true;
        }
        self.host.pop(now)
    }

    /// The "Laden" request of the last press, once: the rect of the button the season sheet hangs under (`None` when
    /// the page has not been laid out). The host builds a `LoadRequest::Season` for the series.
    pub fn take_download(&mut self) -> Option<Option<swiftly_layout::Rect>> {
        self.download_req.take()
    }

    /// The cast tile that was tapped, once.
    pub fn take_person(&mut self) -> Option<crate::pages_screen::PersonTap> {
        self.person_req.take()
    }

    /// The episode that plays next (the series itself when the server names none).
    fn next_title(&self) -> String {
        let b = self.vm.button();
        b.next_episode.clone().unwrap_or_else(|| b.id.clone())
    }

    /// The requests of the tile menu for the host since the last call.
    pub fn take_requests(&mut self) -> Vec<swiftly_vm::TileRequest> {
        std::mem::take(&mut self.requests)
    }

    /// What the create panel says the group will watch when `id` (an episode row or a tile of this page) is chosen.
    pub fn together_line(&self, id: &str) -> Option<String> {
        let series = self.vm.button().title.clone();
        if let Some(row) = self.vm.episodes().rows.iter().find(|e| e.id == id) {
            let (season, number) = row
                .code
                .as_deref()
                .and_then(crate::together_ui::parse_code)
                .map_or((None, row.number), |(s, e)| (Some(s), Some(e)));
            return Some(crate::together_ui::title_line(
                true, &series, season, number, &row.title,
            ));
        }
        self.tile_by_id(id)
            .map(|t| crate::together_ui::tile_line(&t))
    }

    /// The similar tile that was tapped, once: the title page of that tile opens next.
    pub fn take_tile(&mut self) -> Option<swiftly_vm::Tile> {
        self.tile_req.take()
    }

    fn title_now(&self) -> Option<String> {
        let t = self.vm.button().title.clone();
        Some(t).filter(|t| !t.is_empty())
    }

    /// The play request of the last press, once.
    pub fn take_play(&mut self) -> Option<crate::live_play::PlayRequest> {
        self.play_req.take()
    }

    fn drain(&mut self, now: f64) {
        for a in self.host.drain(now) {
            let is = |s: &str| a == Action::from(s);
            let desktop = self.host.ui().env().idiom == swiftly_ui::Idiom::Desktop;
            let pressed = {
                let more = self.vm.more();
                let rows = self.vm.episodes();
                more.similar
                    .iter()
                    .chain(more.extras.iter())
                    .map(|t| t.id.as_str())
                    .chain(rows.rows.iter().map(|e| e.id.as_str()))
                    .find(|id| is(&format!("tilemenu:{id}")))
                    .map(str::to_owned)
            };
            // The short menu of an episode row (the Mac's `Menu { Abspielen, Als gesehen markieren }`) and its entries.
            let episodes: Vec<(String, bool)> = self
                .vm
                .episodes()
                .rows
                .iter()
                .map(|e| (e.id.clone(), e.watched))
                .collect();
            let row_menu = episodes
                .iter()
                .find(|(id, _)| is(&format!("epmenu:{id}")))
                .cloned();
            let row_play = episodes
                .iter()
                .find(|(id, _)| is(&format!("epplay:{id}")))
                .cloned();
            let row_seen = episodes
                .iter()
                .find(|(id, _)| is(&format!("epseen:{id}")))
                .cloned();
            if a == popover::DISMISS {
                self.host.sx.menu.close();
            } else if let Some((id, watched)) = row_menu {
                let rect = self
                    .host
                    .ui()
                    .frame_of(format!("epmore:{id}").as_str())
                    .map_or(swiftly_layout::Rect::new(0.0, 0.0, 18.0, 18.0), |f| {
                        swiftly_layout::Rect::new(f[0], f[1], f[2], f[3])
                    });
                self.host.sx.menu.open(
                    short_episode_menu(&id, watched),
                    Anchor::Button(rect),
                    260.0,
                    false,
                );
            } else if let Some((id, _)) = row_play {
                self.host.sx.menu.close();
                let play = self.episode_action(&id);
                self.launch(play, None);
            } else if let Some((id, watched)) = row_seen {
                self.host.sx.menu.close();
                self.vm
                    .send(SeriesIntent::SetEpisodeWatched { id, on: !watched });
                crate::desk::note_list_change();
            } else if desktop && let Some(id) = pressed {
                // Right click on a tile or an episode: the Mac's tile menu (`TileMenuMac`) at the pointer.
                self.tile_id = Some(id.clone());
                let tile = self.tile_by_id(&id);
                let cx = crate::tile_menu::context_for(tile.as_ref());
                let items = crate::tile_menu::pop_items(Form::Desktop, &cx, tile.as_ref());
                if !items.is_empty() {
                    let p = self.host.pointer;
                    self.host.sx.menu.open(
                        items,
                        Anchor::Pointer(swiftly_layout::Point::new(p.0, p.1)),
                        swiftly_ui::feel::DROPDOWN_WIDTH,
                        false,
                    );
                }
            } else if desktop && is("more") {
                let rect = self
                    .host
                    .ui()
                    .frame_of("more")
                    .map_or(swiftly_layout::Rect::new(0.0, 0.0, 48.0, 56.0), |f| {
                        swiftly_layout::Rect::new(f[0], f[1], f[2], f[3])
                    });
                // The entries are the core's (`page.model.moreMenu()`), then "Laden" (the episode selection).
                let mut items: Vec<popover::MenuEntry> = self
                    .menu
                    .iter()
                    .enumerate()
                    .map(|(i, e)| {
                        popover::MenuEntry::Item(
                            MenuItem::new(
                                Action::from(format!("menu:{i}").as_str()),
                                e.text.clone(),
                            )
                            .icon(crate::tile_menu::more_icon(&e.kind)),
                        )
                    })
                    .collect();
                items.push(popover::MenuEntry::Item(
                    MenuItem::new(Action::from("download"), "Laden").icon("arrow-circle-down"),
                ));
                self.host
                    .sx
                    .menu
                    .open(items, Anchor::Button(rect), 260.0, false);
            } else if is("play") {
                let a = self.vm.play_next(None);
                self.launch(a, None);
            } else if let Some(t) = self
                .vm
                .more()
                .extras
                .iter()
                .find(|t| is(&format!("tile:{}", t.id)))
                .cloned()
            {
                // `SeriesView.swift:292`: an extra plays from the start instead of opening a page.
                self.play_req = Some(crate::live_play::PlayRequest {
                    item_id: t.id.clone(),
                    since: 0.0,
                    source_id: None,
                });
                self.log.push(format!("play extra {}", t.id));
            } else if let Some(tile) = self
                .vm
                .more()
                .similar
                .iter()
                .find(|t| is(&format!("tile:{}", t.id)))
                .cloned()
            {
                self.log.push(format!("open {}", tile.id));
                self.tile_req = Some(tile);
            } else if let Some(c) = self
                .vm
                .more()
                .cast
                .iter()
                .find(|c| is(&format!("person:{}", c.id)))
                .cloned()
            {
                self.person_req = Some(crate::pages_screen::PersonTap {
                    id: c.id,
                    name: c.name,
                    role: c.role,
                    image: c.image,
                    origin: self.title_now(),
                });
            } else if is("favorite") {
                self.vm.send(SeriesIntent::SetWatchlist {
                    on: !self.vm.button().favorite,
                });
                crate::desk::note_list_change();
            } else if is("watched") {
                self.vm.send(SeriesIntent::SetWatched {
                    on: !self.vm.button().watched,
                });
                crate::desk::note_list_change();
            } else if is("more") {
                self.host.sx.sheet = 1;
            } else if is("overview") {
                self.host.sx.overview_open = !self.host.sx.overview_open;
            } else if is("close-sheet") {
                self.host.sx.sheet = 0;
            } else if is("dismiss") {
                self.vm.send(SeriesIntent::DismissMessage);
            } else if is("retry-similar") {
                // The Mac's `page?.model.refresh()`.
                self.vm.send(SeriesIntent::Refresh);
            } else if is("retry-episodes") || is("retry") {
                self.vm.send(SeriesIntent::RetryEpisodes);
            } else if is("more-episodes") {
                self.vm.send(SeriesIntent::MoreEpisodes);
            } else if is("download") {
                // The season sheet grows out of the button that opened the menu.
                let at = self
                    .host
                    .ui()
                    .frame_of("more")
                    .map(|f| swiftly_layout::Rect::new(f[0], f[1], f[2], f[3]));
                self.host.sx.menu.close();
                self.download_req = Some(at);
            } else if is("menu:0") && self.menu.is_empty() {
                // No entries from the core (scripted pages): the season mark, as before.
                self.host.sx.sheet = 0;
                self.host.sx.menu.close();
                self.vm.send(SeriesIntent::MarkSeasonWatched);
                crate::desk::note_list_change();
            } else {
                for i in 0..4_u8 {
                    if is(&format!("tab:{i}")) {
                        let several = self.vm.seasons().seasons.len() > 1;
                        if i == 0 && self.host.sx.tab == 0 && several {
                            if desktop {
                                // Mac: the first tab toggles the season list under it (220 wide, `leap`).
                                if self.host.sx.menu.is_open() {
                                    self.host.sx.menu.close();
                                } else {
                                    let seasons = self.vm.seasons();
                                    let items = seasons
                                        .seasons
                                        .iter()
                                        .enumerate()
                                        .map(|(n, s)| {
                                            popover::MenuEntry::Item(
                                                MenuItem::new(
                                                    Action::from(format!("season:{n}").as_str()),
                                                    s.name.clone(),
                                                )
                                                .checked(Some(&s.id) == seasons.selected.as_ref()),
                                            )
                                        })
                                        .collect();
                                    let rect = self.host.ui().frame_of("tab:0").map_or(
                                        swiftly_layout::Rect::new(36.0, 0.0, 120.0, 26.0),
                                        |f| swiftly_layout::Rect::new(f[0], f[1], f[2], f[3]),
                                    );
                                    self.host.sx.menu.open(
                                        items,
                                        Anchor::Button(rect),
                                        220.0,
                                        false,
                                    );
                                    // `listBackground`: the page's own tone under the rows (`ImageTone.color(tones,
                                    // (0.2, 0.55))`), so the list is not a foreign grey.
                                    let head = head_of(&self.vm.button(), self.vm.directors());
                                    let tones = self.art.tones_for(head.image.as_ref(), &head.id);
                                    if !tones.is_empty() {
                                        let total = crate::detail_screen::HERO_DESKTOP
                                            + swiftly_images::mood::RUN_OUT as f32;
                                        let at = crate::detail_screen::mood_sampler(
                                            &tones,
                                            crate::detail_screen::HERO_DESKTOP,
                                        )(
                                            0.2, 0.55 * total
                                        );
                                        self.host.sx.menu.set_tint(Some(at));
                                    }
                                }
                            } else {
                                self.host.sx.sheet = 3;
                            }
                        } else if desktop {
                            self.host.sx.menu.close();
                        }
                        self.host.sx.tab = i;
                    }
                }
                for i in 0..self.menu.len() {
                    if is(&format!("menu:{i}")) {
                        self.host.sx.sheet = 0;
                        self.host.sx.menu.close();
                        self.vm.send(SeriesIntent::Menu(self.menu[i].kind.clone()));
                    }
                }
                for i in 0..self.versions.len() {
                    if is(&format!("version:{i}")) {
                        self.host.sx.sheet = 0;
                        self.play_req = self.choose.clone().map(|(item_id, since)| {
                            crate::live_play::PlayRequest {
                                item_id,
                                since,
                                source_id: Some(self.versions[i].id.clone()),
                            }
                        });
                        self.log
                            .push(format!("start version {}", self.versions[i].id));
                    }
                }
                self.tile_pick(&a);
                let seasons = self.vm.seasons();
                for (i, s) in seasons.seasons.iter().enumerate() {
                    if is(&format!("season:{i}")) {
                        self.picked_season = true;
                        self.host.sx.sheet = 0;
                        self.host.sx.menu.close();
                        self.vm
                            .send(SeriesIntent::SelectSeason { id: s.id.clone() });
                    }
                }
                for e in &self.vm.episodes().rows {
                    if is(&format!("episode:{}", e.id)) {
                        self.host.sx.menu.close();
                        let a = self.episode_action(&e.id);
                        self.launch(a, None);
                    }
                }
            }
        }
        self.refresh();
    }

    /// A pick of the tile menu (`tmenu:{i}`) for the tile it was opened on.
    fn tile_pick(&mut self, a: &Action) {
        let Some(id) = self.tile_id.clone() else {
            return;
        };
        let tile = self.tile_by_id(&id);
        let cx = crate::tile_menu::context_for(tile.as_ref());
        // The device list of "Abspielen auf \u{2026}": the title goes to that device.
        for (i, (device, _)) in cx.host.play_on.iter().enumerate() {
            if *a == Action::from(format!("tdev:{i}").as_str()) {
                self.host.sx.menu.close();
                self.requests.push(swiftly_vm::TileRequest::PlayOn {
                    id: id.clone(),
                    device: device.clone(),
                });
            }
        }
        let entries = crate::tile_menu::entries(Form::Desktop, &cx, tile.as_ref());
        for (i, e) in entries.into_iter().enumerate() {
            if *a != Action::from(format!("tmenu:{i}").as_str()) {
                continue;
            }
            self.host.sx.menu.close();
            let Some(t) = tile.clone() else { continue };
            match e {
                crate::tile_menu::Entry::Together => {
                    self.requests
                        .push(swiftly_vm::TileRequest::Together { id: id.clone() });
                    continue;
                }
                crate::tile_menu::Entry::PlayOn => {
                    let items = cx
                        .host
                        .play_on
                        .iter()
                        .enumerate()
                        .map(|(i, (_, name))| {
                            popover::MenuEntry::Item(MenuItem::new(
                                Action::from(format!("tdev:{i}").as_str()),
                                name.clone(),
                            ))
                        })
                        .collect();
                    let p = self.host.pointer;
                    self.host.sx.menu.open(
                        items,
                        Anchor::Pointer(swiftly_layout::Point::new(p.0, p.1)),
                        swiftly_ui::feel::DROPDOWN_WIDTH,
                        false,
                    );
                    continue;
                }
                _ => {}
            }
            match crate::tile_menu::run(&e, &t, &cx, &mut self.writers) {
                crate::tile_menu::Outcome::Play(req) => {
                    self.log.push(format!("play {}", t.id));
                    self.play_req = Some(req);
                }
                crate::tile_menu::Outcome::Open => {
                    self.log.push(format!("open {}", t.id));
                    self.tile_req = Some(t);
                }
                crate::tile_menu::Outcome::Wrote => self.log.push(format!("menu {e:?} {}", t.id)),
                crate::tile_menu::Outcome::Nothing => {}
            }
        }
    }

    /// Arrow, Tab, Enter or Esc on the focus engine; Esc goes back.
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
        if self.host.sx.sheet != 0 && key == swiftly_ui::NavKey::Escape && down {
            self.host.sx.sheet = 0;
            self.refresh();
            return swiftly_ui::Outcome::None;
        }
        let out = self.host.ui().nav_key(key, down, now);
        if out == swiftly_ui::Outcome::Back(swiftly_ui::BackOutcome::Pop) {
            self.host.pop(now);
        }
        self.drain(now);
        out
    }

    /// A finger goes down.
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

    /// One frame at `now` ms.
    pub fn frame(&mut self, now: f64) -> (DrawList, bool) {
        self.refresh();
        if self.vm.button().message.is_some() {
            let since = *self.message_since.get_or_insert(now);
            if now - since >= 3000.0 {
                self.message_since = None;
                self.vm.send(SeriesIntent::DismissMessage);
            }
        } else {
            self.message_since = None;
        }
        let r = self.host.frame_list(now);
        self.drain(now);
        self.pump_effects();
        r
    }

    /// The frame `(x, y, w, h)` of a keyed node in window points (tests click and hover by it).
    pub fn frame_of(&mut self, key: &str) -> Option<[f32; 4]> {
        self.host.ui().frame_of(key)
    }

    /// The pointer moved to `(x, y)` (hover, tooltips, cursor).
    pub fn pointer_move(&mut self, x: f32, y: f32, now: f64) {
        self.host.ui().pointer_move(x, y, now);
    }

    /// The pointer left the window.
    pub fn pointer_leave(&mut self, now: f64) {
        self.host.ui().pointer_leave(now);
    }

    /// A right click at `(x, y)`; true when a node took it.
    pub fn secondary_click(&mut self, x: f32, y: f32, now: f64) -> bool {
        let took = self.host.ui().secondary_click(x, y, now);
        self.drain(now);
        took
    }

    /// A mouse wheel step scrolls the page under the pointer.
    pub fn wheel_scroll(&mut self, x: f32, y: f32, dx: f32, dy: f32, now: f64) -> bool {
        self.host.ui().wheel_scroll(x, y, dx, dy, now)
    }

    /// The cursor the node under the pointer asks for.
    pub fn cursor(&mut self) -> swiftly_ui::Cursor {
        self.host.ui().cursor()
    }

    /// The tooltip to draw at `now`.
    pub fn visible_tooltip(&mut self, now: f64) -> Option<(String, swiftly_layout::Rect)> {
        self.host.ui().visible_tooltip(now)
    }

    /// Closes the anchored panel: the sheet that came from it is up (or gone), and the Mac shows no menu there.
    pub fn close_menu(&mut self) {
        self.host.sx.menu.close();
    }

    /// An anchored panel (More, season list, episode menu) is open.
    pub fn menu_open(&mut self) -> bool {
        self.host.sx.menu.is_open()
    }

    /// Shows the real pictures of the server through `hub` (without it the demo art stays).
    #[must_use]
    pub fn with_images(self, hub: std::rc::Rc<crate::hub::ImageHub>) -> Self {
        crate::hub::HubSlotExt::attach(&self.host.hub, hub);
        self
    }

    /// Waits for every picture and applies it (headless goldens).
    pub fn settle_images(&mut self, now: f64) {
        crate::hub::HubSlotExt::settle(&self.host.hub, now);
    }

    /// An animation or a glide needs another frame.
    pub fn wants_frame(&self) -> bool {
        self.host.wants_frame()
    }

    /// A new window size or scale.
    pub fn set_env(&mut self, env: Env) {
        self.host.set_env(env);
    }

    /// The services (atlas pages) the renderers read.
    pub fn cx(&self) -> &Cx {
        self.host.cx()
    }

    /// Renders a list with the software renderer.
    pub fn render_software(&self, list: &DrawList) -> RgbaImage {
        self.host.render(list)
    }

    /// Scroll offsets of all scroll views in tree order.
    pub fn scroll_offsets(&mut self) -> Vec<f64> {
        self.host.ui().scroll_offsets()
    }

    /// The focused key on tv.
    pub fn focused(&mut self) -> Option<swiftly_ui::FocusId> {
        self.host.ui().focused()
    }

    /// Opens a sheet (tests): 1 more, 3 seasons.
    pub fn open_sheet(&mut self, which: u8) {
        self.host.sx.sheet = which;
        self.refresh();
    }

    /// Switches the tab (tests).
    pub fn set_tab(&mut self, tab: u8) {
        self.host.sx.tab = tab;
        self.refresh();
    }
}

/// The short menu of an episode row: play it, mark it (the Mac's `Menu` in `EpisodesRow`).
fn short_episode_menu(id: &str, watched: bool) -> Vec<popover::MenuEntry> {
    vec![
        popover::MenuEntry::Item(MenuItem::new(
            Action::from(format!("epplay:{id}").as_str()),
            "Abspielen",
        )),
        popover::MenuEntry::Item(MenuItem::new(
            Action::from(format!("epseen:{id}").as_str()),
            if watched {
                "Als ungesehen markieren"
            } else {
                "Als gesehen markieren"
            },
        )),
    ]
}

#[cfg(test)]
mod round2_tests {
    use super::*;

    fn demo() -> SeriesScreen {
        let env = Env::new(
            swiftly_layout::Size::new(1280.0, 800.0),
            1.0,
            swiftly_ui::Idiom::Desktop,
        );
        let mut s = SeriesScreen::new(env, Cx::deterministic(), Scenario::Ready);
        let _ = s.frame(0.0);
        s
    }

    #[test]
    fn the_fresh_season_of_an_episode_moves_the_page_unless_the_reader_chose_one() {
        let mut s = demo();
        let seasons = s.vm().seasons();
        let other = seasons
            .seasons
            .iter()
            .find(|r| Some(&r.id) != seasons.selected.as_ref())
            .expect("the demo series has a second season")
            .clone();
        let series = s.vm().button().id.clone();
        // A fresh season of another series is ignored.
        s.apply_fresh_season("another-series", Some(other.id.clone()), other.number);
        let _ = s.frame(16.0);
        assert_ne!(
            s.vm().seasons().selected.as_deref(),
            Some(other.id.as_str())
        );
        // The page's own series moves to it, by id.
        s.apply_fresh_season(&series, Some(other.id.clone()), None);
        let _ = s.frame(32.0);
        assert_eq!(
            s.vm().seasons().selected.as_deref(),
            Some(other.id.as_str())
        );
    }

    #[test]
    fn a_season_the_reader_picked_stays_when_the_fresh_one_arrives() {
        let mut s = demo();
        s.picked_season = true;
        let before = s.vm().seasons().selected.clone();
        let series = s.vm().button().id.clone();
        let other = s
            .vm()
            .seasons()
            .seasons
            .iter()
            .find(|r| Some(&r.id) != before.as_ref())
            .map(|r| r.id.clone());
        s.apply_fresh_season(&series, other, None);
        let _ = s.frame(16.0);
        assert_eq!(s.vm().seasons().selected, before);
    }

    #[test]
    fn the_short_episode_menu_has_two_rows_and_names_the_watched_switch_by_state() {
        let unseen = short_episode_menu("e1", false);
        let seen = short_episode_menu("e1", true);
        assert_eq!(unseen.len(), 2);
        let texts = |m: &[popover::MenuEntry]| -> Vec<String> {
            m.iter()
                .filter_map(|e| match e {
                    popover::MenuEntry::Item(i) => Some(i.label.clone()),
                    _ => None,
                })
                .collect()
        };
        assert_eq!(texts(&unseen), ["Abspielen", "Als gesehen markieren"]);
        assert_eq!(texts(&seen), ["Abspielen", "Als ungesehen markieren"]);
    }
}
