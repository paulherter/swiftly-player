//! Shared components built from swiftly-design tokens: `Tile`, `Rail`, `PressButton`, and a `page` background.

use crate::cx::{Cx, ImageId};
use crate::env::Env;
use crate::focus::{FocusId, ScopeSpec};
use crate::tuning;
use crate::view::{Action, FocusLook, Key, Node, Paint};
use swiftly_design::tokens::{colour, touch, tv};
use swiftly_layout::{Align, Alignment, Axis, EdgeInsets, FlexFrame, Proposal, Size};
use swiftly_render::Color;
use swiftly_text::TextStyle;

/// A design colour as a render colour.
pub fn color(c: swiftly_design::Colour) -> Color {
    Color::new(c.r, c.g, c.b, c.a)
}

/// Height of `lines` lines of the tile title style.
pub fn tile_title_height(cx: &Cx, lines: usize) -> f32 {
    let style = TextStyle::from(touch::text::TILE);
    cx.measure_text("Ag", &style, Some(1), Proposal::NIL).h * lines as f32
}

/// The size one tile takes in a rail: poster, gap and room for the title lines.
pub fn tile_slot(cx: &Cx) -> Size {
    Size::new(
        touch::TILE_WIDTH,
        touch::TILE_HEIGHT
            + tuning::TILE_TITLE_GAP
            + tile_title_height(cx, tuning::TILE_TITLE_LINES),
    )
}

/// A poster tile: poster 116 x 174, radius 10, 1 pt edge, title below. Taps report `action` and show the press feedback.
/// Design name: PosterTile
pub fn poster_tile(
    cx: &Cx,
    key: impl Into<Key>,
    title: &str,
    image: ImageId,
    action: impl Into<Action>,
) -> Node {
    let poster = Node::image(
        image,
        touch::TILE_WIDTH,
        touch::TILE_HEIGHT,
        touch::CORNER_TILE,
    )
    .paint(Paint::Stroke {
        color: color(colour::TILE_BORDER),
        width: 1.0,
        radius: touch::CORNER_TILE,
    });
    let title = Node::text(
        cx,
        title,
        &TextStyle::from(touch::text::TILE),
        color(colour::FONT),
        Some(tuning::TILE_TITLE_LINES),
        swiftly_text::Align::Start,
    );
    Node::vstack(
        Align::Start,
        Some(tuning::TILE_TITLE_GAP),
        vec![poster, title],
    )
    .key(key)
    .on_tap(action)
}

/// A horizontal lazy row of tiles with a section header. `item(i)` builds tile `i` when it nears the viewport.
pub fn rail(
    cx: &Cx,
    key: impl Into<Key>,
    title: &str,
    count: usize,
    item: impl Fn(usize) -> Node + 'static,
) -> Node {
    let slot = tile_slot(cx);
    let step = touch::TILE_WIDTH + touch::TILE_SPACING;
    let row = Node::scroll(
        Axis::Horizontal,
        tuning::RAIL_SNAPS.then_some(step),
        Node::lazy_stack(
            Axis::Horizontal,
            touch::TILE_SPACING,
            count,
            slot,
            touch::EDGE_SPACING,
            touch::EDGE_SPACING,
            item,
        ),
    )
    .frame(None, Some(slot.h), Alignment::TOP_LEADING);
    let header = Node::text(
        cx,
        title,
        &TextStyle::from(touch::text::RAIL),
        color(colour::FONT),
        Some(1),
        swiftly_text::Align::Start,
    )
    .padding(EdgeInsets {
        top: 0.0,
        leading: touch::EDGE_SPACING,
        bottom: 0.0,
        trailing: touch::EDGE_SPACING,
    });
    Node::vstack(
        Align::Start,
        Some(tuning::RAIL_HEADER_GAP),
        vec![header, row],
    )
    .key(key)
}

/// Look of a [`press_button`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ButtonStyle {
    /// Accent fill, dark label.
    Primary,
    /// Translucent fill with an edge, light label.
    Secondary,
}

