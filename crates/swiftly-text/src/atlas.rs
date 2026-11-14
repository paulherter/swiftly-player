//! Glyph rasterisation (swash) into an R8 atlas page that swiftly-render samples.
//!
//! **Subpixel positioning.** Horizontal position is quantised to quarter pixels (4 bins, rounded to nearest) and the
//! baseline is rounded to a whole device pixel. Four bins is the usual trade (Skia, GPUI): the error is at most an
//! eighth of a pixel, and one glyph costs at most four atlas entries. Vertical subpixels are not worth a 4x blow-up;
//! text does not move smoothly in y. Hinting is off (Apple does not hint either), so stems look the same at every bin.
//!
//! **Device scale.** Layout is measured in points and does not depend on the scale. Rasterising happens at
//! `size * scale` pixels with glyph positions multiplied by the scale, so a 2x screen gets true 2x outlines and
//! identical line breaks.
//!
//! **Why swash.** It is already parley's companion (same author family, same font data type), renders outlines to
//! 8-bit coverage with variable-font coordinates, no hinting and no C code. `ab_glyph` has no variable-font support;
//! `fontdue` ignores variations; `skrifa` alone has no rasteriser; `freetype` is C and unsafe.
//!
//! **Colour glyphs (emoji).** A run whose font carries colour data (CBDT/CBLC or sbix bitmaps, as in Noto Color Emoji
//! and Apple Color Emoji, or COLR v0 layers with CPAL, as in Segoe UI Emoji) is rendered by swash in colour
//! (`ColorOutline`, then `ColorBitmap`, bitmaps scaled to the pixel size) into a second, `Rgba8` page of
//! 1024 x 1024 texels that is created on the first emoji, so text without emoji costs nothing. The texels are stored
//! premultiplied and the quad is a [`DrawList::color_glyph`]: drawn untinted, only the alpha of the text colour
//! applies. Colour glyphs get no subpixel bins (they snap to whole pixels), so an emoji costs one entry. They share the
//! cache, the clear-when-full rule and the one frame of hitch of the coverage page. Fonts without colour data are
//! rasterised exactly as before (outline coverage, no colour sources asked), so ordinary text does not change.
//! COLR v1 (gradients, as in `Noto-COLRv1`) is not drawn by swash; such a font falls back to its plain outlines.

use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};

use parley::{GlyphRun, PositionedLayoutItem};
use swash::FontRef;
use swash::scale::image::{Content, Image};
use swash::scale::{Render, ScaleContext, Source, StrikeWith};
use swash::zeno::{Format, Vector};
use swiftly_render::{Atlas, AtlasFormat, Color, DirtyRect, DrawList, PixelPage, Rect};

use crate::layout::TextLayout;

/// Number of horizontal subpixel positions.
pub const SUBPIXEL_BINS: u32 = 4;

/// Padding in texels around every glyph so bilinear sampling never bleeds into a neighbour.
const GUTTER: u32 = 1;

/// A multiplicative hasher: the keys are small integers, SipHash is wasted on them.
#[derive(Default)]
struct Fx(u64);

impl Hasher for Fx {
    fn finish(&self) -> u64 {
        self.0
    }
    fn write(&mut self, bytes: &[u8]) {
        for b in bytes {
            self.write_u64(u64::from(*b));
        }
    }
    fn write_u64(&mut self, v: u64) {
        self.0 = (self.0.rotate_left(5) ^ v).wrapping_mul(0x517c_c1b7_2722_0a95);
    }
    fn write_u32(&mut self, v: u32) {
        self.write_u64(u64::from(v));
    }
    fn write_u8(&mut self, v: u8) {
        self.write_u64(u64::from(v));
    }
    fn write_usize(&mut self, v: usize) {
        self.write_u64(v as u64);
    }
}

