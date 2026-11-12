//! The shared request layer: [`LayeredTransport`] wraps any [`HttpTransport`] and is one itself,
//! so every client and view model gets it by being handed the wrapper instead of the bare
//! transport.
//!
//! What it does, for every request:
//!
//! * **Dedup.** Identical in-flight GETs (same address, same headers, so the same account) share
//!   one network call; every caller gets its own copy of the answer.
//! * **Cancellation that stops work.** A caller that drops its future leaves the flight; when the
//!   last one has left, the underlying future is dropped, which closes the connection (reqwest)
//!   or cancels the task (a platform stack that cancels on drop). A flight with a waiting caller
//!   keeps running even if the caller that started it is gone.
//! * **Priorities.** [`Priority::Visible`] before [`Priority::Normal`] before [`Priority::Prefetch`]
//!   before [`Priority::Background`], decided when a connection slot frees up. Prefetch and
//!   background work can never take the last `visible_reserve` slots of a host. A caller that
//!   joins a flight with a higher priority lifts the flight.
//! * **Per-host concurrency limit** (`max_per_host`).
//! * **Retry with jitter** for GET only: transient network failures and 408/429/502/503/504,
//!   `Retry-After` honoured (capped), exponential backoff with jitter.
//! * **Total deadline** per request including retries.
//! * **Conditional requests.** A GET whose earlier answer carried `ETag`/`Last-Modified` is sent
//!   with `If-None-Match`/`If-Modified-Since`; a 304 is turned back into the stored 200. Servers
//!   that never send validators (most Jellyfin JSON) are never asked conditionally.
//! * **Metrics hooks** ([`NetMetrics`]).
//!
//! **Compression.** The layer never sets `Accept-Encoding`: reqwest negotiates gzip/deflate/brotli
//! and decodes by itself, and a platform stack (URLSession, OkHttp) does the same. Setting the
//! header by hand would switch the automatic decoding off on those stacks.
//!
//! **Priority from a view model.** Wrap the future that calls the client in [`scoped`]; the
//! options are read when the client calls `send`, so they reach every request made inside.

use std::cell::Cell;
use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU8, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::task::{Context, Poll, Waker};
use std::time::{Duration, Instant};

use futures_util::future::{Either, FutureExt, Shared, WeakShared, select};

use crate::{ErrorKind, HttpRequest, HttpResponse, HttpTransport, Method, url_error};

type Answer = Result<HttpResponse, ErrorKind>;
type BoxFuture<T> = Pin<Box<dyn Future<Output = T> + Send>>;
type Flight = Shared<BoxFuture<Answer>>;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// How urgent a request is. Higher goes first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub enum Priority {
    /// Nobody waits for it (cache warming, sync).
    Background = 0,
    /// A guess about what the user opens next.
    Prefetch = 1,
    /// An ordinary request.
    #[default]
    Normal = 2,
    /// Something on screen is waiting for it.
    Visible = 3,
}

impl Priority {
    fn from_u8(v: u8) -> Self {
        match v {
            0 => Self::Background,
            1 => Self::Prefetch,
            3 => Self::Visible,
            _ => Self::Normal,
        }
    }
}

/// Per-request switches, set with [`scoped`] or [`LayeredTransport::send_with`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RequestOptions {
    /// Urgency.
    pub priority: Priority,
    /// Share the call with identical in-flight GETs.
    pub dedup: bool,
    /// Retry a transient failure (GET only).
    pub retry: bool,
    /// Use `If-None-Match`/`If-Modified-Since` when a validator is known (GET only).
    pub conditional: bool,
}

impl Default for RequestOptions {
    fn default() -> Self {
        Self {
            priority: Priority::Normal,
            dedup: true,
            retry: true,
            conditional: true,
        }
    }
}

impl RequestOptions {
    /// Defaults with another priority.
    pub fn with_priority(priority: Priority) -> Self {
        Self {
            priority,
            ..Self::default()
        }
    }
}

