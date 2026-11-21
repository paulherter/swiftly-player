# header.subpage

Subpage header: back button, centred title.

## Use when

Every pushed page.

## Do not use when

Root pages (they use RootHeader).

## Props

- `title`
- `back`
- `right?`

## States

| State | Look |
|---|---|
| default | title at rest |
| scrolled | blurred bar fades in under it |

## Tokens

| Token | Where |
|---|---|
| `title.subpage` | title |
| `space.header-top` | top space |
| `space.page` | side margin |
| `text.primary` | title |

## Platform files

- Swift: SubpageHeader (Sources/Shared/Style.swift:1076; Sources/macOS/SettingRows.swift:355); BackButton (Sources/Shared/Style.swift:1056)
- Kotlin: SubpageHeader (Android/phone/src/main/java/de/paulherter/swiftly/Settings.kt:297); TvBack (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvBack.kt)
- Rust: none

Sets: touch, desktop, tv.
