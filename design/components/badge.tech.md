# badge.tech

Colour-coded technical badge (resolution, dynamic range, video codec, audio).

## Use when

Quality facts in downloads and the player proof line.

## Do not use when

Status (use badge.request).

## Props

- `kind (resolution | range | video | audio)`
- `text`

## States

| State | Look |
|---|---|
| default | kind colour, text.primary |

## Tokens

| Token | Where |
|---|---|
| `badge.resolution` | resolution |
| `badge.range` | dynamic range |
| `badge.video` | video codec |
| `badge.audio` | audio |
| `text.primary` | text |
| `overline.badge` | font |
| `radius.small` | corner |

## Platform files

- Swift: MacQualityBadge, MacAudioBadge (Sources/macOS/MacDownloads.swift:1381,1456)
- Kotlin: TechBadge (Android/phone/src/main/java/de/paulherter/swiftly/PlayerPage.kt:2911)
- Rust: none

Sets: touch, desktop, tv.

## Deviations seen (not fixed here)

- No Swift component on iOS or tvOS; no Rust component.
