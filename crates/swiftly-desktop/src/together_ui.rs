//! The panel of watching together and continuing elsewhere (`MacShared.swift` `SharedPanel`): "Gemeinsam schauen"
//! (name the group), "Beitreten" and the picker "Läuft gerade" over a scrim in the middle of the window, one card 420
//! wide. The card of "Wo weiterschauen?" is the same picker. The picker grows out of the sidebar row; create and join
//! fade in with a small scale. Return confirms, Escape cancels.
//!
//! This is only the presentation: the suite owns the hub and acts on what [`TogetherUi::take_acts`] returns.

use crate::browse::wide;
use crate::home::{fill_frame, ins, rgba, text};
use swiftly_design::TextStyle;
use swiftly_design::tokens::{colour, desktop};
use swiftly_layout::{Align, Alignment, EdgeInsets};
use swiftly_playback::handoff_card::{
    AT_MOST_WAIT, BLACK_DURATION, CARDS_START, Direction, END, EXIT_START, FADE, FADE_OUT,
    LOADING_BAR_OUT, LOADING_BAR_TICK, MAC, Status, cards_coverage, corner, exit, exit_out,
    exit_rows_coverage, fullscreen, idle_status, load_line, momentum, pages_coverage,
    rows_coverage, rows_top, stage_coverage, wait, zoom, zoom_start,
};
use swiftly_playback::takeover::DevicesKind;
use swiftly_render::{Color, DrawList};
use swiftly_text::{Clipboard, TextEditor, TextInputEvent};
use swiftly_ui::components::color;
use swiftly_ui::field::{FieldLook, FieldState, FieldView};
use swiftly_ui::icons::Icons;
use swiftly_ui::{Action, Cx, Env, Node, Paint, Ui, UiEvent};
use swiftly_vm::GroupRow;

/// The name a new group starts with (`Filmabend`).
pub const DEFAULT_NAME: &str = "Filmabend";

/// What the create panel says the group will watch (`SharedPanel.titleLine`): an episode as "Series · Staffel 1 ·
/// Folge 2", "Series · Name" when the numbers are missing, anything else by its name.
pub fn title_line(
    episode: bool,
    series: &str,
    season: Option<i64>,
    number: Option<i64>,
    name: &str,
) -> String {
    if !episode || series.is_empty() {
        return name.to_owned();
    }
    match (season, number) {
        (Some(s), Some(e)) => format!("{series} \u{b7} Staffel {s} \u{b7} Folge {e}"),
        _ => format!("{series} \u{b7} {name}"),
    }
}

/// The second line under the leaving card (`HandoffStyle.rows`): "Staffel 1 \u{b7} Folge 2" for an episode, nothing for
/// anything else (the player's own line of a film is year, runtime and genre; the card does not carry it).
pub fn exit_line(player_line: &str) -> String {
    if let Some((s, e)) = parse_code(player_line) {
        return format!("Staffel {s} \u{b7} Folge {e}");
    }
    if player_line.starts_with("Staffel ") {
        return player_line.to_owned();
    }
    String::new()
}

/// The two lines of the arriving card (`HandoffStyle.rows`): the series and "Staffel 1 \u{b7} Folge 2" for an episode, the
/// episode's name when the numbers are missing, the film's name alone otherwise.
pub fn receive_lines(item: &swiftly_model::Item) -> (String, String) {
    match item.series_name.as_deref().filter(|s| !s.is_empty()) {
        Some(series) => match (item.parent_index_number, item.index_number) {
            (Some(s), Some(e)) => (series.to_owned(), format!("Staffel {s} \u{b7} Folge {e}")),
            _ => (series.to_owned(), item.name.clone()),
        },
        None => (item.name.clone(), String::new()),
    }
}

/// [`title_line`] for a tile: its `title` is the series for an episode and `facts.name` the episode's own name.
pub fn tile_line(tile: &swiftly_vm::Tile) -> String {
    let f = &tile.facts;
    let episode = f
        .kind
        .as_deref()
        .is_some_and(|k| k.eq_ignore_ascii_case("episode"));
    let name = if f.name.is_empty() {
        &tile.title
    } else {
        &f.name
    };
    title_line(
        episode,
        &tile.title,
        f.season_number.map(i64::from),
        f.episode_number.map(i64::from),
        name,
    )
}

/// The season and episode of a "S1 \u{b7} F3" code.
pub fn parse_code(code: &str) -> Option<(i64, i64)> {
    let (s, f) = code.split_once(" \u{b7} ")?;
    Some((
        s.trim().strip_prefix('S')?.parse().ok()?,
        f.trim().strip_prefix('F')?.parse().ok()?,
    ))
}

/// The icon of a device (`devicesCharacter`: iphone, ipad, laptopcomputer, tv, play.tv).
pub fn device_symbol(kind: DevicesKind) -> &'static str {
    match kind {
        DevicesKind::Phone => "device-mobile",
        DevicesKind::Tablet => "device-tablet",
        DevicesKind::Computer => "laptop",
        DevicesKind::Tv => "television",
        DevicesKind::Unknown => "monitor-play",
    }
}

/// Which panel is open.
#[derive(Debug, Clone, PartialEq)]
pub enum Mode {
    /// None.
    Closed,
    /// Name the group for a title.
    Create {
        /// The title the group will watch.
        title_id: String,
        /// "Series · Staffel 1 · Folge 2" or the film's name.
        line: String,
    },
    /// Join this group.
    Join(GroupRow),
    /// The picker: devices that play, groups to join.
    Pick,
    /// Continuing on this device did not work: the words of the reason.
    Failed(String),
    /// The picture leaves for another device (`HandoffExit`): the title, the episode line and the device.
    Exit {
        /// The title.
        title: String,
        /// "Staffel 1 · Folge 2" or empty.
        line: String,
        /// The device that took over.
        device: String,
        /// The last picture of the video (`None`: the card flies without a picture).
        still: Option<ExitStill>,
        /// Whether the card flies off the top edge (the other device is the bigger one) or the bottom.
        top: bool,
    },
    /// The picture arrives from another device (`HandoffStage`): the card grows from the sidebar row, waits for the
    /// first frame of the player under it, then zooms into the picture.
    Receive {
        /// The title.
        title: String,
        /// "Staffel 1 \u{b7} Folge 2" or empty.
        line: String,
        /// The device it comes from.
        device: String,
    },
}

