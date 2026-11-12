//! Pieces of the Downloads page that follow `Sources/macOS/MacDownloads.swift` and `MacComponents.swift`: the progress
//! ring (`DownloadRing`), the thin progress bar, the square action button (`ActionButton`), the primary button, the sub
//! line of a row and the Mac page frame. Own copies, so `forms.rs` stays with the Settings helper.

use crate::browse::wide;
use crate::forms::{self, Fm};
use crate::home::{ins, rgba, text};
use swiftly_design::tokens::colour;
use swiftly_downloads::{DownloadItem, DownloadQuality, DownloadRules, DownloadState};
use swiftly_layout::{Align, Alignment, Axis};
use swiftly_render::Color;
use swiftly_ui::a11y::{A11yNode, Role};
use swiftly_ui::components::color;
use swiftly_ui::icons::Icons;
use swiftly_ui::{Action, Cx, Env, Node, Paint, feel};
use swiftly_vm::RowState;

/// The decimal separator of the German texts.
pub const SEP: &str = ",";

/// A text style of `size` and `weight`.
pub fn st(size: f32, weight: u16) -> swiftly_design::TextStyle {
    swiftly_design::TextStyle {
        size,
        weight,
        tracking: 0.0,
        uppercase: false,
    }
}

/// The mass of the ring and of its hit area (`DownloadRing.mass` 26, hit `mass + 10`).
pub const RING: f32 = 26.0;
/// Hit area of the ring.
pub const RING_HIT: f32 = 36.0;

/// Tooltip and accessibility label of the ring (`DownloadRing.help`).
pub fn ring_label(state: Option<RowState>) -> &'static str {
    match state {
        None => "Laden",
        Some(RowState::Waiting) => "Wartet",
        Some(RowState::Loading) => "L\u{00E4}dt, anhalten",
        Some(RowState::Paused) => "Angehalten, fortsetzen",
        Some(RowState::Done) => "Auf diesem Mac",
        Some(RowState::Failed) => "Fehlgeschlagen, erneut versuchen",
    }
}

fn polygon(cx: &Cx, d: &str, pt: f32, tint: Color) -> Node {
    let px = (pt * 3.0).ceil() as u32;
    match cx.add_image(px, px, &swiftly_ui::icons::rasterize(d, px, true)) {
        Some(id) => {
            let mut node = Node::image(id, pt, pt, 0.0);
            for p in &mut node.paint {
                if let Paint::Image { tint: t, .. } = p {
                    *t = tint;
                }
            }
            node
        }
        None => Node::fixed(pt, pt),
    }
}

/// The dashed circle of a waiting row (`StrokeStyle(lineWidth: 2, dash: [3, 4])`): dashes 3 pt long, 4 pt apart on the
/// circle through the middle of the 2 pt stroke, starting at 3 o'clock.
fn dashed(cx: &Cx, tint: Color, pt: f32) -> Node {
    let k = 100.0 / pt;
    let r = pt / 2.0 - 1.0;
    let (r_mid, half) = (r * k, k);
    let (period, dash) = (7.0 / r, 3.0 / r);
    let at = |rad: f32, t: f32| (50.0 + rad * t.cos(), 50.0 + rad * t.sin());
    let mut d = String::new();
    let mut a = 0.0_f32;
    while a < std::f32::consts::TAU - 0.01 {
        let end = (a + dash).min(std::f32::consts::TAU);
        let steps = 6;
        for i in 0..=steps {
            let (x, y) = at(r_mid + half, a + (end - a) * i as f32 / steps as f32);
            d.push_str(&format!(
                "{} {x:.2} {y:.2} ",
                if i == 0 { "M" } else { "L" }
            ));
        }
        for i in (0..=steps).rev() {
            let (x, y) = at(r_mid - half, a + (end - a) * i as f32 / steps as f32);
            d.push_str(&format!("L {x:.2} {y:.2} "));
        }
        d.push_str("Z ");
        a += period;
    }
    polygon(cx, &d, pt, tint)
}

