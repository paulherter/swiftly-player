// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The CPU reference renderer of a [`DrawList`]: the same per-pixel math as `quad.wgsl`, in `f32`, evaluated at pixel
//! centres. It is the oracle of the golden images and of [`crate::WgpuRenderer`]; change both together.
//!
//! The painter's-order idea and the float buffer come from the Sequence Studio `SoftwareRenderer`; the shapes are new.

use crate::atlas::{Atlas, AtlasFormat};
use crate::draw_list::{DrawList, DrawQuad, QuadKind};
use crate::geometry::Color;
use crate::image::RgbaImage;

/// The atlas pages a list refers to.
#[derive(Clone, Copy, Default)]
pub struct Sources<'a> {
    /// The R8 glyph page (glyph quads).
    pub glyphs: Option<&'a dyn Atlas>,
    /// The RGBA8 image page (image quads).
    pub images: Option<&'a dyn Atlas>,
}

/// Software rendering of a draw list.
pub struct SoftwareRenderer;

type Rgba = [f32; 4];

/// Number of scan-line steps of the shadow integral (mirrored by `SHADOW_STEPS` in the shader).
const SHADOW_STEPS: usize = 8;

fn erf_approx(x: f32) -> f32 {
    let s = if x > 0.0 {
        1.0
    } else if x < 0.0 {
        -1.0
    } else {
        0.0
    };
    let a = x.abs();
    let mut y = 1.0 + (0.278393 + (0.230389 + (0.000972 + 0.078108 * a) * a) * a) * a;
    y *= y;
    s - s / (y * y)
}

fn gaussian(x: f32, sigma: f32) -> f32 {
    (-(x * x) / (2.0 * sigma * sigma)).exp() / (2.506_628_3 * sigma)
}

fn radius_at(px: f32, py: f32, r: [f32; 4]) -> f32 {
    if px < 0.0 {
        if py < 0.0 { r[0] } else { r[3] }
    } else if py < 0.0 {
        r[1]
    } else {
        r[2]
    }
}

fn sd_round_box(px: f32, py: f32, hx: f32, hy: f32, r: f32) -> f32 {
    let (qx, qy) = (px.abs() - hx + r, py.abs() - hy + r);
    let (mx, my) = (qx.max(0.0), qy.max(0.0));
    (mx * mx + my * my).sqrt() + qx.max(qy).min(0.0) - r
}

fn blur_along_x(x: f32, y: f32, sigma: f32, corner: f32, hx: f32, hy: f32) -> f32 {
    let delta = (hy - corner - y.abs()).min(0.0);
    let curved = hx - corner + (corner * corner - delta * delta).max(0.0).sqrt();
    let k = std::f32::consts::FRAC_1_SQRT_2 / sigma;
    let lo = 0.5 + 0.5 * erf_approx((x - curved) * k);
    let hi = 0.5 + 0.5 * erf_approx((x + curved) * k);
    hi - lo
}

fn shadow_value(px: f32, py: f32, hx: f32, hy: f32, corner_in: f32, sigma_in: f32) -> f32 {
    let sigma = sigma_in.max(0.01);
    let corner = corner_in.min(hx.min(hy));
    let (low, high) = (py - hy, py + hy);
    let start = (-3.0 * sigma).clamp(low, high);
    let stop = (3.0 * sigma).clamp(low, high);
    let dstep = (stop - start) / SHADOW_STEPS as f32;
    let mut y = start + dstep * 0.5;
    let mut value = 0.0;
    for _ in 0..SHADOW_STEPS {
        value += blur_along_x(px, py - y, sigma, corner, hx, hy) * gaussian(y, sigma) * dstep;
        y += dstep;
    }
    value
}

