# header.detail

Detail header: hero picture, title, proof line and action buttons.

## Use when

The top of a movie, show or person page.

## Do not use when

Lists.

## Props

- `title`
- `secondLine`
- `image`
- `logo?`
- `mood (image colour)`

## States

| State | Look |
|---|---|
| default | hero with gradient into surface.base |
| scrolled | compact header fades in |

## Tokens

| Token | Where |
|---|---|
| `size.hero-height` | picture height |
| `title.detail` | title |
| `caption.small` | second line |
| `surface.base` | gradient end |
| `space.page` | margin |
| `motion.backdrop` | TV backdrop fade |

## Platform files

- Swift: DetailHeader, HeroImage, HeroRunOut (Sources/Shared/Style.swift:3444,3835,3267); DetailHero (Sources/macOS/DetailView.swift:339); DetailHeader (Sources/tvOS/DetailView.swift:22)
- Kotlin: Hero, HeroRunOut, DetailHeader (Android/phone/src/main/java/de/paulherter/swiftly/TitlePage.kt:452,476,766); TvDetailHeader (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvTitle.kt:78)
- Rust: hero_node (crates/swiftly-desktop/src/hub.rs:833)

Sets: touch, desktop, tv.