/// `DownloadRing.arc`: `trim(from: 0, to: max(0.02, share))`, 2 pt wide with round caps, from 12 o'clock clockwise,
/// drawn on the track's centre line (the 100-unit template space is `pt` wide).
fn arc(cx: &Cx, share: f32, tint: Color, pt: f32) -> Node {
    let k = 100.0 / pt;
    let share = ((share.clamp(0.0, 1.0) * 120.0).round() / 120.0).max(0.02);
    let (outer, inner, mid, cap) = (50.0, 50.0 - 2.0 * k, 50.0 - k, k);
    let end = share * std::f32::consts::TAU;
    let at = |r: f32, t: f32| (50.0 + r * t.sin(), 50.0 - r * t.cos());
    let n = ((48.0 * share) as usize).max(4);
    let mut d = String::new();
    for i in 0..=n {
        let (x, y) = at(outer, end * i as f32 / n as f32);
        d.push_str(&format!(
            "{} {x:.2} {y:.2} ",
            if i == 0 { "M" } else { "L" }
        ));
    }
    for i in (0..=n).rev() {
        let (x, y) = at(inner, end * i as f32 / n as f32);
        d.push_str(&format!("L {x:.2} {y:.2} "));
    }
    d.push_str("Z ");
    for t in [0.0, end] {
        let (cx0, cy0) = at(mid, t);
        for i in 0..16 {
            let a = std::f32::consts::TAU * i as f32 / 16.0;
            d.push_str(&format!(
                "{} {:.2} {:.2} ",
                if i == 0 { "M" } else { "L" },
                cx0 + cap * a.sin(),
                cy0 - cap * a.cos()
            ));
        }
        d.push_str("Z ");
    }
    polygon(cx, &d, pt, tint)
}

/// The exclamation mark of a failed row: a bar and a dot, 12 pt tall.
fn exclamation(c: Color) -> Node {
    Node::vstack(
        Align::Center,
        Some(1.8),
        vec![
            Node::rect(c, 0.9).frame(Some(1.9), Some(6.6), Alignment::CENTER),
            Node::rect(c, 1.1).frame(Some(2.2), Some(2.2), Alignment::CENTER),
        ],
    )
}

fn circle(c: Color, width: f32) -> Node {
    Node::rect(Color::new(0.0, 0.0, 0.0, 0.0), RING / 2.0)
        .paint(Paint::Stroke {
            color: c,
            width,
            radius: RING / 2.0,
        })
        .frame(Some(RING), Some(RING), Alignment::CENTER)
}

/// `DownloadRing`: one icon, six states (`None` is a title that is not downloaded). 26 pt in a 36 pt hit area, opacity
/// 0.9 and 1 while the pointer is over it, tooltip and screen reader label from [`ring_label`]. `share` is the estimate.
#[allow(clippy::too_many_arguments)]
pub fn ring(
    cx: &Cx,
    icons: &Icons,
    f: &Fm,
    state: Option<RowState>,
    share: f32,
    hovered: bool,
    key: &str,
    hover_key: &str,
    reveal: bool,
) -> Node {
    let quiet = color(colour::FONT_VERY_QUIET);
    let track = rgba(colour::FONT, 0.3);
    let glyph = |name: &str, size: f32, c: Color| icons.node(name, size, false, c);
    let mut face = match state {
        None => circle(color(colour::FONT_QUIET), 1.5).overlay(
            icons.node("arrow-down", 12.0, true, color(colour::FONT)),
            Alignment::CENTER,
        ),
        Some(RowState::Waiting) => {
            dashed(cx, quiet, RING).overlay(glyph("pause.fill", 10.0, quiet), Alignment::CENTER)
        }
        Some(RowState::Loading) => circle(track, 2.0)
            .overlay(
                arc(cx, share, color(colour::MARK_ACCENT), RING),
                Alignment::CENTER,
            )
            .overlay(
                Node::rect(color(colour::MARK_ACCENT), 1.5).frame(
                    Some(RING * 0.32),
                    Some(RING * 0.32),
                    Alignment::CENTER,
                ),
                Alignment::CENTER,
            ),
        Some(RowState::Paused) => circle(track, 2.0)
            .overlay(
                arc(cx, share, color(colour::FONT_QUIET), RING),
                Alignment::CENTER,
            )
            .overlay(
                glyph("play.fill", 10.0, color(colour::FONT)),
                Alignment::CENTER,
            ),
        // An arrow, not a check: the check means "watched".
        Some(RowState::Done) => Node::rect(color(colour::MARK_ACCENT), RING / 2.0)
            .frame(Some(RING), Some(RING), Alignment::CENTER)
            .overlay(
                icons.node("arrow-down", 12.0, true, color(colour::REASON)),
                Alignment::CENTER,
            ),
        Some(RowState::Failed) => circle(color(colour::ORIGINAL_WARNING), 2.0).overlay(
            exclamation(color(colour::ORIGINAL_WARNING)),
            Alignment::CENTER,
        ),
    };
    let label = ring_label(state);
    // The face is keyed by its state: a new state is a new node, and with `reveal` it comes in (opacity and scale 0.8
    // to 1 over `Theme.reveal`, 0.28 s ease in/out; there is no move transition in the engine).
    face = face
        .frame(Some(RING), Some(RING), Alignment::CENTER)
        .key(format!("face:{key}:{label}").as_str());
    if reveal {
        face = face.appear_from(0.8, 0.0).opacity(1.0, feel::reveal());
    }
    face = face
        .frame(Some(RING), Some(RING), Alignment::CENTER)
        .opacity(if hovered { 1.0 } else { 0.9 }, feel::hover());
    let hit = face
        .frame(Some(RING_HIT), Some(RING_HIT), Alignment::CENTER)
        .on_hover(Action::from(hover_key))
        .tooltip(label)
        .a11y(A11yNode::new("", Role::Button, label));
    forms::tappable(hit, f, key, RING_HIT / 2.0)
}

