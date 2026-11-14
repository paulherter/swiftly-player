// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The frame's quads in painter's order. Views fill a [`DrawList`]; a renderer draws it.
//!
//! The data model comes from the Sequence Studio draw list (one instanced quad per primitive, clip rectangle baked into
//! every quad); the quad itself is new: per-corner radii, border, gradient, analytic shadow, atlas image and glyph.

use crate::geometry::{Color, Corners, Fill, LinearGradient, Rect};

/// What a quad draws; the discriminant is the kind number the shader reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QuadKind {
    /// Rounded rectangle with a solid fill and an optional inside border.
    Shape = 0,
    /// Rounded rectangle filled with a linear gradient, optional inside border.
    Gradient = 1,
    /// Analytic soft shadow of a rounded rectangle (gaussian, no offscreen pass).
    Shadow = 2,
    /// Rounded rectangle showing a region of the RGBA image atlas, tinted.
    Image = 3,
    /// A glyph: coverage from the R8 glyph atlas times the colour. Rect is pixel-aligned by the text layer.
    Glyph = 4,
    /// Frosted glass: blurs what is behind. The software renderer blurs (three box passes); `WgpuRenderer::render_to_image`/`render_to_surface` hand lists with glass to it and upload the result, so both give the same pixels.
    BackdropBlur = 5,
    /// Rounded rectangle filled with one band of a radial (elliptical) gradient, see [`DrawList::radial_stops`].
    Radial = 6,
    /// A colour glyph (emoji): premultiplied RGBA from the colour page of the glyph atlas ([`Atlas::color_page`]), drawn
    /// untinted; only the alpha of the quad colour (and the group opacity) applies.
    ColorGlyph = 7,
}

impl QuadKind {
    /// The kind from its number.
    pub fn from_index(i: u32) -> Option<QuadKind> {
        Some(match i {
            0 => QuadKind::Shape,
            1 => QuadKind::Gradient,
            2 => QuadKind::Shadow,
            3 => QuadKind::Image,
            4 => QuadKind::Glyph,
            5 => QuadKind::BackdropBlur,
            6 => QuadKind::Radial,
            7 => QuadKind::ColorGlyph,
            _ => return None,
        })
    }
}

/// An inside border: it takes `width` points from the inside edge of the shape.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Border {
    /// Border colour.
    pub color: Color,
    /// Width in points.
    pub width: f32,
}

/// A soft shadow. `blur` is the SwiftUI `radius` (the gaussian sigma is `blur / 2`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ShadowStyle {
    /// Shadow colour including alpha.
    pub color: Color,
    /// Horizontal offset in points.
    pub dx: f32,
    /// Vertical offset in points.
    pub dy: f32,
    /// Blur radius in points.
    pub blur: f32,
    /// Growth of the casting rectangle in points (negative shrinks).
    pub spread: f32,
}

/// One GPU instance: every primitive is a quad. All lengths are points. On the GPU an instance is 176 bytes, see
/// [`DrawQuad::write_bytes`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DrawQuad {
    /// The shape's rectangle (for a shadow: the casting rectangle, offset and spread already applied).
    pub rect: Rect,
    /// Clip as `(x0, y0, x1, y1)`.
    pub clip: [f32; 4],
    /// Rounded clip as `(x0, y0, x1, y1, radius)`: the picture of the quad is cut to this rounded rectangle, with an
    /// anti-aliased edge (a card that clips its children, SwiftUI `clipShape(RoundedRectangle)`). Radius 0 = none.
    pub round_clip: [f32; 5],
    /// Fill, gradient start, image tint, glyph colour, shadow colour or glass tint.
    pub color: Color,
    /// Gradient end colour.
    pub color2: Color,
    /// Border colour.
    pub border_color: Color,
    /// Corner radii.
    pub radii: Corners,
    /// Image and glyph: normalised source rectangle `(u0, v0, u1, v1)` in the atlas page.
    pub uv: [f32; 4],
    /// Border width (0 = none).
    pub border_width: f32,
    /// Shadow: gaussian sigma. Backdrop blur: blur radius.
    pub blur: f32,
    /// Multiplier on the whole quad (group opacity; see [`DrawList::push_opacity`]).
    pub opacity: f32,
    /// The primitive.
    pub kind: QuadKind,
    /// Gradient line `(x0, y0, x1, y1)` in the unit square of `rect`.
    pub gradient: [f32; 4],
    /// The quad belongs to an opacity group (set between `push_opacity` and `pop_opacity`).
    pub grouped: bool,
    /// Noise of one level is added to the output, so a slow ramp does not band in 8 bits. Always on for gradients; images
    /// opt in (a pre-computed gradient picture).
    pub dither: bool,
}