/// The still frame of the video that leaves as the card: straight RGBA, rows packed. Cloning shares the pixels.
#[derive(Debug, Clone)]
pub struct ExitStill {
    /// Width in pixels.
    pub w: u32,
    /// Height in pixels.
    pub h: u32,
    /// `w * h * 4` bytes.
    pub rgba: std::sync::Arc<Vec<u8>>,
}

impl PartialEq for ExitStill {
    fn eq(&self, other: &Self) -> bool {
        self.w == other.w && self.h == other.h && std::sync::Arc::ptr_eq(&self.rgba, &other.rgba)
    }
}

/// Where the outgoing picture, its lines and the grounds stand at one moment (`HandoffExit.play`, shared curves of
/// `swiftly_playback::handoff_card`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ExitLook {
    /// Centre x of the picture in window points.
    pub x: f64,
    /// Centre y.
    pub y: f64,
    /// Width of the picture.
    pub width: f64,
    /// Height of the picture (its own aspect).
    pub height: f64,
    /// Visible corner radius.
    pub corner: f64,
    /// Top edge of the two lines under the card.
    pub rows_top: f64,
    /// Opacity of the lines.
    pub rows: f64,
    /// Opacity of the player's black ground (it goes when the card shrinks).
    pub black: f64,
    /// Opacity of the picture (1, except with reduced motion where it fades).
    pub picture: f64,
    /// Opacity of the app-coloured ground under all of it.
    pub ground: f64,
    /// The whole exit is through.
    pub over: bool,
}

/// How long the stage stays after the card is out, until the ground fades (`HandoffExit.closeDuration`).
const CLOSE_AFTER: f64 = 0.5;

/// The plan of one exit: where the picture stood, where the card rests and where it flies.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ExitPlan {
    full: Status,
    card: Status,
    bearing: Direction,
    pages: f64,
    reduced: bool,
    out: f64,
}

impl ExitPlan {
    /// `window` in points, `pages` the picture's width over its height, `top` the flight direction.
    pub fn new(window: (f32, f32), pages: f64, top: bool, reduced: bool) -> ExitPlan {
        let (w, h) = (f64::from(window.0), f64::from(window.1));
        let pages = if pages > 0.0 { pages } else { 16.0 / 9.0 };
        // Where the video stood: fitted to the picture itself, centred in the window.
        let full = Status::new(w / 2.0, h / 2.0, w.min(h * pages));
        let card = idle_status(w, h, MAC);
        let bearing = if top {
            Direction::TOP
        } else {
            Direction::BOTTOM
        };
        let out = if reduced {
            FADE_OUT
        } else {
            exit_out(full, card, bearing)
        };
        ExitPlan {
            full,
            card,
            bearing,
            pages,
            reduced,
            out,
        }
    }

    /// Seconds from the stop until the card is out of the window.
    pub fn out(&self) -> f64 {
        self.out
    }

    /// Seconds until the whole stage is gone.
    pub fn total(&self) -> f64 {
        self.out + CLOSE_AFTER + FADE + 0.05
    }

    /// The look `t` seconds after the stop.
    pub fn look(&self, t: f64) -> ExitLook {
        let t = t.max(0.0);
        let ground = 1.0 - ((t - self.out - CLOSE_AFTER) / FADE).clamp(0.0, 1.0);
        let over = t >= self.total();
        if self.reduced {
            let fade = 1.0 - (t / FADE_OUT).clamp(0.0, 1.0);
            return ExitLook {
                x: self.full.x,
                y: self.full.y,
                width: self.full.width,
                height: self.full.width / self.pages,
                corner: 0.0,
                rows_top: 0.0,
                rows: 0.0,
                black: fade,
                picture: fade,
                ground,
                over,
            };
        }
        let at = exit(t, self.full, self.card, self.bearing);
        ExitLook {
            x: at.x,
            y: at.y,
            width: at.width,
            height: at.width / self.pages,
            corner: corner(at, MAC, self.full),
            rows_top: rows_top(at, MAC),
            rows: exit_rows_coverage(t),
            black: 1.0 - ((t - EXIT_START) / BLACK_DURATION).clamp(0.0, 1.0),
            picture: 1.0,
            ground,
            over,
        }
    }
}

/// Where the arriving card stands at one moment (`HandoffStage`, the shared curves of
/// `swiftly_playback::handoff_card`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ReceiveLook {
    /// Centre x of the card in window points.
    pub x: f64,
    /// Centre y.
    pub y: f64,
    /// Width of the card.
    pub width: f64,
    /// Height of the card (16:9).
    pub height: f64,
    /// Visible corner radius.
    pub corner: f64,
    /// Top edge of the lines under the card.
    pub rows_top: f64,
    /// Opacity of the lines.
    pub rows: f64,
    /// Opacity of the card.
    pub card: f64,
    /// Opacity of the app-coloured ground that steps in front of the page.
    pub ground: f64,
    /// Opacity of the player's black that comes in while the card zooms.
    pub black: f64,
    /// Opacity of the whole stage (it goes as the zoom ends).
    pub stage: f64,
    /// Whether the loading line shows (the picture is late).
    pub loading: bool,
    /// The whole arrival is through.
    pub over: bool,
}

/// The plan of one arrival: the badge the card flies out of, where it hovers and the full picture.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ReceivePlan {
    from: Status,
    idle: Status,
    full: Status,
    reduced: bool,
}

/// How wide the card is at the badge when it opens (`HandoffStyle.badgeWidth` on the Mac).
const BADGE_WIDTH: f64 = 32.0;

impl ReceivePlan {
    /// `window` in points, `badge` the middle of the sidebar row the tap came from.
    pub fn new(window: (f32, f32), badge: (f32, f32), reduced: bool) -> ReceivePlan {
        let (w, h) = (f64::from(window.0), f64::from(window.1));
        let idle = idle_status(w, h, MAC);
        let from = if reduced {
            idle
        } else {
            Status::new(f64::from(badge.0), f64::from(badge.1), BADGE_WIDTH)
        };
        ReceivePlan {
            from,
            idle,
            full: fullscreen(w, h),
            reduced,
        }
    }

    /// Seconds from the tap until the zoom begins, when the picture is up at `ready` (`HandoffCard.zoomStart`).
    pub fn zoom_at(&self, ready: f64) -> f64 {
        if self.reduced {
            ready
        } else {
            zoom_start(ready)
        }
    }

    /// Seconds from the tap until everything is gone, for a zoom that begins at `zoom_at`.
    pub fn end(&self, zoom_at: f64) -> f64 {
        zoom_at + if self.reduced { FADE_OUT } else { END }
    }

