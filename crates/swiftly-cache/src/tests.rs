use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use swiftly_library::Store;

use super::*;

fn mem() -> EntityCache {
    EntityCache::in_memory(CacheConfig::default()).expect("cache")
}
fn scope() -> Scope {
    Scope::new("https://jf.test", "u1")
}
fn ids(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| (*s).to_string()).collect()
}
fn item(id: &str) -> (String, Vec<u8>) {
    (id.to_string(), format!("{{\"Id\":\"{id}\"}}").into_bytes())
}

#[test]
fn entity_and_list_round_trip_with_total_and_order() {
    let c = mem();
    let t = c.ticket(&scope());
    c.put_entities(&t, "item", &[item("a"), item("b")])
        .expect("put");
    let d = c
        .put_list(&t, "movies", &ids(&["b", "a"]), Some(2))
        .expect("list");
    assert_eq!(d.inserted.len(), 2);
    let l = c.get_list(&scope(), "movies").expect("list");
    assert_eq!(
        (l.ids, l.total, l.stale),
        (ids(&["b", "a"]), Some(2), false)
    );
    assert_eq!(
        &*c.get_entity(&scope(), "item", "a").expect("a").data,
        b"{\"Id\":\"a\"}"
    );
    assert!(c.get_entity(&scope(), "item", "zz").is_none());
}

#[test]
fn diff_names_inserts_removals_and_moves() {
    let d = diff_ids(&ids(&["a", "b", "c", "d"]), &ids(&["b", "a", "c", "x"]));
    assert_eq!(d.inserted, vec![(3, "x".to_string())]);
    assert_eq!(d.removed, ids(&["d"]));
    assert_eq!(
        d.moved.len(),
        1,
        "one of a/b moved, the rest keeps order: {d:?}"
    );
    assert!(diff_ids(&ids(&["a"]), &ids(&["a"])).is_empty());
}

#[test]
fn page_merge_keeps_later_pages_and_cuts_to_total() {
    let c = mem();
    let t = c.ticket(&scope());
    c.put_list_page(&t, "k", 0, &ids(&["1", "2"]), Some(6))
        .expect("p1");
    c.put_list_page(&t, "k", 2, &ids(&["3", "4"]), Some(6))
        .expect("p2");
    c.put_list_page(&t, "k", 0, &ids(&["0", "2"]), Some(6))
        .expect("refresh p1");
    assert_eq!(
        c.get_list(&scope(), "k").expect("l").ids,
        ids(&["0", "2", "3", "4"])
    );
    c.put_list_page(&t, "k", 0, &ids(&["0", "2"]), Some(3))
        .expect("shrink");
    assert_eq!(c.get_list(&scope(), "k").expect("l").ids.len(), 3);
}

