//! The app's own icons (Phosphor-style outlines drawn by the Swift app from `Icons.xcassets`), shared by every target.
//! The outline path data is rasterised here into white-on-alpha pictures on the image page and tinted at draw time,
//! so a symbol has the same shape and stroke on every OS. The stroke weight follows the point size like
//! `AppIcon.suffix` (one stroke look at every size).

use crate::cx::{Cx, ImageId};
use crate::view::{Node, Paint};
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use swiftly_render::Color;

/// Path data of an asset (`house`, `house.fill`, `film-strip.w28`), template space.
pub fn path_data(asset: &str) -> Option<&'static str> {
    find(asset).or_else(|| {
        // The drawn-in Phosphor icons come in two weights only: the heavier strokes use the plain one.
        let base = asset
            .strip_suffix(".w28")
            .or_else(|| asset.strip_suffix(".w32"))?;
        crate::icon_data_phos::ICONS_PHOS
            .iter()
            .find(|(n, _)| *n == base)
            .map(|(_, d)| *d)
    })
}

fn find(asset: &str) -> Option<&'static str> {
    crate::icon_data::ICONS
        .iter()
        .chain(crate::icon_data_more::ICONS_MORE.iter())
        .chain(crate::icon_data_forms::ICONS_FORMS.iter())
        .chain(crate::icon_data_audit::ICONS_AUDIT.iter())
        .chain(crate::icon_data_keys::ICONS_KEYS.iter())
        .chain(crate::icon_data_rest::ICONS_REST.iter())
        .chain(crate::icon_data_kinds::ICONS_KINDS.iter())
        .chain(crate::icon_data_phos::ICONS_PHOS.iter())
        .find(|(n, _)| *n == asset)
        .map(|(_, d)| *d)
}

/// Asset names that were asked for and not found (`SWIFTLY_ICON_REPORT=1` prints each once to stderr as
/// `icon missing: <name>`); a missing icon draws as an empty square, so this is how a gap is found.
fn note_missing(asset: &str) {
    use std::sync::{Mutex, OnceLock};
    static SEEN: OnceLock<Mutex<std::collections::BTreeSet<String>>> = OnceLock::new();
    if std::env::var_os("SWIFTLY_ICON_REPORT").is_none() {
        return;
    }
    if let Ok(mut seen) = SEEN.get_or_init(Default::default).lock()
        && seen.insert(asset.to_owned())
    {
        eprintln!("icon missing: {asset}");
    }
}

/// The stroke suffix for an icon drawn at `size` pt (`AppIcon.suffix`): strokes 16, 24, 28, 32 on the 256 grid; the one
/// closest to 24 at 20 pt. `tv` draws at double size, so pass half.
pub fn stroke_suffix(size: f32) -> &'static str {
    let wanted = 24.0 * 20.0 / size.max(1.0);
    [
        (16.0_f32, ".light"),
        (24.0, ""),
        (28.0, ".w28"),
        (32.0, ".w32"),
    ]
    .iter()
    .min_by(|a, b| {
        (a.0 - wanted)
            .abs()
            .partial_cmp(&(b.0 - wanted).abs())
            .unwrap_or(std::cmp::Ordering::Equal)
    })
    .map_or("", |s| s.1)
}

#[derive(Clone, Copy)]
struct P(f32, f32);

