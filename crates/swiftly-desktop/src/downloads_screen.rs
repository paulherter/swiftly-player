//! The Downloads page of the shared Rust UI, drawn from `DownloadsVm` parts after `Sources/macOS/MacDownloads.swift`:
//! "Lädt gerade" rows with the progress ring and a 10 Hz estimate, the finished titles grouped by series, edit mode
//! (check circles, trash beside the pencil), the series page with its hero and the context menu of an episode row.
//! Differences from the Swift screens are noted in the code.

use crate::browse;
use crate::forms::{self, Fm};
use crate::home::{Form, ins, rgba, text};
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use swiftly_design::tokens::{colour, touch};
use swiftly_downloads::{
    Art, DownloadItem, DownloadManagerState, DownloadRules, DownloadState, DownloadTransport,
    Effect, Intent, ProgressEstimator, RunningTransfer, TaskParts,
};
use swiftly_l10n::Locale;
use swiftly_layout::{Align, Alignment, Point, Rect};
use swiftly_ui::a11y::{A11yNode, Role};
use swiftly_ui::components::color;
use swiftly_ui::icons::Icons;
use swiftly_ui::popover::{self, Anchor, MenuController, MenuEntry, MenuItem, MenuOutcome};
use swiftly_ui::{Action, Cx, Env, ImageId, Motion, Node, Paint, PressStyle, Ui, UiEvent, feel};
use swiftly_vm::{
    DownloadRow, DownloadServices, DownloadsIntent, DownloadsVm, ItemRow, ListPart, RowState,
    StoragePart,
};

pub use crate::load_sheets::LoadRequest;
use crate::load_sheets::{AddSheet, SeasonSheet, Sheet};

#[path = "downloads_widgets.rs"]
mod widgets;
use widgets::st;

/// The open sheet as the view reads it; the revision tells the view when it changed.
#[derive(Clone)]
struct SheetPart {
    rev: u64,
    data: Arc<Sheet>,
}

impl PartialEq for SheetPart {
    fn eq(&self, other: &SheetPart) -> bool {
        self.rev == other.rev
    }
}

/// How far the check circle of edit mode slides in from the leading edge: its own width and the gap.
const CHECK_SLIDE: f32 = 28.0;

/// The demo transport: records nothing, runs nothing.
#[derive(Default)]
pub struct Quiet(Mutex<Vec<String>>);
impl DownloadTransport for Quiet {
    fn start(&self, parts: &TaskParts, _: &str, _: Option<&[u8]>) {
        self.0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(parts.description());
    }
    fn cancel(&self, _: &str, _: Option<i64>, _: i64, _: bool) {}
    fn resume(&self, _: &str) {}
    fn running(&self) -> Vec<RunningTransfer> {
        Vec::new()
    }
}
impl DownloadServices for Quiet {
    fn run(&self, _: &Effect) {}
}

/// Any transport behind the page: the demo's `Quiet` or the real file downloads.
pub struct Dyn(pub Arc<dyn DownloadTransport>);
impl DownloadTransport for Dyn {
    fn start(&self, parts: &TaskParts, address: &str, resume: Option<&[u8]>) {
        self.0.start(parts, address, resume);
    }
    fn cancel(
        &self,
        id: &str,
        task_generation: Option<i64>,
        new_generation: i64,
        want_resume_data: bool,
    ) {
        self.0
            .cancel(id, task_generation, new_generation, want_resume_data);
    }
    fn resume(&self, id: &str) {
        self.0.resume(id);
    }
    fn running(&self) -> Vec<RunningTransfer> {
        self.0.running()
    }
}

/// What the page shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scenario {
    /// Two running, three finished (one series with three episodes).
    Mixed,
    /// Nothing stored.
    Empty,
    /// One title in every state: loading, waiting, paused, failed, done.
    States,
    /// The sample rows of the SwiftUI parity check (`ParitySnapshots.testDownloadsFilled`): one loading, one waiting,
    /// one failed, a series of eight finished episodes (1080p) and one finished film. Same ids, titles, sizes and states
    /// as the Swift fixture there, so both sides draw the same rows.
    Parity,
    /// Worst case (`break-ui`): 400 stored titles with the longest realistic, right-to-left, CJK and emoji names, one
    /// series with 400 episodes, sizes up to 90 GB.
    Worst,
}

fn film(
    id: &str,
    title: &str,
    bytes: i64,
    state: DownloadState,
    loaded: i64,
    at: f64,
) -> DownloadItem {
    let mut i = DownloadItem::new(id, "u1", Art::Film, title, bytes, at);
    i.state = state;
    i.loaded = loaded;
    i
}

fn episode(n: i64, state: DownloadState, loaded: i64) -> DownloadItem {
    let mut i = DownloadItem::new(
        format!("e{n}"),
        "u1",
        Art::Episode,
        format!("Folge {n}"),
        900_000_000,
        20.0 + n as f64,
    );
    i.series = Some("Die Nachbarn".into());
    i.series_identifier = Some("s1".into());
    i.season = Some(1);
    i.episode = Some(n);
    i.state = state;
    i.loaded = loaded;
    i
}

fn items(s: Scenario) -> Vec<DownloadItem> {
    match s {
        Scenario::Empty => Vec::new(),
        Scenario::States => vec![
            film(
                "a1",
                "Der lange Weg",
                2_400_000_000,
                DownloadState::Loads,
                1_080_000_000,
                10.0,
            ),
            film(
                "a2",
                "Nachts im Zug",
                1_500_000_000,
                DownloadState::Waits,
                0,
                11.0,
            ),
            film(
                "a3",
                "Stille Wasser",
                1_800_000_000,
                DownloadState::Halted,
                600_000_000,
                12.0,
            ),
            film(
                "a4",
                "Kaputte Kopie",
                900_000_000,
                DownloadState::Error,
                0,
                13.0,
            ),
            film(
                "a5",
                "Das letzte Licht",
                1_200_000_000,
                DownloadState::Done,
                1_200_000_000,
                14.0,
            ),
        ],
        Scenario::Parity => {
            let mut v = vec![
                film(
                    "p1",
                    "Der lange Weg",
                    3_400_000_000,
                    DownloadState::Loads,
                    1_200_000_000,
                    10.0,
                ),
                film(
                    "p2",
                    "Nachts im Zug",
                    1_500_000_000,
                    DownloadState::Waits,
                    0,
                    11.0,
                ),
                film(
                    "p3",
                    "Kaputte Kopie",
                    900_000_000,
                    DownloadState::Error,
                    0,
                    12.0,
                ),
            ];
            for n in 1..=8 {
                let mut e = episode(n, DownloadState::Done, 700_000_000);
                e.bytes = 700_000_000;
                e.quality = Some(swiftly_downloads::DownloadQuality::Hd1080);
                v.push(e);
            }
            let mut done = film(
                "p4",
                "Stille Wasser",
                1_800_000_000,
                DownloadState::Done,
                1_800_000_000,
                40.0,
            );
            done.container = Some("mkv".into());
            v.push(done);
            v
        }
        Scenario::Worst => {
            let mut v: Vec<DownloadItem> = (0..400)
                .map(|n| {
                    let state = match n % 5 {
                        0 => DownloadState::Loads,
                        1 => DownloadState::Waits,
                        2 => DownloadState::Halted,
                        3 => DownloadState::Error,
                        _ => DownloadState::Done,
                    };
                    let bytes = if n % 7 == 0 {
                        90_000_000_000
                    } else {
                        1_500_000_000 + n as i64
                    };
                    film(
                        &format!("w{n}"),
                        crate::browse::worst_title(n),
                        bytes,
                        state,
                        bytes / 3,
                        10.0 + n as f64,
                    )
                })
                .collect();
            for n in 1..=400 {
                let mut e = episode(n, DownloadState::Done, 900_000_000);
                e.series = Some(crate::browse::worst_title(0).into());
                v.push(e);
            }
            v
        }
        Scenario::Mixed => vec![
            film(
                "f1",
                "Der lange Weg",
                2_400_000_000,
                DownloadState::Loads,
                1_080_000_000,
                10.0,
            ),
            episode(4, DownloadState::Halted, 300_000_000),
            film(
                "f2",
                "Stille Wasser",
                1_800_000_000,
                DownloadState::Done,
                1_800_000_000,
                11.0,
            ),
            episode(1, DownloadState::Done, 900_000_000),
            episode(2, DownloadState::Done, 900_000_000),
            episode(3, DownloadState::Done, 900_000_000),
        ],
    }
}