thread_local! {
    static AMBIENT: Cell<Option<RequestOptions>> = const { Cell::new(None) };
}

/// The future returned by [`scoped`].
pub struct Scoped<F> {
    options: RequestOptions,
    inner: Pin<Box<F>>,
}

impl<F: Future> Future for Scoped<F> {
    type Output = F::Output;
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<F::Output> {
        let options = self.options;
        let previous = AMBIENT.with(|a| a.replace(Some(options)));
        let out = self.inner.as_mut().poll(cx);
        AMBIENT.with(|a| a.set(previous));
        out
    }
}

/// Runs `future` so that every request it sends through a [`LayeredTransport`] uses `options`.
pub fn scoped<F: Future>(options: RequestOptions, future: F) -> Scoped<F> {
    Scoped {
        options,
        inner: Box::pin(future),
    }
}

/// Sleeps without blocking; the layer needs it for retry delays and the deadline.
pub trait Timer: Send + Sync {
    /// Resolves after `duration`.
    fn sleep(&self, duration: Duration) -> BoxFuture<()>;
}

/// [`Timer`] on tokio's clock (needs a tokio runtime).
#[cfg(feature = "reqwest")]
#[derive(Debug, Clone, Copy, Default)]
pub struct TokioTimer;

#[cfg(feature = "reqwest")]
impl Timer for TokioTimer {
    fn sleep(&self, duration: Duration) -> BoxFuture<()> {
        Box::pin(tokio::time::sleep(duration))
    }
}

/// What happened to a request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetEventKind {
    /// Answered (any status) after `attempts` tries.
    Completed,
    /// Ended with an error.
    Failed,
    /// Joined a flight that was already running; no new network call.
    Joined,
    /// A try failed and another one follows.
    Retried,
    /// A conditional request got 304 and the stored answer was used.
    NotModified,
    /// The last caller left; the network call was dropped.
    Cancelled,
}

/// One metrics event.
#[derive(Debug, Clone)]
pub struct NetEvent {
    /// What happened.
    pub kind: NetEventKind,
    /// `host:port`.
    pub host: String,
    /// Path without the query (no secrets).
    pub path: String,
    /// Priority of the request.
    pub priority: Priority,
    /// Time since the flight started.
    pub elapsed: Duration,
    /// Time spent waiting for a connection slot (completed events).
    pub queued: Duration,
    /// Status, if there was an answer.
    pub status: Option<u16>,
    /// Body size, if there was an answer.
    pub bytes: usize,
    /// Number of tries so far.
    pub attempts: u32,
}

/// Receives [`NetEvent`]s. Must be quick and must not block.
pub trait NetMetrics: Send + Sync {
    /// One event.
    fn event(&self, event: &NetEvent);
}

/// Atomic counters, a ready [`NetMetrics`].
#[derive(Debug, Default)]
pub struct NetCounters {
    /// Network calls that ended with an answer.
    pub completed: AtomicU64,
    /// Network calls that ended with an error.
    pub failed: AtomicU64,
    /// Callers that shared a running call.
    pub joined: AtomicU64,
    /// Retries done.
    pub retried: AtomicU64,
    /// 304 answers.
    pub not_modified: AtomicU64,
    /// Calls dropped because nobody waited any more.
    pub cancelled: AtomicU64,
}

impl NetMetrics for NetCounters {
    fn event(&self, event: &NetEvent) {
        let c = match event.kind {
            NetEventKind::Completed => &self.completed,
            NetEventKind::Failed => &self.failed,
            NetEventKind::Joined => &self.joined,
            NetEventKind::Retried => &self.retried,
            NetEventKind::NotModified => &self.not_modified,
            NetEventKind::Cancelled => &self.cancelled,
        };
        c.fetch_add(1, Ordering::Relaxed);
    }
}