    /// The look `t` seconds after the tap; `zoom_at`: when the zoom began, `None` while the card waits.
    pub fn look(&self, t: f64, zoom_at: Option<f64>) -> ReceiveLook {
        let t = t.max(0.0);
        let loading = zoom_at.is_none() && t >= LOADING_BAR_OUT && load_line(None);
        if self.reduced {
            let fade = |since: f64| ((t - since) / FADE).clamp(0.0, 1.0);
            let stage = zoom_at.map_or(1.0, |z| 1.0 - ((t - z) / FADE_OUT).clamp(0.0, 1.0));
            return ReceiveLook {
                x: self.idle.x,
                y: self.idle.y,
                width: self.idle.width,
                height: self.idle.height(),
                corner: MAC.corner,
                rows_top: rows_top(self.idle, MAC),
                rows: fade(CARDS_START),
                card: fade(CARDS_START),
                ground: fade(0.0),
                black: 0.0,
                stage,
                loading,
                over: zoom_at.is_some_and(|z| t >= self.end(z)),
            };
        }
        let (at, rows, black, stage, over) = match zoom_at.filter(|z| t >= *z) {
            None => (
                wait(t, self.from, self.idle, CARDS_START),
                rows_coverage(t, zoom_at),
                0.0,
                1.0,
                false,
            ),
            Some(z) => {
                let start = wait(z, self.from, self.idle, CARDS_START);
                let v = momentum(z, self.from, self.idle, CARDS_START);
                (
                    zoom(t - z, start, v, self.full),
                    rows_coverage(t, Some(z)),
                    ((t - z) / BLACK_DURATION).clamp(0.0, 1.0),
                    stage_coverage(t - z),
                    t >= z + END,
                )
            }
        };
        ReceiveLook {
            x: at.x,
            y: at.y,
            width: at.width,
            height: at.height(),
            corner: corner(at, MAC, self.full),
            rows_top: rows_top(at, MAC),
            rows,
            card: cards_coverage(t),
            ground: pages_coverage(t),
            black,
            stage,
            loading,
            over,
        }
    }
}

impl Mode {
    /// Whether a panel is up.
    pub fn open(&self) -> bool {
        !matches!(self, Mode::Closed)
    }
}

/// One row of the picker.
#[derive(Debug, Clone, PartialEq)]
pub struct PickRow {
    /// A session to take over (its id), or a group to join (its id).
    pub target: PickTarget,
    /// The icon.
    pub symbol: String,
    /// The first line.
    pub title: String,
    /// The second line.
    pub under: String,
}

/// What a picker row does.
#[derive(Debug, Clone, PartialEq)]
pub enum PickTarget {
    /// Continue here what plays on this session.
    Session(String),
    /// Join this group.
    Group(GroupRow),
}

/// What the user chose.
#[derive(Debug, Clone, PartialEq)]
pub enum Act {
    /// Scrim, "Abbrechen" or Escape.
    Cancel,
    /// "Gruppe öffnen": the name and the title.
    Create {
        /// The typed name.
        name: String,
        /// The title.
        title_id: String,
    },
    /// "Beitreten".
    Join(GroupRow),
    /// "Hier weiterschauen" on a session.
    Take(String),
}

#[derive(Clone, PartialEq)]
struct Parts {
    mode: Mode,
    rows: Vec<PickRow>,
    field: FieldView,
    works: bool,
    origin: (f32, f32),
    exit: Option<ExitFrame>,
    receive: Option<ReceiveFrame>,
}

/// The panel.
pub struct TogetherUi {
    ui: Ui<Parts>,
    mode: Mode,
    rows: Vec<PickRow>,
    field: FieldState,
    clip: Box<dyn Clipboard>,
    works: bool,
    origin: (f32, f32),
    acts: Vec<Act>,
    now: f64,
    run: Option<ExitRun>,
    arrival: Option<ArrivalRun>,
}

/// The arrival that is playing: when the tap was and what the card waits for.
struct ArrivalRun {
    /// `None` until the first frame says what time it is.
    since: Option<f64>,
    plan: ReceivePlan,
    /// Seconds after the tap when the player opened under the card.
    up: Option<f64>,
    /// Seconds after the tap when the zoom begins.
    zoom_at: Option<f64>,
    /// Seconds after the tap when the arrival was called off (the takeover failed or the player closed).
    cancelled: Option<f64>,
}

#[derive(Clone, PartialEq)]
struct ReceiveFrame {
    look: ReceiveLook,
    /// Where the loading line's stripe is, 0..1 across.
    travel: f64,
}

/// The exit that is playing: when it began and what it stands on.
struct ExitRun {
    /// `None` until the first frame says what time it is.
    since: Option<f64>,
    plan: ExitPlan,
    slot: Option<swiftly_ui::ImageSlot>,
}

fn st(size: f32, weight: u16) -> TextStyle {
    TextStyle {
        size,
        weight,
        tracking: 0.0,
        uppercase: false,
    }
}

fn look() -> FieldLook {
    FieldLook {
        style: swiftly_text::TextStyle::from(st(14.0, 400)),
        text: color(colour::FONT),
        placeholder: color(colour::FONT_VERY_QUIET),
        caret: color(colour::MARK_ACCENT),
        selection: color(colour::MARK_ACCENT).with_alpha(0.30),
        caret_height: Some(18.0),
    }
}

fn line(w: f32) -> Node {
    Node::rect(color(colour::LINE), 0.0).frame(Some(w), Some(1.0), Alignment::CENTER)
}

fn heading(cx: &Cx, s: &str) -> Node {
    wide(
        text(
            cx,
            s,
            st(17.0, 600),
            colour::FONT,
            Some(1),
            swiftly_text::Align::Start,
        ),
        Alignment::LEADING,
    )
    .padding(ins(20.0, 20.0, 12.0, 20.0))
    .a11y(swiftly_ui::a11y::A11yNode::new(
        "",
        swiftly_ui::a11y::Role::Heading,
        s,
    ))
}

fn primary(cx: &Cx, icons: &Icons, key: &str, label: &str, symbol: &str, enabled: bool) -> Node {
    let inner = Node::hstack(
        Align::Center,
        Some(8.0),
        vec![
            icons
                .node(symbol, 16.0, false, color(colour::REASON))
                .a11y_hidden(),
            text(
                cx,
                label,
                st(17.0, 600),
                colour::REASON,
                Some(1),
                swiftly_text::Align::Center,
            ),
        ],
    );
    let n = wide(inner, Alignment::CENTER)
        .frame(None, Some(48.0), Alignment::CENTER)
        .background(Node::rect(color(colour::FONT), 10.0), Alignment::CENTER)
        .hover_surface(Color::new(0.0, 0.0, 0.0, 0.12), 10.0)
        .a11y(swiftly_ui::a11y::A11yNode::new(
            "",
            swiftly_ui::a11y::Role::Button,
            label,
        ));
    if enabled {
        n.key(key).on_tap(Action::from(key))
    } else {
        n.key(key)
            .disabled(true)
            .opacity(0.5, swiftly_ui::feel::hover())
    }
}

