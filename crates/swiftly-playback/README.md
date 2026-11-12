# swiftly-playback

Playback decision logic of the Swiftly core, ported 1:1 from Swift (`Packages/JellyfinKit` and the
engine-neutral part of `Sources/Shared/AetherPlayerEngine.swift`). No I/O, no UI strings.
Every module header names its Swift source; public items cite `file:line`.

| Module | Swift source |
|---|---|
| `device_profile` | DeviceProfile.swift (`Flavour` input: Aether, Media3, Mpv, AirPlay; golden JSON in `tests/golden`) |
| `playback_plan` | PlaybackPlan.swift (+ `server_relative` from ServerURL.swift) |
| `track_rule`, `track_mapping`, `track_label`, `original_audio` | TrackRule, TrackMapping, TrackLabel, OriginalAudio (+ TechDetails codec/channel helpers) |
| `resume_point`, `pause_jump_back`, `first_frame`, `prebuffer`, `audio_guards` | same-named Swift files (`JumpTarget` is in `resume_point`) |
| `airplay_suitability`, `av_computation`, `fade_times`, `trickplay` | same-named Swift files |
| `sections`, `section_offering`, `offering_layer` | Sections, SectionOffering, OfferingLayer |
| `engine` | `PlaybackEngine` trait, `EngineLoad`, `EngineEvent` (PlaybackBackend.swift, ARCHITECTURE.md D4) |
| `player_state` | `PlayerState`: `apply(EngineEvent)` and `intent(Intent)` return `Vec<Command>` |

Rules that already exist in `swiftly-rules` (PlaybackTick, TimeAssumption, Delay, EpisodesEnd/Card/Switch,
NotchesSnap, BufferLevel, Language, PlaybackSelection, PlaybackLevels) and `swiftly-jellyfin`
(PlaybackReporting, `TrackIndices`) are reused, not copied.

Run: `cargo test -p swiftly-playback`.
