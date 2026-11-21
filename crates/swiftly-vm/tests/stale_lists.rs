//! The host-facing signal "this account's lists went stale": what the server socket, a link that came back after a
//! real drop and a delete tell the cache moves one count per account, so a host that draws its own pages reloads them.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;
use std::task::{Context, Poll, Waker};
use std::time::Duration;

use common::account;
use swiftly_cache::{CacheConfig, EntityCache, Invalidation};
use swiftly_vm::{StaleLists, ViewCache};

fn rig() -> (ViewCache, Arc<StaleLists>) {
    let cache = ViewCache::new(EntityCache::in_memory(CacheConfig::default()).unwrap());
    let stale = StaleLists::watch(&cache);
    (cache, stale)
}

/// `true` if the future is still waiting after one poll.
fn waits<F: std::future::Future + Unpin>(f: &mut F) -> bool {
    matches!(
        std::pin::Pin::new(f).poll(&mut Context::from_waker(Waker::noop())),
        Poll::Pending
    )
}

#[test]
fn a_user_data_event_from_the_socket_moves_the_count_of_its_account_only() {
    let (cache, stale) = rig();
    let (a, b) = (account("A"), account("B"));
    let (seen_a, seen_b) = (stale.version(&a), stale.version(&b));
    let mut wait_a = Box::pin(stale.after(&a, seen_a));
    let mut wait_b = Box::pin(stale.after(&b, seen_b));
    assert!(waits(&mut wait_a), "nothing happened yet");

    cache.apply_event(
        &a,
        &Invalidation::UserDataChanged {
            item_ids: vec!["x".into()],
        },
    );
    assert!(!waits(&mut wait_a), "the account's own wait resolves");
    assert!(waits(&mut wait_b), "another account's wait does not");
    assert!(stale.version(&a) > seen_a);
    assert_eq!(stale.version(&b), seen_b);
}

#[test]
fn a_library_event_a_reconnect_and_a_delete_all_count() {
    let (cache, stale) = rig();
    let a = account("A");
    let mut seen = stale.version(&a);
    cache.apply_event(
        &a,
        &Invalidation::LibraryChanged {
            added: vec![],
            updated: vec!["u".into()],
            removed: vec![],
        },
    );
    assert!(stale.version(&a) > seen, "LibraryChanged");
    seen = stale.version(&a);
    cache.lists_changed(&a);
    assert!(
        stale.version(&a) > seen,
        "the refresh after a real drop and the polling fallback"
    );
    seen = stale.version(&a);
    cache.apply_event(
        &a,
        &Invalidation::LibraryChanged {
            added: vec![],
            updated: vec![],
            removed: vec!["gone".into()],
        },
    );
    assert!(stale.version(&a) > seen, "the delete's removal");
}

#[test]
fn what_already_happened_before_the_host_asked_is_not_replayed() {
    let (cache, stale) = rig();
    let a = account("A");
    cache.lists_changed(&a);
    let seen = stale.version(&a);
    let mut wait = Box::pin(stale.after(&a, seen));
    assert!(waits(&mut wait), "the host starts from the count it read");
}

#[test]
fn a_burst_answers_once_and_a_dropped_wait_leaves_nothing_behind() {
    let (cache, stale) = rig();
    let a = account("A");
    let seen = stale.version(&a);
    let mut early = Box::pin(stale.after(&a, seen));
    assert!(waits(&mut early));
    drop(early);
    for _ in 0..5 {
        cache.lists_changed(&a);
    }
    let latest = futures_executor::block_on(stale.after(&a, seen));
    assert_eq!(
        latest,
        stale.version(&a),
        "one answer with the newest count"
    );
    // Waiting from the newest count parks again.
    let mut next = Box::pin(stale.after(&a, latest));
    assert!(waits(&mut next));
}

#[test]
fn a_wait_on_another_thread_wakes_when_the_event_lands() {
    let (cache, stale) = rig();
    let a = account("A");
    let seen = stale.version(&a);
    let (waiter, from) = (Arc::clone(&stale), a.clone());
    let handle = std::thread::spawn(move || futures_executor::block_on(waiter.after(&from, seen)));
    std::thread::sleep(Duration::from_millis(50));
    cache.lists_changed(&a);
    assert!(handle.join().unwrap() > seen);
}
