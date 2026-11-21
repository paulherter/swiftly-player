# button.secondary

Neutral action next to or below the primary one (Abbrechen, Schnellverbindung).

## Use when

Second way to a goal, or any action that is not the page's main one.

## Do not use when

The main action (button.primary).

## Props

- `label`
- `symbol?`
- `stretches`
- `accent (label in accent.selection, e.g. Quick Connect)`
- `enabled`
- `area (override surface)`

## States

| State | Look |
|---|---|
| default | surface.control, text.primary |
| pressed | surface.pressed, scale 0.97 |
| disabled | text.tertiary label |

## Tokens

| Token | Where |
|---|---|
| `surface.control` | fill |
| `surface.pressed` | pressed fill |
| `text.primary` | label |
| `accent.selection` | label when accent |
| `text.tertiary` | disabled label |
| `radius.control` | corner |
| `size.control-height` | height |
| `label.button` | label font |
| `state.pressed-scale` | press scale |
| `motion.instant` | press down |
| `motion.quick` | release |

## Platform files

- Swift: SecondaryButtonStyle (Sources/Shared/Style.swift:663); macOS shim (Sources/macOS/SupportShims.swift:43)
- Kotlin: SecondaryButton (Android/shared/src/main/java/de/paulherter/swiftly/shared/Components.kt:85); SecondaryButton with symbol (Android/phone/src/main/java/de/paulherter/swiftly/AccountsPages.kt:79)
- Rust: press_button ButtonStyle::Secondary (crates/swiftly-ui/src/components.rs:133); action_button (crates/swiftly-desktop/src/downloads_widgets.rs:246)

Sets: touch, desktop, tv.

## Deviations seen (not fixed here)

- Rust press_button fills the secondary with surface.selected (white 8%), Swift and Kotlin use surface.control.
