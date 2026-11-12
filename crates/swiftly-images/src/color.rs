//! `ColorSelection.swift`: OKLab (Bjorn Ottosson), the colour maths the fade of the image colour
//! into the background rests on.
//!
//! `swiftly-playback::av_computation` keeps private copies of `oklab`, `srgb` and the transfer
//! curves (this file was not ported when it was written); the colours built on them match the Swift
//! output (`tests/golden.rs`). The pieces it lacks (`spacing`, `srgb_lch`) are here.

/// Shortest distance of two hues on the colour wheel, in degrees (`spacing`).
pub fn spacing(a: f64, b: f64) -> f64 {
    let d = (a - b).abs() % 360.0;
    d.min(360.0 - d)
}

/// sRGB channel (0...1) to linear light.
pub fn linear(x: f64) -> f64 {
    if x <= 0.04045 {
        x / 12.92
    } else {
        ((x + 0.055) / 1.055).powf(2.4)
    }
}

/// Linear light to an sRGB channel (0...1).
pub fn gamma(x: f64) -> f64 {
    if x <= 0.003_130_8 {
        12.92 * x
    } else {
        1.055 * x.powf(1.0 / 2.4) - 0.055
    }
}

/// sRGB (each 0...1) to OKLab `(L, a, b)`.
pub fn oklab(r8: f64, g8: f64, b8: f64) -> (f64, f64, f64) {
    let (r, g, b) = (linear(r8), linear(g8), linear(b8));
    let l = (0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b).cbrt();
    let m = (0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b).cbrt();
    let s = (0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b).cbrt();
    (
        0.210_454_255_3 * l + 0.793_617_785_0 * m - 0.004_072_046_8 * s,
        1.977_998_495_1 * l - 2.428_592_205_0 * m + 0.450_593_709_9 * s,
        0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766_0 * s,
    )
}

/// OKLab to sRGB (each 0...1). `None` if the colour lies outside sRGB.
pub fn srgb_from_lab(l_: f64, a: f64, b: f64) -> Option<(f64, f64, f64)> {
    let l = (l_ + 0.396_337_777_4 * a + 0.215_803_757_3 * b).powf(3.0);
    let m = (l_ - 0.105_561_345_8 * a - 0.063_854_172_8 * b).powf(3.0);
    let s = (l_ - 0.089_484_177_5 * a - 1.291_485_548_0 * b).powf(3.0);
    let r = 4.076_741_662_1 * l - 3.307_711_591_3 * m + 0.230_969_929_2 * s;
    let g = -1.268_438_004_6 * l + 2.609_757_401_1 * m - 0.341_319_396_5 * s;
    let bb = -0.004_196_086_3 * l - 0.703_418_614_7 * m + 1.707_614_701_0 * s;
    if ![r, g, bb].iter().all(|v| (-0.0001..=1.0001).contains(v)) {
        return None;
    }
    Some((gamma(r.max(0.0)), gamma(g.max(0.0)), gamma(bb.max(0.0))))
}

/// OKLCH to sRGB with **preserved hue** (degrees): if it does not fit in sRGB, chroma is
/// reduced in steps of 0.005; the hue is never shifted.
pub fn srgb_lch(l: f64, chroma: f64, hue: f64) -> (f64, f64, f64) {
    let mut c = chroma;
    let w = hue.to_radians();
    while c > 0.0 {
        if let Some(found) = srgb_from_lab(l, c * w.cos(), c * w.sin()) {
            return found;
        }
        c -= 0.005;
    }
    srgb_from_lab(l, 0.0, 0.0).unwrap_or((l, l, l))
}