fn flatten(d: &str) -> Vec<Vec<P>> {
    // Tokens: command letters and numbers.
    let mut toks: Vec<String> = Vec::new();
    let mut cur = String::new();
    for ch in d.chars() {
        if ch.is_ascii_alphabetic() {
            if !cur.is_empty() {
                toks.push(std::mem::take(&mut cur));
            }
            toks.push(ch.to_string());
        } else if ch == ' ' || ch == ',' || ch == '\n' {
            if !cur.is_empty() {
                toks.push(std::mem::take(&mut cur));
            }
        } else if ch == '-' && !cur.is_empty() && !cur.ends_with('e') {
            toks.push(std::mem::take(&mut cur));
            cur.push(ch);
        } else {
            cur.push(ch);
        }
    }
    if !cur.is_empty() {
        toks.push(cur);
    }
    let mut subs: Vec<Vec<P>> = Vec::new();
    let (mut i, mut cmd) = (0, 'M');
    let (mut pos, mut start, mut last_c) = (P(0.0, 0.0), P(0.0, 0.0), P(0.0, 0.0));
    let num = |i: &mut usize| -> f32 {
        let v = toks.get(*i).and_then(|t| t.parse().ok()).unwrap_or(0.0);
        *i += 1;
        v
    };
    while i < toks.len() {
        if toks[i]
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_alphabetic())
        {
            cmd = toks[i].chars().next().unwrap_or('Z');
            i += 1;
            if cmd == 'Z' || cmd == 'z' {
                if let Some(s) = subs.last_mut() {
                    s.push(start);
                }
                pos = start;
                continue;
            }
        }
        let rel = cmd.is_ascii_lowercase();
        let (ox, oy) = if rel { (pos.0, pos.1) } else { (0.0, 0.0) };
        match cmd.to_ascii_uppercase() {
            'M' => {
                let p = P(num(&mut i) + ox, num(&mut i) + oy);
                subs.push(vec![p]);
                pos = p;
                start = p;
                cmd = if rel { 'l' } else { 'L' };
            }
            'L' => {
                let p = P(num(&mut i) + ox, num(&mut i) + oy);
                if let Some(s) = subs.last_mut() {
                    s.push(p);
                }
                pos = p;
            }
            'H' => {
                let p = P(num(&mut i) + ox, pos.1);
                if let Some(s) = subs.last_mut() {
                    s.push(p);
                }
                pos = p;
            }
            'V' => {
                let p = P(pos.0, num(&mut i) + oy);
                if let Some(s) = subs.last_mut() {
                    s.push(p);
                }
                pos = p;
            }
            'C' | 'S' => {
                let c1 = if cmd.eq_ignore_ascii_case(&'C') {
                    P(num(&mut i) + ox, num(&mut i) + oy)
                } else {
                    P(2.0 * pos.0 - last_c.0, 2.0 * pos.1 - last_c.1)
                };
                let c2 = P(num(&mut i) + ox, num(&mut i) + oy);
                let p = P(num(&mut i) + ox, num(&mut i) + oy);
                let p0 = pos;
                if let Some(s) = subs.last_mut() {
                    for k in 1..=16 {
                        let t = k as f32 / 16.0;
                        let u = 1.0 - t;
                        s.push(P(
                            u * u * u * p0.0
                                + 3.0 * u * u * t * c1.0
                                + 3.0 * u * t * t * c2.0
                                + t * t * t * p.0,
                            u * u * u * p0.1
                                + 3.0 * u * u * t * c1.1
                                + 3.0 * u * t * t * c2.1
                                + t * t * t * p.1,
                        ));
                    }
                }
                last_c = c2;
                pos = p;
                continue;
            }
            'Q' => {
                let c = P(num(&mut i) + ox, num(&mut i) + oy);
                let p = P(num(&mut i) + ox, num(&mut i) + oy);
                let p0 = pos;
                if let Some(s) = subs.last_mut() {
                    for k in 1..=12 {
                        let t = k as f32 / 12.0;
                        let u = 1.0 - t;
                        s.push(P(
                            u * u * p0.0 + 2.0 * u * t * c.0 + t * t * p.0,
                            u * u * p0.1 + 2.0 * u * t * c.1 + t * t * p.1,
                        ));
                    }
                }
                pos = p;
            }
            'A' => {
                let (rx, ry, rot) = (num(&mut i).abs(), num(&mut i).abs(), num(&mut i));
                let (large, sweep) = (num(&mut i) != 0.0, num(&mut i) != 0.0);
                let p = P(num(&mut i) + ox, num(&mut i) + oy);
                let p0 = pos;
                if let Some(s) = subs.last_mut() {
                    arc(s, p0, p, rx, ry, rot, large, sweep);
                }
                pos = p;
            }
            _ => {
                i += 1;
            }
        }
        last_c = pos;
    }
    subs
}

