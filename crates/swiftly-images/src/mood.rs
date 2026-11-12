//! `ImageMood.swift` and the mesh part of `ImageTone.swift`: how hues become a background,
//! identical on TV and iPhone. Drawing stays with the UI.

use crate::tone::av;
use swiftly_playback::av_computation::Rgb;

/// The colour is distributed over this height as on TV (`MoodReason.colorHeight`).
pub const COLOR_HEIGHT: f64 = 900.0;
/// The colour returns to `reason` over this length in OKLab (`MoodReason.runOut`).
pub const RUN_OUT: f64 = 1300.0;
/// Opacity of the tiled noise tile over the mesh.
pub const NOISE_OPACITY: f64 = 0.008;
/// Edge of the noise tile in pixels.
pub const NOISE_EDGE: usize = 96;

/// `Theme.reason` (#101010) as sRGB 0...1.
pub const REASON: Rgb = Rgb {
    r: 16.0 / 255.0,
    g: 16.0 / 255.0,
    b: 16.0 / 255.0,
};

/// One control point of the fading mesh.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MeshPoint {
    /// Position across, 0...1.
    pub x: f32,
    /// Position down, as a fraction of the mesh height.
    pub y: f32,
    /// Colour (sRGB 0...1).
    pub color: Rgb,
}

/// The fading mesh: `columns` x `rows` points, row by row.
#[derive(Debug, Clone, PartialEq)]
pub struct Mesh {
    /// Points per row.
    pub columns: usize,
    /// Number of rows.
    pub rows: usize,
    /// The points.
    pub points: Vec<MeshPoint>,
}

/// The mesh for a detail page that fades out into `reason` (iPhone): at the top the TV image over
/// `color_height`; from `since` it runs over `run_out` along a smootherstep curve exactly to
/// `reason`, with control rows dense over the fade (`ImageTone.network(_:height:...)`).
pub fn mesh(tones: &[f64], height: f64, color_height: f64, since: f64, run_out: f64) -> Mesh {
    const COLUMNS: usize = 5;
    let mut rows = vec![0.0, since * 0.5, since];
    for i in 1..=10 {
        rows.push(since + run_out * f64::from(i) / 10.0);
    }
    rows.push(height);
    let mut points = Vec::with_capacity(rows.len() * COLUMNS);
    for &y in &rows {
        let f = av::decay(y, since, run_out);
        for s in 0..COLUMNS {
            let x = s as f64 / (COLUMNS - 1) as f64;
            let color = if tones.is_empty() {
                REASON
            } else {
                av::color(tones, x, 1.0_f64.min(y / color_height), f)
            };
            points.push(MeshPoint {
                x: x as f32,
                y: 1.0_f64.min(y / height) as f32,
                color,
            });
        }
    }
    Mesh {
        columns: COLUMNS,
        rows: rows.len(),
        points,
    }
}

/// The mesh under a detail page whose header image is `since` high (`MoodReason.network`).
pub fn detail_mesh(tones: &[f64], since: f64) -> Mesh {
    mesh(tones, since + RUN_OUT, since + COLOR_HEIGHT, since, RUN_OUT)
}

/// The fine noise tile against banding (`ImageTone.noise`): 96 x 96 pixels of premultiplied RGBA,
/// each pixel randomly black or white at random coverage, so the mean stays neutral. Drawn at
/// [`NOISE_OPACITY`] it breaks up the 8-bit steps of a dark gradient (dithering). Deterministic:
/// a fixed xorshift, the same pixels on every run.
pub fn noise_tile() -> Vec<u8> {
    let mut pixels = vec![[0_u8; 4]; NOISE_EDGE * NOISE_EDGE];
    let mut condition: u64 = 0x2545_F491_4F6C_DD1D;
    for pixel in &mut pixels {
        condition ^= condition << 13;
        condition ^= condition >> 7;
        condition ^= condition << 17;
        let bright = condition & 1 == 1;
        let coverage = (condition >> 8) as u8;
        let channel = if bright { coverage } else { 0 };
        *pixel = [channel, channel, channel, coverage];
    }
    pixels.concat()
}
