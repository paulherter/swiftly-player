# card.landscape

Landscape tile 16:9: continue-watching, episodes, extras.

## Use when

Pictures that are wider than tall; the continue-watching rail.

## Do not use when

Posters (card.poster).

## Props

- `title`
- `secondLine?`
- `image`
- `progress?`
- `mark?`
- `pick`

## States

| State | Look |
|---|---|
| default | picture + text |
| pressed | scale 0.97 |
| hover | desktop: picture scales 1.04 |
| focused | TV: scale 1.06, shadow.lift |
| loading | tile.placeholder |

## Tokens

| Token | Where |
|---|---|
| `size.landscape-width` | width |
| `size.landscape-height` | height |
| `radius.tile` | corner |
| `label.tile` | title |
| `label.tile-caption` | second line |
| `space.tile-gap` | gap |
| `state.pressed-scale` | press |
| `state.hover-scale` | hover |
| `state.focus-scale` | focus |
| `shadow.lift` | TV lift |

## Platform files

- Swift: Tile landscape variant (Sources/Shared/HomeView.swift:744); LandscapeTile (Sources/macOS/MacComponents.swift:374); ExtraTile (Sources/Shared/ExtraTile.swift:7)
- Kotlin: TileView landscape = true (Android/phone/src/main/java/de/paulherter/swiftly/StartPage.kt:381); ExtraTile (Android/phone/src/main/java/de/paulherter/swiftly/TitlePage.kt:711); TvTile landscape (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvStyle.kt:738)
- Rust: tile_card (crates/swiftly-ui/src/components.rs:204); grid_tile_with (crates/swiftly-desktop/src/browse.rs:475)

Sets: touch, desktop, tv.
