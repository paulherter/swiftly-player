# swiftly-plex

Plex Media Server support of the Swiftly core, ported 1:1 from
`Packages/JellyfinKit/Sources/JellyfinKit/Plex`.

| Module | Swift source | What |
| --- | --- | --- |
| `wire`, `loose` | `PlexWire.swift` | answers of a server, read leniently (numbers as text, bad list entries skipped) |
| `PlexMapper` | `PlexMapping.swift` | wire types into `Item`, `MediaSource`, `MediaStream`, `Segment`, `Chapter` |
| `merge` | `PlexMerge.swift` | several libraries as one sorted list, page windows |
| `PlexPlayback`, `PlexBif` | `PlexPlayback.swift`, `PlexBIF.swift` | file / subtitle / photo-transcode / preview addresses, direct-play plan, `/:/timeline` query, BIF parser |
| `PlexAccountService` | `PlexAccount.swift` | plex.tv PIN sign-in, token check, server list, Plex Home profiles |
| `PlexConnector` | `PlexConnections.swift` | which address of a server to use (rank, probe, grace) |
| `PlexClient` | `PlexClient.swift` | the REST calls, route switching, preview cache |
| `media_server` (impl) | `PlexClient+MediaServer.swift` | `MediaServer` and `HomePageSource` for `PlexClient` |
| `PlexIdentity`, `PlexError`, `PlexFeatures`, `PlexAccountSession` | `PlexIdentity.swift`, `PlexFeatures.swift`, `PlexSession.swift` | headers, errors, capabilities, session block |

The `MediaServer` trait itself lives in `swiftly-playback` (`media_server.rs`), because it names
`PlaybackPlan`, `Segment` and `Trickplay` from there and the list types from `swiftly-library`.

The crate never opens a connection by itself. Every client is generic over
`swiftly_net::HttpTransport`; the tests use a closure-driven stub and `MockTransport`. The caller
also hands in the timers (`Sleep`) used for the PIN poll, the connection grace and the
silent-address rule, since the crate has no runtime.

```rust
let client = PlexClient::new(base_url, token, identity, Arc::new(ReqwestTransport::new(..)));
let views = client.views().await?;
```

Tests: `cargo test -p swiftly-plex` (fixtures in `tests/fixtures`, copied from the Swift tests).
