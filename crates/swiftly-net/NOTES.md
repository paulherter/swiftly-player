# Notes

- Redirect rules: `NetworkSession.swift` sets none, so URLSession's default (follow) applies. The Rust transport follows
  up to 10 redirects by hand; 301/302/303 turn POST into GET without body, 307/308 keep it; on another origin only
  `Accept`, `Content-Type` (if there is a body) and `User-Agent` survive, so the token and the user's gateway headers
  never leave the server.
- TLS: reqwest 0.13 `rustls` feature = rustls + `rustls-platform-verifier` (OS trust store). No pinning, no
  "accept invalid certificates" switch. rustls errors are sorted into `CertificateReason` by their words (`UnknownIssuer`,
  `Expired`, `NotValidForName`, `NotValidYet`).
- Proxy: system proxy settings via reqwest's `system-proxy` feature.
- `waitsForConnectivity` (Apple local-network prompt) has no equivalent in reqwest; on Apple the Swift shell may keep
  using URLSession through its own `HttpTransport` if the prompt race matters.
- reqwest pulls aws-lc-rs as the crypto provider (C build). If a target cannot build it, swap the transport behind the
  `reqwest` feature.
