# button.icon

Round or square icon-only button, often dark over an image (back, close, more).

## Use when

One glyph, no label, over a picture or a bar.

## Do not use when

Text actions; targets under 44 pt on touch.

## Props

- `glyph`
- `label (accessibility)`
- `size`
- `scrimmed (dark round plate)`

## States

| State | Look |
|---|---|
| default | glyph on scrim.button |
| pressed | button.press |
| focused | TV: state.focus-fill, dark glyph |
| disabled | state.disabled-opacity |

## Tokens

| Token | Where |
|---|---|
| `scrim.button` | round plate over images |
| `text.primary` | glyph |
| `state.disabled-opacity` | disabled |
| `state.focus-fill` | TV focus |
| `state.pressed-scale` | press |

## Platform files

- Swift: BackButton (Sources/Shared/Style.swift:1056); IconButton (Sources/macOS/PlayerLayers.swift:67); DetailIconButton (Sources/macOS/DetailView.swift:1052)
- Kotlin: PlayerCloseButton (Android/phone/src/main/java/de/paulherter/swiftly/PlayerMenus.kt:555)
- Rust: none

Sets: touch, desktop, tv.

## Deviations seen (not fixed here)

- No shared icon-button type on any platform: each screen draws its own plate and size.
