# rail.alphabet

Letter index at the screen edge for long lists.

## Use when

Long alphabetical lists such as the library.

## Do not use when

Short lists.

## Props

- `letters`
- `current`
- `onSelect`

## States

| State | Look |
|---|---|
| default | quiet letters |
| focused | TV: one letter focused |
| selected | current letter |

## Tokens

| Token | Where |
|---|---|
| `text.tertiary` | letters |
| `text.primary` | current letter |
| `accent.selection` | current letter (state) |

## Platform files

- Swift: AlphabetRail (Sources/Shared/AlphabetRail.swift); TVAlphabetRail (Sources/tvOS/TVAlphabetRail.swift:17)
- Kotlin: AlphabetRail (Android/phone/src/main/java/de/paulherter/swiftly/AlphabetRail.kt:138); TvAlphabetRail (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvAlphabetRail.kt)
- Rust: none

Sets: touch, desktop, tv.
