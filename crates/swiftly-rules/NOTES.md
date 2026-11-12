# swiftly-rules - port notes

## Test count (Swift tests in the source test files vs. Rust tests with the same inputs)

| Swift test file | Swift tests | Translated | Not translated |
|---|---|---|---|
| NaturalOrderTests | 6 | 6 | - |
| AlphabetIndexTests | 5 | 5 | - |
| DelayTests | 8 | 8 | - |
| DownloadQualityTests | 12 | 7 | 5 |
| DownloadRightTests | 7 | 3 | 4 |
| DownloadAudioTests | 14 | 7 | 7 |
| DisplayRulesTests | 12 | 12 | - |
| AgeRatingTests | 3 | 3 | - |
| ChapterTests | 22 | 20 | 2 |
| PlaybackTickTests (tick 24, TimeAssumption 5, EpisodeEnd 3, PlaybackLevels 3, PlayTime 3) | 38 | 38 | - |
| EpisodesCardTests | 15 | 8 | 7 |
| EpisodesSwitchTests (6 switch + 2 StopLock) | 8 | 8 | - |
| NotchesSnapTests | 5 | 5 | - |
| BufferLevelTests | 6 | 6 | - |
| LanguageTests | 3 | 3 | - |
| **Total** | **164** | **139** | **25** |

(`cargo test` runs 148: the 139 plus 9 extra tests, e.g. whole_number, the other index orders,
collator option flags, raw values.)

Adapted translations (same inputs/expectations, different shape):
- `Delay.text`: the unit is catalog text, so the Rust test appends " s" itself.
- `DownloadQuality.gemeinsam`: `DownloadItem` reduced to its level (`guete`).
- `DownloadQuality.phrases`: `Locale` became the decimal separator.
- `tileCharacter`: `Item` reduced to `type` and `seriesId`.
- `BufferLevel.namesPresentAndDistinct`: names are catalog strings; distinctness is checked on raw values.
- `ChapterInReadTests.inRead`: JSON decoding is `swiftly-model`; the tick conversion and name trimming are tested with the same values.
- `DownloadAudioTests`: `TrackImprint`/`TrackLabel`/`TrackRule` are a test double behind the `AudioTrackRules` trait.
- `EpisodesCardTests.endDoesNotSwitchPastCountdown`: only the `EpisodeEnd.advance` assertions (the `OfferingLayer` that produces `cardCounts` is not ported; `true` is passed in).

### Not translated, and why
- DownloadQualityTests: `entries`, `share` (need `DownloadItem`), `subtitle` (`SubtitleFile`, `MediaStream`, URL building), `address` (`JellyfinClient`), `audioRight` (`AccountPreGift` JSON).
- DownloadRightTests: `outResponse` (`AccountPreGift` JSON), `noAddressIfForbidden`, `addressIfAllowed`, `accountSwitch` (`JellyfinClient` + `URLProtocol` stub).
- DownloadAudioTests: `itemWithAudio`, `oldList` (`DownloadItem`), `address` (`JellyfinClient`), `end`, `following`, `followUp`, `replaced` (`DownloadRules`, not on the list).
- ChapterTests: `without`, `withoutStart` (serde decoding of `ChapterResponse`/`Lenient`; belongs with `swiftly-model`).
- EpisodesCardTests: `noCreditsInLastThirtySeconds`, `withCreditsAppliesCredits` (`SectionLogic`, `Segment`), `controlsCoveredAndHoldsAn`, `cancelSaysNextOff`, `withoutToggleHowUntilFrom`, `atEndCountsCountdownNext`, `jumpSetsCountdownBack` (`OfferingLayer`).

## Types that would need `Models.swift` (not ported; local plain inputs instead)
- `AlphabetIndex`: `IndexItem` struct (name, sort_name, premiere_date, production_year, community_rating, date_created) and a local `Sorting` enum replace `Item`/`Sorting`. `swiftly-library` should map its model onto these or re-export.
- `DownloadAudio`: `AudioStream` struct replaces `MediaStream`; `AudioTrackRules` trait stands in for `TrackLabel`, `TrackImprint`, `TechDetails`, `TrackRule` and the catalog strings. `swiftly-playback` implements it.
- `DisplayRules.tileCharacter`: takes the two fields instead of `Item`. `AgeRating`: takes `Option<&str>`.
- `Chapter`: no serde; `Chapter::from_ticks` does the conversion. Decoding is `swiftly-model`'s job.
- `DownloadQuality.gemeinsam`, `DownloadItem.withAudio`/`inQuality`: need `DownloadItem`; only the level logic is here.
- Added `time_assumption` (not on the requested list) because `PlaybackTick` calls it; `Date()` inside it became a `now` parameter.

