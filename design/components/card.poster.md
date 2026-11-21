# card.poster

Poster tile: picture 2:3, title and second line below, optional progress and badge.

## Use when

Any title in a rail or grid with a portrait picture.

## Do not use when

Landscape pictures (card.landscape). No edge or shadow: content tiles carry neither.

## Props

- `title`
- `secondLine?`
- `image`
- `progress?`
- `mark? (watched, count)`
- `pick`
- `prefetch?`

## States

| State | Look |
|---|---|
| default | picture + text |
| pressed | scale 0.97 |
| hover | desktop: picture scales 1.04, no ring |
| focused | TV: scale 1.06, shadow.lift |
| loading | tile.placeholder |
| selected | n/a (selection lives in a sheet) |

## Tokens

| Token | Where |
|---|---|
| `size.poster-width` | width |
| `size.poster-height` | height |
| `radius.tile` | picture corner |
| `label.tile` | title |
| `label.tile-caption` | second line |
| `text.primary` | title |
| `text.secondary` | second line |
| `space.tile-gap` | gap to the next tile |
| `state.pressed-scale` | press |
| `state.hover-scale` | hover (desktop) |
| `state.focus-scale` | focus (TV) |
| `shadow.lift` | TV lift |
| `motion.quick` | release |
| `motion.focus` | TV focus |

## Platform files

- Swift: PosterTile (Sources/Shared/BrowseViews.swift:5); Tile (Sources/Shared/HomeView.swift:744); PosterCell (Sources/macOS/MacComponents.swift:276); TileStyle + TileContent (Sources/tvOS/TVComponents.swift:98,478)
- Kotlin: TileView (Android/phone/src/main/java/de/paulherter/swiftly/StartPage.kt:381); GridTileView (Android/phone/src/main/java/de/paulherter/swiftly/LibraryPage.kt:543); TvTile (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvStyle.kt:738)
- Rust: poster_tile (crates/swiftly-ui/src/components.rs:46); grid_tile (crates/swiftly-desktop/src/browse.rs:423)

Sets: touch, desktop, tv.

## Deviations seen (not fixed here)

- Rust poster_tile strokes the tile with border.tile; the token is for the look picker only, content tiles have no edge.
