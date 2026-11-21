//! The pages of the server management on the desktop: the server page (`ServerAdminPart`), the log pages
//! (`ServerLogsPart`) and the Profile row. Everything shown comes from the core's finished page objects (counts, task
//! progress, stream cards, load and drives, the actions with their texts, the question before a restart); this file only
//! places them with the desktop's form components. Two columns where the window allows it (`forms::settings_page`).
//!
//! Keys: `admin:scan`, `admin:restart`, `admin:logs`, `admin:retry`, `admin:stop-task:{id}`, `admin:stop-stream:{session}`,
//! `admin:ask.ok`, `admin:ask.cancel`, `admin:log:{i}`, `go:management` (the Profile row), `hub:tab:{n}` (the tab row). Every stream card has the key
//! `admin:card:{id}` (session and title), so a card that stays keeps its poster while the numbers move.

use crate::browse::wide;
use crate::forms::{self, Cols, Fm, Trail};
use crate::home::{ins, tabular_text, text};
use crate::hub::HubSlot;
use crate::management_hub::Dest;
use crate::server_admin_link::{poster_address, user_address};
use std::sync::Arc;
use swiftly_design::tokens_generated::color;
use swiftly_images::ImageAddress;
use swiftly_layout::{Align, Alignment};
use swiftly_render::Color;
use swiftly_ui::components::color;
use swiftly_ui::icons::Icons;
use swiftly_ui::{Action, Cx, Env, Node};
use swiftly_vm::{
    ImageKind, ImageRef, ProfileEntry, ProfileEntryKind, ServerAction, ServerActionKind,
    ServerAdminAsk, ServerAdminPage, ServerAdminPart, ServerAdminState, ServerBadgeKind,
    ServerLoadView, ServerLogsPart, ServerLogsState, ServerStreamCard,
};

/// What the pages draw (part of the settings screen's `Parts`: a change rebuilds the page).
#[derive(Clone, PartialEq)]
pub struct AdminView {
    /// The server page.
    pub part: Arc<ServerAdminPart>,
    /// The log pages.
    pub logs: Arc<ServerLogsPart>,
    /// For posters and viewer pictures.
    pub images: Option<ImageAddress>,
    /// The one Profile entry (`profile_entry`), when the account has one.
    pub entry: Option<ProfileEntry>,
    /// The management page's tab row with "Server" on (`management_hub::tabs`); empty for a single section.
    pub tabs: Vec<(Dest, String, bool)>,
}

fn style(size: f32, weight: u16) -> swiftly_design::TextStyle {
    swiftly_design::TextStyle {
        size,
        weight,
        tracking: 0.0,
        uppercase: false,
    }
}

/// `Colors.originalWarning`: transcoding and a nearly full drive.
const WARNING: swiftly_design::Colour = swiftly_design::Colour {
    r: 0.910,
    g: 0.514,
    b: 0.227,
    a: 1.0,
    rgba8: 0xE883_3AFF,
};

fn rgb(r: f32, g: f32, b: f32) -> Color {
    Color::new(r, g, b, 1.0)
}

/// The Profile's one management group (`ProfileEntry`): "Verwaltung" for an administrator with what waits as its second
/// line and as the count, "Meine Anfragen" for everyone else with Seerr. The row opens the page behind it (`go:management`).
pub fn profile_group(cx: &Cx, icons: &Icons, f: &Fm, entry: &ProfileEntry) -> Node {
    let (symbol, trail) = match entry.kind {
        ProfileEntryKind::Admin if entry.count > 0 => {
            ("hard-drives", Trail::ValueChevron(entry.count.to_string()))
        }
        ProfileEntryKind::Admin => ("hard-drives", Trail::Chevron),
        ProfileEntryKind::Mine => ("arrow-circle-down", Trail::Chevron),
    };
    forms::setting_group(
        cx,
        f,
        "",
        forms::GROUP_GAP,
        vec![forms::row_kb(
            cx,
            icons,
            f,
            "go:management",
            symbol,
            &entry.title,
            entry.under.as_deref(),
            trail,
            true,
        )],
    )
}

/// The height of the tab row with its gap below.
const TAB_ROW_H: f32 = 46.0;

