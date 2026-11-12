//! The Series screen of the shared Rust UI: head like the Detail screen, then the page tabs (the first one is the season
//! picker), the episode list with progress and watched state, cast, similar and extras. Drawn from `SeriesVm` parts
//! for `touch`, `desktop` and `tv`. Differences from the Swift `SeriesView` are noted in the code.

use crate::detail_screen::{
    Art, HERO_DESKTOP, Head, Kit, Pushed, UiState, body_touch, cast_rail, fill_frame, ground, hero,
    hero_buttons, ins, look, menu_key, mood_strips, poster_tile, resume_info, rgba, sheet,
    status_card, tile_rail, top_bar, txt, txt_center, weight, wide,
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
    EpisodeRow, EpisodesPart, EpisodesStatus, MorePart, SeasonsPart, SeriesButtonPart,
    SeriesIntent, SeriesVm,
};

#[derive(Clone, PartialEq)]
struct Data {
    head: Head,
    seasons: Arc<SeasonsPart>,
    episodes: Arc<EpisodesPart>,
    more: Arc<MorePart>,
}

fn head_of(b: &SeriesButtonPart) -> Head {
    Head {
        id: b.id.clone(),
        image: b.image.clone(),
        title: b.title.clone(),
        secondary: b.secondary_line.clone(),
        overview: b.overview.clone(),
        directors: Vec::new(),
        label: b.label.clone(),
        enabled: b.enabled,
        remaining: b.remaining.clone(),
        progress: b.progress,
        watched: b.watched,
        favorite: b.favorite,
        fav_caption: b.favorite_caption.clone(),
        download: None,
        proof: None,
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
        let text = Node::vstack(Align::Start, Some(5.0), lines).frame(
            Some(820.0 - 20.0 - w - 16.0),
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
        return Node::hstack(Align::Start, Some(16.0), vec![still, text])
            .padding(ins(10.0, 10.0, 10.0, 10.0))
            .frame(Some(820.0), Some(110.0), Alignment::TOP_LEADING)
            .key(key)
            .on_tap(Action::from(format!("episode:{}", e.id).as_str()))
            .on_secondary(Action::from(format!("epmenu:{}", e.id).as_str()))
            .hover_surface(color(colour::GROUPS_AREA), 12.0)
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
            "Keine Folgen",
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
            // `DisturbHint`: 200 high, the retry in accent 15 / 500.
            let col = Node::vstack(
                Align::Center,
                Some(8.0),
                vec![
                    k.icons
                        .node("hard-drive-x", 30.0, true, color(colour::FONT_QUIET)),
                    txt_center(
                        k.cx,
                        "Server ist abgetaucht",
                        weight(lk.body, 15.0, 600),
                        colour::FONT,
                        1,
                    ),
                    txt_center(
                        k.cx,
                        "Die Folgen kommen gerade nicht an.",
                        weight(lk.small, 13.0, 400),
                        colour::FONT_QUIET,
                        2,
                    )
                    .frame(Some(262.0), None, Alignment::CENTER),
                    txt_center(
                        k.cx,
                        "Erneut versuchen",
                        weight(lk.body, 15.0, 500),
                        colour::MARK_ACCENT,
                        1,
                    )
                    .key("retry")
                    .on_tap(Action::from("retry-episodes")),
                ],
            );
            col.frame(Some(820.0), Some(200.0), Alignment::CENTER)
                .padding(ins(0.0, lk.edge, 0.0, 0.0))
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
                    // The list is shifted by -10 so the stills meet the page edge; rows are 6 apart; no "more" button.
                    return Node::vstack(Align::Start, Some(6.0), rows).padding(ins(
                        0.0,
                        lk.edge - 10.0,
                        0.0,
                        0.0,
                    ));
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
            let c = if on { colour::FONT } else { colour::FONT_QUIET };
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
                if lk.form == Form::Desktop {
                    txt(
                        cx,
                        "Keine Besetzung hinterlegt.",
                        weight(lk.body, 15.0, 400),
                        colour::FONT_VERY_QUIET,
                        Some(1),
                    )
                    .padding(ins(0.0, lk.edge, 0.0, 0.0))
                } else {
                    Node::fixed(0.0, 0.0)
                }
            } else {
                cast_rail(&k, &d.more.cast)
            }
        }
        3 if !d.more.extras.is_empty() => tile_rail(&k, "extras", "Extras", &d.more.extras, true),
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
            if d.more.similar.is_empty() && lk.form == Form::Desktop && !d.more.similar_failed {
                txt(
                    cx,
                    "Nichts Ähnliches gefunden",
                    weight(lk.body, 15.0, 400),
                    colour::FONT_VERY_QUIET,
                    Some(1),
                )
                .padding(ins(0.0, lk.edge, 0.0, 0.0))
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
            let name = d
                .seasons
                .seasons
                .iter()
                .find(|s| Some(&s.id) == d.seasons.selected.as_ref())
                .map_or("Staffel".to_owned(), |s| s.name.clone());
            page = page.overlay(
                sheet(
                    &k,
                    &h.title,
                    &[(format!("{name} als gesehen markieren"), false)],
                    "menu",
                ),
                Alignment::CENTER,
            );
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
    message_since: Option<f64>,
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
        let data = Self::data(&vm);
        let host = Pushed::new(env, cx, data, art, bare, move |d, sx, env, cx| {
            page(d, sx, env, cx, &art2, &icons)
        });
        let mut s = SeriesScreen {
            host,
            vm,
            log: Vec::new(),
            play_req: None,
            download_req: None,
            message_since: None,
        };
        s.refresh();
        s
    }

    fn data(vm: &SeriesVm<AppTransport>) -> Data {
        Data {
            head: head_of(&vm.button()),
            seasons: vm.seasons(),
            episodes: vm.episodes(),
            more: vm.more(),
        }
    }

    fn refresh(&mut self) {
        let d = Self::data(&self.vm);
        self.host.set_data(d);
        self.host.sync();
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

    /// Back: pops the page.
    pub fn back(&mut self, now: f64) -> bool {
        self.host.pop(now)
    }

    /// The "Laden" request of the last press, once: the rect of the button the season sheet hangs under (`None` when
    /// the page has not been laid out). The host builds a `LoadRequest::Season` for the series.
    pub fn take_download(&mut self) -> Option<Option<swiftly_layout::Rect>> {
        self.download_req.take()
    }

    /// The play request of the last press, once.
    pub fn take_play(&mut self) -> Option<crate::live_play::PlayRequest> {
        self.play_req.take()
    }

    fn drain(&mut self, now: f64) {
        for a in self.host.drain(now) {
            let is = |s: &str| a == Action::from(s);
            let desktop = self.host.ui().env().idiom == swiftly_ui::Idiom::Desktop;
            let ep_menu = self
                .vm
                .episodes()
                .rows
                .iter()
                .find(|e| is(&format!("epmenu:{}", e.id)))
                .cloned();
            if a == popover::DISMISS {
                self.host.sx.menu.close();
            } else if let Some(e) = ep_menu {
                // Right click on an episode: the tile menu of an episode (play, watched).
                let items = vec![
                    popover::MenuEntry::Item(MenuItem::new(
                        Action::from(format!("episode:{}", e.id).as_str()),
                        "Abspielen",
                    )),
                    popover::MenuEntry::Item(MenuItem::new(
                        Action::from(format!("epwatched:{}", e.id).as_str()),
                        if e.watched {
                            "Als ungesehen markieren"
                        } else {
                            "Als gesehen markieren"
                        },
                    )),
                ];
                let p = self.host.pointer;
                self.host.sx.menu.open(
                    items,
                    Anchor::Pointer(swiftly_layout::Point::new(p.0, p.1)),
                    swiftly_ui::feel::DROPDOWN_WIDTH,
                    false,
                );
            } else if desktop && is("more") {
                let rect = self
                    .host
                    .ui()
                    .frame_of("more")
                    .map_or(swiftly_layout::Rect::new(0.0, 0.0, 48.0, 56.0), |f| {
                        swiftly_layout::Rect::new(f[0], f[1], f[2], f[3])
                    });
                let seasons = self.vm.seasons();
                let name = seasons
                    .seasons
                    .iter()
                    .find(|s| Some(&s.id) == seasons.selected.as_ref())
                    .map_or("Staffel".to_owned(), |s| s.name.clone());
                let items = vec![
                    popover::MenuEntry::Item(MenuItem::new(Action::from("download"), "Laden")),
                    popover::MenuEntry::Item(MenuItem::new(
                        Action::from("menu:0"),
                        format!("{name} als gesehen markieren"),
                    )),
                ];
                self.host
                    .sx
                    .menu
                    .open(items, Anchor::Button(rect), 260.0, false);
            } else if is("play") {
                let a = self.vm.play_next(None);
                self.play_req = crate::live_play::request_of(&a);
                self.log.push(format!("play {a:?}"));
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
            } else if is("menu:0") {
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
                for e in &self.vm.episodes().rows {
                    if is(&format!("epwatched:{}", e.id)) {
                        self.host.sx.menu.close();
                        self.vm.send(SeriesIntent::SetEpisodeWatched {
                            id: e.id.clone(),
                            on: !e.watched,
                        });
                    }
                }
                let seasons = self.vm.seasons();
                for (i, s) in seasons.seasons.iter().enumerate() {
                    if is(&format!("season:{i}")) {
                        self.host.sx.sheet = 0;
                        self.host.sx.menu.close();
                        self.vm
                            .send(SeriesIntent::SelectSeason { id: s.id.clone() });
                    }
                }
                for e in &self.vm.episodes().rows {
                    if is(&format!("episode:{}", e.id)) {
                        self.host.sx.menu.close();
                        let a = self.vm.play_episode(&e.id, None);
                        self.play_req = crate::live_play::request_of(&a);
                        self.log.push(format!("play {a:?}"));
                    }
                }
            }
        }
        self.refresh();
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
