# card.episode

Episode card over the player picture (cards stack and rest at different depths).

## Use when

Episode list inside the player.

## Do not use when

Pages (use row.media or card.landscape).

## Props

- `episode`
- `present`
- `rest (how far it rests)`
- `details`

## States

| State | Look |
|---|---|
| default | resting card |
| focused | TV: lift |
| pressed | scale |

## Tokens

| Token | Where |
|---|---|
| `shadow.card` | shadow scales with rest |
| `ring.progress` | countdown ring |
| `radius.card` | corner |
| `motion.emphasized-land` | landing |
| `surface.control` | card surface |

## Platform files

- Swift: EpisodeCardParts (Sources/Shared/EpisodeCardParts.swift); EpisodeCardsView (Sources/macOS/EpisodeCardsView.swift:22); TVEpisodesCard (Sources/tvOS/TVEpisodesCard.swift:8)
- Kotlin: EpisodeCard (Android/phone/src/main/java/de/paulherter/swiftly/EpisodesCard.kt:141)
- Rust: CardLook, CardMotion, CardStill (crates/swiftly-desktop/src/player_card.rs:79,100,302)

Sets: touch, desktop, tv.