/// Tuning of the layer.
#[derive(Debug, Clone)]
pub struct LayerConfig {
    /// Most requests on the wire per `host:port`.
    pub max_per_host: usize,
    /// Slots of a host that prefetch and background work may not take.
    pub visible_reserve: usize,
    /// Retries after the first try (GET only).
    pub max_retries: u32,
    /// First retry delay before jitter.
    pub retry_base: Duration,
    /// Longest `Retry-After` honoured.
    pub retry_after_cap: Duration,
    /// Whole-request deadline, retries included.
    pub deadline: Duration,
    /// Bytes of answers kept for conditional requests (0 turns them off).
    pub validator_budget: usize,
}

impl Default for LayerConfig {
    fn default() -> Self {
        Self {
            max_per_host: 8,
            visible_reserve: 2,
            max_retries: 2,
            retry_base: Duration::from_millis(200),
            retry_after_cap: Duration::from_secs(5),
            deadline: Duration::from_secs(40),
            validator_budget: 8 * 1024 * 1024,
        }
    }
}

// ---------------------------------------------------------------- the gate

struct Waiter {
    id: u64,
    priority: Arc<AtomicU8>,
    seq: u64,
    waker: Option<Waker>,
    granted: bool,
}

struct GateState {
    in_use: usize,
    next: u64,
    waiters: Vec<Waiter>,
}

/// Per-host slot queue: priority first, then arrival order.
struct Gate {
    limit: usize,
    reserve: usize,
    state: Mutex<GateState>,
}

impl Gate {
    fn new(limit: usize, reserve: usize) -> Arc<Self> {
        let limit = limit.max(1);
        Arc::new(Self {
            limit,
            reserve: reserve.min(limit - 1),
            state: Mutex::new(GateState {
                in_use: 0,
                next: 0,
                waiters: Vec::new(),
            }),
        })
    }

    fn allowed(&self, priority: Priority, in_use: usize) -> bool {
        in_use < self.limit && (priority >= Priority::Normal || in_use + self.reserve < self.limit)
    }

    /// Hands free slots to the best waiters; returns the wakers to call after unlocking.
    fn regrant(&self, st: &mut GateState) -> Vec<Waker> {
        let mut wake = Vec::new();
        loop {
            let pick = st
                .waiters
                .iter()
                .enumerate()
                .filter(|(_, w)| !w.granted)
                .filter(|(_, w)| {
                    self.allowed(
                        Priority::from_u8(w.priority.load(Ordering::Relaxed)),
                        st.in_use,
                    )
                })
                .max_by_key(|(_, w)| (w.priority.load(Ordering::Relaxed), std::cmp::Reverse(w.seq)))
                .map(|(i, _)| i);
            let Some(i) = pick else { break };
            st.in_use += 1;
            st.waiters[i].granted = true;
            if let Some(w) = st.waiters[i].waker.take() {
                wake.push(w);
            }
        }
        wake
    }

    fn acquire(self: &Arc<Self>, priority: Arc<AtomicU8>) -> Acquire {
        Acquire {
            gate: Arc::clone(self),
            id: None,
            priority,
        }
    }

    fn release(&self) {
        let wake = {
            let mut st = lock(&self.state);
            st.in_use = st.in_use.saturating_sub(1);
            self.regrant(&mut st)
        };
        wake.into_iter().for_each(Waker::wake);
    }
}

struct Acquire {
    gate: Arc<Gate>,
    id: Option<u64>,
    priority: Arc<AtomicU8>,
}

struct Permit(Arc<Gate>);

impl Drop for Permit {
    fn drop(&mut self) {
        self.0.release();
    }
}

