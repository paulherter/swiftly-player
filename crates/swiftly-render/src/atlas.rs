// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The atlas interface: a page of texels that glyph and image quads sample.
//!
//! Text shaping and glyph rasterising come in a later crate; it implements [`Atlas`] over its glyph page. The idea of
//! uploading only the dirty rectangle comes from the Sequence Studio glyph atlas.

use std::cell::Cell;

/// The texel format of an [`Atlas`] page.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AtlasFormat {
    /// One byte of coverage per texel (glyphs).
    R8,
    /// Four straight-alpha bytes per texel (images, icons).
    Rgba8,
}

impl AtlasFormat {
    /// Bytes per texel.
    pub const fn bytes_per_texel(self) -> usize {
        match self {
            AtlasFormat::R8 => 1,
            AtlasFormat::Rgba8 => 4,
        }
    }
}

/// A changed rectangle of a page, in texels.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DirtyRect {
    /// Left.
    pub x: u32,
    /// Top.
    pub y: u32,
    /// Width.
    pub w: u32,
    /// Height.
    pub h: u32,
}

impl DirtyRect {
    /// The smallest rectangle holding both.
    pub fn union(self, o: DirtyRect) -> DirtyRect {
        let (x0, y0) = (self.x.min(o.x), self.y.min(o.y));
        let (x1, y1) = (
            (self.x + self.w).max(o.x + o.w),
            (self.y + self.h).max(o.y + o.h),
        );
        DirtyRect {
            x: x0,
            y: y0,
            w: x1 - x0,
            h: y1 - y0,
        }
    }
}

/// A page of texels. Quads address it with normalised `uv` rectangles; sampling is bilinear with clamped edges and
/// texel centres at `(i + 0.5) / size`.
///
/// One GPU renderer mirrors one page and consumes [`Atlas::take_dirty`], so do not share a page between renderers.
pub trait Atlas {
    /// Width and height in texels.
    fn size(&self) -> (u32, u32);
    /// The texel format.
    fn format(&self) -> AtlasFormat;
    /// All texels, rows top to bottom, tightly packed (`width * height * bytes_per_texel`).
    fn pixels(&self) -> &[u8];
    /// The rectangle changed since the last call (and forgets it); `None` when nothing changed.
    fn take_dirty(&self) -> Option<DirtyRect>;
}

/// A plain in-memory page: `put` copies a block of texels in and records the dirty rectangle.
#[derive(Debug)]
pub struct PixelPage {
    width: u32,
    height: u32,
    format: AtlasFormat,
    pixels: Vec<u8>,
    dirty: Cell<Option<DirtyRect>>,
}

impl PixelPage {
    /// A zeroed page. It starts fully dirty so the first upload sends everything.
    pub fn new(width: u32, height: u32, format: AtlasFormat) -> PixelPage {
        let len = width as usize * height as usize * format.bytes_per_texel();
        PixelPage {
            width,
            height,
            format,
            pixels: vec![0; len],
            dirty: Cell::new(Some(DirtyRect {
                x: 0,
                y: 0,
                w: width,
                h: height,
            })),
        }
    }

    /// Copies a `w x h` block (tightly packed texels) to `(x, y)`. Returns false when it does not fit or `data` is short.
    pub fn put(&mut self, x: u32, y: u32, w: u32, h: u32, data: &[u8]) -> bool {
        let bpt = self.format.bytes_per_texel();
        if x + w > self.width || y + h > self.height || data.len() < w as usize * h as usize * bpt {
            return false;
        }
        let row = w as usize * bpt;
        for r in 0..h as usize {
            let dst = ((y as usize + r) * self.width as usize + x as usize) * bpt;
            self.pixels[dst..dst + row].copy_from_slice(&data[r * row..(r + 1) * row]);
        }
        let rect = DirtyRect { x, y, w, h };
        self.dirty
            .set(Some(self.dirty.get().map_or(rect, |d| d.union(rect))));
        true
    }

    /// The normalised `uv` rectangle `[u0, v0, u1, v1]` of the block at `(x, y)` of size `w x h`.
    pub fn uv(&self, x: u32, y: u32, w: u32, h: u32) -> [f32; 4] {
        let (pw, ph) = (self.width as f32, self.height as f32);
        [
            x as f32 / pw,
            y as f32 / ph,
            (x + w) as f32 / pw,
            (y + h) as f32 / ph,
        ]
    }
}

impl Atlas for PixelPage {
    fn size(&self) -> (u32, u32) {
        (self.width, self.height)
    }
    fn format(&self) -> AtlasFormat {
        self.format
    }
    fn pixels(&self) -> &[u8] {
        &self.pixels
    }
    fn take_dirty(&self) -> Option<DirtyRect> {
        self.dirty.take()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn put_tracks_the_union_of_dirty_blocks() {
        let mut p = PixelPage::new(8, 8, AtlasFormat::R8);
        assert_eq!(
            p.take_dirty(),
            Some(DirtyRect {
                x: 0,
                y: 0,
                w: 8,
                h: 8
            })
        );
        assert_eq!(p.take_dirty(), None);
        assert!(p.put(1, 1, 2, 2, &[1, 2, 3, 4]));
        assert!(p.put(5, 4, 1, 1, &[9]));
        assert_eq!(
            p.take_dirty(),
            Some(DirtyRect {
                x: 1,
                y: 1,
                w: 5,
                h: 4
            })
        );
        assert_eq!(p.pixels()[8 + 1], 1);
        assert!(!p.put(7, 7, 2, 2, &[0; 4]), "does not fit");
    }
}
