# bar.tab

Navigation between sections: bottom bar (touch), sidebar (desktop), top tabs (TV).

## Use when

The top-level sections only.

## Do not use when

Switching inside a page (chip.filter).

## Props

- `sections`
- `selected`
- `runningCount (downloads badge)`

## States

| State | Look |
|---|---|
| default | quiet glyph and label |
| selected | touch: text.primary; desktop: surface.selected row; TV: state.focus-fill on focus |
| pressed | button.press |
| hover | desktop: surface.hover |

## Tokens

| Token | Where |
|---|---|
| `surface.selected` | desktop selected row |
| `surface.hover` | desktop hover |
| `state.focus-fill` | TV focus |
| `text.primary` | selected |
| `text.tertiary` | unselected |
| `label.bar-title` | label |
| `motion.section` | section switch (touch) |
| `motion.tabs` | TV tab change |
| `state.focus-scale` | TV focus |

## Platform files

- Swift: NavBar, SectionButton (Sources/Shared/Style.swift:2236,2150); Sidebar (Sources/Shared/Style.swift:2641); SidebarRow (Sources/macOS/MacComponents.swift:17); TabStyle, HeaderBar (Sources/tvOS/TVComponents.swift:165,614)
- Kotlin: Bar (Android/phone/src/main/java/de/paulherter/swiftly/MainView.kt:382); PageTab, HeaderBar (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvMain.kt:675,549)
- Rust: sidebar (crates/swiftly-desktop/src/library_screen.rs:1773); tabs (crates/swiftly-desktop/src/management_hub.rs:66)

Sets: touch, desktop, tv.

## Local sizes (no layout token yet)

- glyph: 20 dp (Theme.characterBar)
