// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// The video layer: one textured rectangle drawn under the UI quads. Colour is copied as code values (the video is
// already in display space; HDR tone mapping happens in mpv).

struct Place {
    // left, top, right, bottom in clip space
    rect: vec4<f32>,
}

@group(0) @binding(0) var<uniform> place: Place;
@group(0) @binding(1) var frame_tex: texture_2d<f32>;
@group(0) @binding(2) var frame_sampler: sampler;

struct Varyings {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

@vertex
fn vs_main(@builtin(vertex_index) vertex: u32) -> Varyings {
    var corners = array<vec2<f32>, 6>(
        vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 1.0),
        vec2<f32>(0.0, 1.0), vec2<f32>(1.0, 0.0), vec2<f32>(1.0, 1.0),
    );
    let c = corners[vertex];
    let p = vec2<f32>(mix(place.rect.x, place.rect.z, c.x), mix(place.rect.y, place.rect.w, c.y));
    var out: Varyings;
    out.position = vec4<f32>(p, 0.0, 1.0);
    out.uv = c;
    return out;
}

@fragment
fn fs_main(in: Varyings) -> @location(0) vec4<f32> {
    return vec4<f32>(textureSample(frame_tex, frame_sampler, in.uv).rgb, 1.0);
}
