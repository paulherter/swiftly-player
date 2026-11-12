# swiftly-text notes

## Stack and why

- parley 0.12.0 (layout, bidi, line breaking, caret/selection geometry), fontique 0.12 through parley (system font
  discovery and script fallback), swash 0.2.10 (outline rasteriser, variable fonts). All Apache-2.0 OR MIT.
- swash over the alternatives: `ab_glyph` and `fontdue` ignore variable-font coordinates (Inter is one variable file),
  `skrifa` alone has no rasteriser, FreeType is C and needs `unsafe`. No `unsafe` in this crate.
- Inter 4.1 variable (`fonts/InterVariable.ttf`, 880 KB, copy of `Linux/Resources/Fonts/`) is compiled in with
  `include_bytes!`; licence SIL OFL 1.1 next to it (`fonts/OFL.txt`). Only the upright variable file is bundled, not the
  italic or the static SemiBold (those are for the Linux shell and libVLC subtitles).
  The driver should add the font and the OFL to `THIRD-PARTY-NOTICES.md` / `LICENSES` for the Rust UI binaries.

## Decisions

- Layout is in points at scale 1, unquantised; the device scale is applied only when rasterising (glyph size and
  positions times the scale). Line breaks and measurements are the same on every density, like Core Text.
- Subpixel: 4 horizontal bins (quarter pixel, round to nearest), baseline rounded to a whole device pixel, no hinting.
- Line height default = the font's own (ascent + descent + gap of Inter, 1.21 em): identical to Core Text
  (20.569 pt at 17 pt, 26.619 pt at 22 pt).
- Optical size: the `opsz` axis is set to the point size by default. Core Text does the same for this font: with
  `opsz = size` the widths match Core Text within 0.06 pt; without it they are 1.6 % (17 pt) to 4 % (22 pt) too wide.
- Ellipsis: U+2026, cut at character level (as SwiftUI tail truncation), binary search for the longest prefix of the
  last allowed line that fits with the ellipsis. With `max_lines` set, long words break anywhere instead of overflowing.
- Tracking is dropped for text containing Arabic-script characters (it would break the joins).
- Atlas: one R8 page (default 1024x1024), shelf packing, 1 px zero gutter. When the page is full the glyphs of that
  frame are dropped and `begin_frame()` clears the cache next frame (no mid-frame invalidation of quads already emitted).
  The page never grows because the renderers mirror a fixed texture; use 2048 on TV or 4K.
- Colour glyphs (emoji) are not rendered (R8 page): they are skipped.

## Core Text comparison (Mac, `tools/coretext_widths.swift`, Inter Variable file registered in the process)

Widths in points, tracking 0, weight 400 | 600. Core Text / this crate (`opsz` automatic).

| Size | String | Core Text | swiftly-text |
|---|---|---|---|
| 17 | Swiftly Player | 106.861 \| 110.757 | 106.864 \| 110.766 |
| 17 | Größe, Übergänge und Ärger | 229.912 \| 234.404 | 229.890 \| 234.422 |
| 17 | Frieren: Beyond Journey's End | 242.833 \| 248.752 | 242.831 \| 248.758 |
| 22 | Swiftly Player | 134.651 \| 140.573 | 134.653 \| 140.572 |
| 22 | Größe, Übergänge und Ärger | 290.545 \| 297.699 | 290.555 \| 297.655 |
| 22 | Frieren: Beyond Journey's End | 306.240 \| 315.272 | 306.238 \| 315.219 |

The Swift sources contain no such numbers (the app measures at run time), so the Core Text column comes from a script
that loads the same font file with `CTFontManagerRegisterFontsForURL` and asks `CTLineGetTypographicBounds`. The test
`widths_match_core_text_within_a_tenth_of_a_point` pins them. **Still to compare on the iPhone:** SwiftUI `Text` with
`.custom("Inter Variable", fixedSize:)` is expected to equal Core Text; check once with the same three strings in a debug
view (UIKit/SwiftUI could differ in rounding of the line, not in advances).

## Measured (Mac, Apple M1 Max, release; `cargo run --release -p swiftly-text --example measure`)

The machine was under load from other builds (load average above 20), so read these as upper bounds.

| What | Time |
|---|---|
| Layout of 200 short strings (13 pt, 116 pt wide, max 2 lines, mixed 1 to 4 words) | 1.65 ms, 8.2 us each (best of 5) |
| `FontSystem::new` + first layout (system font scan, Inter registration) | about 40 to 55 ms, once at start |
| Cold atlas: 200 of those strings at 2x (84 distinct glyph images) | 0.95 ms, 11.4 us per glyph image |
| Same 200 strings with a warm atlas (cache hits, quad emission) | 0.12 ms |

A frame of a poster grid (about 30 labels) therefore costs well under 1 ms of text work when warm.

## Scripts checked on this Mac

- Latin and German: Inter only, goldens are machine independent.
- Arabic (`مرحبا بكم في تطبيق سويفتلي`): fallback found (Core Text), shaped and joined, paragraph RTL, caret and
  hit-test run right to left. Hebrew (`שלום עולם`): fallback found.
- Japanese: fallback found; a long run without spaces breaks inside the run at the given width.
- In the Japanese golden the kana come out heavier than the kanji at weight 600: fontique picks different system fonts
  per script run. Not a bug of this crate; it goes away once a fixed CJK font is bundled or chosen by name.

## Open / leftovers

- P2: no Noto Arabic, Hebrew or CJK is bundled. Windows, Linux (fontconfig) and Android (system fonts) must be
  checked on the device; `missing_glyphs()` tells the UI when a script has no font. Architecture D2 plans Noto Arabic and
  Hebrew in the bundle; add them with `FontSystem::register_font`.
- The Arabic/Japanese goldens are compared on macOS only (system fonts differ elsewhere).
- Parley's Arabic shaping is checked by eye only (A4); no diacritics, no mixed-direction digits test.
- Locale-aware line breaking (`Locale` for ja/zh) is not set; parley guesses from the script.
- No text editing state yet (selection anchor, IME composition); `hit_test`, `caret_rect`, `selection_rects` are the base.
- Colour emoji (R8 page) and underline/strikethrough are not drawn. No inline boxes or rich spans (one style per layout).
- Atlas page does not grow; no per-frame eviction of single glyphs (whole clear when full).
- Not run through `WgpuRenderer`: only the software renderer (oracle) draws the goldens here; the atlas follows the
  `Atlas` trait, `take_dirty()` is tested.
- The root `Cargo.lock` gained parley, fontique, swash and their dependencies from the first build; the driver commits it.