/// The tab row of the management page (`hub:tab:{n}`), the same capsules as the Seerr pages draw.
pub fn hub_tabs(cx: &Cx, tabs: &[(Dest, String, bool)]) -> Node {
    let pills: Vec<Node> = tabs
        .iter()
        .enumerate()
        .map(|(n, (_, label, on))| {
            let key = format!("hub:tab:{n}");
            let (fg, bg) = if *on {
                (color::SURFACE_BASE, color::TEXT_PRIMARY)
            } else {
                (color::TEXT_SECONDARY, color::SURFACE_CONTROL)
            };
            text(
                cx,
                label,
                style(13.0, 600),
                fg,
                Some(1),
                swiftly_text::Align::Start,
            )
            .padding(ins(7.0, 14.0, 7.0, 14.0))
            .background(Node::rect(color(bg), 16.0), Alignment::CENTER)
            .key(key.as_str())
            .on_tap(Action::from(key.as_str()))
            .a11y_label(swiftly_ui::a11y::Role::Button, label.clone())
        })
        .collect();
    Node::hstack(Align::Center, Some(8.0), pills).padding(ins(0.0, 0.0, 14.0, 0.0))
}

/// A progress line: `share` 0...1 of `w` points, 4 high, rounded.
fn bar(share: f64, w: f32, fill: Color) -> Node {
    let share = share.clamp(0.0, 1.0) as f32;
    let track = Node::rect(Color::new(1.0, 1.0, 1.0, 0.12), 2.0).frame(
        Some(w),
        Some(4.0),
        Alignment::LEADING,
    );
    if share <= 0.0 {
        return track;
    }
    track.overlay(
        Node::rect(fill, 2.0).frame(Some((w * share).max(4.0)), Some(4.0), Alignment::LEADING),
        Alignment::LEADING,
    )
}

fn accent() -> Color {
    color(crate::look_glow::accent())
}

/// A label on the left, a value on the right, the line under them (a task, the load, a drive).
fn meter_row(
    cx: &Cx,
    label: &str,
    value: &str,
    share: f64,
    w: f32,
    warn: bool,
    trail: Option<Node>,
) -> Node {
    let tone = if warn {
        color::STATE_ERROR
    } else {
        color::TEXT_SECONDARY
    };
    let head = Node::hstack(
        Align::Center,
        Some(8.0),
        vec![
            text(
                cx,
                label,
                style(15.0, 500),
                color::TEXT_PRIMARY,
                Some(1),
                swiftly_text::Align::Start,
            )
            .layout_priority(1.0),
            Node::spacer(),
            tabular_text(
                cx,
                value,
                style(13.0, 400),
                tone,
                Some(1),
                swiftly_text::Align::End,
            ),
        ],
    );
    let line = bar(
        share,
        w - 32.0,
        if warn { color(WARNING) } else { accent() },
    );
    let col = Node::vstack(
        Align::Start,
        Some(10.0),
        vec![wide(head, Alignment::LEADING), line],
    );
    let col = col.padding(ins(14.0, 16.0, 14.0, 16.0));
    match trail {
        Some(t) => Node::hstack(
            Align::Center,
            Some(0.0),
            vec![wide(col, Alignment::LEADING), t],
        ),
        None => wide(col, Alignment::LEADING),
    }
}

/// "Server": the name with its version, then the counts and (when known) the resolutions in rows of three.
fn server_group(cx: &Cx, f: &Fm, page: &ServerAdminPage, col_w: f32) -> Node {
    let head = Node::hstack(
        Align::Center,
        Some(6.0),
        vec![
            text(
                cx,
                &page.name,
                style(15.0, 700),
                color::TEXT_PRIMARY,
                Some(1),
                swiftly_text::Align::Start,
            )
            .layout_priority(1.0),
            text(
                cx,
                &page.version,
                style(15.0, 500),
                color::TEXT_TERTIARY,
                Some(1),
                swiftly_text::Align::Start,
            ),
            Node::spacer(),
        ],
    )
    .padding(ins(14.0, 16.0, 14.0, 16.0));
    let cell_w = ((col_w - 8.0 - 32.0) / 3.0).floor();
    let numbers = |list: &[swiftly_vm::ServerNumber]| -> Node {
        let cells = list
            .iter()
            .map(|n| {
                Node::vstack(
                    Align::Start,
                    Some(2.0),
                    vec![
                        tabular_text(
                            cx,
                            &n.text,
                            style(22.0, 700),
                            color::TEXT_PRIMARY,
                            Some(1),
                            swiftly_text::Align::Start,
                        ),
                        text(
                            cx,
                            &n.label,
                            style(13.0, 400),
                            color::TEXT_SECONDARY,
                            Some(1),
                            swiftly_text::Align::Start,
                        ),
                    ],
                )
                .frame(Some(cell_w), None, Alignment::LEADING)
            })
            .collect();
        wide(
            Node::hstack(Align::Start, Some(0.0), cells).padding(ins(14.0, 16.0, 14.0, 16.0)),
            Alignment::LEADING,
        )
    };
    let mut rows = vec![wide(head, Alignment::LEADING), numbers(&page.counts)];
    if !page.resolutions.is_empty() {
        rows.push(numbers(&page.resolutions));
    }
    forms::setting_group_at(cx, f, &page.server_title, 0.0, rows, 0.0)
}

