# swiftly-library

Library and home logic of Swiftly, ported 1:1 from Swift (`Packages/JellyfinKit`,
`Sources/Shared/HomePageModel.swift`, `Sources/Shared/LibraryModel.swift`).

- Rules without I/O: `ListRules`, `StartRail`/`StartRailsEpisode`, `StartLibraries`, `Refresh`,
  sort/filter enums with their Jellyfin query parameters (`SortingExt`, `LibraryFilter`,
  `RememberGenre`), `LibraryGenre`, `ShelfSource`/`TitleFilter`, `SearchHistory`,
  `CollectionDirectory`, `PlaylistDirectory`, `SeasonSelectionRule`, `JumpTarget`, `ShuffleRun`,
  `PagesRatio`.
- `HomeLoader` over the `HomePageSource` trait (all fetch levels and fallbacks), implemented for
  `swiftly_jellyfin::JellyfinClient` in `client_ext`, which also holds the client-side extensions
  (one entry per work, natural list and page, directories, series state).
- `HomeStore` plus the `Store` and `KeyValue` traits (in-memory implementations for tests).
- `HomeState` and `LibraryState`: the view-model logic as pure state machines. Intents and answers
  go in, state and effect commands come out; the driver does the I/O. See the module docs for the
  step order.

NaturalOrder and AlphabetIndex are in `swiftly-rules`; the endpoints are in `swiftly-jellyfin`.
`NOTES.md` lists the tests translated from Swift, what is not ported, and the risks.
