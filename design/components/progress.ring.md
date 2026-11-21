# progress.ring

Ring for downloads and countdowns.

## Use when

Download state in a row; countdown to the next episode.

## Do not use when

Bars (progress.bar).

## Props

- `state (none | waits | running | paused | done | failed)`
- `share`
- `size`

## States

| State | Look |
|---|---|
| none | arrow, outlined circle |
| waits | dashed circle, pause glyph |
| running | arc on ring.track |
| paused | arc, pause glyph |
| done | filled with check |
| failed | exclamation, state.error |

## Tokens

| Token | Where |
|---|---|
| `ring.track` | download track |
| `ring.progress` | episode-card ring |
| `text.primary` | glyph |
| `text.secondary` | outline |
| `text.tertiary` | waiting |
| `state.error` | failed |

## Platform files

- Swift: DownloadRing (Sources/Shared/DownloadsView.swift:19; Sources/macOS/MacDownloads.swift:20)
- Kotlin: DownloadRing (Android/phone/src/main/java/de/paulherter/swiftly/DownloadsPage.kt:81); CountdownRing (Android/phone/src/main/java/de/paulherter/swiftly/EpisodesCard.kt:339)
- Rust: ring (crates/swiftly-desktop/src/downloads_widgets.rs:157)

Sets: touch, desktop, tv.
