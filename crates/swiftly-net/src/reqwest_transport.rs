//! The default transport: reqwest with rustls.
//!
//! **TLS.** reqwest 0.13's `rustls` feature verifies server certificates through
//! `rustls-platform-verifier`, i.e. the operating system's trust store (Keychain on Apple,
//! the system store on Android, Windows and Linux). A server with a private CA works once
//! the CA is installed in the OS, like in the Swift app, and no certificate is ever accepted
//! "blindly". There is no certificate pinning and no override.
//!
//! **Proxy.** The system proxy settings (`system-proxy` feature) are honoured, as URLSession
//! does.
//!
//! **Timeouts** (NetworkSession.swift:20-34): 15 s without data (`timeoutIntervalForRequest`),
//! 20 s for the whole call (`timeoutIntervalForResource`). A request can carry its own timeout
//! (the 8 s address check, AddressCheck.swift).
//!
//! **Cookies** are kept in a jar per transport (Seerr needs a session cookie).
//!
//! **Redirects.** `NetworkSession.swift` sets no redirect rule, so URLSession's default
//! applies: follow. Here they are followed by hand (up to [`MAX_REDIRECTS`]) so that headers
//! can be handled: 301, 302 and 303 turn a POST into a GET without body (as URLSession does);
//! 307 and 308 keep method and body. When the target is another origin (scheme, host or
//! port), every header except `Accept`, `Content-Type` and `User-Agent` is dropped, so the
//! token and the user's own gateway headers (`Authorization`, `CF-Access-*`) never leave the
//! server they were meant for.

use std::error::Error as StdError;
use std::io;
use std::time::Duration;

use url::Url;

use crate::{
    CertificateReason, ErrorKind, HttpRequest, HttpResponse, HttpTransport, Method,
    TransportReason, certificate_reason, url_error,
};

/// Most redirects followed for one request.
pub const MAX_REDIRECTS: usize = 10;

/// Timeouts and switches of [`ReqwestTransport`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TransportConfig {
    /// Longest silence while connecting or reading (`timeoutIntervalForRequest`, 15 s).
    pub request_timeout: Duration,
    /// Longest time for the whole call (`timeoutIntervalForResource`, 20 s).
    pub resource_timeout: Duration,
    /// Keep cookies between requests.
    pub cookies: bool,
    /// Largest answer body that is read; a bigger one fails with `CANNOT_PARSE_RESPONSE` instead of filling memory.
    pub max_response_bytes: usize,
    /// How long an idle connection stays in the pool. Plex sends `Keep-Alive: timeout=20` and
    /// stops answering shortly before it closes, so a pooled socket older than that fails the
    /// next call; 15 s keeps the pool below the server's limit (research 13, Plezy #2670).
    pub pool_idle_timeout: Duration,
}

/// Default idle time of a pooled connection ([`TransportConfig::pool_idle_timeout`]).
pub const POOL_IDLE_TIMEOUT: Duration = Duration::from_secs(15);

/// Default cap for one answer body: library pages and images are far below this; a malicious server is not.
pub const MAX_RESPONSE_BYTES: usize = 64 * 1024 * 1024;

impl Default for TransportConfig {
    /// `URLSession.localNetworkCapable`: 15 s / 20 s (NetworkSession.swift:30-32).
    fn default() -> Self {
        Self {
            request_timeout: Duration::from_secs(15),
            resource_timeout: Duration::from_secs(20),
            cookies: true,
            max_response_bytes: MAX_RESPONSE_BYTES,
            pool_idle_timeout: POOL_IDLE_TIMEOUT,
        }
    }
}

/// Extra TLS and proxy settings of [`ReqwestTransport::with_tls`] (the "TLS cases" of the Swift app).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TlsOptions {
    /// Certificate authorities the user added, PEM or DER, trusted in addition to the platform store.
    pub extra_roots: Vec<Vec<u8>>,
    /// Trust any certificate on EVERY host (legacy switch of the desktop shell). Dangerous; prefer
    /// [`TlsOptions::accept_invalid_hosts`], which limits the exception to the hosts the user named.
    pub accept_invalid_certs: bool,
    /// Hosts (lower case, no port) whose certificate is not checked because the user accepted them. Every other
    /// host is still verified; the exception never applies to a redirect target on another host.
    pub accept_invalid_hosts: Vec<String>,
    /// A proxy for every request (`http://host:port`); `None` keeps the system proxy settings.
    pub proxy: Option<String>,
}