#[allow(clippy::too_many_arguments)]
fn arc(out: &mut Vec<P>, p0: P, p1: P, rx: f32, ry: f32, rot_deg: f32, large: bool, sweep: bool) {
    if rx == 0.0 || ry == 0.0 || (p0.0 == p1.0 && p0.1 == p1.1) {
        out.push(p1);
        return;
    }
    let phi = rot_deg.to_radians();
    let (cp, sp) = (phi.cos(), phi.sin());
    let (dx, dy) = ((p0.0 - p1.0) / 2.0, (p0.1 - p1.1) / 2.0);
    let (x1, y1) = (cp * dx + sp * dy, -sp * dx + cp * dy);
    let (mut rx, mut ry) = (rx, ry);
    let lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
    if lam > 1.0 {
        let s = lam.sqrt();
        rx *= s;
        ry *= s;
    }
    let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
    let den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
    let mut co = (num / den).max(0.0).sqrt();
    if large == sweep {
        co = -co;
    }
    let (cxp, cyp) = (co * rx * y1 / ry, -co * ry * x1 / rx);
    let (cx, cy) = (
        cp * cxp - sp * cyp + (p0.0 + p1.0) / 2.0,
        sp * cxp + cp * cyp + (p0.1 + p1.1) / 2.0,
    );
    let ang = |ux: f32, uy: f32, vx: f32, vy: f32| (ux * vy - uy * vx).atan2(ux * vx + uy * vy);
    let th1 = ang(1.0, 0.0, (x1 - cxp) / rx, (y1 - cyp) / ry);
    let mut dth = ang(
        (x1 - cxp) / rx,
        (y1 - cyp) / ry,
        (-x1 - cxp) / rx,
        (-y1 - cyp) / ry,
    );
    if !sweep && dth > 0.0 {
        dth -= std::f32::consts::TAU;
    } else if sweep && dth < 0.0 {
        dth += std::f32::consts::TAU;
    }
    let steps = ((dth.abs() / std::f32::consts::FRAC_PI_2) * 8.0)
        .ceil()
        .max(2.0) as usize;
    for k in 1..=steps {
        let t = th1 + dth * k as f32 / steps as f32;
        let (x, y) = (rx * t.cos(), ry * t.sin());
        out.push(P(cp * x - sp * y + cx, sp * x + cp * y + cy));
    }
}

/// Rasterises path data (nonzero fill) into a `px` x `px` straight-alpha RGBA picture, white where covered. With `fit`
/// the drawing is centred on its bounding box at 100 template units per canvas; without it the path is in canvas units
/// (0 to 100).
pub fn rasterize(d: &str, px: u32, fit: bool) -> Vec<u8> {
    raster(d, px, if fit { Origin::Bounds } else { Origin::Canvas })
}

/// The centre of the symbol template (Regular-M: margins 1594..1706, baseline 1126, capline 1055.54).
pub const TEMPLATE_CENTRE: (f32, f32) = (1650.0, 1090.77);

/// Like [`rasterize`] with `fit`, but centred on the symbol template's centre instead of the path's bounding box: how SwiftUI
/// places a custom symbol, so an asymmetric glyph (an arrow ring with its head on one side) keeps its ring on the box centre.
pub fn rasterize_template(d: &str, px: u32) -> Vec<u8> {
    raster(d, px, Origin::At(TEMPLATE_CENTRE.0, TEMPLATE_CENTRE.1))
}

/// What the picture is centred on.
#[derive(Clone, Copy)]
enum Origin {
    /// The path is already in canvas units (0 to 100).
    Canvas,
    /// The centre of the path's bounding box.
    Bounds,
    /// A fixed point of the path's own units.
    At(f32, f32),
}

