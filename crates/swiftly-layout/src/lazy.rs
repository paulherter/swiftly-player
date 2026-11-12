//! Lazy stacks and the adaptive grid: closed-form item geometry and windowing for big lists.

use crate::geom::{Align, Axis, Rect, Size};
use crate::node::{AdaptiveGrid, LazyStack};
use std::ops::Range;

/// The items of a lazy stack.
#[derive(Clone, Debug, PartialEq)]
pub enum Items {
    /// `count` items of one size (O(1) geometry).
    Uniform {
        /// Number of items.
        count: usize,
        /// Size of each item.
        size: Size,
    },
    /// Individually sized items (binary search over prefix sums).
    Sizes(Vec<Size>),
}

impl Items {
    /// Number of items.
    pub fn count(&self) -> usize {
        match self {
            Items::Uniform { count, .. } => *count,
            Items::Sizes(v) => v.len(),
        }
    }
    fn size(&self, i: usize) -> Size {
        match self {
            Items::Uniform { size, .. } => *size,
            Items::Sizes(v) => v.get(i).copied().unwrap_or(Size::ZERO),
        }
    }
}

#[derive(Clone, Debug)]
enum Geom {
    Stack {
        axis: Axis,
        spacing: f32,
        inset_start: f32,
        items: Items,
        starts: Vec<f32>,
        cross: f32,
        align: Align,
    },
    Grid {
        cols: usize,
        grid: AdaptiveGrid,
        x0: f32,
    },
}

/// Where the items of a lazy node are. Frames are relative to the lazy node's origin.
#[derive(Clone, Debug)]
pub struct LazyPlan {
    geom: Geom,
    content: Size,
}

/// Columns of an adaptive grid: `floor((width - 2 margin + gap) / (item + gap))`, at least one.
pub fn adaptive_columns(width: f32, margin: f32, gap: f32, item: f32) -> usize {
    let n = ((width - 2.0 * margin + gap) / (item + gap)).floor();
    if n.is_finite() && n >= 1.0 {
        n as usize
    } else {
        1
    }
}

impl LazyPlan {
    pub(crate) fn stack(s: &LazyStack, cross_proposal: Option<f32>) -> LazyPlan {
        let n = s.items.count();
        let mut starts = Vec::new();
        if matches!(s.items, Items::Sizes(_)) {
            let mut at = s.inset_start;
            for i in 0..n {
                starts.push(at);
                at += s.items.size(i).along(s.axis) + s.spacing;
            }
        }
        let max_cross = match &s.items {
            Items::Uniform { size, count } => {
                if *count > 0 {
                    size.along(s.axis.cross())
                } else {
                    0.0
                }
            }
            Items::Sizes(v) => v
                .iter()
                .map(|z| z.along(s.axis.cross()))
                .fold(0.0, f32::max),
        };
        let cross = cross_proposal
            .filter(|v| v.is_finite())
            .unwrap_or(max_cross);
        let main = if n == 0 {
            s.inset_start + s.inset_end
        } else {
            let sum: f32 = match &s.items {
                Items::Uniform { size, count } => size.along(s.axis) * *count as f32,
                Items::Sizes(v) => v.iter().map(|z| z.along(s.axis)).sum(),
            };
            s.inset_start + sum + s.spacing * (n - 1) as f32 + s.inset_end
        };
        LazyPlan {
            content: Size::from_axis(s.axis, main, cross),
            geom: Geom::Stack {
                axis: s.axis,
                spacing: s.spacing,
                inset_start: s.inset_start,
                items: s.items.clone(),
                starts,
                cross,
                align: s.align,
            },
        }
    }

    pub(crate) fn grid(g: &AdaptiveGrid, width: f32) -> LazyPlan {
        let cols = adaptive_columns(width, g.margin, g.gap, g.item.w);
        let rows = g.count.div_ceil(cols);
        let used = cols as f32 * g.item.w + (cols - 1) as f32 * g.gap;
        let x0 = if g.center {
            ((width - used) / 2.0).max(g.margin)
        } else {
            g.margin
        };
        let h = if rows == 0 {
            0.0
        } else {
            rows as f32 * g.item.h + (rows - 1) as f32 * g.row_gap
        };
        LazyPlan {
            content: Size::new(width, h),
            geom: Geom::Grid {
                cols,
                grid: g.clone(),
                x0,
            },
        }
    }

