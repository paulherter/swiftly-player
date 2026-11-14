//! Shared pieces of the Settings, Downloads and sign-in screens: the page frame with the back header, grouped cards,
//! rows (toggle, value, chevron), buttons, input fields and the profile signal. Sizes follow `SettingRows.swift`
//! (rows 52/60, icon 20 in a 26 column, card corner 16, hairline inset 54) and `ProfileRow` on touch (rows 60, title
//! 17 medium); differences per view are noted in the code.

use crate::browse::wide;
use crate::home::{Form, fill_frame, ins, rgba, text};
use std::cell::Cell;
use swiftly_design::tokens::{colour, desktop, touch};
use swiftly_layout::{Align, Alignment, Axis, EdgeInsets};
use swiftly_render::Color;
use swiftly_ui::components::{color, focus_id};
use swiftly_ui::icons::Icons;
use swiftly_ui::{Action, Cx, Env, FocusLook, Motion, Node};

thread_local! {
    static PROFILE: Cell<bool> = const { Cell::new(false) };
    /// The desktop toolbar strength (0...`home::BAR_STEPS`) of the page being built: the screen sets it from its scroll
    /// offset before the view runs, [`settings_page`] reads it for the `StateBar`.
    static BAR: Cell<u8> = const { Cell::new(0) };
}

/// Sets the toolbar strength the next [`settings_page`] build draws (see `BAR`).
pub fn set_bar(strength: u8) {
    BAR.with(|b| b.set(strength));
}

/// The toolbar strength of a desktop page from its scroll `offset`: the small title fades in as the large one scrolls out.
pub fn bar_for(env: &Env, offset: f64) -> u8 {
    if env.idiom == swiftly_ui::Idiom::Desktop {
        crate::home::bar_strength(offset as f32, crate::home::BAR_SINCE, 26.0)
    } else {
        0
    }
}

/// Called by the tab screens for every tap: the profile button raises the signal the app reads.
pub fn note_tap(a: &Action) {
    crate::desk::note_tap(a);
    if *a == Action::from("profile") {
        PROFILE.with(|p| p.set(true));
    }
}
/// Whether the profile button was tapped since the last call.
pub fn take_profile() -> bool {
    PROFILE.with(|p| p.replace(false))
}

fn style(size: f32, weight: u16) -> swiftly_design::TextStyle {
    swiftly_design::TextStyle {
        size,
        weight,
        tracking: 0.0,
        uppercase: false,
    }
}

/// Sizes of the form pages per layout.
#[derive(Clone, Copy)]
pub struct Fm {
    /// The layout.
    pub form: Form,
    /// Page edge.
    pub edge: f32,
    /// Widest column (cards, forms).
    pub col: f32,
    /// Row height without / with a second line.
    pub row: (f32, f32),
    /// Row title style, second line size, icon size.
    pub title: (f32, u16),
    /// Second line size.
    pub under: f32,
    /// Header height below the safe area.
    pub head: f32,
}

/// The sizes of `env`.
pub fn fm(env: &Env) -> Fm {
    match Form::of(env.idiom) {
        Form::Touch => Fm {
            form: Form::Touch,
            edge: touch::EDGE_SPACING,
            col: 560.0,
            row: (60.0, 60.0),
            title: (17.0, 500),
            under: 13.0,
            head: 56.0,
        },
        Form::Desktop => Fm {
            form: Form::Desktop,
            edge: desktop::EDGE_SPACING,
            col: 640.0,
            row: (52.0, 60.0),
            title: (15.0, 600),
            under: 13.0,
            head: 64.0,
        },
        Form::Tv => Fm {
            form: Form::Tv,
            edge: 80.0,
            col: 1100.0,
            row: (96.0, 112.0),
            title: (30.0, 600),
            under: 22.0,
            head: 120.0,
        },
    }
}

/// A tap target that is also a focus stop on tv.
pub fn tappable(n: Node, f: &Fm, key: &str, corner: f32) -> Node {
    let n = n.key(key).on_tap(Action::from(key));
    if f.form == Form::Tv {
        n.focusable(focus_id(key), Some(FocusLook::tile(corner)))
    } else {
        n
    }
}

/// [`tappable`] that is also a keyboard stop on the desktop (Tab, Shift-Tab, arrows, Return), as the Mac's button rows are.
/// The focus shows as a soft light edge (no magnifying: a Mac row does not grow), and only after the first key.
pub fn tappable_kb(n: Node, f: &Fm, key: &str, corner: f32) -> Node {
    let n = tappable(n, f, key, corner);
    if f.form != Form::Desktop {
        return n;
    }
    let mut look = FocusLook::tile(corner)
        .scaled(1.0)
        .with_glow(rgba(colour::FONT, 0.5));
    look.shadow = None;
    n.focusable(focus_id(key), Some(look))
}

