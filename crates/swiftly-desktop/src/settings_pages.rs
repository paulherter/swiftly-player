//! The pages below Settings that only the Mac has in Swift: the subtitle look
//! (`MacSubtitleLook.swift`), Seerr (`SeerrSettingsView.swift`), the header editor (`MacAdvanced.swift`) and the
//! licences (`LicensesView.swift`). Pure views over small data structs; `settings_screen` owns the state.

use crate::browse::wide;
use crate::forms::{self, Fm, Trail};
use crate::home::{Form, fill_frame, ins, rgba};
use swiftly_design::tokens::colour;
use swiftly_layout::{Align, Alignment};
use swiftly_render::Color;
use swiftly_support::licenses::{LicenseComponent, LicenseData};
use swiftly_support::subtitle::{
    Colour as SubColour, Outline, Position, Size, SubtitleLook, base_scale,
};
use swiftly_ui::components::color;
use swiftly_ui::icons::Icons;
use swiftly_ui::{Cx, Env, Node};

fn style(size: f32, weight: u16) -> swiftly_design::TextStyle {
    swiftly_design::TextStyle {
        size,
        weight,
        tracking: 0.0,
        uppercase: false,
    }
}

/// A text line in an arbitrary colour.
fn label(
    cx: &Cx,
    s: &str,
    size: f32,
    weight: u16,
    c: Color,
    lines: Option<usize>,
    align: swiftly_text::Align,
) -> Node {
    Node::text(
        cx,
        s,
        &swiftly_text::TextStyle::from(style(size, weight)),
        c,
        lines,
        align,
    )
}

fn rgb(v: u32) -> Color {
    Color::new(
        ((v >> 16) & 0xFF) as f32 / 255.0,
        ((v >> 8) & 0xFF) as f32 / 255.0,
        (v & 0xFF) as f32 / 255.0,
        1.0,
    )
}

/// The page shell: the Mac page frame on the desktop, the plain form page on touch and tv.
#[allow(clippy::too_many_arguments)]
fn shell(
    cx: &Cx,
    icons: &Icons,
    env: &Env,
    f: &Fm,
    title: &str,
    cols: forms::Cols,
    columns: Vec<Vec<Node>>,
    overlay: Option<Node>,
) -> Node {
    if f.form == Form::Desktop {
        forms::settings_page(
            cx,
            icons,
            env,
            f,
            title,
            10.0,
            cols,
            columns,
            vec![],
            overlay,
        )
    } else {
        forms::page(
            cx,
            icons,
            env,
            f,
            title,
            None,
            columns.into_iter().flatten().collect(),
            overlay,
        )
    }
}

// ---- Untertitel-Stil ----------------------------------------------------------------------------------------------

/// What the subtitle page draws.
#[derive(Clone, PartialEq)]
pub struct SubView {
    /// The look.
    pub look: SubtitleLook,
    /// The "Zurückgesetzt / Rückgängig" strip is showing.
    pub undo: bool,
    /// The file style can be switched (not on Plex).
    pub adjustable: bool,
}

/// One cell of a segment strip.
pub struct Cell {
    /// Text of the cell.
    pub text: String,
    /// Size of the text (13 for words, the glyph size for the "A" of Größe).
    pub size: f32,
    /// Colour of the text.
    pub tint: Color,
}

/// `MacSegments`: a raised track with cells of 28 height, the chosen one on a white 29 % pill, hover white 6 %.
pub fn segments(cx: &Cx, f: &Fm, prefix: &str, cells: &[Cell], chosen: usize, each: f32) -> Node {
    let items = cells
        .iter()
        .enumerate()
        .map(|(i, c)| {
            let on = i == chosen;
            let t = label(
                cx,
                &c.text,
                c.size,
                600,
                c.tint,
                Some(1),
                swiftly_text::Align::Center,
            )
            .frame(Some(each), Some(28.0), Alignment::CENTER);
            let t = if on {
                t.background(Node::rect(rgba(colour::FONT, 0.29), 6.0), Alignment::CENTER)
            } else {
                t
            };
            let key = format!("{prefix}.{i}");
            let n = forms::tappable(t, f, &key, 6.0);
            if on {
                n
            } else {
                n.hover_surface(
                    rgba(colour::FONT, swiftly_ui::feel::HOVER_SURFACE_ALPHA),
                    6.0,
                )
            }
        })
        .collect();
    Node::hstack(Align::Center, Some(2.0), items)
        .padding(ins(2.0, 2.0, 2.0, 2.0))
        .background(Node::rect(color(colour::RAISED), 8.0), Alignment::CENTER)
}

