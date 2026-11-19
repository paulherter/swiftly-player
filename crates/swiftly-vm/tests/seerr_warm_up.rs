//! The warm-up of the Seerr screens over a fake server that answers late: it fills the stash once, never twice at the
//! same time, skips the admin reads of an ordinary account, and a screen that opens afterwards paints without a call.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport, MockTransport};
use swiftly_seerr::{BodyStash, NoCookies, SeerrAccess, SeerrClient};
use swiftly_vm::{AdminTab, ListLoad, SeerrAdminScreen, SeerrHub, SeerrListsScreen};

/// Seerr's permission bit for an administrator: every right.
const ADMIN: i64 = 2;
/// Only the right to ask for things.
const REQUEST: i64 = 32;
const LATE_MS: u64 = 40;

/// Answers like the mock, but `LATE_MS` later (a server that is far away).
struct Slow(Arc<MockTransport>);

impl HttpTransport for Slow {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl Future<Output = Result<HttpResponse, ErrorKind>> + Send {
        let inner = Arc::clone(&self.0);
        async move {
            tokio::time::sleep(Duration::from_millis(LATE_MS)).await;
            inner.send(request).await
        }
    }
}

fn world(perms: i64) -> Arc<MockTransport> {
    Arc::new(
        MockTransport::new()
            .route(
                "auth/me",
                200,
                &format!(r#"{{"id":2,"displayName":"demo","permissions":{perms}}}"#),
            )
            .route("settings/public", 200, "{}")
            .route("request/count", 200, r#"{"pending":1,"total":2}"#)
            .route("issue/count", 200, r#"{"open":0,"closed":0,"total":0}"#)
            .route(
                "request",
                200,
                r#"{"pageInfo":{"pages":1,"pageSize":50,"results":2,"page":1},"results":[
                {"id":50,"status":1,"mediaType":"movie","is4k":false,"requestedBy":{"id":2,"displayName":"demo"},
                 "media":{"id":20,"tmdbId":2002,"mediaType":"movie","status":2}},
                {"id":51,"status":4,"mediaType":"movie","is4k":false,"requestedBy":{"id":2,"displayName":"demo"},
                 "media":{"id":21,"tmdbId":2001,"mediaType":"movie","status":1}}]}"#,
            )
            .route("movie/2002", 200, r#"{"id":2002,"title":"Nordlicht","releaseDate":"2024-03-01"}"#)
            .route("movie/2001", 200, r#"{"id":2001,"title":"Nordstern","releaseDate":"2024-01-01"}"#),
    )
}

#[derive(Default)]
struct Memory(Mutex<std::collections::HashMap<String, Vec<u8>>>);

impl BodyStash for Memory {
    fn get(&self, key: &str) -> Option<Vec<u8>> {
        self.0.lock().unwrap().get(key).cloned()
    }
    fn put(&self, key: &str, body: &[u8]) {
        self.0.lock().unwrap().insert(key.to_owned(), body.to_vec());
    }
}

type Hub = SeerrHub<Slow, NoCookies>;

fn hub(world: &Arc<MockTransport>, stash: &Arc<Memory>, log: &Arc<Mutex<Vec<String>>>) -> Arc<Hub> {
    let sink = Arc::clone(log);
    let client = SeerrClient::new(
        SeerrAccess::new("https://seerr.test", "connect.sid=x", &[]),
        Slow(Arc::clone(world)),
    )
    .with_stash(Arc::clone(stash) as Arc<dyn BodyStash>)
    .with_log(Arc::new(move |line: &str| {
        sink.lock().unwrap().push(line.to_owned())
    }));
    SeerrHub::new(Some(client), "de".into())
}

fn run<F: Future>(f: F) -> F::Output {
    tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()
        .unwrap()
        .block_on(f)
}

fn asked(world: &MockTransport, needle: &str) -> usize {
    world
        .requests()
        .iter()
        .filter(|r| r.url.as_str().contains(needle))
        .count()
}

fn fresh() -> (Arc<Memory>, Arc<Mutex<Vec<String>>>) {
    (
        Arc::new(Memory::default()),
        Arc::new(Mutex::new(Vec::new())),
    )
}

#[test]
fn after_the_warm_up_the_admin_page_and_my_requests_paint_with_no_call() {
    let (stash, log) = fresh();
    // The start: the warm-up reads everything once.
    let first = world(ADMIN);
    assert!(run(hub(&first, &stash, &log).warm_up()));
    assert!(
        asked(&first, "request?take=100") >= 1,
        "the admin queue was read"
    );

    // The first visit of Verwaltung (a new hub, a Seerr that must not be asked): content at once.
    let second = world(ADMIN);
    let live = hub(&second, &stash, &log);
    let page = SeerrAdminScreen::new(Arc::clone(&live));
    assert!(run(page.restore_all()));
    assert_eq!(page.first_tab(), Some(AdminTab::Requests));
    assert_eq!(page.requests().rows.len(), 2);
    let lists = SeerrListsScreen::new(Arc::clone(&live));
    // "Meine Anfragen" of the same visit stands too, on a hub that already painted once.
    assert!(run(lists.restore_requests()) || lists.requests().load == ListLoad::Content);
    assert_eq!(second.requests().len(), 0, "the paint went to Seerr");

    let lines = log.lock().unwrap().join("\n");
    assert!(lines.contains("[Seerr] GET request 200"), "{lines}");
    assert!(lines.contains("[Seerr] warm-up done (admin)"), "{lines}");
    assert!(
        lines.contains("[Seerr] admin first paint from stash"),
        "{lines}"
    );
    assert!(
        !lines.contains("connect.sid"),
        "no secret in the log: {lines}"
    );
}

#[test]
fn a_warm_up_never_runs_twice_at_the_same_time() {
    let (stash, log) = fresh();
    let w = world(ADMIN);
    let h = hub(&w, &stash, &log);
    let (a, b) = run(async { futures_util::future::join(h.warm_up(), h.warm_up()).await });
    assert!(a ^ b, "one ran, the other turned away: {a} {b}");
    assert_eq!(asked(&w, "auth/me"), 1, "the account was read once");
    // Once it is over, the next start may warm again.
    assert!(run(h.warm_up()));
}

#[test]
fn an_ordinary_account_warms_up_without_the_admin_reads() {
    let (stash, log) = fresh();
    let w = world(REQUEST);
    assert!(run(hub(&w, &stash, &log).warm_up()));
    assert_eq!(asked(&w, "request?take=100"), 0, "no queue");
    assert_eq!(asked(&w, "request/count"), 0, "no queue count");
    assert_eq!(asked(&w, "issue/count"), 0, "no problem count");
    assert!(asked(&w, "request?") >= 1, "its own requests were read");
}

#[test]
fn a_page_opened_while_the_warm_up_runs_waits_for_it_instead_of_reading_again() {
    let (stash, log) = fresh();
    let w = world(ADMIN);
    let h = hub(&w, &stash, &log);
    let page = SeerrAdminScreen::new(Arc::clone(&h));
    let (warmed, painted) = run(async {
        futures_util::future::join(h.warm_up(), async {
            // Opens a moment after the warm-up began, with nothing stored yet.
            tokio::time::sleep(Duration::from_millis(LATE_MS / 2)).await;
            page.restore_all().await
        })
        .await
    });
    assert!(warmed && painted);
    let urls: Vec<String> = w.requests().iter().map(|r| r.url.to_string()).collect();
    assert_eq!(
        asked(&w, "request?take=100"),
        1,
        "{urls:?}: the queue was read by the warm-up only, not by the page too"
    );
}
