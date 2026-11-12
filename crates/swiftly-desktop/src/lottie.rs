//! A small Lottie player for the shapes of one file: the Mac's launch animation (`Sources/Shared/Assets/startanimation.json`,
//! 1024 x 1024, 60 fps, 80 frames). It reads shape layers with a static group (bezier path + flat fill + group
//! transform) and an animated layer transform (position, scale with cubic-bezier easing; opacity and rotation are read as
//! static values). Each layer's shape is rasterised once into a white coverage image (the free scanline rasteriser of
//! `swiftly-ui`) and drawn tinted, moved and scaled every frame. Anything else in a file is ignored, so this is not a
//! general Lottie renderer.

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

struct Layer {
    ip: f64,
    op: f64,
    pos: Prop,
    scale: Prop,
    anchor: (f64, f64),
    opacity: f64,
    image: Option<ImageId>,
    /// The shape's box in layer space: `(x, y, w, h)`.
    bbox: (f64, f64, f64, f64),
    tint: Color,
}

/// The parsed animation with its layers rasterised.
pub struct Lottie {
    layers: Vec<Layer>,
    size: f64,
    /// The last frame (`op`).
    pub frames: f64,
    /// Frames per second.
    pub fps: f64,
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

impl Lottie {
    /// Parses `json` and rasterises every layer's shape at `px_per_unit` pixels per composition unit.
    pub fn load(cx: &Cx, json: &str, px_per_unit: f32) -> Option<Lottie> {
        let doc: Value = serde_json::from_str(json).ok()?;
        let size = doc.get("w")?.as_f64()?;
        let mut layers = Vec::new();
        for l in doc.get("layers")?.as_array()? {
            if l.get("ty").and_then(Value::as_i64) != Some(4) {
                continue;
            }
            let ks = l.get("ks")?;
            let anchor = prop(ks.get("a")?).at(0.0);
            let mut image = None;
            let mut bbox = (0.0, 0.0, 0.0, 0.0);
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
                    && let Some((d, b)) = shape_path(sh, gp, ga, gs)
                {
                    // Two transparent pixels of margin on every side (the antialiased edge and the atlas neighbours stay clear),
                    // and the box is exactly `w` x `h` pixels so the scale is exact.
                    let k = f64::from(px_per_unit);
                    let (w, h) = (
                        ((b.2 * k).ceil() as u32 + 4).clamp(4, 2048),
                        ((b.3 * k).ceil() as u32 + 4).clamp(4, 2048),
                    );
                    let (vw, vh) = (f64::from(w) / k, f64::from(h) / k);
                    let (vx, vy) = (b.0 + b.2 / 2.0 - vw / 2.0, b.1 + b.3 / 2.0 - vh / 2.0);
                    let pixels = swiftly_ui::icons::rasterize_box(
                        &d,
                        w as usize,
                        h as usize,
                        [vx as f32, vy as f32, vw as f32, vh as f32],
                    );
                    image = cx.add_image(w, h, &pixels);
                    bbox = (vx, vy, vw, vh);
                }
            }
            layers.push(Layer {
                ip: l.get("ip").and_then(Value::as_f64).unwrap_or(0.0),
                op: l.get("op").and_then(Value::as_f64).unwrap_or(f64::MAX),
                pos: prop(ks.get("p")?),
                scale: prop(ks.get("s")?),
                anchor: (
                    anchor.first().copied().unwrap_or(0.0),
                    anchor.get(1).copied().unwrap_or(0.0),
                ),
                opacity: prop(ks.get("o")?).at(0.0).first().copied().unwrap_or(100.0) / 100.0,
                image,
                bbox,
                tint,
            });
        }
        Some(Lottie {
            layers,
            size,
            frames: doc.get("op")?.as_f64()?,
            fps: doc.get("fr")?.as_f64()?,
        })
    }

    /// The composition at `frame` in a square of `box_pt` points: every visible layer moved and scaled by its keyframes.
    /// The first layer of the file is on top.
    pub fn node(&self, frame: f64, box_pt: f32) -> Node {
        let k = f64::from(box_pt) / self.size;
        let mut parts = Vec::new();
        for l in self.layers.iter().rev() {
            if frame < l.ip || frame >= l.op {
                continue;
            }
            let Some(id) = l.image else { continue };
            let (p, s) = (l.pos.at(frame), l.scale.at(frame));
            if p.len() < 2 || s.len() < 2 {
                continue;
            }
            let (sx, sy) = (s[0] / 100.0, s[1] / 100.0);
            if sx.abs() < 1e-4 || sy.abs() < 1e-4 {
                continue;
            }
            let (bx, by, bw, bh) = l.bbox;
            let x = (p[0] + sx * (bx - l.anchor.0)) * k;
            let y = (p[1] + sy * (by - l.anchor.1)) * k;
            let (w, h) = ((bw * sx.abs() * k) as f32, (bh * sy.abs() * k) as f32);
            let mut n = Node::image(id, w, h, 0.0);
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
}
