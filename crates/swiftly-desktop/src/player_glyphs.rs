//! The player's own glyphs (play, pause, skip rings, captions, sliders, skip end), drawn as path data in the 100-unit
//! template space of `swiftly_ui::icons::rasterize` so they have the same shape on every OS. The shared icon set
//! (`check`, `x`) is reused through `Icons`; the spinner uses its spokes.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use swiftly_render::Color;
use swiftly_ui::icons::{Icons, rasterize};
use swiftly_ui::{Cx, ImageId, Node, Paint};

type Cache = Rc<RefCell<HashMap<(&'static str, u32), Option<ImageId>>>>;

/// A cache of rasterised player glyphs.
#[derive(Clone)]
pub struct Glyphs {
    cx: Cx,
    scale: f32,
    icons: Icons,
    cache: Cache,
}

fn rect(x0: f32, y0: f32, x1: f32, y1: f32) -> String {
    format!("M {x0} {y0} L {x1} {y0} L {x1} {y1} L {x0} {y1} Z ")
}

/// A ring with a gap at the top and an arrow head at one end (`gobackward` / `goforward`).
fn ring(forward: bool) -> String {
    let (ro, ri) = (46.0_f32, 38.0_f32);
    let (a0, a1) = (28.0_f32.to_radians(), 332.0_f32.to_radians());
    let mx = |x: f32| if forward { x } else { 100.0 - x };
    let pt = |r: f32, t: f32| (mx(50.0 + r * t.sin()), 50.0 - r * t.cos());
    let n = 24;
    let mut d = String::new();
    let mut pts = Vec::new();
    for i in 0..=n {
        pts.push(pt(ro, a0 + (a1 - a0) * i as f32 / n as f32));
    }
    for i in (0..=n).rev() {
        pts.push(pt(ri, a0 + (a1 - a0) * i as f32 / n as f32));
    }
    for (i, (x, y)) in pts.iter().enumerate() {
        d.push_str(&format!(
            "{} {x:.2} {y:.2} ",
            if i == 0 { "M" } else { "L" }
        ));
    }
    d.push_str("Z ");
    // Head at the end of the arc, pointing along the travel direction.
    let (px, py) = pt(42.0, a1);
    let (tx, ty) = {
        let (x, y) = (a1.cos(), a1.sin());
        (if forward { x } else { -x }, y)
    };
    let (nx, ny) = (ty, -tx);
    let _ = (nx, ny);
    let (bx, by) = (px + tx * 14.0, py + ty * 14.0);
    let (ox, oy) = (-ty * 13.0, tx * 13.0);
    d.push_str(&format!(
        "M {bx:.2} {by:.2} L {:.2} {:.2} L {:.2} {:.2} Z",
        px + ox,
        py + oy,
        px - ox,
        py - oy
    ));
    d
}

/// A straight stroke of thickness `t` from (x0, y0) to (x1, y1) as a quad.
fn bar(x0: f32, y0: f32, x1: f32, y1: f32, t: f32) -> String {
    let (dx, dy) = (x1 - x0, y1 - y0);
    let len = (dx * dx + dy * dy).sqrt().max(0.001);
    let (nx, ny) = (-dy / len * t / 2.0, dx / len * t / 2.0);
    format!(
        "M {:.2} {:.2} L {:.2} {:.2} L {:.2} {:.2} L {:.2} {:.2} Z ",
        x0 + nx,
        y0 + ny,
        x1 + nx,
        y1 + ny,
        x1 - nx,
        y1 - ny,
        x0 - nx,
        y0 - ny
    )
}

/// One diagonal arrow of the window button: an L-shaped head at `(cx, cy)` whose arms run along `(ax, ay)` (each +-1), and
/// a shaft from the head's corner to `(tx, ty)`.
fn diagonal_arrow(cx: f32, cy: f32, ax: f32, ay: f32, (tx, ty): (f32, f32)) -> String {
    let (arm, t) = (32.0_f32, 10.0_f32);
    bar(cx - ax * t / 2.0, cy, cx + ax * arm, cy, t)
        + &bar(cx, cy - ay * t / 2.0, cx, cy + ay * arm, t)
        + &bar(cx, cy, tx, ty, t)
}

/// The Mac's `arrow.up.left.and.arrow.down.right` (enter fullscreen: one arrow at the top left pointing up-left, one at
/// the bottom right pointing down-right) and `arrow.down.right.and.arrow.up.left` (leave it: both point at the middle).
fn window_arrows(inward: bool) -> String {
    if inward {
        diagonal_arrow(46.0, 46.0, -1.0, -1.0, (8.0, 8.0))
            + &diagonal_arrow(54.0, 54.0, 1.0, 1.0, (92.0, 92.0))
    } else {
        diagonal_arrow(10.0, 10.0, 1.0, 1.0, (46.0, 46.0))
            + &diagonal_arrow(90.0, 90.0, -1.0, -1.0, (54.0, 54.0))
    }
}

/// The loader arc: 22 % of a circle (stroke 3 of 34 points), turned to step `i` of 12.
fn arc(i: u8) -> String {
    let (ro, ri) = (50.0_f32, 41.0_f32);
    let a0 = f32::from(i) * std::f32::consts::TAU / 12.0;
    let a1 = a0 + 0.22 * std::f32::consts::TAU;
    let n = 16;
    let pt = |r: f32, t: f32| (50.0 + r * t.sin(), 50.0 - r * t.cos());
    let mut pts = Vec::new();
    for k in 0..=n {
        pts.push(pt(ro, a0 + (a1 - a0) * k as f32 / n as f32));
    }
    for k in (0..=n).rev() {
        pts.push(pt(ri, a0 + (a1 - a0) * k as f32 / n as f32));
    }
    let mut d = String::new();
    for (k, (x, y)) in pts.iter().enumerate() {
        d.push_str(&format!(
            "{} {x:.2} {y:.2} ",
            if k == 0 { "M" } else { "L" }
        ));
    }
    d + "Z"
}

const ARCS: [&str; 12] = [
    "arc0", "arc1", "arc2", "arc3", "arc4", "arc5", "arc6", "arc7", "arc8", "arc9", "arc10",
    "arc11",
];

fn path(name: &str) -> String {
    match name {
        "fullscreen" => window_arrows(false),
        "fullscreen-exit" => window_arrows(true),
        "speaker-slash" => {
            // Cone and body, then the slash cross (muted).
            "M 4 36 L 24 36 L 54 12 L 54 88 L 24 64 L 4 64 Z ".to_owned()
                + &bar(66.0, 36.0, 96.0, 64.0, 8.0)
                + &bar(66.0, 64.0, 96.0, 36.0, 8.0)
        }
        n if n.starts_with("arc") => arc(n[3..].parse().unwrap_or(0)),
        "play" => "M 22 0 L 100 50 L 22 100 Z".to_owned(),
        "pause" => rect(8.0, 0.0, 38.0, 100.0) + &rect(62.0, 0.0, 92.0, 100.0),
        "skip-end" => "M 0 0 L 72 50 L 0 100 Z ".to_owned() + &rect(82.0, 0.0, 100.0, 100.0),
        "goforward" => ring(true),
        "gobackward" => ring(false),
        "captions" => {
            // Bubble outline (outer clockwise, inner counter-clockwise) with two text dashes.
            let mut d = rect(0.0, 10.0, 100.0, 78.0);
            d.push_str("M 8 18 L 8 70 L 92 70 L 92 18 Z ");
            d.push_str(&rect(18.0, 30.0, 44.0, 40.0));
            d.push_str(&rect(52.0, 30.0, 82.0, 40.0));
            d.push_str(&rect(18.0, 50.0, 34.0, 60.0));
            d.push_str(&rect(42.0, 50.0, 82.0, 60.0));
            d.push_str("M 20 78 L 36 78 L 20 96 Z");
            d
        }
        "sliders" => {
            let mut d = String::new();
            for (y, k) in [(14.0_f32, 70.0_f32), (50.0, 30.0), (86.0, 55.0)] {
                d.push_str(&rect(0.0, y - 3.0, 100.0, y + 3.0));
                d.push_str(&rect(k - 9.0, y - 11.0, k + 9.0, y + 11.0));
            }
            d
        }
        _ => String::new(),
    }
}

/// The shared icon asset behind a player glyph name (and whether it is an outline with stroke variants).
fn asset_of(name: &str) -> Option<(&'static str, bool)> {
    match name {
        "check" => Some(("check", true)),
        "x" => Some(("x", true)),
        "play" => Some(("play.fill", false)),
        "pause" => Some(("pause.fill", false)),
        "skip-end" => Some(("skip-forward.fill", false)),
        "captions" => Some(("subtitles", true)),
        "speaker" => Some(("speaker-high", false)),
        "sliders" => Some(("sliders-horizontal", true)),
        "stack" => Some(("stack", true)),
        "pip" => Some(("picture-in-picture.fill", false)),
        "television" => Some(("television", true)),
        "users" => Some(("users", true)),
        "warning" => Some(("warning.fill", false)),
        "goforward" => Some(("arrow-clockwise", true)),
        "gobackward" => Some(("arrow-counter-clockwise", true)),
        // The window button's arrows (up-left / down-right, `IconMap`: arrow.up.left.and.arrow.down.right) are drawn
        // by `window_arrows`: the shared set only has the mirrored pair (up-right / down-left).
        _ => None,
    }
}

impl Glyphs {
    /// The shared icon set behind the glyphs (the paging arrows use its caret).
    pub fn icons(&self) -> &Icons {
        &self.icons
    }

    /// Glyphs for `cx` drawn at `scale` pixels per point.
    pub fn new(cx: &Cx, scale: f32) -> Glyphs {
        Glyphs {
            cx: cx.clone(),
            scale,
            icons: Icons::new(cx, scale),
            cache: Rc::new(RefCell::new(HashMap::new())),
        }
    }

    /// A glyph `pt` points square in `tint`.
    pub fn node(&self, name: &'static str, pt: f32, tint: Color) -> Node {
        // The real Swift assets (`IconMap.swift`): play.fill, pause.fill, forward.end.fill, captions.bubble,
        // slider.horizontal.3 and the skip arrows (`arrow-clockwise` / `arrow-counter-clockwise`, the seconds are text).
        let asset = asset_of(name);
        if let Some((asset, outlined)) = asset {
            // The skip rings keep their ring on the box centre (the seconds are centred in the same box).
            if matches!(name, "goforward" | "gobackward") {
                return self.icons.node_template(asset, pt, outlined, tint);
            }
            return self.icons.node(asset, pt, outlined, tint);
        }
        let px = ((pt * self.scale).ceil() as u32).max(8);
        let cached = self.cache.borrow().get(&(name, px)).copied();
        let id = cached.unwrap_or_else(|| {
            let id = self.cx.add_image(px, px, &rasterize(&path(name), px, true));
            self.cache.borrow_mut().insert((name, px), id);
            id
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

    /// The Mac loader (`Components.swift:104`): an arc of 22 % in `tint`, step `i` of 12 (0.7 s per turn).
    pub fn arc(&self, i: u8, pt: f32, tint: Color) -> Node {
        self.node(ARCS[usize::from(i % 12)], pt, tint)
    }

    /// The activity spinner at spoke `i`.
    pub fn spinner(&self, i: u8, pt: f32, tint: Color) -> Node {
        self.icons.spoke(usize::from(i), pt, tint)
    }
}

#[cfg(test)]
mod tests {
    use super::{asset_of, path, rasterize};

    /// Whether the glyph has ink around `(fx, fy)` (fractions of its box).
    fn ink(name: &str, fx: f32, fy: f32) -> bool {
        let px = 100u32;
        let img = rasterize(&path(name), px, true);
        let (cx, cy) = ((fx * px as f32) as i32, (fy * px as f32) as i32);
        (-3..=3).any(|dy| {
            (-3..=3).any(|dx| {
                let (x, y) = ((cx + dx) as usize, (cy + dy) as usize);
                img[(y * px as usize + x) * 4 + 3] > 128
            })
        })
    }

    #[test]
    fn the_window_button_is_drawn_like_the_mac_symbols() {
        // `IconMap`: arrow.up.left.and.arrow.down.right / arrow.down.right.and.arrow.up.left.
        assert_eq!(asset_of("fullscreen"), None);
        assert_eq!(asset_of("fullscreen-exit"), None);
        // Enter: the arrow heads sit in the top-left and bottom-right corners, nothing in the other two.
        assert!(ink("fullscreen", 0.10, 0.10) && ink("fullscreen", 0.90, 0.90));
        assert!(!ink("fullscreen", 0.90, 0.10) && !ink("fullscreen", 0.10, 0.90));
        // Leave: the heads move to the middle, the corners keep only the shafts' ends.
        assert!(ink("fullscreen-exit", 0.46, 0.46) && ink("fullscreen-exit", 0.54, 0.54));
        assert!(!ink("fullscreen-exit", 0.90, 0.10) && !ink("fullscreen-exit", 0.10, 0.90));
    }
}
