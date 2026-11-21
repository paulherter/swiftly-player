# pill.offering

Skip intro / next episode pill over the player.

## Use when

Time-bound player offers (Intro überspringen, Nächste Folge).

## Do not use when

Permanent controls.

## Props

- `art`
- `text`
- `share (countdown)`
- `seconds?`

## States

| State | Look |
|---|---|
| default | glass capsule |
| focused | TV: state.focus-fill |
| running | countdown fill |

## Tokens

| Token | Where |
|---|---|
| `scrim.glass` | glass behind |
| `scrim.glass-edge` | glass edge |
| `text.primary` | text |
| `state.focus-fill` | TV focus |
| `motion.controls-fade` | fade |

## Platform files

- Swift: OfferingButton (Sources/macOS/PlayerScreen.swift:2551); OfferingBadge (Sources/tvOS/TVShared.swift:13); OfferingRow (Sources/macOS/MacShared.swift:81)
- Kotlin: OfferingPill (Android/phone/src/main/java/de/paulherter/swiftly/PlayerPage.kt:2854); TvOfferingPill (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvPlayer.kt:803)
- Rust: none

Sets: touch, desktop, tv.