/// Bilinear sample at normalised `(u, v)`; texel centres at `(i + 0.5) / size`, edges clamped. R8 pages give `(r, 0, 0, 1)`.
fn sample(page: &dyn Atlas, u: f32, v: f32) -> Rgba {
    let (w, h) = page.size();
    let (fx, fy) = (u * w as f32 - 0.5, v * h as f32 - 0.5);
    let (x0, y0) = (fx.floor(), fy.floor());
    let (ax, ay) = (fx - x0, fy - y0);
    let (x0, y0) = (x0 as i32, y0 as i32);
    let bpt = page.format().bytes_per_texel();
    let data = page.pixels();
    let texel = |x: i32, y: i32| -> Rgba {
        let cx = x.clamp(0, w as i32 - 1) as usize;
        let cy = y.clamp(0, h as i32 - 1) as usize;
        let i = (cy * w as usize + cx) * bpt;
        match page.format() {
            AtlasFormat::R8 => [data[i] as f32 / 255.0, 0.0, 0.0, 1.0],
            AtlasFormat::Rgba8 => [0, 1, 2, 3].map(|c| data[i + c] as f32 / 255.0),
        }
    };
    let (t00, t10, t01, t11) = (
        texel(x0, y0),
        texel(x0 + 1, y0),
        texel(x0, y0 + 1),
        texel(x0 + 1, y0 + 1),
    );
    let mut o = [0.0; 4];
    for (c, out) in o.iter_mut().enumerate() {
        let top = t00[c] * (1.0 - ax) + t10[c] * ax;
        let bottom = t01[c] * (1.0 - ax) + t11[c] * ax;
        *out = top * (1.0 - ay) + bottom * ay;
    }
    o
}

/// The point `(tx, ty)` (0..1 across the quad) of an image quad as a normalised page position, mirroring
/// `region_clamped` of the shader: the uv rectangle is snapped to whole texels (a sub-texel offset up to 0.4 only tells
/// handed-out rectangles apart) and the position stays on the texel centres inside it, so filtering never reaches the
/// neighbouring picture of the page.
fn region_uv(uv: [f32; 4], tx: f32, ty: f32, page_w: u32, page_h: u32) -> (f32, f32) {
    let dims = [page_w as f32, page_h as f32];
    let lo = [
        (uv[0] * dims[0] + 0.5).floor(),
        (uv[1] * dims[1] + 0.5).floor(),
    ];
    let hi = [
        (uv[2] * dims[0] + 0.5).floor(),
        (uv[3] * dims[1] + 0.5).floor(),
    ];
    let at = |i: usize, t: f32| {
        let first = lo[i] + 0.5;
        let last = first.max(hi[i] - 0.5);
        (lo[i] + (hi[i] - lo[i]) * t).clamp(first, last) / dims[i]
    };
    (at(0, tx), at(1, ty))
}

/// Interleaved gradient noise in [0, 1), the dither of `quad.wgsl`.
fn dither_noise(x: f32, y: f32) -> f32 {
    let inner = (x * 0.067_110_56 + y * 0.005_837_15).fract();
    (52.982_92 * inner).fract()
}

fn premul(c: [f32; 4]) -> Rgba {
    [c[0] * c[3], c[1] * c[3], c[2] * c[3], c[3]]
}

fn lerp4(a: Rgba, b: Rgba, t: f32) -> Rgba {
    [0, 1, 2, 3].map(|i| a[i] * (1.0 - t) + b[i] * t)
}

/// Coverage of the rounded clip of `q` at pixel centre `(x, y)`, the oracle of `round_clip_mask` in `quad.wgsl`.
fn round_clip_mask(q: &DrawQuad, x: f32, y: f32, s: f32) -> f32 {
    let r = q.round_clip[4];
    if r <= 0.0 {
        return 1.0;
    }
    let c = q.round_clip;
    let (lx, ly) = (c[0] * s, c[1] * s);
    let (hx, hy) = ((c[2] - c[0]) * s * 0.5, (c[3] - c[1]) * s * 0.5);
    (0.5 - sd_round_box(x - lx - hx, y - ly - hy, hx, hy, (r * s).min(hx.min(hy)))).clamp(0.0, 1.0)
}

/// Premultiplied colour of quad `q` at pixel centre `(x, y)`; `None` = untouched.
fn shade(q: &DrawQuad, x: f32, y: f32, s: f32, src: &Sources) -> Option<Rgba> {
    let mask = round_clip_mask(q, x, y, s);
    if mask <= 0.0 {
        return None;
    }
    let c = shade_unmasked(q, x, y, s, src)?;
    Some(if mask < 1.0 { c.map(|v| v * mask) } else { c })
}

