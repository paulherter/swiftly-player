# swiftly-ui notes

## Measured here

- `frame(now)` for the poster rail (release build, M1 Max, headless, DrawList only, no rendering, 100 000 items declared):
  0.006 ms at rest, 0.010 ms per frame while flinging (89 frames, 5 items built). Rendering is not included.
- 64 tests and one doctest: 40 layout (SwiftUI rules), 20 UI behaviour with touch traces (offset, press, long press, edge pan, rebuild
  state, windowing, draw list content, three goldens), 4 animation unit tests (a doctest more in layout).

## Estimated (no source; all in `src/tuning.rs` or noted here)

- Press values 0.97 / 0.85, release ease-out 0.12 s, press-in on the first frame (instant), 150 ms delay inside scroll views
  (a 2010 Apple mailing-list value), cancel at > 10 pt (WWDC18: "usually 10 points", known). Long press 0.5 s is Apple's default.
- A scroll starts at the point where the pan is recognised (no jump by the 10 pt hysteresis); the real app may add the 10 pt.
- Axis lock (along >= across), edge strip 20 pt, lazy overscan 64 pt, tile title gap 8 pt, two title lines, rail header gap 12 pt,
  button label padding 24 pt, title colour white, rail snapping on (checklist 7 implies it).
- A tap inside a scroll view that ends before 150 ms flashes the press (jump to 0.97, ease back over 0.12 s).
- Size classes: phone width regular from 900 pt. The research text says "~700" but its own table makes iPhone landscape
  (~852) compact, so 900 is used. Pad compact below 0.4 of the screen width.
- Scroll physics are `swiftly-motion`'s (0.998, rubber band 0.55, snap projection with 0.99, back spring 0.45 s, release
  velocity: least squares over 100 ms); a rail snaps to `round(projected / (116 + 12)) * 128`.
- Layout defaults (spacing 8, spacer 8, flexible frame rule): `../swiftly-layout/NOTES.md`.

## Known simplifications

- Press scale moves and scales shapes and images about the node centre; glyphs move with it but keep their size (the
  glyph atlas draws at the layout size).
- Group opacity fades each quad on its own (render crate limit); overlapping quads inside a pressed tile (poster and its edge)
  show a small double-blend at the rim.
- `Paint::Shadow` exists but no component uses it yet. Clips are rectangular (poster corners come from the image quad).
- One touch at a time; no pinch, double tap, hover, focus, keyboard, AccessKit tree.

## G1 checklist: what to compare against the real iPhone app (research-feel.md, items 1-11)

1. Refresh, 120 Hz, no dropped frames: needs the Pixel (90/120 Hz) and Instruments on the iPhone. We only know the CPU cost above.
2. Fling distance: 2000 pt/s should travel ~999 pt on a free list (`swiftly-motion` test). Compare the same flick on the old
   app's rail with the same finger speed (+-5 %). Also check that our release velocity (100 ms least squares) equals what the
   old app gets; the snapping rail uses the 0.99 projection, so a 3000 pt/s flick ends 4 items on (offset 512 in the test).
3. Fling duration ~3.8 s and a clean stop (free list): look at the last pixels of motion.
4. A touch stops the fling on the same frame, no jump, no tap: covered by a test; check by hand that no highlight flashes.
5. Rubber band: 100 pt pull -> 51.7 pt, 200 pt -> 97.4 pt for d = 852. Our rail uses its own width (390) as `d`, so the
   numbers differ there: 130 pt of finger past the edge shows 60.4 pt. Check that the old app uses the viewport length along the axis.
6. Bounce-back: no overshoot, under ~0.5 s, starts with the finger's velocity (spring 0.45 s is estimated).
7. Poster row snap: does the old rail snap at all? Which item ends at the left edge (we land with the item at the 18 pt margin)?
8. Spring check (`.smooth` ~0.7 s, `.snappy` 15 %, `.bouncy` 30 %): covered in `swiftly-motion`; `Node::scaled/opacity` drive it.
9. Interrupt keeps the velocity: covered by a rebuild test (no kink); tap during a spring on the device.
10. Press: 0.97 / 0.85, <= 1 frame outside scroll views, ~150 ms inside, cancel at 10 pt, release 0.12 s: record the old app at
    240 fps and fit the five numbers in `tuning.rs`.
11. Push (~0.35 s, parallax, edge-swipe back): **not built here**. Only the edge pan gesture (progress as a share of the width,
    release velocity) exists; the `nav` module is open.

## Open

- `tuning.toml` hot reload in debug builds and the xtask lint against duration/spring literals outside `tuning.rs`
  (`Motion::EaseOut(0.3)`-style literals in tests are fine; components use `tuning`).
- `nav` (push, interactive back), `sheet`, `focus` (tv), `a11y`, pinch, double tap, hover; wheel/trackpad phases for desktop.
- A vertical page `ScrollView` with pull-to-refresh, scroll indicators, scroll-into-view, safe-area content insets.
- Expose `AdaptiveGrid` as a UI node (layout has it, tested); lazy lists of different item sizes in the UI.
- Press scale of glyph sizes; offscreen group opacity; rounded clips; GPU run of the goldens (software only here).
- `swiftly-design` has no touch colour for the tile title or caption (white used); the generator's `TILE_BORDER` is 8 % white.
- A second verification run in the real workspace: while this was built, `crates/swiftly-plex` had no sources, so the
  tests ran in a private workspace that links the same sources (same lints, same lock).
