# Port notes

## Endpoints (apple-logic.md 2.1 / 2.2 / 1.2)

Done (request builder + golden test): System/Info/Public (+ address-check timeout), AuthenticateByName, Sessions/Logout,
Users/{id} (session check), Users/Public, UserViews, Items (generic, count, ids, slim, remembered, collection members,
`Ids`), Items/{id}/Ancestors, Playlists/{id}/Items, Items/{id}/PlaybackInfo, Items/{id}, Genres, Items/{id}/Similar,
SpecialFeatures, LocalTrailers, search, UserItems/{id}/UserData (GET, last-played set, point back), UserFavoriteItems,
UserPlayedItems, Shows/{id}/Seasons, Shows/{id}/Episodes (all, season, first, adjacentTo, Emby NextUp fallback),
Items/{id}/Refresh, Shows/NextUp, UserItems/Resume, newly joined (Items), QuickConnect/Initiate, QuickConnect/Connect,
Users/AuthenticateWithQuickConnect, Sessions/Playing, /Progress, /Stopped, Videos/ActiveEncodings, stream / image /
backdrop / trickplay-sheet / user-picture addresses, Emby path rewrite and token name, PendingReport rules and late
reports, OwnHeaders, CheckState, secret masking.
= 41 of 56 listed calls/addresses.

Not done (needs types that are not in `swiftly-model` yet, or belongs to another crate):
- `GET Items/{id}?Fields=Trickplay` manifest, `Fields=Chapters`, `MediaSegments/{id}` (Segment, Trickplay, Chapter types).
- `GET Users/{id}` -> `AccountPreGift` (`accountDefaults`, download permission state), `GET JellyTwiggy/.../Watchers` (`Watcher`).
- `GET Sessions`, `POST Sessions/{id}/Playing/{command}`, `POST Sessions/{id}/Message`, `POST Sessions/Playing` play-on
  (`RemoteSession`, `ForeignCommand`, `Takeover.hintHeader`), `Sessions/Capabilities/Full`, the WebSocket.
- `QuickConnect/Enabled` and `QuickConnect/Authorize` (QuickConnect.swift, not read), AirPlay plan (:1314),
  download/convert URLs (`Videos/{id}/stream.{container}` :1413-1500), `playbackPlan` (needs `PlaybackPlan`).
- `HEAD`/UDP discovery, `ServerURL` normalising (`AppModelURLNormalizer`), Plex.

Post-processing left to the library crate (the Swift client does it inside the call): `jeItemInTimes` (one entry per work)
after resume / next up / search, `NaturalOrder` sort after search, `ListRules.titleKey` self-filter in `similar`,
`VideoPlaylist.isVideoEntry` filter in `playlist_entries`. The Rust calls return the raw lists.

## Device profile

`DeviceProfile` is not in `swiftly-model`. `playback_info` takes any `impl Serialize` plus the profile's
`MaxStreamingBitrate`. TODO for the playback crate: port `DeviceProfile.vlc()` / `.airplay()` (DeviceProfile.swift) and
pass it in; the body around it (`UserId`, `MaxStreamingBitrate`, `AutoOpenLiveStream`, `EnableDirectPlay`,
`EnableDirectStream`, `EnableTranscoding`, optional `AudioStreamIndex`, `SubtitleStreamIndex`, `MediaSourceId`) is done and tested.

## Deviations

- Query encoding follows `URLComponents.queryItems`: letters, digits and `-._~!$'()*+,/:;?@` stay, everything else is `%XX`.
  Verified by reading, not by running Foundation: the local Swift toolchain is broken (`swiftc` fails on the SDK), so the
  `+` and `'` cases are from memory of swift-foundation. If the live check shows a difference, change `encode_query_value`.
- JSON key order of bodies is the struct's field order (Swift's `JSONEncoder` order is unspecified); tests compare values
  except for the progress body, where the order is asserted as declared.
- `Authorization` only; no `X-Emby-Authorization` is sent (the Swift client does not either, it is only on the locked list).
- `AddressCheck.session(for:)` (home network waits for the local-network prompt, outside does not) has no counterpart:
  `check_reachability` sets an 8 s timeout on the request. `waitsForConnectivity` is Apple only.
- `Session.server_url` is the address as given (String), not a `URL`.
- `Date` is `f64` seconds since 1970 (as in `swiftly-model`); `PendingReport` still reads and writes `wann` in
  seconds since 2001 so stored files stay compatible.
- Added to `ErrorKind` beyond `JellyfinError`: `QuickConnectExpired` (was its own Swift error type) and `Cancelled`
  (`CancellationError`). `Transport(String)` became `Transport(TransportReason)`, because the sentences are wording.

## Changes to swiftly-model

None.
