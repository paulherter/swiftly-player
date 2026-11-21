# focus.tv

Shared TV focus treatment: scale, white fill or surface, small lift.

## Use when

Every focusable thing on TV.

## Do not use when

Touch and desktop (hover uses surface.hover).

## Props

- `focused`
- `magnifier`

## States

| State | Look |
|---|---|
| default | rest |
| focused | scale 1.06 (1.10 small icons, 1.03 wide rows), shadow.lift, fill by role |

## Tokens

| Token | Where |
|---|---|
| `state.focus-scale` | scale |
| `state.focus-fill` | buttons, tabs, keys |
| `surface.focus` | rows, chips |
| `shadow.lift` | lift |
| `motion.focus` | move |

## Platform files

- Swift: lift(), focusMagnifier (Sources/tvOS/TVComponents.swift:98-135)
- Kotlin: FocusArea (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvStyle.kt:300)
- Rust: focus_ring, focus (crates/swiftly-ui/src/view.rs:889; crates/swiftly-ui/src/focus.rs)

Sets: tv.
