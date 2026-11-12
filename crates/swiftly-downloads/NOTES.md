# swiftly-downloads - port notes

## Tests (Swift tests vs. Rust tests with the same inputs)

| Swift test file | Swift tests | Translated | Not translated |
|---|---|---|---|
| DownloadRulesTests (suite DownloadRulesTests 38, DownloadItemItemTests 2, PendingReportTests 6) | 46 | 39 | 7 |
| DownloadTaskTests | 5 | 5 | - |
| DownloadQualityTests, the ones blocked on `DownloadItem` (`entries`, `share`) | 2 | 2 | - |
| DownloadAudioTests, the ones blocked on `DownloadItem`/`DownloadRules` (`itemWithAudio`, `oldList`, `end`, `following`, `followUp`, `replaced`) | 6 | 6 | - |
| **Total in scope** | **59** | **52** | **7** |

Of the 25 tests `swiftly-rules/NOTES.md` lists as blocked, 8 are finished here. The other 17 are
blocked on other things and stay there (`JellyfinClient`, `AccountPreGift`, `SectionLogic`,
`OfferingLayer`, subtitle URL building, Chapter serde).

`cargo test` runs 102: the 52 plus 50 new ones: the manager replay tests (33), the JSON
compatibility tests (8), `LoadSelection` (7, there is no Swift test file for it), the offline
helpers (`postPlayback` thresholds, `episodePost` gaps, `follow`), two size-text tests, and one
extra `DownloadTask` test.

Not translated: `PendingReportTests` (6, `PostReportRules` is a different Swift file, not on the
list) and `planFromSlab` (`PlaybackPlan`, belongs to `swiftly-playback`). `DownloadAudioTests.address`
needs `JellyfinClient.downloadURL` (client crate).

The two `sizeInGB` / `sizeRussian` Swift tests are translated as unit tests of `size_text`
(see risk 1).

## JSON compatibility with the Swift `liste.json`

* Keys are the Swift `CodingKeys`, exactly (27 of them, listed in `tests/json_compat.rs`).
* `art`: `film`/`folge`; `stand`: `wartet`/`laedt`/`angehalten`/`fertig`/`fehler`; `qualitaet`: the
  `DownloadQuality` raw values. Unknown values are a decode error, as in Swift.
* Dates (`angelegt`, `zuletzt`) are numbers of seconds since 2001-01-01 (default `deferredToDate`).
  In memory they are Unix seconds; the offset is 978307200.
* Absent optionals are omitted on write (Swift's synthesised `encodeIfPresent`); `null` or missing
  reads as `None`. `sections` use `Segment`'s own `Type`/`StartTicks`/`EndTicks` form from
  `swiftly-playback`.
* The sample in the test is derived from the Swift encoder code, not from a real file. **Not
  verified against a real `liste.json` from a device**: the Swift app was not run.
* Like Swift, decoding does not run the initializer's normalisation (`original` quality stays
  `original`, `bildcodec` of a converted file stays). `DownloadItem::normalized()` is the init logic.

## State machine

All of `DownloadManager`'s rules are in `manager.rs`; the `URLSession` plumbing is not (it is the
`DownloadTransport`). Mapping: `tick/start/taskStart/progress/completed/failed/halt/putBack/resume/
remove/allHalt/allRemove/signIn/release/load/tasksAgainFind/networkStatus/smartNext/follow/
playbackRemember` are private methods behind `Intent`s; `secure()` is the dirty flag that becomes
one `Effect::Persist`.

Additions beyond the Swift code (all small, all marked here):
1. **Space guard at start.** With a measured free space (`SpaceChanged` > 0), a title whose remaining
   bytes would leave less than the 1 GiB reserve becomes `error` with `REASON_NOT_ENOUGH_SPACE`
   instead of starting; the queue goes on with the next one. Swift only checked in the sheet
   (`inquiry`) and let the transfer fail on a full disk. `0` means unknown and never blocks.
2. **`Add { check_space }`** returns `Report::NotEnoughSpace(SpaceInfo)` and queues nothing, as the
   sheet does before calling `trigger`.
3. **`Effect::RequestAddress`**: Swift awaited `client.downloadURL`; the machine has no client, so
   the address is an effect and an answer intent (`AddressReady` / `AddressFailed`).
4. Failure reasons are the German source strings (catalog keys) as constants; the Swift list stores
   the *localised* text, so old entries show whatever language they were written in.
5. A start is refused without a client (`SignIn { client: false }`), as `guard let client`.

Known Swift quirks kept: `allHalt` iterates a snapshot, so a waiting title started by the first
halt's tick is paused by the loop; `progress` does `min(loaded, max(total, loaded))`, which is
`loaded`; `resume` does not check the state; `put_back` does not clear `reason`; a started title
whose address request fails is failed through the normal `failed` path.

## Not ported (platform or other crates)

* `URLSession` background session, `NWPathMonitor`, folder and backup-exclusion, file moves,
  `volumeAvailableCapacityForImportantUsage`, image/subtitle/segment fetching (they are effects).
* `immediateFailed` (polls the list for 4 s; a UI helper, the `Report::Failed` effect replaces it).
* `Downloadposten`/`DownloadReporter`/`DownloadProgress` (the live map is internal).
* `EpisodePreparation.swift`: it is player prebuffering (`Prebuffer`, `PlaybackPlan`), not a
  download rule; it belongs to `swiftly-playback`'s prebuffer and was left alone.
* `LoadSelection`'s views, wording (`gesehen`, `alles da`, counts) and `QualityBadge`/`AudioBadge`:
  the shells draw them; the module returns `SeasonRight`, `CheckboxState`, `FootSpace`.
* `episodePost` that takes a `server` closure is `episode_post_item` (async, generic over the
  future); `sections(stored:server:)` is `DownloadRules::sections`. Neither is used by the machine.

## Risks

1. **Byte text.** `ByteCountFormatStyle(.file)` is Foundation; `size_text::size` approximates it
   (thousands steps, at most three significant digits, none for bytes/KB, trailing zeros dropped,
   "N bytes" under 1000). Only the decimal separator is a parameter. Compare against the device
   before the UI switches to it.
2. **Rounding in `progress`.** `String(format)` ties-to-even on the exact binary value, which is
   what Foundation's default does for these inputs; exact ties are unreachable in practice.
3. **Generation numbers.** Swift seeds the counter with the clock in ms; here the caller passes the
   seed to `DownloadManagerState::new`. A seed of 0 works but can match numbers of an earlier run.
4. **Re-attach details.** The platform must filter `running()` to running/suspended transfers and
   resume the suspended ones when told (`ResumeTransfer`). `CancelTransfer` for an orphan carries
   the orphan's own generation.
5. **Others' list.** The machine keeps the other accounts' entries it was given at sign-in and writes
   them back unchanged. Swift re-read the file at every write; nothing else writes it, so this is
   equal unless a second process writes the list.
6. **Dependencies.** The crate depends on `swiftly-playback` only for `Segment` (and so builds
   `swiftly-library`/`-net` too). If that is too heavy, `Segment` should move to `swiftly-model`.
7. **Timestamps.** `created`/`recent` are `f64` seconds; Swift `Date` is also a double
   (reference-date based), so no precision is lost beyond the offset arithmetic (about 1e-7 s).
8. **`AudioTrackRules`.** `DownloadItem::with_audio` and `DownloadRules::follow_up` take the trait;
   nothing implements it in production yet (`swiftly-playback` should). The tests use a double.

## Dependencies
`swiftly-model`, `swiftly-rules`, `swiftly-playback`, `serde`, `serde_json`. Nothing new in the
lock file besides this crate.
