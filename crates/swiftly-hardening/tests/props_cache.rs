//! Model-based random sequences for `EntityCache` (entities, lists, pages, blobs, events,
//! `lists_changed`, `drop_scope`, tickets, eviction, memory budget, reopen). A failure prints
//! the seed; replay with `HARDENING_SEED=<n>`.
//!
//! Two modes per seed. Roomy: the disk cap is never reached, so the model is exact (what was
//! stored comes back byte for byte, with the stale flag the rules give it). Tight: the cap is a
//! few payloads, so rows get evicted; then the model is a superset (a hit must equal the model,
//! a miss is allowed) but the budget, the byte counter and "nothing deleted comes back" are
//! still exact. In both modes every scope is isolated from the others.
#![allow(clippy::expect_used, clippy::unwrap_used)]

mod common;

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use swiftly_cache::{
    CacheChange, CacheConfig, CacheError, EntityCache, Invalidation, ListDiff, Scope, Ticket,
    diff_ids,
};
use swiftly_hardening::Rng;
use swiftly_library::Store;

const KINDS: [&str; 2] = ["item", "person"];
const IDS: [&str; 8] = ["i0", "i1", "i2", "i3", "i4", "i5", "i6", "i7"];
const LISTS: [&str; 3] = ["k0", "k1", "k2"];
const BLOBS: [&str; 2] = ["b0", "b1"];

type Ent = (Vec<u8>, f64, bool);
type Lst = (Vec<String>, Option<u64>, f64, bool);

struct Model {
    ent: HashMap<(usize, &'static str, &'static str), Ent>,
    lst: HashMap<(usize, &'static str), Lst>,
    blob: HashMap<(usize, &'static str), Vec<u8>>,
    gens: Vec<(u64, u64)>,
}

struct Harness {
    cache: EntityCache,
    scopes: Vec<Scope>,
    clock: Arc<AtomicU64>,
    heard: Arc<Mutex<Vec<CacheChange>>>,
    limited_calls: Arc<AtomicU64>,
    tickets: Vec<(Ticket, usize, u64, u64)>,
    config: (u64, usize),
    path: Option<std::path::PathBuf>,
    lossy: bool,
}

fn json_len(ids: &[String]) -> usize {
    serde_json::to_vec(ids).expect("json").len()
}

impl Harness {
    fn open(&mut self) {
        let clock = Arc::clone(&self.clock);
        let config = CacheConfig {
            max_bytes: self.config.0,
            memory_budget: self.config.1,
            touch_interval: 1.5,
            now: Arc::new(move || clock.load(Ordering::Relaxed) as f64),
        };
        self.cache = match &self.path {
            Some(p) => EntityCache::open(p, config).expect("open"),
            None => EntityCache::in_memory(config).expect("in memory"),
        };
        let heard = Arc::clone(&self.heard);
        self.cache
            .subscribe(move |c| heard.lock().unwrap().push(c.clone()));
        let calls = Arc::clone(&self.limited_calls);
        self.limited_calls.store(0, Ordering::Relaxed);
        self.cache
            .subscribe_while(move |_| calls.fetch_add(1, Ordering::Relaxed) + 1 < 2);
        self.tickets.clear();
    }

    fn tick(&self) {
        self.clock.fetch_add(1, Ordering::Relaxed);
    }

    fn heard(&self) -> Vec<CacheChange> {
        std::mem::take(&mut *self.heard.lock().unwrap())
    }
}

fn payload(rng: &mut Rng, label: &str, max: u64) -> Vec<u8> {
    let len = 1 + rng.below(max) as usize;
    let mut v = label.as_bytes().to_vec();
    while v.len() < len {
        v.push(b'a' + rng.below(26) as u8);
    }
    v.truncate(len.max(1));
    v
}

fn subset(rng: &mut Rng, pct: u64) -> Vec<&'static str> {
    IDS.iter().copied().filter(|_| rng.chance(pct)).collect()
}

fn owned(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| (*s).to_string()).collect()
}

