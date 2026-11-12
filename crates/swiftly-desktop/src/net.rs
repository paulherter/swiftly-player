//! The transport of the app: the scripted server of the demo or the real network. The screens are written once over
//! this type; `--demo app` keeps the scripted one for the goldens.

use swiftly_net::{
    ErrorKind, HttpRequest, HttpResponse, HttpTransport, MockTransport, ReqwestTransport,
};

/// A blocking HTTP stack the platform provides (Android: `HttpURLConnection` over JNI, so system trust, user CAs and
/// proxies apply). One call is one complete exchange; it runs on a blocking thread of the network runtime.
pub trait HostHttp: Send + Sync {
    /// Sends the request and returns the complete answer.
    ///
    /// # Errors
    /// The kind of failure when the request did not get through.
    fn send(&self, request: HttpRequest) -> Result<HttpResponse, ErrorKind>;
}

static HOST_HTTP: std::sync::OnceLock<std::sync::Arc<dyn HostHttp>> = std::sync::OnceLock::new();

/// Registers the platform stack; `Core::open` then uses it instead of reqwest. Called once by the Android shell.
pub fn set_host_http(h: std::sync::Arc<dyn HostHttp>) {
    let _ = HOST_HTTP.set(h);
}

/// The registered platform stack, if any.
pub fn host_http() -> Option<std::sync::Arc<dyn HostHttp>> {
    HOST_HTTP.get().cloned()
}

/// Scripted (demo, goldens) or real (reqwest) network.
pub enum AppTransport {
    /// The scripted server.
    Mock(MockTransport),
    /// reqwest over rustls with the platform certificate verifier. reqwest needs a tokio reactor, so every request
    /// is spawned on this runtime and awaited from whatever executor asked (view model pool, image loader pool).
    Real(ReqwestTransport, tokio::runtime::Handle),
    /// The platform's own stack (`HostHttp`), called on a blocking thread of the runtime.
    Host(std::sync::Arc<dyn HostHttp>, tokio::runtime::Handle),
}

impl HttpTransport for AppTransport {
    async fn send(&self, request: HttpRequest) -> Result<HttpResponse, ErrorKind> {
        match self {
            AppTransport::Mock(m) => m.send(request).await,
            AppTransport::Real(r, handle) => {
                let r = r.clone();
                handle
                    .spawn(async move { r.send(request).await })
                    .await
                    .unwrap_or(Err(ErrorKind::Cancelled))
            }
            AppTransport::Host(h, handle) => {
                let h = std::sync::Arc::clone(h);
                handle
                    .spawn_blocking(move || h.send(request))
                    .await
                    .unwrap_or(Err(ErrorKind::Cancelled))
            }
        }
    }
}
