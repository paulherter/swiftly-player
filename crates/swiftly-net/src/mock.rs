use std::collections::VecDeque;
use std::path::Path;
use std::sync::Mutex;

use crate::{ErrorKind, HttpRequest, HttpResponse, HttpTransport, Method};

/// One request the mock saw.
pub type Recorded = HttpRequest;

struct Route {
    method: Option<Method>,
    path_suffix: String,
    answers: VecDeque<Result<HttpResponse, ErrorKind>>,
}

#[derive(Default)]
struct Inner {
    routes: Vec<Route>,
    seen: Vec<Recorded>,
    fallback: Option<HttpResponse>,
}

/// A transport that never touches a network. It replays canned answers and records every
/// request, so a test can assert the exact address, query string, headers and body.
///
/// Routing works like the Swift tests' `Replay` protocol (EmbyTests.swift:16-27): the first
/// route whose path ends with the given suffix (and, if given, whose method matches) answers.
/// A route with several answers hands them out in turn and repeats the last one.
/// Without a route the answer is `{}` with status 200, as in the Swift tests.
#[derive(Default)]
pub struct MockTransport {
    inner: Mutex<Inner>,
}

impl MockTransport {
    /// An empty mock; every request is answered with `{}`.
    pub fn new() -> Self {
        Self::default()
    }

    fn with<R>(&self, f: impl FnOnce(&mut Inner) -> R) -> R {
        let mut guard = self
            .inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        f(&mut guard)
    }

    /// Answers any method for paths ending in `path_suffix` with `status` and `body`.
    #[must_use]
    pub fn route(self, path_suffix: &str, status: u16, body: &str) -> Self {
        self.push(None, path_suffix, Ok(HttpResponse::new(status, body)));
        self
    }

    /// Like [`route`](Self::route) for one method only.
    #[must_use]
    pub fn route_method(self, method: Method, path_suffix: &str, status: u16, body: &str) -> Self {
        self.push(
            Some(method),
            path_suffix,
            Ok(HttpResponse::new(status, body)),
        );
        self
    }

    /// Answers with a prepared response (headers, content type).
    #[must_use]
    pub fn route_response(self, path_suffix: &str, response: HttpResponse) -> Self {
        self.push(None, path_suffix, Ok(response));
        self
    }

    /// Fails with a transport error.
    #[must_use]
    pub fn route_error(self, path_suffix: &str, error: ErrorKind) -> Self {
        self.push(None, path_suffix, Err(error));
        self
    }

    /// Answers with a recorded fixture file (status 200).
    ///
    /// A fixture that cannot be read makes the call fail with the path in the error.
    #[must_use]
    pub fn route_fixture(self, path_suffix: &str, file: impl AsRef<Path>) -> Self {
        let path = file.as_ref();
        let answer = match std::fs::read(path) {
            Ok(bytes) => Ok(HttpResponse::new(200, bytes)),
            Err(e) => Err(ErrorKind::Transport(crate::TransportReason::Other(
                format!("fixture {}: {e}", path.display()),
            ))),
        };
        self.push(None, path_suffix, answer);
        self
    }

    /// The answer for requests no route matches (default: 200 with `{}`).
    #[must_use]
    pub fn fallback(self, response: HttpResponse) -> Self {
        self.with(|i| i.fallback = Some(response));
        self
    }

    fn push(&self, method: Option<Method>, suffix: &str, answer: Result<HttpResponse, ErrorKind>) {
        self.with(|i| {
            if let Some(r) = i
                .routes
                .iter_mut()
                .find(|r| r.method == method && r.path_suffix == suffix)
            {
                r.answers.push_back(answer);
            } else {
                i.routes.push(Route {
                    method,
                    path_suffix: suffix.to_string(),
                    answers: VecDeque::from([answer]),
                });
            }
        });
    }

    /// Every request seen so far, oldest first.
    pub fn requests(&self) -> Vec<Recorded> {
        self.with(|i| i.seen.clone())
    }

    /// The newest request, if any.
    pub fn last_request(&self) -> Option<Recorded> {
        self.with(|i| i.seen.last().cloned())
    }

    /// Forgets the recorded requests (the routes stay).
    pub fn clear_requests(&self) {
        self.with(|i| i.seen.clear());
    }
}

impl HttpTransport for MockTransport {
    async fn send(&self, request: HttpRequest) -> Result<HttpResponse, ErrorKind> {
        self.with(|i| {
            let path = request.url.path().to_string();
            i.seen.push(request.clone());
            let Some(route) = i.routes.iter_mut().find(|r| {
                path.ends_with(&r.path_suffix) && r.method.is_none_or(|m| m == request.method)
            }) else {
                return Ok(i
                    .fallback
                    .clone()
                    .unwrap_or_else(|| HttpResponse::new(200, "{}")));
            };
            let answer = if route.answers.len() > 1 {
                route.answers.pop_front()
            } else {
                route.answers.front().cloned()
            };
            answer.unwrap_or_else(|| Ok(HttpResponse::new(200, "{}")))
        })
        .map(|mut r| {
            if r.url.is_none() {
                r.url = Some(request.url.clone());
            }
            r
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use url::Url;

    fn get(path: &str) -> HttpRequest {
        let url = Url::parse(&format!("https://x.test{path}")).expect("url");
        HttpRequest::new(Method::Get, url)
    }

    #[test]
    fn replays_in_turn_and_records() {
        let mock = MockTransport::new()
            .route("/a", 200, "one")
            .route("/a", 500, "two");
        let first = futures_executor::block_on(mock.send(get("/a"))).expect("ok");
        let second = futures_executor::block_on(mock.send(get("/a"))).expect("ok");
        let third = futures_executor::block_on(mock.send(get("/a"))).expect("ok");
        assert_eq!(first.body, b"one");
        assert_eq!(second.status, 500);
        assert_eq!(third.status, 500, "the last answer repeats");
        assert_eq!(mock.requests().len(), 3);
    }

    #[test]
    fn unrouted_is_empty_object() {
        let mock = MockTransport::new();
        let r = futures_executor::block_on(mock.send(get("/z"))).expect("ok");
        assert_eq!((r.status, r.body.as_slice()), (200, b"{}".as_slice()));
    }

    #[test]
    fn headers_replace_case_insensitively() {
        let mut r = get("/");
        r.set_header("Accept", "a");
        r.set_header("accept", "b");
        assert_eq!(r.headers.len(), 1);
        assert_eq!(r.header("ACCEPT"), Some("b"));
    }
}
