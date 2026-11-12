# swiftly-settings

Typed settings for the Swiftly Rust rebuild. The persisted keys are the German names devices already
hold (`tonSprache`, `utAuto`, `pufferstufe`, `immerDirectPlay|<server>` ...) and **never change**.

- `KeyValueStore` (`get`, `set`, `remove`, `keys`; values `Bool`, `Int`, `Double`, `Str`, `Data`, plus
  `[String]` and `[String: String]` because `UserDefaults` holds those for several keys).
  `MemoryStore` and `JsonFileStore` (write-through, atomic rename, unknown entries survive a rewrite).
  On Apple the app-group `UserDefaults` implements the trait.
- `keys::*`: one `Key<T>` const per setting with the Swift default and the Swift `file:line` in its doc
  comment and in `keys::ALL` (the registry). `Option<T>` marks "no default, unset is a state".
- `Settings<S>`: `get` (stored value of the right type, else the default; the same rule as
  `object(forKey:) as? T ?? default`), `set`, `reset`, `get_for_server` (`<key>|<server>`, then the
  device-wide key, then the default), `get_for_server_only`, `buffer_level`, `migrate_subtitle_auto`.
- `server_key(name, server)` builds `name|server` exactly like `Session.serverSuffix`: the address for
  Jellyfin/Emby, `plex:<machine id>` for Plex (`plex_server`).
- Key families: `keys::sort_key` (`sortierung.<library>`), `filter_key`, `search_history_key`
  (`letzteSuchen[.<account>]`), `track_rule_title_key` (`<account>|<id>` inside `utJeTitel`/`tonJeTitel`).
- `options`: `BufferLevel`, `Sorting`, `LibraryFilter`, `RememberGenre`, `StartRail` with their raw
  values, and the option lists (skip seconds, bitrates, sleep timer, speeds).
- `sync`: port of `SettingsSync.swift`: the 19 synced entries (`swiftly.<name>` on the server), text
  encoding and decoding, `remote_from`, `fields_for`, `decide` (newest change wins, whole set at a time;
  another account always takes the server's copy), `change_time`, the Seerr connection step, and the
  `DisplayPreferencesCopy` body merge. Times are milliseconds since 1970.

Device-only by design: Wi-Fi only, downloads, volume, fill screen, buffer, end time, landscape lock,
who-watched, debug keys.
