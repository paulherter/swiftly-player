# swipe.row

Row that reveals an action when swiped sideways (touch).

## Use when

Quick row actions on touch (Entfernen).

## Do not use when

Desktop and TV (use the tile menu).

## Props

- `symbol`
- `text`
- `color`
- `perform`

## States

| State | Look |
|---|---|
| default | rest |
| dragging | action plate follows the finger |
| pressed | PressRow |

## Tokens

| Token | Where |
|---|---|
| `accent.selection` | default action colour |
| `state.error` | destructive action |
| `surface.base` | glyph on the plate |

## Platform files

- Swift: SwipeRow (Sources/Shared/Style.swift:3608)
- Kotlin: SwipeRow (Android/phone/src/main/java/de/paulherter/swiftly/PageComponents.kt:568)
- Rust: none

Sets: touch.