type FxMap<K, V> = HashMap<K, V, BuildHasherDefault<Fx>>;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct GlyphKey {
    font: u64,
    font_index: u32,
    glyph: u32,
    /// Pixel size times 64.
    size: u32,
    coords: u64,
    bin: u8,
}

/// The texel page of colour glyphs: 1024 x 1024 RGBA is 4 MB and holds a few hundred emoji at 30 px.
const COLOR_PAGE: u32 = 1024;

/// Shelf packing state of one page.
#[derive(Clone, Copy, Default)]
struct Shelf {
    /// Next free x of the current shelf, y of the shelf, height of the shelf.
    x: u32,
    y: u32,
    h: u32,
}

impl Shelf {
    fn alloc(&mut self, (pw, ph): (u32, u32), w: u32, h: u32) -> Option<(u32, u32)> {
        let (w, h) = (w + 2 * GUTTER, h + 2 * GUTTER);
        if w > pw || h > ph {
            return None;
        }
        if self.x + w > pw {
            self.y += self.h;
            self.x = 0;
            self.h = 0;
        }
        if self.y + h > ph {
            return None;
        }
        let at = (self.x + GUTTER, self.y + GUTTER);
        self.x += w;
        self.h = self.h.max(h);
        Some(at)
    }
}

/// Where a glyph sits in the page and how it hangs off its origin.
#[derive(Clone, Copy, Debug)]
struct Slot {
    /// Texel rectangle of the coverage bitmap (without the gutter).
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    /// Offset of the bitmap's left edge from the (floored) glyph origin, in pixels.
    left: i32,
    /// Offset of the bitmap's top edge above the baseline, in pixels.
    top: i32,
    /// True for a colour glyph: the texels are in the colour page.
    color: bool,
}

/// Counters for tests and tuning.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AtlasStats {
    /// Glyphs rasterised (cache misses).
    pub rasterised: u64,
    /// Lookups answered from the cache.
    pub hits: u64,
    /// Glyphs dropped because the page was full this frame.
    pub dropped: u64,
    /// Times the page was cleared.
    pub clears: u64,
}

/// A glyph cache and the R8 page behind it. Implements [`Atlas`], so a renderer can mirror it and upload the dirty
/// rectangle only.
pub struct GlyphAtlas {
    page: PixelPage,
    /// The premultiplied RGBA page of colour glyphs, created on the first one.
    color: Option<PixelPage>,
    scaler: ScaleContext,
    cache: FxMap<GlyphKey, Option<Slot>>,
    /// Whether a font (data id, index) has colour glyph data.
    color_fonts: FxMap<(u64, u32), bool>,
    shelf: Shelf,
    color_shelf: Shelf,
    full: bool,
    stats: AtlasStats,
}

impl GlyphAtlas {
    /// An atlas page of `size x size` texels (1024 suits a phone; 2048 a TV or 4K desktop).
    pub fn new(size: u32) -> GlyphAtlas {
        GlyphAtlas {
            page: PixelPage::new(size, size, AtlasFormat::R8),
            color: None,
            scaler: ScaleContext::new(),
            cache: FxMap::default(),
            color_fonts: FxMap::default(),
            shelf: Shelf::default(),
            color_shelf: Shelf::default(),
            full: false,
            stats: AtlasStats::default(),
        }
    }

    /// Call once per frame before emitting text. If the page ran full in the last frame, everything is dropped so
    /// the next frame starts clean (a hitch of one frame of re-rasterising instead of missing glyphs).
    pub fn begin_frame(&mut self) {
        if self.full {
            self.cache.clear();
            self.shelf = Shelf::default();
            self.color_shelf = Shelf::default();
            self.full = false;
            self.stats.clears += 1;
        }
    }

    /// Counters since creation.
    pub fn stats(&self) -> AtlasStats {
        self.stats
    }

    /// Number of cached glyph images.
    pub fn len(&self) -> usize {
        self.cache.len()
    }

    /// True if nothing is cached.
    pub fn is_empty(&self) -> bool {
        self.cache.is_empty()
    }

