#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::clone_on_ref_ptr,
    clippy::print_stdout,
    clippy::print_stderr,
    dead_code,
    missing_docs
)]
//! Core speed scenarios (`cargo bench -p swiftly-vm --bench core_speed`): the view models over a
//! scripted server with injected latency, once per network/runtime variant, so one run shows the
//! before (bare transport, one-thread runtime) next to the after (layer, multi-thread runtime).
//! Numbers are wall times (median of several runs) and counted requests / bytes on the "wire".

#[path = "../tests/common/mod.rs"]
mod common;

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::script::{Script, list, movie, param};
use common::{Manual, Net, account};
use swiftly_l10n::Locale;
use swiftly_library::{MemoryKeyValue, MemoryStore, ShelfSource};
use swiftly_net::{
    ErrorKind, HttpRequest, HttpResponse, HttpTransport, LayeredTransport, Priority,
    RequestOptions, Timer, scoped,
};
use swiftly_vm::{
    HomeIntent, HomePrefs, HomeVm, Host, LibraryIntent, LibrarySpec, LibraryStatus, LibraryVm,
    Spawner, Status,
};

// ---------------------------------------------------------------- rigging

/// Adds a fixed latency to every request and counts requests and body bytes.
struct Slow<T> {
    inner: Arc<T>,
    delay: Duration,
    wire: Arc<AtomicUsize>,
    bytes: Arc<AtomicUsize>,
}

impl<T: HttpTransport + 'static> HttpTransport for Slow<T> {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl Future<Output = Result<HttpResponse, ErrorKind>> + Send {
        let inner = Arc::clone(&self.inner);
        let (delay, wire, bytes) = (self.delay, Arc::clone(&self.wire), Arc::clone(&self.bytes));
        async move {
            wire.fetch_add(1, Ordering::SeqCst);
            tokio::time::sleep(delay).await;
            let answer = inner.send(request).await;
            if let Ok(a) = &answer {
                bytes.fetch_add(a.body.len(), Ordering::SeqCst);
            }
            answer
        }
    }
}

struct Tt;
impl Timer for Tt {
    fn sleep(&self, d: Duration) -> Pin<Box<dyn Future<Output = ()> + Send>> {
        Box::pin(tokio::time::sleep(d))
    }
}

/// Effects on a tokio runtime; `visible` runs them under `Priority::Visible` like `Core` does.
struct Tokio {
    handle: tokio::runtime::Handle,
    visible: bool,
}

impl Spawner for Tokio {
    fn spawn(&self, task: Pin<Box<dyn Future<Output = ()> + Send>>) {
        if self.visible {
            drop(self.handle.spawn(scoped(
                RequestOptions::with_priority(Priority::Visible),
                task,
            )));
        } else {
            drop(self.handle.spawn(task));
        }
    }
}

enum Rt {
    /// What `async-compat` gives today: one thread runs every task and timer.
    OneThread,
    /// An owned multi-thread runtime.
    Workers(usize),
}

struct Runtime {
    handle: tokio::runtime::Handle,
    _keep: Box<dyn std::any::Any>,
}

fn runtime(rt: &Rt) -> Runtime {
    match rt {
        Rt::OneThread => {
            let r = Arc::new(
                tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .unwrap(),
            );
            let handle = r.handle().clone();
            let (stop, rx) = tokio::sync::oneshot::channel::<()>();
            let rr = Arc::clone(&r);
            let t = std::thread::spawn(move || {
                rr.block_on(async move {
                    let _ = rx.await;
                })
            });
            Runtime {
                handle,
                _keep: Box::new((stop, t, r)),
            }
        }
        Rt::Workers(n) => {
            let r = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(*n)
                .enable_all()
                .build()
                .unwrap();
            Runtime {
                handle: r.handle().clone(),
                _keep: Box::new(r),
            }
        }
    }
}

fn host(spawner: Arc<dyn Spawner>) -> Host {
    Host {
        spawner,
        clock: Manual::at(1000.0),
        store: Arc::new(MemoryStore::new()),
        locale: Locale::parse("de"),
        device_name: "Bench".into(),
        client_version: "0.0.0".into(),
        cache: None,
    }
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(f64::total_cmp);
    v[v.len() / 2]
}

fn wait(mut done: impl FnMut() -> bool) {
    let t = Instant::now();
    while !done() {
        assert!(t.elapsed() < Duration::from_secs(30), "timeout");
        std::thread::sleep(Duration::from_micros(300));
    }
}

