# swiftly-playback - port notes

## Tests: Swift translated / Swift total (names match, snake_case)
| Swift test file | Translated / total | Not translated |
|---|---|---|
| DeviceProfileTests (DeviceProfile 7, MediaSource 2, ProfileGaps 5) | 14 / 14 | - (+4 golden tests) |
| PlaybackPlan (CompatibilityTests rejected/convertForbidden/conversion/ogg, AuthRequestTests SourcesSelection 4, MediaVersionsTests pickedWins, DownloadRulesTests fromSlab) | 10 / 10 | - |
| TrackRuleTests | 19 / 20 | `message` (report body JSON; belongs to `swiftly-jellyfin::reporting`) |
| TrackLabelTests | 8 / 8 | language names come from a test double, see risks |
| OriginalAudioTests | 6 / 6 | - |
| ResumePointTests (+ JumpTargetTests 3) | 8 / 8 | - |
| PauseJumpBackTests | 5 / 5 | - |
| FirstFrameTests | 8 / 12 | `slab`, `entries`, `list` (need `DownloadItem`), one needing the downloads list |
| PrebufferTests | 6 / 6 | the network fetch (`startRequest`) is I/O, only the rules are ported |
| AirPlaySuitabilityTests | 14 / 14 | type `AirPlayInfo` (needs the plan's UI text) |
| AudioGuardsTests, FadeTimesTests, AvComputationTests | 13 / 13 | - |
| TrickplayTests | 5 / 6 | `address` (needs `JellyfinClient`; `trickplay_url` is in `swiftly-jellyfin`) |
| SectionsTests | 32 / 32 | - (7 EpisodesCard tests left over by `swiftly-rules` are here) |
| SectionOfferingTests | 18 / 18 | - |
| OfferingLayerTests | 21 / 21 | - |
| **Total** | **187 / 193** | |

`cargo test` runs 216: the above plus golden tests, 13 state-machine replays, 3 extra offering tests,
`range_header_covers_initial_bytes`, `diagnose_names_the_stream`, `server_relative_keeps_subpath`, `ordered_choice_wins`.

## DeviceProfile golden
`tests/golden/*.json` were produced by compiling the real `DeviceProfile.swift` with `swiftc` and encoding
`vlc()`, `vlc(maxBitrate: 8_000_000)`, `airplay()` and `airplay(av1: true)` with `JSONEncoder` and `.sortedKeys`.
The Rust JSON is compared as a value for all four, and `vlc` also byte for byte. All equal.

Flavours: Swift has two profiles only (`vlc()` "Swiftly (VLC)" and `airplay()`). Android and the desktop
apps send the same engine profile today (through the shared core), so `Flavour::{Aether, Media3, Mpv}`
return it unchanged; only `AirPlay{av1}` differs. A Media3 or mpv specific profile is a later decision.

## Not ported, and why
- `PlaybackPlan.summary` and `TranscodeReason.text`: catalog sentences. `ReasonDetail::source_text()` gives the German keys.
- `TrackMemory` storage (`UserDefaults`): `read_choice`/`write_choice`/`title_key` work on a plain map; the store is `swiftly-settings`.
- `TrackLabel.displayLocale` and `Locale.localizedString`: the `LabelText` trait supplies language names and the four catalog words.
- PlaybackReporting: already in `swiftly-jellyfin` (`TrackIndices`, `ReportPlan`); the tick schedule is `swiftly_rules::playback_tick`.
- `FirstFrame` ladder only as pure data; TimeAssumption/PowerGuard stay in `swiftly-rules` or parked (VLC-only).
- Plex marker mapping is not in the three section files.
- The engine side of `AetherPlayerEngine` (AVFoundation, PiP controller, `SubtitleOverlay`, `UIApplication` idle timer, logging sink): host work.
  PiP and idle timer are `Command::Running` / `PipCmd` for the driver.

## Player seam
`PlaybackEngine` (13 methods, commands return `()`, only `select_audio`/`select_subtitle` answer at once) and `EngineEvent`
live in `engine`. `PlayerState::apply(EngineEvent)` / `intent(Intent)` return `Vec<Command>`; `Command::run(&dyn PlaybackEngine)` runs
engine calls and returns `false` for host notifications (`Running`, `Failed`, `HandOver`, `ReportTracks`, `ArmStartWatchdog`, `Log`).
Added events beyond the D4 list because Swift awaits results that are now events: `LoadFinished{attempt}`, `LoadFailed`, `StartWatchdog`,
`SeekLanded{target}`. The 30 s start watchdog is a command the host arms (no clock inside). The `#[uniffi::export(with_foreign)]`
attribute is for `swiftly-uniffi`; this crate has no uniffi dependency.

## Risks / deviations
1. `swiftly-playback/Cargo.toml` depends on `swiftly-library` (added by the sections port, for `CollectionDirectory`, `ShelfSource`, `TitleFilter`);
   Cargo.lock gains the `swiftly-playback` entry (the driver commits it).
2. Language names: tests use a small table for the en/de/ru names; real CLDR names come from the l10n crate through `LabelText`.
   `looks_like_language_code` (extra title) checks the shape and the language table instead of asking `Locale(identifier: "en")`.
3. Strings in `ReasonDetail`, `Prebuffer`, `FirstFrame` and `AirPlaySuitability` go through `Localizer` or German keys, as in `swiftly-model`.
4. `server_relative` is string based (no `URLComponents`): keeps the base path, drops the fragment, appends the query; percent-encoding of the key is minimal.
5. `av_computation.rs` has private OKLab helpers because `ColorSelection` is not ported; switch when it is.
6. `Int(x.rounded())` traps on NaN in Swift; Rust saturates.
7. Cue/seek timing: the seek target is cleared by `SeekLanded` (Swift cleared it after `await engine.seek`). The driver must send it.
8. `PlayerState` is single-threaded state; the facade in `swiftly-vm` owns it behind its own lock.
