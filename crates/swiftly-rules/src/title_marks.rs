//! Port of TitleMarksMetric.swift: the rules for title logos (crop, measure, choose size). Pure
//! functions; the image work itself lives in the UI.

/// What measuring a title logo yields: the opaque crop, how full it is and how bright.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LogoMeasurement {
    /// Crop in pixels, without the transparent border.
    pub x: i64,
    pub y: i64,
    pub width: i64,
    pub height: i64,
    /// Share of opaque pixels in the crop, 0...1.
    pub density: f64,
    /// Mean relative luminance of the opaque pixels, 0...1.
    pub luminance: f64,
}

impl LogoMeasurement {
    /// `pagesRatio`: width over height.
    pub fn pages_ratio(&self) -> f64 {
        self.width as f64 / self.height.max(1) as f64
    }
}

/// From here a pixel counts as opaque (out of 255).
pub const ALPHA_THRESHOLD: u8 = 8;
/// Below this a logo counts as dark and is drawn as a light silhouette.
pub const DARK_LIMIT: f64 = 0.25;

fn linear(c: f64) -> f64 {
    let c = c.clamp(0.0, 1.0);
    if c <= 0.04045 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

/// Measures an 8-bit RGBA image, premultiplied (row by row, `width * 4` bytes). `None` if
/// nothing is opaque.
pub fn measure(rgba: &[u8], width: i64, height: i64) -> Option<LogoMeasurement> {
    let needed = width.checked_mul(height).and_then(|n| n.checked_mul(4));
    if width <= 0 || height <= 0 || needed.is_none_or(|n| (rgba.len() as i64) < n) {
        return None;
    }
    let (w, h) = (width as usize, height as usize);
    let (mut left, mut right, mut top, mut bottom) = (w as i64, -1_i64, h as i64, -1_i64);
    for y in 0..h {
        let row = y * w * 4;
        for x in 0..w {
            if rgba[row + x * 4 + 3] > ALPHA_THRESHOLD {
                left = left.min(x as i64);
                right = right.max(x as i64);
                top = top.min(y as i64);
                bottom = y as i64;
            }
        }
    }
    if right < left || bottom < top {
        return None;
    }
    let mut opaque = 0_i64;
    let mut light_sum = 0.0;
    for y in top as usize..=bottom as usize {
        let row = y * w * 4;
        for x in left as usize..=right as usize {
            let i = row + x * 4;
            if rgba[i + 3] <= ALPHA_THRESHOLD {
                continue;
            }
            let a = f64::from(rgba[i + 3]) / 255.0;
            opaque += 1;
            // Premultiplied: divide by alpha, then linearize.
            let r = linear(f64::from(rgba[i]) / 255.0 / a);
            let g = linear(f64::from(rgba[i + 1]) / 255.0 / a);
            let b = linear(f64::from(rgba[i + 2]) / 255.0 / a);
            light_sum += 0.2126 * r + 0.7152 * g + 0.0722 * b;
        }
    }
    let b = right - left + 1;
    let h2 = bottom - top + 1;
    Some(LogoMeasurement {
        x: left,
        y: top,
        width: b,
        height: h2,
        density: opaque as f64 / (b * h2) as f64,
        luminance: if opaque > 0 {
            light_sum / opaque as f64
        } else {
            1.0
        },
    })
}

/// `isDark(luminance:)`.
pub fn is_dark(luminance: f64) -> bool {
    luminance < DARK_LIMIT
}

/// Gentle compensation: very full logos a little smaller, very thin ones a little larger,
/// 0.85...1.15.
pub fn density_factor(density: f64) -> f64 {
    let d = density.max(0.05);
    (0.5 / d).sqrt().clamp(0.85, 1.15)
}

/// Size for equal visual weight: via a target area instead of a fixed height. `row` is one title
/// line in points. h = sqrt(area / aspect) * density factor, w = h * aspect; then at least one
/// line high, at most 2.2 lines high and `max_width` wide (and, if set, at most `max_height`
/// high); the upper limits win.
pub fn size(
    pages_ratio: f64,
    density: f64,
    row: f64,
    max_width: f64,
    max_height: Option<f64>,
) -> (f64, f64) {
    let v = pages_ratio.max(0.05);
    let area = 12.0 * row * row;
    let mut h = (area / v).sqrt() * density_factor(density);
    h = h.max(row);
    h = h.min(2.2 * row);
    // A title slot of fixed height (Mac, TV) takes precedence over the minimum height.
    if let Some(max_height) = max_height {
        h = h.min(max_height.max(1.0));
    }
    let mut w = h * v;
    if w > max_width {
        w = max_width.max(1.0);
        h = w / v;
    }
    (w, h)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crop_density_and_luminance() {
        // 3x2: only the middle pixel of the top row is opaque white.
        let mut px = vec![0_u8; 3 * 2 * 4];
        px[4..8].copy_from_slice(&[255, 255, 255, 255]);
        let m = measure(&px, 3, 2).unwrap();
        assert_eq!((m.x, m.y, m.width, m.height), (1, 0, 1, 1));
        assert!((m.density - 1.0).abs() < 1e-12 && (m.luminance - 1.0).abs() < 1e-9);
        assert!(measure(&px[..8], 3, 2).is_none());
        assert!(measure(&[0; 24], 3, 2).is_none());
    }

    #[test]
    fn size_limits() {
        assert!((density_factor(0.0) - 1.15).abs() < 1e-12);
        assert!((density_factor(1.0) - 0.85).abs() < 1e-12);
        let (w, h) = size(4.0, 0.5, 20.0, 50.0, None);
        assert!((w - 50.0).abs() < 1e-9 && (h - 12.5).abs() < 1e-9);
        assert!(is_dark(0.1) && !is_dark(0.25));
    }
}
