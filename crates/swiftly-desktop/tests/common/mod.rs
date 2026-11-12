//! The golden tolerance policy shared by the frame-golden tests (the goldens come from macOS).
//!
//! The vector rasteriser (swiftly-ui `icons.rs`, f32 edge coverage with arcs flattened through libm) rounds a few edge
//! pixels differently per OS build and CPU, so a golden may differ by a few levels on icon edges (measured 2026-11-10:
//! 3-12 levels in well under 0.05 % of the pixels, never on fills). The tolerance has two parts: at most 12 levels,
//! and on macOS a difference above 2 levels may touch at most 0.05 % of the pixels (a real layout change moves far
//! more pixels and fails). Other systems keep the wider level tolerance (up to 10 levels from font hinting) without
//! a pixel limit.
#![allow(dead_code)]

/// The largest allowed difference in levels.
pub const TOLERANCE: u8 = 12;
/// On macOS: the share of pixels that may differ by more than 2 levels.
pub const MAC_PIXEL_SHARE: f64 = 0.0005;

/// Whether a golden with the largest difference `max` in `share` (0..1) of the pixels passes.
pub fn golden_ok(max: u8, share: f64) -> bool {
    if cfg!(target_os = "macos") {
        // Edge-only differences (a tiny share of the pixels) may round a few levels further, as elsewhere.
        return max <= 2 || (max <= OTHER_EDGE_TOLERANCE && share <= MAC_PIXEL_SHARE);
    }
    // Other systems: font hinting adds up to 10 levels anywhere; a single icon edge may round a little further
    // (measured 13 levels in 0.0016 % of the pixels on Linux), which stays far below any layout change.
    max <= TOLERANCE || (max <= OTHER_EDGE_TOLERANCE && share <= MAC_PIXEL_SHARE)
}

/// Elsewhere: the largest difference allowed when it touches at most `MAC_PIXEL_SHARE` of the pixels.
pub const OTHER_EDGE_TOLERANCE: u8 = 24;