/// "Aufgaben": the running tasks with their progress, each with a button that asks before it stops the task.
fn tasks_group(cx: &Cx, icons: &Icons, f: &Fm, page: &ServerAdminPage, col_w: f32) -> Node {
    let rows = page
        .tasks
        .iter()
        .map(|t| {
            let stop = icons
                .node("x-circle", 22.0, true, color(color::TEXT_SECONDARY))
                .frame(Some(44.0), Some(44.0), Alignment::CENTER);
            let stop = forms::tappable_kb(stop, f, &format!("admin:stop-task:{}", t.id), 22.0)
                .hover_surface(
                    crate::home::rgba(color::TEXT_PRIMARY, swiftly_ui::feel::HOVER_SURFACE_ALPHA),
                    22.0,
                )
                .padding(ins(0.0, 0.0, 0.0, 8.0));
            meter_row(
                cx,
                &t.name,
                t.progress_text.as_deref().unwrap_or(""),
                t.progress.unwrap_or(0.0),
                col_w - 8.0 - 52.0,
                false,
                Some(stop),
            )
        })
        .collect();
    forms::setting_group_at(cx, f, &page.tasks_title, 26.0, rows, 0.0)
}

fn badge_colour(kind: ServerBadgeKind) -> Color {
    match kind {
        ServerBadgeKind::Resolution => rgb(0.494, 0.231, 0.718),
        ServerBadgeKind::Range => rgb(0.471, 0.298, 0.157),
        ServerBadgeKind::Video => rgb(0.247, 0.298, 0.616),
        ServerBadgeKind::Audio => rgb(0.231, 0.231, 0.251),
    }
}

/// A poster through the hub (one picture per address, so a card that stays keeps its picture), else the plain ground.
fn poster(hub: &HubSlot, address: Option<&str>, w: f32, h: f32, radius: f32) -> Node {
    let hub = hub.borrow().clone();
    match (hub, address) {
        (Some(hub), Some(a)) => hub.node(
            Some(&ImageRef {
                address: a.to_owned(),
                kind: ImageKind::Poster,
                wanted_width: (w * 2.0) as u32,
                wanted_height: (h * 2.0) as u32,
            }),
            w,
            h,
            radius,
        ),
        _ => Node::rect(color(color::SURFACE_CONTROL), radius).frame(
            Some(w),
            Some(h),
            Alignment::CENTER,
        ),
    }
}

