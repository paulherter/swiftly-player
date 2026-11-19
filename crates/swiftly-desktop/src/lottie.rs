//! A small Lottie player for the shapes of one file: the Mac's launch animation (`Sources/Shared/Assets/startanimation.json`,
//! 1024 x 1024, 60 fps, 80 frames). It reads shape layers with a static group (bezier path + flat fill + group
//! transform) and an animated layer transform (position, scale with cubic-bezier easing; opacity and rotation are read as
//! static values). Each layer's shape is rasterised into white coverage images (the free scanline rasteriser of
//! `swiftly-ui`) and drawn tinted, moved and scaled every frame. A shape that grows (the play mark of the launch
//! animation swells to 782 %) must never be drawn larger than its picture, or its edge turns soft: every layer gets a
//! small chain of pictures, from the largest scale the animation draws it at down to the smallest in steps of
//! 1/sqrt(2), and each frame takes the smallest picture that is still at least as large as the drawn size. The chain
//! is made for the pixels per composition unit of the surface and made again when that changes (the window's scale
//! is announced after the first frame on Wayland). Anything else in a file is ignored, so this is not a general Lottie
//! renderer.

use std::cell::RefCell;

use serde_json::Value;
use swiftly_layout::Alignment;
use swiftly_render::Color;
use swiftly_ui::{Cx, ImageId, Node, Paint};

/// The Mac's launch animation.
pub const START_ANIMATION: &str =
    include_str!("../../../Sources/Shared/Assets/startanimation.json");

#[derive(Clone, Debug)]
struct Key {
    t: f64,
    s: Vec<f64>,
    /// Out and in handles of the segment that starts here: `(o.x, o.y, i.x, i.y)` per component.
    ease: Option<[Vec<f64>; 4]>,
}

#[derive(Clone, Debug)]
enum Prop {
    Fixed(Vec<f64>),
    Anim(Vec<Key>),
}

fn nums(v: &Value) -> Vec<f64> {
    match v {
        Value::Array(a) => a.iter().filter_map(Value::as_f64).collect(),
        other => other.as_f64().into_iter().collect(),
    }
}

fn prop(v: &Value) -> Prop {
    let animated = v.get("a").and_then(Value::as_i64) == Some(1);
    let k = &v["k"];
    if !animated {
        return Prop::Fixed(nums(k));
    }
    let keys =
        k.as_array()
            .map(|a| {
                a.iter()
                    .map(|kf| Key {
                        t: kf["t"].as_f64().unwrap_or(0.0),
                        s: nums(&kf["s"]),
                        ease: kf.get("o").zip(kf.get("i")).map(|(o, i)| {
                            [nums(&o["x"]), nums(&o["y"]), nums(&i["x"]), nums(&i["y"])]
                        }),
                    })
                    .collect()
            })
            .unwrap_or_default();
    Prop::Anim(keys)
}