fn raster(d: &str, px: u32, origin: Origin) -> Vec<u8> {
    let subs = flatten(d);
    let (mut x0, mut y0, mut x1, mut y1) = (f32::MAX, f32::MAX, f32::MIN, f32::MIN);
    for p in subs.iter().flatten() {
        x0 = x0.min(p.0);
        y0 = y0.min(p.1);
        x1 = x1.max(p.0);
        y1 = y1.max(p.1);
    }
    let (ox, oy) = match origin {
        Origin::Bounds => (50.0 - (x0 + x1) / 2.0, 50.0 - (y0 + y1) / 2.0),
        Origin::Canvas => (0.0, 0.0),
        Origin::At(x, y) => (50.0 - x, 50.0 - y),
    };
    let k = px as f32 / 100.0;
    // Edges in pixel space: (x_top, y_top, x_bottom, y_bottom, dir).
    let mut edges: Vec<(f32, f32, f32, f32, i32)> = Vec::new();
    for s in &subs {
        for w in s.windows(2) {
            let (a, b) = (
                ((w[0].0 + ox) * k, (w[0].1 + oy) * k),
                ((w[1].0 + ox) * k, (w[1].1 + oy) * k),
            );
            if (a.1 - b.1).abs() < f32::EPSILON {
                continue;
            }
            if a.1 < b.1 {
                edges.push((a.0, a.1, b.0, b.1, 1));
            } else {
                edges.push((b.0, b.1, a.0, a.1, -1));
            }
        }
        if let (Some(f), Some(l)) = (s.first(), s.last()) {
            let (a, b) = (
                ((l.0 + ox) * k, (l.1 + oy) * k),
                ((f.0 + ox) * k, (f.1 + oy) * k),
            );
            if (a.1 - b.1).abs() > f32::EPSILON {
                if a.1 < b.1 {
                    edges.push((a.0, a.1, b.0, b.1, 1));
                } else {
                    edges.push((b.0, b.1, a.0, a.1, -1));
                }
            }
        }
    }
    const SUB: usize = 4;
    let w = px as usize;
    let mut out = vec![0_u8; w * w * 4];
    let mut cov = vec![0.0_f32; w];
    for row in 0..w {
        cov.iter_mut().for_each(|c| *c = 0.0);
        for sub in 0..SUB {
            let y = row as f32 + (sub as f32 + 0.5) / SUB as f32;
            let mut xs: Vec<(f32, i32)> = edges
                .iter()
                .filter(|e| e.1 <= y && y < e.3)
                .map(|e| (e.0 + (y - e.1) / (e.3 - e.1) * (e.2 - e.0), e.4))
                .collect();
            xs.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
            let mut wind = 0;
            for j in 0..xs.len() {
                wind += xs[j].1;
                if wind != 0 && j + 1 < xs.len() {
                    let (a, b) = (xs[j].0.max(0.0), xs[j + 1].0.min(w as f32));
                    if b <= a {
                        continue;
                    }
                    let (ia, ib) = (a.floor() as usize, (b.ceil() as usize).min(w));
                    for (x, c) in cov.iter_mut().enumerate().take(ib).skip(ia) {
                        let l = a.max(x as f32);
                        let r = b.min(x as f32 + 1.0);
                        *c += (r - l).max(0.0) / SUB as f32;
                    }
                }
            }
        }
        for (x, c) in cov.iter().enumerate() {
            let o = (row * w + x) * 4;
            out[o..o + 3].copy_from_slice(&[255, 255, 255]);
            out[o + 3] = (c.clamp(0.0, 1.0) * 255.0).round() as u8;
        }
    }
    out
}

/// Rasterises `d` (SVG path data) into a `w` x `h` coverage image (white with alpha) mapping the SVG viewBox `vb`
/// (x, y, width, height) onto it: for artwork that is not on the 100 x 100 icon grid (the wordmark).
pub fn rasterize_box(d: &str, w: usize, h: usize, vb: [f32; 4]) -> Vec<u8> {
    let subs = flatten(d);
    let (vx, vy, kx, ky) = (vb[0], vb[1], w as f32 / vb[2], h as f32 / vb[3]);
    // Edges in pixel space: (x_top, y_top, x_bottom, y_bottom, dir).
    let mut edges: Vec<(f32, f32, f32, f32, i32)> = Vec::new();
    for s in &subs {
        for w in s.windows(2) {
            let (a, b) = (
                ((w[0].0 - vx) * kx, (w[0].1 - vy) * ky),
                ((w[1].0 - vx) * kx, (w[1].1 - vy) * ky),
            );
            if (a.1 - b.1).abs() < f32::EPSILON {
                continue;
            }
            if a.1 < b.1 {
                edges.push((a.0, a.1, b.0, b.1, 1));
            } else {
                edges.push((b.0, b.1, a.0, a.1, -1));
            }
        }
        if let (Some(f), Some(l)) = (s.first(), s.last()) {
            let (a, b) = (
                ((l.0 - vx) * kx, (l.1 - vy) * ky),
                ((f.0 - vx) * kx, (f.1 - vy) * ky),
            );
            if (a.1 - b.1).abs() > f32::EPSILON {
                if a.1 < b.1 {
                    edges.push((a.0, a.1, b.0, b.1, 1));
                } else {
                    edges.push((b.0, b.1, a.0, a.1, -1));
                }
            }
        }
    }
    const SUB: usize = 4;
    let mut out = vec![0_u8; w * h * 4];
    let mut cov = vec![0.0_f32; w];
    for row in 0..h {
        cov.iter_mut().for_each(|c| *c = 0.0);
        for sub in 0..SUB {
            let y = row as f32 + (sub as f32 + 0.5) / SUB as f32;
            let mut xs: Vec<(f32, i32)> = edges
                .iter()
                .filter(|e| e.1 <= y && y < e.3)
                .map(|e| (e.0 + (y - e.1) / (e.3 - e.1) * (e.2 - e.0), e.4))
                .collect();
            xs.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
            let mut wind = 0;
            for j in 0..xs.len() {
                wind += xs[j].1;
                if wind != 0 && j + 1 < xs.len() {
                    let (a, b) = (xs[j].0.max(0.0), xs[j + 1].0.min(w as f32));
                    if b <= a {
                        continue;
                    }
                    let (ia, ib) = (a.floor() as usize, (b.ceil() as usize).min(w));
                    for (x, c) in cov.iter_mut().enumerate().take(ib).skip(ia) {
                        let l = a.max(x as f32);
                        let r = b.min(x as f32 + 1.0);
                        *c += (r - l).max(0.0) / SUB as f32;
                    }
                }
            }
        }
        for (x, c) in cov.iter().enumerate() {
            let o = (row * w + x) * 4;
            out[o..o + 3].copy_from_slice(&[255, 255, 255]);
            out[o + 3] = (c.clamp(0.0, 1.0) * 255.0).round() as u8;
        }
    }
    out
}