fn shade_unmasked(q: &DrawQuad, x: f32, y: f32, s: f32, src: &Sources) -> Option<Rgba> {
    if x < q.clip[0] * s || x >= q.clip[2] * s || y < q.clip[1] * s || y >= q.clip[3] * s {
        return None;
    }
    let (ox, oy) = (q.rect.x * s, q.rect.y * s);
    let (w, h) = (q.rect.w * s, q.rect.h * s);
    let (hx, hy) = (w * 0.5, h * 0.5);
    let (rx, ry) = (x - ox - hx, y - oy - hy);
    let corner = (radius_at(rx, ry, q.radii.to_array()) * s).min(hx.min(hy));
    let c = q.color.to_array();

    match q.kind {
        QuadKind::Shadow => {
            let v = shadow_value(rx, ry, hx, hy, corner, q.blur * s);
            let a = c[3] * v * q.opacity;
            return Some([c[0] * a, c[1] * a, c[2] * a, a]);
        }
        QuadKind::Glyph => {
            if x < ox || y < oy || x >= ox + w || y >= oy + h {
                return None;
            }
            let page = src.glyphs?;
            let (u, v) = (
                q.uv[0] + (q.uv[2] - q.uv[0]) * ((x - ox) / w),
                q.uv[1] + (q.uv[3] - q.uv[1]) * ((y - oy) / h),
            );
            let a = c[3] * sample(page, u, v)[0] * q.opacity;
            return Some([c[0] * a, c[1] * a, c[2] * a, a]);
        }
        QuadKind::ColorGlyph => {
            if x < ox || y < oy || x >= ox + w || y >= oy + h {
                return None;
            }
            let page = src.glyphs?.color_page()?;
            let (u, v) = (
                q.uv[0] + (q.uv[2] - q.uv[0]) * ((x - ox) / w),
                q.uv[1] + (q.uv[3] - q.uv[1]) * ((y - oy) / h),
            );
            // The page holds premultiplied texels: the sample is already the premultiplied colour.
            let k = c[3] * q.opacity;
            let t = sample(page, u, v);
            return Some(t.map(|v| v * k));
        }
        _ => {}
    }

    let mut fill = premul(c);
    match q.kind {
        QuadKind::Gradient => {
            let (dx, dy) = (q.gradient[2] - q.gradient[0], q.gradient[3] - q.gradient[1]);
            let len2 = dx * dx + dy * dy;
            let t = if len2 > 0.0 {
                let (nx, ny) = ((x - ox) / w - q.gradient[0], (y - oy) / h - q.gradient[1]);
                ((nx * dx + ny * dy) / len2).clamp(0.0, 1.0)
            } else {
                0.0
            };
            fill = lerp4(premul(c), premul(q.color2.to_array()), t);
        }
        QuadKind::Radial => {
            let (nx, ny) = (
                ((x - ox) / w - q.gradient[0]) / q.gradient[2].max(0.0001),
                ((y - oy) / h - q.gradient[1]) / q.gradient[3].max(0.0001),
            );
            let t = (nx * nx + ny * ny).sqrt();
            if t < q.uv[0] || t >= q.uv[3] {
                return None;
            }
            let span = (q.uv[2] - q.uv[1]).max(0.00001);
            fill = lerp4(
                premul(c),
                premul(q.color2.to_array()),
                ((t - q.uv[1]) / span).clamp(0.0, 1.0),
            );
        }
        QuadKind::Image => {
            let page = src.images?;
            let (pw, ph) = page.size();
            let (u, v) = region_uv(q.uv, (x - ox) / w, (y - oy) / h, pw, ph);
            let t = sample(page, u, v);
            fill = premul([t[0] * c[0], t[1] * c[1], t[2] * c[2], t[3] * c[3]]);
        }
        QuadKind::BackdropBlur => {}
        _ => {}
    }

    let cov_outer = (0.5 - sd_round_box(rx, ry, hx, hy, corner)).clamp(0.0, 1.0);
    let mut result = fill.map(|v| v * cov_outer);
    let bw = q.border_width * s;
    if bw > 0.0 {
        let mut cov_inner = 0.0;
        let (ix, iy) = (hx - bw, hy - bw);
        if ix > 0.0 && iy > 0.0 {
            cov_inner =
                (0.5 - sd_round_box(rx, ry, ix, iy, (corner - bw).max(0.0))).clamp(0.0, 1.0);
        }
        let ring_cov = (cov_outer - cov_inner).max(0.0);
        let ring = premul(q.border_color.to_array()).map(|v| v * ring_cov);
        result = [0, 1, 2, 3].map(|i| ring[i] + result[i] * (1.0 - ring[3]));
    }
    let mut result = result.map(|v| v * q.opacity);
    if q.kind == QuadKind::Gradient || q.kind == QuadKind::Radial || q.dither {
        let n = dither_noise(x, y) - 0.5;
        let w = (result[3].min(1.0 - result[3]) * 255.0).clamp(0.0, 1.0);
        let a = result[3];
        result = [
            result[0] + n * a / 255.0,
            result[1] + n * a / 255.0,
            result[2] + n * a / 255.0,
            a + n * w / 255.0,
        ];
    }
    Some(result)
}

