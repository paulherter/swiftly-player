# swiftly-net

The network seam of the Swiftly core. Clients are generic over `HttpTransport`; the app picks the transport.

- `HttpTransport`: `async fn send(HttpRequest) -> Result<HttpResponse, ErrorKind>`. A non-2xx status is an answer, not an error.
- `ReqwestTransport` (cargo feature `reqwest`, default): reqwest 0.13 with rustls and the OS certificate verifier (`rustls-platform-verifier`), system proxy, cookie jar, timeouts 15 s idle / 20 s total (`NetworkSession.swift`), hand-rolled redirects (headers are dropped on other origins).
- `MockTransport`: canned answers by path suffix, fixture files, records every request. No network.
- `ErrorKind`: the cases of Swift's `JellyfinError` without user text, with `topic()` (network, auth, server, decode), NSURLError codes in `url_error`, and the address fallback rule.

Without the `reqwest` feature only the trait, the types and the mock are built, so a platform HTTP stack can be swapped in.

Tests: `cargo test -p swiftly-net`. The reqwest tests talk to throw-away listeners on 127.0.0.1 only.
