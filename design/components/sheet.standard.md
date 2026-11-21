# sheet.standard

Bottom sheet (centred card on wide layouts) with title, lines and a cancel row.

## Use when

Choices and confirmations that interrupt the page briefly.

## Do not use when

Long forms (use a page).

## Props

- `opened (binding)`
- `dimmed`
- `content`
- `category`
- `lines`
- `cancel`

## States

| State | Look |
|---|---|
| default | closed |
| opening | motion.emphasized slide |
| open | surface.control card over a dimmed page |
| dismissing | drag down or tap outside |
| reduced | motion.reduced fade |

## Tokens

| Token | Where |
|---|---|
| `surface.control` | card |
| `radius.sheet` | corner |
| `shadow.sheet` | shadow |
| `surface.overlay` | dim layer (token exists, code still uses black) |
| `motion.emphasized` | slide in |
| `motion.reduced` | Reduce Motion |
| `space.sheet-inset` | inner inset |
| `border.hairline` | SheetLine separator |
| `label.row-title` | lines |

## Platform files

- Swift: SheetModifier, SheetCategory, SheetLine, SheetCancel, ActionSheet (Sources/Shared/Style.swift:4047,4283,4379,4386,4414); SheetLine (Sources/macOS/Style.swift:453)
- Kotlin: SheetCard, SheetCancel, SheetLine (Android/phone/src/main/java/de/paulherter/swiftly/PageComponents.kt:721,788,796)
- Rust: sheet, sheet_with, SheetRow (crates/swiftly-desktop/src/browse.rs:716-743)

Sets: touch, desktop, tv.

## Deviations seen (not fixed here)

- surface.overlay is not used by name yet; the dim layer is a raw black.
