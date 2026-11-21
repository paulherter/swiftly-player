# badge.tile

Corner badge on a tile: watched check or unwatched count.

## Use when

Watch state on poster and landscape tiles.

## Do not use when

Decoration.

## Props

- `mark (watched | count)`
- `figure`

## States

| State | Look |
|---|---|
| default | surface.base at 78% with text.primary |

## Tokens

| Token | Where |
|---|---|
| `surface.base` | plate (78% alpha) |
| `text.primary` | check and count |
| `overline.badge` | count font |
| `radius.small` | corner |

## Platform files

- Swift: TileBadge (Sources/Shared/Style.swift:4314; Sources/tvOS/TVComponents.swift:1823; Sources/macOS/MacComponents.swift:611); CountMark (Sources/Shared/Style.swift:3905)
- Kotlin: TileBadge (Android/phone/src/main/java/de/paulherter/swiftly/PageComponents.kt:420); TvTileBadge (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvStyle.kt:814); CountMark (Android/phone/src/main/java/de/paulherter/swiftly/PageComponents.kt:308)
- Rust: count_mark (crates/swiftly-desktop/src/browse.rs:690)

Sets: touch, desktop, tv.

## Deviations seen (not fixed here)

- Swift draws the plate as Theme.reason.opacity(0.78): the 78% alpha is a raw value.
