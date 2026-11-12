//! Port of `AvComputation.swift` (JellyfinKit): the computation behind the image color. From
//! the pixels of an image to the hues, and from the hues to the color at every point of a page.
//!
//! Needs OKLab helpers from Swift `ColorSelection.swift`, which has no Rust port yet; the
//! three functions used (`oklab`, `srgb`, `linear`/`gamma`) are private copies at the bottom
//! of this file. Hue values are called `audio` in the Swift source (a translation slip for
//! "hue"); the Rust names keep `audio_at` and the `audio` field for 1:1 lookup.

use std::f64::consts::PI;

// MARK: Numbers (style tokens, `Colors.swift`)

/// Saturation away from the backdrop (AvComputation.swift:17).
pub const SATURATION: f64 = 0.38;
/// Saturation added near the backdrop (AvComputation.swift:19).
pub const SATURATION_NEAR: f64 = 0.20;
/// Brightness away from the backdrop, just above `reason` (AvComputation.swift:21).
pub const BRIGHTNESS: f64 = 0.075;
/// Brightness added near the backdrop (AvComputation.swift:23).
pub const BRIGHTNESS_NEAR: f64 = 0.140;
/// How fast brightness falls with distance, exponent (AvComputation.swift:25).
pub const DROP: f64 = 1.6;
/// How far the secondary hues may deviate from the main hue, fraction (AvComputation.swift:27).
pub const SPAN_RANGE: f64 = 0.34;

/// `reason` (#101010) in OKLab, lightness; every fade ends exactly here
/// (AvComputation.swift:30).
pub fn reason_l() -> f64 {
    oklab(16.0 / 255.0, 16.0 / 255.0, 16.0 / 255.0).0
}

/// A color in sRGB, each channel 0...1.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rgb {
    /// Red.
    pub r: f64,
    /// Green.
    pub g: f64,
    /// Blue.
    pub b: f64,
}

/// Hue (degrees), saturation and brightness (0...1) at a point (AvComputation.swift:127).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Hsb {
    /// Hue in degrees (Swift field `audio`).
    pub audio: f64,
    /// Saturation, 0...1.
    pub saturation: f64,
    /// Brightness, 0...1.
    pub brightness: f64,
}

// MARK: Hues from the image

/// Up to five hues in degrees, by weight; empty if none can be derived. `rgba`: pixels of
/// four bytes each (red, green, blue, alpha), ideally downscaled to at most 48 pixels on a
/// side (AvComputation.swift:37).
pub fn tones(rgba: &[u8]) -> Vec<f64> {
    const BINS: usize = 36;
    let mut bucket = [0.0_f64; BINS];
    let mut total = 0.0;

    for px in rgba.as_chunks::<4>().0 {
        let r = f64::from(px[0]) / 255.0;
        let g = f64::from(px[1]) / 255.0;
        let b = f64::from(px[2]) / 255.0;

        let up = r.max(g).max(b);
        let deep = r.min(g).min(b);
        let extent_span = up - deep;
        if !(extent_span > 0.04 && up > 0.08) {
            continue;
        }

        let saturation = extent_span / up;
        let mut audio = if up == r {
            (g - b) / extent_span
        } else if up == g {
            2.0 + (b - r) / extent_span
        } else {
            4.0 + (r - g) / extent_span
        };
        audio *= 60.0;
        if audio < 0.0 {
            audio += 360.0;
        }

        let weight = saturation * saturation * up;
        bucket[(BINS - 1).min((audio / 10.0) as usize)] += weight;
        total += weight;
    }

    if total <= 0.5 {
        return Vec::new();
    }

    // Pick peaks: the strongest bin, then the strongest one at least three bins (30 degrees)
    // away, and so on.
    let mut selected: Vec<f64> = Vec::new();
    let mut leftover = bucket;
    for _ in 0..5 {
        // Strongest bin; on a tie the first one stays (Swift `max(by:)`).
        let mut compartment = 0;
        let mut value = leftover[0];
        for (i, v) in leftover.iter().enumerate().skip(1) {
            if value < *v {
                compartment = i;
                value = *v;
            }
        }
        if value <= total * 0.035 {
            break;
        }
        // The exact hue comes from the bin and its neighbors, so it does not snap to
        // multiples of ten degrees.
        let mut x = 0.0;
        let mut y = 0.0;
        for k in 0..3 {
            let f = (compartment + BINS + k - 1) % BINS;
            let arc = (f as f64 * 10.0 + 5.0) * PI / 180.0;
            x += arc.cos() * bucket[f];
            y += arc.sin() * bucket[f];
        }
        let mut grad = y.atan2(x) * 180.0 / PI;
        if grad < 0.0 {
            grad += 360.0;
        }
        selected.push(grad);
        for k in 0..3 {
            leftover[(compartment + BINS + k - 1) % BINS] = 0.0;
        }
    }
    selected
}

// MARK: Color at a point

