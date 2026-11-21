# bar.player

Glass capsule with the player's bar buttons.

## Use when

Controls over the picture while a title plays.

## Do not use when

Anything without a material under it.

## Props

- `buttons`
- `active`
- `open`

## States

| State | Look |
|---|---|
| default | scrim.glass plate |
| focused | TV: state.focus-fill |
| active | glyph highlighted |

## Tokens

| Token | Where |
|---|---|
| `scrim.glass` | plate |
| `scrim.glass-edge` | hairline |
| `text.primary` | glyphs |
| `state.focus-fill` | TV focus |
| `motion.controls-fade` | fade in/out |

## Platform files

- Swift: TVBarCapsule, TVBarHalf (Sources/tvOS/TVPlayerMenus.swift:506,474)
- Kotlin: BarCapsule (Android/phone/src/main/java/de/paulherter/swiftly/PlayerMenus.kt:533); TvBarCapsule (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvPlayerMenus.kt:365)
- Rust: none

Sets: touch, desktop, tv.