/// The wordmark's letters (white in the artwork), `.github/images/wordmark.svg`.
const WORDMARK_LETTERS: &str = "M262.0 8.0 Q224.0 8.0 184.5 -1.0 Q145.0 -10.0 111.0 -30.0 Q77.0 -50.0 54.0 -85.0 Q31.0 -120.0 23.0 -173.0 L183.0 -173.0 Q189.0 -157.0 201.5 -145.5 Q214.0 -134.0 232.5 -128.5 Q251.0 -123.0 270.0 -123.0 Q283.0 -123.0 295.0 -125.0 Q307.0 -127.0 316.5 -132.0 Q326.0 -137.0 331.0 -144.5 Q336.0 -152.0 336.0 -163.0 Q336.0 -177.0 327.5 -184.5 Q319.0 -192.0 304.0 -196.5 Q289.0 -201.0 270.0 -205.0 Q251.0 -210.0 230.5 -213.5 Q210.0 -217.0 191.0 -222.0 Q152.0 -231.0 117.0 -247.5 Q82.0 -264.0 60.0 -294.5 Q38.0 -325.0 38.0 -376.0 Q38.0 -420.0 57.0 -451.0 Q76.0 -482.0 108.0 -501.0 Q140.0 -520.0 179.0 -528.5 Q218.0 -537.0 257.0 -537.0 Q312.0 -537.0 359.0 -519.5 Q406.0 -502.0 437.5 -463.5 Q469.0 -425.0 477.0 -363.0 L324.0 -363.0 Q321.0 -383.0 301.0 -395.0 Q281.0 -407.0 251.0 -407.0 Q240.0 -407.0 229.0 -405.0 Q218.0 -403.0 209.5 -399.0 Q201.0 -395.0 195.5 -388.0 Q190.0 -381.0 190.0 -371.0 Q190.0 -364.0 195.0 -356.5 Q200.0 -349.0 210.0 -343.5 Q220.0 -338.0 235.0 -334.0 Q266.0 -327.0 298.5 -321.0 Q331.0 -315.0 360.0 -308.0 Q392.0 -300.0 422.0 -285.0 Q452.0 -270.0 471.5 -242.0 Q491.0 -214.0 491.0 -166.0 Q491.0 -116.0 470.5 -82.0 Q450.0 -48.0 416.0 -29.0 Q382.0 -10.0 342.0 -1.0 Q302.0 8.0 262.0 8.0 Z M644.0 -0.0 L477.0 -527.0 L650.0 -527.0 L738.0 -186.0 L833.0 -527.0 L1005.0 -527.0 L1100.0 -186.0 L1187.0 -527.0 L1356.0 -527.0 L1189.0 -0.0 L1013.0 -0.0 L916.0 -333.0 L820.0 -0.0 Z M1370.0 -0.0 L1370.0 -527.0 L1529.0 -527.0 L1529.0 -0.0 Z M1638.0 -0.0 L1638.0 -386.0 L1561.0 -386.0 L1561.0 -527.0 L1638.0 -527.0 L1638.0 -572.0 Q1638.0 -633.0 1658.0 -672.0 Q1678.0 -711.0 1720.5 -729.0 Q1763.0 -747.0 1827.0 -747.0 L1923.0 -747.0 L1923.0 -606.0 L1847.0 -606.0 Q1828.0 -606.0 1817.0 -600.5 Q1806.0 -595.0 1801.5 -583.5 Q1797.0 -572.0 1797.0 -555.0 L1797.0 -527.0 L1923.0 -527.0 L1923.0 -386.0 L1797.0 -386.0 L1797.0 -0.0 Z M2187.0 -0.0 Q2119.0 -0.0 2074.5 -15.5 Q2030.0 -31.0 2008.5 -69.5 Q1987.0 -108.0 1987.0 -178.0 L1987.0 -386.0 L1911.0 -386.0 L1911.0 -527.0 L1987.0 -527.0 L1987.0 -663.0 L2146.0 -663.0 L2146.0 -527.0 L2251.0 -527.0 L2251.0 -386.0 L2146.0 -386.0 L2146.0 -201.0 Q2146.0 -175.0 2155.0 -158.5 Q2164.0 -142.0 2201.0 -142.0 L2246.0 -142.0 L2246.0 -0.0 Z M2281.0 -0.0 L2281.0 -708.0 L2440.0 -708.0 L2440.0 -0.0 Z M2739.0 246.0 Q2679.0 246.0 2621.0 230.0 Q2563.0 214.0 2510.0 178.0 L2560.0 50.0 Q2590.0 71.0 2633.5 86.5 Q2677.0 102.0 2731.0 102.0 Q2807.0 102.0 2838.5 68.0 Q2870.0 34.0 2870.0 -32.0 L2870.0 -48.0 Q2853.0 -27.0 2828.5 -15.0 Q2804.0 -3.0 2777.0 2.5 Q2750.0 8.0 2723.0 8.0 Q2647.0 8.0 2601.0 -24.0 Q2555.0 -56.0 2534.0 -112.0 Q2513.0 -168.0 2513.0 -238.0 L2513.0 -527.0 L2671.0 -527.0 L2671.0 -269.0 Q2671.0 -248.0 2674.0 -224.5 Q2677.0 -201.0 2686.0 -181.0 Q2695.0 -161.0 2715.0 -148.5 Q2735.0 -136.0 2769.0 -136.0 Q2814.0 -136.0 2835.0 -158.0 Q2856.0 -180.0 2862.5 -212.5 Q2869.0 -245.0 2869.0 -278.0 L2869.0 -527.0 L3028.0 -527.0 L3028.0 -101.0 Q3028.0 -24.0 3014.5 39.5 Q3001.0 103.0 2969.0 149.0 Q2937.0 195.0 2881.0 220.5 Q2825.0 246.0 2739.0 246.0 Z";
/// The play mark of the wordmark (the accent colour in the artwork).
const WORDMARK_MARK: &str = "M1407.4 -748.5 L1508.1 -690.8 A28.0 28.0 0 0 1 1508.1 -642.2 L1407.4 -584.5 A28.0 28.0 0 0 1 1365.5 -608.8 L1365.5 -724.2 A28.0 28.0 0 0 1 1407.4 -748.5 Z";
/// The wordmark's viewBox (x, y, width, height).
const WORDMARK_BOX: [f32; 4] = [23.0, -778.0, 3005.0, 1024.0];