fn body(cx: &Cx, s: &str, size: f32, c: swiftly_design::Colour, lines: usize) -> Node {
    wide(
        text(
            cx,
            s,
            st(size, 400),
            c,
            Some(lines),
            swiftly_text::Align::Start,
        ),
        Alignment::LEADING,
    )
}

fn pick_row(cx: &Cx, icons: &Icons, i: usize, r: &PickRow) -> Node {
    let action = match r.target {
        PickTarget::Session(_) => "Hier weiterschauen",
        PickTarget::Group(_) => "Beitreten",
    };
    let key = format!("tg:pick:{i}");
    let row = Node::hstack(
        Align::Center,
        Some(14.0),
        vec![
            icons
                .node(&r.symbol, 17.0, true, color(colour::MARK_ACCENT))
                .frame(Some(26.0), None, Alignment::CENTER),
            Node::vstack(
                Align::Start,
                Some(1.0),
                vec![
                    text(
                        cx,
                        &r.title,
                        st(14.0, 600),
                        colour::FONT,
                        Some(1),
                        swiftly_text::Align::Start,
                    ),
                    text(
                        cx,
                        &r.under,
                        st(12.0, 400),
                        colour::FONT_QUIET,
                        Some(1),
                        swiftly_text::Align::Start,
                    ),
                ],
            )
            .layout_priority(1.0),
            Node::spacer(),
            text(
                cx,
                action,
                st(14.0, 600),
                colour::MARK_ACCENT,
                Some(1),
                swiftly_text::Align::End,
            )
            .layout_priority(2.0),
        ],
    )
    .padding(EdgeInsets::symmetric(20.0, 0.0))
    .frame(None, Some(58.0), Alignment::LEADING);
    wide(row, Alignment::LEADING)
        .hover_surface(
            Color::new(1.0, 1.0, 1.0, swiftly_ui::feel::PRESS_ROW_ALPHA),
            0.0,
        )
        .press_style(swiftly_ui::PressStyle::Row)
        .a11y(swiftly_ui::a11y::A11yNode::new(
            "",
            swiftly_ui::a11y::Role::Button,
            format!("{}, {}, {}", r.title, r.under, action),
        ))
        .key(key.as_str())
        .on_tap(Action::from(key.as_str()))
}

/// How high the card is (for the point the picker grows from).
fn card_height(p: &Parts) -> f32 {
    let inner = match &p.mode {
        Mode::Closed => 0.0,
        Mode::Create { .. } => 52.0 + 48.0 + 14.0 + 17.0 + 40.0 + 60.0 + 18.0 + 48.0 + 20.0,
        Mode::Join(_) => 52.0 + 60.0 + 48.0 + 20.0,
        Mode::Pick => 52.0 + 59.0 * p.rows.len() as f32,
        Mode::Failed(_) => 52.0 + 60.0 + 20.0,
        Mode::Exit { .. } | Mode::Receive { .. } => 0.0,
    };
    inner + 51.0
}

/// One frame of the exit: the look and the picture's place in the image page.
#[derive(Clone, PartialEq)]
struct ExitFrame {
    look: ExitLook,
    image: Option<swiftly_ui::ImageId>,
}

/// The sender's picture leaves as a card (`HandoffExit.play`): the app ground, the player's black, the still of the
/// video shrinking to the card on the zoom spring, the two lines under it, then the card flies off the window.
fn exit_view(
    cx: &Cx,
    env: &Env,
    title: &str,
    episode: &str,
    device: &str,
    frame: &ExitFrame,
) -> Node {
    use swiftly_ui::Motion;
    let l = &frame.look;
    let (ww, wh) = (env.size.w, env.size.h);
    let (x, y) = (l.x as f32, l.y as f32);
    let (w, h) = (l.width as f32, l.height as f32);
    let ground = Node::rect(color(colour::REASON), 0.0).opacity(l.ground as f32, Motion::Instant);
    let black =
        Node::rect(Color::new(0.0, 0.0, 0.0, 1.0), 0.0).opacity(l.black as f32, Motion::Instant);
    let picture = match frame.image {
        Some(id) => Node::image(id, w, h, l.corner as f32),
        None => Node::rect(color(colour::AREA), l.corner as f32)
            .paint(Paint::Stroke {
                color: color(colour::LINE),
                width: 1.0,
                radius: l.corner as f32,
            })
            .frame(Some(w), Some(h), Alignment::CENTER),
    }
    .opacity(l.picture as f32, Motion::Instant)
    .offset(x - ww / 2.0, y - wh / 2.0, Motion::Instant);
    let mut layers = vec![
        fill_frame(ground, Alignment::CENTER),
        fill_frame(black, Alignment::CENTER),
        fill_frame(picture, Alignment::CENTER),
    ];
    if l.rows > 0.0 {
        // Left-aligned at the card's width, centred under the card; 3 pt between the lines (`rowsView`).
        let metrics = MAC;
        let mut lines = vec![text(
            cx,
            title,
            st(metrics.title as f32, 600),
            colour::FONT,
            Some(1),
            swiftly_text::Align::Start,
        )];
        if !episode.is_empty() {
            lines.push(text(
                cx,
                episode,
                st(metrics.small as f32, 400),
                colour::FONT_QUIET,
                Some(1),
                swiftly_text::Align::Start,
            ));
        }
        let rows = Node::vstack(Align::Start, Some((metrics.spacing * 0.25) as f32), lines)
            .frame(Some(metrics.width as f32), None, Alignment::TOP_LEADING)
            .padding(ins(
                (l.rows_top as f32 + 2.0 + (metrics.spacing * 0.35) as f32).max(0.0),
                x - (metrics.width as f32) / 2.0,
                0.0,
                0.0,
            ))
            .opacity(l.rows as f32, Motion::Instant);
        layers.push(fill_frame(rows, Alignment::TOP_LEADING));
    }
    Node::zstack(Alignment::CENTER, layers)
        .frame(Some(ww), Some(wh), Alignment::CENTER)
        .a11y(swiftly_ui::a11y::A11yNode::new(
            "",
            swiftly_ui::a11y::Role::Text,
            format!("{title}, {device}"),
        ))
        .key("tg:panel")
}

