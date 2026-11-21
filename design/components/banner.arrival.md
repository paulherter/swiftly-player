# banner.arrival

Card for a request that has arrived: poster, line, play button and close; several stack.

## Use when

A title the user requested is available now.

## Do not use when

General news.

## Props

- `arrival`
- `badge? (stack count)`
- `depth`
- `lifted`
- `play`
- `tap`
- `close`

## States

| State | Look |
|---|---|
| default | card on surface.group |
| stacked | cards behind darken by depth |
| expanded | stack opens |
| pending | skeleton while loading |
| dismissed | close |

## Tokens

| Token | Where |
|---|---|
| `surface.group` | card |
| `radius.card` | corner |
| `text.primary` | line |
| `text.tertiary` | Deine Anfrage |
| `surface.control` | count badge |
| `overline.badge` | count font |
| `motion.emphasized-land` | arriving |
| `state.pressed-scale` | press |

## Platform files

- Swift: ArrivalBanner, ArrivalStack (Sources/Shared/SeerrHomeBlock.swift:273,120); DesktopArrivalCard (Sources/Shared/DesktopArrivalStack.swift:177)
- Kotlin: ArrivalStack, ArrivalCard (Android/phone/src/main/java/de/paulherter/swiftly/StartSeerr.kt:299,341)
- Rust: Arrival part (crates/swiftly-desktop/src/pages_screen/seerr_views.rs); state (crates/swiftly-desktop/src/seerr_desk.rs)

Sets: touch, desktop, tv.

## Deviations seen (not fixed here)

- Swift darkens stacked cards with a raw black at 10% per depth.