/// What sits at the right end of a row.
pub enum Trail {
    /// Nothing.
    None,
    /// The switch (`ToggleSwitch`: 38 x 22 capsule, 16 knob).
    Switch(bool),
    /// A value in quiet text.
    Value(String),
    /// A value and the chevron.
    ValueChevron(String),
    /// The chevron.
    Chevron,
    /// The check of the chosen entry.
    Check,
    /// The "opens outside" arrow (`external`, 14).
    External,
    /// A small quiet icon (`trailingSymbol`, 16: the sync mark of "Verbindung prüfen").
    Icon(&'static str),
}

/// `ToggleSwitch`.
pub fn toggle_switch(on: bool) -> Node {
    let knob = Node::rect(color(if on { colour::REASON } else { colour::FONT }), 8.0).frame(
        Some(16.0),
        Some(16.0),
        Alignment::CENTER,
    );
    let knob = knob.padding(ins(3.0, 3.0, 3.0, 3.0));
    let track = Node::rect(
        if on {
            color(colour::MARK_ACCENT)
        } else {
            rgba(colour::FONT, 0.2)
        },
        11.0,
    );
    wide(
        knob,
        if on {
            Alignment::TRAILING
        } else {
            Alignment::LEADING
        },
    )
    .frame(Some(38.0), Some(22.0), Alignment::CENTER)
    .background(track, Alignment::CENTER)
}

/// The Mac switch (`SettingRows.swift:170-188`): capsule 38 x 22, off in the margin colour (white 12 %), on in the accent,
/// knob 16 with padding 3 (on `reason`, off `font`); the knob slides over `Theme.toggle` (easeOut 0.10 s), drawn as two
/// knobs that cross-fade because the engine has no animated offset.
pub fn toggle_switch_mac(on: bool) -> Node {
    let m = swiftly_ui::feel::toggle();
    let knob = |c, shown: bool, at: Alignment| {
        let k = Node::rect(color(c), 8.0)
            .frame(Some(16.0), Some(16.0), Alignment::CENTER)
            .padding(ins(3.0, 3.0, 3.0, 3.0));
        wide(k, at).opacity(if shown { 1.0 } else { 0.0 }, m)
    };
    let track = Node::rect(
        if on {
            color(colour::MARK_ACCENT)
        } else {
            color(colour::MARGIN)
        },
        11.0,
    );
    let both = wide(
        knob(colour::FONT, !on, Alignment::LEADING),
        Alignment::LEADING,
    )
    .overlay(
        knob(colour::REASON, on, Alignment::TRAILING),
        Alignment::CENTER,
    );
    both.frame(Some(38.0), Some(22.0), Alignment::CENTER)
        .background(track, Alignment::CENTER)
}

/// The tv switch (`ToggleSwitch` with the settings look): 84 x 50 capsule, knob 42, inset 4.
pub fn toggle_switch_tv(on: bool) -> Node {
    let knob = Node::rect(color(if on { colour::REASON } else { colour::FONT }), 21.0).frame(
        Some(42.0),
        Some(42.0),
        Alignment::CENTER,
    );
    let knob = knob.padding(ins(0.0, 4.0, 0.0, 4.0));
    let track = Node::rect(
        if on {
            color(colour::MARK_ACCENT)
        } else {
            rgba(colour::FONT, 0.2)
        },
        25.0,
    );
    wide(
        knob,
        if on {
            Alignment::TRAILING
        } else {
            Alignment::LEADING
        },
    )
    .frame(Some(84.0), Some(50.0), Alignment::CENTER)
    .background(track, Alignment::CENTER)
}

/// One row (`RowsBody`): icon, title, optional second line, trailing part. `enabled == false` dims it and drops the tap.
#[allow(clippy::too_many_arguments)]
pub fn row(
    cx: &Cx,
    icons: &Icons,
    f: &Fm,
    key: &str,
    symbol: &str,
    title: &str,
    under: Option<&str>,
    trail: Trail,
    enabled: bool,
) -> Node {
    row_ex(
        cx, icons, f, key, symbol, title, under, trail, enabled, enabled,
    )
}

/// [`row`] as a keyboard stop on the desktop (the settings pages).
#[allow(clippy::too_many_arguments)]
pub fn row_kb(
    cx: &Cx,
    icons: &Icons,
    f: &Fm,
    key: &str,
    symbol: &str,
    title: &str,
    under: Option<&str>,
    trail: Trail,
    enabled: bool,
) -> Node {
    row_inner(
        cx, icons, f, key, symbol, title, under, trail, enabled, enabled, true,
    )
}

/// [`row`] with the dimming (`enabled`) apart from the tap (`act`): an info row (`ValueRow` without an action) is not
/// dimmed and has no hover.
#[allow(clippy::too_many_arguments)]
pub fn row_ex(
    cx: &Cx,
    icons: &Icons,
    f: &Fm,
    key: &str,
    symbol: &str,
    title: &str,
    under: Option<&str>,
    trail: Trail,
    enabled: bool,
    act: bool,
) -> Node {
    row_inner(
        cx, icons, f, key, symbol, title, under, trail, enabled, act, false,
    )
}

/// [`row_ex`] as a keyboard stop on the desktop (the settings pages).
#[allow(clippy::too_many_arguments)]
pub fn row_kb_ex(
    cx: &Cx,
    icons: &Icons,
    f: &Fm,
    key: &str,
    symbol: &str,
    title: &str,
    under: Option<&str>,
    trail: Trail,
    enabled: bool,
    act: bool,
) -> Node {
    row_inner(
        cx, icons, f, key, symbol, title, under, trail, enabled, act, true,
    )
}

#[allow(clippy::too_many_arguments)]
fn row_inner(
    cx: &Cx,
    icons: &Icons,
    f: &Fm,
    key: &str,
    symbol: &str,
    title: &str,
    under: Option<&str>,
    trail: Trail,
    enabled: bool,
    act: bool,
    kb: bool,
) -> Node {
    let mut right: Vec<Node> = Vec::new();
    // iPhone and iPad (`ValueRow`, `Shared/PlaybackSettingsView.swift`): value and chevron in the full font colour,
    // the second line 12; the Mac (`SettingRows.swift`) and the tv keep the quiet value.
    let touch = f.form == Form::Touch;
    let tone = if touch {
        colour::FONT
    } else {
        colour::FONT_QUIET
    };
    // tvOS `SettingsRowsStyle`: title and value 30 medium, the value very quiet, the arrow 24 semibold.
    let tv = f.form == Form::Tv;
    let quiet = |s: &str| {
        if tv {
            text(
                cx,
                s,
                style(30.0, 500),
                colour::FONT_VERY_QUIET,
                Some(1),
                swiftly_text::Align::End,
            )
        } else {
            text(
                cx,
                s,
                style(15.0, 400),
                tone,
                Some(1),
                swiftly_text::Align::End,
            )
        }
    };
    let tone = if tv { colour::FONT_VERY_QUIET } else { tone };
    match &trail {
        Trail::Switch(on) => right.push(if tv {
            toggle_switch_tv(*on)
        } else if f.form == Form::Desktop {
            toggle_switch_mac(*on)
        } else {
            toggle_switch(*on)
        }),
        Trail::Value(v) => right.push(quiet(v)),
        Trail::ValueChevron(v) => {
            right.push(quiet(v));
            right.push(icons.node(
                "caret-right",
                if tv { 24.0 } else { 13.0 },
                true,
                color(tone),
            ));
        }
        Trail::Chevron => right.push(icons.node(
            "caret-right",
            if tv { 24.0 } else { 13.0 },
            true,
            color(tone),
        )),
        Trail::Check => right.push(icons.node("check", 17.0, true, color(colour::MARK_ACCENT))),
        Trail::External => right.push(icons.node("arrow-up-right", 14.0, true, color(tone))),
        Trail::Icon(name) => right.push(icons.node(name, 16.0, true, color(colour::FONT_QUIET))),
        Trail::None => {}
    }
    // tv: symbol 40 in a 52 column (`TVSpec.rowSymbol`).
    let sym = if tv { 40.0 } else { 20.0 };
    // On touch the title and the second line wrap (no line limit in `RowsLayout`); the row grows past its minimum.
    // The Mac rows grow the same way (`SettingRows.swift:139`: vertical padding 8, minimum height 52 / 60).
    let grows = touch || f.form == Form::Desktop;
    let max_lines = if grows { None } else { Some(1) };
    let mut lines = vec![text(
        cx,
        title,
        style(f.title.0, if tv { 500 } else { f.title.1 }),
        colour::FONT,
        max_lines,
        swiftly_text::Align::Start,
    )];
    if let Some(u) = under {
        let size = if touch {
            12.0
        } else if tv {
            24.0
        } else {
            f.under
        };
        lines.push(text(
            cx,
            u,
            style(size, 400),
            if tv {
                colour::FONT_QUIET
            } else {
                colour::FONT_VERY_QUIET
            },
            max_lines,
            swiftly_text::Align::Start,
        ));
    }
    let gap = if tv {
        28.0
    } else if f.form == Form::Touch {
        14.0
    } else {
        12.0
    };
    let body = Node::hstack(
        Align::Center,
        Some(gap),
        vec![
            icons.node(symbol, sym, true, color(colour::FONT)).frame(
                Some(if tv { 52.0 } else { sym.max(26.0) }),
                None,
                Alignment::CENTER,
            ),
            Node::vstack(Align::Start, Some(if tv { 4.0 } else { 2.0 }), lines)
                .layout_priority(1.0),
            Node::spacer(),
            Node::hstack(Align::Center, Some(if tv { 12.0 } else { 8.0 }), right)
                .layout_priority(2.0),
        ],
    )
    .padding(EdgeInsets::symmetric(
        if tv { 26.0 } else { 16.0 },
        if grows { 8.0 } else { 0.0 },
    ));
    let min_h = if tv {
        84.0
    } else if under.is_some() {
        f.row.1
    } else {
        f.row.0
    };
    let body = if grows {
        body.flex_frame(swiftly_layout::FlexFrame {
            min_h: Some(min_h),
            align: Some(Alignment::LEADING),
            ..Default::default()
        })
    } else {
        body.frame(None, Some(min_h), Alignment::LEADING)
    };
    let n =
        wide(body, Alignment::LEADING).opacity(if enabled { 1.0 } else { 0.4 }, Motion::Instant);
    if !(enabled && act) {
        return n.key(key);
    }
    let n = if kb {
        tappable_kb(n, f, key, 12.0)
    } else {
        tappable(n, f, key, 12.0)
    };
    if f.form == Form::Desktop {
        // `SettingRows.swift:154-164`: white 6 % surface, radius 12, easeOut 0.12 s; a press keeps the surface.
        n.hover_surface(
            rgba(colour::FONT, swiftly_ui::feel::HOVER_SURFACE_ALPHA),
            12.0,
        )
        .press_style(swiftly_ui::interact::PressStyle::Row)
    } else {
        n
    }
}

/// The hairline between two rows: inset by padding 16 + icon column 26 + gap 12.
pub fn separator_line() -> Node {
    separator_line_at(54.0)
}

/// [`separator_line`] with another left inset: `GroupLine` is 54 (16 + 26 + 12), `Theme.separatorInsetCard` on the
/// Playback and Appearance pages is 52.
pub fn separator_line_at(inset: f32) -> Node {
    wide(
        Node::rect(rgba(colour::FONT, 0.07), 0.0).frame(None, Some(1.0), Alignment::CENTER),
        Alignment::CENTER,
    )
    .padding(ins(0.0, inset, 0.0, 0.0))
}

/// `CardView`: group surface (#1E1E1E), corner 16, padding 4, the rows apart by hairlines.
pub fn card_view(rows: Vec<Node>) -> Node {
    card_view_at(rows, 54.0)
}

/// [`card_view`] with the hairline inset of the page.
pub fn card_view_at(rows: Vec<Node>, inset: f32) -> Node {
    let mut col = Vec::new();
    for (i, r) in rows.into_iter().enumerate() {
        if i > 0 {
            col.push(separator_line_at(inset));
        }
        col.push(r);
    }
    wide(
        Node::vstack(Align::Start, Some(0.0), col).padding(ins(4.0, 4.0, 4.0, 4.0)),
        Alignment::TOP_LEADING,
    )
    .background(
        Node::rect(color(colour::GROUPS_AREA), 16.0),
        Alignment::CENTER,
    )
}

/// `SettingGroup`: the title (`GroupsTitle`, 22 bold, tracking -0.2) 10 above the card; `top` is the gap above.
pub fn setting_group(cx: &Cx, f: &Fm, title: &str, top: f32, rows: Vec<Node>) -> Node {
    setting_group_at(cx, f, title, top, rows, 54.0)
}

/// [`setting_group`] with the hairline inset of the page.
pub fn setting_group_at(
    cx: &Cx,
    f: &Fm,
    title: &str,
    top: f32,
    rows: Vec<Node>,
    inset: f32,
) -> Node {
    let size = if f.form == Form::Tv { 34.0 } else { 22.0 };
    let t = swiftly_design::TextStyle {
        size,
        weight: 700,
        tracking: -0.2,
        uppercase: false,
    };
    let head = if title.is_empty() {
        Node::fixed(0.0, 0.0)
    } else {
        text(
            cx,
            title,
            t,
            colour::FONT,
            Some(1),
            swiftly_text::Align::Start,
        )
        .padding(ins(top, 0.0, 10.0, 0.0))
    };
    wide(
        Node::vstack(
            Align::Start,
            Some(0.0),
            vec![wide(head, Alignment::LEADING), card_view_at(rows, inset)],
        ),
        Alignment::TOP_LEADING,
    )
}

/// `PrimaryButtonStyle` (white, 52 high) or `SecondaryButtonStyle` (area colour; `accent` writes the label in the accent).
#[allow(clippy::too_many_arguments)]
/// Design name: PrimaryButton
pub fn button(
    cx: &Cx,
    icons: &Icons,
    f: &Fm,
    key: &str,
    label: &str,
    symbol: Option<&str>,
    primary: bool,
    accent: bool,
    enabled: bool,
) -> Node {
    let c = if primary {
        colour::REASON
    } else if accent {
        colour::MARK_ACCENT
    } else {
        colour::FONT
    };
    let mut parts = Vec::new();
    if let Some(s) = symbol {
        parts.push(icons.node(s, 18.0, true, color(c)));
    }
    parts.push(text(
        cx,
        label,
        style(if f.form == Form::Tv { 28.0 } else { 17.0 }, 600),
        c,
        Some(1),
        swiftly_text::Align::Center,
    ));
    let h = if f.form == Form::Tv { 80.0 } else { 52.0 };
    let n = wide(
        Node::hstack(Align::Center, Some(9.0), parts).frame(None, Some(h), Alignment::CENTER),
        Alignment::CENTER,
    )
    .background(
        Node::rect(
            if primary {
                color(colour::FONT)
            } else {
                color(colour::AREA)
            },
            12.0,
        ),
        Alignment::CENTER,
    )
    .opacity(if enabled { 1.0 } else { 0.4 }, Motion::Instant);
    if enabled {
        tappable(n, f, key, 12.0)
    } else {
        n.key(key)
    }
}

/// Key of the caret of the focused sign-in field: the anchor of the input method's candidate window.
pub const CARET_KEY: &str = "field.caret";

/// Key of the placeholder of the focused, empty sign-in field: where typed text will start.
pub const START_KEY: &str = "field.start";

/// `InputField`: a 56 high rounded field with a leading symbol, the text (dots when `secret`) or the placeholder and a
/// caret while it has the keyboard.
#[allow(clippy::too_many_arguments)]
/// Design name: InputField
pub fn input(
    cx: &Cx,
    icons: &Icons,
    f: &Fm,
    key: &str,
    symbol: &str,
    placeholder: &str,
    value: &str,
    secret: bool,
    focused: bool,
) -> Node {
    input_ex(
        cx,
        icons,
        f,
        key,
        symbol,
        placeholder,
        value,
        secret,
        focused,
        None,
    )
}

/// [`input`] for the field with the keyboard: `edit` is the shared editor's display (caret, selection, composition), drawn
/// by `swiftly_ui::field::field_content` (keyed `field.text`, so the pointer can place the caret in it).
#[allow(clippy::too_many_arguments)]
pub fn input_ex(
    cx: &Cx,
    icons: &Icons,
    f: &Fm,
    key: &str,
    symbol: &str,
    placeholder: &str,
    value: &str,
    secret: bool,
    focused: bool,
    edit: Option<&swiftly_text::Display>,
) -> Node {
    let mut row = vec![icons.node(symbol, 17.0, true, color(colour::FONT_QUIET))];
    let size = if f.form == Form::Tv { 28.0 } else { 15.0 };
    if let (true, Some(d)) = (focused, edit) {
        let look = swiftly_ui::field::FieldLook {
            style: swiftly_text::TextStyle::new(size, 400),
            text: color(colour::FONT),
            placeholder: color(colour::FONT_VERY_QUIET),
            caret: color(colour::MARK_ACCENT),
            selection: rgba(colour::MARK_ACCENT, 0.35),
            caret_height: None,
        };
        let view = swiftly_ui::field::FieldView {
            display: d.clone(),
            placeholder: placeholder.to_owned(),
            focused: true,
            caret_on: true,
            touch: false,
            loupe: None,
        };
        row.push(swiftly_ui::field::field_content(cx, &view, &look));
    } else if value.is_empty() {
        row.push(text(
            cx,
            placeholder,
            style(size, 400),
            colour::FONT_VERY_QUIET,
            Some(1),
            swiftly_text::Align::Start,
        ));
    } else {
        let shown = if secret {
            "\u{2022}".repeat(value.chars().count())
        } else {
            value.to_owned()
        };
        row.push(text(
            cx,
            &shown,
            style(size, 400),
            colour::FONT,
            Some(1),
            swiftly_text::Align::Start,
        ));
    }
    row.push(Node::spacer());
    let h = if f.form == Form::Tv { 80.0 } else { 56.0 };
    let n = Node::hstack(Align::Center, Some(10.0), row)
        .padding(EdgeInsets::symmetric(14.0, 0.0))
        .frame(None, Some(h), Alignment::LEADING);
    tappable(
        wide(n, Alignment::LEADING)
            .background(Node::rect(color(colour::AREA), 10.0), Alignment::CENTER),
        f,
        key,
        10.0,
    )
}

/// A quiet note line (`Theme.small`, very quiet), `error` in the error colour, centred when `centre`.
pub fn note(cx: &Cx, f: &Fm, s: &str, error: bool, centre: bool) -> Node {
    let t = text(
        cx,
        s,
        style(if f.form == Form::Tv { 22.0 } else { 12.0 }, 400),
        if error {
            colour::ERROR
        } else {
            colour::FONT_VERY_QUIET
        },
        Some(3),
        if centre {
            swiftly_text::Align::Center
        } else {
            swiftly_text::Align::Start
        },
    );
    wide(
        t,
        if centre {
            Alignment::CENTER
        } else {
            Alignment::LEADING
        },
    )
}

/// `SubpageHeader`: the back arrow (44 x 44 target) and the title in one line, over a ground that fades the content.
/// Design name: SubpageHeader
fn header(cx: &Cx, icons: &Icons, env: &Env, f: &Fm, title: &str, right: Option<Node>) -> Node {
    let h = env.safe.top + f.head;
    let sz = if f.form == Form::Tv { 40.0 } else { 20.0 };
    let back = tappable(
        icons
            .node("caret-left", sz, true, color(colour::FONT))
            .frame(Some(44.0), Some(44.0), Alignment::CENTER)
            .a11y_label(swiftly_ui::a11y::Role::Button, "Zurück"),
        f,
        "back",
        22.0,
    );
    let t = swiftly_design::TextStyle {
        size: if f.form == Form::Tv { 44.0 } else { 26.0 },
        ..style(26.0, 700)
    };
    let row = Node::hstack(
        Align::Center,
        Some(6.0),
        vec![
            back,
            text(
                cx,
                title,
                t,
                colour::FONT,
                Some(1),
                swiftly_text::Align::Start,
            )
            .frame(
                Some((env.size.w - 2.0 * f.edge - 120.0).max(100.0)),
                None,
                Alignment::LEADING,
            ),
            Node::spacer(),
            right.unwrap_or_else(|| Node::fixed(0.0, 0.0)),
        ],
    )
    .padding(ins(env.safe.top, f.edge - 12.0, 0.0, f.edge - 12.0))
    .frame(None, Some(h), Alignment::TOP_LEADING);
    let fade = Node::rect(Color::new(0.063, 0.063, 0.063, 0.94), 0.0);
    row.background(fade, Alignment::CENTER)
}

/// `MacFlowPage`: the title and `body` in one column at the top (58 down); `centred` puts the column in the middle of the
/// window (first start, no sidebar), else it sits at the left edge like every subpage. Touch and tv use [`page`].
#[allow(clippy::too_many_arguments)]
pub fn flow_page(
    cx: &Cx,
    icons: &Icons,
    env: &Env,
    f: &Fm,
    title: &str,
    body: Vec<Node>,
    centred: bool,
) -> Node {
    if !centred || f.form != Form::Desktop {
        return page(cx, icons, env, f, title, None, body, None);
    }
    let mut rows = vec![
        page_title(cx, title)
            .frame(Some(f.col), None, Alignment::LEADING)
            .padding(ins(0.0, 0.0, 18.0, 0.0)),
    ];
    rows.extend(body);
    let col = Node::vstack(Align::Start, Some(0.0), rows).frame(
        Some(f.col),
        None,
        Alignment::TOP_LEADING,
    );
    let content =
        col.padding(ins(58.0, 0.0, 40.0, 0.0))
            .frame(Some(env.size.w), None, Alignment::TOP);
    let scroll = Node::scroll(Axis::Vertical, None, content).key("form-scroll");
    let strip = crate::home::state_bar(cx, title, BAR.with(Cell::get));
    fill_frame(scroll, Alignment::TOP_LEADING)
        .overlay(strip, Alignment::TOP)
        .overlay(back_arrow(icons, f), Alignment::TOP_LEADING)
        .background(Node::rect(color(colour::REASON), 0.0), Alignment::CENTER)
}

/// A full page: `body` scrolls under the header (column at most `Fm::col` wide), `overlay` (a sheet) covers all.
#[allow(clippy::too_many_arguments)]
pub fn page(
    cx: &Cx,
    icons: &Icons,
    env: &Env,
    f: &Fm,
    title: &str,
    right: Option<Node>,
    body: Vec<Node>,
    overlay: Option<Node>,
) -> Node {
    if f.form == Form::Desktop && right.is_none() {
        // The Mac has no page header of its own: its toolbar carries the back and forward arrows, the title is a big
        // one in the page (small in the toolbar once scrolled). The touch header would sit under those arrows.
        let col = Node::vstack(Align::Start, Some(0.0), body).frame(
            Some(f.col),
            None,
            Alignment::TOP_LEADING,
        );
        return settings_page(
            cx,
            icons,
            env,
            f,
            title,
            18.0,
            Cols::One,
            vec![vec![col]],
            vec![],
            overlay,
        );
    }
    let bottom = if f.form == Form::Touch {
        env.safe.bottom + 40.0
    } else {
        48.0
    };
    let col = Node::vstack(Align::Start, Some(0.0), body)
        .padding(ins(0.0, f.edge, bottom, f.edge))
        .frame(
            Some((f.col + 2.0 * f.edge).min(env.size.w)),
            None,
            Alignment::TOP_LEADING,
        );
    let col = wide(col, Alignment::TOP).flex_frame(swiftly_layout::FlexFrame {
        max_w: Some(f32::INFINITY),
        align: Some(Alignment::TOP),
        ..swiftly_layout::FlexFrame::default()
    });
    let scroll = Node::scroll(
        Axis::Vertical,
        None,
        col.padding(ins(env.safe.top + f.head + 6.0, 0.0, 0.0, 0.0)),
    )
    .key("form-scroll");
    let p = fill_frame(scroll, Alignment::TOP_LEADING)
        .overlay(
            wide(header(cx, icons, env, f, title, right), Alignment::TOP),
            Alignment::TOP,
        )
        .background(Node::rect(color(colour::REASON), 0.0), Alignment::CENTER);
    let p = fill_frame(p, Alignment::TOP_LEADING);
    match overlay {
        Some(o) => p.overlay(o, Alignment::BOTTOM),
        None => p,
    }
}

/// How the columns of a desktop settings page are laid out (`SettingsView.swift:26`, `Style.swift:135-145`).
#[derive(Clone, Copy, PartialEq)]
pub enum Cols {
    /// Two columns of at most 470, gap 24 (Allgemein, Profil); narrower pages keep two columns of less width, like the Mac's
    /// `HStack` of `maxWidth: 470` children.
    Fixed,
    /// Two equal columns, gap 72, at most 1366 together (Wiedergabe, Darstellung).
    Equal,
    /// One column of at most 700 (reading width).
    One,
}

/// The title of a Mac page (`MacPageTitle`): 30 bold, tracking -0.5.
pub fn page_title(cx: &Cx, title: &str) -> Node {
    let t = swiftly_design::TextStyle {
        size: 30.0,
        weight: 700,
        tracking: -0.5,
        uppercase: false,
    };
    wide(
        text(
            cx,
            title,
            t,
            colour::FONT,
            Some(1),
            swiftly_text::Align::Start,
        ),
        Alignment::LEADING,
    )
}

/// Where the Mac `NavArrows` chevron sits in a page (x, y, w, h): the window's drag strip must leave it alone when the
/// sidebar and its arrows are not there (first start), or a click on it would move the window instead of going back.
pub const BACK_RECT: [f32; 4] = [14.0, 6.0, 42.0, 40.0];

/// Whether `(x, y)` is on the back chevron of a page ([`BACK_RECT`], the chevron plus its tap margin).
pub fn on_back_arrow(x: f32, y: f32) -> bool {
    let r = BACK_RECT;
    x >= r[0] && x <= r[0] + r[2] && y >= r[1] && y <= r[1] + r[3]
}

/// The back chevron of a Mac page, 30 x 28 at (20, 12) like `NavArrows`.
pub fn back_arrow(icons: &Icons, f: &Fm) -> Node {
    tappable(
        icons
            .node("caret-left", 16.0, true, color(colour::FONT))
            .frame(Some(30.0), Some(28.0), Alignment::CENTER)
            .a11y_label(swiftly_ui::a11y::Role::Button, "Zurück"),
        f,
        "back",
        6.0,
    )
    .tooltip("Zurück")
    .padding(ins(12.0, 20.0, 0.0, 0.0))
}

/// A page of the first start (no sidebar): the column of `body` centred in the window, the big title at the top over the
/// column's width and the back chevron top left, like the Mac's `ServerView` (a centred stack, the header as an overlay).
pub fn centred_page(cx: &Cx, icons: &Icons, f: &Fm, title: &str, body: Vec<Node>) -> Node {
    let col = Node::vstack(Align::Start, Some(0.0), body).frame(
        Some(f.col),
        None,
        Alignment::TOP_LEADING,
    );
    let head = page_title(cx, title)
        .frame(Some(f.col), None, Alignment::LEADING)
        .padding(ins(58.0, 0.0, 0.0, 0.0));
    fill_frame(col, Alignment::CENTER)
        .overlay(fill_frame(head, Alignment::TOP), Alignment::TOP)
        .overlay(back_arrow(icons, f), Alignment::TOP_LEADING)
        .background(Node::rect(color(colour::REASON), 0.0), Alignment::CENTER)
}

/// A Mac settings page (`SettingsView.swift:20-75`): a scroll view with padding h 36, top 58, bottom 40, the title, the
/// `columns` side by side (one column when the window is too narrow), the `footer` below, the back arrow top left and
/// `overlay` centred over all.
#[allow(clippy::too_many_arguments)]
pub fn settings_page(
    cx: &Cx,
    icons: &Icons,
    env: &Env,
    f: &Fm,
    title: &str,
    title_gap: f32,
    cols: Cols,
    columns: Vec<Vec<Node>>,
    footer: Vec<Node>,
    overlay: Option<Node>,
) -> Node {
    let avail = (env.size.w - 72.0).max(200.0);
    let (w, gap, two) = match cols {
        Cols::Fixed if avail >= 560.0 => (((avail.min(964.0) - 24.0) / 2.0).floor(), 24.0, true),
        Cols::Equal if avail >= 700.0 => (((avail.min(1366.0) - 72.0) / 2.0).floor(), 72.0, true),
        Cols::Fixed | Cols::Equal => (avail.min(640.0), 0.0, false),
        Cols::One => (avail.min(700.0), 0.0, false),
    };
    let col = |items: Vec<Node>| {
        Node::vstack(Align::Start, Some(0.0), items).frame(Some(w), None, Alignment::TOP_LEADING)
    };
    let body = if two && columns.len() > 1 {
        Node::hstack(
            Align::Start,
            Some(gap),
            columns.into_iter().map(col).collect(),
        )
    } else {
        // One column: the groups of the second column follow the first with the gap of every other group.
        let mut flat: Vec<Node> = Vec::new();
        for (i, items) in columns.into_iter().enumerate() {
            for (j, node) in items.into_iter().enumerate() {
                flat.push(if i > 0 && j == 0 && !flat.is_empty() {
                    node.padding(ins(18.0, 0.0, 0.0, 0.0))
                } else {
                    node
                });
            }
        }
        col(flat)
    };
    let mut page = vec![
        page_title(cx, title)
            .frame(Some(avail), None, Alignment::LEADING)
            .padding(ins(0.0, 0.0, title_gap, 0.0)),
        body,
    ];
    page.extend(footer);
    let content = Node::vstack(Align::Start, Some(0.0), page)
        .padding(ins(58.0, 36.0, 40.0, 36.0))
        .frame(Some(env.size.w), None, Alignment::TOP_LEADING);
    let scroll = Node::scroll(Axis::Vertical, None, content).key("form-scroll");
    // `StateBar` (the edge glow and the small page title once the large one has scrolled out); the arrows' column holds
    // the back chevron at the same place as the Mac's `NavArrows` (30 x 28 at 20, 12).
    let back = back_arrow(icons, f);
    let strip = crate::home::state_bar(cx, title, BAR.with(Cell::get));
    let p = fill_frame(scroll, Alignment::TOP_LEADING)
        .overlay(strip, Alignment::TOP)
        .overlay(back, Alignment::TOP_LEADING)
        .background(Node::rect(color(colour::REASON), 0.0), Alignment::CENTER);
    let p = fill_frame(p, Alignment::TOP_LEADING);
    match overlay {
        Some(o) => p.overlay(o, Alignment::CENTER),
        None => p,
    }
}

/// The input and frame methods every pushed form screen shares. The screen has `ui`, `closed`, `drain()` and
/// `go_back() -> bool` (true when it used the back itself, e.g. closed a sheet).
#[macro_export]
macro_rules! form_io {
    () => {
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
        /// Back: closes a sheet first, then the page.
        pub fn back(&mut self, _now: f64) -> bool {
            if !self.go_back() {
                self.closed = true;
            }
            true
        }
        /// A new window size or scale.
        pub fn set_env(&mut self, env: swiftly_ui::Env) {
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
            if down && matches!(key, swiftly_ui::NavKey::Escape) && self.escape_backs() {
                self.back(now);
                return swiftly_ui::Outcome::None;
            }
            let out = self.ui.nav_key(key, down, now);
            self.drain();
            out
        }
        /// One frame at `now` ms.
        pub fn frame(&mut self, now: f64) -> (swiftly_render::DrawList, bool) {
            use $crate::hub::HubSlotExt as _;
            self.clock(now);
            self.hub.frame(now);
            self.sync();
            let mut list = self.ui.frame(now);
            self.hub.finish(&mut list);
            self.drain();
            let wants = self.ui.needs_frame() || self.hub.busy();
            (list, wants)
        }
        /// Another frame is wanted.
        pub fn wants_frame(&self) -> bool {
            use $crate::hub::HubSlotExt as _;
            self.ui.needs_frame() || self.hub.busy()
        }
        /// The services the renderers read.
        pub fn cx(&self) -> &swiftly_ui::Cx {
            self.ui.cx()
        }
        /// Renders a list with the software renderer.
        pub fn render_software(
            &self,
            list: &swiftly_render::DrawList,
        ) -> swiftly_render::RgbaImage {
            self.ui.render(list, swiftly_render::Color::BLACK)
        }
        /// Focused key on tv.
        pub fn focused(&self) -> Option<swiftly_ui::FocusId> {
            self.ui.focused()
        }
        fn drain(&mut self) {
            for ev in self.ui.take_events() {
                if let swiftly_ui::UiEvent::Tap(a) = ev {
                    self.tapped(&a);
                }
            }
        }
    };
}

/// What one row of the Home group or the Genres group carries (`ChoiceRow` and `GenreRow` of `AppearanceView.swift`).
pub struct HomeRowSpec<'a> {
    /// The tap key of the row (it toggles the switch when there is one).
    pub key: &'a str,
    /// The icon.
    pub symbol: &'a str,
    /// The title (a name from the server is shown as it is).
    pub title: &'a str,
    /// The switch of a fixed row.
    pub switch: Option<bool>,
    /// The key of the remove cross (libraries and genres).
    pub remove: Option<String>,
    /// The Move Up and Move Down controls: key and whether there is a row to swap with.
    pub moves: Option<[(String, bool); 2]>,
}

