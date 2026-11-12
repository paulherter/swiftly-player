# Port notes

Source: `Packages/JellyfinKit/Sources/JellyfinKit/{ImageAddress,ImageSelection,ImageSlab,ImageStoreKey}.swift`,
`ImageKey` from `AddressSecret.swift`, `Sources/Shared/{ImageTone,ImageMood,NetworkImage}.swift` (pure parts),
`ColorSelection.swift`.

## Tests translated vs total

| Swift file | @Test | Rust | Where |
| --- | --- | --- | --- |
| `ImageKeyTests` | 4 | 4 | `tests/cache.rs` |
| `ImageStoreKeyTests` | 3 | 3 | `tests/cache.rs` |
| `ImageSlabTests` | 5 | 5 | `tests/cache.rs` (the clean-up test twice: folder and in-memory) |
| `ImageSelectionTests` | 11 | 11 | `tests/selection.rs` |
| `PlexImageTests` | 11 | 11 | `tests/selection.rs` (the 11 `swiftly-plex/NOTES.md` left here; items are mapped with `PlexMapper`, a dev-dependency) |

34 of 34 translated. New: 9 golden tests (`tests/golden.rs`), 6 more in `tests/cache.rs` (memory plate, exact
three-quarter stop, memory cache LRU/key table/budgets, tone cache cap), 2 in `tests/selection.rs` (header and
fallback, logo). `ColorSelectionTests` (3) and `AvComputationTests` (5) are not repeated: `AvComputation` is ported and
tested in `swiftly-playback`; the golden tests cover its numbers and `ColorSelection`.

## Golden numbers

`tests/fixtures/golden.txt` comes from `swiftc` (Xcode 6.3.3) compiling the real Swift files `ImageAddress`,
`ImageStoreKey`, `ImageSlab`, `AddressSecret`, `AvComputation`, `ColorSelection` with a 10-line stub for `ServerKind` /
`EmbyPaths.tokenName` and the harness `golden_harness.swift` (the mesh and noise loops of `ImageTone.swift` are copied
into it verbatim, since that file needs SwiftUI). It pins 19 addresses and 4 user addresses (Jellyfin, subpath base,
awkward characters, Emby, Plex all variants), 12 key addresses (image key, store key, file name), hashes, tones of 8
synthetic images, `hsb`/`color`/`points`/`decay`, OKLab, the mood mesh, the 5x5 grid and the 96x96 noise tile.
Numbers agree to 1e-9; keys and URLs are compared as strings.

## Key compatibility

Existing disk caches stay valid: the file name is FNV-1a 64 of the store key, and `tests/golden.rs`
(`keys_and_file_names_match_swift`, `a_known_disk_key`) shows Swift and Rust give the same key and name for 12 addresses,
for example `…/Items/abc/Images/Primary?fillHeight=600&tag=f00&ApiKey=geheim` -> `/Items/abc/Images/Primary?fillHeight=600&tag=f00`
-> `704a6685d9e01d56`. Cache files are named by hash only, so the folder (`Bilder` in the cache directory) is shared as is.

## Reused, not duplicated

- `image_key` is `swiftly_jellyfin::image_key` plus one case: when the token was the only query item Swift leaves an
  empty query (`…/i?`), jellyfin drops it. The wrapper in `store_key.rs` adds it back. Better to fix it in
  `swiftly-jellyfin` and make this a plain re-export.
- `AvComputation` (tones, hsb, color, decay, points) is `swiftly_playback::av_computation`, re-exported as `tone::av`.
  `color.rs` ports `ColorSelection` completely, so four small functions (`oklab`, `srgb_from_lab`, `linear`, `gamma`)
  exist twice until playback switches to this crate's (it cannot: images depends on playback). Moving `color.rs` into
  `swiftly-playback` or a lower crate would end that.
- The query builder in `url_build.rs` is the same as `swiftly-jellyfin`'s `build_url`, which is `pub(crate)`. Making it
  `pub` there would remove the copy (about 30 lines).
- `swiftly-plex` has its own `PlexPlayback::image_url` / `PlexClient::image_url_for` (the older `PlexClient` path:
  `quality` 90, no `minSize`, optional sizes). It is a different Swift function and stays; the tile and detail code
  should call `ImageAddress` here.

## Not ported, and why

- Decoding, `CGImageSource` thumbnails, `SwiftUI.Image`, `MeshGradient`, `Theme`: UI. `ImageTone.audioOut` is
  `tones_from_rgba` after the UI has decoded to at most 48 px.
- Async parts: `ImageTone.tones(for:)` download and in-flight de-duplication (`ongoing`), `ImageCache.load` with its
  fetch gate (4 at once, 2 conversions), priority, `DevicesStore` (profile pictures on device), memory warning
  notification. They need the transport and the UI's decode; the core would call `MemoryImageCache::wipe`.
- `ImageStore` singleton (`Caches/Bilder`, once-per-launch clean-up): the caller makes a `FolderPlate` in
  `Platform.cache_dir` and calls `clean_up` on the first write.
- `ColorSnap.swift` (`ColorRange`, `ColorInfo`) is video dynamic range, not an image tone; it lives with the media model.
- `ColorSelectionTests` / `AvComputationTests` (see above).

## Deviations and risks

- URLs are `url::Url`, not `Foundation.URL`. For addresses the builder emits, both give the same string (golden). For
  hand-written odd addresses fed to `image_key` (uppercase hosts, dot segments) `Url` normalises where Foundation does
  not, so such a key could differ; the app only feeds addresses built here.
- `image_key` removes tokens by raw name compare; Swift decodes the names and re-encodes the other items through
  `URLComponents`. They agree for everything the builder emits (it never writes `%2B` or `%2C`); an address from
  elsewhere with such escapes could differ.
- `store_key` decodes only percent escapes of the item name to find `tag` (case-insensitive), like `URLQueryItem.name`.
- `FolderPlate`: sizes and dates come from `std::fs`; subfolders are ignored by clean-up (Swift would count them as
  0 bytes, oldest first, and could delete an empty folder). `.part` temp files from a crash stay until the next
  clean-up counts them. The read-refreshes-date step needs a writable file; on a read-only mount it silently skips.
- `MemoryPlate` dates are a counter, not time, so tests set them with `set_stamp`.
- Dates in `eviction` sort stably (Swift's `sort` is not); only ties differ.
- `Landscape.source` keeps the German log texts of Swift.
- `ImageSelection` default widths are consts (`LANDSCAPE_WIDTH` 600, `HEADER_WIDTH` 1200, `LOGO_HEIGHT` 240,
  `PORTRAIT_HEIGHT` 480), because Rust has no default arguments.
