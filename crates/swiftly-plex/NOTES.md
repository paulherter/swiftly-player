# Port notes

Source: `Packages/JellyfinKit/Sources/JellyfinKit/Plex/*.swift` (incl. `PlexAccount.swift`, 404 lines, which the
task list did not name but the sign-in flow lives in) and the Swift tests `Plex*Tests.swift`.

## Tests translated vs total

| Swift file | @Test | Rust | Where |
| --- | --- | --- | --- |
| `PlexTests.swift` | 43 | 43 | `tests/plex_tests.rs` |
| `PlexMergeTests.swift` | 7 | 7 | `tests/server_tests.rs` |
| `PlexFilesTests.swift` | 5 | 5 | `tests/server_tests.rs` |
| `PlexServerTests.swift` | 17 | 16 | `tests/server_tests.rs` (`bundle` skipped) |
| `PlexImageTests.swift` | 11 | 0 | not ported, see below |
| `PlexRouteTests.swift` | 1 (live) | 0 (+1 mock version) | `stale_route_moves_after_silence` |
| `PlexFixtures.swift` | fixtures | 10 JSON files | `tests/fixtures/` |
| (new) golden tests, `MockTransport` | - | 4 | `tests/golden.rs` |

Total: 84 Swift tests, 71 translated, +1 mock replacement of the live route test, +4 golden tests (28 calls with
method, path, query and headers; plex.tv calls; address builders) = 76 Rust tests in 3 files. No `#[ignore]`d live
test was written.

## REST calls (apple-logic.md 2.5 and 1.3)

Done and golden-tested: 32 of 32 listed calls (26 server routes: identity, sections, section all, genre, continue
watching, on deck, recently added x2, hubs x2, search, metadata, children, allLeaves, similar, extras, collections,
collection children, playlists, playlist items, filter by person/genre, scrobble/unscrobble, rate, track choice,
timeline, refresh, remove-from-continue-watching, BIF index; plex.tv: pins POST/GET, user, resources, home users,
switch) plus the three address builders (file/download, subtitle, photo transcode). Tests assert the exact path,
query string, the `X-Plex-*` headers, paging headers and the 20 s timeout.

## Not ported, and why

- `PlexImageTests` (11): all of them test `ImageAddress` / `ImageSelection` / `ImageKey`, which belong to the images
  crate (`swiftly-images`), not to Plex. The Plex part they pin (`/photo/:/transcode`, both sides, token last,
  absolute person URLs) is covered by `images` and `address_builders` in this crate.
- `PlexServerTests.bundle`: `AccountBundle.fitsServer` is the accounts crate. `PlexAccountSession::server_identity`
  and `account_key` (what it uses) are tested.
- `PlexTests.PlexStub` (URLProtocol): replaced by the closure-driven `Stub` transport in `tests/common`.
- `PlexClient.make(...)` (MediaServerFactory glue with `#if os(...)` platform names): the caller builds a
  `PlexIdentity`; `PlexClient::signed_out_copy` is not in the trait (see below), build a second client from
  `transport()` and `base_url()`.
- `PlexIdentity.thisDevice(...)`: platform names come from `cfg` in the Swift code; here the caller passes them.
- `URLSession.localNetworkCapable` / `PlexConnector.probeSession`: the Apple-only session choice has no
  counterpart; the probe sets the per-request timeout (3 s, relay 6 s) on `HttpRequest`.
- `MediaServer` members without a Rust type yet: `watchers` (`Watcher`), `airplayPlan` (`AirPlayInfo`),
  `signedOutCopy`, DEBUG `userDataRaw`/`userDataBackPut`, `stateInSeries` stays, the Jellyfin-only helper protocols
  (`QuickSignIn`, `RemoteSessionServer`, `DisplayPreferencesServer`, `ActiveEncodingServer`). `naturalList` and
  `naturalPage` are inherent methods of `PlexClient` (they need the caller's `NaturalCollator`), not trait methods.
- `VideoPlaylist.isVideoEntry` / `ListRules` post-filters other than the ones the Swift Plex code itself calls.

## Where the MediaServer trait lives

`crates/swiftly-playback/src/media_server.rs` (new file, one `pub mod` line in its `lib.rs`, one `swiftly-net`
dependency line in its `Cargo.toml`). It cannot sit in `swiftly-model` or `swiftly-jellyfin`: it names `PlaybackPlan`,
`Segment`, `Trickplay` (playback), `PlaylistDirectory`, `ShelfSource` (library). It extends `HomePageSource` like the
Swift protocol. `ServerCapability` (18 cases) is defined there too. A Jellyfin/Emby client can implement the trait from
a crate above `swiftly-jellyfin`; this crate implements it for `PlexClient`.

## Deviations and risks

- **Errors.** Swift throws `PlexError` and `JellyfinError` side by side. Here `PlexError` has a `Request(ErrorKind)`
  case and all client calls return `PlexError`. The trait speaks `ErrorKind`; a Plex case travels as
  `Transport(Other("plex:<case>"))` and `PlexError::from_kind` reads it back. The l10n crate must map those strings
  (or look at `PlexError::text_key` first).
- **Concurrency.** No runtime. `withTaskGroup` became `join_all` / `FuturesUnordered` (futures-util); the
  single-flight route search is a `Shared` future; timers (`Sleep`) are injected: PIN poll pause, the grace in
  `PlexConnector::choose`, the 4 s silence rule of an unconfirmed stored address (`PlexClient::with_sleep`; without a
  timer the first request is plain). Cancelling means dropping the future. The `PlexClient` guards its state with a
  `std::sync::Mutex` that is never held across an `await`.
- `adopt` (route switch) is idempotent: callers that shared one search all end in it, but only the call that really
  changed the route tells `on_session_change`. Swift's actor would tell again for an identical route.
- `PlexSessionDetails.user_image` is a `String`, not a `URL`. The shared `Session` has no `plex` field, so the Plex block
  is `PlexAccountSession { session, plex }` with `to_json`/`from_json` (same keys as Swift, block written only when
  present). `account_key` for Plex (`plex:<machine>|<user>`) is defined here, not on `Session`.
- Dates: `Item.dateCreated`/`lastPlayedDate` are formatted by `PlexMapper::iso_date` (`2023-11-14T22:13:20Z`, like
  `ISO8601DateFormatter`); `PendingReport` times are seconds since 1970 as in `swiftly-jellyfin`.
- `PlexIdentity::make_client_id` and the client's `session_id` take their randomness from std's randomly keyed hasher
  (no `uuid`/`rand` dependency); the output is a valid UUID v4. Do not use it where unpredictability matters.
- Genre names are sorted by lower-cased text, not by `localizedCaseInsensitiveCompare`; `titleSort`-style comparisons
  in `merge` use byte order of the lower-cased text (Swift: Unicode string order).
- Query encoding of the REST calls follows `PlexPlayback.escape` (everything but `A-Za-z0-9-._~` is `%XX`), as in
  Swift; the plex.tv calls use `swiftly_jellyfin::encode_query_value` (the `URLComponents.queryItems` rule, whose
  `+`/`'` cases are unverified, see that crate's notes).
- `PlexMetadata`, `PlexStream` ... keep the Swift field set; the `Guid` list is reduced to its ids.
- Not verified against a real server or plex.tv by design (task rule); shapes come from the Swift fixtures.
