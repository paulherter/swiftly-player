# card.group

Rounded surface that holds settings rows (a group).

## Use when

Settings groups and cards that lie directly on the page.

## Do not use when

A card inside a card; tiles.

## Props

- `content (rows)`
- `inset?`

## States

| State | Look |
|---|---|
| default | surface.group |

## Tokens

| Token | Where |
|---|---|
| `surface.group` | fill |
| `radius.card` | corner (touch 16, desktop 14) |
| `radius.area` | settings group corner (tv 24) |
| `space.page` | side margin |
| `space.group-top` | space above a group |
| `border.hairline` | row separators |

## Platform files

- Swift: CardView + SettingGroup (Sources/Shared/Style.swift:918,980); CardView, RowsGroup (Sources/macOS/SettingRows.swift:24,82)
- Kotlin: CardView (Android/phone/src/main/java/de/paulherter/swiftly/Settings.kt:353)
- Rust: card_view, setting_group (crates/swiftly-desktop/src/forms.rs:510,534)

Sets: touch, desktop, tv.

## Deviations seen (not fixed here)

- Swift CardView uses radius.card; the token doc names radius.area for settings groups. Equal on touch (16), different on desktop (14 vs 16).
