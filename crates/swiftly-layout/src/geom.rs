//! Geometry and the proposal type of the propose/answer model.

/// A width and a height in points.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Size {
    /// Width.
    pub w: f32,
    /// Height.
    pub h: f32,
}

impl Size {
    /// Zero by zero.
    pub const ZERO: Size = Size { w: 0.0, h: 0.0 };
    /// A size.
    pub const fn new(w: f32, h: f32) -> Size {
        Size { w, h }
    }
    /// The length along `axis`.
    pub fn along(self, axis: Axis) -> f32 {
        match axis {
            Axis::Horizontal => self.w,
            Axis::Vertical => self.h,
        }
    }
    /// A size from a main and a cross length of `axis`.
    pub fn from_axis(axis: Axis, main: f32, cross: f32) -> Size {
        match axis {
            Axis::Horizontal => Size::new(main, cross),
            Axis::Vertical => Size::new(cross, main),
        }
    }
}

/// A point in points.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Point {
    /// X.
    pub x: f32,
    /// Y.
    pub y: f32,
}

impl Point {
    /// A point.
    pub const fn new(x: f32, y: f32) -> Point {
        Point { x, y }
    }
}

/// A rectangle: origin and size, y down.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    /// Left.
    pub x: f32,
    /// Top.
    pub y: f32,
    /// Width.
    pub w: f32,
    /// Height.
    pub h: f32,
}

impl Rect {
    /// An empty rectangle at the origin.
    pub const ZERO: Rect = Rect::new(0.0, 0.0, 0.0, 0.0);
    /// A rectangle.
    pub const fn new(x: f32, y: f32, w: f32, h: f32) -> Rect {
        Rect { x, y, w, h }
    }
    /// A rectangle from an origin and a size.
    pub const fn from_size(x: f32, y: f32, s: Size) -> Rect {
        Rect::new(x, y, s.w, s.h)
    }
    /// Right edge.
    pub fn max_x(&self) -> f32 {
        self.x + self.w
    }
    /// Bottom edge.
    pub fn max_y(&self) -> f32 {
        self.y + self.h
    }
    /// The size.
    pub fn size(&self) -> Size {
        Size::new(self.w, self.h)
    }
    /// Whether the point lies inside (left/top edge inclusive, right/bottom exclusive).
    pub fn contains(&self, p: Point) -> bool {
        p.x >= self.x && p.x < self.max_x() && p.y >= self.y && p.y < self.max_y()
    }
    /// The same rectangle moved.
    pub fn offset(&self, dx: f32, dy: f32) -> Rect {
        Rect::new(self.x + dx, self.y + dy, self.w, self.h)
    }
}

/// The two layout axes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Axis {
    /// Left to right.
    Horizontal,
    /// Top to bottom.
    Vertical,
}

impl Axis {
    /// The other axis.
    pub fn cross(self) -> Axis {
        match self {
            Axis::Horizontal => Axis::Vertical,
            Axis::Vertical => Axis::Horizontal,
        }
    }
}

/// Which axes `ViewThatFits` tests.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Axes {
    /// Test the width.
    pub horizontal: bool,
    /// Test the height.
    pub vertical: bool,
}

impl Axes {
    /// Both axes (the SwiftUI default).
    pub const BOTH: Axes = Axes {
        horizontal: true,
        vertical: true,
    };
    /// Width only.
    pub const HORIZONTAL: Axes = Axes {
        horizontal: true,
        vertical: false,
    };
    /// Height only.
    pub const VERTICAL: Axes = Axes {
        horizontal: false,
        vertical: true,
    };
}

/// Position along one axis: leading/top, center, trailing/bottom.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Align {
    /// Leading (horizontal) or top (vertical).
    Start,
    /// Centered.
    Center,
    /// Trailing (horizontal) or bottom (vertical).
    End,
}

impl Align {
    /// Offset of a child of length `child` inside a container of length `container`.
    pub fn offset(self, container: f32, child: f32) -> f32 {
        match self {
            Align::Start => 0.0,
            Align::Center => (container - child) / 2.0,
            Align::End => container - child,
        }
    }
}

/// A two-axis alignment (SwiftUI `Alignment`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Alignment {
    /// Horizontal part.
    pub h: Align,
    /// Vertical part.
    pub v: Align,
}

