# button.primary

The one filled action of a page or sheet: white surface, dark text (Abspielen, Anmelden).

## Use when

One per screen or sheet: the action the screen exists for.

## Do not use when

Second actions (button.secondary). Never an accent fill: the accent carries state only.

## Props

- `label`
- `symbol?`
- `stretches (full width, default true)`
- `enabled`
- `lockedArea (disabled surface on a sheet)`
- `abbreviation? (desktop)`

## States

| State | Look |
|---|---|
| default | text.primary fill, text.on-accent label |
| pressed | fill at 75%, scale 0.97, no delay in, quick out |
| hover | desktop only: lighter fill |
| disabled | surface.control fill, text.tertiary label (dimmed, not translucent) |

## Tokens

| Token | Where |
|---|---|
| `text.primary` | fill (white) |
| `text.on-accent` | label |
| `surface.control` | disabled fill |
| `text.tertiary` | disabled label |
| `radius.control` | corner |
| `size.control-height` | minimum height (touch) |
| `size.primary-height` | height on desktop and TV |
| `label.button` | label font |
| `state.pressed-scale` | press scale |
| `motion.instant` | press down |
| `motion.quick` | release |

## Platform files

- Swift: PrimaryButtonStyle (Sources/Shared/Style.swift:601); macOS PrimaryButton (Sources/macOS/MacComponents.swift:181)
- Kotlin: PrimaryButton (Android/shared/src/main/java/de/paulherter/swiftly/shared/Components.kt:52)
- Rust: primary_button (crates/swiftly-desktop/src/downloads_widgets.rs:270); press_button ButtonStyle::Primary (crates/swiftly-ui/src/components.rs:133)

Sets: touch, desktop, tv.

## Deviations seen (not fixed here)

- Swift draws the fill as Color.white and the pressed fill as white 75%; no token names the primary fill or its pressed state yet.
- Swift label is an inline 17 pt semibold; label.button is 15 pt.
- Rust press_button uses a 999 radius, the others radius.control (10).