/// The hue at position `run` (0...1), blended between the hues found along the shortest path
/// on the color wheel; each hue is moved toward the main color by [`SPAN_RANGE`]
/// (AvComputation.swift:99).
pub fn audio_at(tones: &[f64], run: f64) -> f64 {
    let Some(&lead) = tones.first() else {
        return 0.0;
    };
    let damped = |audio: f64| -> f64 {
        let mut distance = audio - lead;
        if distance > 180.0 {
            distance -= 360.0;
        }
        if distance < -180.0 {
            distance += 360.0;
        }
        lead + distance * SPAN_RANGE
    };
    if tones.len() <= 1 {
        return lead;
    }

    let spot = run * (tones.len() - 1) as f64;
    let a = (spot as i64).min(tones.len() as i64 - 2).max(0) as usize;
    let t = spot - a as f64;

    let from = damped(tones[a]);
    let until = damped(tones[a + 1]);
    let mut distance = until - from;
    if distance > 180.0 {
        distance -= 360.0;
    }
    if distance < -180.0 {
        distance += 360.0;
    }
    let mut audio = from + distance * (t * t * (3.0 - 2.0 * t));
    if audio < 0.0 {
        audio += 360.0;
    }
    if audio >= 360.0 {
        audio -= 360.0;
    }
    audio
}

/// Hue, saturation and brightness at a point of the surface: `x` from left to right, `y` from
/// top to bottom, both 0...1. The backdrop sits at the top right, where it is brightest
/// (AvComputation.swift:126).
pub fn hsb(tones: &[f64], x: f64, y: f64) -> Hsb {
    let dx = 1.0 - x;
    let dy = y;
    let proximity = 1.0 - 1.0_f64.min((dx * dx + dy * dy).sqrt() / 1.414);
    Hsb {
        audio: audio_at(tones, (x + y) / 2.0),
        saturation: SATURATION + SATURATION_NEAR * proximity,
        brightness: BRIGHTNESS + BRIGHTNESS_NEAR * proximity.powf(DROP),
    }
}

/// The same color as sRGB; `decay` (1 ... 0) leads it back to `reason` in OKLab until at 0
/// exactly `reason` remains. Without hues: `reason` (AvComputation.swift:138; Swift default
/// `decay` 1).
pub fn color(tones: &[f64], x: f64, y: f64, decay: f64) -> Rgb {
    let gray = 16.0 / 255.0;
    if tones.is_empty() {
        return Rgb {
            r: gray,
            g: gray,
            b: gray,
        };
    }
    let t = hsb(tones, x, y);
    let rgb = hsb_post_rgb(t.audio, t.saturation, t.brightness);
    if decay >= 1.0 {
        return rgb;
    }
    let (lab_l, lab_a, lab_b) = oklab(rgb.r, rgb.g, rgb.b);
    let l = reason_l() + (lab_l - reason_l()) * decay;
    srgb(l, lab_a * decay, lab_b * decay).unwrap_or(Rgb { r: l, g: l, b: l })
}

/// How much of the color is still present on the way into the background (1 ... 0): fully
/// until `since`, then over `run_out` on a smootherstep curve to exactly zero
/// (AvComputation.swift:153).
pub fn decay(y: f64, since: f64, run_out: f64) -> f64 {
    if run_out <= 0.0 {
        return if y < since { 1.0 } else { 0.0 };
    }
    let t = ((y - since) / run_out).clamp(0.0, 1.0);
    1.0 - t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
}

/// The mesh of a detail page that fades out into `reason`, as points: `columns` x `rows`
/// colors (row by row, ARGB with full alpha, as `i32` bit patterns) over the height `height`.
/// The color is read from the TV image above `color_height`, faded from `since` over `run_out`
/// exactly to `reason` (AvComputation.swift:166).
pub fn points(
    tones: &[f64],
    columns: usize,
    rows: usize,
    height: f64,
    color_height: f64,
    since: f64,
    run_out: f64,
) -> Vec<i32> {
    if !(columns > 1 && rows > 1 && height > 0.0) {
        return Vec::new();
    }
    let k = |w: f64| -> u32 { (w * 255.0).round().clamp(0.0, 255.0) as u32 };
    let mut from: Vec<i32> = Vec::with_capacity(columns * rows);
    for z in 0..rows {
        let y = height * z as f64 / (rows - 1) as f64;
        let f = decay(y, since, run_out);
        for s in 0..columns {
            let x = s as f64 / (columns - 1) as f64;
            let c = color(tones, x, 1.0_f64.min(y / color_height.max(1.0)), f);
            let argb: u32 = 0xFF00_0000 | (k(c.r) << 16) | (k(c.g) << 8) | k(c.b);
            from.push(argb as i32);
        }
    }
    from
}

