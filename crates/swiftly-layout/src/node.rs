//! The layout tree: a node is a kind plus children, built with SwiftUI-like constructors and modifiers.

use crate::geom::{Align, Alignment, Axes, Axis, EdgeInsets, Size};
use crate::{Proposal, lazy::Items};
use std::fmt;
use std::rc::Rc;

/// A text (or any content-dependent) leaf: answers a proposal with a size. Build it from `swiftly-text`.
#[derive(Clone)]
pub struct Measure(pub Rc<dyn Fn(Proposal) -> Size>);

impl fmt::Debug for Measure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Measure(..)")
    }
}

/// `aspectRatio(contentMode:)`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ContentMode {
    /// Fit inside the proposal.
    Fit,
    /// Cover the proposal.
    Fill,
}

/// `frame(minWidth:idealWidth:maxWidth:minHeight:idealHeight:maxHeight:alignment:)`.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct FlexFrame {
    /// Minimum width.
    pub min_w: Option<f32>,
    /// Ideal width (used when the width is proposed as `nil`).
    pub ideal_w: Option<f32>,
    /// Maximum width (may be infinity).
    pub max_w: Option<f32>,
    /// Minimum height.
    pub min_h: Option<f32>,
    /// Ideal height.
    pub ideal_h: Option<f32>,
    /// Maximum height (may be infinity).
    pub max_h: Option<f32>,
    /// Where the child sits inside the frame.
    pub align: Option<Alignment>,
}

/// Item sizes and margins of a lazy stack.
#[derive(Clone, Debug, PartialEq)]
pub struct LazyStack {
    /// Scroll axis (main axis).
    pub axis: Axis,
    /// Gap between items.
    pub spacing: f32,
    /// The items.
    pub items: Items,
    /// Space before the first item.
    pub inset_start: f32,
    /// Space after the last item.
    pub inset_end: f32,
    /// Cross-axis alignment of items narrower than the stack.
    pub align: Align,
}

/// An adaptive grid: `columns = floor((width - 2 margin + gap) / (item + gap))`.
#[derive(Clone, Debug, PartialEq)]
pub struct AdaptiveGrid {
    /// Number of items.
    pub count: usize,
    /// Size of every item.
    pub item: Size,
    /// Horizontal margin on both sides.
    pub margin: f32,
    /// Horizontal gap.
    pub gap: f32,
    /// Vertical gap.
    pub row_gap: f32,
    /// Whether the columns hug the leading margin or are centered in the leftover width.
    pub center: bool,
}

/// What a node is.
#[derive(Clone, Debug)]
pub enum Kind {
    /// A leaf with its own size whatever is proposed (a fixed-size image, an icon).
    Fixed(Size),
    /// A leaf that accepts any proposal (`Color`, `Rectangle`); `nil` gives `ideal`.
    Flexible {
        /// Size for a `nil` proposal.
        ideal: Size,
    },
    /// A content-dependent leaf, normally text.
    Measured(Measure),
    /// `Spacer(minLength:)`: expands along the axis of the stack that holds it (both axes outside a stack).
    Spacer {
        /// Minimum length; `None` is the system default.
        min: Option<f32>,
    },
    /// `HStack` / `VStack`.
    Stack {
        /// Main axis.
        axis: Axis,
        /// Gap between children; `None` is the adaptive system default.
        spacing: Option<f32>,
        /// Cross-axis alignment.
        align: Align,
    },
    /// `ZStack`.
    ZStack(Alignment),
    /// `frame(width:height:alignment:)`.
    Frame {
        /// Fixed width.
        w: Option<f32>,
        /// Fixed height.
        h: Option<f32>,
        /// Alignment of the child.
        align: Alignment,
    },
    /// The flexible frame.
    FlexFrame(FlexFrame),
    /// `padding`.
    Padding(EdgeInsets),
    /// `overlay` (child 0 is the primary view, child 1 the overlay).
    Overlay(Alignment),
    /// `background` (child 0 is the primary view, child 1 the background).
    Background(Alignment),
    /// `aspectRatio`; `None` takes the ratio of the child's ideal size.
    Aspect {
        /// Width / height.
        ratio: Option<f32>,
        /// Fit or fill.
        mode: ContentMode,
    },
    /// `fixedSize(horizontal:vertical:)`.
    FixedSize {
        /// Propose `nil` for the width.
        h: bool,
        /// Propose `nil` for the height.
        v: bool,
    },
    /// `ViewThatFits(in:)`.
    ViewThatFits(Axes),
    /// `LazyHStack` / `LazyVStack` with known item sizes (children are not stored).
    LazyStack(LazyStack),
    /// `LazyVGrid` with an adaptive column.
    Grid(AdaptiveGrid),
    /// `ScrollView`: a viewport on one child.
    Scroll(Axis),
}

