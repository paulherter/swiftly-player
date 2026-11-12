//! SwiftUI's propose/answer layout model in pure Rust (no dependencies, `f32` points).
//!
//! A parent proposes a [`Proposal`] (each axis `nil`, zero, infinity or a value), the child answers with a [`Size`], the
//! parent places the child. Nodes: `HStack`/`VStack`/`ZStack`, `Spacer`, `frame` (fixed and flexible), `padding`,
//! `overlay`/`background`, `aspect_ratio`, `fixed_size`, layout priority, content-measured leaves (text, through a
//! callback), `ViewThatFits`, lazy stacks and an adaptive grid with item windowing, and `ScrollView` content size.
//!
//! ```
//! use swiftly_layout::{Node, Align, Size, layout};
//! let row = Node::hstack(Align::Center, Some(0.0), vec![Node::fixed(50.0, 20.0), Node::spacer_min(0.0), Node::fixed(50.0, 20.0)]);
//! let placed = layout(&row, Size::new(300.0, 100.0));
//! assert_eq!(placed.children[2].frame.x, 250.0);
//! ```

#![deny(missing_docs)]

mod engine;
mod geom;
mod lazy;
mod node;

pub use engine::{
    DEFAULT_SPACER_MIN, DEFAULT_SPACING, Engine, Placed, layout, layout_aligned, size_that_fits,
};
pub use geom::{Align, Alignment, Axes, Axis, EdgeInsets, Point, Proposal, Rect, Size};
pub use lazy::{Items, LazyPlan, adaptive_columns};
pub use node::{AdaptiveGrid, ContentMode, FlexFrame, Kind, LazyStack, Measure, Node};
