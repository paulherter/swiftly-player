# swiftly-images

The image logic of the Swiftly core, ported 1:1 from `Packages/JellyfinKit` (`ImageAddress`,
`ImageSelection`, `ImageStoreKey`, `ImageSlab`, `ImageKey`) and the pure parts of
`Sources/Shared` (`ImageTone`, `ImageMood`, `NetworkImage`). It decodes nothing: the UIs decode
and hand over RGBA pixels where a calculation needs them.

## API

- `ImageAddress::construct` / `construct_with` / `user`: the address of an image per server kind
  (Jellyfin `ApiKey`, Emby `api_key`, Plex `/photo/:/transcode` with `X-Plex-Token`), with the
  exact query items and order of the Swift code. `ImageKind`, `ImageMetric`.
- `ImageSelection::{landscape, header, header_with_fallback, logo, portrait}`: which image and tag
  a tile uses, with the series fallbacks and the two extra Plex steps. `Landscape` carries the
  step name for the log.
- `image_key`, `store_key`, `file_name`, `name`: cache keys, byte-identical to Swift (FNV-1a 64
  hex file names, no host or token, only addresses with `tag` go to disk).
- `DiskCache` trait with `FolderPlate` (a folder in `Platform.cache_dir`) and `MemoryPlate`;
  read refreshes the date, `clean_up` removes the oldest until three quarters of the limit.
- `MemoryImageCache<V>` (LRU by byte cost, key table) and `Device` budgets (memory, decode edge,
  disk limit per platform).
- `tone`: `ToneCache` (300 results, unknown vs empty), `tones_from_rgba`, `grid`; `tone::av` is
  `swiftly_playback::av_computation` (the `AvComputation` port).
- `mood`: `mesh`, `detail_mesh`, `noise_tile`, the constants `COLOR_HEIGHT` 900, `RUN_OUT` 1300.
- `color`: OKLab (`ColorSelection`).

## Tests

`cargo test -p swiftly-images`. `tests/fixtures/golden.txt` is the output of the compiled Swift
functions (harness and stubs next to it); see `NOTES.md`.
