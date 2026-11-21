# spinner.loading

Indeterminate loader.

## Use when

Work with no known length.

## Do not use when

Page loading (tile.placeholder).

## Props

- `size`
- `color`

## States

| State | Look |
|---|---|
| loading | rotating arc |

## Tokens

| Token | Where |
|---|---|
| `text.primary` | arc (Swift), text.tertiary (Kotlin default) |

## Platform files

- Swift: Loader, LoadingSpinner (Sources/Shared/Components.swift:104; Sources/Shared/Style.swift:1775)
- Kotlin: Spinner (Android/phone/src/main/java/de/paulherter/swiftly/PageComponents.kt:923); Loader (Android/phone/src/main/java/de/paulherter/swiftly/PlayerPage.kt:2484); TvLoader (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvPlayer.kt:793)
- Rust: spinner (crates/swiftly-desktop/src/home.rs:2063); loader (crates/swiftly-desktop/src/player_screen.rs:3861)

Sets: touch, desktop, tv.

## Deviations seen (not fixed here)

- Swift and Kotlin use different default colours (text.primary vs text.tertiary).
