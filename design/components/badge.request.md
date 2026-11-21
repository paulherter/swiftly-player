# badge.request

Capsule that names the state of a request (verfügbar, wartet, abgelehnt).

## Use when

Seerr request and issue states.

## Do not use when

Quality facts (badge.tech).

## Props

- `tint`
- `word`

## States

| State | Look |
|---|---|
| default | tinted capsule, dark text |

## Tokens

| Token | Where |
|---|---|
| `state.warning` | waiting |
| `state.error` | failed |
| `accent.selection` | available / chosen |
| `surface.base` | text on the tint |
| `overline.badge` | font |
| `radius.pill` | shape |

## Platform files

- Swift: SeerrBadgeCapsule (Sources/Shared/SeerrMark.swift:114); TVPills (Sources/tvOS/TVManagementHub.swift:152); MacRequestPills (Sources/macOS/SeerrPages.swift:623)
- Kotlin: Capsule (Android/phone/src/main/java/de/paulherter/swiftly/SeerrCore.kt:195)
- Rust: none

Sets: touch, desktop, tv.
