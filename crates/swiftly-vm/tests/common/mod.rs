//! A scripted Jellyfin server for the view model tests: a transport that answers from the JSON
//! fixtures (the Swift tests serve the same files over a local socket), can be held back with a
//! gate and can be taken offline.
#![allow(
    dead_code,
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::clone_on_ref_ptr
)]

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};
use std::time::Duration;

use futures_executor::ThreadPool;
use swiftly_jellyfin::ServerKind;
use swiftly_l10n::Locale;
use swiftly_library::MemoryStore;
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport};
use swiftly_vm::{AccountRef, Clock, HomeVm, Host, Spawner, Status};

pub mod script;

pub const CATALOG: &str = include_str!("../fixtures/catalog.json");
pub const CATALOG_B: &str = include_str!("../fixtures/catalog_b.json");
pub const VIEWS: &str = include_str!("../fixtures/views.json");

/// Holds every request back until opened.
#[derive(Default)]
pub struct Gate {
    state: Mutex<(bool, Vec<Waker>)>,
}

impl Gate {
    pub fn open(&self) {
        let wakers = {
            let mut s = self.state.lock().unwrap();
            s.0 = true;
            std::mem::take(&mut s.1)
        };
        wakers.into_iter().for_each(Waker::wake);
    }
    pub fn close(&self) {
        self.state.lock().unwrap().0 = false;
    }
    pub fn wait(self: &Arc<Self>) -> Pin<Box<dyn Future<Output = ()> + Send>> {
        let gate = Arc::clone(self);
        Box::pin(std::future::poll_fn(move |cx: &mut Context<'_>| {
            let mut s = gate.state.lock().unwrap();
            if s.0 {
                Poll::Ready(())
            } else {
                s.1.push(cx.waker().clone());
                Poll::Pending
            }
        }))
    }
}

pub struct Net {
    pub gate: Arc<Gate>,
    pub offline: AtomicBool,
    /// Answer every request with this status and body instead (`401`: refused, `200` + junk: unreadable).
    pub force: Mutex<Option<(u16, String)>>,
    /// Serve 30 generated movies as the "recently added" list.
    pub many: AtomicBool,
    /// "r1" was watched to its end meanwhile: the server's continue list no longer has it.
    pub r1_finished: AtomicBool,
    pub seen: Mutex<Vec<HttpRequest>>,
}

impl Net {
    pub fn new(open: bool) -> Arc<Self> {
        let gate = Arc::new(Gate::default());
        if open {
            gate.open();
        }
        Arc::new(Self {
            gate,
            offline: AtomicBool::new(false),
            force: Mutex::new(None),
            many: AtomicBool::new(false),
            r1_finished: AtomicBool::new(false),
            seen: Mutex::new(Vec::new()),
        })
    }
    pub fn requests(&self) -> usize {
        self.seen.lock().unwrap().len()
    }
}

fn param(r: &HttpRequest, name: &str) -> Option<String> {
    r.url
        .query_pairs()
        .find(|(k, _)| k == name)
        .map(|(_, v)| v.into_owned())
}

fn items_of(catalog: &str, ids: &[&str]) -> Vec<serde_json::Value> {
    let all: serde_json::Value = serde_json::from_str(catalog).unwrap();
    let all = all["Items"].as_array().cloned().unwrap_or_default();
    ids.iter()
        .filter_map(|id| all.iter().find(|i| i["Id"] == *id).cloned())
        .collect()
}

fn list(items: &[serde_json::Value]) -> String {
    serde_json::json!({"Items": items, "TotalRecordCount": items.len()}).to_string()
}

impl Net {
    fn answer(&self, r: &HttpRequest) -> String {
        let auth = r.header("Authorization").unwrap_or_default();
        let b = auth.contains("TOKEN-B");
        let catalog = if b { CATALOG_B } else { CATALOG };
        let path = r.url.path();
        if path.ends_with("UserViews") {
            return VIEWS.to_owned();
        }
        if path.ends_with("UserItems/Resume") {
            let done = self.r1_finished.load(Ordering::SeqCst);
            return list(&items_of(
                catalog,
                if b {
                    &["x1"]
                } else if done {
                    &["e1"]
                } else {
                    &["r1", "e1"]
                },
            ));
        }
        if path.ends_with("Shows/NextUp") {
            return list(&items_of(catalog, if b { &[] } else { &["e1", "e2"] }));
        }
        if path.ends_with("/Items") {
            if let Some(ids) = param(r, "Ids") {
                let ids: Vec<&str> = ids.split(',').collect();
                let mut found = items_of(catalog, &ids);
                for id in ids.iter().filter(|id| id.starts_with('g')) {
                    found.push(
                        serde_json::json!({"Id": id, "Name": format!("Titel {id}"), "Type": "Movie",
                        "ImageTags": {"Primary": format!("p-{id}")}}),
                    );
                }
                return list(&found);
            }
            if self.many.load(Ordering::SeqCst) {
                let many: Vec<_> = (0..30)
                    .map(|n| serde_json::json!({"Id": format!("g{n}"), "Name": format!("Titel g{n}"), "Type": "Movie"}))
                    .collect();
                return list(&many);
            }
            return list(&items_of(
                catalog,
                if b { &["x2"] } else { &["m1", "m2", "m3"] },
            ));
        }
        "{}".to_owned()
    }
}

