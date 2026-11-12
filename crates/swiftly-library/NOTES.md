# swiftly-library - port notes

## Tests: Swift tests translated vs. total

| Swift test file | Swift tests | Translated | Where / note |
|---|---|---|---|
| HomePageLoaderTests | 19 | 19 | `home.rs` (scripted `Source`); the log check reads `HomePageSource::log` |
| HomePageStoreTests | 3 | 3 | `home_store.rs` |
| StartRailsTests (StartRails 13 + StartLibraries 5) | 18 | 18 | `start_rails.rs`, `start_libraries.rs`, `home.rs` (`libraryRails`) |
| RefreshTests | 5 | 5 | `refresh.rs` (`Date` is `f64` seconds) |
| LibraryFilterTests | 2 | 2 | `library_filter.rs` |
| LibraryGenreTests | 4 | 4 | `library_genre.rs` |
| SearchHistoryTests | 6 | 6 | `search_history.rs` |
| CollectionDirectoryTests | 5 | 5 | `collection_directory.rs` (catalog replaced by `swiftly_model::Source`) |
| PlaylistDirectoryTests | 7 | 6 | `menu` needs `SectionOffering` (not ported) |
| SeasonSelectionTests | 8 | 8 | `series_state.rs` |
| JumpTargetTests | 3 | 3 | `jump_target.rs` |
| ShuffleRunTests | 1 | 1 | `shuffle_run.rs` (own SplitMix, property check) |
| NaturalPageTests | 2 | 2 | `tests/client_paths.rs` (a request-counting transport instead of `URLProtocol`) |
| ListsRulesTests (ListRules 11 + JeTitleInTimes 5) | 16 | 16 | `list_rules.rs` |
| CompatibilityTests, the 3 `PagesRatio` tests only | 3 | 3 | `pages_ratio.rs` |
| **Total** | **102** | **101** | |

`cargo test` runs 153 tests: the 101 above plus 52 of our own. These are the state machines
(`HomeState` 12, `LibraryState` 12), the mock-transport paths in `tests/client_paths.rs` (9 beyond
`NaturalPage`: loader through the client, failed fetches, one work in two libraries, split-row
fallback, directories with the sliding window, a failing member), `shelf`, `store`, raw values and
query parameters.

## Not ported, and why
- `SortIndexTests`/`AlphabetIndex`, `NaturalOrder`: already in `swiftly-rules`; `Sorting` is re-used
  from there and extended by `SortingExt`.
- `SectionOffering`/`SectionSelection`/`OfferingLayer` (the section menu): not on the list. Only
  `ShelfSource`, `TitleFilter`, `LibraryShare` and `LibraryGenre.canBeMixed/art(toType:)` were taken
  from that file because the library page needs them.
- Labels, symbols and wording of `Sorting`, `LibraryFilter`, `RememberGenre` (`translated(...)`):
  UI strings. `StartRail.lists_name`/`rails_title` stay because a Swift test pins them (catalog keys).
- `LibraryModel`: `loadAlphabet`, `currentAlphabet`, `jumpTarget` (alphabet strip: depends on
  `AlphabetIndex` + a polling loop with `Task.sleep`). `AppModel.naturalList` cache keyed per account.
  `AppModel.items(from:...)`/`indexList`/`remembered` glue (the query assembly is in `client_ext`).
- `HomeModel`: the tvOS branch (`SeriesCache.nextRemember`, `prefetchBundle`) and `SeriesCache.prefetch`
  beyond the `PrefetchSeries` command; `model.loadViews`, `offeringLoad`, `librariesPreOff` are commands.
- `SearchHistory` and `LibraryModel` read/write `UserDefaults`: behind `KeyValue`; the home store file
  is behind `Store` (Swift: `Caches/Startseite/<name>`, atomic write, detached task).
- `LogRing`: `HomePageSource::log` (default: nothing).
- Plex/Emby-specific home sources.

## Home/Library state machines (design)
Swift `async` functions are split at their `await`s into steps (see module docs). `applies()` /
`myOwn == run` become a run token; an overtaken run gets `Step::Stop`/`Fixed::Stop` and changes
nothing. `runningRuns` is decremented on every end of a run (Swift `defer`). `Task.isCancelled`
is a `cancelled` argument. `fill` is an explicit sub-state (`FillStep`), not a loop. `HomeState`
keeps the `change` flag of the run (account switched) for the later genre/library adoption.

## Foundation-dependent risks
1. `ListRules.titleKey` folds with `folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)`.
   Rust: NFD, drop combining marks, `to_lowercase`. Differs from Foundation for a few characters
   (ligatures, ß, special folds); only matters for the key of Movie/Series without provider ids.
2. `SearchHistory`: `count >= 2` counts grapheme clusters (done with `unicode-segmentation`);
   `caseInsensitiveCompare` is `to_lowercase` equality (as in `swiftly-model`); `"\r\n"` is one
   Character in Swift (not split by `split(separator: "\n")`), here it splits.
3. `ShuffleRun`: Swift `shuffled(using:)` sequence is not reproduced (Fisher-Yates over an own RNG);
   unwatched-first and "nothing lost" hold.
4. `Refresh`/`lastLoaded`: `Date` is `f64` seconds; the driver supplies `now`.
5. `HomeLoader.load`: Swift `async let` ordering is replaced by `join5`; genre rows are fetched after
   the fixed rows (as in Swift's `load`), while the *app* starts them in parallel (see `HomeState`).
6. `StartLibraries.read`: a wrong type in an entry (`"id": 5`) fails the whole list, as in Swift
   (the Swift comment promises per-entry reading, but `decodeIfPresent` throws).
7. Query values: encoding is `swiftly-jellyfin`'s; `Ids` order and batch sizes are asserted in tests.
8. Sorting stability: the natural sort is `NaturalOrder::sorted` (offset tie-break); `Items::merge`
   keeps the first minimal element like `min(by:)`.
