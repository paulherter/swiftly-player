# row.media

Row with a picture: episode, file, download.

## Use when

Lists of playable or downloadable things.

## Do not use when

Settings (row.settings).

## Props

- `image`
- `title`
- `subline`
- `trailing (ring, chevron)`
- `progress?`
- `ongoing`

## States

| State | Look |
|---|---|
| default | row on the page |
| pressed | dim (PressRow) |
| hover | desktop: surface.hover |
| focused | TV: surface.focus |
| selected | surface.selected (playing) |

## Tokens

| Token | Where |
|---|---|
| `size.row-height` | height |
| `surface.selected` | playing row |
| `surface.hover` | hover |
| `surface.focus` | TV focus |
| `border.hairline` | separator |
| `label.row-title` | title |
| `text.secondary` | subline |
| `radius.tile` | picture corner |

## Platform files

- Swift: FileRow (Sources/Shared/Style.swift:1411; Sources/macOS/DetailView.swift:974); DownloadRow (Sources/Shared/DownloadsView.swift:229); EpisodesRow (Sources/macOS/SeriesView.swift:733)
- Kotlin: EpisodesRow (Android/phone/src/main/java/de/paulherter/swiftly/SeriesPage.kt:676); DownloadRow (Android/phone/src/main/java/de/paulherter/swiftly/DownloadsPage.kt:525)
- Rust: none

Sets: touch, desktop, tv.