impl SoftwareRenderer {
    /// Draws `list` onto an opaque image of the list's pixel size, cleared to `clear`.
    pub fn render(list: &DrawList, clear: Color, src: &Sources) -> RgbaImage {
        let (wpx, hpx) = list.pixel_size();
        let (width, height) = (wpx as usize, hpx as usize);
        let mut buf: Vec<f32> = (0..width * height)
            .flat_map(|_| [clear.r, clear.g, clear.b])
            .collect();
        let s = list.scale();
        for q in list.quads() {
            if q.kind == QuadKind::BackdropBlur {
                blur_backdrop(q, &mut buf, width, height, s);
            }
            draw_quad(q, &mut buf, width, height, s, src);
        }
        let mut pixels = vec![255u8; width * height * 4];
        for i in 0..width * height {
            for k in 0..3 {
                pixels[i * 4 + k] = (buf[i * 3 + k].clamp(0.0, 1.0) * 255.0 + 0.5) as u8;
            }
        }
        RgbaImage {
            width,
            height,
            pixels,
        }
    }
}

/// One box-blur pass over `w x h` RGB texels of `data` along x (`horizontal`) or y, half-width `b`, edges clamped.
fn box_pass(data: &mut [f32], w: usize, h: usize, b: usize, horizontal: bool) {
    let (lines, len, step, stride) = if horizontal {
        (h, w, 3, w * 3)
    } else {
        (w, h, w * 3, 3)
    };
    let mut line = vec![0.0_f32; len];
    for l in 0..lines {
        for k in 0..3 {
            let base = l * stride + k;
            for (i, v) in line.iter_mut().enumerate() {
                *v = data[base + i * step];
            }
            let at = |i: isize| line[i.clamp(0, len as isize - 1) as usize];
            let n = (2 * b + 1) as f32;
            let mut acc: f32 = (-(b as isize)..=b as isize).map(at).sum();
            for i in 0..len {
                data[base + i * step] = acc / n;
                acc += at(i as isize + b as isize + 1) - at(i as isize - b as isize);
            }
        }
    }
}