/// The arriving card (`HandoffStage`): the app ground steps in front of the page, the card grows out of the sidebar row
/// and hovers with its two lines below, then zooms into the picture while the player's black comes in and the stage
/// goes.
fn receive_view(cx: &Cx, env: &Env, title: &str, episode: &str, frame: &ReceiveFrame) -> Node {
    use swiftly_ui::Motion;
    let l = &frame.look;
    let (ww, wh) = (env.size.w, env.size.h);
    let (w, h) = (l.width as f32, l.height as f32);
    let ground = Node::rect(color(colour::REASON), 0.0)
        .opacity((l.ground * l.stage) as f32, Motion::Instant);
    let black = Node::rect(Color::new(0.0, 0.0, 0.0, 1.0), 0.0)
        .opacity((l.black * l.stage) as f32, Motion::Instant);
    let card = Node::rect(color(colour::AREA), l.corner as f32)
        .paint(Paint::Stroke {
            color: color(colour::LINE),
            width: 1.0,
            radius: l.corner as f32,
        })
        .frame(Some(w), Some(h), Alignment::CENTER)
        .opacity((l.card * l.stage) as f32, Motion::Instant)
        .offset(
            l.x as f32 - ww / 2.0,
            l.y as f32 - wh / 2.0,
            Motion::Instant,
        );
    let mut layers = vec![
        fill_frame(ground, Alignment::CENTER),
        fill_frame(black, Alignment::CENTER),
        fill_frame(card, Alignment::CENTER),
    ];
    let lines_opacity = (l.rows * l.stage) as f32;
    if lines_opacity > 0.0 {
        let metrics = MAC;
        let mut lines = vec![text(
            cx,
            title,
            st(metrics.title as f32, 600),
            colour::FONT,
            Some(1),
            swiftly_text::Align::Start,
        )];
        if !episode.is_empty() {
            lines.push(text(
                cx,
                episode,
                st(metrics.small as f32, 400),
                colour::FONT_QUIET,
                Some(1),
                swiftly_text::Align::Start,
            ));
        }
        let left = l.x as f32 - (metrics.width as f32) / 2.0;
        let top = l.rows_top as f32;
        let rows = Node::vstack(Align::Start, Some((metrics.spacing * 0.25) as f32), lines)
            .frame(Some(metrics.width as f32), None, Alignment::TOP_LEADING)
            .padding(ins(
                (top + 2.0 + (metrics.spacing * 0.35) as f32).max(0.0),
                left,
                0.0,
                0.0,
            ))
            .opacity(lines_opacity, Motion::Instant);
        layers.push(fill_frame(rows, Alignment::TOP_LEADING));
        if l.loading {
            // The picture is late: a thin line under the card with a stripe running across it.
            let track = metrics.width as f32;
            let stripe = track * 0.3;
            let at = (frame.travel as f32) * (track + stripe) - stripe;
            let (from, to) = (at.max(0.0), (at + stripe).min(track));
            let line = Node::rect(color(colour::LINE), 1.0).frame(
                Some(track),
                Some(2.0),
                Alignment::TOP_LEADING,
            );
            let run = Node::rect(color(colour::MARK_ACCENT), 1.0)
                .frame(
                    Some((to - from).max(0.0)),
                    Some(2.0),
                    Alignment::TOP_LEADING,
                )
                .padding(ins(0.0, from, 0.0, 0.0));
            let bar = Node::zstack(Alignment::TOP_LEADING, vec![line, run])
                .padding(ins(top, left, 0.0, 0.0))
                .opacity(lines_opacity, Motion::Instant);
            layers.push(fill_frame(bar, Alignment::TOP_LEADING));
        }
    }
    Node::zstack(Alignment::CENTER, layers)
        .frame(Some(ww), Some(wh), Alignment::CENTER)
        .a11y(swiftly_ui::a11y::A11yNode::new(
            "",
            swiftly_ui::a11y::Role::Text,
            title.to_owned(),
        ))
        .key("tg:panel")
}

