# swiftly-design

Design tokens for the Swiftly Rust UI: colours, sizes, type ladder, shadows and motion, as typed `const`s.

```rust
use swiftly_design::tokens::{colour, tv, touch};
let area = colour::AREA;                 // r/g/b/a as f32 and rgba8 = 0x262626FF
let margin = touch::EDGE_SPACING;        // 18.0
let poster = (tv::POSTER_WIDTH, tv::POSTER_HEIGHT); // 208 x 312
let title = touch::text::TITLE_LARGE;    // TextStyle { size: 34.0, weight: 700, tracking: -0.7, .. }
```

Modules in `tokens`: `colour`, `common` (same for all sets), `touch`, `desktop`, `tv`. Inside a layout set:
the size constants, `text` (type ladder), `shadow` and `motion`. How the layout sets map to the design file
is explained in the header of `src/tokens.rs` and in `NOTES.md`.

## Files

| File | What |
|---|---|
| `src/tokens.rs` | Generated, committed. Never edit by hand. |
| `generated/Tokens.swift` | Generated, committed. Same values for the Apple UIs (`Tokens.Touch.tileWidth`, `Tokens.Colour.area`). |
| `src/types.rs` | `Colour`, `TextStyle`, `Shadow`, `Curve`, `LayoutSet`. |
| `src/bin/gen_tokens.rs` | The generator. |
| `data/system.json` | Snapshot of `~/Documents/Design-Kits/swiftly/tokens/system.json` (type ladder, shadows, motion; cross-check). |
| `NOTES.md` | Differences between the design file and the kit, and what the design file lacks. |

## Regenerate

```sh
export PATH=$HOME/.cargo/bin:$PATH
cargo run -p swiftly-design --bin gen_tokens -- \
  --isd "/Users/paul/Documents/Swiftly/App/design/Swiftly Player.isd" \
  --out-rs crates/swiftly-design/src/tokens.rs \
  --out-swift crates/swiftly-design/generated/Tokens.swift
```

`--system <file>` uses another kit file (default `data/system.json`); `SWIFTLY_ISD` can replace `--isd`.
After the kit changes: copy `system.json` to `data/system.json`, then regenerate.

## Check (becomes `cargo xtask check`)

Add `--check` to the same command. It regenerates in memory and exits with 1 when a committed file differs,
with 2 on an input error. The test `committed_files_are_up_to_date` does the same and skips when the design file is absent
(set `SWIFTLY_ISD` if it is not at `../../../App/design/Swiftly Player.isd` relative to the crate).

The design file is a zip; only `document.json` is read in memory (keys `variables`, `variable_collections`), nothing is extracted.