/// Frosted glass: replaces the pixels under a `BackdropBlur` quad by a blurred copy (three box passes approximate the
/// gaussian of sigma `blur / 2`), weighted by the quad's rounded-corner coverage. The tint is drawn afterwards.
fn blur_backdrop(q: &DrawQuad, buf: &mut [f32], width: usize, height: usize, s: f32) {
    let sigma = (q.blur * s * 0.5).max(0.0);
    let b = (sigma * 0.9).round() as usize;
    let r = &q.rect;
    let x0 = (r.x * s).max(q.clip[0] * s).floor().max(0.0) as usize;
    let y0 = (r.y * s).max(q.clip[1] * s).floor().max(0.0) as usize;
    let x1 = (r.max_x() * s)
        .min(q.clip[2] * s)
        .ceil()
        .min(width as f32)
        .max(0.0) as usize;
    let y1 = (r.max_y() * s)
        .min(q.clip[3] * s)
        .ceil()
        .min(height as f32)
        .max(0.0) as usize;
    if b == 0 || x1 <= x0 || y1 <= y0 {
        return;
    }
    let (w, h) = (x1 - x0, y1 - y0);
    let mut region = vec![0.0_f32; w * h * 3];
    for y in 0..h {
        let src = ((y0 + y) * width + x0) * 3;
        region[y * w * 3..(y + 1) * w * 3].copy_from_slice(&buf[src..src + w * 3]);
    }
    for _ in 0..3 {
        box_pass(&mut region, w, h, b, true);
        box_pass(&mut region, w, h, b, false);
    }
    let (ox, oy) = (r.x * s, r.y * s);
    let (hx, hy) = (r.w * s * 0.5, r.h * s * 0.5);
    for y in 0..h {
        for x in 0..w {
            let (rx, ry) = (
                (x0 + x) as f32 + 0.5 - ox - hx,
                (y0 + y) as f32 + 0.5 - oy - hy,
            );
            let corner = (radius_at(rx, ry, q.radii.to_array()) * s).min(hx.min(hy));
            let cov = (0.5 - sd_round_box(rx, ry, hx, hy, corner)).clamp(0.0, 1.0)
                * round_clip_mask(q, (x0 + x) as f32 + 0.5, (y0 + y) as f32 + 0.5, s);
            let i = ((y0 + y) * width + x0 + x) * 3;
            for k in 0..3 {
                buf[i + k] = buf[i + k] * (1.0 - cov) + region[(y * w + x) * 3 + k] * cov;
            }
        }
    }
}