#[derive(Clone, PartialEq)]
struct Parts {
    list: Arc<ListPart>,
    storage: Arc<StoragePart>,
    /// The stored titles with everything the sub lines read (container, quality, runtime).
    items: Arc<Vec<DownloadItem>>,
    /// The estimated byte count of every loading or paused title, refreshed at 10 Hz.
    shown: Vec<(String, i64)>,
    edit: bool,
    selected: Vec<String>,
    /// The series page (`DownloadSeriesView`) that is pushed, by group id.
    series: Option<String>,
    /// The title whose ring the pointer is over.
    hover: Option<String>,
    /// The context menu of a series episode row.
    menu: MenuController,
    /// The add popover or the season sheet.
    sheet: Option<SheetPart>,
    /// The first frame is over: rings that appear from now on play the reveal.
    settled: bool,
    /// Only the sheet draws: the page it floats over is the title page the sheet was opened from.
    sheet_only: bool,
}

struct Ctx {
    icons: Icons,
    /// The generated pictures of the demo list; empty over real downloads.
    posters: Vec<ImageId>,
    /// The folder the engine saved the covers in (`MacDownloads.imageAddress`: disk first); `None` in the demo.
    covers: Option<std::path::PathBuf>,
    /// Covers read from disk so far, by file name (`None`: no such file).
    loaded: std::cell::RefCell<HashMap<String, Option<ImageId>>>,
}

/// The longest edge a cover is decoded to (the row picture at 3x).
const COVER_EDGE: u32 = 480;

impl Ctx {
    /// The saved cover of `id` (`account`'s download folder), as the Mac shows it. Over real downloads a title without a
    /// file gets no picture (the caller draws the ground and the symbol); only the demo list uses generated art.
    fn picture(&self, cx: &Cx, account: &str, id: &str) -> Option<ImageId> {
        let Some(dir) = &self.covers else {
            let h = id.bytes().fold(7_usize, |a, b| {
                a.wrapping_mul(31).wrapping_add(usize::from(b))
            });
            return self.posters.get(h % self.posters.len().max(1)).copied();
        };
        let name = DownloadItem::image_name(account, id);
        if let Some(known) = self.loaded.borrow().get(&name) {
            return *known;
        }
        let read = std::fs::read(dir.join(&name))
            .ok()
            .and_then(|b| swiftly_images::decode::decode(&b, COVER_EDGE).ok())
            .and_then(|d| cx.add_image(d.width, d.height, &d.rgba));
        // A file that is not there yet stays unknown, so the next frame looks again.
        if read.is_some() || dir.join(&name).exists() {
            self.loaded.borrow_mut().insert(name, read);
        }
        read
    }
}

/// Everything one row needs.
struct Line {
    key: String,
    ring_key: Option<String>,
    hover_key: String,
    title: String,
    sub: String,
    state: RowState,
    /// A single title that was watched: the picture is dimmed and carries the check (`watchedCheckmark`).
    watched: bool,
    share: Option<f32>,
    picked: Option<bool>,
    group: bool,
    landscape: bool,
    /// The id for the context menu (series page episode rows only).
    menu_id: Option<String>,
    hovered: bool,
    picture: Option<String>,
    /// The account of the download (the cover's file name).
    account: String,
    /// Play the reveal when the ring changes state.
    reveal: bool,
}

/// The width of the content column.
fn col_w(env: &Env, f: &Fm) -> f32 {
    if f.form == Form::Desktop {
        (900.0 + 72.0_f32).min(env.size.w) - 72.0
    } else {
        env.size.w.min(f.col + 2.0 * f.edge) - 2.0 * f.edge
    }
}

/// `MacDownloadRow`: image, two lines and the thin bar in a button, the ring beside it (a button of its own); spacing 16,
/// padding 12 / 10; in edit mode the check circle comes in first and the row takes the area colour on hover.
fn line(cx: &Cx, ctx: &Ctx, f: &Fm, env: &Env, l: &Line) -> Node {
    let icons = &ctx.icons;
    let (iw, ih) = if l.landscape {
        (142.0, 80.0)
    } else {
        (76.0, 114.0)
    };
    let edit_w = if l.picked.is_some() { 18.0 + 16.0 } else { 0.0 };
    let text_w = (col_w(env, f) - 20.0 - edit_w - iw - 16.0 - 16.0 - 36.0).max(80.0);
    let sub_colour = match l.state {
        RowState::Loading => colour::MARK_ACCENT,
        RowState::Failed => colour::ORIGINAL_WARNING,
        _ => colour::FONT_QUIET,
    };
    let sub_style = swiftly_text::TextStyle::from(st(12.0, 400)).with_tabular();
    let mut col = vec![
        text(
            cx,
            &l.title,
            st(15.0, 600),
            colour::FONT,
            Some(1),
            swiftly_text::Align::Start,
        ),
        Node::text(
            cx,
            &l.sub,
            &sub_style,
            color(sub_colour),
            Some(1),
            swiftly_text::Align::Start,
        ),
    ];
    if let (Some(s), RowState::Loading | RowState::Paused) = (l.share, l.state) {
        col.push(widgets::bar(s, text_w).padding(ins(4.0, 0.0, 0.0, 0.0)));
    }
    let mut inner = Vec::new();
    if let Some(on) = l.picked {
        let check = icons
            .node(
                if on { "check-circle.fill" } else { "circle" },
                18.0,
                !on,
                color(if on {
                    colour::MARK_ACCENT
                } else {
                    colour::FONT_VERY_QUIET
                }),
            )
            .a11y_hidden();
        // The circle comes in from the leading edge (`.move(edge: .leading)` + opacity, leap) and goes the same way.
        inner.push(
            check
                .key(format!("check:{}", l.key).as_str())
                .appear_offset(-CHECK_SLIDE, 0.0)
                .exit_offset(-CHECK_SLIDE, 0.0)
                .appear_from(1.0, 0.0)
                .exit_to(1.0, 0.0)
                .opacity(1.0, feel::leap()),
        );
    }
    let pic = match ctx.picture(cx, &l.account, l.picture.as_deref().unwrap_or(&l.key)) {
        Some(id) => Node::image(id, iw, ih, touch::CORNER_TILE),
        // `Theme.area` and the symbol of `tileCharacter`: a series and an episode are "tv", a film "film".
        None => icons
            .node(
                if l.landscape || l.group {
                    "television"
                } else {
                    "film-strip"
                },
                22.0,
                true,
                color(colour::FONT),
            )
            .frame(Some(iw), Some(ih), Alignment::CENTER)
            .background(
                Node::rect(color(colour::AREA), touch::CORNER_TILE),
                Alignment::CENTER,
            ),
    };
    let pic = if l.watched {
        // `watchedCheckmark(border: 20, spacing: 6)`: the still darker (multiplied by 0.6), a 20 pt disc in the page colour
        // at 78 % with the check, 6 pt from the top right corner.
        let dim = Node::rect(
            swiftly_render::Color::new(0.0, 0.0, 0.0, 0.4),
            touch::CORNER_TILE,
        );
        let check = icons
            .node("check", 11.0, true, color(colour::FONT))
            .frame(Some(20.0), Some(20.0), Alignment::CENTER)
            .background(
                Node::rect(rgba(colour::REASON, 0.78), 10.0),
                Alignment::CENTER,
            )
            .padding(ins(6.0, 6.0, 0.0, 0.0));
        pic.overlay(dim, Alignment::CENTER)
            .overlay(check, Alignment::TOP_TRAILING)
    } else {
        pic
    };
    inner.push(pic.paint(Paint::Stroke {
        color: color(colour::TILE_BORDER),
        width: 1.0,
        radius: touch::CORNER_TILE,
    }));
    inner.push(Node::vstack(Align::Start, Some(4.0), col).frame(
        Some(text_w),
        None,
        Alignment::LEADING,
    ));
    inner.push(Node::spacer());
    // Playing, unfolding and selecting hang on one button; the ring beside it is a button itself.
    let mut main = forms::tappable(
        browse::wide(
            Node::hstack(Align::Center, Some(16.0), inner),
            Alignment::LEADING,
        ),
        f,
        &l.key,
        10.0,
    )
    .press_style(PressStyle::Text);
    if f.form == Form::Desktop {
        // `Dim`: the press dims the content to 0.6 (`PressStyle::Text`); keyboard focus (Tab, then Return) fills the row with
        // `hoverArea` at radius 10 and nothing shows on hover.
        main = main
            .focusable(swiftly_ui::components::focus_id(l.key.as_str()), None)
            .focus_fill(
                swiftly_render::Color::new(1.0, 1.0, 1.0, feel::HOVER_SURFACE_ALPHA),
                feel::HOVER_SURFACE_RADIUS,
            );
    }
    let main = main.a11y(
        A11yNode::new("", Role::Button, l.title.clone())
            .with_value(l.sub.clone())
            .with_selected(l.picked == Some(true)),
    );
    let mut parts = vec![main];
    if l.group {
        parts.push(
            icons
                .node("caret-right", 13.0, true, color(colour::FONT_VERY_QUIET))
                .frame(Some(36.0), None, Alignment::CENTER)
                .a11y_hidden(),
        );
    } else if let Some(k) = &l.ring_key {
        parts.push(widgets::ring(
            cx,
            icons,
            f,
            Some(l.state),
            l.share.unwrap_or(0.0),
            l.hovered,
            k,
            &l.hover_key,
            l.reveal,
        ));
    }
    let mut row =
        Node::hstack(Align::Center, Some(16.0), parts).padding(ins(12.0, 10.0, 12.0, 10.0));
    if l.picked.is_some() {
        row = row.hover_surface(color(colour::AREA), 12.0);
    }
    if let Some(id) = &l.menu_id {
        row = row.on_secondary(Action::from(format!("ctx:{id}").as_str()));
    }
    browse::wide(row, Alignment::LEADING)
}