impl Future for Acquire {
    type Output = Permit;
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Permit> {
        let gate = Arc::clone(&self.gate);
        let mut st = lock(&gate.state);
        match self.id {
            None => {
                let p = Priority::from_u8(self.priority.load(Ordering::Relaxed));
                let nobody_better = !st.waiters.iter().any(|w| !w.granted);
                if nobody_better && gate.allowed(p, st.in_use) {
                    st.in_use += 1;
                    return Poll::Ready(Permit(Arc::clone(&gate)));
                }
                let id = st.next;
                st.next += 1;
                st.waiters.push(Waiter {
                    id,
                    priority: Arc::clone(&self.priority),
                    seq: id,
                    waker: Some(cx.waker().clone()),
                    granted: false,
                });
                self.id = Some(id);
                // A slot may be free for this one while only lower classes queue; settle now.
                let wake = gate.regrant(&mut st);
                drop(st);
                wake.into_iter().for_each(Waker::wake);
                Poll::Pending
            }
            Some(id) => {
                let Some(pos) = st.waiters.iter().position(|w| w.id == id) else {
                    return Poll::Pending;
                };
                if st.waiters[pos].granted {
                    st.waiters.remove(pos);
                    self.id = None;
                    return Poll::Ready(Permit(Arc::clone(&gate)));
                }
                st.waiters[pos].waker = Some(cx.waker().clone());
                Poll::Pending
            }
        }
    }
}

impl Drop for Acquire {
    fn drop(&mut self) {
        let Some(id) = self.id else { return };
        let wake = {
            let mut st = lock(&self.gate.state);
            let Some(pos) = st.waiters.iter().position(|w| w.id == id) else {
                return;
            };
            let w = st.waiters.remove(pos);
            if w.granted {
                st.in_use = st.in_use.saturating_sub(1);
            }
            self.gate.regrant(&mut st)
        };
        wake.into_iter().for_each(Waker::wake);
    }
}

// ------------------------------------------------------------ validators

struct Validated {
    etag: Option<String>,
    last_modified: Option<String>,
    response: HttpResponse,
    stamp: u64,
}

#[derive(Default)]
struct Validators {
    map: HashMap<String, Validated>,
    bytes: usize,
    clock: u64,
}

impl Validators {
    fn store(&mut self, key: String, v: Validated, budget: usize) {
        let size = v.response.body.len();
        if size > budget / 4 {
            return;
        }
        if let Some(old) = self.map.insert(key, v) {
            self.bytes -= old.response.body.len();
        }
        self.bytes += size;
        while self.bytes > budget {
            let Some(oldest) = self
                .map
                .iter()
                .min_by_key(|(_, v)| v.stamp)
                .map(|(k, _)| k.clone())
            else {
                break;
            };
            if let Some(old) = self.map.remove(&oldest) {
                self.bytes -= old.response.body.len();
            }
        }
    }
}

// ------------------------------------------------------------- the layer

struct FlightEntry {
    id: u64,
    weak: WeakShared<BoxFuture<Answer>>,
    priority: Arc<AtomicU8>,
}

struct Core {
    config: LayerConfig,
    timer: Arc<dyn Timer>,
    metrics: Mutex<Option<Arc<dyn NetMetrics>>>,
    flights: Mutex<HashMap<String, FlightEntry>>,
    gates: Mutex<HashMap<String, Arc<Gate>>>,
    validators: Mutex<Validators>,
    flight_ids: AtomicU64,
    jitter: AtomicU64,
}

impl Core {
    fn emit(&self, event: NetEvent) {
        let m = lock(&self.metrics).clone();
        if let Some(m) = m {
            m.event(&event);
        }
    }

    fn gate(&self, host: &str) -> Arc<Gate> {
        let mut gates = lock(&self.gates);
        Arc::clone(
            gates.entry(host.to_string()).or_insert_with(|| {
                Gate::new(self.config.max_per_host, self.config.visible_reserve)
            }),
        )
    }

    /// A number in `[lo, hi]` from a xorshift stream; spreads retries, needs no crate.
    fn jittered(&self, base: Duration) -> Duration {
        let mut x = self.jitter.load(Ordering::Relaxed);
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.jitter.store(x, Ordering::Relaxed);
        let half = base / 2;
        let spread = base.as_millis().saturating_sub(half.as_millis()) as u64 + 1;
        half + Duration::from_millis(x % spread)
    }
}