/// A pill button (height 56) with press feedback.
/// Design name: PrimaryButton (alias: also covers the secondary look through [`ButtonStyle`])
pub fn press_button(
    cx: &Cx,
    key: impl Into<Key>,
    label: &str,
    style: ButtonStyle,
    action: impl Into<Action>,
) -> Node {
    let (text_color, fill) = match style {
        ButtonStyle::Primary => (colour::ORIGINAL_ON_ACCENT, colour::MARK_ACCENT),
        ButtonStyle::Secondary => (colour::FONT, colour::SELECTED),
    };
    let text = Node::text(
        cx,
        label,
        &TextStyle::from(touch::text::CATEGORY),
        color(text_color),
        Some(1),
        swiftly_text::Align::Center,
    )
    .padding(EdgeInsets::symmetric(tuning::BUTTON_LABEL_PADDING, 0.0))
    .frame(None, Some(touch::CONTROL_HEIGHT), Alignment::CENTER);
    let mut back = Node::rect(color(fill), 999.0);
    if style == ButtonStyle::Secondary {
        back = back.paint(Paint::Stroke {
            color: color(colour::MARGIN),
            width: 1.0,
            radius: 999.0,
        });
    }
    text.background(back, Alignment::CENTER)
        .key(key)
        .on_tap(action)
}

/// A page: the ground colour behind a column that fills the window, content hugging the top-leading corner.
pub fn page(env: &Env, children: Vec<Node>) -> Node {
    Node::vstack(Align::Start, Some(touch::RAILS_SPACING), children)
        .padding(EdgeInsets {
            top: env.safe.top + touch::HEADER_TOP,
            leading: 0.0,
            bottom: 0.0,
            trailing: 0.0,
        })
        .flex_frame(FlexFrame {
            max_w: Some(f32::INFINITY),
            max_h: Some(f32::INFINITY),
            align: Some(Alignment::TOP_LEADING),
            ..FlexFrame::default()
        })
        .background(Node::rect(color(colour::REASON), 0.0), Alignment::CENTER)
}

// ---- tv: focusable components --------------------------------------------------------------------------------------

/// The focus id a keyed node gets: the key itself.
pub fn focus_id(key: impl Into<Key>) -> FocusId {
    FocusId(key.into().0)
}

/// Corner radius (pt) of a tv poster and its focus shadow. Source: the touch tile radius scaled to the 1.8 x larger
/// tv poster, estimated.
const TV_TILE_RADIUS: f32 = 18.0;

/// A tv poster tile (208 x 312, title below) that takes focus: it lifts to 1.06 with the one soft shadow, springs
/// back when focus leaves; the tap is `action`, a long press is `long` (the tile menu).
/// Design name: TileCard (TV)
pub fn tile_card(
    cx: &Cx,
    key: impl Into<Key>,
    title: &str,
    image: ImageId,
    action: impl Into<Action>,
    long: Option<Action>,
) -> Node {
    let key = key.into();
    let poster = Node::image(image, tv::POSTER_WIDTH, tv::POSTER_HEIGHT, TV_TILE_RADIUS).paint(
        Paint::Stroke {
            color: color(colour::TILE_BORDER),
            width: 1.0,
            radius: TV_TILE_RADIUS,
        },
    );
    let label = Node::text(
        cx,
        title,
        &TextStyle::from(tv::text::TILE),
        color(colour::FONT),
        Some(tuning::TILE_TITLE_LINES),
        swiftly_text::Align::Start,
    );
    let mut n = Node::vstack(
        Align::Start,
        Some(tuning::TILE_TITLE_GAP),
        vec![poster, label],
    )
    .key(key)
    .on_tap(action)
    .focusable(focus_id(key), Some(FocusLook::tile(TV_TILE_RADIUS)));
    if let Some(l) = long {
        n = n.on_long_press(l);
    }
    n
}

