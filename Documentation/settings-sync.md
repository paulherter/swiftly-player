# Settings sync

Settings that belong to the person, not the device, are kept on the Jellyfin
server and applied on every device. No plugin: the server's own
display preferences carry them.

## Where

| | |
|---|---|
| Endpoint | `GET` / `POST /DisplayPreferences/swiftly?userId=<user id>&client=Swiftly` |
| Display preferences id | `swiftly` (any string; the server hashes it) |
| Client | `Swiftly` (the server column holds 32 characters at most) |
| Payload | `CustomPrefs`, a dictionary of strings |

`POST` replaces the whole set, including the fields the server maps itself. So
always: `GET`, change only the `swiftly.*` keys inside `CustomPrefs`, send the
**whole body back**. Keys that do not start with `swiftly.` are never touched.
Old servers that answer with an error: do nothing, say nothing.

## Keys

Every key is `swiftly.` plus the name below. Values are text.

| Name | Encoding | Meaning |
|---|---|---|
| `changed` | integer, ms since 1970 | time of the last change of the set |
| `format` | `1` | version of this scheme |
| `tonSprache` | text | preferred audio language, empty = server decides |
| `utSprache` | text | preferred subtitle language |
| `utAuto` | `true`/`false` | subtitles automatically |
| `naechsteAuto` | `true`/`false` | next episode automatically (only present once chosen in the app) |
| `introAbspannAuto` | `true`/`false` | skip intro and credits automatically |
| `restzeitAlsEnde` | `true`/`false` | show the end time instead of the time left |
| `vorSek` | integer 0 to 3600 | seconds forward |
| `zurueckSek` | integer 0 to 3600 | seconds back |
| `titelAlsLogo` | `true`/`false` | title as logo |
| `fortschritt` | `true`/`false` | progress on tiles |
| `merklisteAn` | `true`/`false` | watchlist shown |
| `alphabetAn` | `true`/`false` | letter strip beside lists |
| `neuGetrennt` | `true`/`false` | new movies and new series as separate rows |
| `startReihen` | JSON array of strings | order of the fixed home rows (`continueWatching`, `nextEpisode`, `newMovies`, `newSeries`, `newArrivals`) |
| `startAus` | JSON array of strings | hidden home rows (same names) |
| `genreChips` | `true`/`false` | genres as chips instead of rows |
| `startGenres` | JSON array of strings | genres on the home page |
| `startBibliotheken` | JSON array of objects | libraries and collections as home rows: `[{"id": "...", "name": "...", "sammlung": false}]` (`sammlung` = collection) |

A key that is missing means "not chosen on any device"; the receiving device keeps
its own value. Unknown or damaged values (wrong type, integer out of range, bad JSON) are
ignored one by one.

Not synced, stays on the device: Wi-Fi only, downloads, volume, fill screen,
fixed landscape, buffer level, technical badge, frame rate matching, counters,
what's-new and rating state, Discord display, debug switches, direct play and bitrate
limit (per server), looks.

## Who wins

The whole set is compared by `swiftly.changed`; the newer side wins.

1. Each device keeps the time of its last local change (or the time it took from the
   server). A new change gets the current time, but never one earlier than the newest
   server time it has seen.
2. On start, on sign-in, on account switch and when the app comes to the front the
   device fetches the set.
   - Server copy newer, or the device last synced with another account, or the device
     never changed anything: **apply** the server's values.
   - Server copy older, or none: **write** the device's values (with its time).
   - Same time: nothing.
3. After a local change the device waits about 2 seconds, then runs step 2 again
   (fetch, compare, merge, write).

A switch in the settings turns all of this off ("Einstellungen auf allen Geräten
gleich halten", on by default). Changes made while it is off still get a time, so
turning it on again sends them if they are newer.

Code: `Packages/JellyfinKit/Sources/JellyfinKit/SettingsSync.swift` (keys, encoding,
decision, requests) and `Sources/Shared/SettingsSyncRun.swift` (watching the device,
applying).
