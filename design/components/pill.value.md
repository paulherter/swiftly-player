# pill.value

Small capsule with a glyph and a value (Abspielen, sort order, season).

## Use when

A single action or value that is not a filter.

## Do not use when

Filters (chip.filter).

## Props

- `symbol`
- `text`
- `perform`

## States

| State | Look |
|---|---|
| default | surface.control, text.primary |
| pressed | button.press |
| focused | TV: state.focus-fill |

## Tokens

| Token | Where |
|---|---|
| `surface.control` | fill |
| `radius.pill` | shape |
| `size.chip-height` | height |
| `text.primary` | glyph and text |
| `state.focus-fill` | TV focus |
| `state.pressed-scale` | press |

## Platform files

- Swift: ValuePill (Sources/Shared/Style.swift:3866); SeasonPill (Sources/macOS/SeriesView.swift:553, Sources/tvOS/TVComponents.swift:1620)
- Kotlin: ValuePill (Android/phone/src/main/java/de/paulherter/swiftly/PageComponents.kt:391)
- Rust: value_pill (crates/swiftly-desktop/src/browse.rs:606)

Sets: touch, desktop, tv.

## Local sizes (no layout token yet)

- min height: 30 dp (Theme.pillsHeight, = size.chip-height touch)

## Deviations seen (not fixed here)

- Rust TV value_pill rests on a raw white 10% fill (Color::new(1,1,1,0.10)) and radius 999 literal; no token names that 10%.
- Rust desktop value_pill uses radius 15.0 literal instead of radius.pill.
