# swiftly-model

Jellyfin/Emby wire models and their derived properties, ported 1:1 from
`Packages/JellyfinKit` (`Models.swift`, `Items.swift`, `ItemKind.swift`,
`MediaVersions.swift`). Decoding is as forgiving as the Swift code: one broken
list entry is skipped, numbers sent as text are accepted, unknown enum values
never fail a decode. Every Swift rule is cited by file and line in a `///`
comment.

## API

- `ItemsResponse`, `Item`, `UserItemData`, `Person`, `NameId`, `MediaUrl`, `User`,
  `AuthenticationResult`, `PublicSystemInfo` (`serde`, PascalCase keys, `Option` for every optional field).
- `PlaybackInfoResponse`, `MediaSource`, `MediaStream`, `DeliveryMethod`, `ColorRange`.
- `Lenient<T>` (list that drops unreadable entries), `NumberValue` (number as float or string).
- `Item` methods: `direction`, `actors`, `is_container`, `episode_code`, `watched_share`,
  `is_watched`, `new_arrivals_row`, `context_line`, `runtime_seconds`, `kind`, `pre_common_series`.
- `MediaVersions::{choices, start, matching}`, `VersionStart`.
- `Items::{groups, merge, has_double, series_suspicion, ...}`: one entry per work across libraries.
- `ticks_from_seconds`, `seconds_from_ticks`, `parse_timestamp`.
- UI text goes through the `Localizer` trait (`*_with` methods); `Source` returns the German keys as they are.

## Test

```
cargo test -p swiftly-model
cargo clippy -p swiftly-model --all-targets -- -D warnings
```

`tests/swift_tests.rs` is the translation of `ModelsTests`, `ItemsTests` and
`RobustDecodeTests`; `tests/fixtures.rs` decodes sanitized Emby answers from
`tests/fixtures/` with the assertions of `EmbyTests.swift`.