/// The thin bar under a row's lines: 3 pt, track white 30 %, fill in the accent.
pub fn bar(share: f32, w: f32) -> Node {
    let fill = Node::rect(color(colour::MARK_ACCENT), 1.5).frame(
        Some((w * share.clamp(0.0, 1.0)).max(0.0)),
        Some(3.0),
        Alignment::LEADING,
    );
    fill.frame(Some(w), Some(3.0), Alignment::LEADING)
        .background(Node::rect(rgba(colour::FONT, 0.3), 1.5), Alignment::CENTER)
}

/// `ActionButton`: a 48 pt square field (corner 10, area colour, hover surface), the glyph in the accent while `active`.
/// The word is the screen reader label.
pub fn action_button(
    icons: &Icons,
    f: &Fm,
    key: &str,
    symbol: &str,
    filled: bool,
    label: &str,
    active: bool,
) -> Node {
    let c = color(if active {
        colour::MARK_ACCENT
    } else {
        colour::FONT
    });
    let n = icons
        .node(symbol, 17.0, !filled, c)
        .frame(Some(48.0), Some(48.0), Alignment::CENTER)
        .background(Node::rect(color(colour::AREA), 10.0), Alignment::CENTER)
        .hover_surface(color(colour::HOVER_AREA), 10.0);
    forms::tappable(n, f, key, 10.0)
        .a11y(A11yNode::new("", Role::Button, label).with_selected(active))
}

/// `PrimaryButton` of the Mac: 48 high, at least 200 wide, white, corner 10, dimmed 12 % on hover, 40 % when `enabled` is false.
pub fn primary_button(cx: &Cx, f: &Fm, key: &str, label: &str, enabled: bool) -> Node {
    let t = text(
        cx,
        label,
        st(17.0, 600),
        colour::REASON,
        Some(1),
        swiftly_text::Align::Center,
    );
    let n = Node::hstack(
        Align::Center,
        Some(0.0),
        vec![t.padding(ins(0.0, 18.0, 0.0, 18.0))],
    )
    .flex_frame(swiftly_layout::FlexFrame {
        min_w: Some(200.0),
        min_h: Some(48.0),
        max_h: Some(48.0),
        align: Some(Alignment::CENTER),
        ..swiftly_layout::FlexFrame::default()
    })
    .background(Node::rect(color(colour::FONT), 10.0), Alignment::CENTER)
    .hover_surface(Color::new(0.0, 0.0, 0.0, 0.12), 10.0);
    if enabled {
        forms::tappable(n, f, key, 10.0)
    } else {
        n.key(key).disabled(true)
    }
}

/// The text of a runtime: "2 Std. 8 Min." or "94 Min.".
pub fn runtime_text(seconds: f64) -> String {
    let m = (seconds / 60.0).round() as i64;
    if m >= 60 {
        format!("{} Std. {} Min.", m / 60, m % 60)
    } else {
        format!("{m} Min.")
    }
}