// ---------------------------------------------------------------- scenario A: Home remounted

/// `n` Home view models of one account load at once (tab switched back and forth quickly).
/// Returns (ms, requests on the wire, body bytes).
fn homes(n: usize, layered: bool, rt: &Runtime) -> (f64, usize, usize) {
    let net = Net::new(true);
    let (wire, bytes) = (Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0)));
    let slow = Slow {
        inner: net,
        delay: Duration::from_millis(30),
        wire: Arc::clone(&wire),
        bytes: Arc::clone(&bytes),
    };
    let spawner: Arc<dyn Spawner> = Arc::new(Tokio {
        handle: rt.handle.clone(),
        visible: layered,
    });
    let start = Instant::now();
    if layered {
        let t = Arc::new(LayeredTransport::new(slow, Arc::new(Tt)));
        run_homes(n, &t, &spawner);
    } else {
        run_homes(n, &Arc::new(slow), &spawner);
    }
    (
        start.elapsed().as_secs_f64() * 1000.0,
        wire.load(Ordering::SeqCst),
        bytes.load(Ordering::SeqCst),
    )
}

fn run_homes<T: HttpTransport + 'static>(n: usize, t: &Arc<T>, spawner: &Arc<dyn Spawner>) {
    let vms: Vec<_> = (0..n)
        .map(|_| {
            HomeVm::new(
                Arc::clone(t),
                host(Arc::clone(spawner)),
                HomePrefs::default(),
                Some(account("TOKEN-A")),
            )
            .unwrap()
        })
        .collect();
    for vm in &vms {
        vm.send(HomeIntent::Load);
    }
    wait(|| {
        vms.iter().all(|vm| {
            let s = vm.status();
            s.status == Status::Ready && !s.preview && !s.refreshing
        })
    });
}

// ---------------------------------------------------------------- scenario B: big libraries

const BIG: usize = 5000;

fn big_server() -> Arc<Script> {
    let all: Vec<_> = (0..BIG)
        .map(|n| {
            let mut m = movie(n);
            m["UserData"] = serde_json::json!({"Played": n % 10 == 0, "IsFavorite": n % 7 == 0});
            m["SortName"] = m["Name"].clone();
            m["DateCreated"] = "2024-05-01T10:00:00.0000000Z".into();
            m
        })
        .collect();
    let mut rev = all.clone();
    rev.reverse();
    let rev_json = list(&rev, BIG);
    let pages: Mutex<HashMap<(usize, usize), String>> = Mutex::new(HashMap::new());
    Script::new(move |r| {
        if !r.url.path().ends_with("/Items") {
            return Some("{}".into());
        }
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
            return Some(rev_json.clone());
        }
        let since: usize = param(r, "StartIndex")
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        let limit: usize = param(r, "Limit")
            .and_then(|v| v.parse().ok())
            .unwrap_or(100);
        let mut cache = pages.lock().unwrap();
        Some(
            cache
                .entry((since, limit))
                .or_insert_with(|| {
                    let page: Vec<_> = all.iter().skip(since).take(limit).cloned().collect();
                    list(&page, BIG)
                })
                .clone(),
        )
    })
}

/// `n` libraries of 5000 titles open at once (parse, natural sort, tile building, all on the
/// runtime). Returns ms.
fn libraries(n: usize, rt: &Runtime) -> f64 {
    let server = big_server();
    let (wire, bytes) = (Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0)));
    let slow = Arc::new(Slow {
        inner: server,
        delay: Duration::from_millis(10),
        wire,
        bytes,
    });
    let spawner: Arc<dyn Spawner> = Arc::new(Tokio {
        handle: rt.handle.clone(),
        visible: false,
    });
    let start = Instant::now();
    let vms: Vec<_> = (0..n)
        .map(|_| {
            let spec = LibrarySpec {
                source: ShelfSource::new(Some("lib1"), Some("movies"), false, &[]),
                genre: None,
                remember_name: None,
            };
            LibraryVm::new(
                Arc::clone(&slow),
                host(Arc::clone(&spawner)),
                Arc::new(MemoryKeyValue::new()),
                spec,
                Some(account("TOKEN-A")),
            )
            .unwrap()
        })
        .collect();
    for vm in &vms {
        vm.send(LibraryIntent::Load);
    }
    wait(|| {
        vms.iter()
            .all(|vm| vm.status().status == LibraryStatus::Ready)
    });
    start.elapsed().as_secs_f64() * 1000.0
}

