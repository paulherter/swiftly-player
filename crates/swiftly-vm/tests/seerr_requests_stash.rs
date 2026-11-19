//! "Meine Anfragen" over a fake server and a stash, the way the desktop runs it: the second open paints the stored list
//! without one call and the pills work on it (the withdrawn request is covered in the uniffi test `seerr_tests`).
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::sync::Arc;

use futures_executor::block_on;
use swiftly_net::MockTransport;
use swiftly_seerr::{BodyStash, NoCookies, SeerrAccess, SeerrClient};
use swiftly_vm::{ListLoad, RequestPill, SeerrHub, SeerrListsScreen, Shared};

fn world() -> Arc<MockTransport> {
    Arc::new(
        MockTransport::new()
            .route("auth/me", 200, r#"{"id":2,"displayName":"demo","permissions":32}"#)
            .route("settings/public", 200, "{}")
            .route("user/2/quota", 200, "{}")
            .route("request/count", 200, r#"{"pending":1,"total":2}"#)
            .route(
                "request",
                200,
                r#"{"pageInfo":{"pages":1,"pageSize":50,"results":2,"page":1},"results":[
                {"id":50,"status":1,"mediaType":"movie","is4k":false,"requestedBy":{"id":2,"displayName":"demo"},
                 "media":{"id":20,"tmdbId":2002,"mediaType":"movie","status":2}},
                {"id":51,"status":2,"mediaType":"movie","is4k":false,"requestedBy":{"id":2,"displayName":"demo"},
                 "media":{"id":21,"tmdbId":2001,"mediaType":"movie","status":3}}]}"#,
            )
            .route("movie/2002", 200, r#"{"id":2002,"title":"Nordlicht","releaseDate":"2024-03-01"}"#)
            .route("movie/2001", 200, r#"{"id":2001,"title":"Nordstern","releaseDate":"2024-01-01"}"#),
    )
}

#[derive(Default)]
struct Memory(std::sync::Mutex<std::collections::HashMap<String, Vec<u8>>>);

impl BodyStash for Memory {
    fn get(&self, key: &str) -> Option<Vec<u8>> {
        self.0.lock().unwrap().get(key).cloned()
    }
    fn put(&self, key: &str, body: &[u8]) {
        self.0.lock().unwrap().insert(key.to_owned(), body.to_vec());
    }
}

fn screen(
    world: &Arc<MockTransport>,
    stash: &Arc<Memory>,
) -> Arc<SeerrListsScreen<Shared<MockTransport>, NoCookies>> {
    let client = SeerrClient::new(
        SeerrAccess::new("https://seerr.test", "connect.sid=x", &[]),
        Shared(Arc::clone(world)),
    )
    .with_stash(Arc::clone(stash) as Arc<dyn BodyStash>);
    SeerrListsScreen::new(SeerrHub::new(Some(client), "de".into()))
}

#[test]
fn the_second_open_paints_the_stored_list_without_a_call() {
    let stash = Arc::new(Memory::default());
    let first_world = world();
    let first = screen(&first_world, &stash);
    assert!(!block_on(first.restore_requests()), "nothing stored yet");
    assert_eq!(first.requests().load, ListLoad::Idle);
    assert_eq!(block_on(first.load_requests()).rows.len(), 2);

    let second_world = world();
    let second = screen(&second_world, &stash);
    assert!(block_on(second.restore_requests()));
    assert_eq!(second_world.requests().len(), 0, "the paint went to Seerr");
    assert_eq!(second.requests().rows.len(), 2);
    assert_eq!(second.select_pill(RequestPill::Open).rows.len(), 1);
    assert_eq!(second_world.requests().len(), 0, "a pill read from Seerr");
    block_on(second.load_requests());
    assert!(
        second_world
            .requests()
            .iter()
            .any(|r| r.url.path().ends_with("auth/me"))
    );
}
