//! Shaping, line breaking, ellipsis and hit-testing.

use std::borrow::Cow;
use std::ops::Range;

use parley::fontique::GenericFamily;
use parley::setting::Tag;
use parley::style::{
    FontFamily, FontFamilyName, FontFeatures, FontVariation, FontVariations, OverflowWrap,
};
use parley::{
    Affinity, Alignment, AlignmentOptions, Cursor, FontWeight, Layout, LineHeight as PLineHeight,
    PositionedLayoutItem, Selection, StyleProperty,
};
use swiftly_render::Rect;

use crate::fonts::FontSystem;
use crate::style::{Align, LineHeight, TextStyle};

/// The ellipsis character appended on truncation, as SwiftUI's tail truncation does.
pub const ELLIPSIS: char = '\u{2026}';

/// One laid-out line.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LineInfo {
    /// Byte range of the line in [`TextLayout::text`].
    pub range_start: usize,
    /// End of the byte range.
    pub range_end: usize,
    /// Top of the line box in points, from the top of the layout.
    pub top: f32,
    /// Height of the line box.
    pub height: f32,
    /// Baseline, from the top of the layout.
    pub baseline: f32,
    /// Advance width of the line's ink-carrying content (trailing spaces excluded).
    pub width: f32,
}

impl LineInfo {
    /// The byte range as a `Range`.
    pub fn range(&self) -> Range<usize> {
        self.range_start..self.range_end
    }
}

/// A shaped, broken and aligned paragraph, measured in points.
pub struct TextLayout {
    pub(crate) layout: Layout<()>,
    pub(crate) text: String,
    pub(crate) truncated: bool,
    pub(crate) size: (f32, f32),
    pub(crate) style: TextStyle,
}

impl TextLayout {
    /// The text that is shown: capitalised if the style asks for it, with the ellipsis if it was cut. Byte indices of
    /// the hit-test and caret functions refer to this string.
    pub fn text(&self) -> &str {
        &self.text
    }

    /// Measured size in points: widest line (trailing spaces excluded) by total line height.
    pub fn size(&self) -> (f32, f32) {
        self.size
    }

    /// Measured width in points.
    pub fn width(&self) -> f32 {
        self.size.0
    }

    /// Measured height in points.
    pub fn height(&self) -> f32 {
        self.size.1
    }

    /// True if the text was cut and ends in the ellipsis.
    pub fn truncated(&self) -> bool {
        self.truncated
    }

    /// The style the layout was made with.
    pub fn style(&self) -> &TextStyle {
        &self.style
    }

    /// Number of lines.
    pub fn line_count(&self) -> usize {
        self.layout.len()
    }

    /// Geometry of every line.
    pub fn lines(&self) -> Vec<LineInfo> {
        let mut top = 0.0;
        self.layout
            .lines()
            .map(|l| {
                let m = l.metrics();
                let range = l.text_range();
                let info = LineInfo {
                    range_start: range.start,
                    range_end: range.end,
                    top,
                    height: m.line_height,
                    baseline: m.baseline,
                    width: m.advance - m.hanging_advance,
                };
                top += m.line_height;
                info
            })
            .collect()
    }

    /// True if the first strong character makes the paragraph right-to-left.
    pub fn is_rtl(&self) -> bool {
        self.layout.is_rtl()
    }

    /// The byte index of the caret position nearest to the point (layout coordinates, points). Left of the text gives
    /// 0 for LTR; the end of the text gives `text().len()`.
    pub fn hit_test(&self, x: f32, y: f32) -> usize {
        Cursor::from_point(&self.layout, x, y).index()
    }

    /// The caret rectangle at a byte index (a `char` boundary of [`TextLayout::text`]), `width` points wide.
    pub fn caret_rect(&self, index: usize, width: f32) -> Rect {
        let index = index.min(self.text.len());
        let c = Cursor::from_byte_index(&self.layout, index, Affinity::Downstream);
        let g = c.geometry(&self.layout, width);
        Rect::new(
            g.x0 as f32,
            g.y0 as f32,
            (g.x1 - g.x0) as f32,
            (g.y1 - g.y0) as f32,
        )
    }