// ------------------------------------------------ scenario C: first paint, cold versus warm cache

/// Milliseconds from `Load` until the first tile is in the grid. `cache` is shared between runs,
/// so the second visit of one account finds the first one's page.
fn first_paint(cache: Option<&swiftly_vm::ViewCache>, rt: &Runtime) -> f64 {
    let slow = Arc::new(Slow {
        inner: big_server(),
        delay: Duration::from_millis(30),
        wire: Arc::new(AtomicUsize::new(0)),
        bytes: Arc::new(AtomicUsize::new(0)),
    });
    let spawner: Arc<dyn Spawner> = Arc::new(Tokio {
        handle: rt.handle.clone(),
        visible: false,
    });
    let mut h = host(spawner);
    h.cache = cache.cloned();
    let spec = LibrarySpec {
        source: ShelfSource::new(Some("lib1"), Some("movies"), false, &[]),
        genre: None,
        remember_name: None,
    };
    let vm = LibraryVm::new(
        slow,
        h,
        Arc::new(MemoryKeyValue::new()),
        spec,
        Some(account("TOKEN-A")),
    )
    .unwrap();
    let start = Instant::now();
    vm.send(LibraryIntent::Load);
    wait(|| !vm.grid().tiles.is_empty());
    let ms = start.elapsed().as_secs_f64() * 1000.0;
    wait(|| vm.status().status == LibraryStatus::Ready);
    ms
}

fn main() {
    let runs = 7;
    println!("== A. Home x4 loaded at once, 30 ms latency per request ({runs} runs, median)");
    let one = runtime(&Rt::OneThread);
    for (name, layered) in [("bare transport", false), ("LayeredTransport", true)] {
        let r: Vec<_> = (0..runs).map(|_| homes(4, layered, &one)).collect();
        println!(
            "  {name:<18} {:>7.1} ms  wire requests {:>3}  body bytes {:>7}",
            median(r.iter().map(|x| x.0).collect()),
            r[0].1,
            r[0].2
        );
    }
    println!("== B. 4 libraries x {BIG} titles opened at once, 10 ms latency");
    for (name, rt) in [
        ("1 thread (today)", Rt::OneThread),
        ("2 workers", Rt::Workers(2)),
        ("3 workers", Rt::Workers(3)),
        ("4 workers", Rt::Workers(4)),
    ] {
        let rt = runtime(&rt);
        let r: Vec<_> = (0..runs).map(|_| libraries(4, &rt)).collect();
        println!("  {name:<18} {:>7.1} ms", median(r));
    }
    println!("== C. Library first paint (first tile in the grid), {BIG} titles, 30 ms latency");
    let rt = runtime(&Rt::Workers(4));
    let cold: Vec<_> = (0..runs).map(|_| first_paint(None, &rt)).collect();
    println!("  {:<24} {:>7.1} ms", "cold, no cache", median(cold));
    let mem = swiftly_vm::ViewCache::new(
        swiftly_cache::EntityCache::in_memory(swiftly_cache::CacheConfig::default()).unwrap(),
    );
    first_paint(Some(&mem), &rt);
    let warm: Vec<_> = (0..runs).map(|_| first_paint(Some(&mem), &rt)).collect();
    println!("  {:<24} {:>7.1} ms", "warm, memory cache", median(warm));
    let dir = std::env::temp_dir().join(format!("swiftly-bench-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("core-cache.sqlite");
    {
        let disk = swiftly_vm::ViewCache::new(
            swiftly_cache::EntityCache::open(&file, swiftly_cache::CacheConfig::default()).unwrap(),
        );
        first_paint(Some(&disk), &rt);
    }
    // A new launch: the database is opened again, the memory copy is empty.
    let warm: Vec<_> = (0..runs)
        .map(|_| {
            let disk = swiftly_vm::ViewCache::new(
                swiftly_cache::EntityCache::open(&file, swiftly_cache::CacheConfig::default())
                    .unwrap(),
            );
            first_paint(Some(&disk), &rt)
        })
        .collect();
    println!("  {:<24} {:>7.1} ms", "warm, after relaunch", median(warm));
    let _ = std::fs::remove_dir_all(&dir);
}