/// reqwest + rustls (platform verifier) behind [`HttpTransport`].
#[derive(Debug, Clone)]
pub struct ReqwestTransport {
    client: reqwest::Client,
    /// A client that skips certificate checks, used only for the hosts in `lenient_hosts`.
    lenient: Option<reqwest::Client>,
    lenient_hosts: Vec<String>,
    max_response_bytes: usize,
}

impl ReqwestTransport {
    /// A transport with the Swiftly defaults.
    ///
    /// # Errors
    /// [`ErrorKind::Transport`] if the TLS stack or the platform verifier cannot start.
    pub fn new() -> Result<Self, ErrorKind> {
        Self::with_config(TransportConfig::default())
    }

    /// A transport with its own timeouts.
    ///
    /// # Errors
    /// [`ErrorKind::Transport`] if the TLS stack or the platform verifier cannot start.
    pub fn with_config(config: TransportConfig) -> Result<Self, ErrorKind> {
        Self::with_tls(config, &TlsOptions::default())
    }

    /// A transport with its own timeouts, user certificate authorities, an optional proxy and the self-signed switch.
    ///
    /// # Errors
    /// [`ErrorKind::Transport`] if a certificate or the proxy address cannot be read, or the TLS stack cannot start.
    pub fn with_tls(config: TransportConfig, tls: &TlsOptions) -> Result<Self, ErrorKind> {
        let other = |e: reqwest::Error| {
            ErrorKind::Transport(TransportReason::Other(e.without_url().to_string()))
        };
        let base = |insecure: bool| -> Result<reqwest::Client, ErrorKind> {
            let mut builder = reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .cookie_store(config.cookies)
                .pool_idle_timeout(config.pool_idle_timeout)
                .tcp_nodelay(true)
                .connect_timeout(config.request_timeout)
                .read_timeout(config.request_timeout)
                .timeout(config.resource_timeout);
            for bytes in &tls.extra_roots {
                let cert = reqwest::Certificate::from_pem(bytes)
                    .or_else(|_| reqwest::Certificate::from_der(bytes))
                    .map_err(other)?;
                builder = builder.add_root_certificate(cert);
            }
            if insecure {
                builder = builder.danger_accept_invalid_certs(true);
            }
            if let Some(url) = &tls.proxy {
                builder = builder.proxy(reqwest::Proxy::all(url.as_str()).map_err(other)?);
            }
            builder.build().map_err(other)
        };
        let lenient_hosts: Vec<String> = tls
            .accept_invalid_hosts
            .iter()
            .map(|h| h.to_ascii_lowercase())
            .collect();
        let lenient = if lenient_hosts.is_empty() {
            None
        } else {
            Some(base(true)?)
        };
        Ok(Self {
            client: base(tls.accept_invalid_certs)?,
            lenient,
            lenient_hosts,
            max_response_bytes: config.max_response_bytes,
        })
    }

    /// The client for this address: the lenient one only for a host the user accepted.
    fn client_for(&self, url: &Url) -> &reqwest::Client {
        match (&self.lenient, url.host_str()) {
            (Some(c), Some(h)) if self.lenient_hosts.iter().any(|a| a.eq_ignore_ascii_case(h)) => c,
            _ => &self.client,
        }
    }
}

fn same_origin(a: &Url, b: &Url) -> bool {
    a.scheme() == b.scheme()
        && a.host_str() == b.host_str()
        && a.port_or_known_default() == b.port_or_known_default()
}

fn to_reqwest(method: Method) -> reqwest::Method {
    match method {
        Method::Get => reqwest::Method::GET,
        Method::Post => reqwest::Method::POST,
        Method::Put => reqwest::Method::PUT,
        Method::Delete => reqwest::Method::DELETE,
    }
}

