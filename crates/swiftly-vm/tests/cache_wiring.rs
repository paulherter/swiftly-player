//! The persistent cache wired into the library grid and the preview store: first paint from
//! the stored copy, offline keeps it, accounts never see each other's data, logout wipes,
//! events refresh, and a storm of cancelled loads leaves the cache usable.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;
use std::sync::atomic::Ordering;

use common::account;
use common::script::{Script, host, list, movie, param, wait_for};
use swiftly_cache::{CacheConfig, EntityCache};
use swiftly_library::{LibraryFilter, MemoryKeyValue, ShelfSource, Store};
use swiftly_vm::{Host, LibraryIntent, LibrarySpec, LibraryStatus, LibraryVm, ViewCache};

const N: usize = 40;

/// A library of `N` movies; `suffix` is appended to every name, so a new answer is visible.
fn server(suffix: &'static str) -> Arc<Script> {
    Script::new(move |r| {
        if !r.url.path().ends_with("/Items") {
            return Some("{}".into());
        }
        let all: Vec<_> = (0..N)
            .map(|n| {
                let mut m = movie(n);
                m["Name"] = format!("Titel {n:03}{suffix}").into();
                m
            })
            .collect();
        if let Some(ids) = param(r, "Ids") {
            let ids: Vec<_> = ids.split(',').map(String::from).collect();
            let found: Vec<_> = all
                .iter()
                .filter(|m| ids.contains(&m["Id"].as_str().unwrap().to_owned()))
                .cloned()
                .collect();
            return Some(list(&found, found.len()));
        }
        if param(r, "EnableImages").is_some() {
            return Some(list(&all, N));
        }
        Some(list(&all, N))
    })
}

fn spec() -> LibrarySpec {
    LibrarySpec {
        source: ShelfSource::new(Some("lib1"), Some("movies"), false, &[]),
        genre: None,
        remember_name: None,
    }
}

fn cache() -> ViewCache {
    ViewCache::new(EntityCache::in_memory(CacheConfig::default()).unwrap())
}

fn with_cache(cache: &ViewCache) -> Host {
    Host {
        cache: Some(cache.clone()),
        ..host()
    }
}

fn vm(net: &Arc<Script>, cache: &ViewCache, token: &str) -> LibraryVm<Script> {
    LibraryVm::new(
        net.clone(),
        with_cache(cache),
        Arc::new(MemoryKeyValue::new()),
        spec(),
        Some(account(token)),
    )
    .unwrap()
}

fn ready(vm: &LibraryVm<Script>) -> bool {
    vm.status().status == LibraryStatus::Ready
}

fn first_title(vm: &LibraryVm<Script>) -> Option<String> {
    vm.grid().tiles.first().map(|t| t.title.clone())
}

#[test]
fn a_second_visit_paints_from_the_cache_when_the_server_is_gone() {
    let cache = cache();
    let online = server("");
    let first = vm(&online, &cache, "A");
    first.send(LibraryIntent::Load);
    wait_for("first load", || ready(&first));
    let shown = first.grid().tiles.len();
    assert!(shown > 0);

    // A new screen, the server unreachable: the stored page shows, nothing says "offline".
    let down = server("");
    down.offline.store(true, Ordering::SeqCst);
    let second = vm(&down, &cache, "A");
    second.send(LibraryIntent::Load);
    wait_for("cached paint", || ready(&second));
    assert_eq!(second.grid().tiles.len(), shown);
    assert_eq!(first_title(&second), first_title(&first));
}

#[test]
fn another_account_never_sees_the_data_of_the_first() {
    let cache = cache();
    let online = server("");
    let a = vm(&online, &cache, "A");
    a.send(LibraryIntent::Load);
    wait_for("a", || ready(&a));

    let down = server("");
    down.offline.store(true, Ordering::SeqCst);
    let b = vm(&down, &cache, "B");
    b.send(LibraryIntent::Load);
    wait_for("b settles", || b.status().status != LibraryStatus::Loading);
    assert!(b.grid().tiles.is_empty(), "account B read account A's list");
    assert_eq!(b.status().status, LibraryStatus::Offline);
}

