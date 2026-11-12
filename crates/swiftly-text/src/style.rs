//! Text style: the type-ladder step plus the line height and optical size.

use swiftly_design::types::TextStyle as Token;

/// How tall a line is.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum LineHeight {
    /// The font's own ascent + descent + line gap, times the factor. `Metrics(1.0)` is what Core Text and SwiftUI
    /// use when no line spacing is set.
    Metrics(f32),
    /// A multiple of the font size (CSS unitless `line-height`).
    Size(f32),
    /// A fixed height in points.
    Points(f32),
    /// The font's own height plus extra points: SwiftUI `.lineSpacing(n)`, which the Mac code uses with 2, 3 and 4.5.
    MetricsPlus(f32),
}

/// Ascent + descent + line gap of Inter in em (20.569 pt at 17 pt, 26.619 pt at 22 pt, measured against SwiftUI).
/// [`LineHeight::MetricsPlus`] needs it because parley has no "metrics + points" height.
pub const INTER_LINE_EM: f32 = 1.20996;

/// Horizontal alignment inside `max_width`. `Start` and `End` follow the paragraph direction (right edge for Arabic).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Align {
    /// Start edge of the paragraph direction.
    #[default]
    Start,
    /// End edge of the paragraph direction.
    End,
    /// Centred.
    Center,
    /// Left edge, whatever the direction.
    Left,
    /// Right edge, whatever the direction.
    Right,
}

/// One text style: what the type ladder gives (size, weight, tracking, capitals) plus the line height.
///
/// All lengths are points (device independent); the scale factor only matters when glyphs are rasterised.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TextStyle {
    /// Font size in points.
    pub size: f32,
    /// CSS-style weight, 100 to 900.
    pub weight: u16,
    /// Letter spacing in points, added after every character.
    pub tracking: f32,
    /// Set the text in capitals before shaping.
    pub uppercase: bool,
    /// Line height; the default is the font's own.
    pub line_height: LineHeight,
    /// Value of the `opsz` axis of the variable font. `None` means "automatic": the size in points, which is what
    /// Core Text does and what makes the widths match the Apple apps (measured, see `NOTES.md`).
    pub optical_size: Option<f32>,
    /// Tabular figures (OpenType `tnum`): every digit has the same advance, so counters do not jitter. SwiftUI
    /// `.monospacedDigit()`.
    pub tabular: bool,
}

impl TextStyle {
    /// A plain style: weight 400, no tracking, the font's own line height.
    pub const fn new(size: f32, weight: u16) -> TextStyle {
        TextStyle {
            size,
            weight,
            tracking: 0.0,
            uppercase: false,
            line_height: LineHeight::Metrics(1.0),
            optical_size: None,
            tabular: false,
        }
    }

    /// The same style with tabular figures (SwiftUI `.monospacedDigit()`).
    #[must_use]
    pub const fn with_tabular(mut self) -> TextStyle {
        self.tabular = true;
        self
    }

    /// The same style with SwiftUI `.lineSpacing(extra)`: the font's own line height plus `extra` points.
    #[must_use]
    pub const fn with_line_spacing(mut self, extra: f32) -> TextStyle {
        self.line_height = LineHeight::MetricsPlus(extra);
        self
    }

    /// The same style with another line height.
    #[must_use]
    pub const fn with_line_height(mut self, lh: LineHeight) -> TextStyle {
        self.line_height = lh;
        self
    }

    /// The same style at another size (tracking is kept as given: points, not em).
    #[must_use]
    pub const fn with_size(mut self, size: f32) -> TextStyle {
        self.size = size;
        self
    }
}

impl From<Token> for TextStyle {
    fn from(t: Token) -> TextStyle {
        TextStyle {
            size: t.size,
            weight: t.weight,
            tracking: t.tracking,
            uppercase: t.uppercase,
            line_height: LineHeight::Metrics(1.0),
            optical_size: None,
            tabular: false,
        }
    }
}