impl Alignment {
    /// Centered both ways.
    pub const CENTER: Alignment = Alignment::new(Align::Center, Align::Center);
    /// Leading, vertically centered.
    pub const LEADING: Alignment = Alignment::new(Align::Start, Align::Center);
    /// Trailing, vertically centered.
    pub const TRAILING: Alignment = Alignment::new(Align::End, Align::Center);
    /// Top, horizontally centered.
    pub const TOP: Alignment = Alignment::new(Align::Center, Align::Start);
    /// Bottom, horizontally centered.
    pub const BOTTOM: Alignment = Alignment::new(Align::Center, Align::End);
    /// Top leading corner.
    pub const TOP_LEADING: Alignment = Alignment::new(Align::Start, Align::Start);
    /// Top trailing corner.
    pub const TOP_TRAILING: Alignment = Alignment::new(Align::End, Align::Start);
    /// Bottom leading corner.
    pub const BOTTOM_LEADING: Alignment = Alignment::new(Align::Start, Align::End);
    /// Bottom trailing corner.
    pub const BOTTOM_TRAILING: Alignment = Alignment::new(Align::End, Align::End);
    /// An alignment.
    pub const fn new(h: Align, v: Align) -> Alignment {
        Alignment { h, v }
    }
    /// Position of a `child` inside a `container` of the given sizes, relative to the container origin.
    pub fn place(self, container: Size, child: Size) -> Point {
        Point::new(
            self.h.offset(container.w, child.w),
            self.v.offset(container.h, child.h),
        )
    }
}

/// Insets of `padding`.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct EdgeInsets {
    /// Top.
    pub top: f32,
    /// Leading.
    pub leading: f32,
    /// Bottom.
    pub bottom: f32,
    /// Trailing.
    pub trailing: f32,
}

impl EdgeInsets {
    /// No insets.
    pub const ZERO: EdgeInsets = EdgeInsets::all(0.0);
    /// The same inset on all four edges.
    pub const fn all(v: f32) -> EdgeInsets {
        EdgeInsets {
            top: v,
            leading: v,
            bottom: v,
            trailing: v,
        }
    }
    /// Horizontal and vertical insets.
    pub const fn symmetric(horizontal: f32, vertical: f32) -> EdgeInsets {
        EdgeInsets {
            top: vertical,
            leading: horizontal,
            bottom: vertical,
            trailing: horizontal,
        }
    }
    /// Sum of leading and trailing.
    pub fn horizontal(&self) -> f32 {
        self.leading + self.trailing
    }
    /// Sum of top and bottom.
    pub fn vertical(&self) -> f32 {
        self.top + self.bottom
    }
}

/// What a parent proposes to a child: a width and a height, each `None` (SwiftUI `nil`: "your ideal size"), zero
/// ("your minimum"), infinity ("your maximum") or a finite value.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Proposal {
    /// Proposed width.
    pub w: Option<f32>,
    /// Proposed height.
    pub h: Option<f32>,
}

impl Proposal {
    /// `nil` x `nil`: ask for the ideal size.
    pub const NIL: Proposal = Proposal { w: None, h: None };
    /// Zero x zero: ask for the minimum size.
    pub const ZERO: Proposal = Proposal {
        w: Some(0.0),
        h: Some(0.0),
    };
    /// Infinity x infinity: ask for the maximum size.
    pub const INFINITY: Proposal = Proposal {
        w: Some(f32::INFINITY),
        h: Some(f32::INFINITY),
    };
    /// A proposal from two optional lengths.
    pub const fn new(w: Option<f32>, h: Option<f32>) -> Proposal {
        Proposal { w, h }
    }
    /// An exact size.
    pub const fn value(s: Size) -> Proposal {
        Proposal {
            w: Some(s.w),
            h: Some(s.h),
        }
    }
    /// The proposed length along `axis`.
    pub fn along(&self, axis: Axis) -> Option<f32> {
        match axis {
            Axis::Horizontal => self.w,
            Axis::Vertical => self.h,
        }
    }
    /// A proposal from a main and a cross length of `axis`.
    pub fn from_axis(axis: Axis, main: Option<f32>, cross: Option<f32>) -> Proposal {
        match axis {
            Axis::Horizontal => Proposal::new(main, cross),
            Axis::Vertical => Proposal::new(cross, main),
        }
    }
    /// The same proposal with one axis replaced.
    pub fn with(self, axis: Axis, v: Option<f32>) -> Proposal {
        match axis {
            Axis::Horizontal => Proposal { w: v, ..self },
            Axis::Vertical => Proposal { h: v, ..self },
        }
    }
    /// `nil` replaced by `fallback`, infinity replaced by `fallback` too (for sizes that need a number).
    pub fn or(&self, fallback: Size) -> Size {
        Size::new(
            self.w.filter(|v| v.is_finite()).unwrap_or(fallback.w),
            self.h.filter(|v| v.is_finite()).unwrap_or(fallback.h),
        )
    }
}