impl DrawQuad {
    /// Bytes of one instance in the GPU buffer.
    pub const SIZE: usize = 176;

    fn base(rect: Rect, clip: Rect, kind: QuadKind) -> DrawQuad {
        DrawQuad {
            rect,
            clip: [clip.x, clip.y, clip.max_x(), clip.max_y()],
            round_clip: [0.0; 5],
            color: Color::CLEAR,
            color2: Color::CLEAR,
            border_color: Color::CLEAR,
            radii: Corners::ZERO,
            uv: [0.0; 4],
            border_width: 0.0,
            blur: 0.0,
            opacity: 1.0,
            kind,
            gradient: [0.0, 0.5, 1.0, 0.5],
            grouped: false,
            dither: false,
        }
    }

    /// Appends the 176-byte little-endian instance: rect, clip, colour, colour2, border colour, radii, uv,
    /// `(border_width, blur, opacity, kind + 16 * flags)`, gradient, rounded clip rectangle, `(radius, 0, 0, 0)`.
    pub fn write_bytes(&self, out: &mut Vec<u8>) {
        let r = &self.rect;
        let flags = u32::from(self.grouped) + 2 * u32::from(self.dither);
        let floats: [f32; 44] = {
            let (c, c2, bc, ra) = (self.color, self.color2, self.border_color, self.radii);
            [
                r.x,
                r.y,
                r.w,
                r.h,
                self.clip[0],
                self.clip[1],
                self.clip[2],
                self.clip[3],
                c.r,
                c.g,
                c.b,
                c.a,
                c2.r,
                c2.g,
                c2.b,
                c2.a,
                bc.r,
                bc.g,
                bc.b,
                bc.a,
                ra.tl,
                ra.tr,
                ra.br,
                ra.bl,
                self.uv[0],
                self.uv[1],
                self.uv[2],
                self.uv[3],
                self.border_width,
                self.blur,
                self.opacity,
                (self.kind as u32 + 16 * flags) as f32,
                self.gradient[0],
                self.gradient[1],
                self.gradient[2],
                self.gradient[3],
                self.round_clip[0],
                self.round_clip[1],
                self.round_clip[2],
                self.round_clip[3],
                self.round_clip[4],
                0.0,
                0.0,
                0.0,
            ]
        };
        for f in floats {
            out.extend_from_slice(&f.to_le_bytes());
        }
    }
}

/// The frame's quads in painter's order, with a clip stack and an opacity stack.
///
/// Coordinates are points, y down; `scale` is pixels per point (2.0 on a typical phone). The pixel size of the frame is
/// [`DrawList::pixel_size`].
#[derive(Clone, Debug)]
pub struct DrawList {
    quads: Vec<DrawQuad>,
    width: f32,
    height: f32,
    scale: f32,
    clips: Vec<Clip>,
    opacities: Vec<f32>,
}

/// One entry of the clip stack: the rectangle and the innermost rounded clip in force (`(x0, y0, x1, y1, radius)`).
#[derive(Clone, Copy, Debug, PartialEq)]
struct Clip {
    rect: Rect,
    round: [f32; 5],
}

impl DrawList {
    /// An empty list for a `width x height` point canvas drawn at `scale` pixels per point.
    pub fn new(width: f32, height: f32, scale: f32) -> DrawList {
        let scale = if scale > 0.0 { scale } else { 1.0 };
        DrawList {
            quads: Vec::new(),
            width,
            height,
            scale,
            clips: vec![Clip {
                rect: Rect::new(0.0, 0.0, width, height),
                round: [0.0; 5],
            }],
            opacities: Vec::new(),
        }
    }

    /// The quads for in-place edits (the image hub blanks stale picture rectangles).
    pub fn quads_mut(&mut self) -> &mut [DrawQuad] {
        &mut self.quads
    }

