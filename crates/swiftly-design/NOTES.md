# Notes: design file against kit

Checked on 2026-11-08: `App/design/Swiftly Player.isd` (232 variables) against `data/system.json` (kit 1.1,
snapshot of 2026-11-02).
The test `tests/cross_check.rs` fails when this list changes.

## The design file has no layout modes

- Two collections, `Color` (31 variables) and `Size` (201), each with one mode `Mode 1`. There is no `Mobile` mode
  and no per-mode value.
- The layout sets are in the variable names: `size/JerkKind/*` and `size/of/*` = touch (iPhone), `size/BodyShell/*` =
  desktop (Mac), `size/PressButton/*` = tv (Apple TV). The group names are odd, so this mapping was derived from
  the values (poster 116x174 / 150x225 / 208x312, page margin 18 / 36, title tracking -0.7 / -0.5 / -1.176).
- Feature groups were placed by value: `DetailPageMetric` -> desktop (hero image 454, left 36), `PlayerMetric` and
  `SearchLayout` -> tv (safe width 1760, button 88), `TimeSlider`, `Theme`, `HeroRunOut`, `TabStillTimesKey` -> `common`.
  An unknown group makes the generator stop, so a new group in the file has to be placed on purpose (`group_target`).
- The generator rejects a collection with more than one mode: that case would need a decision about the mapping.

## Differences between the design file and the kit (not resolved here)

| Token | Design file | Kit (`system.json`) | Code in `App/Sources` |
|---|---|---|---|
| Section title tracking, touch | `of/lockSection` = -0.484 -> `touch::LOCK_SECTION` | `type.section.ios.tracking` = -0.308 -> `touch::text::SECTION.tracking` | `Shared/Style.swift:493` `lockSection = -0.484` (its comment says "-0,014 em", which would be -0.308) |
| Section title tracking, desktop | `BodyShell/lockSection` = -0.484 -> `desktop::LOCK_SECTION` | `type.section.macos.tracking` = -0.484 -> `desktop::text::SECTION.tracking` (corrected to the Mac code, 09.11.; the iOS row stays -0.308) | `macOS/Style.swift:325` `lockSection = -0.484` |

Both values are generated, under different names, and the generator does not choose. The code agrees with the design file;
the kit probably took -0.308 from the comment. A Rust UI should read one of them on purpose and the kit should be corrected.
All other tokens quoted in apple-screens.md section 1 that exist in both agree (colours, spacing, radii, poster, landscape, hero,
tracking, window, sidebar, toolbar).

## Needed by the code, missing from the design file

These values are in `system.json` / apple-screens.md but not among the 232 variables. They are not generated (no second source of
numbers); add them to the design file or decide to take them from the kit.

- tv: page margin 80, header top 60, sheet inset 24, group top 36, settings columns 72, radii (small 14, control 16, tile 18, card 16, area 24),
  row height 84, progress bar 8, toggle 84x50x40, search key 64
- desktop: grid row 24, group top 18, card gap 14, panel radius 12, row 52 (the file has the sidebar row 32 as `row_height`), chip 30, toggle 38x22x16
- touch: separator inset 34, primary button 56, chip 30, player icon 44, toggle 46x28x22, episode card 600 (all sets)
- colour: `focusArea` (tvOS, white 12%), tvOS `selectedSection` (accent 15% / focused 26%), TV focus fill (white with ground text)
- Not variables at all, so taken from `system.json`: the type ladder (39 styles over the three sets), shadows (6), motion curves (24).
  Motion entries that are free text are not generated; they are listed in the header of `src/tokens.rs`
  (press, focus, section, push, expand, toggle on tv, back drop, controls fade, alphabet rail).

## Other observations

- `colour/originalAccent` and `colour/markAccent` have the same value (teal #50D5DA); the active Look overrides the accent at run time
  (architecture D2), so `colour::ORIGINAL_ACCENT` is the default, not a fixed truth.
- `colour/keyColor` equals `fontVeryQuiet` (#989898).
- The design file has a nearly empty group `TabStillTimesKey` (`defaultValue` 0.0); it is kept as `common::TAB_STILL_TIMES_KEY_DEFAULT_VALUE`.
- Sizes are `f32` for everything, including counts (`GRID_COLUMNS` = 7.0) and durations (`DURATION_PAGES_PUSH` = 0.45 s).