/// `diff_ids` against its written meaning.
fn check_diff(old: &[String], new: &[String], d: &ListDiff, ctx: &str) {
    let removed: Vec<String> = old.iter().filter(|x| !new.contains(x)).cloned().collect();
    assert_eq!(d.removed, removed, "{ctx}: removed");
    let inserted: Vec<(usize, String)> = new
        .iter()
        .enumerate()
        .filter(|(_, x)| !old.contains(x))
        .map(|(i, x)| (i, x.clone()))
        .collect();
    assert_eq!(d.inserted, inserted, "{ctx}: inserted");
    let kept_old: Vec<&String> = old.iter().filter(|x| new.contains(x)).collect();
    let kept_new: Vec<&String> = new.iter().filter(|x| old.contains(x)).collect();
    assert!(
        d.moved.iter().all(|m| kept_new.contains(&m)),
        "{ctx}: moved holds a foreign id"
    );
    assert_eq!(
        d.moved.is_empty(),
        kept_old == kept_new,
        "{ctx}: moved empty iff the common order is kept (old {old:?}, new {new:?}, diff {d:?})"
    );
}

fn case(seed: u64) {
    let mut rng = Rng::new(seed ^ 0xCAC4_E001);
    let lossy = seed % 3 == 2;
    let persistent = !lossy && seed.is_multiple_of(4);
    let payload_max: u64 = if lossy { 90 } else { 200 };
    let path = persistent.then(|| {
        let dir = std::env::temp_dir().join(format!(
            "swiftly-hardening-cache-{}-{seed}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).expect("temp dir");
        dir.join("cache.sqlite")
    });
    let (max_bytes, memory_budget) = if lossy {
        (200 + rng.below(500), 100 + rng.below(300) as usize)
    } else {
        (u64::MAX / 4, 250 + rng.below(500) as usize)
    };
    let cap_hit = max_bytes / 10 * 9;

    let clock = Arc::new(AtomicU64::new(1000));
    let mut h = Harness {
        cache: EntityCache::in_memory(CacheConfig::default()).expect("cache"),
        scopes: ["http://a|u1", "http://a|u2", "http://b|u1", "http://a|u"]
            .iter()
            .map(|s| Scope((*s).to_string()))
            .collect(),
        clock,
        heard: Arc::new(Mutex::new(Vec::new())),
        limited_calls: Arc::new(AtomicU64::new(0)),
        tickets: Vec::new(),
        config: (max_bytes, memory_budget),
        path: path.clone(),
        lossy,
    };
    h.open();
    let mut m = Model {
        ent: HashMap::new(),
        lst: HashMap::new(),
        blob: HashMap::new(),
        gens: vec![(0, 0); h.scopes.len()],
    };
    let mut total_heard = 0usize;
    let mut log: Vec<String> = Vec::new();
    let mut counter = 0u64;
    let steps = 50 + rng.below(70) as usize;

    for step in 0..steps {
        let tail = log
            .iter()
            .rev()
            .take(5)
            .rev()
            .cloned()
            .collect::<Vec<_>>()
            .join(" | ");
        let ctx = format!("step {step} (lossy={lossy}, persistent={persistent}); tail: {tail}");
        let si = rng.below(h.scopes.len() as u64) as usize;
        let scope = h.scopes[si].clone();
        h.tick();
        // A ticket: usually fresh, sometimes one taken a while ago.
        let take_ticket = |h: &mut Harness, m: &Model, rng: &mut Rng| -> (Ticket, u64, u64) {
            let old: Vec<usize> = (0..h.tickets.len())
                .filter(|i| h.tickets[*i].1 == si)
                .collect();
            if !old.is_empty() && rng.chance(35) {
                let t = &h.tickets[*rng.pick(&old)];
                return (t.0.clone(), t.2, t.3);
            }
            let t = h.cache.ticket(&scope);
            let (g, e) = m.gens[si];
            h.tickets.push((t.clone(), si, g, e));
            if h.tickets.len() > 14 {
                h.tickets.remove(0);
            }
            (t, g, e)
        };
        match rng.below(100) {
            0..=24 => {
                let kind = *rng.pick(&KINDS);
                let n = 1 + rng.below(4) as usize;
                let mut items: Vec<(String, Vec<u8>)> = Vec::new();
                let mut picked: Vec<&'static str> = Vec::new();
                for _ in 0..n {
                    let id = *rng.pick(&IDS);
                    counter += 1;
                    picked.push(id);
                    items.push((
                        id.to_string(),
                        payload(
                            &mut rng,
                            &format!("{si}/{kind}/{id}#{counter}"),
                            payload_max,
                        ),
                    ));
                }
                let (t, g, e) = take_ticket(&mut h, &m, &mut rng);
                log.push(format!(
                    "put_entities s{si} {kind} {picked:?} gen {g}/{} ",
                    m.gens[si].0
                ));
                h.tick();
                let r = h.cache.put_entities(&t, kind, &items);
                if g != m.gens[si].0 {
                    assert_eq!(
                        r,
                        Err(CacheError::StaleTicket),
                        "{ctx}: old-generation ticket stored"
                    );
                } else {
                    assert_eq!(r, Ok(()), "{ctx}: put_entities");
                    let fresh = e == m.gens[si].1;
                    for (id, (_, data)) in picked.iter().zip(&items) {
                        m.ent.insert(
                            (si, kind, *id),
                            (data.clone(), h.clock.load(Ordering::Relaxed) as f64, !fresh),
                        );
                    }
                    if lossy && items.len() == 1 && items[0].1.len() as u64 <= cap_hit {
                        let got = h.cache.get_entity(&scope, kind, &items[0].0);
                        assert!(
                            got.is_some(),
                            "{ctx}: the row just stored is already evicted"
                        );
                    }
                }
            }
            25..=39 => {
                let key = *rng.pick(&LISTS);
                let mut pool = owned(&subset(&mut rng, 55));
                if rng.chance(50) {
                    // A shuffle, so that moves show up.
                    for i in (1..pool.len()).rev() {
                        pool.swap(i, rng.below(i as u64 + 1) as usize);
                    }
                }
                let total = rng.chance(70).then(|| pool.len() as u64 + rng.below(3));
                let (t, g, e) = take_ticket(&mut h, &m, &mut rng);
                log.push(format!("put_list s{si} {key} {pool:?} {total:?}"));
                // The old list as the cache itself knows it (an evicted one counts as none).
                let old_real = h.cache.get_list(&scope, key);
                if lossy {
                    match &old_real {
                        Some(l) => {
                            m.lst
                                .insert((si, key), (l.ids.clone(), l.total, l.fetched, l.stale));
                        }
                        None => {
                            m.lst.remove(&(si, key));
                        }
                    }
                }
                let old = m.lst.get(&(si, key)).cloned();
                h.tick();
                let r = h.cache.put_list(&t, key, &pool, total);
                if g != m.gens[si].0 {
                    assert_eq!(
                        r,
                        Err(CacheError::StaleTicket),
                        "{ctx}: old-generation ticket stored a list"
                    );
                } else {
                    let d = r.expect("put_list");
                    check_diff(old.as_ref().map_or(&[][..], |o| &o.0[..]), &pool, &d, &ctx);
                    assert_eq!(
                        d.total_changed,
                        old.as_ref().is_none_or(|o| o.1 != total),
                        "{ctx}: total_changed"
                    );
                    m.lst.insert(
                        (si, key),
                        (
                            pool.clone(),
                            total,
                            h.clock.load(Ordering::Relaxed) as f64,
                            e != m.gens[si].1,
                        ),
                    );
                    if lossy && json_len(&pool) as u64 <= cap_hit {
                        assert!(
                            h.cache.get_list(&scope, key).is_some(),
                            "{ctx}: the list just stored is already evicted"
                        );
                    }
                }
            }
            40..=49 => {
                let key = *rng.pick(&LISTS);
                let old_real = h.cache.get_list(&scope, key);
                if lossy {
                    match &old_real {
                        Some(l) => {
                            m.lst
                                .insert((si, key), (l.ids.clone(), l.total, l.fetched, l.stale));
                        }
                        None => {
                            m.lst.remove(&(si, key));
                        }
                    }
                }
                let old = m.lst.get(&(si, key)).cloned();
                let old_len = old.as_ref().map_or(0, |o| o.0.len());
                let start = rng.below(old_len as u64 + 2) as usize;
                let n = 1 + rng.below(4) as usize;
                let page: Vec<String> = (0..n)
                    .map(|_| {
                        counter += 1;
                        format!("n{counter}")
                    })
                    .collect();
                let total = rng
                    .chance(70)
                    .then(|| (start + page.len()) as u64 + rng.below(4));
                let (t, g, e) = take_ticket(&mut h, &m, &mut rng);
                log.push(format!(
                    "put_list_page s{si} {key} start {start} {page:?} {total:?} (old {old_len})"
                ));
                h.tick();
                let r = h.cache.put_list_page(&t, key, start, &page, total);
                if g != m.gens[si].0 {
                    assert_eq!(
                        r,
                        Err(CacheError::StaleTicket),
                        "{ctx}: old-generation ticket stored a page"
                    );
                } else {
                    let d = r.expect("put_list_page");
                    let old_ids = old.as_ref().map_or_else(Vec::new, |o| o.0.clone());
                    let gap = old_ids.len() < start && start > 0;
                    let expect: Vec<String> = if gap {
                        page.clone()
                    } else {
                        let mut merged = old_ids.clone();
                        let end = (start + page.len()).min(merged.len());
                        merged.splice(start..end, page.iter().cloned());
                        if let Some(t) = total {
                            merged.truncate(t as usize);
                        }
                        merged
                    };
                    check_diff(
                        &old_ids,
                        &expect,
                        &ListDiff {
                            total_changed: false,
                            ..d.clone()
                        },
                        &ctx,
                    );
                    if gap {
                        assert!(d.total_changed, "{ctx}: a gap must report total_changed");
                    } else {
                        assert_eq!(
                            d.total_changed,
                            old.as_ref().is_none_or(|o| o.1 != total),
                            "{ctx}: page total_changed"
                        );
                    }
                    m.lst.insert(
                        (si, key),
                        (
                            expect,
                            total,
                            h.clock.load(Ordering::Relaxed) as f64,
                            e != m.gens[si].1,
                        ),
                    );
                }
            }
            50..=62 => {
                let event = if rng.chance(60) {
                    Invalidation::LibraryChanged {
                        added: owned(&subset(&mut rng, 20)),
                        updated: owned(&subset(&mut rng, 30)),
                        removed: owned(&subset(&mut rng, 20)),
                    }
                } else {
                    Invalidation::UserDataChanged {
                        item_ids: owned(&subset(&mut rng, 35)),
                    }
                };
                log.push(format!("event s{si} {event:?}"));
                let (touched, removed): (Vec<String>, Vec<String>) = match &event {
                    Invalidation::LibraryChanged {
                        updated, removed, ..
                    } => (
                        updated.iter().chain(removed).cloned().collect(),
                        removed.clone(),
                    ),
                    Invalidation::UserDataChanged { item_ids } => (item_ids.clone(), vec![]),
                };
                let _ = h.heard();
                h.cache.apply_event(&scope, &event);
                m.gens[si].1 += 1;
                for l in m.lst.iter_mut().filter(|((s, _), _)| *s == si) {
                    l.1.3 = true;
                }
                let ids_touched: Vec<&str> = touched.iter().map(String::as_str).collect();
                for ((s, _, id), v) in m.ent.iter_mut() {
                    if *s == si && ids_touched.contains(id) {
                        v.2 = true;
                    }
                }
                m.ent
                    .retain(|(s, _, id), _| !(*s == si && removed.iter().any(|r| r == id)));
                let mut want = vec![CacheChange::ListsStale(scope.clone())];
                if !touched.is_empty() {
                    want.push(CacheChange::ItemsChanged(scope.clone(), touched));
                }
                let got = h.heard();
                assert_eq!(got, want, "{ctx}: what the listeners heard");
                total_heard += got.len();
            }
            63..=68 => {
                log.push(format!("lists_changed s{si}"));
                let _ = h.heard();
                h.cache.lists_changed(&scope);
                m.gens[si].1 += 1;
                for l in m.lst.iter_mut().filter(|((s, _), _)| *s == si) {
                    l.1.3 = true;
                }
                let got = h.heard();
                assert_eq!(
                    got,
                    vec![CacheChange::ListsStale(scope.clone())],
                    "{ctx}: lists_changed heard"
                );
                total_heard += got.len();
            }
            69..=72 => {
                log.push(format!("mark_lists_stale s{si}"));
                let _ = h.heard();
                h.cache.mark_lists_stale(&scope);
                for l in m.lst.iter_mut().filter(|((s, _), _)| *s == si) {
                    l.1.3 = true;
                }
                assert!(h.heard().is_empty(), "{ctx}: mark_lists_stale is silent");
            }
            73..=78 => {
                log.push(format!("drop_scope s{si}"));
                let _ = h.heard();
                h.cache.drop_scope(&scope);
                m.gens[si].0 += 1;
                m.gens[si].1 += 1;
                m.ent.retain(|(s, _, _), _| *s != si);
                m.lst.retain(|(s, _), _| *s != si);
                m.blob.retain(|(s, _), _| *s != si);
                let got = h.heard();
                assert_eq!(
                    got,
                    vec![CacheChange::ScopeDropped(scope.clone())],
                    "{ctx}: drop heard"
                );
                total_heard += got.len();
                // Every ticket taken before is dead, a new one works.
                let old: Vec<Ticket> = h
                    .tickets
                    .iter()
                    .filter(|t| t.1 == si)
                    .map(|t| t.0.clone())
                    .collect();
                for t in old {
                    assert_eq!(
                        h.cache
                            .put_entities(&t, "item", &[("i0".into(), b"x".to_vec())]),
                        Err(CacheError::StaleTicket),
                        "{ctx}: a ticket survived drop_scope"
                    );
                }
            }
            79..=86 => {
                let name = *rng.pick(&BLOBS);
                let store = h.cache.blob_store(&scope);
                if rng.chance(70) {
                    counter += 1;
                    let data = format!("blob {si} {name} {counter}").into_bytes();
                    log.push(format!("blob write s{si} {name}"));
                    store.write(name, &data);
                    m.blob.insert((si, name), data);
                } else {
                    log.push(format!("blob remove s{si} {name}"));
                    store.remove(name);
                    m.blob.remove(&(si, name));
                }
            }
            87..=91 if persistent => {
                log.push("reopen".into());
                let before = h.cache.disk_bytes();
                h.cache = EntityCache::in_memory(CacheConfig::default()).expect("placeholder");
                h.open();
                m.gens = vec![(0, 0); h.scopes.len()];
                assert_eq!(
                    h.cache.disk_bytes(),
                    before,
                    "{ctx}: byte counter after reopen"
                );
                assert_eq!(h.cache.memory_bytes(), 0, "{ctx}: memory after reopen");
                total_heard = 0;
            }
            _ => {
                log.push(format!("reads s{si}"));
            }
        }
        // The scope the step touched: every row against the model.
        verify_scope(&h, &m, si, &ctx);
        assert!(
            h.cache.memory_bytes() <= memory_budget,
            "{ctx}: memory {} over budget {memory_budget}",
            h.cache.memory_bytes()
        );
        assert!(
            h.cache.disk_bytes() <= max_bytes,
            "{ctx}: disk {} over cap {max_bytes}",
            h.cache.disk_bytes()
        );
        if step % 7 == 0 {
            for other in 0..h.scopes.len() {
                verify_scope(&h, &m, other, &ctx);
            }
            check_bytes(&h, &ctx);
        }
    }

    // Drain: dropping every scope leaves nothing anywhere and both counters at zero; the
    // listener that said "no more" was called at most twice.
    for (si, scope) in h.scopes.clone().iter().enumerate() {
        h.cache.drop_scope(scope);
        m.gens[si].0 += 1;
    }
    m.ent.clear();
    m.lst.clear();
    m.blob.clear();
    for si in 0..h.scopes.len() {
        verify_scope(&h, &m, si, "drain");
        for k in KINDS {
            for id in IDS {
                assert!(
                    h.cache.get_entity(&h.scopes[si], k, id).is_none(),
                    "drain: {k}/{id} survived"
                );
            }
        }
    }
    assert_eq!(h.cache.disk_bytes(), 0, "drain: disk bytes");
    assert_eq!(h.cache.memory_bytes(), 0, "drain: memory bytes");
    check_bytes(&h, "drain");
    assert!(
        h.limited_calls.load(Ordering::Relaxed) <= 2,
        "a listener that returned false was called again"
    );
    let _ = total_heard;
    if let Some(p) = path
        && let Some(dir) = p.parent()
    {
        drop(h);
        let _ = std::fs::remove_dir_all(dir);
    }
}

fn verify_scope(h: &Harness, m: &Model, si: usize, ctx: &str) {
    let scope = &h.scopes[si];
    for kind in KINDS {
        for id in IDS {
            let real = h.cache.get_entity(scope, kind, id);
            let want = m.ent.get(&(si, kind, id));
            match (real, want) {
                (Some(r), Some(w)) => {
                    assert_eq!(
                        (r.data.to_vec(), r.fetched, r.stale),
                        w.clone(),
                        "{ctx}: entity {scope:?} {kind}/{id}"
                    );
                }
                (None, None) => {}
                (None, Some(_)) if h.lossy => {}
                (r, w) => panic!(
                    "{ctx}: entity {scope:?} {kind}/{id}: real {} model {}",
                    r.is_some(),
                    w.is_some()
                ),
            }
        }
    }
    for key in LISTS {
        let real = h.cache.get_list(scope, key);
        let want = m.lst.get(&(si, key));
        match (real, want) {
            (Some(r), Some(w)) => {
                assert_eq!(
                    (r.ids, r.total, r.fetched, r.stale),
                    w.clone(),
                    "{ctx}: list {scope:?} {key}"
                );
            }
            (None, None) => {}
            (None, Some(_)) if h.lossy => {}
            (r, w) => panic!(
                "{ctx}: list {scope:?} {key}: real {} model {}",
                r.is_some(),
                w.is_some()
            ),
        }
    }
    let store = h.cache.blob_store(scope);
    for name in BLOBS {
        assert_eq!(
            store.read(name),
            m.blob.get(&(si, name)).cloned(),
            "{ctx}: blob {scope:?} {name}"
        );
    }
}

/// The byte counter against what is really in the closed pool of rows.
fn check_bytes(h: &Harness, ctx: &str) {
    let mut sum = 0u64;
    for scope in &h.scopes {
        for kind in KINDS {
            for id in IDS {
                if let Some(c) = h.cache.get_entity(scope, kind, id) {
                    sum += c.data.len() as u64;
                }
            }
        }
        for key in LISTS {
            if let Some(l) = h.cache.get_list(scope, key) {
                sum += json_len(&l.ids) as u64;
            }
        }
    }
    assert_eq!(
        h.cache.disk_bytes(),
        sum,
        "{ctx}: disk_bytes against the rows that are there"
    );
}

#[test]
fn entity_cache_random_sequences() {
    common::for_seeds("props_cache", 300, case);
}

#[test]
fn diff_ids_matches_its_meaning() {
    common::for_seeds("props_cache", 400, |seed| {
        let mut rng = Rng::new(seed);
        let mut pool: Vec<String> = IDS.iter().map(|s| (*s).to_string()).collect();
        let mut pick = |rng: &mut Rng| -> Vec<String> {
            for i in (1..pool.len()).rev() {
                pool.swap(i, rng.below(i as u64 + 1) as usize);
            }
            pool[..rng.below(9) as usize].to_vec()
        };
        let (a, b) = (pick(&mut rng), pick(&mut rng));
        check_diff(&a, &b, &diff_ids(&a, &b), "diff_ids");
        assert!(
            diff_ids(&a, &a).is_empty(),
            "diff against itself is not empty"
        );
    });
}
