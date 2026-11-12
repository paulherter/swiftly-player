//! HTTP implemented by the host (URLSession on Apple), so the Apple binary carries no TLS stack.
//! The host gets plain records and answers with a record or an [`HttpFailure`]; this file maps
//! them to `swiftly-net` types.

use std::sync::Arc;

use std::future::Future;
use std::pin::Pin;
use std::time::Duration;

use futures_util::future::Either;
use swiftly_net::{
    CertificateReason, ErrorKind, HttpRequest, HttpResponse, HttpTransport, LayerConfig,
    LayeredTransport, Method, RequestOptions, Timer, Url, certificate_reason,
};

/// HTTP method of a [`NetRequest`].
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum NetMethod {
    /// GET
    Get,
    /// POST
    Post,
    /// PUT
    Put,
    /// DELETE
    Delete,
}

/// A header field (order is kept by the list).
#[derive(Debug, Clone, uniffi::Record)]
pub struct NetHeader {
    /// Field name.
    pub name: String,
    /// Field value.
    pub value: String,
}

/// One request for the host to send.
#[derive(Debug, Clone, uniffi::Record)]
pub struct NetRequest {
    /// Method.
    pub method: NetMethod,
    /// Complete address.
    pub url: String,
    /// Header fields in order.
    pub headers: Vec<NetHeader>,
    /// Body, if any.
    pub body: Option<Vec<u8>>,
    /// Timeout for this one request in milliseconds (replaces the session's), if set.
    pub timeout_ms: Option<u64>,
    /// Refuse a redirect that would change the method (POST turned into GET) and return the 3xx
    /// answer instead (`KeepPostRedirects`; the Seerr sign-in sets it).
    #[uniffi(default = false)]
    pub keep_method: bool,
}

/// The complete answer. Redirects are followed by the host; `url` is the final address.
#[derive(Debug, Clone, uniffi::Record)]
pub struct NetResponse {
    /// Status code (any, also non-2xx).
    pub status: u16,
    /// Header fields.
    pub headers: Vec<NetHeader>,
    /// Body.
    pub body: Vec<u8>,
    /// Final address after redirects.
    pub url: Option<String>,
}

/// Why a request did not get an answer.
#[derive(Debug, uniffi::Error)]
pub enum HttpFailure {
    /// `NSURLErrorDomain` code (timeout -1001, no host -1003, ...).
    Network {
        /// The URL error code.
        code: i32,
    },
    /// TLS failure; the code and the error text sort the reason.
    Certificate {
        /// The URL error code (-1200 ...).
        code: i32,
        /// The error text, for the reason rules.
        text: String,
    },
    /// The request was cancelled.
    Cancelled,
    /// Anything else.
    Other {
        /// Developer-readable description.
        message: String,
    },
}

impl std::fmt::Display for HttpFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for HttpFailure {}

/// The host's HTTP stack. Implemented in Swift with URLSession (system trust, proxies, cookies).
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait HttpClient: Send + Sync {
    /// Sends the request, follows redirects, returns the complete answer.
    async fn send(&self, request: NetRequest) -> Result<NetResponse, HttpFailure>;
}

/// [`HttpTransport`] over the host's [`HttpClient`].
#[derive(Clone)]
pub struct ForeignTransport(pub(crate) Arc<dyn HttpClient>);

impl HttpTransport for ForeignTransport {
    async fn send(&self, request: HttpRequest) -> Result<HttpResponse, ErrorKind> {
        let net = NetRequest {
            method: match request.method {
                Method::Get => NetMethod::Get,
                Method::Post => NetMethod::Post,
                Method::Put => NetMethod::Put,
                Method::Delete => NetMethod::Delete,
            },
            url: request.url.to_string(),
            headers: request
                .headers
                .into_iter()
                .map(|(name, value)| NetHeader { name, value })
                .collect(),
            body: request.body,
            timeout_ms: request
                .timeout
                .map(|t| u64::try_from(t.as_millis()).unwrap_or(u64::MAX)),
            keep_method: request.keep_method,
        };
        let answer = self.0.send(net).await.map_err(map_failure)?;
        Ok(HttpResponse {
            status: answer.status,
            headers: answer
                .headers
                .into_iter()
                .map(|h| (h.name, h.value))
                .collect(),
            body: answer.body,
            url: answer.url.and_then(|u| Url::parse(&u).ok()),
        })
    }
}

fn map_failure(failure: HttpFailure) -> ErrorKind {
    match failure {
        HttpFailure::Network { code } => ErrorKind::Network { code },
        HttpFailure::Certificate { code, text } => ErrorKind::Certificate(
            certificate_reason(code, &text).unwrap_or(CertificateReason::Otherwise),
        ),
        HttpFailure::Cancelled => ErrorKind::Cancelled,
        HttpFailure::Other { .. } => ErrorKind::Network { code: -1 },
    }
}

/// Sleeps on the core's tokio runtime (the layer's retry delays and deadline).
struct CoreTimer;

impl Timer for CoreTimer {
    fn sleep(&self, duration: Duration) -> Pin<Box<dyn Future<Output = ()> + Send>> {
        Box::pin(tokio::time::sleep(duration))
    }
}

/// What every view model gets: the host's HTTP behind the shared request layer (identical
/// in-flight GETs share one call, visible work goes first, at most 12 calls per host, transient
/// failures of GETs are retried, a screen that goes away cancels its calls).
///
/// One per core, so Home, Library and Detail share dedup and limits; the dedup key includes
/// the headers, so two accounts never share an answer.
#[derive(Clone)]
pub struct CoreTransport(LayeredTransport<ForeignTransport>);

impl CoreTransport {
    pub(crate) fn new(http: Arc<dyn HttpClient>) -> Self {
        let config = LayerConfig {
            max_per_host: 12,
            // Not longer than the host's own limit for one request (20 s), so an unreachable
            // server is reported as early as before.
            deadline: Duration::from_secs(21),
            ..LayerConfig::default()
        };
        Self(LayeredTransport::with_config(
            ForeignTransport(http),
            Arc::new(CoreTimer),
            config,
        ))
    }

    /// The bare host transport, for the player (live position reports must not queue behind a
    /// host limit and are POSTs the layer would not touch anyway).
    pub(crate) fn foreign(&self) -> &ForeignTransport {
        self.0.inner()
    }
}

impl HttpTransport for CoreTransport {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl Future<Output = Result<HttpResponse, ErrorKind>> + Send {
        if request.timeout.is_some() {
            // A request with its own short timeout is a probe (address check, Plex connection
            // race): it is answered as given, not retried.
            let options = RequestOptions {
                retry: false,
                ..RequestOptions::with_priority(swiftly_net::Priority::Visible)
            };
            Either::Left(self.0.send_with(request, options))
        } else {
            Either::Right(self.0.send(request))
        }
    }
}
