# Not ported / deviations

Not ported (outside this crate's scope or UI/platform bound):
- `JellyfinClient` extensions in `Items.swift` (`jeItemInTimes`, `origin`, `rememberedItems`) and all of
  `People.swift` (`title(person:)`, `title(genre:)`, `titleWithNumber`): network calls, belong to the client crate.
- `TitleFilter`, `ListRules` (used by one test in `ItemsTests`): other files.
- Plex/Emby wire types (not needed by `Models.swift`).
- `TrackLabel.language` language-name lookup and the string catalog: `Localizer` hook; `Source` only
  uppercases codes / capitalises words (`TrackLabel.swift:69-70`).
- `DownloadRules.size` byte formatting: `MediaSource::version_detail` takes a closure.
- Swift test `catalogLetterJeLanguage` (reads `.lproj` files): replaced by an English `Localizer` test.

Deviations / risks:
- `Lenient<T>` is the list type (Swift `Lenient`); the number type is `NumberValue` (Swift `NumberValue`).
- `Date` is replaced by `f64` seconds since 1970 (`UserItemData::last_play`, `parse_timestamp`);
  accepts `Z` and `+HH:MM`/`+HHMM` offsets only.
- Swift `Int` is `i64`. `Item` hashes by `id` only, but `PartialEq` compares all fields (as in Swift).
- Case/diacritic folding for `series_suspicion` is a Latin table, not full Foundation folding.
- `caseInsensitiveCompare` in `MediaVersions::matching` is `to_lowercase` equality.
- Strictness is unchanged: a wrongly typed optional field (e.g. `ProductionYear: "x"`) fails that item,
  which `Lenient` then drops, exactly as in Swift.