/// The capsule path of spoke `i` of 12 for an activity spinner in a 100 x 100 box.
fn spoke_path(i: usize) -> String {
    let ang = (i as f32) * std::f32::consts::TAU / 12.0;
    let (sn, cs) = ang.sin_cos();
    // Capsule from radius 24 to 48, width 11, round ends.
    let (r0, r1, hw) = (24.0_f32, 48.0_f32, 5.5_f32);
    let pt = |r: f32, side: f32| {
        // r along the spoke (up = -y when i = 0), side across.
        (50.0 + sn * r + cs * side, 50.0 - cs * r + sn * side)
    };
    let mut d = String::new();
    let mut first = true;
    let mut add = |(x, y): (f32, f32)| {
        d.push_str(if first { "M " } else { " L " });
        d.push_str(&format!("{x:.2} {y:.2}"));
        first = false;
    };
    for k in 0..=8 {
        let a = std::f32::consts::PI * k as f32 / 8.0;
        add(pt(r1 - hw + hw * a.sin(), hw * a.cos()));
    }
    for k in 0..=8 {
        let a = std::f32::consts::PI * k as f32 / 8.0;
        add(pt(r0 + hw - hw * a.sin(), -hw * a.cos()));
    }
    d.push_str(" Z");
    d
}

/// Number of spokes of the spinner.
pub const SPOKES: usize = 12;