/// A tv pill button (height 76) that takes focus, as the Swift `ButtonLabel`: white 10 % fill and white label at rest,
/// solid white with the dark ground colour as label when focused, lifted to 1.06. `style` only keeps the call sites of
/// the touch button readable: the Swift tv buttons have no accent fill (the accent is reserved for Direct Play).
/// Design name: ThemedButton (TV)
pub fn themed_button(
    cx: &Cx,
    key: impl Into<Key>,
    label: &str,
    _style: ButtonStyle,
    action: impl Into<Action>,
) -> Node {
    themed_button_height(cx, key, label, tv::BUTTON_HEIGHT, action)
}

/// A [`themed_button`] of another height (the tab capsules of the top bar are 68 high).
pub fn themed_button_height(
    cx: &Cx,
    key: impl Into<Key>,
    label: &str,
    height: f32,
    action: impl Into<Action>,
) -> Node {
    let key = key.into();
    let mut text = Node::text(
        cx,
        label,
        &TextStyle::from(tv::text::BUTTON),
        color(colour::FONT),
        Some(1),
        swiftly_text::Align::Center,
    );
    // The label's own paint becomes one that fades to the focused colour.
    text.paint = text
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
                rest: color(colour::FONT),
                focused: color(colour::REASON),
                lines,
                align,
            },
            other => other,
        })
        .collect();
    let text =
        text.padding(EdgeInsets::symmetric(40.0, 0.0))
            .frame(None, Some(height), Alignment::CENTER);
    let surface = Node::rect(
        Color::new(1.0, 1.0, 1.0, tuning::FOCUS_BUTTON_REST_ALPHA),
        999.0,
    )
    .paint(Paint::FocusFill {
        color: Color::WHITE,
        radius: 999.0,
    });
    text.background(surface, Alignment::CENTER)
        .key(key)
        .on_tap(action)
        .focusable(focus_id(key), Some(FocusLook::tile(999.0)))
}

/// A tv rail: a header over a horizontal lazy row of focusable tiles. The rail is a focus section, so a vertical move
/// into it keeps the column; `item(i)` builds tile `i` (use [`tile_card`]).
pub fn tv_rail(
    cx: &Cx,
    key: impl Into<Key>,
    title: &str,
    count: usize,
    item: impl Fn(usize) -> Node + 'static,
) -> Node {
    let key = key.into();
    let slot = Size::new(
        tv::POSTER_WIDTH,
        tv::POSTER_HEIGHT
            + tuning::TILE_TITLE_GAP
            + cx.measure_text(
                "Ag",
                &TextStyle::from(tv::text::TILE),
                Some(1),
                Proposal::NIL,
            )
            .h * tuning::TILE_TITLE_LINES as f32,
    );
    let row = Node::scroll(
        Axis::Horizontal,
        None,
        Node::lazy_stack(
            Axis::Horizontal,
            tv::TILE_SPACING,
            count,
            slot,
            tv::RAILS_PADDING,
            tv::RAILS_PADDING,
            item,
        )
        .padding(EdgeInsets {
            top: tuning::FOCUS_HEADROOM_PT,
            leading: 0.0,
            bottom: tuning::FOCUS_HEADROOM_PT,
            trailing: 0.0,
        }),
    )
    .frame(
        None,
        Some(slot.h + 2.0 * tuning::FOCUS_HEADROOM_PT),
        Alignment::TOP_LEADING,
    );
    let header = Node::text(
        cx,
        title,
        &TextStyle::from(tv::text::RAIL),
        color(colour::FONT),
        Some(1),
        swiftly_text::Align::Start,
    )
    .padding(EdgeInsets {
        top: 0.0,
        leading: tv::RAILS_PADDING,
        bottom: 0.0,
        trailing: 0.0,
    });
    Node::vstack(
        Align::Start,
        Some(tv::RAILS_HEADER_PADDING - tuning::FOCUS_HEADROOM_PT),
        vec![header, row],
    )
    .key(key)
    .focus_scope(ScopeSpec::section(focus_id(key)))
}