fn segment_row(cx: &Cx, icons: &Icons, title: &str, symbol: &str, strip: Node) -> Node {
    let head = || {
        Node::hstack(
            Align::Center,
            Some(12.0),
            vec![
                icons
                    .node(symbol, 20.0, true, color(colour::FONT_QUIET))
                    .frame(Some(26.0), None, Alignment::CENTER),
                label(
                    cx,
                    title,
                    15.0,
                    600,
                    color(colour::FONT),
                    Some(1),
                    swiftly_text::Align::Start,
                ),
            ],
        )
    };
    // `ViewThatFits(in: .horizontal)` of `MacSubtitleLook.segmentRow`: title left and segments right; when they do not
    // fit side by side, the segments stack under the title (nothing is cut).
    // The title keeps its unshrunk width: an hstack hands the title only half of what the rigid strip leaves (the
    // spacer takes the other half), so a title that fits by its ideal width was still cut to "F..." beside its strip.
    let inline = Node::hstack(
        Align::Center,
        Some(12.0),
        vec![
            head().fixed_size(true, false),
            Node::spacer(),
            strip.clone(),
        ],
    )
    .padding(ins(8.0, 12.0, 8.0, 12.0))
    .frame(None, Some(46.0), Alignment::LEADING);
    let stacked = Node::vstack(Align::Start, Some(8.0), vec![head(), strip])
        .padding(ins(10.0, 12.0, 10.0, 12.0));
    wide(
        Node::view_that_fits(swiftly_layout::Axes::HORIZONTAL, vec![inline, stacked]),
        Alignment::LEADING,
    )
}

/// Memo key of the room [`reserve_preview_room`] keeps for the sample picture.
const PREVIEW_ROOM: &str = "subtitle-preview-room";

/// Keeps room for the sample picture (1280 x 720) on the image page, once, while the page is still empty. A long session
/// of posters and icons fills the page, and a picture added only when the page opens found no room then: the preview
/// had no background. The room is black until the page opens and fills it.
pub fn reserve_preview_room(cx: &Cx) {
    if cx.memo.borrow().contains_key(PREVIEW_ROOM) {
        return;
    }
    let room = cx.images.borrow_mut().reserve(1280, 720);
    cx.memo
        .borrow_mut()
        .insert(PREVIEW_ROOM, room.map(|s| s.id).into_iter().collect());
}

/// The picture behind the sample text (`subtitle-preview` of the Apple apps), cut to 16:9 around its middle like
/// `scaledToFill`; `None` when it cannot be decoded (the dark ground stays).
pub fn preview_picture(cx: &Cx) -> Option<swiftly_ui::ImageId> {
    if let Some(v) = cx.memo.borrow().get("subtitle-preview") {
        return v.first().copied();
    }
    let room = cx
        .memo
        .borrow()
        .get(PREVIEW_ROOM)
        .and_then(|v| v.first().copied());
    let id = swiftly_images::decode::decode(PREVIEW_JPEG, 1280)
        .ok()
        .and_then(|d| {
            let (w, h, rgba) = crop_16_9(d.width, d.height, &d.rgba);
            match room {
                Some(room) if cx.images.borrow_mut().rewrite_in(&room, w, h, &rgba) => Some(room),
                _ => cx.add_image(w, h, &rgba),
            }
        });
    cx.memo
        .borrow_mut()
        .insert("subtitle-preview", id.into_iter().collect());
    id
}

const PREVIEW_JPEG: &[u8] = include_bytes!("../assets/subtitle-preview.jpg");

/// The middle band of an RGBA picture that is 16:9 (or the middle columns when it is wider).
fn crop_16_9(w: u32, h: u32, rgba: &[u8]) -> (u32, u32, Vec<u8>) {
    let (cw, ch) = if u64::from(w) * 9 > u64::from(h) * 16 {
        (h * 16 / 9, h)
    } else {
        (w, w * 9 / 16)
    };
    let (x0, y0) = ((w - cw) / 2, (h - ch) / 2);
    let mut out = Vec::with_capacity(cw as usize * ch as usize * 4);
    for row in y0..y0 + ch {
        let start = (row as usize * w as usize + x0 as usize) * 4;
        out.extend_from_slice(&rgba[start..start + cw as usize * 4]);
    }
    (cw, ch, out)
}

/// The sample picture: 16:9 with the look applied to a sample line.
fn preview(cx: &Cx, look: &SubtitleLook, w: f32) -> Node {
    let h = (w * 9.0 / 16.0).round();
    let pts = (look.preview_points(f64::from(h), base_scale::IPAD_MAC) as f32).max(11.0);
    // The Apple sample: two short lines.
    let line = |c: Color| {
        let one = |t: &str| label(cx, t, pts, 600, c, Some(1), swiftly_text::Align::Center);
        Node::vstack(
            Align::Center,
            Some(0.0),
            vec![one("Hörst du das auch?"), one("Da hinten am See.")],
        )
    };
    let mut stack = line(rgb(look.colour.rgb()));
    // The outline is the text copied around a circle (as the Mac preview does), each copy moved by an offset: a padded copy
    // needs more width than its box and wraps into a second line.
    let t = (pts * look.outline.thickness() as f32 / 100.0).max(1.0);
    let black = |a: f32| Color::new(0.0, 0.0, 0.0, a);
    if t > 0.0 && look.outline.thickness() > 0 {
        for k in 0..8_i16 {
            let angle = f32::from(k) * std::f32::consts::FRAC_PI_4;
            let copy = line(black(0.9)).a11y_hidden().offset(
                t * angle.cos(),
                t * angle.sin(),
                swiftly_ui::Motion::Instant,
            );
            stack = stack.background(copy, Alignment::CENTER);
        }
    }
    if look.shadow {
        let shade =
            line(black(0.63))
                .a11y_hidden()
                .offset(0.0, pts * 0.04, swiftly_ui::Motion::Instant);
        stack = stack.background(shade, Alignment::CENTER);
    }
    let stack = if look.background {
        stack.padding(ins(3.0, 8.0, 3.0, 8.0)).background(
            Node::rect(Color::new(0.0, 0.0, 0.0, 0.6), 4.0),
            Alignment::CENTER,
        )
    } else {
        stack
    };
    let lift = 16.0
        + if look.position == Position::Raised {
            (f64::from(h) * 0.07) as f32
        } else {
            0.0
        };
    stack
        .padding(ins(0.0, 12.0, lift, 12.0))
        .frame(Some(w), Some(h), Alignment::BOTTOM)
        .background(
            match preview_picture(cx) {
                Some(id) => Node::image(id, w, h, 16.0),
                None => Node::rect(Color::new(0.06, 0.07, 0.09, 1.0), 16.0),
            },
            Alignment::CENTER,
        )
}

