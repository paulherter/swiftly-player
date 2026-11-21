# row.settings

Row in a settings group: glyph, title, optional second line, trailing value, toggle or chevron.

## Use when

Every row of a settings group, profile page and picker.

## Do not use when

Rows with a picture (row.media).

## Props

- `symbol`
- `title`
- `under?`
- `value?`
- `trailing (chevron | none | external | toggle)`
- `color`
- `locked`

## States

| State | Look |
|---|---|
| default | row on surface.group |
| pressed | row dim (PressRow) |
| hover | desktop: surface.hover |
| focused | TV: surface.focus |
| disabled | text.tertiary |
| selected | check mark |

## Tokens

| Token | Where |
|---|---|
| `size.row-height` | height |
| `label.row-title` | title |
| `text.secondary` | value |
| `text.tertiary` | second line, disabled |
| `border.hairline` | separator |
| `surface.hover` | desktop hover |
| `surface.focus` | TV focus |
| `surface.selected` | selected / playing row |
| `motion.leap` | expanding rows |
| `state.focus-scale` | TV wide rows scale 1.03 |

## Platform files

- Swift: ProfileRow (Sources/Shared/Style.swift:3743); RowsLayout, ChoiceRow, ValueRow (Sources/Shared/PlaybackSettingsView.swift:252,290,342); ToggleRow, ValuesRow (Sources/macOS/SettingRows.swift:148,195); ActionRow, ToggleRow, RowsStyle (Sources/tvOS/ProfileView.swift:916,984,1288; Sources/tvOS/TVComponents.swift:386)
- Kotlin: RowsLayout, ChoiceRow, ValueRow, ProfileRow (Android/phone/src/main/java/de/paulherter/swiftly/Settings.kt:424,455,466,490); TvRow, TvSettingsRow (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvStyle.kt:673,926)
- Rust: row, row_kb, row_ex (crates/swiftly-desktop/src/forms.rs:243-299)

Sets: touch, desktop, tv.

## Local sizes (no layout token yet)

- glyph: 17 dp (Theme.symbolText)
- glyph column: 20 dp (Theme.characterColumn)