/// `cubic-bezier(x1, y1, x2, y2)` easing: the output for progress `u` in 0..1.
fn bezier(u: f64, x1: f64, y1: f64, x2: f64, y2: f64) -> f64 {
    if u <= 0.0 {
        return 0.0;
    }
    if u >= 1.0 {
        return 1.0;
    }
    let at = |a: f64, b: f64, t: f64| {
        3.0 * a * (1.0 - t).powi(2) * t + 3.0 * b * (1.0 - t) * t * t + t.powi(3)
    };
    let (mut lo, mut hi) = (0.0_f64, 1.0_f64);
    for _ in 0..40 {
        let mid = 0.5 * (lo + hi);
        if at(x1, x2, mid) < u {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    at(y1, y2, 0.5 * (lo + hi))
}

impl Prop {
    fn at(&self, frame: f64) -> Vec<f64> {
        match self {
            Prop::Fixed(v) => v.clone(),
            Prop::Anim(keys) => {
                let Some(first) = keys.first() else {
                    return Vec::new();
                };
                if frame <= first.t {
                    return first.s.clone();
                }
                for w in keys.windows(2) {
                    let (a, b) = (&w[0], &w[1]);
                    if frame < b.t {
                        let u = (frame - a.t) / (b.t - a.t).max(1e-9);
                        return a
                            .s
                            .iter()
                            .zip(&b.s)
                            .enumerate()
                            .map(|(c, (from, to))| {
                                let e = match &a.ease {
                                    Some([ox, oy, ix, iy]) => {
                                        let pick = |v: &Vec<f64>| {
                                            v.get(c).or_else(|| v.first()).copied().unwrap_or(0.0)
                                        };
                                        bezier(u, pick(ox), pick(oy), pick(ix), pick(iy))
                                    }
                                    None => u,
                                };
                                from + (to - from) * e
                            })
                            .collect();
                    }
                }
                keys.last().map(|k| k.s.clone()).unwrap_or_default()
            }
        }
    }
}

/// The step between two pictures of a layer's chain.
const LEVEL_STEP: f64 = std::f64::consts::SQRT_2;
/// Largest picture side in pixels (the image page's limit for one picture, minus the margin).
const MAX_SIDE: f64 = 2040.0;
/// The most pictures one layer gets.
const MAX_LEVELS: usize = 24;
/// A shape drawn smaller than this many pixels is a speck: the smallest picture of its chain serves it.
const SPECK_PX: f64 = 2.0;
/// Margin of transparent pixels around a picture's shape (the antialiased edge and the atlas neighbours stay clear).
const MARGIN: u32 = 4;

/// One picture of a layer: the shape rasterised at `scale` (a layer scale of 1.0 is 100 %).
#[derive(Clone, Copy, Debug)]
struct Level {
    scale: f64,
    id: ImageId,
    /// The picture's box in layer space: `(x, y, w, h)`.
    bbox: (f64, f64, f64, f64),
    /// The picture's size in pixels.
    px: (u32, u32),
}

struct Layer {
    ip: f64,
    op: f64,
    pos: Prop,
    scale: Prop,
    anchor: (f64, f64),
    opacity: f64,
    tint: Color,
    /// The shape as SVG path data with its box in layer space `(x, y, w, h)`.
    shape: Option<(String, (f64, f64, f64, f64))>,
    /// The smallest and the largest scale (the larger of x and y, 1.0 = 100 %) the layer is drawn at; `None` when it never
    /// is.
    scales: Option<(f64, f64)>,
}

/// The pictures of every layer for one pixel density.
struct Raster {
    /// Pixels per composition unit at 100 %.
    ppu: f64,
    /// Per layer, from the largest scale to the smallest.
    levels: Vec<Vec<Level>>,
}

/// The parsed animation with its layers rasterised.
pub struct Lottie {
    layers: Vec<Layer>,
    size: f64,
    /// The last frame (`op`).
    pub frames: f64,
    /// Frames per second.
    pub fps: f64,
    /// The pictures per pixel density (a window that moves between monitors keeps both), the newest last.
    rasters: RefCell<Vec<Raster>>,
}

/// What one layer's pictures give against what the animation draws, in device pixels (see [`Lottie::audit`]).
#[derive(Clone, Debug, PartialEq)]
pub struct LayerAudit {
    /// The largest size the animation draws the layer at (width, height).
    pub max_drawn_px: (f64, f64),
    /// The size of the layer's largest picture.
    pub largest_picture_px: (u32, u32),
    /// How often the pictures are used: the worst enlargement over all frames (drawn size over picture size, above 1.0
    /// the picture is stretched and soft).
    pub worst_enlargement: f64,
    /// The worst reduction over all frames in which the layer is more than a speck (picture size over drawn size;
    /// bilinear filtering is clean below 2).
    pub worst_reduction: f64,
    /// Number of pictures.
    pub levels: usize,
    /// Pixels of all the pictures together.
    pub total_px: u64,
}

/// SVG path data of a Lottie bezier shape with the group transform `(p, a, s)` applied, and its box.
fn shape_path(
    shape: &Value,
    p: (f64, f64),
    a: (f64, f64),
    s: (f64, f64),
) -> Option<(String, (f64, f64, f64, f64))> {
    let k = shape.get("ks")?.get("k")?;
    let pts = |name: &str| -> Option<Vec<(f64, f64)>> {
        Some(
            k.get(name)?
                .as_array()?
                .iter()
                .map(|v| {
                    let n = nums(v);
                    (n[0], n[1])
                })
                .collect(),
        )
    };
    let (v, i, o) = (pts("v")?, pts("i")?, pts("o")?);
    let closed = k.get("c").and_then(Value::as_bool).unwrap_or(true);
    let tf = |q: (f64, f64)| {
        (
            (q.0 - a.0) * s.0 / 100.0 + p.0,
            (q.1 - a.1) * s.1 / 100.0 + p.1,
        )
    };
    let n = v.len();
    if n < 2 {
        return None;
    }
    let (mut x0, mut y0, mut x1, mut y1) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
    let mut grow = |q: (f64, f64)| {
        x0 = x0.min(q.0);
        y0 = y0.min(q.1);
        x1 = x1.max(q.0);
        y1 = y1.max(q.1);
    };
    let mut d = String::new();
    let start = tf(v[0]);
    d.push_str(&format!("M {:.3} {:.3}", start.0, start.1));
    grow(start);
    let segs = if closed { n } else { n - 1 };
    for idx in 0..segs {
        let j = (idx + 1) % n;
        let c1 = tf((v[idx].0 + o[idx].0, v[idx].1 + o[idx].1));
        let c2 = tf((v[j].0 + i[j].0, v[j].1 + i[j].1));
        let end = tf(v[j]);
        d.push_str(&format!(
            " C {:.3} {:.3} {:.3} {:.3} {:.3} {:.3}",
            c1.0, c1.1, c2.0, c2.1, end.0, end.1
        ));
        let p0 = tf(v[idx]);
        for step in 1..=12 {
            let t = f64::from(step) / 12.0;
            let m = 1.0 - t;
            let px = m.powi(3) * p0.0
                + 3.0 * m * m * t * c1.0
                + 3.0 * m * t * t * c2.0
                + t.powi(3) * end.0;
            let py = m.powi(3) * p0.1
                + 3.0 * m * m * t * c1.1
                + 3.0 * m * t * t * c2.1
                + t.powi(3) * end.1;
            grow((px, py));
        }
    }
    if closed {
        d.push_str(" Z");
    }
    Some((d, (x0, y0, x1 - x0, y1 - y0)))
}

/// The scales of a layer's chain, largest first: steps of [`LEVEL_STEP`] around `rest` (the scale the layer is held at,
/// which gets a picture of exactly its size and so is drawn texel for texel), from the first scale that is at least `max`
/// down to the first that is at least `min` (or that makes the shape [`SPECK_PX`] large). `side` is the shape's larger side in pixels at 100 %.
fn chain(min: f64, max: f64, rest: f64, side: f64) -> Vec<f64> {
    let step = LEVEL_STEP.ln();
    let min = min.max(SPECK_PX / side.max(1e-6)).min(max);
    let at = |n: i32| rest * LEVEL_STEP.powi(n);
    let top = ((max / rest).ln() / step - 1e-9).ceil() as i32;
    let bottom = ((min / rest).ln() / step - 1e-9).ceil() as i32;
    let mut out: Vec<f64> = (bottom..=top.max(bottom))
        .rev()
        .map(at)
        .filter(|s| s * side + f64::from(MARGIN) <= MAX_SIDE)
        .collect();
    if out.is_empty() {
        // A shape so large that even the smallest picture would not fit the page: one picture at the largest size.
        out.push(((MAX_SIDE - f64::from(MARGIN)) / side.max(1.0)).min(min.max(1e-3)));
    }
    out.truncate(MAX_LEVELS);
    out
}

impl Layer {
    /// The layer's position and its scale `(sx, sy)` (1.0 = 100 %) at `frame`; `None` while it is not drawn.
    fn pose(&self, frame: f64) -> Option<((f64, f64), (f64, f64))> {
        if frame < self.ip || frame >= self.op {
            return None;
        }
        let (p, s) = (self.pos.at(frame), self.scale.at(frame));
        if p.len() < 2 || s.len() < 2 {
            return None;
        }
        let (sx, sy) = (s[0] / 100.0, s[1] / 100.0);
        if sx.abs() < 1e-4 || sy.abs() < 1e-4 {
            return None;
        }
        Some(((p[0], p[1]), (sx, sy)))
    }

    /// The smallest and the largest scale the layer is drawn at over the animation, and the scale it ends at.
    fn scale_range(&self, frames: f64) -> Option<(f64, f64, f64)> {
        let (mut lo, mut hi, mut last) = (f64::MAX, 0.0_f64, None);
        let mut f = self.ip.max(0.0);
        let end = self.op.min(frames);
        while f < end {
            if let Some((_, (sx, sy))) = self.pose(f) {
                let s = sx.abs().max(sy.abs());
                lo = lo.min(s);
                hi = hi.max(s);
                last = Some(s);
            }
            f += FRAME_STEP;
        }
        last.map(|l| (lo, hi, l))
    }
}

/// The picture of `levels` (largest scale first) for a layer drawn at `scale`: the smallest one that is not smaller.
fn pick(levels: &[Level], scale: f64) -> Option<&Level> {
    levels
        .iter()
        .rev()
        .find(|l| l.scale >= scale - 1e-9)
        .or_else(|| levels.first())
}

/// Frames between two samples when the animation is scanned for the scales it draws.
const FRAME_STEP: f64 = 0.05;

impl Lottie {
    /// Parses `json` and rasterises every layer's shape for `px_per_unit` pixels per composition unit at 100 %.
    pub fn load(cx: &Cx, json: &str, px_per_unit: f32) -> Option<Lottie> {
        let doc: Value = serde_json::from_str(json).ok()?;
        let size = doc.get("w")?.as_f64()?;
        let frames = doc.get("op")?.as_f64()?;
        let mut layers = Vec::new();
        for l in doc.get("layers")?.as_array()? {
            if l.get("ty").and_then(Value::as_i64) != Some(4) {
                continue;
            }
            let ks = l.get("ks")?;
            let anchor = prop(ks.get("a")?).at(0.0);
            let mut shape = None;
            let mut tint = Color::WHITE;
            for g in l.get("shapes")?.as_array()? {
                if g.get("ty").and_then(Value::as_str) != Some("gr") {
                    continue;
                }
                let items = g.get("it")?.as_array()?;
                let tr = items.iter().find(|i| i["ty"] == "tr");
                let at = |name: &str, default: (f64, f64)| -> (f64, f64) {
                    tr.and_then(|t| t.get(name))
                        .map(|v| prop(v).at(0.0))
                        .filter(|v| v.len() >= 2)
                        .map_or(default, |v| (v[0], v[1]))
                };
                let (gp, ga, gs) = (
                    at("p", (0.0, 0.0)),
                    at("a", (0.0, 0.0)),
                    at("s", (100.0, 100.0)),
                );
                if let Some(fl) = items.iter().find(|i| i["ty"] == "fl") {
                    let c = prop(&fl["c"]).at(0.0);
                    if c.len() >= 3 {
                        tint = Color::new(c[0] as f32, c[1] as f32, c[2] as f32, 1.0);
                    }
                }
                if let Some(sh) = items.iter().find(|i| i["ty"] == "sh")
                    && let Some(found) = shape_path(sh, gp, ga, gs)
                {
                    shape = Some(found);
                }
            }
            let mut layer = Layer {
                ip: l.get("ip").and_then(Value::as_f64).unwrap_or(0.0),
                op: l.get("op").and_then(Value::as_f64).unwrap_or(f64::MAX),
                pos: prop(ks.get("p")?),
                scale: prop(ks.get("s")?),
                anchor: (
                    anchor.first().copied().unwrap_or(0.0),
                    anchor.get(1).copied().unwrap_or(0.0),
                ),
                opacity: prop(ks.get("o")?).at(0.0).first().copied().unwrap_or(100.0) / 100.0,
                tint,
                shape,
                scales: None,
            };
            layer.scales = layer.scale_range(frames).map(|(lo, hi, _)| (lo, hi));
            layers.push(layer);
        }
        let lottie = Lottie {
            layers,
            size,
            frames,
            fps: doc.get("fr")?.as_f64()?,
            rasters: RefCell::new(Vec::new()),
        };
        lottie.raster_index(cx, f64::from(px_per_unit));
        Some(lottie)
    }

    /// Rasterises the chain of every layer for `ppu` pixels per composition unit at 100 %.
    fn rasterise(&self, cx: &Cx, ppu: f64) -> Raster {
        let levels = self
            .layers
            .iter()
            .map(|l| {
                let (Some((d, b)), Some((lo, hi))) = (&l.shape, l.scales) else {
                    return Vec::new();
                };
                let rest = l.scale_range(self.frames).map_or(1.0, |(_, _, last)| last);
                chain(lo, hi, rest, b.2.max(b.3) * ppu)
                    .into_iter()
                    .filter_map(|scale| {
                        let k = ppu * scale;
                        // Whole pixels around the shape's box with a transparent margin; the box is exactly `w` x `h` pixels
                        // so the drawn scale is exact.
                        let (w, h) = (
                            ((b.2 * k).ceil() as u32 + MARGIN).clamp(MARGIN, 2048),
                            ((b.3 * k).ceil() as u32 + MARGIN).clamp(MARGIN, 2048),
                        );
                        let (vw, vh) = (f64::from(w) / k, f64::from(h) / k);
                        let (vx, vy) = (b.0 + b.2 / 2.0 - vw / 2.0, b.1 + b.3 / 2.0 - vh / 2.0);
                        let pixels = swiftly_ui::icons::rasterize_box(
                            d,
                            w as usize,
                            h as usize,
                            [vx as f32, vy as f32, vw as f32, vh as f32],
                        );
                        cx.add_image(w, h, &pixels).map(|id| Level {
                            scale,
                            id,
                            bbox: (vx, vy, vw, vh),
                            px: (w, h),
                        })
                    })
                    .collect()
            })
            .collect();
        Raster { ppu, levels }
    }

    /// The index of the raster for `ppu` in [`Lottie::rasters`], made when this density has none yet.
    fn raster_index(&self, cx: &Cx, ppu: f64) -> usize {
        let found = self
            .rasters
            .borrow()
            .iter()
            .position(|r| (r.ppu - ppu).abs() <= 1e-6 * ppu.abs().max(1e-6));
        if let Some(i) = found {
            return i;
        }
        let raster = self.rasterise(cx, ppu);
        let mut all = self.rasters.borrow_mut();
        all.push(raster);
        all.len() - 1
    }

    /// For every layer what its pictures give against what the animation draws, for `ppu` pixels per composition unit
    /// (tests and measurements).
    pub fn audit(&self, cx: &Cx, ppu: f32) -> Vec<LayerAudit> {
        let ppu = f64::from(ppu);
        let i = self.raster_index(cx, ppu);
        let rasters = self.rasters.borrow();
        let raster = &rasters[i];
        self.layers
            .iter()
            .zip(&raster.levels)
            .map(|(l, levels)| {
                let mut a = LayerAudit {
                    max_drawn_px: (0.0, 0.0),
                    largest_picture_px: levels.first().map_or((0, 0), |v| v.px),
                    worst_enlargement: 0.0,
                    worst_reduction: 0.0,
                    levels: levels.len(),
                    total_px: levels
                        .iter()
                        .map(|v| u64::from(v.px.0) * u64::from(v.px.1))
                        .sum(),
                };
                let Some((_, b)) = &l.shape else { return a };
                let mut f = l.ip.max(0.0);
                while f < l.op.min(self.frames) {
                    if let Some((_, (sx, sy))) = l.pose(f) {
                        let s = sx.abs().max(sy.abs());
                        a.max_drawn_px.0 = a.max_drawn_px.0.max(b.2 * sx.abs() * ppu);
                        a.max_drawn_px.1 = a.max_drawn_px.1.max(b.3 * sy.abs() * ppu);
                        if let Some(v) = pick(levels, s) {
                            a.worst_enlargement = a.worst_enlargement.max(s / v.scale);
                            if (b.2 * sx.abs()).max(b.3 * sy.abs()) * ppu >= SPECK_PX {
                                a.worst_reduction = a.worst_reduction.max(v.scale / s);
                            }
                        }
                    }
                    f += FRAME_STEP;
                }
                a
            })
            .collect()
    }

    /// The composition at `frame` in a square of `box_pt` points on a surface of `device_scale` pixels per point: every
    /// visible layer moved and scaled by its keyframes, from the picture that fits the drawn size. The first layer of the
    /// file is on top.
    pub fn node(&self, cx: &Cx, frame: f64, box_pt: f32, device_scale: f32) -> Node {
        let k = f64::from(box_pt) / self.size;
        let ppu = k * f64::from(device_scale);
        let i = self.raster_index(cx, ppu);
        let rasters = self.rasters.borrow();
        let mut parts = Vec::new();
        for (l, levels) in self.layers.iter().zip(&rasters[i].levels).rev() {
            let Some((p, (sx, sy))) = l.pose(frame) else {
                continue;
            };
            let Some(v) = pick(levels, sx.abs().max(sy.abs())) else {
                continue;
            };
            let (bx, by, bw, bh) = v.bbox;
            let x = (p.0 + sx * (bx - l.anchor.0)) * k;
            let y = (p.1 + sy * (by - l.anchor.1)) * k;
            let (w, h) = ((bw * sx.abs() * k) as f32, (bh * sy.abs() * k) as f32);
            let mut n = Node::image(v.id, w, h, 0.0);
            for paint in &mut n.paint {
                if let Paint::Image { tint, .. } = paint {
                    *tint = Color::new(
                        l.tint.r,
                        l.tint.g,
                        l.tint.b,
                        (l.opacity as f32).clamp(0.0, 1.0),
                    );
                }
            }
            parts.push(
                n.padding(crate::home::ins(y as f32, x as f32, 0.0, 0.0))
                    .frame(Some(box_pt), Some(box_pt), Alignment::TOP_LEADING),
            );
        }
        Node::zstack(Alignment::TOP_LEADING, parts).frame(
            Some(box_pt),
            Some(box_pt),
            Alignment::TOP_LEADING,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_file_has_eight_shape_layers_and_the_mac_timing() {
        let doc: Value = serde_json::from_str(START_ANIMATION).unwrap();
        assert_eq!(
            (doc["w"].as_f64(), doc["fr"].as_f64(), doc["op"].as_f64()),
            (Some(1024.0), Some(60.0), Some(80.0))
        );
        assert_eq!(doc["layers"].as_array().unwrap().len(), 8);
    }

    #[test]
    fn easing_is_the_css_cubic_bezier() {
        assert!(
            (bezier(0.5, 0.25, 0.1, 0.25, 1.0) - 0.8).abs() < 0.05,
            "ease: {}",
            bezier(0.5, 0.25, 0.1, 0.25, 1.0)
        );
        assert!(
            (bezier(0.5, 0.0, 0.0, 1.0, 1.0) - 0.5).abs() < 1e-6,
            "linear"
        );
        assert_eq!(
            (
                bezier(0.0, 0.4, 0.0, 0.2, 1.0),
                bezier(1.0, 0.4, 0.0, 0.2, 1.0)
            ),
            (0.0, 1.0)
        );
    }

    fn start(scale: f32) -> (Cx, Lottie) {
        let cx = Cx::deterministic().with_image_page(4096);
        let l = Lottie::load(&cx, START_ANIMATION, scale * 520.0 / 1024.0).unwrap();
        (cx, l)
    }

    /// The soft edge of the launch animation: the play mark swells to 782 % but its picture was made for 100 %, so it was
    /// stretched almost eight times. Every layer's largest picture must be at least as large as the largest size the
    /// animation draws it at, and no frame may stretch a picture, at every device scale.
    #[test]
    fn no_layer_is_drawn_larger_than_its_picture_at_any_scale() {
        for scale in [1.0_f32, 1.25, 1.5, 2.0, 3.0] {
            let (cx, l) = start(scale);
            let ppu = scale * 520.0 / 1024.0;
            for (i, a) in l.audit(&cx, ppu).iter().enumerate() {
                assert!(
                    a.worst_enlargement <= 1.0 + 1e-6,
                    "scale {scale}, layer {i}: stretched {:.2} times ({a:?})",
                    a.worst_enlargement
                );
                assert!(
                    f64::from(a.largest_picture_px.0) >= a.max_drawn_px.0
                        && f64::from(a.largest_picture_px.1) >= a.max_drawn_px.1,
                    "scale {scale}, layer {i}: picture {:?} px is smaller than the largest drawn size {:?} px",
                    a.largest_picture_px,
                    a.max_drawn_px
                );
                // Bilinear filtering is clean when a picture is shrunk by less than 2, and the chain keeps it under 1.5.
                assert!(
                    a.worst_reduction <= LEVEL_STEP + 1e-6,
                    "scale {scale}, layer {i}: shrunk {:.2} times ({a:?})",
                    a.worst_reduction
                );
                assert!(a.total_px < 400_000, "scale {scale}, layer {i}: {a:?}");
            }
        }
    }

    /// The scale a layer is held at is drawn texel for texel: its picture is made for exactly that scale.
    #[test]
    fn the_held_frame_is_drawn_from_a_picture_of_exactly_its_size() {
        let (cx, l) = start(1.5);
        let i = l.raster_index(&cx, 1.5 * 520.0 / 1024.0);
        let rasters = l.rasters.borrow();
        for (n, (layer, levels)) in l.layers.iter().zip(&rasters[i].levels).enumerate() {
            let (_, _, rest) = layer.scale_range(l.frames).unwrap();
            let v = pick(levels, rest).unwrap();
            assert!(
                (v.scale - rest).abs() < 1e-9,
                "layer {n}: {} for {rest}",
                v.scale
            );
        }
    }

    /// A window that gets its scale after the curtain was built (Wayland announces it after the first frame) makes the
    /// pictures again for the new density instead of stretching the old ones.
    #[test]
    fn a_new_device_scale_makes_new_pictures() {
        let (cx, l) = start(1.0);
        assert_eq!(l.rasters.borrow().len(), 1);
        let _ = l.node(&cx, 20.0, 520.0, 1.5);
        assert_eq!(l.rasters.borrow().len(), 2);
        let _ = l.node(&cx, 21.0, 520.0, 1.5);
        let _ = l.node(&cx, 22.0, 520.0, 1.0);
        assert_eq!(l.rasters.borrow().len(), 2, "known densities are kept");
        let a = l.audit(&cx, 1.5 * 520.0 / 1024.0);
        assert!(a.iter().all(|a| a.worst_enlargement <= 1.0 + 1e-6));
    }
}
