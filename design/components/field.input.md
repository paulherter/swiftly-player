# field.input

Text field: surface.control, one line, clear button.

## Use when

Any single-line entry (address, name, search).

## Do not use when

Multi-line text.

## Props

- `text (binding)`
- `placeholder`
- `symbol?`
- `kind (normal | address)`
- `enabled`

## States

| State | Look |
|---|---|
| default | surface.control, text.primary |
| focused | keyboard open / caret |
| filled | clear button shown |
| disabled | text.tertiary |
| error | state.error message below |

## Tokens

| Token | Where |
|---|---|
| `surface.control` | fill |
| `radius.field` | corner |
| `size.control-height` | height |
| `text.primary` | text |
| `text.tertiary` | placeholder |
| `state.error` | error line |

## Platform files

- Swift: InputField (Sources/Shared/Style.swift:4718; Sources/tvOS/RootView.swift:138); SearchField (Sources/Shared/Style.swift:3093); InputRow (Sources/macOS/RootView.swift:380)
- Kotlin: InputField (Android/shared/src/main/java/de/paulherter/swiftly/shared/Components.kt:135); SearchField (Android/phone/src/main/java/de/paulherter/swiftly/SearchPage.kt:372); TvField (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvStyle.kt:554)
- Rust: FieldView, FieldLook (crates/swiftly-ui/src/field.rs:128,145); search_field (crates/swiftly-desktop/src/browse.rs:863)

Sets: touch, desktop, tv.

## Local sizes (no layout token yet)

- glyph: 17 dp (Theme.symbolText)
- glyph column: 20 dp (Theme.characterColumn)