/// A cache of rasterised icons on one image page.
#[derive(Clone)]
pub struct Icons {
    cx: Cx,
    /// Shared with the `Cx` (see [`Cx::scale`]): follows the window when its scale changes.
    scale: Rc<Cell<f32>>,
    cache: Rc<RefCell<crate::cx::IconCache>>,
}

impl Icons {
    /// Icons for `cx` drawn at `scale` pixels per point.
    pub fn new(cx: &Cx, scale: f32) -> Icons {
        cx.scale.set(scale);
        Icons {
            cx: cx.clone(),
            scale: Rc::clone(&cx.scale),
            cache: Rc::clone(&cx.icon_cache),
        }
    }

    fn image(&self, key: &str, pt: f32, make: impl Fn(u32) -> Vec<u8>) -> Option<ImageId> {
        let px = ((pt * self.scale.get()).round() as u32).max(8);
        let k = (key.to_owned(), px);
        if let Some(hit) = self.cache.borrow().get(&k) {
            return *hit;
        }
        let id = self.cx.add_image(px, px, &make(px));
        if id.is_none() && std::env::var_os("SWIFTLY_ICON_REPORT").is_some() {
            let (x, y, row) = self.cx.images.borrow().cursor();
            eprintln!("icon page full: {key} at {px} px, shelf cursor x {x} y {y} row {row}");
        }
        self.cache.borrow_mut().insert(k, id);
        id
    }

    /// An icon `pt` points square in `tint`. `asset` is the asset name without stroke suffix (`house`, `film-strip.fill`);
    /// `outlined` picks the stroke weight for `pt` like the Swift app (fill assets have one weight).
    pub fn node(&self, asset: &str, pt: f32, outlined: bool, tint: Color) -> Node {
        self.node_placed(asset, pt, outlined, tint, false)
    }

    /// As [`Icons::node`], placed on the symbol template's centre (see [`rasterize_template`]).
    pub fn node_template(&self, asset: &str, pt: f32, outlined: bool, tint: Color) -> Node {
        self.node_placed(asset, pt, outlined, tint, true)
    }

    fn node_placed(
        &self,
        asset: &str,
        pt: f32,
        outlined: bool,
        tint: Color,
        template: bool,
    ) -> Node {
        let name = if outlined {
            format!("{asset}{}", stroke_suffix(pt))
        } else {
            asset.to_owned()
        };
        // Fall back to the plain asset when a stroke variant does not exist.
        let name = if path_data(&name).is_some() {
            name
        } else {
            asset.to_owned()
        };
        let key = if template {
            format!("tpl:{name}")
        } else {
            name.clone()
        };
        let id = path_data(&name).and_then(|d| {
            self.image(&key, pt, |px| {
                if template {
                    rasterize_template(d, px)
                } else {
                    rasterize(d, px, true)
                }
            })
        });
        match id {
            Some(id) => {
                let mut n = Node::image(id, pt, pt, 0.0);
                for p in &mut n.paint {
                    if let Paint::Image { tint: t, .. } = p {
                        *t = tint;
                    }
                }
                n
            }
            None => {
                note_missing(asset);
                Node::fixed(pt, pt)
            }
        }
    }

    /// The raster of a wordmark `height` points high: pixel size of the artwork (whole device pixels) and the size in
    /// points that maps it one texel to one device pixel.
    fn wordmark_raster(&self, height: f32) -> ((u32, u32), (f32, f32)) {
        let s = self.scale.get();
        let width = height * WORDMARK_BOX[2] / WORDMARK_BOX[3];
        let px = (
            ((width * s).round() as u32).max(8),
            ((height * s).round() as u32).max(8),
        );
        (px, (px.0 as f32 / s, px.1 as f32 / s))
    }