fn view(p: &Parts, env: &Env, cx: &Cx, icons: &Icons) -> Node {
    if p.mode == Mode::Closed {
        return Node::fixed(0.0, 0.0);
    }
    if let Mode::Receive {
        title,
        line: episode,
        ..
    } = &p.mode
    {
        return match &p.receive {
            Some(frame) => receive_view(cx, env, title, episode, frame),
            None => Node::fixed(0.0, 0.0),
        };
    }
    if let Mode::Exit {
        title,
        line: episode,
        device,
        ..
    } = &p.mode
    {
        return match &p.exit {
            Some(frame) => exit_view(cx, env, title, episode, device, frame),
            None => Node::fixed(0.0, 0.0),
        };
    }
    let w = desktop::FORM_WIDTH;
    let mut col: Vec<Node> = Vec::new();
    match &p.mode {
        Mode::Closed | Mode::Exit { .. } | Mode::Receive { .. } => {}
        Mode::Create { line: what, .. } => {
            col.push(heading(cx, "Gemeinsam schauen"));
            let mut c = vec![
                body(cx, what, 14.0, colour::FONT_QUIET, 2).padding(ins(0.0, 0.0, 16.0, 0.0)),
                body(cx, "Name der Gruppe", 12.0, colour::FONT_VERY_QUIET, 1)
                    .padding(ins(0.0, 0.0, 6.0, 0.0)),
            ];
            let field = Node::hstack(
                Align::Center,
                Some(0.0),
                vec![
                    swiftly_ui::field::field_content(cx, &p.field, &look()),
                    Node::spacer(),
                ],
            )
            .padding(EdgeInsets::symmetric(12.0, 0.0))
            .frame(None, Some(desktop::BUTTON_FIELD), Alignment::LEADING);
            c.push(
                wide(field, Alignment::LEADING)
                    .background(
                        Node::rect(color(colour::RAISED), desktop::CORNER_FIELD),
                        Alignment::CENTER,
                    )
                    .a11y(swiftly_ui::a11y::A11yNode::new(
                        "tg:field",
                        swiftly_ui::a11y::Role::TextField,
                        "Name der Gruppe",
                    )),
            );
            c.push(
                body(
                    cx,
                    "Alle auf deinem Server sehen die Gruppe und können mit einsteigen. Pause und Springen gelten dann für alle.",
                    14.0,
                    colour::FONT_QUIET,
                    4,
                )
                .padding(ins(14.0, 0.0, 18.0, 0.0)),
            );
            c.push(primary(
                cx,
                icons,
                "tg:open",
                "Gruppe öffnen",
                "users.fill",
                !p.works,
            ));
            col.push(Node::vstack(Align::Start, Some(0.0), c).padding(ins(0.0, 20.0, 20.0, 20.0)));
        }
        Mode::Join(g) => {
            col.push(heading(cx, &g.name));
            let mut c = vec![body(cx, &g.who, 14.0, colour::FONT_QUIET, 2)];
            if let Some(state) = &g.state_text {
                c.push(
                    body(cx, state, 12.0, colour::MARK_ACCENT, 1).padding(ins(6.0, 0.0, 0.0, 0.0)),
                );
            }
            c.push(
                body(
                    cx,
                    "Pause und Springen gelten für alle.",
                    12.0,
                    colour::FONT_VERY_QUIET,
                    2,
                )
                .padding(ins(10.0, 0.0, 18.0, 0.0)),
            );
            c.push(primary(
                cx,
                icons,
                "tg:join",
                "Beitreten",
                "users.fill",
                !p.works,
            ));
            col.push(Node::vstack(Align::Start, Some(0.0), c).padding(ins(0.0, 20.0, 20.0, 20.0)));
        }
        Mode::Pick => {
            col.push(heading(cx, "Läuft gerade"));
            for (i, r) in p.rows.iter().enumerate() {
                col.push(line(w));
                col.push(pick_row(cx, icons, i, r));
            }
        }
        Mode::Failed(message) => {
            col.push(heading(cx, "Weiterschauen"));
            col.push(
                body(cx, message, 14.0, colour::FONT_QUIET, 4).padding(ins(0.0, 20.0, 20.0, 20.0)),
            );
        }
    }
    col.push(line(w));
    col.push(
        wide(
            text(
                cx,
                "Abbrechen",
                st(14.0, 400),
                colour::FONT_QUIET,
                Some(1),
                swiftly_text::Align::Center,
            ),
            Alignment::CENTER,
        )
        .frame(None, Some(50.0), Alignment::CENTER)
        .hover_surface(
            Color::new(1.0, 1.0, 1.0, swiftly_ui::feel::PRESS_ROW_ALPHA),
            0.0,
        )
        .press_style(swiftly_ui::PressStyle::Row)
        .a11y(swiftly_ui::a11y::A11yNode::new(
            "",
            swiftly_ui::a11y::Role::Button,
            "Abbrechen",
        ))
        .key("tg:cancel")
        .on_tap(Action::from("tg:cancel")),
    );
    let card = Node::vstack(Align::Start, Some(0.0), col)
        .frame(Some(w), None, Alignment::TOP_LEADING)
        .background(
            Node::rect(color(colour::AREA), desktop::CORNER_AREA).paint(Paint::Stroke {
                color: color(colour::LINE),
                width: 1.0,
                radius: desktop::CORNER_AREA,
            }),
            Alignment::CENTER,
        )
        // The card swallows taps on its own face; as a plain group its buttons stay reachable by name (a tappable
        // node without a description would merge every word of the panel into one button).
        .a11y(swiftly_ui::a11y::A11yNode::new(
            "tg:card",
            swiftly_ui::a11y::Role::Group,
            "",
        ))
        .on_tap_silent(Action::from("tg:nop"));
    // The picker grows out of the sidebar row (the spring); create and join fade in at 0.97 (the leap).
    let pick = p.mode == Mode::Pick;
    let (motion, from) = if pick {
        (swiftly_ui::feel::default_spring(), 0.5)
    } else {
        (swiftly_ui::feel::leap(), 0.97)
    };
    let card_x = ((env.size.w - w) / 2.0).max(0.0);
    let card_y = ((env.size.h - card_height(p)) / 2.0).max(0.0);
    let pivot = if pick {
        (p.origin.0 - card_x, p.origin.1 - card_y)
    } else {
        (w / 2.0, card_height(p) / 2.0)
    };
    let card = card
        .scaled(1.0, motion)
        .appear_from(from, 0.0)
        .exit_to(from, 0.0)
        .opacity(1.0, motion)
        .scale_about(pivot.0, pivot.1)
        .key("tg:card");
    let scrim = Node::rect(rgba(colour::REASON, 0.62), 0.0)
        .opacity(1.0, swiftly_ui::feel::leap())
        .key("tg:scrim")
        .on_tap(Action::from("tg:cancel"));
    Node::zstack(
        Alignment::CENTER,
        vec![
            fill_frame(scrim, Alignment::CENTER),
            fill_frame(card, Alignment::CENTER),
        ],
    )
    .frame(Some(env.size.w), Some(env.size.h), Alignment::CENTER)
    .key("tg:panel")
}

impl TogetherUi {
    /// A panel for `env`.
    pub fn new(env: Env, cx: Cx) -> TogetherUi {
        let icons = Icons::new(&cx, env.scale);
        let field = FieldState::new(TextEditor::single_line());
        let parts = Parts {
            mode: Mode::Closed,
            rows: Vec::new(),
            field: field.view(DEFAULT_NAME, false, 0.0),
            works: false,
            origin: (0.0, 0.0),
            exit: None,
            receive: None,
        };
        let ui = Ui::new(
            move |p: &Parts, env: &Env, cx: &Cx| view(p, env, cx, &icons),
            parts,
            env,
            cx,
        );
        TogetherUi {
            ui,
            mode: Mode::Closed,
            rows: Vec::new(),
            field,
            clip: Box::new(crate::field_book::SystemClipboard),
            works: false,
            origin: (0.0, 0.0),
            acts: Vec::new(),
            now: 0.0,
            run: None,
            arrival: None,
        }
    }

    /// A new window size or scale.
    pub fn set_env(&mut self, env: Env) {
        self.ui.set_env(env);
    }

    /// The panel that is up.
    pub fn mode(&self) -> &Mode {
        &self.mode
    }

    /// Whether a panel is up (it takes every click and key).
    pub fn open(&self) -> bool {
        self.mode.open()
    }