/// The second line of a row (`MacDownloadRow.subline`) for a stored title; `loaded` is the shown (estimated) byte count.
pub fn subline(i: &DownloadItem, loaded: i64) -> String {
    let mut parts: Vec<String> = Vec::new();
    if let (Some(s), Some(e)) = (i.season, i.episode) {
        parts.push(format!("S{s} F{e}"));
    } else if let Some(t) = i.runtime_ticks.filter(|t| *t > 0) {
        parts.push(runtime_text(t as f64 / 10_000_000.0));
    }
    let level = i.guete().name().map(str::to_owned);
    match i.state {
        DownloadState::Loads => {
            let (done, total) = DownloadRules::progress(loaded, i.bytes, SEP);
            parts = vec![format!(
                "{done} von {}{total}",
                if i.streamed() { "\u{2248} " } else { "" }
            )];
        }
        DownloadState::Waits => {
            parts.push("wartet".to_owned());
            parts.extend(level.filter(|_| i.converted()));
        }
        DownloadState::Halted => {
            parts.push("angehalten".to_owned());
            parts.extend(level.filter(|_| i.converted()));
        }
        DownloadState::Error => {
            parts = vec![
                i.reason
                    .clone()
                    .unwrap_or_else(|| "Fehlgeschlagen".to_owned()),
            ]
        }
        DownloadState::Done => {
            parts.push(DownloadRules::size(i.bytes, SEP));
            if let (true, Some(n)) = (i.converted(), level) {
                parts.push(n);
            } else if let Some(c) = &i.container {
                parts.push(c.to_uppercase());
            }
            if !i.still_on_the_server {
                parts.push("nicht mehr auf dem Server".to_owned());
            }
        }
    }
    parts.join(" \u{00B7} ")
}

/// The second line of a series row: "3 Folgen \u{00B7} 2,7 GB \u{00B7} 720p".
pub fn group_subline(episodes: &[&DownloadItem]) -> String {
    let bytes: i64 = episodes.iter().map(|e| e.bytes).sum();
    let levels: Vec<DownloadQuality> = episodes.iter().map(|e| e.guete()).collect();
    let mut s = format!(
        "{} \u{00B7} {}",
        swiftly_l10n::plural("%lld Folgen", episodes.len() as i64, &[]),
        DownloadRules::size(bytes, SEP)
    );
    if let Some(n) = DownloadQuality::common(&levels).and_then(DownloadQuality::name) {
        s.push_str(" \u{00B7} ");
        s.push_str(n);
    }
    s
}

/// The Mac page frame (`MacDownloads.body`): the column at most 900 wide with 36 pt edges, 40 below, the header row
/// (title, spacer, buttons) 58 below the top. `before` sits above the column (the series hero), `overlay` covers all.
pub fn mac_page(
    env: &Env,
    hero: Option<Node>,
    head: Node,
    body: Vec<Node>,
    overlay: Option<Node>,
) -> Node {
    use crate::home::fill_frame;
    let edge = 36.0_f32;
    let col_w = (900.0 + 2.0 * edge).min(env.size.w);
    let mut column = vec![head];
    column.extend(body);
    let col = Node::vstack(Align::Start, Some(0.0), column)
        .padding(ins(0.0, edge, 40.0, edge))
        .frame(Some(col_w), None, Alignment::TOP_LEADING);
    // Leading, like the Mac's `.frame(maxWidth: 900).padding(.horizontal, edge).frame(maxWidth: .infinity, alignment: .leading)`.
    let col = wide(col, Alignment::TOP_LEADING).flex_frame(swiftly_layout::FlexFrame {
        max_w: Some(f32::INFINITY),
        align: Some(Alignment::TOP_LEADING),
        ..swiftly_layout::FlexFrame::default()
    });
    let content = match hero {
        Some(h) => Node::vstack(Align::Start, Some(0.0), vec![h, col]),
        None => col,
    };
    let scroll = Node::scroll(Axis::Vertical, None, content).key("form-scroll");
    let p = fill_frame(scroll, Alignment::TOP_LEADING)
        .background(Node::rect(color(colour::REASON), 0.0), Alignment::CENTER);
    let p = fill_frame(p, Alignment::TOP_LEADING);
    match overlay {
        Some(o) => p.overlay(o, Alignment::TOP_LEADING),
        None => p,
    }
}