/// A small quiet icon button of a Home row: 22 x 22, dimmed while it has nothing to do.
fn home_button(icons: &Icons, f: &Fm, key: &str, name: &str, size: f32, enabled: bool) -> Node {
    let n = icons
        .node(name, size, true, color(colour::FONT_QUIET))
        .frame(Some(22.0), Some(22.0), Alignment::CENTER)
        .opacity(if enabled { 0.6 } else { 0.2 }, Motion::Instant);
    if enabled {
        tappable(n, f, key, 6.0).hover_surface(rgba(colour::FONT, 0.10), 6.0)
    } else {
        n.key(key)
    }
}

/// A row of the Home page group: icon 20 (quiet), title, then the switch or the cross and the two move arrows. 44 high,
/// padding 12, gap 14 as on the Mac; the Mac's drag handle is the pair of arrows here (and Alt + Up / Down on a
/// focused row), because the window has no drag-and-drop between rows.
pub fn home_row(cx: &Cx, icons: &Icons, f: &Fm, s: &HomeRowSpec<'_>) -> Node {
    let mut right: Vec<Node> = Vec::new();
    if let Some(on) = s.switch {
        right.push(toggle_switch_mac(on));
    }
    if let Some(k) = &s.remove {
        right.push(home_button(icons, f, k, "x", 12.0, true));
    }
    if let Some([(up, can_up), (down, can_down)]) = &s.moves {
        right.push(home_button(icons, f, up, "caret-up", 13.0, *can_up));
        right.push(home_button(icons, f, down, "caret-down", 13.0, *can_down));
    }
    let body = Node::hstack(
        Align::Center,
        Some(14.0),
        vec![
            icons
                .node(s.symbol, 20.0, true, color(colour::FONT_QUIET))
                .frame(Some(20.0), None, Alignment::CENTER),
            text(
                cx,
                s.title,
                style(15.0, 600),
                colour::FONT,
                Some(1),
                swiftly_text::Align::Start,
            )
            .layout_priority(1.0),
            Node::spacer(),
            Node::hstack(Align::Center, Some(8.0), right).layout_priority(2.0),
        ],
    )
    .padding(EdgeInsets::symmetric(12.0, 0.0))
    .flex_frame(swiftly_layout::FlexFrame {
        min_h: Some(44.0),
        align: Some(Alignment::LEADING),
        ..Default::default()
    });
    let n = wide(body, Alignment::LEADING);
    if s.switch.is_some() {
        tappable_kb(n, f, s.key, 0.0).hover_surface(rgba(colour::FONT, 0.06), 0.0)
    } else {
        n.key(s.key).hover_surface(rgba(colour::FONT, 0.06), 0.0)
    }
}