/// One node of the layout tree.
#[derive(Clone, Debug)]
pub struct Node {
    /// What the node is.
    pub kind: Kind,
    /// Children in order.
    pub children: Vec<Node>,
    /// `layoutPriority`; higher claims space first in stacks.
    pub priority: f32,
}

impl Node {
    /// A node of `kind` with children.
    pub fn new(kind: Kind, children: Vec<Node>) -> Node {
        Node {
            kind,
            children,
            priority: 0.0,
        }
    }
    /// A fixed-size leaf.
    pub fn fixed(w: f32, h: f32) -> Node {
        Node::new(Kind::Fixed(Size::new(w, h)), vec![])
    }
    /// A leaf that takes any proposal (ideal 10 x 10, as `Color` and `Rectangle`).
    pub fn flexible() -> Node {
        Node::new(
            Kind::Flexible {
                ideal: Size::new(10.0, 10.0),
            },
            vec![],
        )
    }
    /// A leaf measured by a callback.
    pub fn measured(f: impl Fn(Proposal) -> Size + 'static) -> Node {
        Node::new(Kind::Measured(Measure(Rc::new(f))), vec![])
    }
    /// `Spacer()`.
    pub fn spacer() -> Node {
        Node::new(Kind::Spacer { min: None }, vec![])
    }
    /// `Spacer(minLength:)`.
    pub fn spacer_min(min: f32) -> Node {
        Node::new(Kind::Spacer { min: Some(min) }, vec![])
    }
    /// `HStack(alignment:spacing:)`; `align` is the vertical alignment.
    pub fn hstack(align: Align, spacing: Option<f32>, children: Vec<Node>) -> Node {
        Node::new(
            Kind::Stack {
                axis: Axis::Horizontal,
                spacing,
                align,
            },
            children,
        )
    }
    /// `VStack(alignment:spacing:)`; `align` is the horizontal alignment.
    pub fn vstack(align: Align, spacing: Option<f32>, children: Vec<Node>) -> Node {
        Node::new(
            Kind::Stack {
                axis: Axis::Vertical,
                spacing,
                align,
            },
            children,
        )
    }
    /// `ZStack(alignment:)`.
    pub fn zstack(align: Alignment, children: Vec<Node>) -> Node {
        Node::new(Kind::ZStack(align), children)
    }
    /// `ViewThatFits(in:)`.
    pub fn view_that_fits(axes: Axes, children: Vec<Node>) -> Node {
        Node::new(Kind::ViewThatFits(axes), children)
    }
    /// A lazy stack of known item sizes.
    pub fn lazy_stack(s: LazyStack) -> Node {
        Node::new(Kind::LazyStack(s), vec![])
    }
    /// An adaptive grid.
    pub fn grid(g: AdaptiveGrid) -> Node {
        Node::new(Kind::Grid(g), vec![])
    }
    /// `ScrollView(axis)` on `content`.
    pub fn scroll(axis: Axis, content: Node) -> Node {
        Node::new(Kind::Scroll(axis), vec![content])
    }

    fn wrap(self, kind: Kind) -> Node {
        Node::new(kind, vec![self])
    }
    /// `.frame(width:height:alignment:)`.
    #[must_use]
    pub fn frame(self, w: Option<f32>, h: Option<f32>, align: Alignment) -> Node {
        self.wrap(Kind::Frame { w, h, align })
    }
    /// `.frame(minWidth:...)`.
    #[must_use]
    pub fn flex_frame(self, f: FlexFrame) -> Node {
        self.wrap(Kind::FlexFrame(f))
    }
    /// `.padding(insets)`.
    #[must_use]
    pub fn padding(self, insets: EdgeInsets) -> Node {
        self.wrap(Kind::Padding(insets))
    }
    /// `.overlay(view, alignment:)`.
    #[must_use]
    pub fn overlay(self, over: Node, align: Alignment) -> Node {
        Node::new(Kind::Overlay(align), vec![self, over])
    }
    /// `.background(view, alignment:)`.
    #[must_use]
    pub fn background(self, back: Node, align: Alignment) -> Node {
        Node::new(Kind::Background(align), vec![self, back])
    }
    /// `.aspectRatio(ratio, contentMode:)`.
    #[must_use]
    pub fn aspect_ratio(self, ratio: Option<f32>, mode: ContentMode) -> Node {
        self.wrap(Kind::Aspect { ratio, mode })
    }
    /// `.fixedSize(horizontal:vertical:)`.
    #[must_use]
    pub fn fixed_size(self, h: bool, v: bool) -> Node {
        self.wrap(Kind::FixedSize { h, v })
    }
    /// `.layoutPriority(p)`.
    #[must_use]
    pub fn layout_priority(mut self, p: f32) -> Node {
        self.priority = p;
        self
    }
}