/// The subtitle look page (`SubtitleLookView`).
pub fn subtitle_page(cx: &Cx, icons: &Icons, env: &Env, f: &Fm, v: &SubView) -> Node {
    let look = &v.look;
    let on_off = |k: &str, sym: &str, title: &str, on: bool| {
        forms::row_kb(cx, icons, f, k, sym, title, None, Trail::Switch(on), true)
    };
    let quiet = color(colour::FONT_VERY_QUIET);
    let glyph = |s: Size| Cell {
        text: "A".into(),
        size: s.glyph_size() as f32,
        tint: color(colour::FONT),
    };
    let word = |t: &str| Cell {
        text: t.into(),
        size: 13.0,
        tint: color(colour::FONT),
    };
    let size_cells: Vec<Cell> = Size::ALL.iter().map(|s| glyph(*s)).collect();
    let colour_cells: Vec<Cell> = SubColour::ALL
        .iter()
        .map(|c| Cell {
            text: "A".into(),
            size: 17.0,
            tint: rgb(c.rgb()),
        })
        .collect();
    let outline_cells: Vec<Cell> = Outline::ALL.iter().map(|o| word(o.name_key())).collect();
    let pos_cells = [
        word(Position::Bottom.name_key()),
        word(Position::Raised.name_key()),
    ];
    let at = |all: &[Size]| all.iter().position(|s| *s == look.size).unwrap_or(1);
    // `SheetLine().padding(.leading, Theme.separatorInsetCard)`: the hairlines of this page start at 52.
    let appearance = forms::setting_group_at(
        cx,
        f,
        "Aussehen",
        22.0,
        vec![
            segment_row(
                cx,
                icons,
                "Größe",
                "text-aa",
                segments(cx, f, "sub.size", &size_cells, at(&Size::ALL), 46.0),
            ),
            segment_row(
                cx,
                icons,
                "Farbe",
                "palette",
                segments(
                    cx,
                    f,
                    "sub.colour",
                    &colour_cells,
                    SubColour::ALL
                        .iter()
                        .position(|c| *c == look.colour)
                        .unwrap_or(0),
                    46.0,
                ),
            ),
            segment_row(
                cx,
                icons,
                "Rand",
                "textbox",
                segments(
                    cx,
                    f,
                    "sub.outline",
                    &outline_cells,
                    Outline::ALL
                        .iter()
                        .position(|o| *o == look.outline)
                        .unwrap_or(0),
                    70.0,
                ),
            ),
            on_off("sub.shadow", "copy", "Schatten", look.shadow),
            on_off(
                "sub.background",
                "square",
                "Dunkler Hintergrund",
                look.background,
            ),
            segment_row(
                cx,
                icons,
                "Position",
                "align-bottom-simple",
                segments(
                    cx,
                    f,
                    "sub.position",
                    &pos_cells,
                    usize::from(look.position == Position::Raised),
                    70.0,
                ),
            ),
        ],
        52.0,
    );
    let under = if v.adjustable {
        look.file_style_line().to_owned()
    } else {
        "Bei Plex-Servern kommt die Gestaltung immer aus der Datei.".to_owned()
    };
    let file = forms::row_kb(
        cx,
        icons,
        f,
        "sub.file",
        "file-text",
        "Gestaltung aus der Datei übernehmen",
        Some(&under),
        Trail::Switch(look.keep_file_style || !v.adjustable),
        v.adjustable,
    );
    let fancy = forms::setting_group_at(cx, f, "Aufwendige Untertitel", 28.0, vec![file], 52.0);
    let reset = forms::card_view(vec![forms::row_kb(
        cx,
        icons,
        f,
        "sub.reset",
        "arrow-counter-clockwise",
        "Zurücksetzen",
        None,
        Trail::None,
        !look.is_standard(),
    )])
    .padding(ins(26.0, 0.0, 0.0, 0.0));
    let width = if f.form == Form::Desktop {
        ((env.size.w - 72.0 - 72.0) / 2.0).clamp(320.0, 640.0)
    } else {
        (env.size.w - 2.0 * f.edge).clamp(200.0, 560.0)
    };
    let note = |s: &str| label(cx, s, 12.0, 400, quiet, None, swiftly_text::Align::Start);
    let left = vec![
        preview(cx, look, width).padding(ins(22.0, 0.0, 10.0, 0.0)),
        wide(note("Gilt für Untertitel aus Text. Die von Blu-rays sind Bilder und bleiben, wie sie sind."), Alignment::LEADING).frame(Some(width), None, Alignment::LEADING),
    ];
    let strip = v.undo.then(|| {
        let undo = forms::tappable(
            label(
                cx,
                "Rückgängig",
                15.0,
                400,
                color(colour::FONT_QUIET),
                Some(1),
                swiftly_text::Align::End,
            )
            .frame(None, Some(32.0), Alignment::CENTER),
            f,
            "sub.undo",
            8.0,
        );
        let bar = Node::hstack(
            Align::Center,
            Some(12.0),
            vec![
                label(
                    cx,
                    "Zurückgesetzt",
                    15.0,
                    600,
                    color(colour::FONT),
                    Some(1),
                    swiftly_text::Align::Start,
                ),
                Node::spacer(),
                undo,
            ],
        )
        .padding(ins(0.0, 16.0, 0.0, 16.0))
        .frame(Some(360.0), Some(48.0), Alignment::CENTER)
        .background(Node::rect(color(colour::AREA), 14.0), Alignment::CENTER)
        .appear_from(1.0, 0.0)
        .opacity(1.0, swiftly_ui::feel::leap());
        fill_frame(bar.padding(ins(0.0, 0.0, 16.0, 0.0)), Alignment::BOTTOM)
    });
    shell(
        cx,
        icons,
        env,
        f,
        "Untertitel",
        forms::Cols::Equal,
        vec![left, vec![appearance, fancy, reset]],
        strip,
    )
}