/// One "Wiedergaben" card: poster, title, who watches, badges, device, position, how it is delivered.
fn stream_card(
    cx: &Cx,
    icons: &Icons,
    f: &Fm,
    hub: &HubSlot,
    images: Option<&ImageAddress>,
    s: &ServerStreamCard,
    col_w: f32,
) -> Node {
    let ph = if s.square_poster { 92.0 } else { 138.0 };
    let pic = poster(
        hub,
        images
            .and_then(|i| poster_address(i, &s.poster_id, s.poster_tag.as_deref(), ph))
            .as_deref(),
        92.0,
        ph,
        8.0,
    )
    .padding(ins(8.0, 8.0, 8.0, 8.0));
    let who = {
        let initial = s
            .user_name
            .chars()
            .next()
            .map(String::from)
            .unwrap_or_default();
        let letter = || {
            text(
                cx,
                &initial,
                style(11.0, 600),
                color::TEXT_SECONDARY,
                Some(1),
                swiftly_text::Align::Center,
            )
        };
        let avatar = crate::hub::avatar_node(
            hub,
            images
                .zip(s.user_id.as_deref())
                .and_then(|(i, id)| user_address(i, id, s.user_image_tag.as_deref(), 22.0))
                .as_deref(),
            22.0,
            letter,
        )
        .frame(Some(22.0), Some(22.0), Alignment::CENTER)
        .background(
            Node::rect(color(color::SURFACE_CONTROL), 11.0),
            Alignment::CENTER,
        );
        Node::hstack(
            Align::Center,
            Some(6.0),
            vec![
                avatar,
                text(
                    cx,
                    &s.user_name,
                    style(13.0, 500),
                    color::TEXT_SECONDARY,
                    Some(1),
                    swiftly_text::Align::Start,
                ),
            ],
        )
    };
    let stop = icons
        .node("x-circle", 20.0, true, color(color::TEXT_SECONDARY))
        .frame(Some(32.0), Some(32.0), Alignment::CENTER);
    let stop = forms::tappable_kb(
        stop,
        f,
        &format!("admin:stop-stream:{}", s.session_id),
        16.0,
    )
    .hover_surface(
        crate::home::rgba(color::TEXT_PRIMARY, swiftly_ui::feel::HOVER_SURFACE_ALPHA),
        16.0,
    );
    let mut title_line = vec![
        text(
            cx,
            &s.title,
            style(15.0, 700),
            color::TEXT_PRIMARY,
            Some(1),
            swiftly_text::Align::Start,
        )
        .layout_priority(1.0),
    ];
    if let Some(a) = &s.addition {
        title_line.push(text(
            cx,
            a,
            style(13.0, 500),
            color::TEXT_TERTIARY,
            Some(1),
            swiftly_text::Align::Start,
        ));
    }
    title_line.push(Node::spacer());
    title_line.push(who);
    title_line.push(stop);
    let mut col = vec![wide(
        Node::hstack(Align::Center, Some(8.0), title_line),
        Alignment::LEADING,
    )];
    if let Some(sub) = &s.subtitle {
        col.push(wide(
            text(
                cx,
                sub,
                style(13.0, 400),
                color::TEXT_SECONDARY,
                Some(1),
                swiftly_text::Align::Start,
            ),
            Alignment::LEADING,
        ));
    }
    if !s.badges.is_empty() {
        let badges = s
            .badges
            .iter()
            .map(|b| {
                text(
                    cx,
                    &b.text,
                    style(11.0, 700),
                    color::TEXT_PRIMARY,
                    Some(1),
                    swiftly_text::Align::Center,
                )
                .padding(ins(2.0, 7.0, 2.0, 7.0))
                .background(Node::rect(badge_colour(b.kind), 5.0), Alignment::CENTER)
            })
            .collect();
        col.push(wide(
            Node::hstack(Align::Center, Some(5.0), badges),
            Alignment::LEADING,
        ));
    }
    col.push(wide(
        text(
            cx,
            &s.device_line,
            style(12.0, 400),
            color::TEXT_TERTIARY,
            Some(1),
            swiftly_text::Align::Start,
        ),
        Alignment::LEADING,
    ));
    let content_w = col_w - 8.0 - 8.0 - 92.0 - 8.0 - 28.0;
    let glyph = icons.node(
        if s.paused { "pause" } else { "play" },
        11.0,
        false,
        color(color::TEXT_SECONDARY),
    );
    col.push(wide(
        Node::hstack(
            Align::Center,
            Some(6.0),
            vec![
                glyph,
                tabular_text(
                    cx,
                    &s.time_line,
                    style(12.0, 500),
                    color::TEXT_SECONDARY,
                    Some(1),
                    swiftly_text::Align::Start,
                ),
            ],
        ),
        Alignment::LEADING,
    ));
    col.push(bar(
        s.share,
        content_w,
        if s.paused {
            color(color::TEXT_TERTIARY)
        } else {
            color(color::TEXT_PRIMARY)
        },
    ));
    let (tone, fill) = if s.cautionary {
        (WARNING, Color::new(0.910, 0.514, 0.227, 0.16))
    } else {
        (
            crate::look_glow::accent(),
            Color::new(0.314, 0.835, 0.855, 0.16),
        )
    };
    col.push(wide(
        text(
            cx,
            &s.delivery_line,
            style(12.0, 600),
            tone,
            Some(1),
            swiftly_text::Align::Start,
        )
        .padding(ins(4.0, 10.0, 4.0, 10.0))
        .background(Node::rect(fill, 11.0), Alignment::CENTER),
        Alignment::LEADING,
    ));
    let body = Node::vstack(Align::Start, Some(7.0), col)
        .padding(ins(12.0, 8.0, 12.0, 14.0))
        .frame(Some(content_w + 28.0 + 8.0), None, Alignment::TOP_LEADING);
    Node::hstack(Align::Start, Some(0.0), vec![pic, body])
        .key(format!("admin:card:{}", s.id).as_str())
}