impl HttpTransport for ReqwestTransport {
    async fn send(&self, request: HttpRequest) -> Result<HttpResponse, ErrorKind> {
        let mut current = request;
        for _ in 0..=MAX_REDIRECTS {
            let mut builder = self
                .client_for(&current.url)
                .request(to_reqwest(current.method), current.url.clone());
            for (name, value) in &current.headers {
                builder = builder.header(name, value);
            }
            if let Some(body) = &current.body {
                builder = builder.body(body.clone());
            }
            if let Some(t) = current.timeout {
                builder = builder.timeout(t);
            }
            let response = builder.send().await.map_err(map_error)?;
            let status = response.status().as_u16();
            let headers: Vec<(String, String)> = response
                .headers()
                .iter()
                .filter_map(|(n, v)| v.to_str().ok().map(|v| (n.to_string(), v.to_string())))
                .collect();
            let location = response
                .headers()
                .get(reqwest::header::LOCATION)
                .and_then(|v| v.to_str().ok())
                .and_then(|l| current.url.join(l).ok());
            // A sign-in session never turns its POST into a GET: the 3xx answer is the result.
            let changes_method = matches!(status, 301..=303) && current.method != Method::Get;
            if current.keep_method && changes_method {
                // fall through to the answer below
            } else if let (true, Some(next)) =
                (matches!(status, 301 | 302 | 303 | 307 | 308), location)
            {
                // Only http(s) targets: a redirect to file:, ftp: and the like is refused outright.
                if !matches!(next.scheme(), "http" | "https") {
                    return Err(ErrorKind::InvalidServerUrl);
                }
                current = redirect(current, next, status);
                continue;
            }
            let final_url = response.url().clone();
            let body = read_capped(response, self.max_response_bytes).await?;
            return Ok(HttpResponse {
                status,
                headers,
                body,
                url: Some(final_url),
            });
        }
        Err(ErrorKind::Network {
            code: url_error::TOO_MANY_REDIRECTS,
        })
    }
}