// ---- Header editor --------------------------------------------------------------------------------------------------

/// What the header editor draws.
#[derive(Clone, PartialEq, Default)]
pub struct HeaderView {
    /// "Erweitert" is open.
    pub open: bool,
    /// Name and value of every row.
    pub rows: Vec<(String, String)>,
    /// The field with the keyboard: row and `true` for the value.
    pub focus: Option<(usize, bool)>,
    /// "Sichern" is offered (the rows differ from the saved ones).
    pub save: bool,
    /// What the shared editor of the focused row shows (caret, selection, composition).
    pub edit: Option<swiftly_text::Display>,
}

/// `MacAdvanced`: the "Erweitert" toggle and, open, the explanation, the rows, "Header hinzufügen" and (if `view.save`)
/// "Sichern". Keys are `{prefix}.toggle|add|save|del.i|name.i|val.i`.
pub fn header_editor(
    cx: &Cx,
    icons: &Icons,
    f: &Fm,
    prefix: &str,
    v: &HeaderView,
    show_save: bool,
) -> Node {
    let k = |s: &str| format!("{prefix}.{s}");
    let quiet = color(colour::FONT_QUIET);
    let toggle = forms::tappable(
        Node::hstack(
            Align::Center,
            Some(6.0),
            vec![
                label(
                    cx,
                    "Erweitert",
                    12.0,
                    400,
                    quiet,
                    Some(1),
                    swiftly_text::Align::Start,
                ),
                icons.node(
                    if v.open { "minus" } else { "caret-right" },
                    11.0,
                    true,
                    quiet,
                ),
            ],
        )
        .frame(None, Some(24.0), Alignment::LEADING),
        f,
        &k("toggle"),
        6.0,
    );
    let mut col = vec![wide(toggle, Alignment::LEADING)];
    if v.open {
        col.push(forms::note(cx, f, "Für einen Dienst vor deinem Server, etwa Cloudflare Access, Authelia oder Pangolin. Swiftly schickt die Header nur an diese Adresse.", false, false));
        for (i, (name, value)) in v.rows.iter().enumerate() {
            let locked = swiftly_jellyfin::OwnHeaders::is_locked(name);
            let del = forms::tappable(
                icons
                    .node("minus", 16.0, true, color(colour::FONT_VERY_QUIET))
                    .frame(Some(28.0), Some(28.0), Alignment::CENTER),
                f,
                &k(&format!("del.{i}")),
                14.0,
            );
            let line = Node::hstack(
                Align::Center,
                Some(8.0),
                vec![
                    forms::input_ex(
                        cx,
                        icons,
                        f,
                        &k(&format!("name.{i}")),
                        "text-aa",
                        "Header-Name",
                        name,
                        false,
                        v.focus == Some((i, false)),
                        v.edit.as_ref(),
                    ),
                    forms::input_ex(
                        cx,
                        icons,
                        f,
                        &k(&format!("val.{i}")),
                        "key",
                        "Wert",
                        value,
                        true,
                        v.focus == Some((i, true)),
                        v.edit.as_ref(),
                    ),
                    del,
                ],
            );
            let mut one = vec![line];
            if locked {
                one.push(label(
                    cx,
                    "Den setzt Swiftly selbst.",
                    12.0,
                    400,
                    color(colour::ERROR),
                    Some(1),
                    swiftly_text::Align::Start,
                ));
            }
            col.push(wide(
                Node::vstack(Align::Start, Some(6.0), one),
                Alignment::LEADING,
            ));
        }
        let add = forms::tappable(
            Node::hstack(
                Align::Center,
                Some(6.0),
                vec![
                    icons.node("plus", 12.0, true, color(colour::MARK_ACCENT)),
                    label(
                        cx,
                        "Header hinzufügen",
                        12.0,
                        400,
                        color(colour::MARK_ACCENT),
                        Some(1),
                        swiftly_text::Align::Start,
                    ),
                ],
            )
            .frame(None, Some(28.0), Alignment::LEADING),
            f,
            &k("add"),
            6.0,
        );
        col.push(wide(add, Alignment::LEADING));
    }
    if show_save && v.save {
        col.push(
            forms::button(
                cx,
                icons,
                f,
                &k("save"),
                "Sichern",
                Some("check"),
                true,
                false,
                true,
            )
            .padding(ins(4.0, 0.0, 0.0, 0.0)),
        );
    }
    wide(
        Node::vstack(Align::Start, Some(10.0), col),
        Alignment::LEADING,
    )
}

