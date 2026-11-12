# swiftly-rules

Pure rule files of the Swiftly Jellyfin client, ported 1:1 from Swift
(`Packages/JellyfinKit/Sources/JellyfinKit`). No networking, no UI strings, no storage.
One module per Swift file; the module header names the Swift source and cites `file:line`
where a rule is non-obvious.

| Module | Swift source |
|---|---|
| `natural_order` | NaturalOrder.swift (sorting; the paging extension is networking, not ported) |
| `alphabet_index` | AlphabetIndex.swift |
| `delay` | Delay.swift |
| `download_quality` | DownloadQuality.swift |
| `download_right` | DownloadRight.swift |
| `download_audio` | DownloadAudio.swift (choice logic; `DownloadItem.withAudio` not ported) |
| `display_rules` | DisplayRules.swift |
| `age_rating` | AgeRating.swift |
| `chapter` | Chapter.swift (`ChapterBar`; JSON decoding is `swiftly-model`) |
| `playback_tick` | PlaybackTick.swift |
| `time_assumption` | TimeAssumption.swift (dependency of the tick) |
| `episodes_end` | EpisodesEnd.swift |
| `episodes_card` | EpisodesCard.swift |
| `episodes_switch` | EpisodesSwitch.swift (`EpisodeSwitch`, `StopLock`) |
| `notches_snap` | NotchesSnap.swift |
| `buffer_level` | BufferLevel.swift |
| `language` | Language.swift |
| `playback_selection` | PlaybackSelection.swift |
| `playback_levels` | PlaybackLevels.swift |
| `whole_number` | WholeNumber.swift (`Int(capped:)`) |

Conventions: Swift `Int` is `i64`; `rounded()` is `f64::round` (half away from zero);
`Date` is `f64` seconds on one clock; localised wording and locale formatting are not done here
(functions take a decimal separator or return `None` where Swift returns a catalog string).
Foundation-dependent behaviour (collation, `Character` semantics) is documented in the modules
and in `NOTES.md`.

```
cargo test -p swiftly-rules
cargo clippy -p swiftly-rules --all-targets -- -D warnings
```
