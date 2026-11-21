# rail.value

Horizontal strip of value pills / chips under a header; fades with scroll.

## Use when

Filters and quick values at the top of a page.

## Do not use when

Tiles (rail.horizontal).

## Props

- `content`
- `offset (scroll offset for the fade)`

## States

| State | Look |
|---|---|
| default | visible |
| scrolled | fades out over space.value-gap |

## Tokens

| Token | Where |
|---|---|
| `space.value-gap` | scroll distance of the fade |
| `space.page` | leading margin |
| `motion.standard` | fade |

## Platform files

- Swift: ValueRail (Sources/Shared/Style.swift:2964)
- Kotlin: ValueRail (Android/phone/src/main/java/de/paulherter/swiftly/PageComponents.kt:296)
- Rust: none

Sets: touch, desktop, tv.