// ---- Seerr ----------------------------------------------------------------------------------------------------------

/// What the Seerr page draws.
#[derive(Clone, PartialEq)]
pub struct SeerrView {
    /// The connection.
    pub conn: crate::seerr_link::SeerrConn,
    /// Address, name and password as typed.
    pub fields: [String; 3],
    /// The field with the keyboard.
    pub focus: Option<usize>,
    /// What the shared editor of the focused field shows (caret, selection, composition).
    pub edit: Option<swiftly_text::Display>,
    /// The headers for the service in front of Seerr.
    pub headers: HeaderView,
}

/// `SeerrSettingsView`.
pub fn seerr_page(cx: &Cx, icons: &Icons, env: &Env, f: &Fm, v: &SeerrView) -> Node {
    let mut col = vec![wide(
        label(cx, "Jellyseerr oder Overseerr. Dann zeigt die Suche auch Titel, die noch nicht auf deinem Server sind, und du kannst sie anfragen.", 15.0, 400, color(colour::FONT_QUIET), None, swiftly_text::Align::Start),
        Alignment::LEADING,
    )
    .padding(ins(10.0, 0.0, 0.0, 0.0))];
    if v.conn.connected {
        let rows = vec![
            forms::row_ex(
                cx,
                icons,
                f,
                "seerr.addr",
                "plug",
                &v.conn.address,
                None,
                Trail::Value(v.conn.session.clone()),
                true,
                false,
            ),
            forms::row_kb(
                cx,
                icons,
                f,
                "seerr.off",
                "x",
                "Verbindung trennen",
                None,
                Trail::None,
                true,
            ),
        ];
        col.push(forms::setting_group(cx, f, "Verbunden", 26.0, rows));
    } else {
        let input = |i: usize, sym: &str, ph: &str, secret: bool| {
            forms::input_ex(
                cx,
                icons,
                f,
                &format!("seerr.f{i}"),
                sym,
                ph,
                &v.fields[i],
                secret,
                v.focus == Some(i),
                v.edit.as_ref(),
            )
        };
        let mut form = vec![
            input(0, "plug", "seerr.example.de", false),
            input(1, "user", "Benutzername", false),
            input(2, "lock", "Passwort", true),
            header_editor(cx, icons, f, "sh", &v.headers, false),
        ];
        if let Some(e) = &v.conn.error {
            form.push(
                wide(
                    label(
                        cx,
                        e,
                        12.0,
                        400,
                        color(colour::ERROR),
                        None,
                        swiftly_text::Align::Start,
                    ),
                    Alignment::LEADING,
                )
                .padding(ins(2.0, 0.0, 0.0, 0.0)),
            );
        }
        // No greyed button: while something is missing there is nothing to press.
        if v.fields.iter().all(|s| !s.is_empty()) {
            form.push(
                forms::button(
                    cx,
                    icons,
                    f,
                    "seerr.go",
                    if v.conn.busy {
                        "Verbinde…"
                    } else {
                        "Verbinden"
                    },
                    Some("plug"),
                    true,
                    false,
                    true,
                )
                .padding(ins(8.0, 0.0, 0.0, 0.0)),
            );
        }
        form.push(forms::note(
            cx,
            f,
            "Swiftly speichert dein Passwort nicht, nur die Anmeldung bei Seerr.",
            false,
            false,
        ));
        col.push(
            wide(
                Node::vstack(Align::Start, Some(12.0), form),
                Alignment::LEADING,
            )
            .padding(ins(26.0, 0.0, 0.0, 0.0)),
        );
    }
    shell(
        cx,
        icons,
        env,
        f,
        "Seerr",
        forms::Cols::One,
        vec![vec![Node::vstack(Align::Start, Some(0.0), col)]],
        None,
    )
}

// ---- Licences -------------------------------------------------------------------------------------------------------

