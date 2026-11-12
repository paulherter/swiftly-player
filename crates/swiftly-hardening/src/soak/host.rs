//! Host implementations of the core's foreign traits, all behind one [`Control`]: it counts every
//! callback and can make the next call of a named callback block for a while. That is the probe of
//! the watchdog: while a foreign callback blocks, nothing else in the core may be held up by it.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use swiftly_net::{HttpRequest, HttpTransport, Method, ReqwestTransport, TransportConfig, Url};
use swiftly_uniffi::{
    HttpClient, HttpFailure, KeyValueStore, NetHeader, NetMethod, NetRequest, NetResponse,
    Platform, SecretStore,
};

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

#[derive(Default)]
pub struct Control {
    armed: Mutex<Option<String>>,
    blocking: Mutex<Option<String>>,
    last_fire: Mutex<Option<std::time::Instant>>,
    fired: AtomicBool,
    pub block_ms: AtomicU64,
    calls: Mutex<BTreeMap<String, u64>>,
    offline: Mutex<BTreeSet<String>>,
}

impl Control {
    pub fn new() -> Arc<Self> {
        let c = Self::default();
        c.block_ms.store(200, Ordering::SeqCst);
        Arc::new(c)
    }

    /// The next call of `name` blocks for `block_ms`.
    pub fn arm(&self, name: &str) {
        self.fired.store(false, Ordering::SeqCst);
        *lock(&self.armed) = Some(name.to_owned());
    }

    pub fn disarm(&self) {
        *lock(&self.armed) = None;
    }

    pub fn fired(&self) -> bool {
        self.fired.load(Ordering::SeqCst)
    }

    /// The callback that blocks right now, if any.
    pub fn blocking(&self) -> Option<String> {
        lock(&self.blocking).clone()
    }

    /// When the armed callback last began to block (kept after it returns).
    pub fn last_fire(&self) -> Option<std::time::Instant> {
        *lock(&self.last_fire)
    }

    /// Requests that carry this token fail like a lost connection until `set_offline(token, false)`.
    pub fn set_offline(&self, token: &str, offline: bool) {
        let mut set = lock(&self.offline);
        if offline {
            set.insert(token.to_owned());
        } else {
            set.remove(token);
        }
    }

    fn is_offline(&self, headers: &[NetHeader]) -> bool {
        let set = lock(&self.offline);
        !set.is_empty()
            && headers
                .iter()
                .any(|h| set.iter().any(|t| h.value.contains(t.as_str())))
    }

    pub fn calls(&self) -> BTreeMap<String, u64> {
        lock(&self.calls).clone()
    }

    fn enter(&self, name: &str) -> Option<Duration> {
        *lock(&self.calls).entry(name.to_owned()).or_insert(0) += 1;
        let mut armed = lock(&self.armed);
        if armed.as_deref() == Some(name) {
            *armed = None;
            *lock(&self.last_fire) = Some(std::time::Instant::now());
            *lock(&self.blocking) = Some(name.to_owned());
            self.fired.store(true, Ordering::SeqCst);
            return Some(Duration::from_millis(self.block_ms.load(Ordering::SeqCst)));
        }
        None
    }

    fn leave(&self) {
        *lock(&self.blocking) = None;
    }

    /// A synchronous callback: blocks the calling thread when armed.
    pub fn hit(&self, name: &str) {
        if let Some(d) = self.enter(name) {
            std::thread::sleep(d);
            self.leave();
        }
    }

    /// An asynchronous callback: waits (without blocking a thread) when armed.
    pub async fn hit_async(&self, name: &str) {
        if let Some(d) = self.enter(name) {
            tokio::time::sleep(d).await;
            self.leave();
        }
    }
}

pub struct SoakPlatform(pub Arc<Control>);

impl Platform for SoakPlatform {
    fn device_name(&self) -> String {
        self.0.hit("platform.device_name");
        "soak-rig".to_owned()
    }
    fn log(&self, _line: String) {
        self.0.hit("platform.log");
    }
    fn cache_dir(&self) -> Option<String> {
        self.0.hit("platform.cache_dir");
        None
    }
}

