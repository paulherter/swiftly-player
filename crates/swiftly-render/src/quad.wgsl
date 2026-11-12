// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// One instanced draw of all quads of a DrawList. The per-pixel math is mirrored 1:1 by software.rs (the oracle):
// change both together. Output is premultiplied; the pipeline blends "one, one minus source alpha" in sRGB code values.
// Instance layout: see DrawQuad::write_bytes (144 bytes, nine vec4 attributes).

struct Globals {
    target_px: vec2<f32>,
    scale: f32,
    unused: f32,
}

@group(0) @binding(0) var<uniform> g: Globals;
@group(0) @binding(1) var glyph_tex: texture_2d<f32>;
@group(0) @binding(2) var image_tex: texture_2d<f32>;
@group(0) @binding(3) var tex_sampler: sampler;

struct Instance {
    @location(0) rect: vec4<f32>,
    @location(1) clip: vec4<f32>,
    @location(2) color: vec4<f32>,
    @location(3) color2: vec4<f32>,
    @location(4) border_color: vec4<f32>,
    @location(5) radii: vec4<f32>,
    @location(6) uv: vec4<f32>,
    @location(7) params: vec4<f32>,
    @location(8) grad: vec4<f32>,
}

struct Varyings {
    @builtin(position) position: vec4<f32>,
    @location(0) @interpolate(flat) rect: vec4<f32>,
    @location(1) @interpolate(flat) clip: vec4<f32>,
    @location(2) @interpolate(flat) color: vec4<f32>,
    @location(3) @interpolate(flat) color2: vec4<f32>,
    @location(4) @interpolate(flat) border_color: vec4<f32>,
    @location(5) @interpolate(flat) radii: vec4<f32>,
    @location(6) @interpolate(flat) uv: vec4<f32>,
    @location(7) @interpolate(flat) params: vec4<f32>,
    @location(8) @interpolate(flat) grad: vec4<f32>,
}

const KIND_SHAPE: u32 = 0u;
const KIND_GRADIENT: u32 = 1u;
const KIND_SHADOW: u32 = 2u;
const KIND_IMAGE: u32 = 3u;
const KIND_GLYPH: u32 = 4u;
const KIND_BACKDROP: u32 = 5u;

const SHADOW_STEPS: i32 = 8;

@vertex
fn vs_main(@builtin(vertex_index) vertex: u32, inst: Instance) -> Varyings {
    var corners = array<vec2<f32>, 6>(
        vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 1.0),
        vec2<f32>(0.0, 1.0), vec2<f32>(1.0, 0.0), vec2<f32>(1.0, 1.0),
    );
    let s = g.scale;
    let kind = u32(inst.params.w) & 15u;
    var pad = 1.0;
    if kind == KIND_SHADOW {
        pad = pad + 3.0 * inst.params.y * s;
    }
    // Pixel bounds: the rect grown by the AA / shadow margin, cut to the clip.
    let lo = max(inst.rect.xy * s - vec2<f32>(pad), inst.clip.xy * s);
    let hi = min((inst.rect.xy + inst.rect.zw) * s + vec2<f32>(pad), inst.clip.zw * s);
    let px = mix(lo, max(lo, hi), corners[vertex]);
    var out: Varyings;
    out.position = vec4<f32>(px.x / g.target_px.x * 2.0 - 1.0, 1.0 - px.y / g.target_px.y * 2.0, 0.0, 1.0);
    out.rect = inst.rect;
    out.clip = inst.clip;
    out.color = inst.color;
    out.color2 = inst.color2;
    out.border_color = inst.border_color;
    out.radii = inst.radii;
    out.uv = inst.uv;
    out.params = inst.params;
    out.grad = inst.grad;
    return out;
}

fn erf_approx(x: f32) -> f32 {
    let s = sign(x);
    let a = abs(x);
    var y = 1.0 + (0.278393 + (0.230389 + (0.000972 + 0.078108 * a) * a) * a) * a;
    y = y * y;
    return s - s / (y * y);
}

fn gaussian(x: f32, sigma: f32) -> f32 {
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (2.5066283 * sigma);
}

// Radius of the corner of the quadrant `p` (centre origin, y down) lies in; radii are tl, tr, br, bl.
fn radius_at(p: vec2<f32>, r: vec4<f32>) -> f32 {
    if p.x < 0.0 {
        if p.y < 0.0 { return r.x; }
        return r.w;
    }
    if p.y < 0.0 { return r.y; }
    return r.z;
}