/// The data of `LICENSES/components.json`, embedded.
pub fn licence_data() -> Option<LicenseData> {
    LicenseData::parse(include_bytes!("../../../LICENSES/components.json"))
}

/// "{spdx} · {version}".
pub fn subline(c: &LicenseComponent) -> String {
    format!("{} \u{00B7} {}", c.spdx, c.version)
}

/// The text of a licence file: next to the program (`LICENSES/`), else the source tree.
pub fn licence_text(file: &str) -> Option<String> {
    let mut places = vec![std::path::PathBuf::from("LICENSES")];
    if let Ok(exe) = std::env::current_exe()
        && let Some(dir) = exe.parent()
    {
        places.push(dir.join("LICENSES"));
    }
    places.push(std::path::PathBuf::from(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../LICENSES"
    )));
    places
        .iter()
        .find_map(|d| std::fs::read_to_string(d.join(file)).ok())
}

/// The paragraphs of a licence text (blank-line separated, whitespace folded).
pub fn paragraphs(text: &str) -> Vec<String> {
    text.replace("\r\n", "\n")
        .split("\n\n")
        .map(|p| p.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|p| !p.is_empty())
        .take(300)
        .collect()
}

/// The "Open-Source-Lizenzen" list. Row keys are `lic.{index into data.components}` and `lic.offer`.
pub fn licences_page(
    cx: &Cx,
    icons: &Icons,
    env: &Env,
    f: &Fm,
    data: &LicenseData,
    platform: &str,
) -> Node {
    let row = |i: usize, c: &LicenseComponent| {
        forms::row_kb(
            cx,
            icons,
            f,
            &format!("lic.{i}"),
            "text-align-left",
            &c.name,
            Some(&subline(c)),
            Trail::Chevron,
            true,
        )
    };
    let group = |g: &str| -> Vec<Node> {
        data.components
            .iter()
            .enumerate()
            .filter(|(_, c)| c.group == g && c.platforms.iter().any(|p| p == platform))
            .map(|(i, c)| row(i, c))
            .collect()
    };
    let mut player = group("player");
    player.push(forms::row_kb(
        cx,
        icons,
        f,
        "lic.offer",
        "text-align-left",
        "Quelltext und schriftliches Angebot",
        Some("Woher libmpv kommt und wie du es ersetzt"),
        Trail::Chevron,
        true,
    ));
    let mut body = vec![
        wide(
            label(cx, "Swiftly Player spielt mit libmpv und FFmpeg (LGPL 2.1 oder später). Was sonst noch drinsteckt, steht darunter, mit Lizenz und Urheber.", 15.0, 400, color(colour::FONT_QUIET), None, swiftly_text::Align::Start),
            Alignment::LEADING,
        )
        .padding(ins(10.0, 0.0, 4.0, 0.0)),
        forms::setting_group(cx, f, "libmpv und FFmpeg", 22.0, player),
    ];
    for (title, g) in [
        ("Weitere Bausteine", "app"),
        ("In libmpv eingebaut", "in-vlckit"),
    ] {
        let rows = group(g);
        if !rows.is_empty() {
            body.push(forms::setting_group(cx, f, title, 28.0, rows));
        }
    }
    shell(
        cx,
        icons,
        env,
        f,
        "Open-Source-Lizenzen",
        forms::Cols::One,
        vec![body],
        None,
    )
}

/// One component: Fassung, Lizenz, Urheber, Quelle (opens the address), the note and every "Lizenztext".
pub fn licence_detail(cx: &Cx, icons: &Icons, env: &Env, f: &Fm, c: &LicenseComponent) -> Node {
    let detail = |name: &str, value: &str, route: bool| {
        let mut line = vec![label(
            cx,
            value,
            15.0,
            400,
            color(colour::FONT),
            None,
            swiftly_text::Align::Start,
        )];
        if route {
            line.push(icons.node("arrow-up-right", 12.0, true, color(colour::FONT_VERY_QUIET)));
        }
        wide(
            Node::vstack(
                Align::Start,
                Some(2.0),
                vec![
                    label(
                        cx,
                        name,
                        12.0,
                        400,
                        color(colour::FONT_VERY_QUIET),
                        Some(1),
                        swiftly_text::Align::Start,
                    ),
                    Node::hstack(Align::Center, Some(6.0), line),
                ],
            ),
            Alignment::LEADING,
        )
    };
    let mut rows = vec![
        detail("Fassung", &c.version, false),
        detail("Lizenz", &c.spdx, false),
        detail("Urheber", &c.author, false),
    ];
    let source = detail("Quelle", &c.source, true);
    rows.push(if c.source.starts_with("http") {
        forms::tappable(source, f, "lic.src", 8.0)
    } else {
        source
    });
    if let Some(n) = &c.note {
        rows.push(wide(
            label(
                cx,
                n,
                12.0,
                400,
                color(colour::FONT_QUIET),
                None,
                swiftly_text::Align::Start,
            ),
            Alignment::LEADING,
        ));
    }
    let card = forms::card_view(vec![wide(
        Node::vstack(Align::Start, Some(14.0), rows).padding(ins(14.0, 16.0, 14.0, 16.0)),
        Alignment::LEADING,
    )])
    .padding(ins(8.0, 0.0, 0.0, 0.0));
    let mut body = vec![card];
    for file in &c.texts {
        let paras: Vec<Node> = match licence_text(file) {
            Some(t) => paragraphs(&t)
                .iter()
                .map(|p| {
                    wide(
                        label(
                            cx,
                            p,
                            12.0,
                            400,
                            color(colour::FONT_QUIET),
                            None,
                            swiftly_text::Align::Start,
                        ),
                        Alignment::LEADING,
                    )
                })
                .collect(),
            None => vec![label(
                cx,
                "Der Text fehlt in dieser Fassung.",
                12.0,
                400,
                color(colour::FONT_QUIET),
                None,
                swiftly_text::Align::Start,
            )],
        };
        let inner = wide(
            Node::vstack(Align::Start, Some(10.0), paras).padding(ins(14.0, 16.0, 14.0, 16.0)),
            Alignment::LEADING,
        );
        body.push(forms::setting_group(cx, f, "Lizenztext", 28.0, vec![inner]));
    }
    shell(
        cx,
        icons,
        env,
        f,
        &c.name,
        forms::Cols::One,
        vec![body],
        None,
    )
}