/// Reads the body chunk by chunk and stops with an error once it grows past `cap` (a declared
/// `Content-Length` over the cap fails before any byte is read).
async fn read_capped(mut response: reqwest::Response, cap: usize) -> Result<Vec<u8>, ErrorKind> {
    let too_big = || ErrorKind::Network {
        code: url_error::CANNOT_PARSE_RESPONSE,
    };
    if response.content_length().is_some_and(|n| n > cap as u64) {
        return Err(too_big());
    }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(map_error)? {
        if body.len().saturating_add(chunk.len()) > cap {
            return Err(too_big());
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

/// The request for the redirect target (rules in the module documentation).
fn redirect(mut from: HttpRequest, next: Url, status: u16) -> HttpRequest {
    let drop_body = matches!(status, 301..=303) && from.method != Method::Get;
    if drop_body {
        from.method = Method::Get;
        from.body = None;
    }
    if !same_origin(&from.url, &next) {
        from.headers.retain(|(n, _)| {
            let n = n.to_ascii_lowercase();
            n == "accept" || n == "user-agent" || (n == "content-type" && from.body.is_some())
        });
    } else if drop_body {
        from.headers
            .retain(|(n, _)| !n.eq_ignore_ascii_case("content-type"));
    }
    from.url = next;
    from
}

fn chain_text(e: &reqwest::Error) -> (String, Option<io::ErrorKind>) {
    let mut text = e.to_string();
    let mut kind = None;
    let mut source: Option<&(dyn StdError + 'static)> = e.source();
    while let Some(s) = source {
        text.push_str(": ");
        text.push_str(&s.to_string());
        if let Some(io) = s.downcast_ref::<io::Error>() {
            kind.get_or_insert(io.kind());
        }
        source = s.source();
    }
    (text.to_lowercase(), kind)
}

/// Sorts a reqwest failure into the codes the Swift code knows (`JellyfinError(petition:)`,
/// JellyfinClient.swift:56-69). The certificate question is asked first, like there.
fn map_error(e: reqwest::Error) -> ErrorKind {
    let (text, io_kind) = chain_text(&e);
    if e.is_builder() {
        return ErrorKind::InvalidServerUrl;
    }
    if e.is_timeout() {
        return ErrorKind::Network {
            code: url_error::TIMED_OUT,
        };
    }
    if let Some(reason) = tls_reason(&text) {
        return ErrorKind::Certificate(reason);
    }
    if e.is_redirect() {
        return ErrorKind::Network {
            code: url_error::TOO_MANY_REDIRECTS,
        };
    }
    let dns = text.contains("dns error")
        || text.contains("failed to lookup")
        || text.contains("nodename nor servname")
        || text.contains("name or service not known");
    let code = if e.is_connect() {
        if dns {
            url_error::CANNOT_FIND_HOST
        } else if text.contains("network is unreachable") || text.contains("network unreachable") {
            url_error::NOT_CONNECTED_TO_INTERNET
        } else {
            url_error::CANNOT_CONNECT_TO_HOST
        }
    } else {
        match io_kind {
            Some(
                io::ErrorKind::ConnectionReset
                | io::ErrorKind::ConnectionAborted
                | io::ErrorKind::BrokenPipe
                | io::ErrorKind::UnexpectedEof,
            ) => url_error::NETWORK_CONNECTION_LOST,
            _ if e.is_decode() || e.is_body() => url_error::CANNOT_PARSE_RESPONSE,
            _ => -1,
        }
    };
    ErrorKind::Network { code }
}

/// A TLS verification failure, if the text is one. rustls words these as
/// `invalid peer certificate: UnknownIssuer` and similar.
fn tls_reason(text: &str) -> Option<CertificateReason> {
    if text.contains("invalid peer certificate")
        || text.contains("certificate verif")
        || text.contains("invalid certificate")
        || text.contains("tls handshake")
        || text.contains("received fatal alert")
        || text.contains("peer is incompatible")
    {
        return certificate_reason(-1, text).or(Some(CertificateReason::Otherwise));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(method: Method, url: &str, body: bool) -> HttpRequest {
        let mut r = HttpRequest::new(method, Url::parse(url).expect("url"));
        r.set_header("Authorization", "MediaBrowser x");
        r.set_header("Accept", "application/json");
        r.set_header("CF-Access-Client-Id", "id");
        if body {
            r.set_header("Content-Type", "application/json");
            r.body = Some(b"{}".to_vec());
        }
        r
    }

    #[test]
    fn same_origin_keeps_headers() {
        let next = Url::parse("https://a.test/other").expect("url");
        let r = redirect(req(Method::Get, "https://a.test/x", false), next, 302);
        assert!(r.header("Authorization").is_some());
        assert!(r.header("CF-Access-Client-Id").is_some());
    }

    #[test]
    fn other_origin_drops_everything_but_accept() {
        let next = Url::parse("https://b.test/x").expect("url");
        let r = redirect(req(Method::Get, "https://a.test/x", false), next, 302);
        assert_eq!(
            r.headers,
            vec![("Accept".to_string(), "application/json".to_string())]
        );
        // http -> https on the same host and a changed port count as another origin, too.
        let r = redirect(
            req(Method::Get, "https://a.test/x", false),
            Url::parse("http://a.test/x").expect("url"),
            301,
        );
        assert!(r.header("Authorization").is_none());
    }

    #[test]
    fn post_becomes_get_on_302_but_not_on_307() {
        let next = Url::parse("https://a.test/y").expect("url");
        let r = redirect(
            req(Method::Post, "https://a.test/x", true),
            next.clone(),
            302,
        );
        assert_eq!((r.method, r.body.is_none()), (Method::Get, true));
        assert!(r.header("Content-Type").is_none());
        let r = redirect(req(Method::Post, "https://a.test/x", true), next, 307);
        assert_eq!(r.method, Method::Post);
        assert!(r.body.is_some());
    }

    #[test]
    fn rustls_words_map_to_reasons() {
        assert_eq!(
            tls_reason("invalid peer certificate: unknownissuer"),
            Some(CertificateReason::NotTrusted)
        );
        assert_eq!(
            tls_reason("invalid peer certificate: expired"),
            Some(CertificateReason::Expired)
        );
        assert_eq!(
            tls_reason("invalid peer certificate: notvalidforname"),
            Some(CertificateReason::OtherAddress)
        );
        assert_eq!(tls_reason("connection refused"), None);
    }
}
