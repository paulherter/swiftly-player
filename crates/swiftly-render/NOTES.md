# swiftly-render notes

## Measured (Mac, Apple M1 Max, Metal, release build, 5000 mixed quads on 1280x720 at 1x)

Scene: `many_quads(5000)` in `tests/common/mod.rs` (fills, bordered, gradients, images, shadows, random overlap).
Run: `cargo test -p swiftly-render --release -- --ignored --nocapture bench`.

| Path | Time per frame |
|---|---|
| SoftwareRenderer (1 thread) | 740 ms |
| WgpuRenderer, instance upload + draw + wait for the GPU | 3.4 ms |
| WgpuRenderer, same + readback to CPU | 5.2 ms |

Software is slow on purpose (oracle, no tiling or threads; the 1000 shadow quads with an 8-step erf integral dominate).
It renders every golden scene in a few milliseconds.

## Software vs wgpu

| Scene | Max difference | Pixels that differ |
|---|---|---|
| poster (1x) | 1 level | 0.11 % |
| pill_button (2x) | 1 level | 1.2 % |
| card_shadow (2x) | 1 level | 0.30 % |
| card_shadow (1.5x, BGRA target) | 1 level | 0.46 % |
| gradient_bar (2x) | 1 level | 0.03 % |
| glyphs_and_clip (1x) | 1 level | 0.72 % |
| 5000 quads (heavy overlap) | 2 levels | 28 % (rounding of 8-bit blending vs float buffer) |

The test asserts at most 4 levels. The goldens (`tests/golden/*.png`) come from the software renderer; the golden test
allows 1 level (libm differences between machines).

## Decisions

- Instance is 144 bytes (nine `vec4`), not 80: per-corner radii, a second colour, border colour and a gradient line do
  not fit in 80. Read as vertex attributes, so the pipeline needs no storage buffers (GL ES 3, older Android).
- Shadow: gaussian with sigma = blur / 2 (SwiftUI `radius`), closed form: erf across x, 8 sample lines across y
  (the method of GPUI/Zed). A shadow uses the radius of the corner nearest the pixel. The shadow is not knocked out
  under the casting shape; draw the shape on top.
- Edges: coverage = clamp(0.5 - signed distance) at the pixel centre. Integer-aligned rects fill exactly.
- Border is inside the shape; the fill continues under it, the border blends over the fill.
- Gradients interpolate premultiplied. Two stops only.
- Group opacity: `push_opacity` multiplies each quad's alpha and flags it (`grouped`). Correct unless quads of the group
  overlap each other.
- wgpu 30.0.1 pinned with `=`, default features off except `std`, `parking_lot`, `wgsl`, `metal`, `vulkan`, `gles`, `dx12`.
  `GpuContext::headless()` asks for downlevel limits plus the adapter's texture size.
- No `unsafe` anywhere.

## Open

- Backdrop blur (`QuadKind::BackdropBlur`): three box passes (software). `WgpuRenderer::render_to_image` and
  `render_to_surface` render a list that holds glass with the software renderer and upload the picture (`write_texture`),
  so the pixels are identical on Metal, Vulkan and GL. The bare `draw(view)` still draws the tint only. A native GPU blur
  needs a render-to-texture detour per glass quad; not done.
- True group opacity with overlapping children (offscreen group texture).
- More than two gradient stops; radial gradients.
- `GpuContext::surface_config` and `WgpuRenderer::render_to_surface` compile but are not exercised: there is no window
  in the tests. Try them in the desktop shell (and on the Android surface).
- Only Metal was run here. Vulkan, DX12 and GL must be run once on the Windows PC, Linux and the Android emulator
  (the test prints `SKIP` without an adapter and the adapter name otherwise).
- One glyph page and one image page per renderer. Several image pages (icon page next to the poster page) come when
  the image cache design is fixed.
- Software renderer could use threads/tiles if the goldens get large.
- The root `Cargo.lock` has not been updated by this work: it was built in a private workspace because other crates were
  being added at the same time. The first `cargo build` in the worktree adds wgpu 30.0.1, png 0.18.1, pollster 1.0.1.