/// The state a title's ring shows: the one the list already put the row under (`ItemRow.state`), so a finished video
/// whose subtitles are still on their way stays "loading" in its ring as well as in its section, instead of the ring
/// saying "on this PC" while the row still sits under "Lädt gerade". The stored item's own state is the fallback.
fn ring_state(rows: &[DownloadRow], d: &DownloadItem) -> RowState {
    rows.iter()
        .flat_map(|r| r.items.iter())
        .find(|i| i.id == d.id)
        .map_or_else(|| RowState::from(d.state), |i| i.state)
}

/// The line of a stored title, with the estimated progress.
fn item_line(p: &Parts, d: &DownloadItem, pick: Option<bool>, menu: bool) -> Line {
    let loaded = p
        .shown
        .iter()
        .find(|s| s.0 == d.id)
        .map_or(d.loaded, |s| s.1);
    let share = if d.bytes > 0 {
        Some((loaded as f32 / d.bytes as f32).clamp(0.0, 1.0))
    } else {
        d.share().map(|s| s as f32)
    };
    let state = ring_state(&p.list.rows, d);
    Line {
        key: format!("row:{}", d.id),
        ring_key: Some(format!("ring:{}", d.id)),
        hover_key: format!("hv:{}", d.id),
        title: d.title.clone(),
        sub: widgets::subline(d, loaded),
        state,
        watched: d.watched,
        share,
        picked: pick,
        group: false,
        landscape: d.art == Art::Episode,
        menu_id: menu.then(|| d.id.clone()),
        hovered: p.hover.as_deref() == Some(d.id.as_str()),
        picture: Some(d.id.clone()),
        account: d.account.clone(),
        reveal: p.settled,
    }
}

/// The 1 px hairline between two rows (`Theme.line`).
fn hairline() -> Node {
    browse::wide(
        Node::rect(color(colour::LINE), 0.0).frame(None, Some(1.0), Alignment::CENTER),
        Alignment::CENTER,
    )
}

fn heading(cx: &Cx, s: &str) -> Node {
    browse::wide(
        text(
            cx,
            s,
            st(20.0, 600),
            colour::FONT,
            Some(1),
            swiftly_text::Align::Start,
        )
        .padding(ins(26.0, 0.0, 10.0, 0.0)),
        Alignment::LEADING,
    )
}

fn empty_state(cx: &Cx, ctx: &Ctx) -> Node {
    let icons = &ctx.icons;
    let disc = icons
        .node(
            "arrow-circle-down",
            touch::EMPTY_SYMBOL,
            true,
            color(colour::FONT),
        )
        .frame(
            Some(touch::EMPTY_DISC),
            Some(touch::EMPTY_DISC),
            Alignment::CENTER,
        )
        .background(
            Node::rect(color(colour::AREA), touch::EMPTY_DISC / 2.0),
            Alignment::CENTER,
        );
    browse::wide(
        Node::vstack(
            Align::Center,
            Some(8.0),
            vec![
                disc.padding(ins(0.0, 0.0, 16.0, 0.0)),
                text(
                    cx,
                    "Noch nichts geladen",
                    st(20.0, 600),
                    colour::FONT,
                    Some(1),
                    swiftly_text::Align::Center,
                ),
                text(
                    cx,
                    "Lad was runter, bevor der Zug ins Funkloch f\u{00E4}hrt.",
                    st(15.0, 400),
                    colour::FONT_QUIET,
                    Some(3),
                    swiftly_text::Align::Center,
                )
                .frame(Some(touch::EMPTY_TEXT_WIDTH), None, Alignment::CENTER),
            ],
        )
        .padding(ins(110.0, 0.0, 0.0, 0.0)),
        Alignment::CENTER,
    )
}

/// The Mac's empty state (`EmptyState` in `MacComponents.swift`): a 78 pt disc with a 44 pt symbol, 22, the headline,
/// 7, the text at most 262 wide. It is centred in the whole content area, not in the page body.
fn mac_empty_state(cx: &Cx, ctx: &Ctx) -> Node {
    let disc = ctx
        .icons
        .node("arrow-circle-down", 44.0, true, color(colour::FONT_QUIET))
        .frame(Some(78.0), Some(78.0), Alignment::CENTER)
        .background(Node::rect(color(colour::AREA), 39.0), Alignment::CENTER);
    let block = Node::vstack(
        Align::Center,
        Some(0.0),
        vec![
            disc.padding(ins(0.0, 0.0, 22.0, 0.0)),
            text(
                cx,
                "Noch nichts geladen",
                st(20.0, 600),
                colour::FONT,
                Some(1),
                swiftly_text::Align::Center,
            )
            .padding(ins(0.0, 0.0, 7.0, 0.0)),
            text(
                cx,
                "Lad was runter, bevor der Zug ins Funkloch f\u{00E4}hrt.",
                st(15.0, 400),
                colour::FONT_QUIET,
                Some(3),
                swiftly_text::Align::Center,
            )
            .frame(Some(262.0), None, Alignment::CENTER),
        ],
    );
    crate::home::fill_frame(block, Alignment::CENTER)
}

/// Rows of one section with a hairline after each but the last.
fn with_lines(rows: Vec<Node>) -> Vec<Node> {
    let n = rows.len();
    rows.into_iter()
        .enumerate()
        .flat_map(|(i, r)| {
            if i + 1 < n {
                vec![r, hairline()]
            } else {
                vec![r]
            }
        })
        .collect()
}