/// "Wiedergaben": one card per stream; nobody playing says so.
fn streams_group(
    cx: &Cx,
    icons: &Icons,
    f: &Fm,
    hub: &HubSlot,
    images: Option<&ImageAddress>,
    page: &ServerAdminPage,
    col_w: f32,
) -> Node {
    if page.streams.is_empty() {
        let line = wide(
            text(
                cx,
                &page.streams_empty,
                style(15.0, 400),
                color::TEXT_SECONDARY,
                None,
                swiftly_text::Align::Start,
            ),
            Alignment::LEADING,
        )
        .padding(ins(16.0, 16.0, 16.0, 16.0));
        return forms::setting_group_at(cx, f, &page.streams_title, 26.0, vec![line], 0.0);
    }
    let groups = page
        .streams
        .iter()
        .enumerate()
        .map(|(i, s)| {
            forms::setting_group_at(
                cx,
                f,
                if i == 0 { &page.streams_title } else { "" },
                if i == 0 { 26.0 } else { 10.0 },
                vec![stream_card(cx, icons, f, hub, images, s, col_w)],
                0.0,
            )
        })
        .collect();
    wide(
        Node::vstack(Align::Start, Some(0.0), groups),
        Alignment::TOP_LEADING,
    )
}

/// "Auslastung": the plugin's processor and memory, the drives' rate, and one line per drive.
fn load_group(cx: &Cx, f: &Fm, page: &ServerAdminPage, col_w: f32) -> Option<Node> {
    let mut rows: Vec<Node> = Vec::new();
    let mut meter = |label: &str, text_: &str, share: f64| {
        rows.push(meter_row(cx, label, text_, share, col_w - 8.0, false, None));
    };
    if let Some(ServerLoadView { cpu, memory, .. }) = &page.load {
        for m in [cpu, memory].into_iter().flatten() {
            meter(&m.label, &m.text, m.share);
        }
    }
    if let Some(io) = page.load.as_ref().and_then(|l| l.disk_io.as_ref()) {
        rows.push(wide(
            Node::hstack(
                Align::Center,
                Some(8.0),
                vec![
                    text(
                        cx,
                        &io.label,
                        style(15.0, 500),
                        color::TEXT_PRIMARY,
                        Some(1),
                        swiftly_text::Align::Start,
                    ),
                    Node::spacer(),
                    tabular_text(
                        cx,
                        &io.text,
                        style(13.0, 400),
                        color::TEXT_SECONDARY,
                        Some(1),
                        swiftly_text::Align::End,
                    ),
                ],
            )
            .padding(ins(16.0, 16.0, 16.0, 16.0)),
            Alignment::LEADING,
        ));
    }
    for d in &page.disks {
        rows.push(meter_row(
            cx,
            &d.title,
            &d.free_text,
            d.free_share,
            col_w - 8.0,
            d.nearly_full,
            None,
        ));
    }
    (!rows.is_empty()).then(|| forms::setting_group_at(cx, f, &page.load_title, 0.0, rows, 0.0))
}

/// "Verwaltung": scan, restart, the log files; the answer to the last action under them.
fn actions_group(cx: &Cx, icons: &Icons, f: &Fm, page: &ServerAdminPage, top: f32) -> Node {
    let rows = page
        .actions
        .iter()
        .map(|a: &ServerAction| {
            let (key, symbol, trail) = match a.kind {
                ServerActionKind::ScanLibraries => ("admin:scan", "arrows-clockwise", Trail::None),
                ServerActionKind::Restart => {
                    ("admin:restart", "arrow-counter-clockwise", Trail::None)
                }
                ServerActionKind::Logs => ("admin:logs", "file-text", Trail::Chevron),
            };
            forms::row_kb(
                cx,
                icons,
                f,
                key,
                symbol,
                &a.title,
                a.under.as_deref(),
                trail,
                true,
            )
        })
        .collect();
    let group = forms::setting_group(cx, f, &page.actions_title, top, rows);
    match &page.notice {
        Some(n) => Node::vstack(
            Align::Start,
            Some(0.0),
            vec![group, forms::note(cx, f, n, false, false)],
        ),
        None => group,
    }
}