    /// Size of the whole content (what a scroll view reports as its content size).
    pub fn content_size(&self) -> Size {
        self.content
    }

    /// Number of items.
    pub fn count(&self) -> usize {
        match &self.geom {
            Geom::Stack { items, .. } => items.count(),
            Geom::Grid { grid, .. } => grid.count,
        }
    }

    /// Columns of a grid plan (1 for a stack).
    pub fn columns(&self) -> usize {
        match &self.geom {
            Geom::Grid { cols, .. } => *cols,
            Geom::Stack { .. } => 1,
        }
    }

    /// The frame of item `i`, relative to the lazy node.
    pub fn item_frame(&self, i: usize) -> Rect {
        match &self.geom {
            Geom::Stack {
                axis,
                spacing,
                inset_start,
                items,
                starts,
                cross,
                align,
            } => {
                let s = items.size(i);
                let main = match items {
                    Items::Uniform { size, .. } => {
                        inset_start + i as f32 * (size.along(*axis) + spacing)
                    }
                    Items::Sizes(_) => starts.get(i).copied().unwrap_or(*inset_start),
                };
                let c = align.offset(*cross, s.along(axis.cross()));
                match axis {
                    Axis::Horizontal => Rect::new(main, c, s.w, s.h),
                    Axis::Vertical => Rect::new(c, main, s.w, s.h),
                }
            }
            Geom::Grid { cols, grid, x0 } => {
                let (col, row) = (i % cols, i / cols);
                Rect::new(
                    x0 + col as f32 * (grid.item.w + grid.gap),
                    row as f32 * (grid.item.h + grid.row_gap),
                    grid.item.w,
                    grid.item.h,
                )
            }
        }
    }

    /// The items whose frame meets the main-axis window `[from, to)` (offsets relative to the lazy node).
    /// This is the windowing for big lists: only these items need views.
    pub fn visible(&self, from: f32, to: f32) -> Range<usize> {
        let n = self.count();
        if n == 0 || to <= from {
            return 0..0;
        }
        match &self.geom {
            Geom::Stack {
                axis,
                spacing,
                inset_start,
                items,
                starts,
                ..
            } => match items {
                Items::Uniform { size, .. } => {
                    let step = size.along(*axis) + spacing;
                    if step <= 0.0 {
                        return 0..n;
                    }
                    let first = ((from - inset_start) / step).floor().max(0.0) as usize;
                    let last = (((to - inset_start) / step).ceil().max(0.0) as usize).min(n);
                    first.min(n)..last
                }
                Items::Sizes(v) => {
                    let ends = |i: usize| {
                        starts.get(i).copied().unwrap_or(0.0)
                            + v.get(i).map_or(0.0, |z| z.along(*axis))
                    };
                    let first = (0..n)
                        .collect::<Vec<_>>()
                        .partition_point(|&i| ends(i) <= from);
                    let last = starts.partition_point(|&s| s < to);
                    first..last.max(first)
                }
            },
            Geom::Grid { cols, grid, .. } => {
                let step = grid.item.h + grid.row_gap;
                if step <= 0.0 {
                    return 0..n;
                }
                let r0 = (from / step).floor().max(0.0) as usize;
                let r1 = (to / step).ceil().max(0.0) as usize;
                (r0 * cols).min(n)..(r1 * cols).min(n)
            }
        }
    }

    /// Main-axis start of item `i` (the offset a "snap to item" lands on).
    pub fn item_start(&self, i: usize) -> f32 {
        let f = self.item_frame(i);
        match &self.geom {
            Geom::Stack { axis, .. } => match axis {
                Axis::Horizontal => f.x,
                Axis::Vertical => f.y,
            },
            Geom::Grid { .. } => f.y,
        }
    }
}
