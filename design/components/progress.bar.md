# progress.bar

Thin progress bar on tiles and rows.

## Use when

Watched share on a tile or row.

## Do not use when

Player seek bar (slider.time).

## Props

- `share (0 to 1)`

## States

| State | Look |
|---|---|
| default | track + fill |

## Tokens

| Token | Where |
|---|---|
| `size.progress-height` | height |
| `accent.selection` | fill |
| `radius.pill` | ends |

## Platform files

- Swift: ProgressBar (Sources/Shared/ProgressBar.swift:11; Sources/tvOS/Style.swift:536); TileProgress (Sources/Shared/Style.swift:721, Sources/macOS/MacComponents.swift:461)
- Kotlin: ProgressBar (Android/phone/src/main/java/de/paulherter/swiftly/PageComponents.kt:376)
- Rust: bar (crates/swiftly-desktop/src/downloads_widgets.rs:234)

Sets: touch, desktop, tv.

## Deviations seen (not fixed here)

- Swift ProgressBar draws the track as a raw Color.white 30%; the same value exists only as ring.track, which is meant for the download ring.
