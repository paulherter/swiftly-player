//! `ImageTone.swift`: the hue of an image, only the tone and not the colour.
//!
//! The calculation itself (36-bin hue histogram weighted by squared saturation times brightness,
//! up to five peaks 30 degrees apart, `color`, `hsb`, `decay`, `points`) is
//! `AvComputation.swift` and already lives in `swiftly_playback::av_computation`; it is
//! re-exported here as [`av`] so the image crate is the one place to look. This file adds what
//! `ImageTone` itself does: the capped cache of finished results and the 5 x 5 grid.

use std::collections::HashMap;
pub use swiftly_playback::av_computation as av;
use swiftly_playback::av_computation::Hsb;

/// Computed once per image, then remembered, so returning to a page does not recompute and the
/// background does not fade in again. Capped: browsing a library for an hour collects thousands
/// of entries; the oldest drop out. Keyed by the image address (the UI decides which string).
#[derive(Debug, Default)]
pub struct ToneCache {
    known: HashMap<String, Vec<f64>>,
    order: Vec<String>,
}

impl ToneCache {
    /// The most results kept (`ImageTone.atMost`).
    pub const AT_MOST: usize = 300;

    /// An empty cache.
    pub fn new() -> Self {
        Self::default()
    }

    /// Already known? `None` means "never computed", an empty slice "computed, found nothing".
    /// These differ: a grey image must not be searched again on every open.
    pub fn remembered(&self, key: &str) -> Option<&[f64]> {
        self.known.get(key).map(Vec::as_slice)
    }

    /// Stores a result; past [`AT_MOST`](Self::AT_MOST) the oldest entries are dropped.
    pub fn insert(&mut self, key: &str, tones: Vec<f64>) {
        if !self.known.contains_key(key) {
            self.order.push(key.to_string());
        }
        self.known.insert(key.to_string(), tones);
        if self.order.len() > Self::AT_MOST {
            let excess = self.order.len() - Self::AT_MOST;
            for old in self.order.drain(..excess) {
                self.known.remove(&old);
            }
        }
    }

    /// Number of results held.
    pub fn len(&self) -> usize {
        self.known.len()
    }

    /// Whether nothing is held.
    pub fn is_empty(&self) -> bool {
        self.known.is_empty()
    }
}

/// Up to five hues in degrees from RGBA pixels (four bytes each, ideally downscaled to at most
/// 48 pixels on a side); empty if none can be derived (`ImageTone.audioOut`, after decoding).
pub fn tones_from_rgba(rgba: &[u8]) -> Vec<f64> {
    av::tones(rgba)
}

/// One control point of the 5 x 5 grid of `ImageTone.network(_:)`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GridPoint {
    /// Position, 0...1 from the left.
    pub x: f32,
    /// Position, 0...1 from the top.
    pub y: f32,
    /// Hue, saturation and brightness here; `None` without hues (the app's `reason` colour).
    pub color: Option<Hsb>,
}

/// The 5 x 5 grid of control points, row by row, with the colour at each (`network(_:)`,
/// `color(_:at:)`).
pub fn grid(tones: &[f64]) -> Vec<GridPoint> {
    const PAGE: usize = 5;
    let mut out = Vec::with_capacity(PAGE * PAGE);
    for row in 0..PAGE {
        for column in 0..PAGE {
            let x = column as f32 / (PAGE - 1) as f32;
            let y = row as f32 / (PAGE - 1) as f32;
            let color = (!tones.is_empty()).then(|| av::hsb(tones, f64::from(x), f64::from(y)));
            out.push(GridPoint { x, y, color });
        }
    }
    out
}
