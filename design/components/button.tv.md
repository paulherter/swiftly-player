# button.tv

TV button: focus fills it white with dark text, small lift.

## Use when

Every button on tvOS and Android TV.

## Do not use when

Touch and desktop.

## Props

- `label`
- `symbol?`
- `onlySymbol`
- `height`
- `active`

## States

| State | Look |
|---|---|
| default | surface.control, text.primary |
| focused | state.focus-fill, dark text, scale 1.06, shadow.lift |
| disabled | text.tertiary |
| pressed | no opacity change |

## Tokens

| Token | Where |
|---|---|
| `surface.control` | rest fill |
| `state.focus-fill` | focused fill |
| `text.on-accent` | text on the focused fill |
| `text.tertiary` | disabled |
| `state.focus-scale` | focus scale |
| `shadow.lift` | lift while focused |
| `motion.focus` | focus move |
| `radius.control` | corner |
| `size.control-height` | height |
| `size.primary-height` | primary height |
| `label.button` | label |

## Platform files

- Swift: ThemedButtonStyle (Sources/tvOS/TVComponents.swift:21)
- Kotlin: TvButton (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvStyle.kt:460)
- Rust: themed_button, themed_button_height (crates/swiftly-ui/src/components.rs:246)

Sets: tv.