    /// Texels of the page in use (rows below the current shelf plus the shelf), for tuning.
    pub fn used_rows(&self) -> u32 {
        self.shelf.y + self.shelf.h
    }

    /// Texels of the colour page in use (rows), 0 while no emoji was drawn.
    pub fn color_used_rows(&self) -> u32 {
        self.color_shelf.y + self.color_shelf.h
    }

    /// Emits the quads of `layout` with its top-left corner at `(x, y)` points into `list`, in `color`.
    pub fn draw(&mut self, layout: &TextLayout, list: &mut DrawList, x: f32, y: f32, color: Color) {
        let scale = list.scale();
        for line in layout.parley().lines() {
            for item in line.items() {
                if let PositionedLayoutItem::GlyphRun(run) = item {
                    self.draw_run(&run, list, x, y, scale, color);
                }
            }
        }
    }

    fn draw_run(
        &mut self,
        run: &GlyphRun<'_, ()>,
        list: &mut DrawList,
        x: f32,
        y: f32,
        scale: f32,
        color: Color,
    ) {
        let r = run.run();
        let font = r.font();
        let Some(font_ref) = FontRef::from_index(font.data.as_ref(), font.index as usize) else {
            return;
        };
        let coords: Vec<i16> = r.normalized_coords().iter().map(|c| c.to_bits()).collect();
        let coords_hash = coords.iter().fold(0xcbf2_9ce4_8422_2325_u64, |h, c| {
            (h ^ u64::from(*c as u16)).wrapping_mul(0x100_0000_01b3)
        });
        let px = (r.font_size() * scale * 64.0).round().max(1.0) as u32;
        let has_color = *self
            .color_fonts
            .entry((font.data.id(), font.index))
            .or_insert_with(|| {
                font_ref.color_palettes().next().is_some()
                    || font_ref.color_strikes().next().is_some()
            });
        let baseline_px = ((y + run.baseline()) * scale).round();
        for g in run.positioned_glyphs() {
            let gx = (x + g.x) * scale;
            let (ix, bin) = if has_color {
                // Colour glyphs snap to whole pixels: one atlas entry, no four-fold blow-up of the colour page.
                (gx.round(), 0)
            } else {
                let mut ix = gx.floor();
                let mut bin = ((gx - ix) * SUBPIXEL_BINS as f32).round() as u32;
                if bin >= SUBPIXEL_BINS {
                    bin = 0;
                    ix += 1.0;
                }
                (ix, bin)
            };
            let key = GlyphKey {
                font: font.data.id(),
                font_index: font.index,
                glyph: g.id,
                size: px,
                coords: coords_hash,
                bin: bin as u8,
            };
            let slot = match self.cache.get(&key) {
                Some(s) => {
                    self.stats.hits += 1;
                    *s
                }
                None => {
                    let s = self.rasterise(&key, font_ref, &coords, has_color);
                    self.cache.insert(key, s);
                    s
                }
            };
            let Some(s) = slot else { continue };
            let left = ix + s.left as f32;
            let top = baseline_px - s.top as f32;
            let rect = Rect::new(
                left / scale,
                top / scale,
                s.w as f32 / scale,
                s.h as f32 / scale,
            );
            if s.color {
                if let Some(page) = &self.color {
                    list.color_glyph(rect, page.uv(s.x, s.y, s.w, s.h), color);
                }
            } else {
                list.glyph(rect, self.page.uv(s.x, s.y, s.w, s.h), color);
            }
        }
    }