fn body(cx: &Cx, env: &Env, f: &Fm, p: &Parts, ctx: &Ctx) -> Vec<Node> {
    if p.list.rows.is_empty() {
        return vec![empty_state(cx, ctx)];
    }
    let mut out = Vec::new();
    let s = &p.storage;
    let find = |id: &str| p.items.iter().find(|d| d.id == id);
    let pick = |ids: &[&str]| {
        p.edit
            .then(|| ids.iter().all(|i| p.selected.iter().any(|s| s == i)))
    };
    // "Ongoing" is everything that is not done; the done ones are grouped by series.
    let running: Vec<&DownloadItem> = p
        .list
        .rows
        .iter()
        .flat_map(|r| r.items.iter())
        .filter(|i| i.state != RowState::Done)
        .filter_map(|i| find(&i.id))
        .collect();
    if !running.is_empty() {
        out.push(heading(
            cx,
            if s.offline {
                "Wartet auf Netz"
            } else {
                "L\u{00E4}dt gerade"
            },
        ));
        out.extend(with_lines(
            running
                .iter()
                .map(|d| {
                    line(
                        cx,
                        ctx,
                        f,
                        env,
                        &item_line(p, d, pick(&[d.id.as_str()]), false),
                    )
                })
                .collect(),
        ));
    }
    let mut done_rows = Vec::new();
    for r in &p.list.rows {
        let done: Vec<&DownloadItem> = r
            .items
            .iter()
            .filter(|i| i.state == RowState::Done)
            .filter_map(|i| find(&i.id))
            .collect();
        if done.is_empty() {
            continue;
        }
        // `DownloadRules.grouped` decides (`MacDownloads.swift`): episodes of one series group, even a single finished one.
        let owned: Vec<DownloadItem> = done.iter().map(|d| (*d).clone()).collect();
        if matches!(
            DownloadRules::grouped(&owned).as_slice(),
            [swiftly_downloads::DownloadGroup::Series { .. }]
        ) {
            let ids: Vec<&str> = done.iter().map(|d| d.id.as_str()).collect();
            done_rows.push(line(
                cx,
                ctx,
                f,
                env,
                &Line {
                    key: format!("grp:{}", r.id),
                    ring_key: None,
                    hover_key: String::new(),
                    title: r.title.clone(),
                    sub: widgets::group_subline(&done),
                    state: RowState::Done,
                    watched: false,
                    share: None,
                    picked: pick(&ids),
                    group: true,
                    landscape: false,
                    menu_id: None,
                    hovered: false,
                    picture: Some(r.id.strip_prefix("serie-").unwrap_or(&r.id).to_owned()),
                    account: done.first().map(|d| d.account.clone()).unwrap_or_default(),
                    reveal: false,
                },
            ));
        } else {
            for d in done {
                done_rows.push(line(
                    cx,
                    ctx,
                    f,
                    env,
                    &item_line(p, d, pick(&[d.id.as_str()]), false),
                ));
            }
        }
    }
    if !done_rows.is_empty() {
        // No heading above the finished titles: everything on the page is on this device.
        out.push(Node::fixed(
            0.0,
            if running.is_empty() { 4.0 } else { 26.0 },
        ));
        out.extend(with_lines(done_rows));
    }
    out
}

/// The episodes of one series by season ("Staffel N"), each row with its own still and the context menu.
fn series_body(cx: &Cx, env: &Env, f: &Fm, p: &Parts, ctx: &Ctx, id: &str) -> Vec<Node> {
    let mut out = Vec::new();
    let Some(r) = p.list.rows.iter().find(|r| r.id == id) else {
        return out;
    };
    let mut seasons: Vec<Option<i64>> = Vec::new();
    for i in &r.items {
        if !seasons.contains(&i.season) {
            seasons.push(i.season);
        }
    }
    seasons.sort_by_key(|s| s.unwrap_or(i64::MAX));
    for season in seasons {
        if let Some(n) = season {
            let t = swiftly_design::TextStyle {
                tracking: -0.2,
                ..st(22.0, 700)
            };
            out.push(browse::wide(
                text(
                    cx,
                    &format!("Staffel {n}"),
                    t,
                    colour::FONT,
                    Some(1),
                    swiftly_text::Align::Start,
                )
                .padding(ins(26.0, 0.0, 10.0, 0.0)),
                Alignment::LEADING,
            ));
        }
        let mut eps: Vec<&ItemRow> = r.items.iter().filter(|i| i.season == season).collect();
        eps.sort_by_key(|i| i.episode.unwrap_or(i64::MAX));
        let rows: Vec<Node> = eps
            .iter()
            .filter_map(|i| p.items.iter().find(|d| d.id == i.id))
            .map(|d| {
                line(
                    cx,
                    ctx,
                    f,
                    env,
                    &item_line(p, d, p.edit.then(|| p.selected.contains(&d.id)), true),
                )
            })
            .collect();
        out.extend(with_lines(rows));
    }
    out
}

/// The episodes of a series in play order (finished and not).
fn episodes_of<'a>(p: &'a Parts, id: &str) -> Vec<&'a DownloadItem> {
    let Some(r) = p.list.rows.iter().find(|r| r.id == id) else {
        return Vec::new();
    };
    let mut v: Vec<&DownloadItem> = r
        .items
        .iter()
        .filter_map(|i| p.items.iter().find(|d| d.id == i.id))
        .collect();
    v.sort_by_key(|d| (d.season.unwrap_or(0), d.episode.unwrap_or(0)));
    v
}

/// The label of the series button ("Abspielen S2 F6", "Weiter mit ..."): the core's `Item.seriesButton`, as the Mac
/// takes it from `DownloadRules.nextEpisode` and `TitleText`.
fn next_label(next: Option<&DownloadItem>) -> String {
    let Some(next) = next else {
        return "Abspielen".to_owned();
    };
    let list = serde_json::to_string(&[next]).unwrap_or_default();
    let answer = swiftly_vm::download_next_episode(&list, Locale::parse("de"));
    serde_json::from_str::<serde_json::Value>(&answer)
        .ok()
        .and_then(|v| v["knopftext"].as_str().map(str::to_owned))
        .unwrap_or_else(|| "Abspielen".to_owned())
}

/// Pencil / cross and, with a selection, the trash button (`EditButton`, `MacDownloadsPage.header`).
fn buttons(ctx: &Ctx, f: &Fm, p: &Parts, spacing: f32) -> Node {
    let mut v = Vec::new();
    if p.edit && !p.selected.is_empty() {
        v.push(
            widgets::action_button(&ctx.icons, f, "delete", "trash", false, "Entfernen", false)
                .appear_from(1.0, 0.0)
                .exit_to(1.0, 0.0)
                .opacity(1.0, feel::leap()),
        );
    }
    v.push(widgets::action_button(
        &ctx.icons,
        f,
        "edit",
        if p.edit { "x" } else { "pencil-simple.fill" },
        !p.edit,
        if p.edit { "Fertig" } else { "Bearbeiten" },
        p.edit,
    ));
    Node::hstack(Align::Center, Some(spacing), v)
}

/// The fade of a hero edge: `bands` strips of the page colour, opaque at the edge.
fn fade(horizontal: bool, len: f32, bands: usize) -> Node {
    let strips: Vec<Node> = (0..bands)
        .map(|i| {
            let a = 1.0 - i as f32 / bands as f32;
            let r = Node::rect(rgba(colour::REASON, a * a), 0.0);
            if horizontal {
                r.frame(Some(len / bands as f32), None, Alignment::CENTER)
            } else {
                r.frame(None, Some(len / bands as f32), Alignment::CENTER)
            }
        })
        .collect();
    if horizontal {
        Node::hstack(Align::Start, Some(0.0), strips)
    } else {
        Node::vstack(Align::End, Some(0.0), strips.into_iter().rev().collect())
    }
}

