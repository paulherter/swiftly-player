use std::future::Future;

use crate::{ErrorKind, HttpRequest, HttpResponse};

/// One HTTP exchange. Implemented by the reqwest transport, by the mock for
/// tests and, later, by a platform stack where reqwest is not wanted.
///
/// A status outside 2xx is **not** an error here: the answer is returned and
/// the caller decides (the Swift client reads the status itself). Only a
/// request that did not get through is an `Err`: [`ErrorKind::Network`],
/// [`ErrorKind::Certificate`] or [`ErrorKind::Transport`].
pub trait HttpTransport: Send + Sync {
    /// Sends the request and returns the complete answer.
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl Future<Output = Result<HttpResponse, ErrorKind>> + Send;
}