    /// Opens a panel. The name field starts as "Filmabend" with the keyboard.
    pub fn show(&mut self, mode: Mode) {
        if let Mode::Create { .. } = mode {
            self.field = FieldState::new(TextEditor::single_line());
            self.field.editor.set_text(DEFAULT_NAME);
            self.field.set_focused(true, self.now);
        } else {
            self.field.set_focused(false, self.now);
        }
        self.run = None;
        self.arrival = None;
        if let Mode::Receive { .. } = &mode {
            let size = self.ui.env().size;
            self.arrival = Some(ArrivalRun {
                since: None,
                plan: ReceivePlan::new((size.w, size.h), self.origin, self.ui.env().reduce_motion),
                up: None,
                zoom_at: None,
                cancelled: None,
            });
        }
        if let Mode::Exit { still, top, .. } = &mode {
            let size = self.ui.env().size;
            let pages = still
                .as_ref()
                .map_or(16.0 / 9.0, |s| f64::from(s.w) / f64::from(s.h.max(1)));
            let plan = ExitPlan::new((size.w, size.h), pages, *top, self.ui.env().reduce_motion);
            let slot = still.as_ref().and_then(|s| {
                let mut images = self.ui.cx().images.borrow_mut();
                let slot = images.reserve(s.w, s.h)?;
                images.rewrite(&slot, s.w, s.h, &s.rgba).then_some(slot)
            });
            self.run = Some(ExitRun {
                since: None,
                plan,
                slot,
            });
        }
        self.mode = mode;
    }

    /// Closes the panel.
    pub fn close(&mut self) {
        self.field.set_focused(false, self.now);
        self.mode = Mode::Closed;
        self.run = None;
        self.arrival = None;
    }

    /// Whether the arriving card is up (it draws over the player too).
    pub fn receiving(&self) -> bool {
        self.arrival.is_some()
    }

    fn arrival_seconds(&self) -> Option<f64> {
        let a = self.arrival.as_ref()?;
        Some((self.now - a.since?) / 1000.0)
    }

    /// The player opened under the card: from here it waits at most [`AT_MOST_WAIT`] for the first frame
    /// (`HandoffStage.playerComes`).
    pub fn receive_player_up(&mut self) {
        let t = self.arrival_seconds();
        if let Some(a) = self.arrival.as_mut()
            && a.up.is_none()
        {
            a.up = Some(t.unwrap_or(0.0));
        }
    }

    /// The first frame of the player is up: the card zooms into it, at the earliest when its hover has begun
    /// (`HandoffStage.imagePresent`).
    pub fn receive_picture(&mut self) {
        let t = self.arrival_seconds().unwrap_or(0.0);
        if let Some(a) = self.arrival.as_mut()
            && a.zoom_at.is_none()
            && a.cancelled.is_none()
        {
            a.zoom_at = Some(a.plan.zoom_at(t));
        }
    }

    /// The takeover failed or the player closed under the card: the stage fades out (`HandoffStage.cancel`).
    pub fn receive_cancel(&mut self) {
        let t = self.arrival_seconds().unwrap_or(0.0);
        if let Some(a) = self.arrival.as_mut()
            && a.zoom_at.is_none()
            && a.cancelled.is_none()
        {
            a.cancelled = Some(t);
        }
    }

    /// The arrival is through (nothing is left of the stage).
    pub fn receive_over(&self) -> bool {
        let (Some(a), Some(t)) = (self.arrival.as_ref(), self.arrival_seconds()) else {
            return false;
        };
        match (a.cancelled, a.zoom_at) {
            (Some(c), _) => t >= c + FADE + 0.05,
            (None, Some(z)) => t >= a.plan.end(z) + 0.05,
            _ => false,
        }
    }

    /// The arrival for tests: its plan, the seconds since the tap and when the zoom began.
    pub fn arrival_plan(&self) -> Option<(ReceivePlan, f64, Option<f64>)> {
        let a = self.arrival.as_ref()?;
        Some((a.plan, self.arrival_seconds()?, a.zoom_at))
    }

    /// The exit card is through (nothing is left of the stage).
    pub fn exit_over(&self) -> bool {
        self.run.as_ref().is_some_and(|r| {
            r.since
                .is_some_and(|s| r.plan.look((self.now - s) / 1000.0).over)
        })
    }

    /// The exit that plays, for tests: its plan and the seconds since the stop.
    pub fn exit_plan(&self) -> Option<(ExitPlan, f64)> {
        let r = self.run.as_ref()?;
        Some((r.plan, (self.now - r.since?) / 1000.0))
    }

    /// The rows of the picker.
    pub fn set_rows(&mut self, rows: Vec<PickRow>) {
        self.rows = rows;
    }

    /// The channel is busy: the button of create and join waits.
    pub fn set_works(&mut self, works: bool) {
        self.works = works;
    }

    /// Where the picker grows from (the middle of the sidebar row).
    pub fn set_origin(&mut self, x: f32, y: f32) {
        self.origin = (x, y);
    }

    /// What the user chose since the last call.
    pub fn take_acts(&mut self) -> Vec<Act> {
        std::mem::take(&mut self.acts)
    }

    fn sync(&mut self) {
        self.ui.set_parts(Parts {
            mode: self.mode.clone(),
            rows: self.rows.clone(),
            field: self.field.view(DEFAULT_NAME, false, self.now),
            works: self.works,
            origin: self.origin,
            exit: self.run.as_ref().and_then(|r| {
                let t = (self.now - r.since?) / 1000.0;
                Some(ExitFrame {
                    look: r.plan.look(t),
                    image: r.slot.map(|s| s.id),
                })
            }),
            receive: self.arrival.as_ref().and_then(|a| {
                let t = (self.now - a.since?) / 1000.0;
                let mut look = a.plan.look(t, a.zoom_at);
                if let Some(c) = a.cancelled {
                    look.stage = 1.0 - ((t - c) / FADE).clamp(0.0, 1.0);
                }
                Some(ReceiveFrame {
                    look,
                    travel: (t * LOADING_BAR_TICK).fract(),
                })
            }),
        });
    }

    fn drain(&mut self) {
        for ev in self.ui.take_events() {
            let UiEvent::Tap(a) = ev else { continue };
            let is = |k: &str| a == Action::from(k);
            if is("tg:cancel") {
                self.acts.push(Act::Cancel);
            } else if is("tg:open") || is("tg:join") {
                self.confirm();
            } else if let Some(i) = (0..self.rows.len()).find(|i| is(&format!("tg:pick:{i}"))) {
                self.acts.push(match &self.rows[i].target {
                    PickTarget::Session(id) => Act::Take(id.clone()),
                    PickTarget::Group(g) => Act::Join(g.clone()),
                });
            }
        }
    }

