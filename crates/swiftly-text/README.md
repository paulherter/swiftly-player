# swiftly-text

Text for the shared Swiftly Rust UI (Windows, Linux, Android, Android TV): fonts, shaping, layout, glyph atlas.

| Piece | What it is |
|---|---|
| `FontSystem` | Font database plus shaping scratch space. Registers the bundled Inter (`fonts/InterVariable.ttf`, SIL OFL 1.1, licence in `fonts/OFL.txt`) and discovers system fonts through fontique. Missing glyphs (Arabic, Hebrew, CJK) fall back to system fonts by script. `FontSystem::bundled_only()` skips the system for deterministic tests. |
| `TextStyle` | Size, weight, tracking, capitals, line height, optical size. `TextStyle::from(swiftly_design::TextStyle)` takes a type-ladder step. Line height defaults to the font's own (matches Core Text); optical size defaults to the point size (matches Core Text). |
| `FontSystem::layout(text, &style, max_width, max_lines, align) -> TextLayout` | parley: shaping, bidi, line breaking (CJK too), ellipsis (U+2026) after `max_lines`, alignment. Measured in points, independent of the device scale. |
| `TextLayout` | `size()`, `lines()`, `truncated()`, `hit_test(x, y)`, `caret_rect(index, width)`, `selection_rects(range)`, `missing_glyphs()`. Byte indices refer to `text()` (capitalised and ellipsised). |
| `GlyphAtlas` | swash rasterises outlines to R8 coverage into a shelf-packed page. Implements `swiftly_render::Atlas` (dirty rectangle). `draw(&layout, &mut list, x, y, colour)` emits `Glyph` quads at the list's scale. |

```rust
let mut fonts = FontSystem::new();
let mut atlas = GlyphAtlas::new(1024);
let t = fonts.layout("Frieren", &touch::text::CATEGORY.into(), Some(116.0), Some(2), Align::Start);
atlas.begin_frame();                                   // once per frame
atlas.draw(&t, &mut list, x, y, Color::WHITE);         // list = DrawList with the device scale
// renderer: take_dirty() on the atlas, upload that rectangle only
```

Decisions (subpixel quarter pixels, baseline rounded, no hinting, R8 only, why swash) are at the top of `src/atlas.rs`.
Measured numbers, comparison with Core Text and open points: `NOTES.md`.

## Tests

```
cargo test -p swiftly-text                      # goldens, measurement, hit-test, atlas
UPDATE_GOLDENS=1 cargo test -p swiftly-text     # rewrite tests/golden/*.png
cargo run --release -p swiftly-text --example measure
swiftc -O tools/coretext_widths.swift -o /tmp/ct && /tmp/ct fonts/InterVariable.ttf   # Core Text widths (Mac)
```

The Latin goldens use only the bundled Inter. `arabic_hebrew.png` and `japanese.png` use the system fonts of the Mac that
made them and are compared on macOS only; the tests skip with a printed note when a script has no fallback font.