fn draw_quad(q: &DrawQuad, buf: &mut [f32], width: usize, height: usize, s: f32, src: &Sources) {
    let mut pad = 1.0;
    if q.kind == QuadKind::Shadow {
        pad += 3.0 * q.blur * s;
    }
    let r = &q.rect;
    let lo = [
        (r.x * s - pad).max(q.clip[0] * s),
        (r.y * s - pad).max(q.clip[1] * s),
    ];
    let hi = [
        (r.max_x() * s + pad).min(q.clip[2] * s),
        (r.max_y() * s + pad).min(q.clip[3] * s),
    ];
    if hi[0] <= lo[0] || hi[1] <= lo[1] {
        return;
    }
    let x0 = lo[0].floor().max(0.0) as usize;
    let y0 = lo[1].floor().max(0.0) as usize;
    let x1 = (hi[0].ceil().min(width as f32)).max(0.0) as usize;
    let y1 = (hi[1].ceil().min(height as f32)).max(0.0) as usize;
    for y in y0..y1 {
        let py = y as f32 + 0.5;
        if py < lo[1] || py >= hi[1] {
            continue;
        }
        for x in x0..x1 {
            let px = x as f32 + 0.5;
            if px < lo[0] || px >= hi[0] {
                continue;
            }
            let Some(c) = shade(q, px, py, s, src) else {
                continue;
            };
            let a = c[3];
            if a <= 0.0 {
                continue;
            }
            let i = (y * width + x) * 3;
            for k in 0..3 {
                buf[i + k] = c[k] + buf[i + k] * (1.0 - a);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::atlas::PixelPage;
    use crate::draw_list::{Border, ShadowStyle};
    use crate::geometry::{Corners, LinearGradient, Rect};

    fn render(l: &DrawList, clear: Color) -> RgbaImage {
        SoftwareRenderer::render(l, clear, &Sources::default())
    }

    #[test]
    fn round_clip_cuts_the_children_to_one_rounded_card() {
        // Two cells side by side, clipped together as one card with radius 10: the card's corners are cut, the seam
        // between the cells is not rounded, the middle is fully drawn.
        let mut l = DrawList::new(40.0, 40.0, 1.0);
        l.push_round_clip(Rect::new(0.0, 0.0, 40.0, 40.0), 10.0);
        l.fill(Rect::new(0.0, 0.0, 19.0, 40.0), Color::WHITE, 0.0);
        l.fill(Rect::new(21.0, 0.0, 19.0, 40.0), Color::WHITE, 0.0);
        l.pop_clip();
        l.fill(
            Rect::new(0.0, 0.0, 2.0, 2.0),
            Color::new(1.0, 0.0, 0.0, 1.0),
            0.0,
        );
        let img = render(&l, Color::BLACK);
        assert_eq!(
            img.pixel(0, 0)[0],
            255,
            "after the pop the red corner square is drawn"
        );
        assert_eq!(img.pixel(1, 20)[0], 255, "left edge, straight part");
        assert_eq!(img.pixel(20, 20)[0], 0, "the gap between the cells");
        assert_eq!(img.pixel(1, 38)[1], 0, "bottom-left corner is cut away");
        assert_eq!(img.pixel(38, 1)[1], 0, "top-right corner is cut away");
        let edge = img.pixel(2, 3)[1];
        assert!(edge > 0 && edge < 255, "the arc is anti-aliased: {edge}");
        assert_eq!(img.pixel(10, 10)[1], 255);
    }

    #[test]
    fn radial_gradient_fades_from_the_centre_and_has_no_seam_between_bands() {
        let mut l = DrawList::new(100.0, 50.0, 1.0);
        let w = |a: f32| Color::new(1.0, 1.0, 1.0, a);
        l.radial_stops(
            Rect::new(0.0, 0.0, 100.0, 50.0),
            [50.0, 0.0],
            [50.0, 40.0],
            &[(0.0, w(1.0)), (0.5, w(0.5)), (1.0, w(0.0))],
        );
        let img = render(&l, Color::BLACK);
        let v = |x, y| img.pixel(x, y)[0] as i32;
        assert!(v(50, 0) > 240, "the centre is full: {}", v(50, 0));
        let (a, b, c) = (v(50, 10), v(50, 20), v(50, 30));
        assert!(a > b && b > c, "it falls off monotonically {a} {b} {c}");
        assert!((b - 128).abs() < 8, "half way at the middle stop: {b}");
        assert!(
            v(50, 45) < 4 && v(2, 45) < 4,
            "beyond the last stop nothing"
        );
        // The ellipse is wider than tall: 30 px to the side is further in than 30 px down.
        assert!(v(80, 0) > v(50, 30), "elliptical, not round");
        for y in 10..30 {
            assert!(
                v(50, y) >= v(50, y + 1) - 2,
                "no step at the band seam, row {y}"
            );
        }
    }

    #[test]
    fn backdrop_blur_softens_an_edge() {
        let mut l = DrawList::new(40.0, 10.0, 1.0);
        l.fill(Rect::new(0.0, 0.0, 20.0, 10.0), Color::WHITE, 0.0);
        l.backdrop_blur(
            Rect::new(0.0, 0.0, 40.0, 10.0),
            8.0,
            Color::new(0.0, 0.0, 0.0, 0.0),
            0.0,
        );
        let img = render(&l, Color::BLACK);
        let (a, b, c) = (img.pixel(2, 5)[0], img.pixel(19, 5)[0], img.pixel(38, 5)[0]);
        assert!(a > 200 && c < 60, "far from the edge stays {a} / {c}");
        assert!(b > 60 && b < 200, "the edge is soft: {b}");
    }

    #[test]
    fn integer_rects_fill_exactly() {
        let mut l = DrawList::new(4.0, 4.0, 1.0);
        l.fill(
            Rect::new(1.0, 1.0, 2.0, 2.0),
            Color::rgb(1.0, 0.0, 0.0),
            0.0,
        );
        let img = render(&l, Color::BLACK);
        assert_eq!(img.pixel(1, 1), [255, 0, 0, 255]);
        assert_eq!(img.pixel(2, 2), [255, 0, 0, 255]);
        assert_eq!(img.pixel(0, 0), [0, 0, 0, 255]);
        assert_eq!(img.pixel(3, 1), [0, 0, 0, 255]);
    }

    #[test]
    fn scale_doubles_the_pixels() {
        let mut l = DrawList::new(2.0, 2.0, 2.0);
        l.fill(Rect::new(1.0, 0.0, 1.0, 2.0), Color::WHITE, 0.0);
        let img = render(&l, Color::BLACK);
        assert_eq!((img.width, img.height), (4, 4));
        assert_eq!(
            (img.pixel(1, 1)[0], img.pixel(2, 1)[0], img.pixel(3, 3)[0]),
            (0, 255, 255)
        );
    }

    #[test]
    fn per_corner_radii_and_borders() {
        let mut l = DrawList::new(20.0, 20.0, 1.0);
        let r = Rect::new(0.0, 0.0, 20.0, 20.0);
        l.rect(
            r,
            Color::WHITE,
            Some(Border {
                color: Color::rgb(1.0, 0.0, 0.0),
                width: 2.0,
            }),
            Corners::new(10.0, 0.0, 0.0, 0.0),
        );
        let img = render(&l, Color::BLACK);
        assert_eq!(img.pixel(0, 0)[0], 0, "rounded top left corner is cut");
        assert_eq!(
            img.pixel(19, 19),
            [255, 0, 0, 255],
            "square corner shows the border"
        );
        assert_eq!(
            img.pixel(10, 10),
            [255, 255, 255, 255],
            "fill inside the border"
        );
    }

    #[test]
    fn pill_clamps_the_radius() {
        let mut l = DrawList::new(40.0, 10.0, 1.0);
        l.fill(Rect::new(0.0, 0.0, 40.0, 10.0), Color::WHITE, 999.0);
        let img = render(&l, Color::BLACK);
        assert_eq!(img.pixel(0, 0)[0], 0);
        assert_eq!(img.pixel(20, 5)[0], 255);
        assert!(
            img.pixel(0, 5)[0] > 100,
            "the left end is round, the middle of the end still covered"
        );
    }

    #[test]
    fn clip_rect_limits_drawing() {
        let mut l = DrawList::new(8.0, 2.0, 1.0);
        l.push_clip(Rect::new(0.0, 0.0, 3.0, 2.0));
        l.fill(Rect::new(0.0, 0.0, 8.0, 2.0), Color::WHITE, 0.0);
        l.pop_clip();
        let img = render(&l, Color::BLACK);
        assert_eq!((img.pixel(2, 0)[0], img.pixel(3, 0)[0]), (255, 0));
    }

    #[test]
    fn gradient_runs_between_its_colours() {
        let mut l = DrawList::new(100.0, 4.0, 1.0);
        l.fill(
            Rect::new(0.0, 0.0, 100.0, 4.0),
            LinearGradient::horizontal(Color::BLACK, Color::WHITE),
            0.0,
        );
        let img = render(&l, Color::rgb(1.0, 0.0, 0.0));
        let (a, b, c) = (img.pixel(0, 1)[0], img.pixel(50, 1)[0], img.pixel(99, 1)[0]);
        assert!(
            a < 5 && (b as i32 - 128).abs() < 4 && c > 250,
            "{a} {b} {c}"
        );
    }

    #[test]
    fn shadow_is_soft_and_centred_under_the_card() {
        let mut l = DrawList::new(120.0, 120.0, 1.0);
        let card = Rect::new(30.0, 30.0, 60.0, 60.0);
        let s = ShadowStyle {
            color: Color::BLACK,
            dx: 0.0,
            dy: 0.0,
            blur: 20.0,
            spread: 0.0,
        };
        l.shadow(card, s, 8.0);
        let img = render(&l, Color::WHITE);
        let at = |x: usize, y: usize| img.pixel(x, y)[0];
        assert!(at(60, 60) < 20, "dark under the middle");
        assert!(
            at(30, 60) > 100 && at(30, 60) < 160,
            "half strength on the edge, got {}",
            at(30, 60)
        );
        assert!(at(5, 60) > 235, "light far outside");
        assert!(
            at(60, 5).abs_diff(at(5, 60)) <= 2,
            "symmetric within the integration error"
        );
    }

    #[test]
    fn images_and_glyphs_sample_their_pages() {
        let mut images = PixelPage::new(2, 2, AtlasFormat::Rgba8);
        images.put(0, 0, 2, 2, &[255, 255, 0, 255].repeat(4));
        let mut glyphs = PixelPage::new(2, 2, AtlasFormat::R8);
        glyphs.put(0, 0, 2, 2, &[255, 0, 255, 0]);
        let mut l = DrawList::new(8.0, 4.0, 1.0);
        l.image(
            Rect::new(0.0, 0.0, 4.0, 4.0),
            [0.0, 0.0, 1.0, 1.0],
            Color::rgb(1.0, 0.5, 1.0),
            0.0,
        );
        l.glyph(
            Rect::new(4.0, 0.0, 2.0, 2.0),
            [0.0, 0.0, 1.0, 1.0],
            Color::WHITE,
        );
        let src = Sources {
            glyphs: Some(&glyphs),
            images: Some(&images),
        };
        let out = SoftwareRenderer::render(&l, Color::BLACK, &src);
        assert_eq!(out.pixel(1, 1), [255, 128, 0, 255]);
        assert_eq!(out.pixel(4, 0)[0], 255);
        assert_eq!(out.pixel(5, 0)[0], 0);
    }

    /// A glyph page that carries a colour page, as the text atlas does.
    struct WithColor {
        coverage: PixelPage,
        color: PixelPage,
    }

    impl Atlas for WithColor {
        fn size(&self) -> (u32, u32) {
            self.coverage.size()
        }
        fn format(&self) -> AtlasFormat {
            self.coverage.format()
        }
        fn pixels(&self) -> &[u8] {
            self.coverage.pixels()
        }
        fn take_dirty(&self) -> Option<crate::atlas::DirtyRect> {
            self.coverage.take_dirty()
        }
        fn color_page(&self) -> Option<&dyn Atlas> {
            Some(&self.color)
        }
    }

    #[test]
    fn color_glyphs_keep_their_colours_and_ignore_the_text_tint() {
        let mut color = PixelPage::new(2, 2, AtlasFormat::Rgba8);
        // Premultiplied: opaque red, half-transparent green (0, 128 * 0.5, 0, 128), and two empty texels.
        color.put(
            0,
            0,
            2,
            2,
            &[255, 0, 0, 255, 0, 64, 0, 128, 0, 0, 0, 0, 0, 0, 0, 0],
        );
        let page = WithColor {
            coverage: PixelPage::new(2, 2, AtlasFormat::R8),
            color,
        };
        let mut l = DrawList::new(8.0, 4.0, 1.0);
        // A blue text colour must not tint the emoji; its alpha does apply.
        l.color_glyph(
            Rect::new(0.0, 0.0, 2.0, 2.0),
            [0.0, 0.0, 1.0, 1.0],
            Color::new(0.0, 0.0, 1.0, 1.0),
        );
        l.color_glyph(
            Rect::new(4.0, 0.0, 2.0, 2.0),
            [0.0, 0.0, 1.0, 1.0],
            Color::new(0.0, 0.0, 1.0, 0.5),
        );
        let src = Sources {
            glyphs: Some(&page),
            images: None,
        };
        let out = SoftwareRenderer::render(&l, Color::BLACK, &src);
        // Bilinear sampling at the 2x2 quad's pixel centres blends the four texels; the corner pixels are exact enough
        // to tell untinted red from blue.
        let p = out.pixel(0, 0);
        assert!(p[0] > 100 && p[2] == 0, "red stays red, got {p:?}");
        let faded = out.pixel(4, 0);
        assert!(
            faded[0] > 30 && faded[0] < p[0] && faded[2] == 0,
            "half alpha halves it, got {faded:?}"
        );
        // Without a colour page nothing is drawn.
        let bare = Sources {
            glyphs: Some(&PixelPage::new(2, 2, AtlasFormat::R8)),
            images: None,
        };
        let none = SoftwareRenderer::render(&l, Color::BLACK, &bare);
        assert_eq!(none.pixel(0, 0), [0, 0, 0, 255]);
    }

    #[test]
    fn group_opacity_fades_each_quad() {
        let mut l = DrawList::new(2.0, 1.0, 1.0);
        l.push_opacity(0.5);
        l.fill(Rect::new(0.0, 0.0, 1.0, 1.0), Color::WHITE, 0.0);
        l.pop_opacity();
        let img = render(&l, Color::BLACK);
        assert_eq!(img.pixel(0, 0)[0], 128);
    }
}