/// HSB to sRGB (0...1) (AvComputation.swift:186).
pub fn hsb_post_rgb(h: f64, s: f64, v: f64) -> Rgb {
    let c = v * s;
    let hh = h / 60.0;
    let x = c * (1.0 - (hh % 2.0 - 1.0).abs());
    let m = v - c;
    let (r, g, b) = match (hh as i64) % 6 {
        0 => (c + m, x + m, m),
        1 => (x + m, c + m, m),
        2 => (m, c + m, x + m),
        3 => (m, x + m, c + m),
        4 => (x + m, m, c + m),
        _ => (c + m, m, x + m),
    };
    Rgb { r, g, b }
}

// MARK: OKLab (private copy of ColorSelection.swift:18-45, Bjorn Ottosson)

fn linear(x: f64) -> f64 {
    if x <= 0.04045 {
        x / 12.92
    } else {
        ((x + 0.055) / 1.055).powf(2.4)
    }
}

fn gamma(x: f64) -> f64 {
    if x <= 0.0031308 {
        12.92 * x
    } else {
        1.055 * x.powf(1.0 / 2.4) - 0.055
    }
}

/// sRGB (0...1) to OKLab `(L, a, b)`.
fn oklab(r8: f64, g8: f64, b8: f64) -> (f64, f64, f64) {
    let r = linear(r8);
    let g = linear(g8);
    let b = linear(b8);
    let l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b).cbrt();
    let m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b).cbrt();
    let s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b).cbrt();
    (
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    )
}

/// OKLab to sRGB (0...1); `None` if outside sRGB.
fn srgb(l_: f64, a: f64, b: f64) -> Option<Rgb> {
    let l = (l_ + 0.3963377774 * a + 0.2158037573 * b).powf(3.0);
    let m = (l_ - 0.1055613458 * a - 0.0638541728 * b).powf(3.0);
    let s = (l_ - 0.0894841775 * a - 1.2914855480 * b).powf(3.0);
    let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
    let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
    let bb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;
    if ![r, g, bb].iter().all(|c| (-0.0001..=1.0001).contains(c)) {
        return None;
    }
    Some(Rgb {
        r: gamma(r.max(0.0)),
        g: gamma(g.max(0.0)),
        b: gamma(bb.max(0.0)),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `ColorSelection.spacing` (ColorSelection.swift:11): shortest distance on the hue wheel.
    fn spacing(a: f64, b: f64) -> f64 {
        let d = (a - b).abs() % 360.0;
        d.min(360.0 - d)
    }

    fn area(r: u8, g: u8, b: u8, points: usize) -> Vec<u8> {
        (0..points).flat_map(|_| [r, g, b, 255]).collect()
    }

    /// A red image has the red hue, a gray one none.
    #[test]
    fn audio_out_image() {
        let rot = tones(&area(200, 30, 30, 256));
        assert!(rot.first().is_some_and(|a| spacing(*a, 0.0) < 6.0));
        assert!(tones(&area(120, 120, 120, 256)).is_empty());
    }

    /// Two colors, two hues, with a minimum distance, by weight.
    #[test]
    fn two_peak() {
        let mut image = area(20, 60, 200, 300);
        image.extend(area(220, 140, 20, 100));
        let t = tones(&image);
        assert_eq!(t.len(), 2);
        assert!(spacing(t[0], 225.0) < 12.0);
        assert!(spacing(t[1], 38.0) < 12.0);
    }

    /// The fade-out ends exactly on `reason` and starts without a jump.
    #[test]
    fn run_out_ends_reason() {
        assert_eq!(decay(100.0, 300.0, 1300.0), 1.0);
        assert_eq!(decay(1600.0, 300.0, 1300.0), 0.0);
        assert!((decay(301.0, 300.0, 1300.0) - 1.0).abs() < 0.0001);
        let c = color(&[200.0], 0.9, 0.1, 0.0);
        let g = 16.0 / 255.0;
        assert!((c.r - g).abs() < 0.003 && (c.g - g).abs() < 0.003 && (c.b - g).abs() < 0.003);
    }

    /// Brightest at the top right, where the backdrop sits.
    #[test]
    fn backdrop_top_right() {
        let near = hsb(&[200.0], 1.0, 0.0);
        let far = hsb(&[200.0], 0.0, 1.0);
        assert!(near.brightness > far.brightness);
        assert!((near.brightness - (BRIGHTNESS + BRIGHTNESS_NEAR)).abs() < 0.0001);
    }

    /// Points for the surface: count, full opacity, base color when there are no hues.
    #[test]
    fn points() {
        let p = super::points(&[30.0, 200.0], 5, 8, 1000.0, 900.0, 300.0, 600.0);
        assert_eq!(p.len(), 40);
        assert!(p.iter().all(|v| (*v as u32) >> 24 == 0xFF));
        let gray = super::points(&[], 2, 2, 10.0, 10.0, 10.0, 0.0);
        assert!(gray.iter().all(|v| (*v as u32) == 0xFF10_1010));
    }
}
