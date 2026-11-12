//! The network seam of the Swiftly core.
//!
//! * [`HttpTransport`]: one async call, request in, response out. Every client
//!   (Jellyfin, Emby, later Plex and Seerr) is generic over it.
//! * [`ReqwestTransport`] (feature `reqwest`, default): reqwest with rustls and the
//!   platform certificate verifier, cookies, the timeouts of
//!   `NetworkSession.swift` and its own redirect rules.
//! * [`MockTransport`]: replays recorded fixtures and records what was asked,
//!   for tests that never touch a network.
//! * [`ErrorKind`]: the error cases of `JellyfinError` without any user text.
#![deny(missing_docs)]

mod error;
mod http;
mod layer;
mod mock;
pub mod redact;
#[cfg(feature = "reqwest")]
mod reqwest_transport;
mod transport;

pub use error::{
    CertificateReason, ErrorKind, ErrorTopic, TransportReason, certificate_reason, url_error,
};
pub use http::{HttpRequest, HttpResponse, Method};
#[cfg(feature = "reqwest")]
pub use layer::TokioTimer;
pub use layer::{
    LayerConfig, LayeredTransport, NetCounters, NetEvent, NetEventKind, NetMetrics, Priority,
    RequestOptions, Scoped, Timer, scoped,
};
pub use mock::{MockTransport, Recorded};
#[cfg(feature = "reqwest")]
pub use reqwest_transport::{ReqwestTransport, TlsOptions, TransportConfig};
pub use transport::HttpTransport;
pub use url::Url;
