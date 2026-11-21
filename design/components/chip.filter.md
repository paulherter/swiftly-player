# chip.filter

Capsule filter or choice chip (genre, sort, language).

## Use when

Choose one of a few values or open a small menu.

## Do not use when

Buttons.

## Props

- `text`
- `symbol?`
- `selected`
- `caret (opens a menu)`
- `action`

## States

| State | Look |
|---|---|
| default | surface.control (touch: translucent glass), text.secondary |
| pressed | button.press |
| selected | touch: accent fill, dark text; desktop: surface.raised, text.primary |
| hover | desktop: surface.hover |
| focused | TV: surface.focus, selected + focused uses accent.selection-light |

## Tokens

| Token | Where |
|---|---|
| `size.chip-height` | height |
| `radius.pill` | shape |
| `surface.control` | rest |
| `surface.translucent` | touch rest over a picture |
| `surface.raised` | desktop selected |
| `accent.selection` | touch selected |
| `accent.selection-light` | TV selected and focused |
| `text.on-accent` | label on accent |
| `text.secondary` | label |
| `surface.focus` | TV focus |
| `surface.hover` | desktop hover |
| `label.tile` | label |
| `state.focus-scale` | TV focus |

## Platform files

- Swift: SelectionChip + ChipSurface (Sources/Shared/Style.swift:3923,3946); Chip (Sources/macOS/MacComponents.swift:102); ChipStyle (Sources/tvOS/TVComponents.swift:219)
- Kotlin: GenreChips (Android/phone/src/main/java/de/paulherter/swiftly/GenrePage.kt:43); CapsuleChip (Android/phone/src/main/java/de/paulherter/swiftly/PlayerMenus.kt:440); Chip (Android/phone/src/main/java/de/paulherter/swiftly/ManagementAdmin.kt:70); TvChip (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvStyle.kt:622)
- Rust: popup_chip (crates/swiftly-desktop/src/browse.rs:667); chips_row (crates/swiftly-desktop/src/home.rs:965)

Sets: touch, desktop, tv.

## Local sizes (no layout token yet)

- min height: 30 dp (Theme.pillsHeight, = size.chip-height touch)

## Deviations seen (not fixed here)

- Rust popup_chip hard-codes height 30, radius 15 and the 13/600 font instead of size.chip-height, radius.pill and the type token.
- Android has three private chip implementations (GenrePage, PlayerMenus, ManagementAdmin).