    /// The quads, painter's order.
    pub fn quads(&self) -> &[DrawQuad] {
        &self.quads
    }
    /// Canvas width in points.
    pub fn width(&self) -> f32 {
        self.width
    }
    /// Canvas height in points.
    pub fn height(&self) -> f32 {
        self.height
    }
    /// Pixels per point.
    pub fn scale(&self) -> f32 {
        self.scale
    }
    /// Frame size in pixels (rounded up).
    pub fn pixel_size(&self) -> (u32, u32) {
        (
            (self.width * self.scale).ceil().max(1.0) as u32,
            (self.height * self.scale).ceil().max(1.0) as u32,
        )
    }

    /// The same list drawn at another scale (pixels per point).
    pub fn with_scale(&self, scale: f32) -> DrawList {
        DrawList {
            scale: if scale > 0.0 { scale } else { 1.0 },
            ..self.clone()
        }
    }

    /// Appends the quads of `other` moved right by `dx` points and clipped to this canvas (a page of a navigation
    /// stack drawn by another UI).
    pub fn append_shifted(&mut self, other: &DrawList, dx: f32) {
        for q in other.quads() {
            let mut q = *q;
            q.rect.x += dx;
            q.clip[0] = (q.clip[0] + dx).max(0.0);
            q.clip[2] = (q.clip[2] + dx).min(self.width);
            q.round_clip[0] += dx;
            q.round_clip[2] += dx;
            if q.clip[2] > q.clip[0] {
                self.quads.push(q);
            }
        }
    }

    /// Moves every quad (and its clip) right by `dx` points, clipped to the canvas: the page below a pushed page that
    /// slides back (the parallax of a navigation push).
    pub fn shift_all(&mut self, dx: f32) {
        let width = self.width;
        self.quads.retain_mut(|q| {
            q.rect.x += dx;
            q.clip[0] = (q.clip[0] + dx).max(0.0);
            q.clip[2] = (q.clip[2] + dx).min(width);
            q.round_clip[0] += dx;
            q.round_clip[2] += dx;
            q.clip[2] > q.clip[0]
        });
    }

    /// Keeps only what lies in the columns `x0 .. x1`: every quad is clipped to them and those outside are dropped (the
    /// sidebar and the content column of a window are drawn apart).
    pub fn clip_x(&mut self, x0: f32, x1: f32) {
        self.quads.retain_mut(|q| {
            q.clip[0] = q.clip[0].max(x0);
            q.clip[2] = q.clip[2].min(x1);
            q.clip[2] > q.clip[0]
        });
    }

    /// Multiplies the opacity of every quad by `alpha` (a cross fade between two pages).
    pub fn fade(&mut self, alpha: f32) {
        for q in &mut self.quads {
            q.opacity *= alpha;
        }
    }

    /// A black veil of `alpha` over the whole canvas (the dim of the page below a pushed page).
    pub fn veil(&mut self, alpha: f32) {
        let full = Rect::new(0.0, 0.0, self.width, self.height);
        self.fill(full, Color::new(0.0, 0.0, 0.0, alpha), 0.0);
    }

    /// Removes all quads and pushed state, keeping the canvas.
    pub fn clear(&mut self) {
        self.quads.clear();
        self.clips.truncate(1);
        self.opacities.clear();
    }

    /// The innermost clip.
    pub fn clip(&self) -> Rect {
        self.clips.last().map_or(Rect::ZERO, |c| c.rect)
    }
    fn round(&self) -> [f32; 5] {
        self.clips.last().map_or([0.0; 5], |c| c.round)
    }
    /// Intersects the clip with `r` until [`pop_clip`](Self::pop_clip).
    pub fn push_clip(&mut self, r: Rect) {
        let c = self.clip().intersection(r);
        let round = self.round();
        self.clips.push(Clip { rect: c, round });
    }
    /// Like [`push_clip`](Self::push_clip), and the picture inside is cut to the rounded rectangle `r` with corner
    /// `radius` (anti-aliased, drawn in the shader: no offscreen pass), SwiftUI `clipShape(RoundedRectangle)`. Closed
    /// with [`pop_clip`](Self::pop_clip). One rounded clip applies at a time: a quad inside two nested rounded clips is
    /// cut to the inner one only (and to the rectangle of both).
    pub fn push_round_clip(&mut self, r: Rect, radius: f32) {
        let c = self.clip().intersection(r);
        let round = if radius > 0.0 {
            [r.x, r.y, r.max_x(), r.max_y(), radius]
        } else {
            self.round()
        };
        self.clips.push(Clip { rect: c, round });
    }
    /// Drops the innermost pushed clip (the canvas clip stays).
    pub fn pop_clip(&mut self) {
        if self.clips.len() > 1 {
            self.clips.pop();
        }
    }