/// The question before something is done (restart, stop a task, stop a stream): the core's texts, two answers.
fn ask_dialog(cx: &Cx, window_h: f32, ask: &ServerAdminAsk) -> Option<Node> {
    let (title, lines, action): (&str, Vec<&str>, &str) = match ask {
        ServerAdminAsk::Nothing => return None,
        ServerAdminAsk::Restart {
            title,
            note,
            action,
        } => (title, vec![note], action),
        ServerAdminAsk::StopTask { title, action, .. } => (title, vec![], action),
        ServerAdminAsk::StopStream {
            title,
            line,
            message_label,
            message,
            action,
            ..
        } => (title, vec![line, message_label, message], action),
    };
    let slide = window_h / 2.0 + 130.0;
    let button = |key: &str, label: &str, c: swiftly_design::types::Colour| {
        wide(
            text(
                cx,
                label,
                style(14.0, 500),
                c,
                Some(1),
                swiftly_text::Align::Center,
            )
            .frame(None, Some(34.0), Alignment::CENTER),
            Alignment::CENTER,
        )
        .background(
            Node::rect(color(color::SURFACE_CONTROL), 8.0),
            Alignment::CENTER,
        )
        .key(key)
        .on_tap(Action::from(key))
        .hover_surface(
            crate::home::rgba(color::TEXT_PRIMARY, swiftly_ui::feel::HOVER_SURFACE_ALPHA),
            8.0,
        )
    };
    let mut col = vec![text(
        cx,
        title,
        style(15.0, 700),
        color::TEXT_PRIMARY,
        Some(2),
        swiftly_text::Align::Center,
    )];
    for (i, l) in lines.iter().enumerate() {
        col.push(
            text(
                cx,
                l,
                style(13.0, 400),
                if i == 2 {
                    color::TEXT_TERTIARY
                } else {
                    color::TEXT_SECONDARY
                },
                Some(4),
                swiftly_text::Align::Center,
            )
            .padding(ins(if i == 0 { 6.0 } else { 0.0 }, 0.0, 0.0, 0.0)),
        );
    }
    col.push(button("admin:ask.ok", action, color::STATE_ERROR).padding(ins(6.0, 0.0, 0.0, 0.0)));
    col.push(button(
        "admin:ask.cancel",
        cancel_label(),
        color::TEXT_PRIMARY,
    ));
    Some(
        Node::vstack(Align::Center, Some(8.0), col)
            .padding(ins(20.0, 20.0, 20.0, 20.0))
            .frame(Some(320.0), None, Alignment::CENTER)
            .background(
                Node::rect(color(color::SURFACE_RAISED), 14.0),
                Alignment::CENTER,
            )
            .appear_offset(0.0, -slide)
            .exit_offset(0.0, -slide),
    )
}

/// "Abbrechen" in the language of the app (the core has the word).
fn cancel_label() -> &'static str {
    "Abbrechen"
}

/// A sentence with a button under it (a failed read, a missing right).
fn message_page(
    cx: &Cx,
    icons: &Icons,
    env: &Env,
    f: &Fm,
    title: &str,
    hint: &str,
    retry: Option<(&str, &str)>,
) -> Node {
    let mut col = vec![
        wide(
            text(
                cx,
                hint,
                style(15.0, 400),
                color::TEXT_SECONDARY,
                None,
                swiftly_text::Align::Start,
            ),
            Alignment::LEADING,
        )
        .padding(ins(0.0, 22.0, 0.0, 0.0)),
    ];
    if let Some((key, label)) = retry {
        col.push(
            forms::button(
                cx,
                icons,
                f,
                key,
                label,
                Some("arrows-clockwise"),
                true,
                false,
                true,
            )
            .padding(ins(12.0, 0.0, 0.0, 0.0)),
        );
    }
    forms::settings_page(
        cx,
        icons,
        env,
        f,
        title,
        0.0,
        Cols::One,
        vec![col],
        vec![],
        None,
    )
}