/// An [`HttpTransport`] with dedup, priorities, limits, retry, conditional requests, deadlines
/// and metrics around another one. Cheap to clone.
pub struct LayeredTransport<T> {
    inner: Arc<T>,
    core: Arc<Core>,
}

impl<T> Clone for LayeredTransport<T> {
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
            core: Arc::clone(&self.core),
        }
    }
}

impl<T: HttpTransport + 'static> LayeredTransport<T> {
    /// Wraps `inner`.
    pub fn new(inner: T, timer: Arc<dyn Timer>) -> Self {
        Self::with_config(inner, timer, LayerConfig::default())
    }

    /// Wraps `inner` with its own tuning.
    pub fn with_config(inner: T, timer: Arc<dyn Timer>, config: LayerConfig) -> Self {
        let seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0x9E37_79B9_7F4A_7C15, |d| d.as_nanos() as u64)
            | 1;
        Self {
            inner: Arc::new(inner),
            core: Arc::new(Core {
                config,
                timer,
                metrics: Mutex::new(None),
                flights: Mutex::new(HashMap::new()),
                gates: Mutex::new(HashMap::new()),
                validators: Mutex::new(Validators::default()),
                flight_ids: AtomicU64::new(1),
                jitter: AtomicU64::new(seed),
            }),
        }
    }

    /// Installs the metrics hook.
    pub fn set_metrics(&self, metrics: Arc<dyn NetMetrics>) {
        *lock(&self.core.metrics) = Some(metrics);
    }

    /// The wrapped transport.
    pub fn inner(&self) -> &T {
        &self.inner
    }

    /// Sends with explicit options (the ambient ones of [`scoped`] are ignored).
    pub fn send_with(
        &self,
        request: HttpRequest,
        options: RequestOptions,
    ) -> impl Future<Output = Answer> + Send + use<T> {
        self.start(request, options)
    }

    fn start(
        &self,
        request: HttpRequest,
        options: RequestOptions,
    ) -> impl Future<Output = Answer> + Send + use<T> {
        let idempotent = matches!(request.method, Method::Get);
        let host = host_of(&request);
        let key = idempotent.then(|| flight_key(&request));
        let core = Arc::clone(&self.core);
        let inner = Arc::clone(&self.inner);
        let prio_value = options.priority as u8;
        // Join a running flight or start one, synchronously, so two calls made back to back
        // in the same poll already share (a later `await` would let both start).
        let flight: Flight = if let (true, Some(key)) = (options.dedup && idempotent, key.as_ref())
        {
            let mut flights = lock(&core.flights);
            let joined = flights
                .get(key)
                .and_then(|e| e.weak.upgrade().map(|f| (f, Arc::clone(&e.priority))));
            if let Some((f, p)) = joined {
                p.fetch_max(prio_value, Ordering::Relaxed);
                drop(flights);
                core.emit(event(
                    NetEventKind::Joined,
                    &request,
                    &host,
                    options.priority,
                ));
                f
            } else {
                let id = core.flight_ids.fetch_add(1, Ordering::Relaxed);
                let priority = Arc::new(AtomicU8::new(prio_value));
                let guard = FlightGuard {
                    core: Arc::clone(&core),
                    key: Some(key.clone()),
                    id,
                    host: host.clone(),
                    request: request.clone(),
                    priority: Arc::clone(&priority),
                    started: Instant::now(),
                    done: false,
                };
                let f = run(
                    Arc::clone(&core),
                    inner,
                    request,
                    host,
                    options,
                    Arc::clone(&priority),
                    Some(guard),
                )
                .boxed()
                .shared();
                if let Some(weak) = f.downgrade() {
                    flights.insert(key.clone(), FlightEntry { id, weak, priority });
                }
                f
            }
        } else {
            let priority = Arc::new(AtomicU8::new(prio_value));
            run(core, inner, request, host, options, priority, None)
                .boxed()
                .shared()
        };
        flight
    }
}