    /// Multiplies the opacity of everything drawn until [`pop_opacity`](Self::pop_opacity) by `opacity` and flags the
    /// quads as one group. Each quad is faded on its own (correct unless quads of the group overlap, which needs an
    /// offscreen pass that is not built yet).
    pub fn push_opacity(&mut self, opacity: f32) {
        self.opacities
            .push(self.current_opacity() * opacity.clamp(0.0, 1.0));
    }
    /// Ends the innermost opacity group.
    pub fn pop_opacity(&mut self) {
        self.opacities.pop();
    }
    fn current_opacity(&self) -> f32 {
        self.opacities.last().copied().unwrap_or(1.0)
    }

    fn push(&mut self, mut q: DrawQuad) {
        q.opacity = self.current_opacity();
        q.grouped = !self.opacities.is_empty();
        self.quads.push(q);
    }

    fn quad(&self, rect: Rect, kind: QuadKind) -> DrawQuad {
        let mut q = DrawQuad::base(rect, self.clip(), kind);
        q.round_clip = self.round();
        q
    }

    /// `r` with every edge on a whole device pixel (at least one pixel wide and high). On a 1.5 scale half of all
    /// edges fall between two pixels; the shader then covers the edge pixels partly, so two touching shapes leave a
    /// seam of the picture behind them and a picture shows a rim of the page. Core Animation snaps layers to the pixel
    /// grid the same way.
    pub fn snapped(&self, r: Rect) -> Rect {
        let s = self.scale;
        let edge = |v: f32| (v * s).round() / s;
        let (x0, y0) = (edge(r.x), edge(r.y));
        let (mut x1, mut y1) = (edge(r.x + r.w), edge(r.y + r.h));
        if x1 <= x0 {
            x1 = x0 + 1.0 / s;
        }
        if y1 <= y0 {
            y1 = y0 + 1.0 / s;
        }
        Rect::new(x0, y0, x1 - x0, y1 - y0)
    }

    /// `r` with its origin and its size on whole device pixels (at least one pixel): a picture is drawn one texel to one
    /// pixel when its texture was made at that size (`round(size * scale)`, what the image hub does), and a raster made
    /// at the device size (icons, the wordmark) never lands between two pixels. This is the only place that snaps
    /// pictures; gradient seams use [`snapped`](Self::snapped), which rounds the edges so touching bands share them.
    pub fn snapped_picture(&self, r: Rect) -> Rect {
        let s = self.scale;
        let px = |v: f32| (v * s).round() / s;
        Rect::new(px(r.x), px(r.y), px(r.w).max(1.0 / s), px(r.h).max(1.0 / s))
    }

    /// A rounded rectangle with a fill and an optional inside border.
    pub fn rect(
        &mut self,
        r: Rect,
        fill: impl Into<Fill>,
        border: Option<Border>,
        radii: impl Into<Corners>,
    ) {
        self.rect_exact(r, fill, border, radii);
    }

    /// [`rect`](Self::rect) at exactly `r`, anti-aliased on its edges.
    fn rect_exact(
        &mut self,
        r: Rect,
        fill: impl Into<Fill>,
        border: Option<Border>,
        radii: impl Into<Corners>,
    ) {
        if r.w <= 0.0 || r.h <= 0.0 {
            return;
        }
        let mut q = self.quad(r, QuadKind::Shape);
        q.radii = radii.into();
        match fill.into() {
            Fill::None => {}
            Fill::Solid(c) => q.color = c,
            Fill::Linear(g) => {
                q.kind = QuadKind::Gradient;
                q.color = g.start;
                q.color2 = g.end;
                q.gradient = [g.from[0], g.from[1], g.to[0], g.to[1]];
            }
        }
        if let Some(b) = border.filter(|b| b.width > 0.0) {
            q.border_color = b.color;
            q.border_width = b.width;
        }
        let visible =
            q.color.a > 0.0 || q.color2.a > 0.0 || q.border_width > 0.0 && q.border_color.a > 0.0;
        if visible {
            self.push(q);
        }
    }

    /// A filled rounded rectangle.
    pub fn fill(&mut self, r: Rect, fill: impl Into<Fill>, radii: impl Into<Corners>) {
        self.rect(r, fill, None, radii);
    }