    fn rasterise(
        &mut self,
        key: &GlyphKey,
        font: FontRef<'_>,
        coords: &[i16],
        has_color: bool,
    ) -> Option<Slot> {
        let mut scaler = self
            .scaler
            .builder(font)
            .size(key.size as f32 / 64.0)
            .hint(false)
            .normalized_coords(coords)
            .build();
        // Only a colour font is asked for colour sources: every other font goes the outline-only way as before.
        let sources_color = [
            Source::ColorOutline(0),
            Source::ColorBitmap(StrikeWith::BestFit),
            Source::Outline,
        ];
        let sources_plain = [Source::Outline];
        let image = Render::new(if has_color {
            &sources_color
        } else {
            &sources_plain
        })
        .format(Format::Alpha)
        .offset(Vector::new(f32::from(key.bin) / SUBPIXEL_BINS as f32, 0.0))
        .render(&mut scaler, key.glyph as u16)?;
        self.stats.rasterised += 1;
        let (w, h) = (image.placement.width, image.placement.height);
        if w == 0 || h == 0 {
            return None; // a space
        }
        match image.content {
            Content::Mask => self.put_mask(&image, w, h),
            Content::Color => self.put_color(&image, w, h),
            Content::SubpixelMask => None,
        }
    }

    fn put_mask(&mut self, image: &Image, w: u32, h: u32) -> Option<Slot> {
        let Some((x, y)) = self.shelf.alloc(self.page.size(), w, h) else {
            self.full = true;
            self.stats.dropped += 1;
            return None;
        };
        // Zero the gutter, then the coverage.
        let (gw, gh) = (w + 2 * GUTTER, h + 2 * GUTTER);
        let mut padded = vec![0u8; gw as usize * gh as usize];
        for row in 0..h as usize {
            let dst = (row + GUTTER as usize) * gw as usize + GUTTER as usize;
            let src = row * w as usize;
            padded[dst..dst + w as usize].copy_from_slice(&image.data[src..src + w as usize]);
        }
        self.page.put(x - GUTTER, y - GUTTER, gw, gh, &padded);
        Some(Slot {
            x,
            y,
            w,
            h,
            left: image.placement.left,
            top: image.placement.top,
            color: false,
        })
    }

    /// Stores a straight-alpha RGBA image premultiplied in the colour page.
    fn put_color(&mut self, image: &Image, w: u32, h: u32) -> Option<Slot> {
        let page = self
            .color
            .get_or_insert_with(|| PixelPage::new(COLOR_PAGE, COLOR_PAGE, AtlasFormat::Rgba8));
        let Some((x, y)) = self.color_shelf.alloc(page.size(), w, h) else {
            self.full = true;
            self.stats.dropped += 1;
            return None;
        };
        let (gw, gh) = (w + 2 * GUTTER, h + 2 * GUTTER);
        let mut padded = vec![0u8; gw as usize * gh as usize * 4];
        for row in 0..h as usize {
            let dst = ((row + GUTTER as usize) * gw as usize + GUTTER as usize) * 4;
            let src = row * w as usize * 4;
            let (out, _) = padded[dst..dst + w as usize * 4].as_chunks_mut::<4>();
            let (inp, _) = image.data[src..src + w as usize * 4].as_chunks::<4>();
            for (d, s) in out.iter_mut().zip(inp) {
                let a = u32::from(s[3]);
                for c in 0..3 {
                    d[c] = ((u32::from(s[c]) * a + 127) / 255) as u8;
                }
                d[3] = s[3];
            }
        }
        page.put(x - GUTTER, y - GUTTER, gw, gh, &padded);
        Some(Slot {
            x,
            y,
            w,
            h,
            left: image.placement.left,
            top: image.placement.top,
            color: true,
        })
    }
}

impl Atlas for GlyphAtlas {
    fn size(&self) -> (u32, u32) {
        self.page.size()
    }
    fn format(&self) -> AtlasFormat {
        AtlasFormat::R8
    }
    fn pixels(&self) -> &[u8] {
        self.page.pixels()
    }
    fn take_dirty(&self) -> Option<DirtyRect> {
        self.page.take_dirty()
    }
    fn color_page(&self) -> Option<&dyn Atlas> {
        self.color.as_ref().map(|p| p as &dyn Atlas)
    }
}