    /// The rectangles that cover the byte range (one per line and direction run), for a selection highlight.
    pub fn selection_rects(&self, range: Range<usize>) -> Vec<Rect> {
        let a = Cursor::from_byte_index(
            &self.layout,
            range.start.min(self.text.len()),
            Affinity::Downstream,
        );
        let b = Cursor::from_byte_index(
            &self.layout,
            range.end.min(self.text.len()),
            Affinity::Upstream,
        );
        Selection::new(a, b)
            .geometry(&self.layout)
            .into_iter()
            .map(|(g, _)| {
                Rect::new(
                    g.x0 as f32,
                    g.y0 as f32,
                    (g.x1 - g.x0) as f32,
                    (g.y1 - g.y0) as f32,
                )
            })
            .collect()
    }

    /// Number of glyphs that no font could provide (shown as the font's "missing" box). Zero means the script has a
    /// fallback font on this machine.
    pub fn missing_glyphs(&self) -> usize {
        self.layout
            .lines()
            .flat_map(|l| l.items().collect::<Vec<_>>())
            .filter_map(|i| match i {
                PositionedLayoutItem::GlyphRun(r) => Some(r.glyphs().filter(|g| g.id == 0).count()),
                PositionedLayoutItem::InlineBox(_) => None,
            })
            .sum()
    }

    pub(crate) fn parley(&self) -> &Layout<()> {
        &self.layout
    }
}

/// Tracking breaks the joins of cursive scripts, so it is dropped for them (as CSS does).
fn has_cursive(text: &str) -> bool {
    text.chars().any(|c| {
        matches!(c as u32,
            0x0600..=0x06FF | 0x0750..=0x077F | 0x08A0..=0x08FF | 0xFB50..=0xFDFF | 0xFE70..=0xFEFF
            | 0x0700..=0x074F | 0x0840..=0x085F)
    })
}

fn convert_height(h: LineHeight, size: f32) -> PLineHeight {
    match h {
        LineHeight::MetricsPlus(extra) => {
            PLineHeight::Absolute(size * crate::style::INTER_LINE_EM + extra)
        }
        LineHeight::Metrics(k) => PLineHeight::MetricsRelative(k),
        LineHeight::Size(k) => PLineHeight::FontSizeRelative(k),
        LineHeight::Points(p) => PLineHeight::Absolute(p),
    }
}

/// True when `text` has a pictograph of the supplementary emoji planes (U+1F000 and up: faces, objects, flags) or an
/// emoji variation selector (U+FE0F). Plain symbols of the BMP stay on the ordinary fallback.
fn has_emoji(text: &str) -> bool {
    text.chars().any(|c| c as u32 >= 0x1F000 || c == '\u{FE0F}')
}