    /// A fill with any number of colour stops along one axis (the Mac header backdrop has 10), drawn as one two-stop
    /// gradient band per pair of neighbouring stops. `stops` are `(position 0..1, colour)`, sorted by position.
    /// Rounded corners (`radius`) apply to the outer ends only. Fewer than two stops fill with the single colour.
    pub fn fill_stops(&mut self, r: Rect, vertical: bool, stops: &[(f32, Color)], radius: f32) {
        match stops {
            [] => {}
            [(_, c)] => self.fill(r, *c, radius),
            _ => {
                let last = stops.len() - 2;
                // The seams between bands lie on whole device pixels: a seam inside a pixel is covered twice by half and
                // lets the picture behind show through as a thin line.
                let whole = self.snapped(r);
                let s = self.scale;
                let at = |from: f32, len: f32, p: f32| {
                    if p <= 0.0 {
                        from
                    } else if p >= 1.0 {
                        from + len
                    } else {
                        ((from + len * p) * s).round() / s
                    }
                };
                for (i, w) in stops.windows(2).enumerate() {
                    let (p0, c0) = (w[0].0.clamp(0.0, 1.0), w[0].1);
                    let (p1, c1) = (w[1].0.clamp(0.0, 1.0), w[1].1);
                    if p1 <= p0 {
                        continue;
                    }
                    let (band, g) = if vertical {
                        let (y0, y1) = (at(whole.y, whole.h, p0), at(whole.y, whole.h, p1));
                        (
                            Rect::new(whole.x, y0, whole.w, y1 - y0),
                            LinearGradient::vertical(c0, c1),
                        )
                    } else {
                        let (x0, x1) = (at(whole.x, whole.w, p0), at(whole.x, whole.w, p1));
                        (
                            Rect::new(x0, whole.y, x1 - x0, whole.h),
                            LinearGradient::horizontal(c0, c1),
                        )
                    };
                    let (a, b) = (
                        if i == 0 { radius } else { 0.0 },
                        if i == last { radius } else { 0.0 },
                    );
                    let corners = if vertical {
                        Corners::new(a, a, b, b)
                    } else {
                        Corners::new(a, b, b, a)
                    };
                    self.fill(band, g, corners);
                }
            }
        }
    }

    /// An elliptical gradient inside `r` (SwiftUI `EllipticalGradient`, `RadialGradient`): the colour at distance `t` from
    /// `center` (points) is read from `stops` (`(position, colour)`, sorted, positions 0..1), where `t` is 1 on the
    /// ellipse with the half axes `radii` (points). Inside the first stop and beyond the last the end colours extend.
    /// Drawn as one quad per pair of neighbouring stops, each covering `r` but painting only its own band, so a band
    /// costs one cheap shader pass and no stop count limits the quad. Dithered like the linear gradient.
    pub fn radial_stops(
        &mut self,
        r: Rect,
        center: [f32; 2],
        radii: [f32; 2],
        stops: &[(f32, Color)],
    ) {
        if r.w <= 0.0 || r.h <= 0.0 || radii[0] <= 0.0 || radii[1] <= 0.0 {
            return;
        }
        let unit = [
            (center[0] - r.x) / r.w,
            (center[1] - r.y) / r.h,
            radii[0] / r.w,
            radii[1] / r.h,
        ];
        let last = stops.len().saturating_sub(2);
        match stops {
            [] => {}
            [(_, c)] => self.fill(r, *c, 0.0),
            _ => {
                for (i, w) in stops.windows(2).enumerate() {
                    let (p0, p1) = (w[0].0, w[1].0);
                    if p1 <= p0 || w[0].1.a <= 0.0 && w[1].1.a <= 0.0 {
                        continue;
                    }
                    let mut q = self.quad(r, QuadKind::Radial);
                    q.color = w[0].1;
                    q.color2 = w[1].1;
                    q.gradient = unit;
                    // The band; the outermost ones extend to infinity (a huge number keeps the shader branch-free).
                    q.uv = [
                        if i == 0 { -1.0e9 } else { p0 },
                        p0,
                        p1,
                        if i == last { 1.0e9 } else { p1 },
                    ];
                    q.dither = true;
                    self.push(q);
                }
            }
        }
    }

    /// An inside border only (the fill stays untouched).
    pub fn stroke(&mut self, r: Rect, color: Color, width: f32, radii: impl Into<Corners>) {
        self.rect(r, Fill::None, Some(Border { color, width }), radii);
    }