impl<T: HttpTransport + 'static> HttpTransport for LayeredTransport<T> {
    fn send(&self, request: HttpRequest) -> impl Future<Output = Answer> + Send {
        let options = AMBIENT.with(Cell::get).unwrap_or_default();
        self.start(request, options)
    }
}

fn host_of(request: &HttpRequest) -> String {
    let u = &request.url;
    format!(
        "{}:{}",
        u.host_str().unwrap_or(""),
        u.port_or_known_default().unwrap_or(0)
    )
}

/// Same address and same headers (so the same account and language) are one flight.
fn flight_key(request: &HttpRequest) -> String {
    let mut headers: Vec<String> = request
        .headers
        .iter()
        .map(|(n, v)| format!("{}:{v}", n.to_ascii_lowercase()))
        .collect();
    headers.sort();
    format!(
        "{} {}\n{}",
        request.method.as_str(),
        request.url,
        headers.join("\n")
    )
}

fn event(kind: NetEventKind, request: &HttpRequest, host: &str, priority: Priority) -> NetEvent {
    NetEvent {
        kind,
        host: host.to_string(),
        path: request.url.path().to_string(),
        priority,
        elapsed: Duration::ZERO,
        queued: Duration::ZERO,
        status: None,
        bytes: 0,
        attempts: 0,
    }
}

/// Removes the flight from the table when its future ends or is dropped; reports a cancel.
struct FlightGuard {
    core: Arc<Core>,
    key: Option<String>,
    id: u64,
    host: String,
    request: HttpRequest,
    priority: Arc<AtomicU8>,
    started: Instant,
    done: bool,
}

impl Drop for FlightGuard {
    fn drop(&mut self) {
        if let Some(key) = self.key.take() {
            let mut flights = lock(&self.core.flights);
            if flights.get(&key).is_some_and(|e| e.id == self.id) {
                flights.remove(&key);
            }
        }
        if !self.done {
            let p = Priority::from_u8(self.priority.load(Ordering::Relaxed));
            let mut e = event(NetEventKind::Cancelled, &self.request, &self.host, p);
            e.elapsed = self.started.elapsed();
            self.core.emit(e);
        }
    }
}

fn transient(answer: &Answer) -> bool {
    match answer {
        Ok(r) => matches!(r.status, 408 | 429 | 502 | 503 | 504),
        Err(ErrorKind::Network { code }) => !matches!(
            *code,
            url_error::CANCELLED
                | url_error::CANNOT_FIND_HOST
                | url_error::DNS_LOOKUP_FAILED
                | url_error::NOT_CONNECTED_TO_INTERNET
        ),
        Err(_) => false,
    }
}

fn retry_after(answer: &Answer, cap: Duration) -> Option<Duration> {
    let secs: u64 = answer
        .as_ref()
        .ok()?
        .header("Retry-After")?
        .trim()
        .parse()
        .ok()?;
    Some(Duration::from_secs(secs).min(cap))
}

fn validator_key(request: &HttpRequest) -> String {
    flight_key(request)
}

async fn run<T: HttpTransport + 'static>(
    core: Arc<Core>,
    inner: Arc<T>,
    request: HttpRequest,
    host: String,
    options: RequestOptions,
    priority: Arc<AtomicU8>,
    guard: Option<FlightGuard>,
) -> Answer {
    let started = Instant::now();
    let mut guard = guard;
    let work = attempts(&core, &inner, &request, &host, options, &priority, started);
    let deadline = core.timer.sleep(core.config.deadline);
    let outcome = match select(Box::pin(work), deadline).await {
        Either::Left((answer, _)) => answer,
        Either::Right(((), _)) => (
            Err(ErrorKind::Network {
                code: url_error::TIMED_OUT,
            }),
            1,
            Duration::ZERO,
        ),
    };
    let (answer, tries, queued) = outcome;
    if let Some(g) = guard.as_mut() {
        g.done = true;
    }
    let p = Priority::from_u8(priority.load(Ordering::Relaxed));
    let mut e = event(
        if answer.is_ok() {
            NetEventKind::Completed
        } else {
            NetEventKind::Failed
        },
        &request,
        &host,
        p,
    );
    e.elapsed = started.elapsed();
    e.queued = queued;
    e.attempts = tries;
    if let Ok(r) = &answer {
        e.status = Some(r.status);
        e.bytes = r.body.len();
    }
    core.emit(e);
    answer
}

