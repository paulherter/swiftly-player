# button.quiet

Text-only action in the accent, no surface (second action of an empty state or error notice).

## Use when

A low-weight second action under an empty state or an error.

## Do not use when

Anything that must be found at a glance.

## Props

- `text`
- `action`

## States

| State | Look |
|---|---|
| default | accent text |
| pressed | press feedback by PressText |

## Tokens

| Token | Where |
|---|---|
| `accent.selection` | text |
| `label.button` | text font |
| `motion.quick` | release |

## Platform files

- Swift: PressText ButtonStyle (Sources/Shared/Style.swift:106), used as a style, no named view
- Kotlin: QuietButton (Android/shared/src/main/java/de/paulherter/swiftly/shared/Components.kt:110)
- Rust: none

Sets: touch, desktop, tv.

## Local sizes (no layout token yet)

- hit height: 44 dp (Theme.stillHeight)

## Deviations seen (not fixed here)

- Only Kotlin has a named component; Swift and Rust build it ad hoc.