#[test]
fn events_mark_stale_delete_removed_and_notify() {
    let c = mem();
    let heard = Arc::new(Mutex::new(Vec::new()));
    let h = Arc::clone(&heard);
    c.subscribe(move |ch| h.lock().expect("lock").push(ch.clone()));
    let t = c.ticket(&scope());
    c.put_entities(&t, "item", &[item("a"), item("b")])
        .expect("put");
    c.put_list(&t, "k", &ids(&["a", "b"]), Some(2))
        .expect("list");
    let ev = parse_ws(r#"{"MessageType":"LibraryChanged","Data":{"ItemsAdded":["n"],"ItemsUpdated":["a"],"ItemsRemoved":["b"]}}"#).expect("event");
    c.apply_event(&scope(), &ev);
    assert!(c.get_list(&scope(), "k").expect("l").stale);
    assert!(c.get_entity(&scope(), "item", "a").expect("a").stale);
    assert!(
        c.get_entity(&scope(), "item", "b").is_none(),
        "removed item is gone"
    );
    assert_eq!(heard.lock().expect("lock").len(), 2);
    let ud =
        parse_ws(r#"{"MessageType":"UserDataChanged","Data":{"UserDataList":[{"ItemId":"a"}]}}"#)
            .expect("ud");
    assert_eq!(
        ud,
        Invalidation::UserDataChanged {
            item_ids: ids(&["a"])
        }
    );
    assert!(parse_ws(r#"{"MessageType":"KeepAlive"}"#).is_none());
}

#[test]
fn fetch_that_started_before_an_event_is_stored_stale() {
    let c = mem();
    let t = c.ticket(&scope());
    c.apply_event(
        &scope(),
        &Invalidation::UserDataChanged {
            item_ids: ids(&["a"]),
        },
    );
    c.put_list(&t, "k", &ids(&["a"]), Some(1)).expect("list");
    assert!(
        c.get_list(&scope(), "k").expect("l").stale,
        "old fetch must not look fresh"
    );
    let t2 = c.ticket(&scope());
    c.put_list(&t2, "k", &ids(&["a"]), Some(1)).expect("list");
    assert!(!c.get_list(&scope(), "k").expect("l").stale);
}

#[test]
fn dropped_scope_rejects_late_writes_and_other_scopes_are_untouched() {
    let c = mem();
    let other = Scope::new("https://jf.test", "u2");
    let t_old = c.ticket(&scope());
    let t_other = c.ticket(&other);
    c.put_entities(&t_other, "item", &[item("a")])
        .expect("other");
    c.put_entities(&t_old, "item", &[item("a")]).expect("mine");
    c.drop_scope(&scope());
    assert_eq!(
        c.put_entities(&t_old, "item", &[item("late")]),
        Err(CacheError::StaleTicket)
    );
    assert_eq!(
        c.put_list(&t_old, "k", &ids(&["late"]), None),
        Err(CacheError::StaleTicket)
    );
    assert!(c.get_entity(&scope(), "item", "a").is_none());
    assert!(c.get_entity(&scope(), "item", "late").is_none());
    assert!(c.get_entity(&other, "item", "a").is_some());
    let fresh = c.ticket(&scope());
    c.put_entities(&fresh, "item", &[item("a")])
        .expect("after re-login");
}

#[test]
fn size_cap_evicts_least_recently_used() {
    let mut cfg = CacheConfig {
        max_bytes: 1000,
        memory_budget: 100,
        ..CacheConfig::default()
    };
    let clock = Arc::new(Mutex::new(1000.0));
    let c2 = Arc::clone(&clock);
    cfg.now = Arc::new(move || {
        let mut g = c2.lock().expect("lock");
        *g += 1.0;
        *g
    });
    let c = EntityCache::in_memory(cfg).expect("cache");
    let t = c.ticket(&scope());
    for i in 0..30 {
        c.put_entities(&t, "item", &[(format!("i{i}"), vec![b'x'; 100])])
            .expect("put");
    }
    assert!(c.disk_bytes() <= 1000, "cap held: {}", c.disk_bytes());
    assert!(
        c.get_entity(&scope(), "item", "i0").is_none(),
        "oldest evicted"
    );
    assert!(
        c.get_entity(&scope(), "item", "i29").is_some(),
        "newest kept"
    );
}

#[test]
fn memory_budget_is_respected() {
    let cfg = CacheConfig {
        memory_budget: 1000,
        ..CacheConfig::default()
    };
    let c = EntityCache::in_memory(cfg).expect("cache");
    let t = c.ticket(&scope());
    for i in 0..50 {
        c.put_entities(&t, "item", &[(format!("i{i}"), vec![b'x'; 100])])
            .expect("put");
    }
    assert!(c.memory_bytes() <= 1000);
    assert!(
        c.get_entity(&scope(), "item", "i0").is_some(),
        "still on disk"
    );
}

#[test]
fn survives_restart_and_garbage_file_is_rebuilt() {
    let dir = tempfile::tempdir().expect("dir");
    let path = dir.path().join("cache.sqlite");
    {
        let c = EntityCache::open(&path, CacheConfig::default()).expect("open");
        let t = c.ticket(&scope());
        c.put_entities(&t, "item", &[item("a")]).expect("put");
        c.put_list(&t, "k", &ids(&["a"]), Some(1)).expect("list");
    }
    let c = EntityCache::open(&path, CacheConfig::default()).expect("reopen");
    assert!(
        c.get_entity(&scope(), "item", "a").is_some(),
        "offline start keeps data"
    );
    assert_eq!(c.recoveries(), 0);
    drop(c);
    std::fs::write(
        &path,
        b"this is not a database at all, just text".repeat(50),
    )
    .expect("garbage");
    let c = EntityCache::open(&path, CacheConfig::default()).expect("rebuilt");
    assert_eq!(c.recoveries(), 1);
    assert!(c.get_entity(&scope(), "item", "a").is_none());
    let t = c.ticket(&scope());
    c.put_entities(&t, "item", &[item("b")])
        .expect("works again");
}

#[test]
fn damaged_pages_are_detected_on_open() {
    let dir = tempfile::tempdir().expect("dir");
    let path = dir.path().join("cache.sqlite");
    {
        let c = EntityCache::open(&path, CacheConfig::default()).expect("open");
        let t = c.ticket(&scope());
        let rows: Vec<_> = (0..400)
            .map(|i| (format!("i{i}"), vec![b'y'; 500]))
            .collect();
        c.put_entities(&t, "item", &rows).expect("put");
    }
    let mut bytes = std::fs::read(&path).expect("read");
    let n = bytes.len();
    for b in &mut bytes[n / 3..n / 3 + 8192] {
        *b = 0xA5;
    }
    std::fs::write(&path, &bytes).expect("damage");
    let _ = std::fs::remove_file(dir.path().join("cache.sqlite-wal"));
    let c = EntityCache::open(&path, CacheConfig::default()).expect("open damaged");
    let t = c.ticket(&scope());
    c.put_entities(&t, "item", &[item("z")]).expect("usable");
    assert!(c.get_entity(&scope(), "item", "z").is_some());
}

#[test]
fn unknown_newer_schema_is_rebuilt() {
    let dir = tempfile::tempdir().expect("dir");
    let path = dir.path().join("cache.sqlite");
    {
        let conn = Connection::open(&path).expect("raw");
        conn.execute_batch("CREATE TABLE entity(x); PRAGMA user_version = 99;")
            .expect("old");
    }
    let c = EntityCache::open(&path, CacheConfig::default()).expect("open");
    let t = c.ticket(&scope());
    c.put_entities(&t, "item", &[item("a")])
        .expect("schema usable");
    let v: i64 = c
        .with_db(|c| c.query_row("PRAGMA user_version", [], |r| r.get(0)))
        .expect("v");
    assert_eq!(v, SCHEMA_VERSION);
}

#[test]
fn concurrent_writers_two_handles_one_file() {
    let dir = tempfile::tempdir().expect("dir");
    let path = dir.path().join("cache.sqlite");
    let a = EntityCache::open(&path, CacheConfig::default()).expect("a");
    let b = EntityCache::open(&path, CacheConfig::default()).expect("b");
    let done = Arc::new(AtomicUsize::new(0));
    let mut threads = Vec::new();
    for n in 0..8 {
        let c = if n % 2 == 0 { a.clone() } else { b.clone() };
        let done = Arc::clone(&done);
        threads.push(std::thread::spawn(move || {
            let t = c.ticket(&scope());
            for i in 0..50 {
                c.put_entities(&t, "item", &[item(&format!("t{n}-{i}"))])
                    .expect("write");
                c.put_list(&t, &format!("l{n}"), &[format!("t{n}-{i}")], Some(1))
                    .expect("list");
            }
            done.fetch_add(1, Ordering::SeqCst);
        }));
    }
    for t in threads {
        t.join().expect("thread");
    }
    assert_eq!(done.load(Ordering::SeqCst), 8);
    let c = EntityCache::open(&path, CacheConfig::default()).expect("verify");
    for n in 0..8 {
        assert!(
            c.get_entity(&scope(), "item", &format!("t{n}-49"))
                .is_some()
        );
    }
}

#[test]
fn blob_store_is_the_library_store_and_keeps_the_preview_offline() {
    let dir = tempfile::tempdir().expect("dir");
    let path = dir.path().join("cache.sqlite");
    let store_scope = Scope("store".into());
    {
        let c = EntityCache::open(&path, CacheConfig::default()).expect("open");
        let s = c.blob_store(&store_scope);
        s.write("home-acc1.json", b"{\"rails\":[]}");
        assert_eq!(
            s.read("home-acc1.json").as_deref(),
            Some(b"{\"rails\":[]}".as_slice())
        );
    }
    let c = EntityCache::open(&path, CacheConfig::default()).expect("reopen");
    let s = c.blob_store(&store_scope);
    assert!(s.read("home-acc1.json").is_some());
    s.remove("home-acc1.json");
    assert!(s.read("home-acc1.json").is_none());
}