/// The header of a series page on the Mac: the picture on the right, name, "N Folgen \u{00B7} size" and the buttons.
fn series_hero(cx: &Cx, env: &Env, f: &Fm, p: &Parts, ctx: &Ctx, id: &str, title: &str) -> Node {
    let hero_h = 350.0;
    let eps = episodes_of(p, id);
    let owned: Vec<DownloadItem> = eps.iter().map(|d| (*d).clone()).collect();
    let next = DownloadRules::next_episode(&owned);
    let backdrop_w = (hero_h * 1.62_f32).min(env.size.w);
    let mut base = browse::wide(
        Node::rect(color(colour::REASON), 0.0).frame(None, Some(hero_h), Alignment::TOP_LEADING),
        Alignment::TOP_LEADING,
    );
    let account = eps.first().map(|d| d.account.as_str()).unwrap_or_default();
    let first = eps.first();
    let sid = first
        .and_then(|d| d.series_identifier.as_deref())
        .unwrap_or_else(|| id.strip_prefix("serie-").unwrap_or(id));
    // The header image of the series, else its poster, else the first episode's own picture (`headerImage`).
    let cover = ctx
        .picture(cx, account, &format!("{sid}-kopf"))
        .or_else(|| ctx.picture(cx, account, sid))
        .or_else(|| first.and_then(|d| ctx.picture(cx, account, &d.id)));
    if let Some(img) = cover {
        let pic = Node::image(img, backdrop_w, hero_h, 0.0).opacity(0.75, Motion::Instant);
        let pic = pic
            .overlay(fade(true, 220.0, 44), Alignment::LEADING)
            .overlay(fade(false, 140.0, 28), Alignment::BOTTOM);
        base = base.overlay(pic, Alignment::TOP_TRAILING);
    }
    let count: Vec<&DownloadItem> = eps.clone();
    let total: i64 = count.iter().map(|d| d.bytes).sum();
    let sub_style = swiftly_text::TextStyle::from(st(12.0, 400)).with_tabular();
    let mut rail = vec![widgets::primary_button(
        cx,
        f,
        "next",
        &next_label(next),
        next.is_some(),
    )];
    rail.push(buttons(ctx, f, p, 12.0));
    // `minimumScaleFactor(0.62)` in a 640 x 42 frame: a long name shrinks to fit, down to 62 %, and only then truncates.
    let t = fitted_title(cx, title, 640.0, 0.62);
    let block = Node::vstack(
        Align::Start,
        Some(0.0),
        vec![
            text(
                cx,
                title,
                t,
                colour::FONT,
                Some(1),
                swiftly_text::Align::Start,
            )
            .frame(Some(640.0), Some(42.0), Alignment::LEADING),
            Node::text(
                cx,
                &format!(
                    "{} \u{00B7} {}",
                    swiftly_l10n::plural("%lld Folgen", count.len() as i64, &[]),
                    DownloadRules::size(total, widgets::SEP)
                ),
                &sub_style,
                color(colour::FONT_QUIET),
                Some(1),
                swiftly_text::Align::Start,
            )
            .padding(ins(12.0, 0.0, 0.0, 0.0)),
            Node::hstack(Align::Center, Some(12.0), rail).padding(ins(22.0, 0.0, 0.0, 0.0)),
        ],
    )
    .padding(ins(52.0 + 98.0, 36.0, 0.0, 0.0));
    let back = forms::tappable(
        ctx.icons
            .node("caret-left", 20.0, true, color(colour::FONT))
            .frame(Some(44.0), Some(44.0), Alignment::CENTER)
            .a11y_label(swiftly_ui::a11y::Role::Button, "Zurück"),
        f,
        "back",
        22.0,
    )
    .padding(ins(10.0, 24.0, 0.0, 0.0));
    base.overlay(block, Alignment::TOP_LEADING)
        .overlay(back, Alignment::TOP_LEADING)
}

/// The hero title style (30 bold, tracking -0.5) scaled down so the line fits `width`, never below `min` of its size.
fn fitted_title(cx: &Cx, title: &str, width: f32, min: f32) -> swiftly_design::TextStyle {
    let full = swiftly_design::TextStyle {
        tracking: -0.5,
        ..st(30.0, 700)
    };
    let natural = cx
        .measure_text(
            title,
            &swiftly_text::TextStyle::from(full),
            Some(1),
            swiftly_layout::Proposal::NIL,
        )
        .w;
    if natural <= width {
        return full;
    }
    let k = (width / natural).max(min);
    swiftly_design::TextStyle {
        size: full.size * k,
        tracking: full.tracking * k,
        ..full
    }
}

fn view(p: &Parts, env: &Env, cx: &Cx, ctx: &Rc<Ctx>) -> Node {
    let f = forms::fm(env);
    // A sheet covers the page; its picker menus come on top of it.
    let menu = p.menu.overlay(cx, env);
    let overlay = match &p.sheet {
        Some(s) => {
            let sheet = crate::load_sheets::sheet_node(cx, &ctx.icons, env, &s.data);
            // The quality and sound menus hang over the sheet.
            Some(match menu {
                Some(m) => Node::zstack(Alignment::TOP_LEADING, vec![sheet, m]),
                None => sheet,
            })
        }
        None => menu,
    };
    if p.sheet_only {
        // The add sheet over a title page: nothing of the Downloads page itself is drawn.
        let none = || Node::fixed(0.0, 0.0);
        return crate::home::fill_frame(none(), Alignment::TOP_LEADING)
            .overlay(overlay.unwrap_or_else(none), Alignment::TOP_LEADING);
    }
    let series = p
        .series
        .as_deref()
        .and_then(|id| p.list.rows.iter().find(|r| r.id == id));
    let any = !p.list.rows.is_empty();
    if f.form != Form::Desktop {
        // Touch and tv keep the shared page with the back header.
        let (title, mut b) = match series {
            Some(r) => {
                let eps = episodes_of(p, &r.id);
                let owned: Vec<DownloadItem> = eps.iter().map(|d| (*d).clone()).collect();
                let next = DownloadRules::next_episode(&owned);
                let mut b = vec![
                    widgets::primary_button(cx, &f, "next", &next_label(next), next.is_some())
                        .padding(ins(0.0, 0.0, 8.0, 0.0)),
                ];
                b.extend(series_body(cx, env, &f, p, ctx, &r.id));
                (r.title.clone(), b)
            }
            None => ("Downloads".to_owned(), body(cx, env, &f, p, ctx)),
        };
        b.push(Node::fixed(0.0, 8.0));
        return forms::page(
            cx,
            &ctx.icons,
            env,
            &f,
            &title,
            (any || series.is_some()).then(|| buttons(ctx, &f, p, 14.0)),
            b,
            overlay,
        );
    }
    match series {
        Some(r) => mac_series(cx, env, &f, p, ctx, r, overlay),
        None => {
            let t = swiftly_design::TextStyle {
                tracking: -0.5,
                ..st(30.0, 700)
            };
            let mut row = vec![
                text(
                    cx,
                    "Downloads",
                    t,
                    colour::FONT,
                    Some(1),
                    swiftly_text::Align::Start,
                ),
                Node::spacer(),
            ];
            if any {
                row.push(buttons(ctx, &f, p, 14.0));
            }
            let head = browse::wide(
                Node::hstack(Align::Center, Some(14.0), row),
                Alignment::LEADING,
            )
            .padding(ins(58.0, 0.0, 0.0, 0.0));
            if any {
                widgets::mac_page(env, None, head, body(cx, env, &f, p, ctx), overlay)
            } else {
                // The empty state sits in the page; a sheet or menu comes over it.
                let page = widgets::mac_page(env, None, head, Vec::new(), None)
                    .overlay(mac_empty_state(cx, ctx), Alignment::CENTER);
                match overlay {
                    Some(o) => page.overlay(o, Alignment::TOP_LEADING),
                    None => page,
                }
            }
        }
    }
}

fn mac_series(
    cx: &Cx,
    env: &Env,
    f: &Fm,
    p: &Parts,
    ctx: &Ctx,
    r: &DownloadRow,
    overlay: Option<Node>,
) -> Node {
    let hero = series_hero(cx, env, f, p, ctx, &r.id, &r.title);
    widgets::mac_page(
        env,
        Some(hero),
        Node::fixed(0.0, 0.0),
        series_body(cx, env, f, p, ctx, &r.id),
        overlay,
    )
}

/// The Downloads page: a UI over a `DownloadsVm`.
pub struct DownloadsScreen {
    ui: Ui<Parts>,
    vm: DownloadsVm<Dyn>,
    edit: bool,
    selected: Vec<String>,
    menu: MenuController,
    hover: Option<String>,
    series: Option<String>,
    opened: Vec<String>,
    closed: bool,
    items: Arc<Vec<DownloadItem>>,
    seen: u64,
    estimators: HashMap<String, ProgressEstimator>,
    reported: HashMap<String, i64>,
    shown: Vec<(String, i64)>,
    last_tick: f64,
    counting: bool,
    sheet: Option<Sheet>,
    sheet_rev: u64,
    sheet_dirty: bool,
    settled: bool,
    sheet_only: bool,
}

