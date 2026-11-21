# toggle.switch

On/off switch with a white thumb.

## Use when

A setting that is either on or off and takes effect at once.

## Do not use when

Choosing between several values.

## Props

- `on (binding)`
- `enabled`

## States

| State | Look |
|---|---|
| on | accent.selection track |
| off | border.edge track |
| disabled | thumb text.tertiary, track surface.control |
| pressed | thumb nudge |
| focused | TV: row focus |

## Tokens

| Token | Where |
|---|---|
| `accent.selection` | on track |
| `border.edge` | off track |
| `surface.control` | disabled track |
| `text.primary` | thumb |
| `text.tertiary` | disabled thumb |
| `motion.toggle` | thumb and track |

## Platform files

- Swift: ToggleSwitch (Sources/Shared/Style.swift:843; Sources/macOS/SettingRows.swift:170; Sources/tvOS/ProfileView.swift:1036)
- Kotlin: ToggleSwitch (Android/phone/src/main/java/de/paulherter/swiftly/Settings.kt:404); TvToggle (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvProfile.kt:697)
- Rust: toggle_switch, toggle_switch_mac, toggle_switch_tv (crates/swiftly-desktop/src/forms.rs:155,185,214)

Sets: touch, desktop, tv.

## Deviations seen (not fixed here)

- Swift ToggleSwitch sizes the track 46x28 with literals; no size token.
