// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Colours, rectangles, corner radii and gradients. Everything is in points unless a renderer says otherwise.

/// A straight-alpha sRGB colour, components 0...1 (blended in sRGB code values, as the Apple apps do).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Color {
    /// Red.
    pub r: f32,
    /// Green.
    pub g: f32,
    /// Blue.
    pub b: f32,
    /// Alpha.
    pub a: f32,
}

impl Color {
    /// Opaque white.
    pub const WHITE: Color = Color::rgb(1.0, 1.0, 1.0);
    /// Opaque black.
    pub const BLACK: Color = Color::rgb(0.0, 0.0, 0.0);
    /// Fully transparent black.
    pub const CLEAR: Color = Color::new(0.0, 0.0, 0.0, 0.0);

    /// A colour from straight components.
    pub const fn new(r: f32, g: f32, b: f32, a: f32) -> Color {
        Color { r, g, b, a }
    }

    /// An opaque colour.
    pub const fn rgb(r: f32, g: f32, b: f32) -> Color {
        Color::new(r, g, b, 1.0)
    }

    /// `0xRRGGBBAA`.
    pub fn from_rgba8(rgba: u32) -> Color {
        let c = |shift: u32| ((rgba >> shift) & 0xFF) as f32 / 255.0;
        Color::new(c(24), c(16), c(8), c(0))
    }

    /// The same colour with alpha `a`.
    pub fn with_alpha(self, a: f32) -> Color {
        Color { a, ..self }
    }

    /// The same colour with its alpha multiplied by `k`.
    pub fn faded(self, k: f32) -> Color {
        Color {
            a: self.a * k,
            ..self
        }
    }

    /// Premultiplied components `[r*a, g*a, b*a, a]`.
    pub fn premultiplied(self) -> [f32; 4] {
        [self.r * self.a, self.g * self.a, self.b * self.a, self.a]
    }

    /// Straight components `[r, g, b, a]`.
    pub fn to_array(self) -> [f32; 4] {
        [self.r, self.g, self.b, self.a]
    }
}

/// A rectangle in points, y down.
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
    /// The empty rectangle at the origin.
    pub const ZERO: Rect = Rect::new(0.0, 0.0, 0.0, 0.0);

    /// A rectangle from origin and size.
    pub const fn new(x: f32, y: f32, w: f32, h: f32) -> Rect {
        Rect { x, y, w, h }
    }

    /// Right edge.
    pub fn max_x(&self) -> f32 {
        self.x + self.w
    }

    /// Bottom edge.
    pub fn max_y(&self) -> f32 {
        self.y + self.h
    }

    /// The overlap with `o` (zero size when apart).
    pub fn intersection(&self, o: Rect) -> Rect {
        let (x0, y0) = (self.x.max(o.x), self.y.max(o.y));
        let (x1, y1) = (self.max_x().min(o.max_x()), self.max_y().min(o.max_y()));
        Rect::new(x0, y0, (x1 - x0).max(0.0), (y1 - y0).max(0.0))
    }

    /// Moved by `(dx, dy)`.
    pub fn offset(&self, dx: f32, dy: f32) -> Rect {
        Rect::new(self.x + dx, self.y + dy, self.w, self.h)
    }

    /// Grown by `d` on every side (shrunk when negative, never below zero size).
    pub fn outset(&self, d: f32) -> Rect {
        Rect::new(
            self.x - d,
            self.y - d,
            (self.w + 2.0 * d).max(0.0),
            (self.h + 2.0 * d).max(0.0),
        )
    }
}

/// Corner radii in points, clockwise from the top left.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Corners {
    /// Top left.
    pub tl: f32,
    /// Top right.
    pub tr: f32,
    /// Bottom right.
    pub br: f32,
    /// Bottom left.
    pub bl: f32,
}

impl Corners {
    /// Square corners.
    pub const ZERO: Corners = Corners::all(0.0);

    /// The same radius on every corner. A radius larger than half the short side is clamped when drawing, so
    /// `Corners::all(999.0)` makes a pill.
    pub const fn all(r: f32) -> Corners {
        Corners {
            tl: r,
            tr: r,
            br: r,
            bl: r,
        }
    }

    /// Four individual radii.
    pub const fn new(tl: f32, tr: f32, br: f32, bl: f32) -> Corners {
        Corners { tl, tr, br, bl }
    }

    /// As `[tl, tr, br, bl]`.
    pub fn to_array(self) -> [f32; 4] {
        [self.tl, self.tr, self.br, self.bl]
    }

    /// Each radius reduced by `d` (not below zero): the radii of an inset shape.
    pub fn inset(self, d: f32) -> Corners {
        Corners::new(
            (self.tl - d).max(0.0),
            (self.tr - d).max(0.0),
            (self.br - d).max(0.0),
            (self.bl - d).max(0.0),
        )
    }
}

impl From<f32> for Corners {
    fn from(r: f32) -> Corners {
        Corners::all(r)
    }
}

/// A two-stop linear gradient. `from` and `to` are in the unit square of the rectangle it fills ((0,0) top left,
/// (1,1) bottom right); the colours interpolate premultiplied, so a fade to transparent has no dark fringe.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LinearGradient {
    /// Colour at `from`.
    pub start: Color,
    /// Colour at `to`.
    pub end: Color,
    /// Start point in the unit square.
    pub from: [f32; 2],
    /// End point in the unit square.
    pub to: [f32; 2],
}

impl LinearGradient {
    /// Left to right.
    pub fn horizontal(start: Color, end: Color) -> LinearGradient {
        LinearGradient {
            start,
            end,
            from: [0.0, 0.5],
            to: [1.0, 0.5],
        }
    }

    /// Top to bottom.
    pub fn vertical(start: Color, end: Color) -> LinearGradient {
        LinearGradient {
            start,
            end,
            from: [0.5, 0.0],
            to: [0.5, 1.0],
        }
    }
}

/// What fills a shape.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Fill {
    /// Nothing.
    None,
    /// One colour.
    Solid(Color),
    /// A linear gradient.
    Linear(LinearGradient),
}

impl From<Color> for Fill {
    fn from(c: Color) -> Fill {
        Fill::Solid(c)
    }
}

impl From<LinearGradient> for Fill {
    fn from(g: LinearGradient) -> Fill {
        Fill::Linear(g)
    }
}
