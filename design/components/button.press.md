# button.press

Press feedback for every other tappable thing: icon buttons, rows, text (scale 0.97 or dim, no layout change).

## Use when

As the ButtonStyle of any tappable that is not one of the named buttons.

## Do not use when

Full-width rows: they dim, they do not shrink (PressRow).

## Props

- `variant: button (scale + opacity), row (dim only), text`

## States

| State | Look |
|---|---|
| default | rest |
| pressed | button: scale 0.97 and opacity 0.85 (TV opacity 1); row: dim |
| hover | desktop: motion.quick |

## Tokens

| Token | Where |
|---|---|
| `state.pressed-scale` | scale |
| `state.pressed-opacity` | opacity |
| `motion.instant` | press down |
| `motion.quick` | release |

## Platform files

- Swift: Theme.PressButton / PressRow / PressText (Sources/Shared/Style.swift:95-117; Sources/macOS/Style.swift:41,63)
- Kotlin: pressMass (Android/shared/src/main/java/de/paulherter/swiftly/shared/Style.kt) with MutableInteractionSource
- Rust: press feedback in widgets (crates/swiftly-ui/src/feel.rs, crates/swiftly-ui/src/interact.rs)

Sets: touch, desktop, tv.
