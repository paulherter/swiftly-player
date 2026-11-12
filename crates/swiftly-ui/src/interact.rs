//! Pointer-facing behaviour of a node: hover, the three Mac press styles, selected and disabled looks, the keyboard focus
//! ring, cursor shape, tooltip and the secondary click. All of it is declared on the node (`Node::hover_surface`,
//! `Node::press_style`, ...) and animated by the UI with the Mac's curves (`crate::feel`).

use crate::view::Action;
use swiftly_render::Color;

/// The mouse cursor a node asks for. The Mac app never sets one (arrow everywhere); text fields and resize handles do.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Cursor {
    /// The arrow.
    #[default]
    Arrow,
    /// The pointing hand.
    Pointer,
    /// The text I-beam.
    Text,
    /// Horizontal resize (left and right arrows).
    ResizeH,
    /// Vertical resize (up and down arrows).
    ResizeV,
    /// An open hand (draggable).
    Grab,
    /// Not allowed.
    NotAllowed,
}

/// How a node looks while it is held down. The Mac has three styles (`macOS/Style.swift`, `Shared/Style.swift`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum PressStyle {
    /// No feedback.
    None,
    /// `PressRow`: a white 6 % surface, no scale. In at once, out over 0.12 s.
    Row,
    /// `PressButton`: scale 0.97 and opacity 0.85. In at once, out over 0.12 s.
    #[default]
    Button,
    /// `PressText`: opacity 0.6.
    Text,
}

/// A rounded surface behind a node that fades in with hover, keyboard focus, a pressed row and the selected state.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Surface {
    /// Colour at full strength (the alpha is the strength: white 6 %).
    pub color: Color,
    /// Corner radius.
    pub radius: f32,
}

/// A keyboard focus ring.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Ring {
    /// Colour.
    pub color: Color,
    /// Line width.
    pub width: f32,
    /// Corner radius of the ring (the node's own radius).
    pub radius: f32,
    /// A surface that fades in with keyboard focus only (not with hover): the `Dim` style's focus mark.
    pub fill: Option<Color>,
}

/// Everything declared about a node's pointer interaction.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Interact {
    /// Press look (default `Button`; used when the node takes taps).
    pub press: PressStyle,
    /// Scale at full hover (1.0 = none).
    pub hover_scale: Option<f32>,
    /// Surface behind the node for hover, focus, pressed row and selected.
    pub surface: Option<Surface>,
    /// Keyboard focus ring.
    pub ring: Option<Ring>,
    /// Tracks the pointer even without a scale or surface (the paging arrows of a row appear while it is on the row).
    pub hoverable: bool,
    /// Motion of the hover amount (`None` = `feel::hover()`); the row arrows use `feel::arrow()`.
    pub hover_motion: Option<crate::anim::Motion>,
    /// Reported when the pointer enters and leaves.
    pub hover_action: Option<Action>,
    /// Reported once when the pointer has rested on the node for `feel::HOVER_REST_MS`.
    pub rest_action: Option<Action>,
    /// Cursor while the pointer is over the node.
    pub cursor: Option<Cursor>,
    /// Tooltip text, shown after `feel::TOOLTIP_DELAY_MS` of hover.
    pub tooltip: Option<String>,
    /// Reported on a secondary (right) click.
    pub secondary: Option<Action>,
    /// Greyed out: dimmed, takes no gestures and no focus.
    pub disabled: bool,
    /// The selected look: the surface stays on (animated with the toggle curve).
    pub selected: bool,
}

impl Interact {
    /// Whether the pointer position matters for this node.
    pub fn tracks_hover(&self) -> bool {
        self.hoverable
            || self.hover_scale.is_some()
            || self.surface.is_some()
            || self.hover_action.is_some()
    }
}
