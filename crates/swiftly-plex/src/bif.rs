//! **Plex's preview pictures for scrubbing** (`.bif`, "Base Index Frames"; `PlexBIF.swift`):
//! one JPEG every few seconds in one file. Unlike Jellyfin's tile sheets there is no grid;
//! each picture stands alone.
//!
//! Layout, little endian: 8 bytes magic `89 42 49 46 0D 0A 1A 0A`, `version` (u32), number of
//! images (u32), `timestampMultiplier` (u32, milliseconds per timestamp unit; 0 means 1000),
//! 44 bytes reserved; then `count + 1` index entries of (timestamp u32, byte offset u32), the
//! last one a sentinel (`0xFFFFFFFF`) whose offset is the end of the last picture; then the
//! JPEG data.

use std::ops::Range;

/// One picture of the file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BifFrame {
    /// Milliseconds from the start of the title.
    pub milliseconds: i64,
    range: Range<usize>,
}

/// A parsed BIF file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexBif {
    /// The pictures, in time order.
    pub frames: Vec<BifFrame>,
    data: Vec<u8>,
}

const MAGIC: [u8; 8] = [0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A];

impl PlexBif {
    /// `None` for anything that is not a well-formed BIF; a half file must not crash a player
    /// that only wanted a preview (PlexBIF.swift:28).
    pub fn parse(data: &[u8]) -> Option<Self> {
        if data.len() < 64 || data[0..8] != MAGIC {
            return None;
        }
        let word = |at: usize| -> Option<i64> {
            let b = data.get(at..at + 4)?;
            Some(i64::from(u32::from_le_bytes([b[0], b[1], b[2], b[3]])))
        };
        let count = word(12)?;
        let multiplier = match word(16)? {
            0 => 1000,
            m => m,
        };
        let table_end = 64 + (count + 1) * 8;
        if !(count > 0 && count < 1_000_000 && data.len() as i64 >= table_end) {
            return None;
        }
        let mut frames = Vec::with_capacity(count as usize);
        for index in 0..count {
            let entry = (64 + index * 8) as usize;
            let start = word(entry + 4)?;
            let end = word(entry + 12)?;
            if !(start >= table_end && end >= start && end <= data.len() as i64) {
                return None;
            }
            frames.push(BifFrame {
                // Both words are up to 2^32: the product does not fit an i64 for a hostile file.
                milliseconds: word(entry)?.saturating_mul(multiplier),
                range: start as usize..end as usize,
            });
        }
        Some(Self {
            frames,
            data: data.to_vec(),
        })
    }

    /// The picture for a position: the last one at or before it (the first before the start,
    /// the last after the end, so scrubbing to the edge never shows nothing).
    pub fn image_at_seconds(&self, seconds: f64) -> Option<Vec<u8>> {
        if self.frames.is_empty() || !seconds.is_finite() {
            return None;
        }
        let ms = (seconds.max(0.0) * 1000.0) as i64;
        let (mut low, mut high) = (0usize, self.frames.len() - 1);
        while low < high {
            let mid = (low + high).div_ceil(2);
            if self.frames[mid].milliseconds <= ms {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        self.image(low as i64)
    }

    /// The picture with this number, `None` outside the file.
    pub fn image(&self, index: i64) -> Option<Vec<u8>> {
        let frame = self.frames.get(usize::try_from(index).ok()?)?;
        Some(self.data[frame.range.clone()].to_vec())
    }

    /// Milliseconds between two pictures (the server writes them at a fixed step).
    pub fn interval(&self) -> i64 {
        if self.frames.len() > 1 {
            (self.frames[1].milliseconds - self.frames[0].milliseconds).max(0)
        } else {
            0
        }
    }

    /// Width and height of the pictures, read from the JPEG header of the first one (no image
    /// framework, so it works on every platform). `None` if it is no JPEG.
    pub fn picture_size(&self) -> Option<(i64, i64)> {
        let b = self.image(0)?;
        if !(b.len() > 4 && b[0] == 0xFF && b[1] == 0xD8) {
            return None;
        }
        let mut at = 2usize;
        while at + 9 < b.len() {
            if b[at] != 0xFF {
                at += 1;
                continue;
            }
            let marker = b[at + 1];
            if marker == 0xFF {
                at += 1;
                continue;
            }
            // Start of frame (baseline, extended, progressive), not the tables in between.
            if (0xC0..=0xCF).contains(&marker) && ![0xC4, 0xC8, 0xCC].contains(&marker) {
                let height = i64::from(b[at + 5]) << 8 | i64::from(b[at + 6]);
                let width = i64::from(b[at + 7]) << 8 | i64::from(b[at + 8]);
                return (width > 0 && height > 0).then_some((width, height));
            }
            if marker == 0xD8 || (0xD0..=0xD7).contains(&marker) || marker == 0x01 {
                at += 2;
                continue;
            }
            at += 2 + (usize::from(b[at + 2]) << 8 | usize::from(b[at + 3]));
        }
        None
    }
}