    /// Return: opens the group or joins it.
    pub fn confirm(&mut self) {
        if self.works {
            return;
        }
        match self.mode.clone() {
            Mode::Create { title_id, .. } => {
                self.acts.push(Act::Create {
                    name: self.field.editor.text().to_owned(),
                    title_id,
                });
            }
            Mode::Join(g) => self.acts.push(Act::Join(g)),
            _ => {}
        }
    }

    /// Escape.
    pub fn escape(&mut self) {
        self.acts.push(Act::Cancel);
    }

    /// A press.
    pub fn touch_down(&mut self, x: f32, y: f32, now: f64) {
        self.now = now;
        self.sync();
        self.ui.touch_down(x, y, now);
        self.drain();
    }

    /// The pointer moves (also while pressed).
    pub fn touch_move(&mut self, x: f32, y: f32, now: f64) {
        self.now = now;
        self.ui.touch_move(x, y, now);
        self.ui.pointer_move(x, y, now);
    }

    /// The press ends.
    pub fn touch_up(&mut self, x: f32, y: f32, now: f64) {
        self.now = now;
        self.ui.touch_up(x, y, now);
        self.drain();
    }

    /// The pointer moves without a button.
    pub fn pointer_move(&mut self, x: f32, y: f32, now: f64) {
        self.now = now;
        self.ui.pointer_move(x, y, now);
    }

    /// The pointer left the window.
    pub fn pointer_leave(&mut self, now: f64) {
        self.ui.pointer_leave(now);
    }

    /// Whether the name field has the keyboard.
    pub fn wants_text(&self) -> bool {
        matches!(self.mode, Mode::Create { .. }) && self.field.focused
    }

    /// One edit event for the name field; Return confirms.
    pub fn text_event(&mut self, ev: &TextInputEvent) -> bool {
        if !self.wants_text() {
            return false;
        }
        let out = self.field.apply(ev, self.clip.as_mut(), self.now);
        if out.submitted {
            self.confirm();
        }
        true
    }

    /// Typed characters.
    pub fn type_text(&mut self, s: &str) {
        let _ = self.text_event(&TextInputEvent::Text(s.to_owned()));
    }

    /// Backspace in the name field.
    pub fn backspace(&mut self) {
        let _ = self.text_event(&TextInputEvent::Key(
            swiftly_text::EditKey::Backspace,
            swiftly_text::Mods::default(),
        ));
    }

    /// The text of the name field.
    pub fn name(&self) -> &str {
        self.field.editor.text()
    }

    /// One frame: the scrim and the card, empty when nothing is open. The second value asks for another frame.
    pub fn frame(&mut self, now: f64) -> (DrawList, bool) {
        self.now = now;
        if let Some(r) = self.run.as_mut() {
            r.since.get_or_insert(now);
        }
        if let Some(a) = self.arrival.as_mut() {
            let since = *a.since.get_or_insert(now);
            // No first frame: the card lets go anyway once the player has had its time (`playerComes`).
            let t = (now - since) / 1000.0;
            if a.zoom_at.is_none()
                && a.cancelled.is_none()
                && a.up.is_some_and(|u| t >= u + AT_MOST_WAIT)
            {
                a.zoom_at = Some(a.plan.zoom_at(t));
            }
        }
        self.sync();
        let list = self.ui.frame(now);
        self.drain();
        let more = self.ui.needs_frame()
            || self.wants_text()
            || self.run.is_some()
            || self.arrival.is_some();
        (list, more)
    }

    /// Whether another frame is wanted (an animation or the caret).
    pub fn wants_frame(&self) -> bool {
        self.ui.needs_frame() || self.wants_text() || self.run.is_some() || self.arrival.is_some()
    }

    /// The keyboard rectangle of the name field for the input method: the field's origin.
    pub fn field_origin(&self) -> Option<[f32; 4]> {
        self.ui.frame_of(swiftly_ui::field::CONTENT_KEY)
    }

    /// The frame `[x, y, w, h]` of a keyed node (tests, the input method).
    pub fn frame_of(&self, key: &str) -> Option<[f32; 4]> {
        self.ui.frame_of(key)
    }

    /// Renders a list with the software renderer over black.
    pub fn render_software(&self, list: &DrawList) -> swiftly_render::RgbaImage {
        self.ui.render(list, Color::BLACK)
    }

    /// The services of the renderers.
    pub fn cx(&self) -> &Cx {
        self.ui.cx()
    }

    /// The accessibility nodes of the open panel.
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.ui.a11y_nodes()
    }
}

#[cfg(test)]
mod receive_tests {
    use super::*;
    use swiftly_playback::handoff_card::FLOAT;

    fn plan() -> ReceivePlan {
        ReceivePlan::new((1280.0, 800.0), (130.0, 700.0), false)
    }

    #[test]
    fn the_card_grows_out_of_the_badge_hovers_and_zooms_into_the_picture() {
        let p = plan();
        let first = p.look(0.0, None);
        // At the tap: at the sidebar row, badge-sized, not yet visible.
        assert!((first.x - 130.0).abs() < 0.01 && (first.y - 700.0).abs() < 0.01);
        assert!(
            (first.width - BADGE_WIDTH).abs() < 0.01 && first.card == 0.0 && first.ground == 0.0
        );
        // Flying and hovering: visible, the lines are in, nothing black yet.
        let mid = p.look(0.3, None);
        assert!(mid.width > first.width && mid.width < p.idle.width && mid.card == 1.0);
        let rest = p.look(1.5, None);
        assert!((rest.width - p.idle.width).abs() < 1.0);
        assert!(rest.rows == 1.0 && rest.black == 0.0 && rest.stage == 1.0 && !rest.over);
        // The zoom waits for the hover (`zoom_start`), then runs to the full picture and the stage goes.
        assert!((p.zoom_at(0.1) - FLOAT).abs() < 1e-9 || p.zoom_at(0.1) >= 0.7);
        let z = p.zoom_at(1.5);
        let end = p.look(z + END, Some(z));
        assert!((end.width - p.full.width).abs() < 1.0 && end.over && end.stage < 0.01);
        assert!(p.look(z + 0.3, Some(z)).black > 0.9);
    }

    #[test]
    fn with_reduced_motion_the_card_only_fades() {
        let p = ReceivePlan::new((1280.0, 800.0), (130.0, 700.0), true);
        let (a, b) = (p.look(0.0, None), p.look(2.0, None));
        assert_eq!((a.x, a.y, a.width), (b.x, b.y, b.width));
        assert!(a.card < b.card && b.card == 1.0);
        let z = p.zoom_at(2.0);
        assert!(p.look(z + FADE_OUT + 0.01, Some(z)).over);
    }
}
