#![allow(clippy::expect_used, clippy::unwrap_used)]
//! Shared test helpers: a transport that answers from a closure and records what was asked,
//! a cooperative timer, and the fixtures (copied from the Swift tests, `PlexFixtures.swift`).
#![allow(dead_code)]

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::task::Poll;
use std::time::{Duration, Instant};

use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport};
use swiftly_plex::{PlexIdentity, PlexListing, PlexMetadata, Sleep};

pub const MOVIE: &str = include_str!("../fixtures/movie.json");
pub const EPISODE: &str = include_str!("../fixtures/episode.json");
pub const SHOW: &str = include_str!("../fixtures/show.json");
pub const PAGE: &str = include_str!("../fixtures/page.json");
pub const SECTIONS: &str = include_str!("../fixtures/sections.json");
pub const IDENTITY: &str = include_str!("../fixtures/identity.json");
pub const RESOURCES: &str = include_str!("../fixtures/resources.json");
pub const PIN_FRESH: &str = include_str!("../fixtures/pin_fresh.json");
pub const PIN_DONE: &str = include_str!("../fixtures/pin_done.json");
pub const HOME_USERS: &str = include_str!("../fixtures/home_users.json");

type Handler = Box<dyn Fn(&HttpRequest) -> (u16, String) + Send + Sync>;

/// Answers every request from the closure (status, body) and keeps the requests.
pub struct Stub {
    handler: Handler,
    seen: Mutex<Vec<HttpRequest>>,
}

impl Stub {
    pub fn new(
        handler: impl Fn(&HttpRequest) -> (u16, String) + Send + Sync + 'static,
    ) -> Arc<Self> {
        Arc::new(Self {
            handler: Box::new(handler),
            seen: Mutex::new(Vec::new()),
        })
    }

    pub fn always(status: u16, body: &str) -> Arc<Self> {
        let body = body.to_string();
        Self::new(move |_| (status, body.clone()))
    }

    pub fn requests(&self) -> Vec<HttpRequest> {
        self.seen.lock().map(|g| g.clone()).unwrap_or_default()
    }

    pub fn on_host(&self, host: &str) -> Vec<HttpRequest> {
        self.requests()
            .into_iter()
            .filter(|r| r.url.host_str() == Some(host))
            .collect()
    }
}

impl HttpTransport for Stub {
    async fn send(&self, request: HttpRequest) -> Result<HttpResponse, ErrorKind> {
        if let Ok(mut g) = self.seen.lock() {
            g.push(request.clone());
        }
        let (status, body) = (self.handler)(&request);
        Ok(HttpResponse::new(status, body))
    }
}

pub fn identity() -> PlexIdentity {
    PlexIdentity::new("cid", "1.0", "macOS", "Mac", "Test Mac")
}

pub fn counter() -> Arc<AtomicUsize> {
    Arc::new(AtomicUsize::new(0))
}

/// `next()` of the Swift `PlexCounter`: increments and returns the new value.
pub fn next(c: &AtomicUsize) -> usize {
    c.fetch_add(1, Ordering::SeqCst) + 1
}

pub fn count(c: &AtomicUsize) -> usize {
    c.load(Ordering::SeqCst)
}

/// A timer that does not block the thread: it wakes itself until the time is up.
pub fn nap(d: Duration) -> Pin<Box<dyn Future<Output = ()> + Send>> {
    Box::pin(async move {
        let end = Instant::now() + d;
        std::future::poll_fn(|cx| {
            if Instant::now() >= end {
                Poll::Ready(())
            } else {
                cx.waker().wake_by_ref();
                Poll::Pending
            }
        })
        .await
    })
}

pub fn sleeper() -> Sleep {
    Arc::new(nap)
}

/// Gives other tasks the turn once.
pub async fn yield_now() {
    let mut yielded = false;
    std::future::poll_fn(|cx| {
        if yielded {
            Poll::Ready(())
        } else {
            yielded = true;
            cx.waker().wake_by_ref();
            Poll::Pending
        }
    })
    .await
}

pub fn decode_metadata(json: &str) -> PlexMetadata {
    PlexListing::from_body(json.as_bytes())
        .expect("decodes")
        .metadata
        .into_iter()
        .next()
        .expect("one entry")
}

pub fn query_of(url: &url::Url) -> String {
    url.query().unwrap_or("").to_string()
}

pub fn header(r: &HttpRequest, name: &str) -> Option<String> {
    r.header(name).map(String::from)
}