    /// A progress arc inside the square `r`: a ring stroke of `width` points from 12 o'clock clockwise, `from`..`to` in turns
    /// (0..1), round caps (SwiftUI `Circle().trim(from:to:).stroke(style: round).rotationEffect(-90)`). Drawn as a chain of
    /// round dots, so the software and GPU renderers give the same pixels without a new shader kind.
    pub fn arc(&mut self, r: Rect, color: Color, width: f32, from: f32, to: f32) {
        let (from, to) = (from.clamp(0.0, 1.0), to.clamp(0.0, 1.0));
        if r.w <= 0.0 || r.h <= 0.0 || width <= 0.0 || color.a <= 0.0 || to <= from {
            return;
        }
        let radius = (r.w.min(r.h) - width) / 2.0;
        if radius <= 0.0 {
            return;
        }
        let (cx, cy) = (r.x + r.w / 2.0, r.y + r.h / 2.0);
        let length = (to - from) * std::f32::consts::TAU * radius;
        let steps = ((length / (width * 0.2)).ceil() as usize).clamp(1, 4000);
        for i in 0..=steps {
            let t = from + (to - from) * i as f32 / steps as f32;
            let a = t * std::f32::consts::TAU - std::f32::consts::FRAC_PI_2;
            let (x, y) = (cx + radius * a.cos(), cy + radius * a.sin());
            self.fill(
                Rect::new(x - width / 2.0, y - width / 2.0, width, width),
                color,
                width / 2.0,
            );
        }
    }

    /// The soft shadow of a rounded rectangle `r` (the casting shape; draw the shape itself afterwards).
    pub fn shadow(&mut self, r: Rect, s: ShadowStyle, radii: impl Into<Corners>) {
        let cast = r.offset(s.dx, s.dy).outset(s.spread);
        if cast.w <= 0.0 || cast.h <= 0.0 || s.color.a <= 0.0 {
            return;
        }
        let mut q = self.quad(cast, QuadKind::Shadow);
        q.color = s.color;
        q.blur = (s.blur / 2.0).max(0.0);
        let grow = s.spread;
        q.radii = radii.into().inset(-grow);
        self.push(q);
    }

    /// Part `uv` (normalised `u0, v0, u1, v1`) of the image atlas into `r` with rounded corners; `tint` multiplies
    /// every channel (white = unchanged).
    pub fn image(&mut self, r: Rect, uv: [f32; 4], tint: Color, radii: impl Into<Corners>) {
        if r.w <= 0.0 || r.h <= 0.0 || tint.a <= 0.0 {
            return;
        }
        let mut q = self.quad(self.snapped_picture(r), QuadKind::Image);
        q.uv = uv;
        q.color = tint;
        q.radii = radii.into();
        self.push(q);
    }

    /// Like [`image`](Self::image), with one level of noise added so a pre-computed slow ramp (a faded backdrop) does not
    /// band in 8 bits.
    pub fn image_dithered(
        &mut self,
        r: Rect,
        uv: [f32; 4],
        tint: Color,
        radii: impl Into<Corners>,
    ) {
        let before = self.quads.len();
        self.image(r, uv, tint, radii);
        if let Some(q) = self.quads[before..].last_mut() {
            q.dither = true;
        }
    }

    /// A glyph from the R8 glyph atlas (`uv` normalised) into `r`, in `color`.
    pub fn glyph(&mut self, r: Rect, uv: [f32; 4], color: Color) {
        if r.w <= 0.0 || r.h <= 0.0 || color.a <= 0.0 {
            return;
        }
        let mut q = self.quad(r, QuadKind::Glyph);
        q.uv = uv;
        q.color = color;
        self.push(q);
    }

    /// A colour glyph (emoji) from the colour page of the glyph atlas (`uv` normalised) into `r`. The picture keeps its own
    /// colours; of `color` only the alpha is used (so a faded row fades its emoji too).
    pub fn color_glyph(&mut self, r: Rect, uv: [f32; 4], color: Color) {
        if r.w <= 0.0 || r.h <= 0.0 || color.a <= 0.0 {
            return;
        }
        let mut q = self.quad(r, QuadKind::ColorGlyph);
        q.uv = uv;
        q.color = color;
        self.push(q);
    }