impl DownloadsScreen {
    /// What a screen reader gets for this screen: the nodes of the current picture.
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.ui.a11y_nodes()
    }

    /// The page for `env` over a scripted download list.
    pub fn new(env: Env, cx: Cx, scenario: Scenario) -> DownloadsScreen {
        let quiet = Arc::new(Quiet::default());
        let machine =
            DownloadManagerState::new(1, true, false, Box::new(swiftly_vm::TrackNames::german()));
        let vm = DownloadsVm::new(
            Arc::new(Dyn(Arc::clone(&quiet) as Arc<dyn DownloadTransport>)),
            quiet as Arc<dyn DownloadServices>,
            Locale::parse("de"),
            machine,
            true,
        );
        for intent in [
            Intent::SignIn {
                account: Some("u1".into()),
                stored: items(scenario),
                client: true,
            },
            Intent::NetworkChanged {
                wlan: true,
                none: false,
            },
            Intent::RunningTransfers(Vec::new()),
            Intent::SpaceChanged(100_000_000_000),
        ] {
            let _ = vm.send(DownloadsIntent::Engine(Box::new(intent)));
        }
        Self::build(env, cx, vm, false)
    }

    /// The page over a view model that is already running (the real app's file downloads).
    pub fn over(env: Env, cx: Cx, vm: DownloadsVm<Dyn>) -> DownloadsScreen {
        Self::build(env, cx, vm, true)
    }

    /// The page over `vm`; `covers`: the pictures are the saved covers on disk (the real app), not generated demo art.
    fn build(env: Env, cx: Cx, vm: DownloadsVm<Dyn>, covers: bool) -> DownloadsScreen {
        let items = Arc::new(vm.entries());
        let parts = Parts {
            list: vm.list(),
            storage: vm.storage(),
            items: Arc::clone(&items),
            shown: Vec::new(),
            edit: false,
            selected: Vec::new(),
            series: None,
            hover: None,
            menu: MenuController::new(),
            sheet: None,
            settled: false,
            sheet_only: false,
        };
        let ctx = Rc::new(Ctx {
            icons: Icons::new(&cx, env.scale),
            posters: if covers {
                Vec::new()
            } else {
                crate::art::posters(&cx)
            },
            covers: covers.then(crate::live_downloads::downloads_dir),
            loaded: Default::default(),
        });
        let ui = Ui::new(
            move |p: &Parts, env: &Env, cx: &Cx| view(p, env, cx, &ctx),
            parts,
            env,
            cx,
        );
        let seen = vm.version();
        let mut s = DownloadsScreen {
            ui,
            vm,
            edit: false,
            selected: Vec::new(),
            menu: MenuController::new(),
            hover: None,
            series: None,
            opened: Vec::new(),
            closed: false,
            items,
            seen,
            estimators: HashMap::new(),
            reported: HashMap::new(),
            shown: Vec::new(),
            last_tick: f64::NEG_INFINITY,
            counting: false,
            sheet: None,
            sheet_rev: 0,
            sheet_dirty: false,
            settled: false,
            sheet_only: false,
        };
        s.clock(0.0);
        s.sync();
        s
    }

    /// The view model.
    pub fn vm(&self) -> &DownloadsVm<Dyn> {
        &self.vm
    }
    /// Whether edit mode is on.
    pub fn editing(&self) -> bool {
        self.edit
    }
    /// Whether the context menu is open.
    pub fn sheet_open(&self) -> bool {
        self.menu.is_open()
    }
    /// Finished titles tapped to play (ids).
    pub fn opened(&self) -> &[String] {
        &self.opened
    }
    /// Takes the finished titles that were tapped to play (the host opens the player for them).
    pub fn take_opened(&mut self) -> Vec<String> {
        std::mem::take(&mut self.opened)
    }
    /// The series page that is pushed, if any (group id).
    pub fn series(&self) -> Option<&str> {
        self.series.as_deref()
    }
    /// Opens the context menu of a row (`row:<id>`), for tests and goldens.
    pub fn show_menu(&mut self, key: &str) {
        let id = key.trim_start_matches("row:").trim_start_matches("grp:");
        self.open_menu(id, Point::new(260.0, 240.0));
    }
    /// Presses a control by its key (`edit`, `delete`, `row:<id>`, `ring:<id>`, `grp:<id>`, `next`), for tests.
    pub fn press(&mut self, key: &str) {
        self.tapped(&Action::from(key));
    }
    /// No text input here.
    pub fn wants_text(&self) -> bool {
        false
    }
    /// The pointer moved over the window (hover, tooltips).
    pub fn pointer_move(&mut self, x: f32, y: f32, now: f64) {
        self.ui.pointer_move(x, y, now);
        self.drain();
    }
    /// The pointer left the window.
    pub fn pointer_leave(&mut self, now: f64) {
        self.ui.pointer_leave(now);
        self.drain();
    }
    /// A right click: opens the context menu of a series episode row.
    pub fn secondary_click(&mut self, x: f32, y: f32, now: f64) -> bool {
        let used = self.ui.secondary_click(x, y, now);
        self.drain();
        used
    }

    fn open_menu(&mut self, id: &str, at: Point) {
        let item = MenuItem::new(
            Action::from(format!("ctxdel:{id}").as_str()),
            "Download entfernen",
        )
        .destructive();
        self.menu.open(
            vec![MenuEntry::Item(item)],
            Anchor::Pointer(at),
            feel::DROPDOWN_WIDTH,
            false,
        );
    }

    fn sync(&mut self) {
        let v = self.vm.version();
        let changed = v != self.seen;
        if changed {
            self.seen = v;
            self.items = Arc::new(self.vm.entries());
        }
        let storage = self.vm.storage();
        if (changed || self.sheet_dirty) && self.sheet.is_some() {
            let no_wlan = storage.only_over_wlan && storage.waiting_for_wlan;
            match self.sheet.as_mut() {
                Some(Sheet::Add(a)) => a.refresh(&self.vm, no_wlan),
                Some(Sheet::Season(s)) => s.refresh(&self.vm),
                None => {}
            }
            self.sheet_rev += 1;
            self.sheet_dirty = false;
        }
        let list = self.vm.list();
        // The last episode gone, the page gone.
        if self
            .series
            .as_deref()
            .is_some_and(|id| !list.rows.iter().any(|r| r.id == id))
        {
            self.series = None;
        }
        self.selected
            .retain(|s| self.items.iter().any(|i| &i.id == s));
        self.ui.set_parts(Parts {
            list,
            storage: self.vm.storage(),
            items: Arc::clone(&self.items),
            shown: self.shown.clone(),
            edit: self.edit,
            selected: self.selected.clone(),
            series: self.series.clone(),
            hover: self.hover.clone(),
            menu: self.menu.clone(),
            sheet: self.sheet.clone().map(|s| SheetPart {
                rev: self.sheet_rev,
                data: Arc::new(s),
            }),
            settled: self.settled,
            sheet_only: self.sheet_only,
        });
    }

    /// Opens the add popover or the season sheet. This is the hook of the download buttons on Detail and Series: they
    /// build a [`LoadRequest`] and the host hands it to the Downloads page in front (the page opens first if it is not).
    pub fn request_load(&mut self, request: LoadRequest) {
        self.menu.close();
        self.sheet = Some(match request {
            LoadRequest::Add {
                title,
                items,
                images,
                quality_select,
                streams,
                anchor,
            } => Sheet::Add(Box::new(AddSheet::new(
                title,
                items,
                images,
                quality_select,
                streams,
                anchor,
            ))),
            LoadRequest::Season {
                account,
                series,
                seasons,
                episodes,
                quality_select,
                anchor,
            } => Sheet::Season(Box::new(SeasonSheet::new(
                account,
                *series,
                seasons,
                episodes,
                quality_select,
                anchor,
            ))),
        });
        self.sheet_dirty = true;
        self.sync();
    }

    /// Draws only the sheet (it floats over the title page it was opened from, not over the Downloads page).
    pub fn set_sheet_only(&mut self, on: bool) {
        self.sheet_only = on;
        self.sheet_dirty = true;
    }

    /// Whether only the sheet draws (see [`DownloadsScreen::set_sheet_only`]).
    pub fn is_sheet_only(&self) -> bool {
        self.sheet_only
    }

    /// Whether the add popover or the season sheet is open.
    pub fn load_open(&self) -> bool {
        self.sheet.is_some()
    }

    /// The seasons of the open season sheet that still have to be read, in batches of three (empty when none is open).
    pub fn season_pending(&self) -> Vec<Vec<String>> {
        match &self.sheet {
            Some(Sheet::Season(s)) => s.sel.batches(),
            _ => Vec::new(),
        }
    }

    /// The answer for one season of the open season sheet (`None` = the request failed).
    pub fn season_loaded(&mut self, season: &str, episodes: Option<Vec<swiftly_model::Item>>) {
        if let Some(Sheet::Season(s)) = self.sheet.as_mut() {
            s.sel.record_season(season, episodes);
            self.sheet_dirty = true;
        }
    }

    /// All seasons have been tried: the sheet stops saying "wird gelesen …".
    pub fn season_finished(&mut self) {
        if let Some(Sheet::Season(s)) = self.sheet.as_mut() {
            s.sel.finish_load();
            self.sheet_dirty = true;
        }
    }

    /// The Delete key: removes the selected rows in edit mode (also on the series page). True when it did something.
    pub fn delete_key(&mut self) -> bool {
        if self.sheet.is_some() || !self.edit || self.selected.is_empty() {
            return false;
        }
        let ids = std::mem::take(&mut self.selected);
        self.remove(&ids);
        self.edit = false;
        true
    }

    /// The selected rows of edit mode (ids).
    pub fn selected(&self) -> &[String] {
        &self.selected
    }

    fn go_back(&mut self) -> bool {
        if self.menu.is_open() {
            self.menu.close();
            true
        } else if self.sheet.take().is_some() {
            true
        } else if self.edit {
            self.edit = false;
            self.selected.clear();
            true
        } else {
            self.series.take().is_some()
        }
    }

    fn remove(&mut self, ids: &[String]) {
        let all: Vec<(String, RowState)> = self
            .vm
            .list()
            .rows
            .iter()
            .flat_map(|r| r.items.iter().map(|i| (i.id.clone(), i.state)))
            .collect();
        let done: Vec<String> = all
            .iter()
            .filter(|(i, s)| ids.contains(i) && *s == RowState::Done)
            .map(|(i, _)| i.clone())
            .collect();
        if !done.is_empty() {
            let _ = self.vm.send(DownloadsIntent::Delete(done));
        }
        for (i, s) in &all {
            if ids.contains(i) && *s != RowState::Done {
                let _ = self.vm.send(DownloadsIntent::Cancel(i.clone()));
            }
        }
    }

    /// Opens the menu of a picker button of the sheet under that button (`Ui::frame_of(key)`). False when the sheet has
    /// no such menu or the button has not been laid out yet.
    fn open_sheet_menu(&mut self, key: &str) -> bool {
        let Some(entries) = self.sheet.as_ref().and_then(|s| s.menu(key)) else {
            return false;
        };
        let Some(f) = self.ui.frame_of(key) else {
            return false;
        };
        self.menu.open(
            entries,
            Anchor::Button(Rect::new(f[0], f[1], f[2], f[3])),
            feel::DROPDOWN_WIDTH,
            false,
        );
        true
    }

    fn tapped(&mut self, a: &Action) {
        let is = |s: &str| *a == Action::from(s);
        if is("back") {
            self.back(0.0);
            return;
        }
        if *a == popover::DISMISS {
            self.menu.close();
            return;
        }
        if self.sheet.is_some() {
            if is("load.close") {
                self.sheet = None;
                return;
            }
            // A picker button opens its menu under itself (quality, sound); without a laid-out button the old cycling stays.
            if let Some(t) = Sheet::TRIGGERS.into_iter().find(|t| is(t))
                && self.open_sheet_menu(t)
            {
                return;
            }
            let keys = self.sheet.as_ref().map(Sheet::keys).unwrap_or_default();
            if let Some(k) = keys.into_iter().find(|k| is(k)) {
                self.menu.close();
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_or(0.0, |d| d.as_secs_f64());
                let done = match self.sheet.as_mut() {
                    Some(Sheet::Add(s)) => s.act(&k, &self.vm),
                    Some(Sheet::Season(s)) => s.act(&k, &self.vm, now),
                    None => None,
                };
                if done == Some(true) {
                    self.sheet = None;
                } else {
                    self.sheet_dirty = true;
                }
            }
            return;
        }
        if is("edit") {
            self.edit = !self.edit;
            self.selected.clear();
        } else if is("delete") {
            let ids = std::mem::take(&mut self.selected);
            self.remove(&ids);
            self.edit = false;
        } else if is("next") {
            let owned: Vec<DownloadItem> = self
                .series
                .as_deref()
                .map(|id| {
                    self.vm
                        .list()
                        .rows
                        .iter()
                        .find(|r| r.id == id)
                        .map(|r| r.items.iter().filter_map(|i| self.vm.item(&i.id)).collect())
                        .unwrap_or_default()
                })
                .unwrap_or_default();
            if let Some(n) = DownloadRules::next_episode(&owned) {
                self.opened.push(n.id.clone());
            }
        }
        let list = self.vm.list();
        for r in &list.rows {
            let group_ids: Vec<String> = r
                .items
                .iter()
                .filter(|i| i.state == RowState::Done)
                .map(|i| i.id.clone())
                .collect();
            if is(&format!("grp:{}", r.id)) {
                if self.edit {
                    self.toggle(&group_ids);
                } else {
                    // Pushes `DownloadSeriesView`.
                    self.series = Some(r.id.clone());
                }
            }
            for i in &r.items {
                let id = &i.id;
                if is(&format!("row:{id}")) {
                    if self.edit {
                        self.toggle(std::slice::from_ref(id));
                    } else if i.state == RowState::Done {
                        self.opened.push(id.clone());
                    }
                } else if is(&format!("ring:{id}")) {
                    // `ringClick`: loading pauses, paused, failed and waiting resume, finished does nothing.
                    let intent = match i.state {
                        RowState::Loading => Some(DownloadsIntent::Pause(id.clone())),
                        RowState::Waiting | RowState::Paused | RowState::Failed => {
                            Some(DownloadsIntent::Resume(id.clone()))
                        }
                        RowState::Done => None,
                    };
                    if let Some(intent) = intent {
                        let _ = self.vm.send(intent);
                    }
                } else if is(&format!("ctxdel:{id}")) {
                    self.menu.close();
                    self.remove(std::slice::from_ref(id));
                }
            }
        }
    }

    fn toggle(&mut self, ids: &[String]) {
        if ids.iter().all(|i| self.selected.contains(i)) {
            self.selected.retain(|s| !ids.contains(s));
        } else {
            for i in ids {
                if !self.selected.contains(i) {
                    self.selected.push(i.clone());
                }
            }
        }
    }

    /// The 10 Hz timeline of `MacDownloadRow`: while bytes arrive the number, bar and ring read the estimate between
    /// two reports; paused titles stand at the larger of estimate and report.
    fn clock(&mut self, now: f64) {
        let t = now / 1000.0;
        if t - self.last_tick < 0.1 {
            return;
        }
        self.last_tick = t;
        let storage = self.vm.storage();
        let no_network = storage.offline || storage.waiting_for_wlan;
        let mut shown = Vec::new();
        let mut counting = false;
        for d in self.vm.entries() {
            if !matches!(d.state, DownloadState::Loads | DownloadState::Halted) {
                self.estimators.remove(&d.id);
                self.reported.remove(&d.id);
                continue;
            }
            let comes = d.state == DownloadState::Loads && !no_network;
            let e = self.estimators.entry(d.id.clone()).or_default();
            if self.reported.get(&d.id) != Some(&d.loaded) {
                e.report(d.loaded, d.bytes, t);
                self.reported.insert(d.id.clone(), d.loaded);
            }
            if !comes {
                e.halt();
            }
            let v = if comes {
                e.value(t)
            } else {
                e.value(t).max(d.loaded)
            };
            counting |= comes;
            shown.push((d.id.clone(), v));
        }
        self.shown = shown;
        self.counting = counting;
    }

    /// Starts showing the page (no slide yet).
    pub fn open(&mut self, _now: f64) {
        self.closed = false;
    }
    /// Whether the page is still on the stack.
    pub fn is_open(&self) -> bool {
        !self.closed
    }
    /// The page covers what is behind it.
    pub fn covers(&self) -> bool {
        true
    }
    /// Back: closes the menu, then edit mode, then the series page, then the page.
    pub fn back(&mut self, _now: f64) -> bool {
        if !self.go_back() {
            self.closed = true;
        }
        true
    }
    /// A new window size or scale.
    pub fn set_env(&mut self, env: Env) {
        self.ui.set_env(env);
    }
    /// A finger goes down.
    pub fn touch_down(&mut self, x: f32, y: f32, now: f64) {
        self.ui.touch_down(x, y, now);
        self.drain();
    }
    /// The finger moves.
    pub fn touch_move(&mut self, x: f32, y: f32, now: f64) {
        self.ui.touch_move(x, y, now);
        self.drain();
    }
    /// The finger lifts.
    pub fn touch_up(&mut self, x: f32, y: f32, now: f64) {
        self.ui.touch_up(x, y, now);
        self.drain();
    }
    /// The touch is cancelled.
    pub fn touch_cancel(&mut self, now: f64) {
        self.ui.touch_cancel(now);
        self.drain();
    }
    /// Arrow, Tab, Enter or Esc; Esc goes back.
    pub fn nav_key(
        &mut self,
        key: swiftly_ui::NavKey,
        down: bool,
        now: f64,
    ) -> swiftly_ui::Outcome {
        if down && self.menu.is_open() {
            // The open menu owns the keys: arrows, Enter, Esc.
            if let Some(k) = crate::detail_screen::menu_key(key) {
                if let MenuOutcome::Activate(a) = self.menu.key(k, now) {
                    self.tapped(&a);
                }
                return swiftly_ui::Outcome::None;
            }
        }
        if down && matches!(key, swiftly_ui::NavKey::Escape) {
            self.back(now);
            return swiftly_ui::Outcome::None;
        }
        let out = self.ui.nav_key(key, down, now);
        self.drain();
        out
    }
    /// One frame at `now` ms.
    pub fn frame(&mut self, now: f64) -> (swiftly_render::DrawList, bool) {
        self.clock(now);
        self.sync();
        let list = self.ui.frame(now);
        self.settled = true;
        self.drain();
        let wants = self.wants_frame();
        (list, wants)
    }
    /// Another frame is wanted (the loading rows count at 10 Hz).
    pub fn wants_frame(&self) -> bool {
        self.ui.needs_frame() || self.counting
    }
    /// The services the renderers read.
    pub fn cx(&self) -> &Cx {
        self.ui.cx()
    }
    /// Renders a list with the software renderer.
    pub fn render_software(&self, list: &swiftly_render::DrawList) -> swiftly_render::RgbaImage {
        self.ui.render(list, swiftly_render::Color::BLACK)
    }
    /// Focused key on tv.
    pub fn focused(&self) -> Option<swiftly_ui::FocusId> {
        self.ui.focused()
    }

    fn drain(&mut self) {
        for ev in self.ui.take_events() {
            match ev {
                UiEvent::Tap(a) => self.tapped(&a),
                UiEvent::HoverChanged { action, entered } => {
                    let found = self
                        .items
                        .iter()
                        .find(|i| action == Action::from(format!("hv:{}", i.id).as_str()))
                        .map(|i| i.id.clone());
                    if let Some(id) = found {
                        if entered {
                            self.hover = Some(id);
                        } else if self.hover.as_deref() == Some(id.as_str()) {
                            self.hover = None;
                        }
                    }
                }
                UiEvent::Secondary { action, x, y } => {
                    let found = self
                        .items
                        .iter()
                        .find(|i| action == Action::from(format!("ctx:{}", i.id).as_str()))
                        .map(|i| i.id.clone());
                    if let Some(id) = found {
                        self.open_menu(&id, Point::new(x, y));
                    }
                }
                _ => {}
            }
        }
    }
}