## Not ported (pure but outside the list, or non-pure)
- `JellyfinClient` extensions in NaturalOrder.swift (`naturalList`, `naturalPage`); `NATURAL_BATCH` (100) is kept as a constant.
- Catalog wording: `BufferLevel.name`, `Bitrate.text`, `LanguageSelection.all` default label, `DownloadQuality` "Original"/"Direct Play" labels, `translated(...)` everywhere. Functions return `None` or take the label.
- `SpeedLevels.label` / `DownloadQuality.addition` use `Locale` number formatting in Swift; here only the decimal separator is a parameter (up to 3 / 1 fraction digits).

## Foundation-dependent behaviour (risks)
1. **NaturalOrder collation.** Swift: `String.compare(_, options: [.numeric, .caseInsensitive, .widthInsensitive], locale:)` (CoreFoundation/ICU, not `localizedStandardCompare`). Rust: ICU4X `Collator`, secondary strength, numeric ordering, tailored to the locale. Matches all Swift test cases (ru: Ё with Е; de: umlauts). Can differ from Apple for: punctuation/whitespace weights, symbols, leading zeros in numbers ("007" vs "7" are equal here, ties keep server order), CLDR version. Locale is passed as a string ("ru", "de_DE"); empty gives root.
2. **`Character` semantics.** `isLetter`/`isNumber` look at the first scalar of a grapheme cluster (`Alphabetic` / has a numeric type). Implemented with `unicode-segmentation` + `char::is_alphabetic`/`is_numeric` (N* categories; differs from `numericType != nil` only for a few CJK numerals that are alphabetic anyway). Unicode data version of Rust's std may differ from the OS.
3. **AlphabetIndex.letter(for:).** `uppercased()` is the locale-free full mapping (ß gives SS, first character S). The accent strip is NFD first scalar for U+00C0-U+024F and U+0600-U+06FF. A *decomposed* "e + accent" uppercases to "E + accent", which is outside the range and is returned whole (a quirk of the Swift code, reproduced). `== "Ё"` is canonical equivalence (NFC compare). Two different letters with the same first scalar are ordered by first appearance here; Swift's tie order depends on dictionary iteration (random).
4. **Language.detected.** `lowercased()` maps per scalar (no final-sigma rule); text and forms are NFC-normalised so `Set.contains`/`contains` match Swift's canonical equivalence; word split uses grapheme clusters. Substring `contains` is byte-wise after NFC (Swift matches on Character boundaries; differs only for a form that ends inside a grapheme cluster).
5. **AgeRating / searchTermFits.** `.whitespaces` is Zs + tab, `.whitespacesAndNewlines` additionally U+000A-U+000D, U+0085, U+2028, U+2029; the Rust sets equal these. `count`, `hasPrefix("age")`, `dropFirst(3)` count grapheme clusters, as implemented.
6. **Integer/float.** Swift `Int` is 64-bit; `Int(Double)` traps on overflow/NaN where Rust saturates (`as`), mostly through `whole_number::capped`; the traps are unreachable in the tested ranges. `rounded()` = `f64::round`. Comparisons with NaN keep Swift's guard behaviour (explicit `is_nan` checks where a `guard x > c` was used).
7. **Time.** Swift's `TimeAssumption` read `Date()` internally; the Rust functions take `now`. Production callers pass the real clock, so behaviour is the same.
8. **EpisodeSwitch.** The actor isolation (`#isolation`) is gone; `execute` is a plain `Send` future (side-by-side stop/plan via `futures_util::future::join`, no executor needed). `close` returns the stop to run now instead of spawning a `Task`; the caller must run it. Swift's `Task { await stopNow() }` fire-and-forget becomes the caller's responsibility.
9. **Sorting stability.** Swift's `sort` is stable in practice but not documented; the Rust port uses an explicit offset tie-break like the Swift code, so equal names keep the server order.

## Dependencies (new in `Cargo.lock`)
`icu_collator`, `icu_locale_core` (collation), `unicode-normalization`, `unicode-segmentation` (Character/String semantics), `futures-util` without default features (`join`), dev: `futures-executor`.