fn sd_round_box(p: vec2<f32>, hs: vec2<f32>, r: f32) -> f32 {
    let q = abs(p) - hs + vec2<f32>(r);
    return length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

// Gaussian-blurred rounded box along x for one scan line at offset y (closed form with erf).
fn blur_along_x(x: f32, y: f32, sigma: f32, corner: f32, hs: vec2<f32>) -> f32 {
    let delta = min(hs.y - corner - abs(y), 0.0);
    let curved = hs.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
    let k = 0.70710678 / sigma;
    let lo = 0.5 + 0.5 * erf_approx((x - curved) * k);
    let hi = 0.5 + 0.5 * erf_approx((x + curved) * k);
    return hi - lo;
}

fn shadow_value(p: vec2<f32>, hs: vec2<f32>, corner_in: f32, sigma_in: f32) -> f32 {
    let sigma = max(sigma_in, 0.01);
    let corner = min(corner_in, min(hs.x, hs.y));
    let low = p.y - hs.y;
    let high = p.y + hs.y;
    let start = clamp(-3.0 * sigma, low, high);
    let stop = clamp(3.0 * sigma, low, high);
    let dstep = (stop - start) / f32(SHADOW_STEPS);
    var y = start + dstep * 0.5;
    var value = 0.0;
    for (var i = 0; i < SHADOW_STEPS; i = i + 1) {
        value = value + blur_along_x(p.x, p.y - y, sigma, corner, hs) * gaussian(y, sigma) * dstep;
        y = y + dstep;
    }
    return value;
}

fn premul(c: vec4<f32>) -> vec4<f32> {
    return vec4<f32>(c.rgb * c.a, c.a);
}

@fragment
fn fs_main(in: Varyings) -> @location(0) vec4<f32> {
    let s = g.scale;
    let p = in.position.xy;
    if p.x < in.clip.x * s || p.x >= in.clip.z * s || p.y < in.clip.y * s || p.y >= in.clip.w * s {
        discard;
    }
    let kind = u32(in.params.w) & 15u;
    let origin = in.rect.xy * s;
    let size = in.rect.zw * s;
    let hs = size * 0.5;
    let rel = p - origin - hs;
    let opacity = in.params.z;
    let corner = min(radius_at(rel, in.radii) * s, min(hs.x, hs.y));

    if kind == KIND_SHADOW {
        let v = shadow_value(rel, hs, corner, in.params.y * s);
        let a = in.color.a * v * opacity;
        return vec4<f32>(in.color.rgb * a, a);
    }

    if kind == KIND_GLYPH {
        if p.x < origin.x || p.y < origin.y || p.x >= origin.x + size.x || p.y >= origin.y + size.y {
            discard;
        }
        let uv = mix(in.uv.xy, in.uv.zw, (p - origin) / size);
        let cov = textureSampleLevel(glyph_tex, tex_sampler, uv, 0.0).r;
        let a = in.color.a * cov * opacity;
        return vec4<f32>(in.color.rgb * a, a);
    }

    // Fill colour (premultiplied) of the shape kinds.
    var fill = premul(in.color);
    if kind == KIND_GRADIENT {
        let d = in.grad.zw - in.grad.xy;
        let len2 = dot(d, d);
        var t = 0.0;
        if len2 > 0.0 {
            t = clamp(dot((p - origin) / size - in.grad.xy, d) / len2, 0.0, 1.0);
        }
        fill = mix(premul(in.color), premul(in.color2), t);
    } else if kind == KIND_IMAGE {
        let uv = mix(in.uv.xy, in.uv.zw, (p - origin) / size);
        fill = premul(textureSampleLevel(image_tex, tex_sampler, uv, 0.0) * in.color);
    }

    let cov_outer = clamp(0.5 - sd_round_box(rel, hs, corner), 0.0, 1.0);
    var result = fill * cov_outer;
    let bw = in.params.x * s;
    if bw > 0.0 {
        var cov_inner = 0.0;
        let inner = hs - vec2<f32>(bw);
        if inner.x > 0.0 && inner.y > 0.0 {
            cov_inner = clamp(0.5 - sd_round_box(rel, inner, max(corner - bw, 0.0)), 0.0, 1.0);
        }
        let ring = premul(in.border_color) * max(cov_outer - cov_inner, 0.0);
        result = ring + result * (1.0 - ring.a);
    }
    return result * opacity;
}