pub struct SoakSecrets(pub Arc<Control>, Mutex<BTreeMap<String, String>>);

impl SoakSecrets {
    pub fn new(ctl: Arc<Control>) -> Self {
        Self(ctl, Mutex::default())
    }
}

impl SecretStore for SoakSecrets {
    fn get(&self, name: String) -> Option<String> {
        self.0.hit("secret.get");
        lock(&self.1).get(&name).cloned()
    }
    fn set(&self, name: String, value: String) {
        self.0.hit("secret.set");
        lock(&self.1).insert(name, value);
    }
    fn remove(&self, name: String) {
        self.0.hit("secret.remove");
        lock(&self.1).remove(&name);
    }
}

pub struct SoakKv(pub Arc<Control>, Mutex<BTreeMap<String, Vec<u8>>>);

impl SoakKv {
    pub fn new(ctl: Arc<Control>) -> Self {
        Self(ctl, Mutex::default())
    }
}

impl KeyValueStore for SoakKv {
    fn get(&self, key: String) -> Option<Vec<u8>> {
        self.0.hit("kv.get");
        lock(&self.1).get(&key).cloned()
    }
    fn set(&self, key: String, value: Vec<u8>) {
        self.0.hit("kv.set");
        lock(&self.1).insert(key, value);
    }
    fn remove(&self, key: String) {
        self.0.hit("kv.remove");
        lock(&self.1).remove(&key);
    }
}

/// reqwest on its own network runtime (the core's runtime has no IO driver, as on Apple where URLSession does the
/// network); one shared single-worker runtime for the whole process.
fn network() -> &'static tokio::runtime::Handle {
    static NET: std::sync::OnceLock<tokio::runtime::Runtime> = std::sync::OnceLock::new();
    NET.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .thread_name("soak-net")
            .enable_all()
            .build()
            .expect("network runtime")
    })
    .handle()
}

/// A transport whose idle connections close quickly: a pooled keep-alive connection is a live task until its idle timeout
/// (15 s in production), which would look like a leak right after the last session ends.
pub fn soak_transport() -> ReqwestTransport {
    let config = TransportConfig {
        pool_idle_timeout: Duration::from_millis(300),
        ..TransportConfig::default()
    };
    ReqwestTransport::with_config(config).expect("transport")
}

/// The host HTTP client of the core in the soak runs (stands in for URLSession).
pub struct SoakHttp(pub Arc<Control>, Arc<ReqwestTransport>);

impl SoakHttp {
    pub fn new(ctl: Arc<Control>) -> Self {
        Self(ctl, Arc::new(soak_transport()))
    }
}

#[async_trait::async_trait]
impl HttpClient for SoakHttp {
    async fn send(&self, request: NetRequest) -> Result<NetResponse, HttpFailure> {
        self.0.hit_async("http.send").await;
        if self.0.is_offline(&request.headers) {
            return Err(HttpFailure::Network { code: -1009 });
        }
        let url = Url::parse(&request.url).map_err(|e| HttpFailure::Other {
            message: e.to_string(),
        })?;
        let mut req = HttpRequest::new(
            match request.method {
                NetMethod::Get => Method::Get,
                NetMethod::Post => Method::Post,
                NetMethod::Put => Method::Put,
                NetMethod::Delete => Method::Delete,
            },
            url,
        );
        req.headers = request
            .headers
            .into_iter()
            .map(|h| (h.name, h.value))
            .collect();
        req.body = request.body;
        let transport = Arc::clone(&self.1);
        let answer = network()
            .spawn(async move { transport.send(req).await })
            .await
            .map_err(|_| HttpFailure::Network { code: -1004 })?
            .map_err(|_| HttpFailure::Network { code: -1004 })?;
        Ok(NetResponse {
            status: answer.status,
            headers: answer
                .headers
                .into_iter()
                .map(|(name, value)| NetHeader { name, value })
                .collect(),
            body: answer.body,
            url: answer.url.map(|u| u.to_string()),
        })
    }
}
