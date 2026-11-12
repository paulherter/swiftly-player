# swiftly-settings notes

Key count: 68 fixed keys in `keys::ALL` (the test `registry_is_consistent_with_the_sync_table` pins the synced
subset at 19 and the per-server subset at 3). Key families (not in `ALL`): `sortierung.<library>`,
`filter.<library>`, `letzteSuchen.<account>`, and the per-server variants of `immerDirectPlay`,
`bitratenGrenze`, `startBibliotheken`.

## Kept raw or uncertain (apple-settings.md says unclear)

- `utJeTitel`, `tonJeTitel`: per-title dictionaries; the value enum (`name(String)` / `track(imprint)`)
  has no documented plist shape. Held as `[String: String]`. If Swift stores nested values the Apple
  `UserDefaults` adapter must hand them over as a JSON string per entry.
- `support.status`, `support.usage`, `support.promptHistory`: JSON, but whether `Data` or `String` is not
  documented. Typed as bytes; a stored string reads as its UTF-8 bytes (and `String` keys read UTF-8
  `Data`), so either way works.
- `support.key`, `support.keyChecked`, `support.plan`, `support.appIcon`: read as strings; the stored type of
  `keyChecked` (date? flag?) is not documented.
- `nachmeldungen`, `letzterServer`: Data, semantics not documented.
- `restzeitAlsEnde`: synced by name but no Swift reader exists (the views use `endzeitImPlayer`, device-only).
  Kept as `Option<bool>`; probably a stale name.
- `einstellungenSyncZeit` / `einstellungenSyncServer`: doc says "timestamp"; the Swift code stores
  milliseconds since 1970 as `Double` (`SettingsSyncRun.swift:105,215`).
- `whatsnew.lastSeen`: apple-settings.md could not locate the value; it is `WhatsNew.lastSeenKey =
  "whatsnew.lastSeen"` (`WhatsNew.swift:81`).
- Not settings, deliberately absent: `zeilen.an`, `zeilen.aus`, `flug.*`, `zoom.*` (Core Animation keys in
  `HandoffStage.swift`), `aktiveArt` (a Keychain account), `session`, `konten*`, `eigenkoepfe`, `seerr`
  (Keychain, see ARCHITECTURE "Storage").
- Line numbers for iOS/macOS/tvOS readers are the first one given in apple-settings.md; further readers are
  listed there.

## Differences from the Swift sync code

- `Date` is `i64` milliseconds. `SettingsSync.Value.List` encodes with `\/` for slashes to match
  `JSONEncoder`.
- `SubtitleLook`/`StartLibraries` are opaque JSON bytes here; their codecs are separate crates.
- The `DisplayPreferences` HTTP calls are not ported (network layer).

## Not done

- No `UserDefaults` adapter (Swift side, via UniFFI later) and no SharedPreferences importer.
- Typed structs for `SubtitleLook`, `StartLibraries`, `LookSelection`, `SupportStatus`.
- The "apply" side effects of `SettingsSyncRun.swift` (what happens when the server wins).
