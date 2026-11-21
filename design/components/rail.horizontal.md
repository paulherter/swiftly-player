# rail.horizontal

Titled horizontal rail of tiles that scrolls sideways and keeps the page margin.

## Use when

Home, collections, cast, seasons: any row of tiles.

## Do not use when

Pills and chips (rail.value).

## Props

- `title`
- `tiles`
- `landscape`
- `onSeeAll?`

## States

| State | Look |
|---|---|
| default | scrolled to start |
| loading | tile.placeholder rail |
| focused | TV: focus moves tile to tile, remembered per rail |

## Tokens

| Token | Where |
|---|---|
| `heading.rail` | title |
| `space.rail-gap` | gap between rails |
| `space.tile-gap` | gap between tiles |
| `space.page` | leading margin |
| `motion.standard` | rail arriving |

## Platform files

- Swift: Rail (Sources/Shared/HomeView.swift:609); Rail (Sources/macOS/HomeView.swift:573); PagingRail (Sources/macOS/MacComponents.swift:1149); CollectionRail (Sources/Shared/CollectionPage.swift:414, Sources/tvOS/TitleRails.swift:392)
- Kotlin: RailView (Android/phone/src/main/java/de/paulherter/swiftly/StartPage.kt:348); CollectionRail (Android/phone/src/main/java/de/paulherter/swiftly/CollectionPage.kt:317); TvCollectionRail (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvCollection.kt:109)
- Rust: rail (crates/swiftly-ui/src/components.rs:82); tv_rail (crates/swiftly-ui/src/components.rs:314)

Sets: touch, desktop, tv.