    /// The wordmark `height` points high (width follows the artwork's box): the letters in `font`, the play mark in `accent`.
    pub fn wordmark(&self, height: f32, font: Color, accent: Color) -> Node {
        let (letters, mark) = self.wordmark_layers(height, font, accent);
        let (_, (w, h)) = self.wordmark_raster(height);
        Node::zstack(swiftly_layout::Alignment::TOP_LEADING, vec![letters, mark]).frame(
            Some(w),
            Some(h),
            swiftly_layout::Alignment::TOP_LEADING,
        )
    }

    /// The wordmark as two layers of the same size, `(letters, play mark)`, to animate apart (the launch curtain).
    /// Drawn one texel to one device pixel (the node is exactly the raster's size in points), never resampled.
    pub fn wordmark_layers(&self, height: f32, font: Color, accent: Color) -> (Node, Node) {
        let ((px_w, px_h), (width, height)) = self.wordmark_raster(height);
        let layer = |key: &str, d: &'static str, tint: Color| -> Node {
            let k = (key.to_owned(), px_h);
            let cached = self.cache.borrow().get(&k).copied();
            let id = match cached {
                Some(id) => id,
                None => {
                    let id = self.cx.add_image(
                        px_w,
                        px_h,
                        &rasterize_box(d, px_w as usize, px_h as usize, WORDMARK_BOX),
                    );
                    self.cache.borrow_mut().insert(k, id);
                    id
                }
            };
            match id {
                Some(id) => {
                    let mut n = Node::image(id, width, height, 0.0);
                    for p in &mut n.paint {
                        if let Paint::Image { tint: t, .. } = p {
                            *t = tint;
                        }
                    }
                    n
                }
                None => Node::fixed(width, height),
            }
        };
        (
            layer("wordmark.letters", WORDMARK_LETTERS, font),
            layer("wordmark.mark", WORDMARK_MARK, accent),
        )
    }

    /// Spoke `i` of the activity spinner, `pt` points square, in `tint`.
    pub fn spoke(&self, i: usize, pt: f32, tint: Color) -> Node {
        let d = spoke_path(i % SPOKES);
        let id = self.image(&format!("spoke{}", i % SPOKES), pt, |px| {
            rasterize(&d, px, false)
        });
        match id {
            Some(id) => {
                let mut n = Node::image(id, pt, pt, 0.0);
                for p in &mut n.paint {
                    if let Paint::Image { tint: t, .. } = p {
                        *t = tint;
                    }
                }
                n
            }
            None => Node::fixed(pt, pt),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stroke_follows_the_swift_rule() {
        assert_eq!(stroke_suffix(18.0), ".w28");
        assert_eq!(stroke_suffix(20.0), "");
        assert_eq!(stroke_suffix(52.0), ".light");
    }

    #[test]
    fn an_icon_has_ink_and_a_hole() {
        let d = path_data("house.fill").unwrap_or("");
        let img = rasterize(d, 64, true);
        let ink = img.chunks(4).filter(|p| p[3] > 128).count();
        assert!(ink > 600 && ink < 64 * 64 - 600, "ink {ink}");
        assert!(path_data("hard-drive-x.light").is_some());
    }

    #[test]
    fn a_template_placed_ring_keeps_its_ring_on_the_box_centre() {
        // arrow-clockwise: ring centre (1650, 1090), outer radius 43.75, the arrow head sticks out to the right.
        let d = path_data("arrow-clockwise").expect("asset");
        let px = 400_u32;
        let first_column = |img: &[u8]| {
            let row = (px / 2) as usize;
            (0..px as usize)
                .find(|x| img[(row * px as usize + x) * 4 + 3] > 128)
                .expect("ink on the centre row")
        };
        let placed = first_column(&rasterize_template(d, px));
        let by_box = first_column(&rasterize(d, px, true));
        // Left edge of the ring at 50 - 43.75 = 6.25 units = 25 px; the bounding box centre sits 6 units further right.
        assert!((placed as i32 - 25).abs() <= 3, "template placed: {placed}");
        assert!(
            by_box + 8 < placed,
            "bounding-box placed (old look): {by_box}"
        );
    }
}