/// "Quelltext und Angebot": the written offer of the licence file.
pub fn offering_page(cx: &Cx, icons: &Icons, env: &Env, f: &Fm, data: &LicenseData) -> Node {
    let mut body = Vec::new();
    for (i, s) in data.offering.sections.iter().enumerate() {
        let paras: Vec<Node> = s
            .paragraphs
            .iter()
            .map(|p| {
                wide(
                    label(
                        cx,
                        p,
                        12.0,
                        400,
                        color(colour::FONT_QUIET),
                        None,
                        swiftly_text::Align::Start,
                    ),
                    Alignment::LEADING,
                )
            })
            .collect();
        let inner = wide(
            Node::vstack(Align::Start, Some(12.0), paras).padding(ins(14.0, 16.0, 14.0, 16.0)),
            Alignment::LEADING,
        );
        body.push(forms::setting_group(
            cx,
            f,
            &s.title,
            if i == 0 { 8.0 } else { 28.0 },
            vec![inner],
        ));
    }
    shell(
        cx,
        icons,
        env,
        f,
        "Quelltext und Angebot",
        forms::Cols::One,
        vec![body],
        None,
    )
}

#[cfg(test)]
mod preview_tests {
    use super::*;

    #[test]
    fn the_sample_picture_is_part_of_the_app_and_is_cut_to_16_by_9() {
        let d =
            swiftly_images::decode::decode(PREVIEW_JPEG, 1280).expect("the sample picture decodes");
        assert!(d.width > 0 && d.height > 0);
        let (w, h, px) = crop_16_9(d.width, d.height, &d.rgba);
        assert_eq!(u64::from(w) * 9, u64::from(h) * 16);
        assert_eq!(px.len(), w as usize * h as usize * 4);
        // A tall picture keeps its full width; a wide one keeps its full height.
        assert_eq!(crop_16_9(100, 400, &vec![0; 100 * 400 * 4]).0, 100);
        assert_eq!(crop_16_9(400, 100, &vec![0; 400 * 100 * 4]).1, 100);
    }

    #[test]
    fn the_preview_gets_its_picture() {
        let cx = Cx::deterministic();
        assert!(preview_picture(&cx).is_some());
        assert_eq!(preview_picture(&cx), preview_picture(&cx), "added once");
    }

    /// The outline and shadow copies of the sample are paint, not text: a screen reader reads the sentence once.
    #[test]
    fn the_sample_sentence_is_read_once() {
        let mut env = Env::new(
            swiftly_layout::Size::new(600.0, 400.0),
            1.0,
            swiftly_ui::Idiom::Desktop,
        );
        env.reduce_motion = true;
        let look = SubtitleLook {
            shadow: true,
            ..SubtitleLook::default()
        };
        let mut u = swiftly_ui::Ui::new(
            |look: &SubtitleLook, _: &Env, cx: &Cx| preview(cx, look, 480.0),
            look,
            env,
            Cx::deterministic(),
        );
        let _ = u.frame(100.0);
        fn count(n: &[swiftly_ui::a11y::A11yNode], what: &str) -> usize {
            n.iter()
                .map(|x| usize::from(x.label.contains(what)) + count(&x.children, what))
                .sum()
        }
        assert_eq!(count(&u.a11y_nodes(), "Hörst du das auch?"), 1);
    }
}

// ---- Home page choices ----------------------------------------------------------------------------------------------

/// What a "Bibliothek hinzufügen" / "Genre hinzufügen" page shows (`GenreSelectionView`, `LibrarySelectionView`).
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct PickView {
    /// The server's answer.
    pub offer: crate::home_choices::Offer<(String, String, bool)>,
    /// The sentence for "the list is empty" (nothing there at all / everything chosen already).
    pub none: &'static str,
    /// The sentence when every entry is chosen already.
    pub all_chosen: &'static str,
    /// How many entries the server has, chosen ones included.
    pub total: usize,
    /// Libraries (true) or genres (false): decides the icon of an entry.
    pub libraries: bool,
}

