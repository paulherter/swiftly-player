# slider.time

Player seek bar with time labels.

## Use when

Seeking in a title.

## Do not use when

Progress on tiles (progress.bar).

## Props

- `position`
- `duration`
- `onSeek`
- `chapters?`

## States

| State | Look |
|---|---|
| default | thin track |
| dragging | bar grows, preview |
| focused | TV: state.focus-fill thumb |

## Tokens

| Token | Where |
|---|---|
| `text.primary` | played part and thumb |
| `scrim.glass` | track plate |
| `motion.controls-fade` | controls fade |
| `caption.small` | time labels |

## Platform files

- Swift: TimeSlider (Sources/Shared/Style.swift:1815; Sources/macOS/PlayerScreen.swift:2325); TimeRow (Sources/macOS/PlayerScreen.swift:2274)
- Kotlin: TimeRow (Android/phone/src/main/java/de/paulherter/swiftly/PlayerPage.kt:2516); TvTimeBar (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvPlayer.kt:832)
- Rust: seek bar in player_screen (crates/swiftly-desktop/src/player_screen.rs)

Sets: touch, desktop, tv.

## Deviations seen (not fixed here)

- Colours of track and thumb were not checked against tokens; entry lists intent from DESIGN.md.
