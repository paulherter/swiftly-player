# menu.player

Player menu layer: audio, subtitles, speed, episodes.

## Use when

Choices while a title plays.

## Do not use when

Choices outside the player (sheet.standard).

## Props

- `levels (rows, steps, chips)`
- `selection`
- `onAct`

## States

| State | Look |
|---|---|
| default | closed |
| open | panel on surface.control with border.edge |
| focused | TV: surface.focus, state.focus-fill on the key |
| selected | check mark / chip on |

## Tokens

| Token | Where |
|---|---|
| `surface.control` | panel |
| `border.edge` | panel edge |
| `radius.panel` | corner |
| `shadow.tooltip` | shadow |
| `scrim.glass` | bar behind |
| `text.primary` | rows |
| `text.secondary` | values |
| `motion.controls-fade` | TV fade |
| `surface.focus` | TV row focus |

## Platform files

- Swift: TVPlayerMenuLayer, TVMenuBox (Sources/tvOS/TVPlayerMenus.swift:31,106); LayersHeader, LayersRow (Sources/macOS/PlayerLayers.swift:177,233)
- Kotlin: PlayerMenuLayer (Android/phone/src/main/java/de/paulherter/swiftly/PlayerMenus.kt:309); TvPlayerMenuLayer (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvPlayerMenus.kt:128)
- Rust: MenuItem, MenuState, MenuController (crates/swiftly-ui/src/popover.rs:27,189,487); player_menu_box (crates/swiftly-desktop/src/player_menu_box.rs)

Sets: touch, desktop, tv.