/// The page of choices: group "Auf deinem Server" with one row per entry (a tap adds it and goes back), or a sentence.
pub fn pick_page(cx: &Cx, icons: &Icons, env: &Env, f: &Fm, title: &str, v: &PickView) -> Node {
    use crate::home_choices::Offer;
    let mut col: Vec<Node> = Vec::new();
    let sentence = |t: &str| {
        wide(
            label(
                cx,
                t,
                15.0,
                400,
                color(colour::FONT_QUIET),
                None,
                swiftly_text::Align::Start,
            ),
            Alignment::LEADING,
        )
        .padding(ins(22.0, 0.0, 0.0, 0.0))
    };
    match &v.offer {
        Offer::Failed => {
            col.push(sentence(
                "Der Server antwortet nicht. Läuft er noch, oder hängt das WLAN?",
            ));
            col.push(
                forms::button(
                    cx,
                    icons,
                    f,
                    "pick.retry",
                    "Erneut versuchen",
                    Some("arrows-clockwise"),
                    true,
                    false,
                    true,
                )
                .padding(ins(12.0, 0.0, 0.0, 0.0)),
            );
        }
        Offer::Ready(list) if list.is_empty() => {
            col.push(sentence(if v.total == 0 { v.none } else { v.all_chosen }));
        }
        Offer::Ready(list) => {
            let rows = list
                .iter()
                .enumerate()
                .map(|(i, (_, name, kind))| {
                    forms::row_kb(
                        cx,
                        icons,
                        f,
                        &format!("pick.add.{i}"),
                        match (v.libraries, *kind) {
                            (false, _) => "tag",
                            (true, true) => "stack",
                            (true, false) => "rows",
                        },
                        name,
                        None,
                        Trail::None,
                        true,
                    )
                })
                .collect();
            col.push(forms::setting_group_at(
                cx,
                f,
                "Auf deinem Server",
                22.0,
                rows,
                52.0,
            ));
        }
        Offer::Idle | Offer::Loading => {}
    }
    shell(
        cx,
        icons,
        env,
        f,
        title,
        forms::Cols::One,
        vec![vec![Node::vstack(Align::Start, Some(0.0), col)]],
        None,
    )
}

/// "Open-Source-Lizenzen" without the inventory (`LicensesView.Missing`).
pub fn licences_missing_page(cx: &Cx, icons: &Icons, env: &Env, f: &Fm) -> Node {
    let t = wide(
        label(
            cx,
            "Die Lizenzliste fehlt in dieser Fassung. Du findest sie auf GitHub in THIRD-PARTY-NOTICES.md.",
            15.0,
            400,
            color(colour::FONT_QUIET),
            None,
            swiftly_text::Align::Start,
        ),
        Alignment::LEADING,
    )
    .padding(ins(22.0, 0.0, 0.0, 0.0));
    shell(
        cx,
        icons,
        env,
        f,
        "Open-Source-Lizenzen",
        forms::Cols::One,
        vec![vec![t]],
        None,
    )
}

#[cfg(test)]
mod segment_row_tests {
    use super::*;
    use swiftly_layout::{Placed, Proposal, Size, layout, size_that_fits};
    use swiftly_ui::Paint;

    fn to_layout(n: &Node) -> swiftly_layout::Node {
        swiftly_layout::Node {
            kind: n.kind.clone(),
            children: n.children.iter().map(to_layout).collect(),
            priority: n.priority,
        }
    }

    /// The placed width and the unshrunk width of every text node `title` that takes part in the layout.
    fn title_widths(n: &Node, p: &Placed, title: &str, out: &mut Vec<(f32, f32)>) {
        if p.hidden {
            return;
        }
        if n.paint
            .iter()
            .any(|a| matches!(a, Paint::Text { text, .. } if text == title))
        {
            let ideal = size_that_fits(&to_layout(n), Proposal::new(None, None)).w;
            out.push((p.frame.w, ideal));
        }
        for (k, c) in n.children.iter().zip(&p.children) {
            title_widths(k, c, title, out);
        }
    }

    /// Whatever the width, a title is never squeezed below its own width: the row stacks the strip under it instead
    /// ("F…" and "P…" beside a strip of three or two segments at 1280 px and 125 %).
    #[test]
    fn a_segment_row_never_cuts_its_title() {
        let cx = Cx::deterministic();
        let icons = Icons::new(&cx, 1.0);
        for title in ["Farbe", "Position", "Größe", "Rand"] {
            for w in (200..700).step_by(2) {
                let strip = Node::fixed(144.0, 32.0);
                let row = segment_row(&cx, &icons, title, "palette", strip);
                let placed = layout(&to_layout(&row), Size::new(w as f32, 300.0));
                let mut found = Vec::new();
                title_widths(&row, &placed, title, &mut found);
                assert!(!found.is_empty(), "{title} at {w}");
                for (got, ideal) in found {
                    assert!(
                        got + 0.5 >= ideal,
                        "{title} is squeezed to {got} of {ideal} at {w} pt"
                    );
                }
            }
        }
    }
}
