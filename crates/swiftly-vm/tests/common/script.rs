//! A scripted server for the library and search tests: a closure answers every request.
#![allow(dead_code, clippy::unwrap_used, clippy::clone_on_ref_ptr)]

use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use swiftly_l10n::Locale;
use swiftly_library::MemoryStore;
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport};
use swiftly_vm::{Host, Sleeper};

use super::{Gate, Manual, Pool, pool};

type Handler = Box<dyn Fn(&HttpRequest) -> Option<String> + Send + Sync>;

pub struct Script {
    handler: Handler,
    pub offline: AtomicBool,
    /// Answer every request with this status and body instead (`401`: refused, `200` + junk: unreadable).
    pub force: Mutex<Option<(u16, String)>>,
    pub gate: Arc<Gate>,
    pub seen: Mutex<Vec<HttpRequest>>,
}

impl Script {
    pub fn new(
        handler: impl Fn(&HttpRequest) -> Option<String> + Send + Sync + 'static,
    ) -> Arc<Self> {
        let gate = Arc::new(Gate::default());
        gate.open();
        Arc::new(Self {
            handler: Box::new(handler),
            offline: AtomicBool::new(false),
            force: Mutex::new(None),
            gate,
            seen: Mutex::new(Vec::new()),
        })
    }
    /// The URLs requested so far.
    pub fn urls(&self) -> Vec<String> {
        self.seen
            .lock()
            .unwrap()
            .iter()
            .map(|r| r.url.to_string())
            .collect()
    }
    pub fn count(&self, needle: &str) -> usize {
        self.urls().iter().filter(|u| u.contains(needle)).count()
    }
}

impl HttpTransport for Script {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl Future<Output = Result<HttpResponse, ErrorKind>> + Send {
        let reply = if self.offline.load(Ordering::SeqCst) {
            Err(ErrorKind::Network { code: -1009 })
        } else if let Some((status, body)) = self.force.lock().unwrap().clone() {
            Ok(HttpResponse::new(status, body))
        } else {
            match (self.handler)(&request) {
                Some(body) => Ok(HttpResponse::new(200, body)),
                None => Ok(HttpResponse::new(500, "{}")),
            }
        };
        self.seen.lock().unwrap().push(request);
        let wait = self.gate.wait();
        async move {
            wait.await;
            reply
        }
    }
}

pub fn param(r: &HttpRequest, name: &str) -> Option<String> {
    r.url
        .query_pairs()
        .find(|(k, _)| k == name)
        .map(|(_, v)| v.into_owned())
}

pub fn list(items: &[serde_json::Value], total: usize) -> String {
    serde_json::json!({"Items": items, "TotalRecordCount": total}).to_string()
}

pub fn movie(n: usize) -> serde_json::Value {
    serde_json::json!({"Id": format!("m{n}"), "Name": format!("Titel {n:03}"), "Type": "Movie",
        "ProductionYear": 2000 + n % 20, "ImageTags": {"Primary": format!("p{n}")}})
}

/// Sleeps until the gate opens.
pub struct GateSleeper(pub Arc<Gate>);

impl Sleeper for GateSleeper {
    fn sleep(&self, _seconds: f64) -> std::pin::Pin<Box<dyn Future<Output = ()> + Send>> {
        self.0.wait()
    }
}

pub fn host() -> Host {
    Host {
        spawner: Arc::new(Pool(pool())),
        clock: Manual::at(1000.0),
        store: Arc::new(MemoryStore::new()),
        locale: Locale::parse("de"),
        device_name: "Test".into(),
        client_version: "0.0.0".into(),
        cache: None,
    }
}

/// Polls until `done` (a few seconds at most).
pub fn wait_for(what: &str, done: impl Fn() -> bool) {
    // A wall-clock bound (a loaded machine starves the worker threads); it is never slept in full.
    let end = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while std::time::Instant::now() < end {
        if done() {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
    panic!("timed out waiting for {what}");
}
