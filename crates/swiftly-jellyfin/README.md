# swiftly-jellyfin

Jellyfin and Emby client of the Swiftly core, ported from `Packages/JellyfinKit`.

`JellyfinClient<T: HttpTransport>` builds every request exactly like the Swift client: same paths, same query order and
encoding, same headers (`Authorization: MediaBrowser Client=…`, own gateway headers, `Accept`, `Content-Type`), same JSON
bodies. Emby paths are rewritten (`emby_rewrite`), the token query is `api_key` there.

Covered: public system info, address check, password sign-in (with two-factor detection), sign-off, session check,
Quick Connect, public users, views, items queries, count / ids / ancestors / watchlist / collection / playlist lists,
PlaybackInfo (device profile is any `Serialize` value), item, genres, similar, extras, trailers, search, user data,
favourite, watched, seasons / episodes / next up, resume, newly added, metadata refresh, stream / image / trickplay
addresses, playback reporting (start, progress, stopped, stop encoding), `PendingReport` store rules and late reports,
own headers table, address-check state, secret masking for logs.

What is left out is listed in `NOTES.md`.

Tests: `cargo test -p swiftly-jellyfin`. `tests/request_golden.rs` asserts the exact request of each call against a mock
transport. One test is `#[ignore]`d and reads `JF_URL`, `JF_USER`, `JF_PASS` from the environment.