async fn attempts<T: HttpTransport + 'static>(
    core: &Core,
    inner: &Arc<T>,
    request: &HttpRequest,
    host: &str,
    options: RequestOptions,
    priority: &Arc<AtomicU8>,
    started: Instant,
) -> (Answer, u32, Duration) {
    let idempotent = matches!(request.method, Method::Get);
    let gate = core.gate(host);
    let vkey = (options.conditional
        && idempotent
        && core.config.validator_budget > 0
        && request.header("If-None-Match").is_none()
        && request.header("If-Modified-Since").is_none())
    .then(|| validator_key(request));
    let mut queued = Duration::ZERO;
    let mut tries = 0u32;
    loop {
        let mut req = request.clone();
        let mut known: Option<HttpResponse> = None;
        if let Some(k) = &vkey {
            let v = lock(&core.validators);
            if let Some(v) = v.map.get(k) {
                if let Some(etag) = &v.etag {
                    req.set_header("If-None-Match", etag);
                } else if let Some(lm) = &v.last_modified {
                    req.set_header("If-Modified-Since", lm);
                }
                known = Some(v.response.clone());
            }
        }
        let wait = Instant::now();
        let permit = gate.acquire(Arc::clone(priority)).await;
        queued += wait.elapsed();
        let answer = inner.send(req).await;
        drop(permit);
        tries += 1;

        if let (Ok(r), Some(k)) = (&answer, &vkey) {
            if r.status == 304 {
                if let Some(mut stored) = known {
                    let p = Priority::from_u8(priority.load(Ordering::Relaxed));
                    let mut e = event(NetEventKind::NotModified, request, host, p);
                    e.elapsed = started.elapsed();
                    e.status = Some(304);
                    core.emit(e);
                    stored.url = r.url.clone().or(stored.url);
                    return (Ok(stored), tries, queued);
                }
            } else if r.status == 200 {
                let etag = r.header("ETag").map(str::to_string);
                let lm = r.header("Last-Modified").map(str::to_string);
                let no_store = r
                    .header("Cache-Control")
                    .is_some_and(|c| c.to_ascii_lowercase().contains("no-store"));
                let mut v = lock(&core.validators);
                if (etag.is_some() || lm.is_some()) && !no_store {
                    v.clock += 1;
                    let stamp = v.clock;
                    v.store(
                        k.clone(),
                        Validated {
                            etag,
                            last_modified: lm,
                            response: r.clone(),
                            stamp,
                        },
                        core.config.validator_budget,
                    );
                } else if let Some(old) = v.map.remove(k) {
                    v.bytes -= old.response.body.len();
                }
            }
        }

        if idempotent && options.retry && tries <= core.config.max_retries && transient(&answer) {
            let backoff = core.config.retry_base * 2u32.saturating_pow(tries - 1);
            let delay = retry_after(&answer, core.config.retry_after_cap)
                .unwrap_or_else(|| core.jittered(backoff));
            let p = Priority::from_u8(priority.load(Ordering::Relaxed));
            let mut e = event(NetEventKind::Retried, request, host, p);
            e.elapsed = started.elapsed();
            e.attempts = tries;
            e.status = answer.as_ref().ok().map(|r| r.status);
            core.emit(e);
            core.timer.sleep(delay).await;
            continue;
        }
        return (answer, tries, queued);
    }
}
