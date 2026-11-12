# swiftly-render

Drawing foundation of the shared Swiftly Rust UI (Windows, Linux, Android, Android TV).

| Piece | What it is |
|---|---|
| `DrawList` / `DrawQuad` | Quads in painter's order. Coordinates in points, plus a scale factor (pixels per point). Kinds: `Shape` (per-corner radii, inside border), `Gradient` (linear, two stops), `Shadow` (analytic gaussian), `Image` (atlas region, rounded, tinted), `Glyph` (R8 coverage), `BackdropBlur` (declared, tint only, logs once). Clip stack and group opacity (`push_opacity`). |
| `SoftwareRenderer` | Pure CPU reference, `f32`, pixel centres. Oracle of the goldens. `RgbaImage` writes and reads PNG. |
| `WgpuRenderer` | One instanced draw, WGSL (`src/quad.wgsl`), 144-byte instances as vertex attributes (so GL ES 3 works). Offscreen with readback, or onto a surface. `GpuContext::headless()` opens Vulkan, DX12, Metal or GL. |
| `Atlas` | Trait of the glyph and image pages (`size`, `format`, `pixels`, `take_dirty`); `PixelPage` is a plain implementation. Text shaping and rasterising come in a later crate. |

Rules: blending in sRGB code values (premultiplied over), targets are non-sRGB formats, no `unsafe`, no `unwrap` outside tests.

```rust
let mut list = DrawList::new(140.0, 198.0, 2.0);      // points, 2 pixels per point
list.shadow(card, ShadowStyle { color, dx: 0.0, dy: 14.0, blur: 17.0, spread: 0.0 }, 16.0);
list.fill(card, color, 16.0);
list.stroke(card, edge, 1.0, 16.0);
let png = SoftwareRenderer::render(&list, clear, &Sources::default()).to_png()?;
```

## Tests

```
cargo test -p swiftly-render                      # unit tests, goldens, wgpu vs software (skips with a note without a GPU)
UPDATE_GOLDENS=1 cargo test -p swiftly-render     # rewrite tests/golden/*.png
cargo test -p swiftly-render --release -- --ignored --nocapture bench
```

Fixture scenes (poster tile, pill button, card with shadow, gradient bar, glyphs and clip) live in `tests/common/mod.rs`
and use the values of `swiftly-design`. Measured numbers and open points: `NOTES.md`.