#[cfg(test)]
mod core_rule_tests {
    use super::*;

    #[test]
    fn the_series_button_text_and_the_group_rule_are_the_cores() {
        let e = episode(2, DownloadState::Done, 900_000_000);
        assert_eq!(next_label(Some(&e)), "Abspielen S1 · F2");
        assert_eq!(next_label(None), "Abspielen");
        // A series with one finished episode is still a series group on the Mac (`DownloadRules.grouped`).
        assert!(matches!(
            DownloadRules::grouped(std::slice::from_ref(&e)).as_slice(),
            [swiftly_downloads::DownloadGroup::Series { .. }]
        ));
    }
}

#[cfg(test)]
mod cover_tests {
    use super::*;

    fn png(w: u32, h: u32) -> Vec<u8> {
        let mut out = Vec::new();
        let mut e = png::Encoder::new(&mut out, w, h);
        e.set_color(png::ColorType::Rgba);
        e.set_depth(png::BitDepth::Eight);
        let mut wr = e.write_header().expect("header");
        wr.write_image_data(&vec![200u8; (w * h * 4) as usize])
            .expect("data");
        drop(wr);
        out
    }

    /// Over real downloads the row picture is the cover the engine saved (`DownloadItem::image_name`), a title without a
    /// file gets none (ground + symbol), and the generated demo posters are only for the demo list.
    #[test]
    fn the_row_picture_is_the_saved_cover_never_a_generated_poster() {
        let dir = std::env::temp_dir().join(format!("swiftly-covers-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        std::fs::write(dir.join(DownloadItem::image_name("u1", "f1")), png(8, 12)).expect("cover");
        let cx = Cx::deterministic();
        let live = Ctx {
            icons: Icons::new(&cx, 1.0),
            posters: Vec::new(),
            covers: Some(dir.clone()),
            loaded: Default::default(),
        };
        assert!(
            live.picture(&cx, "u1", "f1").is_some(),
            "the saved cover is read"
        );
        assert!(
            live.picture(&cx, "u1", "f2").is_none(),
            "no file: no generated art"
        );
        assert!(
            live.picture(&cx, "u2", "f1").is_none(),
            "another account's cover is not shared"
        );
        let demo = Ctx {
            icons: Icons::new(&cx, 1.0),
            posters: crate::art::posters(&cx),
            covers: None,
            loaded: Default::default(),
        };
        assert!(demo.picture(&cx, "u1", "f2").is_some());
        let _ = std::fs::remove_dir_all(dir);
    }
}

#[cfg(test)]
mod ring_state_tests {
    use super::*;
    use swiftly_downloads::DownloadState;

    fn row(id: &str, state: RowState) -> DownloadRow {
        DownloadRow {
            id: id.into(),
            title: String::new(),
            subtitle: None,
            state,
            progress: None,
            size: String::new(),
            items: vec![ItemRow {
                id: id.into(),
                title: String::new(),
                season: None,
                episode: None,
                state,
                progress: None,
                size: String::new(),
                progress_text: None,
                reason: None,
                watched: false,
                can_pause: false,
                can_resume: false,
                can_cancel: false,
                can_delete: false,
            }],
        }
    }

    /// The list files a finished video with pending subtitles under "loading"; its ring must say the same.
    #[test]
    fn the_ring_follows_the_list_row_not_the_stored_state() {
        let mut item = DownloadItem::new("m1", "acc", Art::Film, "Film", 100, 0.0);
        item.state = DownloadState::Done;
        item.subtitles_pending = true;
        let rows = [row("m1", RowState::Loading)];
        assert_eq!(ring_state(&rows, &item), RowState::Loading);
        assert_eq!(
            widgets::ring_label(Some(ring_state(&rows, &item))),
            "L\u{00E4}dt, anhalten"
        );
        assert_eq!(
            ring_state(&[], &item),
            RowState::Done,
            "unlisted: the stored state"
        );
    }
}