    /// Frosted glass over `r`: blur of the backdrop (`radius` points) under `tint`. The software renderer blurs (box passes); the GPU renderer's whole-list entry points use that same path.
    pub fn backdrop_blur(&mut self, r: Rect, radius: f32, tint: Color, radii: impl Into<Corners>) {
        if r.w <= 0.0 || r.h <= 0.0 {
            return;
        }
        let mut q = self.quad(r, QuadKind::BackdropBlur);
        q.blur = radius;
        q.color = tint;
        q.radii = radii.into();
        self.push(q);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quad_is_176_bytes_with_kind_and_flags() {
        let mut l = DrawList::new(10.0, 10.0, 1.0);
        l.push_opacity(0.5);
        l.image(
            Rect::new(0.0, 0.0, 4.0, 4.0),
            [0.0, 0.0, 1.0, 1.0],
            Color::WHITE,
            0.0,
        );
        let mut b = Vec::new();
        l.quads()[0].write_bytes(&mut b);
        assert_eq!(b.len(), DrawQuad::SIZE);
        let f = |i: usize| f32::from_le_bytes([b[i * 4], b[i * 4 + 1], b[i * 4 + 2], b[i * 4 + 3]]);
        assert_eq!(f(30), 0.5, "opacity");
        assert_eq!(f(31), 3.0 + 16.0, "image kind and the group flag");
        assert_eq!(f(40), 0.0, "no rounded clip");
    }

    #[test]
    fn arc_starts_at_the_top_and_runs_clockwise() {
        let mut l = DrawList::new(60.0, 60.0, 1.0);
        l.arc(
            Rect::new(0.0, 0.0, 60.0, 60.0),
            Color::WHITE,
            4.0,
            0.0,
            0.25,
        );
        let q = l.quads();
        assert!(!q.is_empty());
        let first = q[0].rect;
        let last = q[q.len() - 1].rect;
        assert!(
            (first.x + 2.0 - 30.0).abs() < 0.01 && (first.y + 2.0 - 2.0).abs() < 0.01,
            "top centre"
        );
        assert!(
            (last.x + 2.0 - 58.0).abs() < 0.01 && (last.y + 2.0 - 30.0).abs() < 0.01,
            "right centre after a quarter"
        );
        let mut none = DrawList::new(60.0, 60.0, 1.0);
        none.arc(Rect::new(0.0, 0.0, 60.0, 60.0), Color::WHITE, 4.0, 0.3, 0.3);
        assert!(none.quads().is_empty());
    }

    #[test]
    fn empty_and_invisible_draws_add_nothing() {
        let mut l = DrawList::new(10.0, 10.0, 1.0);
        l.fill(Rect::new(0.0, 0.0, 0.0, 5.0), Color::WHITE, 0.0);
        l.fill(Rect::new(0.0, 0.0, 5.0, 5.0), Color::CLEAR, 0.0);
        l.stroke(Rect::new(0.0, 0.0, 5.0, 5.0), Color::WHITE, 0.0, 0.0);
        l.glyph(Rect::new(0.0, 0.0, 5.0, 5.0), [0.0; 4], Color::CLEAR);
        assert!(l.quads().is_empty());
    }

    #[test]
    fn clip_stack_intersects_and_pops() {
        let mut l = DrawList::new(100.0, 100.0, 2.0);
        l.push_clip(Rect::new(10.0, 10.0, 50.0, 50.0));
        l.push_clip(Rect::new(30.0, 0.0, 100.0, 100.0));
        assert_eq!(l.clip(), Rect::new(30.0, 10.0, 30.0, 50.0));
        l.fill(Rect::new(0.0, 0.0, 100.0, 100.0), Color::WHITE, 0.0);
        assert_eq!(l.quads()[0].clip, [30.0, 10.0, 60.0, 60.0]);
        l.pop_clip();
        l.pop_clip();
        l.pop_clip();
        assert_eq!(l.clip(), Rect::new(0.0, 0.0, 100.0, 100.0));
        assert_eq!(l.pixel_size(), (200, 200));
    }

    #[test]
    fn round_clip_is_stored_on_the_quads_and_follows_shifts() {
        let mut l = DrawList::new(100.0, 100.0, 1.0);
        l.push_round_clip(Rect::new(10.0, 10.0, 50.0, 40.0), 8.0);
        l.push_clip(Rect::new(0.0, 0.0, 30.0, 100.0));
        l.fill(Rect::new(0.0, 0.0, 100.0, 100.0), Color::WHITE, 0.0);
        l.pop_clip();
        l.pop_clip();
        l.fill(Rect::new(0.0, 0.0, 5.0, 5.0), Color::WHITE, 0.0);
        assert_eq!(l.quads()[0].round_clip, [10.0, 10.0, 60.0, 50.0, 8.0]);
        assert_eq!(
            l.quads()[0].clip,
            [10.0, 10.0, 30.0, 50.0],
            "the rectangle clip still applies"
        );
        assert_eq!(l.quads()[1].round_clip[4], 0.0, "popped");
        let mut b = Vec::new();
        l.quads()[0].write_bytes(&mut b);
        let f = |i: usize| f32::from_le_bytes([b[i * 4], b[i * 4 + 1], b[i * 4 + 2], b[i * 4 + 3]]);
        assert_eq!((f(36), f(38), f(40)), (10.0, 60.0, 8.0));
        l.shift_all(5.0);
        assert_eq!(
            (l.quads()[0].round_clip[0], l.quads()[0].round_clip[2]),
            (15.0, 65.0)
        );
    }

    #[test]
    fn radial_stops_make_one_band_per_pair_with_open_ends() {
        let mut l = DrawList::new(100.0, 100.0, 1.0);
        let c = |a: f32| Color::new(1.0, 1.0, 1.0, a);
        l.radial_stops(
            Rect::new(0.0, 0.0, 100.0, 50.0),
            [50.0, 0.0],
            [50.0, 25.0],
            &[(0.0, c(0.2)), (0.35, c(0.12)), (1.0, c(0.0))],
        );
        let q = l.quads();
        assert_eq!(q.len(), 2);
        assert!(q.iter().all(|q| q.kind == QuadKind::Radial));
        assert_eq!(
            q[0].gradient,
            [0.5, 0.0, 0.5, 0.5],
            "centre and radii in the unit square"
        );
        assert!(
            q[0].uv[0] < -1.0e8 && q[0].uv[3] == 0.35,
            "first band reaches inwards"
        );
        assert!(
            q[1].uv[3] > 1.0e8 && q[1].uv[1] == 0.35 && q[1].uv[2] == 1.0,
            "last band reaches outwards"
        );
        let mut none = DrawList::new(10.0, 10.0, 1.0);
        none.radial_stops(
            Rect::new(0.0, 0.0, 10.0, 10.0),
            [0.0; 2],
            [0.0, 5.0],
            &[(0.0, c(1.0)), (1.0, c(0.0))],
        );
        assert!(none.quads().is_empty(), "a flat ellipse draws nothing");
    }

    #[test]
    fn opacity_groups_nest() {
        let mut l = DrawList::new(10.0, 10.0, 1.0);
        l.push_opacity(0.5);
        l.push_opacity(0.5);
        l.fill(Rect::new(0.0, 0.0, 5.0, 5.0), Color::WHITE, 0.0);
        l.pop_opacity();
        l.fill(Rect::new(0.0, 0.0, 5.0, 5.0), Color::WHITE, 0.0);
        l.pop_opacity();
        l.fill(Rect::new(0.0, 0.0, 5.0, 5.0), Color::WHITE, 0.0);
        let o: Vec<f32> = l.quads().iter().map(|q| q.opacity).collect();
        assert_eq!(o, [0.25, 0.5, 1.0]);
        assert!(l.quads()[0].grouped && !l.quads()[2].grouped);
    }

    #[test]
    fn stops_become_one_band_per_pair_and_cover_the_rect_exactly() {
        let mut l = DrawList::new(100.0, 150.0, 1.0);
        let c = |a: f32| Color::new(0.0627, 0.0627, 0.0627, a);
        let stops = [
            (0.0, c(0.97)),
            (0.15, c(0.93)),
            (0.58, c(0.64)),
            (1.0, c(0.0)),
        ];
        l.fill_stops(Rect::new(0.0, 0.0, 100.0, 150.0), true, &stops, 0.0);
        let q = l.quads();
        assert_eq!(q.len(), 3);
        // The seam lies on a whole pixel (22.5 rounds to 23).
        assert!((q[0].rect.h - 22.5).abs() <= 0.5);
        let end = q[2].rect.y + q[2].rect.h;
        assert!((end - 150.0).abs() < 1e-3, "{end}");
        assert_eq!(q[1].color.a, 0.93);
        assert_eq!(q[1].color2.a, 0.64);
    }
}