/// The server page, by the core's one state.
pub fn admin_page(cx: &Cx, icons: &Icons, env: &Env, f: &Fm, hub: &HubSlot, v: &AdminView) -> Node {
    let part = &v.part;
    match &part.state {
        // Read ahead from the Profile, so this is rarely seen: the title and nothing that would pop in.
        ServerAdminState::Loading => forms::settings_page(
            cx,
            icons,
            env,
            f,
            &part.title,
            0.0,
            Cols::One,
            vec![vec![]],
            vec![],
            None,
        ),
        ServerAdminState::NotAllowed { hint } => {
            message_page(cx, icons, env, f, &part.title, hint, None)
        }
        ServerAdminState::Failed { hint } => message_page(
            cx,
            icons,
            env,
            f,
            &part.title,
            hint,
            Some(("admin:retry", retry_label())),
        ),
        ServerAdminState::Ready { page } => {
            let (col_w, _, two) = forms::column_layout(env, Cols::Equal);
            let streams = streams_group(cx, icons, f, hub, v.images.as_ref(), page, col_w);
            let mut left = vec![server_group(cx, f, page, col_w)];
            if !page.tasks.is_empty() {
                left.push(tasks_group(cx, icons, f, page, col_w));
            }
            left.push(streams);
            let mut right = Vec::new();
            let load = load_group(cx, f, page, col_w);
            let top = if load.is_some() { 26.0 } else { 0.0 };
            right.extend(load);
            right.push(actions_group(
                cx,
                icons,
                f,
                page,
                if two { top } else { 26.0 },
            ));
            let overlay = ask_dialog(cx, env.size.h, &page.ask);
            if !v.tabs.is_empty() {
                // The row sits above both columns: the first column carries it, the second keeps its place below it.
                left.insert(0, hub_tabs(cx, &v.tabs));
                right.insert(0, Node::fixed(0.0, TAB_ROW_H));
            }
            forms::settings_page(
                cx,
                icons,
                env,
                f,
                &part.title,
                0.0,
                Cols::Equal,
                vec![left, right],
                vec![],
                overlay,
            )
        }
    }
}

fn retry_label() -> &'static str {
    "Erneut versuchen"
}

/// The log pages: the files, then the end of one file.
pub fn logs_page(cx: &Cx, icons: &Icons, env: &Env, f: &Fm, v: &AdminView) -> Node {
    let part = &v.logs;
    match &part.state {
        ServerLogsState::Loading => forms::settings_page(
            cx,
            icons,
            env,
            f,
            &part.title,
            0.0,
            Cols::One,
            vec![vec![]],
            vec![],
            None,
        ),
        ServerLogsState::Empty { hint } => message_page(cx, icons, env, f, &part.title, hint, None),
        ServerLogsState::Failed { hint } => message_page(
            cx,
            icons,
            env,
            f,
            &part.title,
            hint,
            Some(("admin:logs-retry", retry_label())),
        ),
        ServerLogsState::Files { rows } => {
            let rows = rows
                .iter()
                .enumerate()
                .map(|(i, r)| {
                    let under = match &r.day {
                        Some(d) => format!("{} \u{00B7} {d}", r.size_text),
                        None => r.size_text.clone(),
                    };
                    forms::row_kb(
                        cx,
                        icons,
                        f,
                        &format!("admin:log:{i}"),
                        "file-text",
                        &r.name,
                        Some(&under),
                        Trail::Chevron,
                        true,
                    )
                })
                .collect();
            forms::settings_page(
                cx,
                icons,
                env,
                f,
                &part.title,
                0.0,
                Cols::One,
                vec![vec![forms::setting_group(cx, f, "", 0.0, rows)]],
                vec![],
                None,
            )
        }
        ServerLogsState::Text { text: body, .. } => {
            // The end of a long file: the last lines only, so one frame stays cheap.
            let lines: Vec<&str> = body.lines().collect();
            let shown = lines[lines.len().saturating_sub(600)..].join("\n");
            let card = wide(
                text(
                    cx,
                    &shown,
                    style(12.0, 400),
                    color::TEXT_SECONDARY,
                    None,
                    swiftly_text::Align::Start,
                )
                .padding(ins(14.0, 16.0, 14.0, 16.0)),
                Alignment::TOP_LEADING,
            )
            .background(
                Node::rect(color(color::SURFACE_GROUP), 16.0),
                Alignment::CENTER,
            );
            forms::settings_page(
                cx,
                icons,
                env,
                f,
                &part.title,
                0.0,
                Cols::One,
                vec![vec![card]],
                vec![],
                None,
            )
        }
    }
}