impl HttpTransport for Net {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl Future<Output = Result<HttpResponse, ErrorKind>> + Send {
        let reply = if self.offline.load(Ordering::SeqCst) {
            Err(ErrorKind::Network { code: -1009 })
        } else if let Some((status, body)) = self.force.lock().unwrap().clone() {
            Ok(HttpResponse::new(status, body))
        } else {
            Ok(HttpResponse::new(200, self.answer(&request)))
        };
        self.seen.lock().unwrap().push(request);
        let wait = self.gate.wait();
        async move {
            wait.await;
            reply
        }
    }
}

pub struct Pool(pub ThreadPool);

impl Spawner for Pool {
    fn spawn(&self, task: Pin<Box<dyn Future<Output = ()> + Send>>) {
        self.0.spawn_ok(task);
    }
}

/// A clock the test moves.
pub struct Manual(AtomicU64);

impl Manual {
    pub fn at(seconds: f64) -> Arc<Self> {
        Arc::new(Self(AtomicU64::new(seconds.to_bits())))
    }
    pub fn set(&self, seconds: f64) {
        self.0.store(seconds.to_bits(), Ordering::SeqCst);
    }
}

impl Clock for Manual {
    fn now(&self) -> f64 {
        f64::from_bits(self.0.load(Ordering::SeqCst))
    }
}

pub fn account(token: &str) -> AccountRef {
    AccountRef {
        base_url: "https://tv.example.test".into(),
        user_id: format!("user-{}", token.to_lowercase()),
        token: token.into(),
        server_kind: ServerKind::Jellyfin,
        device_id: "device-1".into(),
        plex_machine_id: None,
        plex_account_token: None,
    }
}

pub struct Rig {
    pub net: Arc<Net>,
    pub clock: Arc<Manual>,
    pub store: Arc<MemoryStore>,
    pub vm: HomeVm<Net>,
}

pub fn pool() -> ThreadPool {
    ThreadPool::builder().pool_size(2).create().unwrap()
}

/// A view model over a scripted server. `store` is shared between rigs to carry a snapshot over.
pub fn rig(net: Arc<Net>, store: Arc<MemoryStore>, locale: &str, token: Option<&str>) -> Rig {
    rig_with(net, store, locale, token, swiftly_vm::HomePrefs::default())
}

/// The same with the Start page settings given.
pub fn rig_with(
    net: Arc<Net>,
    store: Arc<MemoryStore>,
    locale: &str,
    token: Option<&str>,
    prefs: swiftly_vm::HomePrefs,
) -> Rig {
    let clock = Manual::at(1000.0);
    let host = Host {
        spawner: Arc::new(Pool(pool())),
        clock: clock.clone(),
        store: store.clone(),
        locale: Locale::parse(locale),
        device_name: "Test".into(),
        client_version: "0.0.0".into(),
        cache: None,
    };
    let vm = HomeVm::new(net.clone(), host, prefs, token.map(account)).unwrap();
    Rig {
        net,
        clock,
        store,
        vm,
    }
}

/// Polls until `done` (a few seconds at most).
pub fn until(vm: &HomeVm<Net>, what: &str, done: impl Fn(&HomeVm<Net>) -> bool) {
    // A wall-clock bound (a loaded machine starves the worker threads); it is never slept in full.
    let end = std::time::Instant::now() + Duration::from_secs(30);
    while std::time::Instant::now() < end {
        if done(vm) {
            return;
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    panic!("timed out waiting for {what}; status {:?}", vm.status());
}

pub fn ready(vm: &HomeVm<Net>) -> bool {
    let s = vm.status();
    s.status == Status::Ready && !s.preview && !s.refreshing
}
