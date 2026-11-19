//! The admin screen of Seerr over a fake server: the rights of the account arrive after the screen was first read.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::sync::Arc;

use futures_executor::block_on;
use swiftly_net::{Method, MockTransport};
use swiftly_seerr::{NoCookies, SeerrAccess, SeerrClient};
use swiftly_vm::{AdminTab, RequestPill, SeerrAdminScreen, SeerrHub, Shared};

/// Seerr's permission bit for an administrator: every right.
const ADMIN: i64 = 2;
/// Only the right to ask for things.
const REQUEST: i64 = 32;

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
                {"id":50,"status":1,"mediaType":"movie","is4k":false,"requestedBy":{"id":5,"displayName":"Lena"},
                 "media":{"id":20,"tmdbId":2002,"mediaType":"movie","status":2}},
                {"id":51,"status":4,"mediaType":"movie","is4k":false,"requestedBy":{"id":5,"displayName":"Lena"},
                 "media":{"id":21,"tmdbId":2001,"mediaType":"movie","status":1}}]}"#,
            )
            .route("movie/2002", 200, r#"{"id":2002,"title":"Nordlicht","releaseDate":"2024-03-01"}"#)
            .route("movie/2001", 200, r#"{"id":2001,"title":"Nordstern","releaseDate":"2024-01-01"}"#)
            .route_method(Method::Post, "request/50/approve", 200, r#"{"id":50,"status":2}"#)
            .route_method(Method::Post, "request/50/decline", 200, r#"{"id":50,"status":3}"#),
    )
}

fn screen(world: &Arc<MockTransport>) -> Arc<SeerrAdminScreen<Shared<MockTransport>, NoCookies>> {
    let client = SeerrClient::new(
        SeerrAccess::new("https://seerr.test", "connect.sid=x", &[]),
        Shared(Arc::clone(world)),
    );
    SeerrAdminScreen::new(SeerrHub::new(Some(client), "de".into()))
}

fn posts(world: &MockTransport, tail: &str) -> usize {
    world
        .requests()
        .iter()
        .filter(|r| r.method == Method::Post && r.url.path().ends_with(tail))
        .count()
}

/// The cause found on the desktop: the screen made its request list on the first read, before the hub had loaded the
/// account's rights, so no row offered a verb. Whatever the screen is asked first, the rights of the account win.
#[test]
fn verbs_appear_when_the_rights_arrive_after_the_first_read() {
    let world = world(ADMIN);
    let admin = screen(&world);

    // The first frame draws before anything loaded: the rights are unknown, nothing is offered, the queue is not a tab.
    assert!(admin.requests().rows.is_empty());
    assert!(admin.tabs().is_empty());

    let info = block_on(admin.load_requests());
    let waiting = info
        .rows
        .iter()
        .find(|r| r.id == 50)
        .expect("the waiting request");
    assert!(
        waiting.can_approve && waiting.can_decline,
        "a manager gets Freigeben and Ablehnen"
    );
    let failed = info
        .rows
        .iter()
        .find(|r| r.id == 51)
        .expect("the failed request");
    assert!(
        failed.can_retry,
        "a manager gets Nochmal on a failed request"
    );
    assert_eq!(admin.first_tab(), Some(AdminTab::Requests));
}

#[test]
fn verbs_appear_when_a_pill_was_picked_before_the_rights_arrived() {
    let world = world(ADMIN);
    let admin = screen(&world);

    // A host that picks a pill first creates the list too: the load hands the rights in afterwards.
    let _ = admin.select_pill(RequestPill::All);
    let info = block_on(admin.load_requests());
    let waiting = info
        .rows
        .iter()
        .find(|r| r.id == 50)
        .expect("the waiting request");
    assert!(waiting.can_approve && waiting.can_decline);
}

#[test]
fn an_account_without_the_right_is_offered_no_verb() {
    let world = world(REQUEST);
    let admin = screen(&world);
    let _ = admin.requests();
    let info = block_on(admin.load_requests());
    assert!(
        info.rows
            .iter()
            .all(|r| !r.can_approve && !r.can_decline && !r.can_retry)
    );
    assert!(
        admin.tabs().is_empty(),
        "no admin tab without a right to manage"
    );
}

#[test]
fn approve_and_decline_send_their_calls() {
    let world = world(ADMIN);
    let admin = screen(&world);
    let _ = admin.requests();
    block_on(admin.load_requests());

    block_on(admin.approve(50));
    assert_eq!(posts(&world, "request/50/approve"), 1);
    block_on(admin.decline(50));
    assert_eq!(posts(&world, "request/50/decline"), 1);
}

/// An in-memory stash, the shape the core's cache gives the hosts.
#[derive(Default)]
struct Memory(std::sync::Mutex<std::collections::HashMap<String, Vec<u8>>>);

impl swiftly_seerr::BodyStash for Memory {
    fn get(&self, key: &str) -> Option<Vec<u8>> {
        self.0.lock().unwrap().get(key).cloned()
    }
    fn put(&self, key: &str, body: &[u8]) {
        self.0.lock().unwrap().insert(key.to_owned(), body.to_vec());
    }
}

fn stashed(
    world: &Arc<MockTransport>,
    stash: &Arc<Memory>,
) -> Arc<SeerrAdminScreen<Shared<MockTransport>, NoCookies>> {
    let client = SeerrClient::new(
        SeerrAccess::new("https://seerr.test", "connect.sid=x", &[]),
        Shared(Arc::clone(world)),
    )
    .with_stash(Arc::clone(stash) as Arc<dyn swiftly_seerr::BodyStash>);
    SeerrAdminScreen::new(SeerrHub::new(Some(client), "de".into()))
}

/// The desktop's second start: the admin page paints the last answers without one call, and the live read after it
/// still reads the account (the painted state never stands in for the live session).
#[test]
fn the_admin_page_paints_from_the_stash_and_the_live_read_still_asks_seerr() {
    let stash = Arc::new(Memory::default());
    // First start: nothing stored, nothing painted, nothing touched.
    let first_world = world(ADMIN);
    let first = stashed(&first_world, &stash);
    assert!(!block_on(first.restore_all()));
    assert!(
        first.tabs().is_empty(),
        "a miss leaves the screen untouched"
    );
    block_on(first.load_all());

    // Second start: a new screen over a Seerr that is asked nothing.
    let second_world = world(ADMIN);
    let second = stashed(&second_world, &stash);
    assert!(block_on(second.restore_all()));
    assert_eq!(second_world.requests().len(), 0, "the paint went to Seerr");
    assert_eq!(second.first_tab(), Some(AdminTab::Requests));
    assert_eq!(second.requests().rows.len(), 2);

    block_on(second.load_all());
    let asked_me = second_world
        .requests()
        .iter()
        .filter(|r| r.url.path().ends_with("auth/me"))
        .count();
    assert_eq!(asked_me, 1, "the live read asks for the account once");
    // A screen that already read is not painted over.
    assert!(!block_on(second.restore_all()));
}