impl FontSystem {
    fn build(&mut self, text: &str, style: &TextStyle, wrap_anywhere: bool) -> Layout<()> {
        // Text with emoji asks the system emoji font right after Inter: the sans-serif fallback of a machine may own
        // monochrome outlines of some pictographs (Noto Sans Symbols 2 has a few) and would win otherwise. Text without
        // emoji keeps the two-family list, so ordinary text resolves exactly as before.
        let with_emoji = [
            FontFamilyName::Named(Cow::Owned(self.primary.clone())),
            FontFamilyName::Generic(GenericFamily::Emoji),
            FontFamilyName::Generic(GenericFamily::SansSerif),
        ];
        let plain = [
            FontFamilyName::Named(Cow::Owned(self.primary.clone())),
            FontFamilyName::Generic(GenericFamily::SansSerif),
        ];
        let family: &[FontFamilyName<'_>] = if has_emoji(text) { &with_emoji } else { &plain };
        // Automatic optical size = the point size (as Core Text does); the font clamps it to its axis (14 to 32).
        let optical = [FontVariation::new(
            Tag::new(b"opsz"),
            style.optical_size.unwrap_or(style.size),
        )];
        let mut b = self
            .layout_cx
            .ranged_builder(&mut self.font_cx, text, 1.0, false);
        b.push_default(StyleProperty::FontFamily(FontFamily::List(Cow::Borrowed(
            family,
        ))));
        b.push_default(StyleProperty::FontSize(style.size));
        b.push_default(StyleProperty::FontWeight(FontWeight::new(f32::from(
            style.weight,
        ))));
        b.push_default(StyleProperty::LineHeight(convert_height(
            style.line_height,
            style.size,
        )));
        if style.tracking != 0.0 && !has_cursive(text) {
            b.push_default(StyleProperty::LetterSpacing(style.tracking));
        }
        b.push_default(StyleProperty::FontVariations(FontVariations::List(
            Cow::Borrowed(&optical),
        )));
        if style.tabular {
            b.push_default(StyleProperty::FontFeatures(FontFeatures::Source(
                Cow::Borrowed("'tnum' 1"),
            )));
        }
        if wrap_anywhere {
            b.push_default(StyleProperty::OverflowWrap(OverflowWrap::Anywhere));
        }
        b.build(text)
    }

    /// Shapes `text` in `style`, breaks it at `max_width` points (no wrapping when `None`), cuts it with an ellipsis
    /// after `max_lines` lines (`None` for no limit) and aligns the lines inside `max_width`.
    ///
    /// Bidi, Arabic shaping and CJK line breaking come from parley; glyphs missing in Inter come from the system
    /// fallback fonts. Measurements are in points and do not depend on the device scale.
    pub fn layout(
        &mut self,
        text: &str,
        style: &TextStyle,
        max_width: Option<f32>,
        max_lines: Option<usize>,
        align: Align,
    ) -> TextLayout {
        let shown: String = if style.uppercase {
            text.to_uppercase()
        } else {
            text.to_owned()
        };
        let limit = max_lines.map(|n| n.max(1));
        let wrap_anywhere = limit.is_some();
        let mut layout = self.build(&shown, style, wrap_anywhere);
        layout.break_all_lines(max_width);

        let mut text_out = shown;
        let mut truncated = false;
        if let (Some(n), Some(w)) = (limit, max_width)
            && layout.len() > n
        {
            let (cut, relaid) = self.truncate(&text_out, style, w, n, &layout);
            text_out = cut;
            layout = relaid;
            truncated = true;
        }

        let alignment = match align {
            Align::Start => Alignment::Start,
            Align::End => Alignment::End,
            Align::Center => Alignment::Center,
            Align::Left => Alignment::Left,
            Align::Right => Alignment::Right,
        };
        layout.align(alignment, AlignmentOptions::default());

        let mut width = 0.0f32;
        let mut height = 0.0f32;
        for l in layout.lines() {
            let m = l.metrics();
            width = width.max(m.advance - m.hanging_advance);
            height += m.line_height;
        }
        TextLayout {
            layout,
            text: text_out,
            truncated,
            size: (width, height),
            style: *style,
        }
    }

    /// Finds the longest prefix of the last allowed line that still fits with the ellipsis after it.
    fn truncate(
        &mut self,
        text: &str,
        style: &TextStyle,
        width: f32,
        n: usize,
        full: &Layout<()>,
    ) -> (String, Layout<()>) {
        let (start, end) = full.get(n - 1).map_or((0, text.len()), |l| {
            (l.text_range().start, l.text_range().end)
        });
        let end = end.min(text.len());
        let start = start.min(end);
        // Candidate cut points: every char boundary of the last line, widest first.
        let cuts: Vec<usize> = text[start..end]
            .char_indices()
            .map(|(i, _)| start + i)
            .chain(std::iter::once(end))
            .collect();
        let candidate = |cut: usize| -> String {
            let mut s = text[..cut].trim_end().to_owned();
            s.push(ELLIPSIS);
            s
        };
        let fits = |this: &mut FontSystem, cut: usize| -> Option<Layout<()>> {
            let s = candidate(cut);
            let mut l = this.build(&s, style, true);
            l.break_all_lines(Some(width));
            (l.len() <= n).then_some(l)
        };
        // Binary search for the largest cut that fits (width grows with the cut).
        let (mut lo, mut hi) = (0usize, cuts.len());
        let mut best: Option<(usize, Layout<()>)> = None;
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            match fits(self, cuts[mid]) {
                Some(l) => {
                    best = Some((cuts[mid], l));
                    lo = mid + 1;
                }
                None => hi = mid,
            }
        }
        match best {
            Some((cut, l)) => (candidate(cut), l),
            None => {
                // Not even one character plus the ellipsis fits: show the ellipsis alone.
                let s = ELLIPSIS.to_string();
                let mut l = self.build(&s, style, true);
                l.break_all_lines(Some(width));
                (s, l)
            }
        }
    }
}
