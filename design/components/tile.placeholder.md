# tile.placeholder

Grey placeholder while pictures and rails load (shimmer-free).

## Use when

Loading state of every tile, rail and grid.

## Do not use when

Empty results (empty.state).

## Props

- `landscape (rail shape)`

## States

| State | Look |
|---|---|
| loading | surface.control block with the tile corner |

## Tokens

| Token | Where |
|---|---|
| `surface.control` | fill |
| `radius.tile` | corner |
| `size.poster-width` | poster size |
| `size.landscape-width` | landscape size |

## Platform files

- Swift: TilePlaceholder, GridPlaceholder, RailsPlaceholder, LoadField (Sources/Shared/Style.swift:4878-4944); tvOS (Sources/tvOS/TVComponents.swift:1753,1788); macOS (Sources/macOS/MacComponents.swift:514-572)
- Kotlin: TilePlaceholder, LoadField (Android/phone/src/main/java/de/paulherter/swiftly/PageComponents.kt:454,461); RailsPlaceholder (Android/phone/src/main/java/de/paulherter/swiftly/StartPage.kt:430); TvTilePlaceholder (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvPages.kt:197)
- Rust: rails_placeholder (crates/swiftly-desktop/src/home.rs:1058)

Sets: touch, desktop, tv.
