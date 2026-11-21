# toast.hint

Short message strip at the bottom of the screen; closes itself after 3 to 6 s and is announced to VoiceOver.

## Use when

Confirmation or a refused action that needs no decision.

## Do not use when

Errors that block the page (empty.state); anything with a button.

## Props

- `text`
- `close`

## States

| State | Look |
|---|---|
| default | visible |
| dismissed | fades with motion.standard after min 3 s, max 6 s |

## Tokens

| Token | Where |
|---|---|
| `surface.raised` | strip surface (token doc) |
| `text.primary` | text |
| `radius.pill` | capsule |
| `motion.standard` | fade |
| `space.page` | side margin |

## Platform files

- Swift: HintStrip (Sources/Shared/Style.swift:4481); TileMessageStrip (Sources/macOS/TileMenuMac.swift:248)
- Kotlin: HintStrip (Android/phone/src/main/java/de/paulherter/swiftly/TitlePage.kt:801); TvHintStrip (Android/phone/src/main/java/de/paulherter/swiftly/tv/TvStyle.kt:882)
- Rust: hint_text state (crates/swiftly-desktop/src/suite.rs:4144)

Sets: touch, desktop, tv.

## Deviations seen (not fixed here)

- Swift HintStrip fills with surface.control; the token doc names surface.raised for the hint strip.
- Rust has the text state but no named component.
