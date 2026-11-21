# empty.state

Empty or failed page: disc with glyph, headline, text, optional button.

## Use when

No results, no connection, nothing downloaded.

## Do not use when

Loading (tile.placeholder).

## Props

- `symbol`
- `headerLine`
- `text`
- `loads (dimmed while loading)`
- `button?`

## States

| State | Look |
|---|---|
| default | disc + text |
| loading | disc at 45% while the request runs |
| error | same layout with the error wording |

## Tokens

| Token | Where |
|---|---|
| `surface.control` | disc |
| `text.primary` | glyph, headline |
| `text.secondary` | text |
| `title.subpage` | headline |
| `motion.standard` | loading dim |

## Platform files

- Swift: EmptyState (Sources/Shared/Style.swift:4526); DisturbHint (Sources/Shared/Style.swift:4664)
- Kotlin: EmptyState, DisturbHint (Android/phone/src/main/java/de/paulherter/swiftly/PageComponents.kt:492,541); TvEmpty (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvPages.kt:211)
- Rust: empty_state (crates/swiftly-desktop/src/home.rs:1082; crates/swiftly-desktop/src/pages_screen.rs:261)

Sets: touch, desktop, tv.

## Local sizes (no layout token yet)

- glyph: 44 dp (Theme.characterEmpty)
- disc: 78 dp (Theme.circleEmpty); Style.kt also has emptyDisc 120 dp