#[test]
fn logout_wipes_and_a_late_answer_is_not_written_back() {
    let cache = cache();
    let online = server("");
    let a = vm(&online, &cache, "A");
    a.send(LibraryIntent::Load);
    wait_for("a", || ready(&a));

    cache
        .entity_cache()
        .drop_scope(&ViewCache::scope(&account("A")));
    let down = server("");
    down.offline.store(true, Ordering::SeqCst);
    let again = vm(&down, &cache, "A");
    again.send(LibraryIntent::Load);
    wait_for("settles", || {
        again.status().status != LibraryStatus::Loading
    });
    assert!(again.grid().tiles.is_empty());

    // A fetch that began before the logout stores nothing afterwards.
    let ticket = cache.ticket(&ViewCache::scope(&account("A")));
    cache
        .entity_cache()
        .drop_scope(&ViewCache::scope(&account("A")));
    let item = serde_json::from_value(movie(1)).unwrap();
    assert!(cache.write_page(&ticket, "k", &[item], Some(1)));
    assert!(
        cache
            .read_page(&ViewCache::scope(&account("A")), "k")
            .is_none()
    );
}

#[test]
fn an_event_refreshes_the_grid_with_the_new_answer() {
    let cache = cache();
    let old = server("");
    let a = vm(&old, &cache, "A");
    a.send(LibraryIntent::Load);
    wait_for("load", || ready(&a));
    assert_eq!(first_title(&a).as_deref(), Some("Titel 000"));

    // The server changes (same net object cannot: use a switch through a new answer).
    let message = r#"{"MessageType":"LibraryChanged","Data":{"ItemsAdded":[],"ItemsUpdated":["m0"],"ItemsRemoved":[]}}"#;
    let event = swiftly_cache::parse_ws(message).unwrap();
    let before = old.count("/Items");
    cache
        .entity_cache()
        .apply_event(&ViewCache::scope(&account("A")), &event);
    wait_for("refetch", || old.count("/Items") > before);
}

#[test]
fn a_storm_of_cancelled_loads_leaves_the_cache_usable() {
    let cache = cache();
    let online = server("");
    for _ in 0..150 {
        let vm = vm(&online, &cache, "A");
        vm.send(LibraryIntent::Load);
        vm.send(LibraryIntent::SetFilter {
            filter: LibraryFilter::All,
        });
        drop(vm);
    }
    let last = vm(&online, &cache, "A");
    last.send(LibraryIntent::Load);
    wait_for("settles", || ready(&last));
    assert_eq!(last.grid().tiles.len(), N);
    // The one listener per closed screen is gone after the next event.
    cache
        .entity_cache()
        .lists_changed(&ViewCache::scope(&account("A")));
}

#[test]
fn the_preview_store_reads_the_old_host_copy_once_and_keeps_scopes_apart() {
    let cache = cache();
    let host_store: Arc<dyn Store> = Arc::new(swiftly_library::MemoryStore::new());
    host_store.write("startseite-x", b"old");
    let a = ViewCache::scope(&account("A"));
    let b = ViewCache::scope(&account("B"));
    let store_a = cache.preview_store(&a, host_store.clone());
    assert_eq!(store_a.read("startseite-x").as_deref(), Some(&b"old"[..]));
    store_a.write("startseite-x", b"new");
    assert_eq!(store_a.read("startseite-x").as_deref(), Some(&b"new"[..]));
    // The host copy was replaced, not duplicated, and the other account sees neither.
    assert!(host_store.read("startseite-x").is_none());
    let store_b = cache.preview_store(&b, host_store);
    assert!(store_b.read("startseite-x").is_none());
    cache.entity_cache().drop_scope(&a);
    assert!(store_a.read("startseite-x").is_none());
}
