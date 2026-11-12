//! The request layer (`LayeredTransport`) against a scripted in-process transport and a manual
//! timer: dedup, cancellation, priorities, per-host limits, retry, deadline, conditional requests
//! and metrics. No sockets and no real waiting (except the one `TokioTimer` test).
#![allow(clippy::expect_used, clippy::unwrap_used)] // test helpers outside #[test] fns

use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};
use std::time::Duration;

use futures_executor::block_on;
use futures_util::future::{join, join_all};
use swiftly_net::{
    ErrorKind, HttpRequest, HttpResponse, HttpTransport, LayerConfig, LayeredTransport, Method,
    NetCounters, NetEvent, NetEventKind, NetMetrics, Priority, RequestOptions, Timer,
    TransportReason, Url, scoped, url_error,
};

type Answer = Result<HttpResponse, ErrorKind>;
type Fut = Pin<Box<dyn Future<Output = Answer> + Send>>;
type Layer = LayeredTransport<Fake>;

const DEADLINE: Duration = Duration::from_secs(999);

// ------------------------------------------------------------------ helpers

#[derive(Default)]
struct LatchState {
    open: bool,
    wakers: Vec<Waker>,
}

/// Calls that wait on it stay pending until `open`.
#[derive(Default)]
struct Latch {
    state: Mutex<LatchState>,
}

impl Latch {
    fn open(&self) {
        let wakers = {
            let mut s = self.state.lock().expect("lock");
            s.open = true;
            std::mem::take(&mut s.wakers)
        };
        wakers.into_iter().for_each(Waker::wake);
    }
}

struct LatchWait(Arc<Latch>);

impl Future for LatchWait {
    type Output = ();
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        let mut s = self.0.state.lock().expect("lock");
        if s.open {
            Poll::Ready(())
        } else {
            s.wakers.push(cx.waker().clone());
            Poll::Pending
        }
    }
}

/// Counts a call as active while its future lives and as dropped early when it is dropped
/// before it produced its answer.
struct InFlight<'a> {
    fake: &'a Fake,
    finished: bool,
}

impl<'a> InFlight<'a> {
    fn start(fake: &'a Fake) -> Self {
        let now = fake.active.fetch_add(1, Ordering::SeqCst) + 1;
        fake.peak.fetch_max(now, Ordering::SeqCst);
        Self {
            fake,
            finished: false,
        }
    }
}

impl Drop for InFlight<'_> {
    fn drop(&mut self) {
        self.fake.active.fetch_sub(1, Ordering::SeqCst);
        if !self.finished {
            self.fake.dropped_early.fetch_add(1, Ordering::SeqCst);
        }
    }
}

/// Scripted transport: hands out the queued answers in turn, then the fallback; records every
/// request; can hold the first `n` calls until a latch opens.
struct Fake {
    script: Mutex<VecDeque<Answer>>,
    fallback: Answer,
    seen: Mutex<Vec<HttpRequest>>,
    active: AtomicUsize,
    peak: AtomicUsize,
    dropped_early: AtomicUsize,
    hold: Option<(Arc<Latch>, usize)>,
}

impl Fake {
    fn new() -> Self {
        Self {
            script: Mutex::new(VecDeque::new()),
            fallback: Ok(HttpResponse::new(200, "ok")),
            seen: Mutex::new(Vec::new()),
            active: AtomicUsize::new(0),
            peak: AtomicUsize::new(0),
            dropped_early: AtomicUsize::new(0),
            hold: None,
        }
    }

    fn then(self, answer: Answer) -> Self {
        self.script.lock().expect("lock").push_back(answer);
        self
    }

    fn always(mut self, answer: Answer) -> Self {
        self.fallback = answer;
        self
    }

    fn hold(mut self, latch: &Arc<Latch>, first: usize) -> Self {
        self.hold = Some((Arc::clone(latch), first));
        self
    }

    fn calls(&self) -> usize {
        self.seen.lock().expect("lock").len()
    }

    fn paths(&self) -> Vec<String> {
        self.seen
            .lock()
            .expect("lock")
            .iter()
            .map(|r| r.url.path().to_string())
            .collect()
    }

    fn header(&self, call: usize, name: &str) -> Option<String> {
        self.seen.lock().expect("lock")[call]
            .header(name)
            .map(str::to_string)
    }
}

impl HttpTransport for Fake {
    fn send(&self, request: HttpRequest) -> impl Future<Output = Answer> + Send {
        let idx = {
            let mut seen = self.seen.lock().expect("lock");
            seen.push(request);
            seen.len() - 1
        };
        let answer = self
            .script
            .lock()
            .expect("lock")
            .pop_front()
            .unwrap_or_else(|| self.fallback.clone());
        let hold = self
            .hold
            .as_ref()
            .filter(|(_, n)| idx < *n)
            .map(|(l, _)| Arc::clone(l));
        async move {
            let mut call = InFlight::start(self);
            if let Some(latch) = hold {
                LatchWait(latch).await;
            }
            call.finished = true;
            answer
        }
    }
}

/// Retry sleeps resolve at once and are recorded; the deadline sleep (recognised by its
/// length) never resolves unless `fire_deadline` is set.
struct TestTimer {
    slept: Mutex<Vec<Duration>>,
    deadline: Duration,
    fire_deadline: AtomicBool,
}

impl Timer for TestTimer {
    fn sleep(&self, duration: Duration) -> Pin<Box<dyn Future<Output = ()> + Send>> {
        if duration == self.deadline {
            if self.fire_deadline.load(Ordering::SeqCst) {
                return Box::pin(std::future::ready(()));
            }
            return Box::pin(std::future::pending());
        }
        self.slept.lock().expect("lock").push(duration);
        Box::pin(std::future::ready(()))
    }
}

impl TestTimer {
    fn slept(&self) -> Vec<Duration> {
        self.slept.lock().expect("lock").clone()
    }
}

#[derive(Default)]
struct Events(Mutex<Vec<NetEvent>>);

impl NetMetrics for Events {
    fn event(&self, event: &NetEvent) {
        self.0.lock().expect("lock").push(event.clone());
    }
}

impl Events {
    fn all(&self) -> Vec<NetEvent> {
        self.0.lock().expect("lock").clone()
    }
    fn kinds(&self) -> Vec<NetEventKind> {
        self.all().iter().map(|e| e.kind).collect()
    }
    fn count(&self, kind: NetEventKind) -> usize {
        self.kinds().iter().filter(|k| **k == kind).count()
    }
}

fn cfg() -> LayerConfig {
    LayerConfig {
        deadline: DEADLINE,
        retry_base: Duration::from_millis(100),
        ..LayerConfig::default()
    }
}

fn layer(fake: Fake, config: LayerConfig) -> (Layer, Arc<TestTimer>, Arc<Events>) {
    let timer = Arc::new(TestTimer {
        slept: Mutex::new(Vec::new()),
        deadline: config.deadline,
        fire_deadline: AtomicBool::new(false),
    });
    let events = Arc::new(Events::default());
    let as_timer: Arc<dyn Timer> = Arc::clone(&timer) as Arc<dyn Timer>;
    let l = LayeredTransport::with_config(fake, as_timer, config);
    let as_metrics: Arc<dyn NetMetrics> = Arc::clone(&events) as Arc<dyn NetMetrics>;
    l.set_metrics(as_metrics);
    (l, timer, events)
}

fn url(s: &str) -> Url {
    Url::parse(s).expect("url")
}

fn get(path: &str) -> HttpRequest {
    HttpRequest::new(Method::Get, url(&format!("https://x.test{path}")))
}

fn post(path: &str) -> HttpRequest {
    HttpRequest::new(Method::Post, url(&format!("https://x.test{path}")))
}

fn go(l: &Layer, path: &str, priority: Priority) -> Fut {
    Box::pin(l.send_with(get(path), RequestOptions::with_priority(priority)))
}

/// Runs two calls side by side and expects both to be answered.
fn run2(a: impl Future<Output = Answer>, b: impl Future<Output = Answer>) {
    let (x, y) = block_on(join(a, b));
    x.expect("first");
    y.expect("second");
}

fn poll_once(f: &mut Fut) -> Poll<Answer> {
    f.as_mut().poll(&mut Context::from_waker(Waker::noop()))
}

fn net(code: i32) -> ErrorKind {
    ErrorKind::Network { code }
}

fn status(s: u16) -> Answer {
    Ok(HttpResponse::new(s, ""))
}

fn assert_between(d: Duration, lo_ms: u64, hi_ms: u64) {
    assert!(
        d >= Duration::from_millis(lo_ms) && d <= Duration::from_millis(hi_ms),
        "{d:?} not within {lo_ms}..={hi_ms} ms"
    );
}

fn tagged(etag: &str, body: &str) -> HttpResponse {
    HttpResponse::new(200, body).with_header("ETag", etag)
}

// -------------------------------------------------------------------- basics

#[test]
fn priority_orders_and_defaults() {
    assert!(Priority::Visible > Priority::Normal);
    assert!(Priority::Normal > Priority::Prefetch);
    assert!(Priority::Prefetch > Priority::Background);
    assert_eq!(Priority::default(), Priority::Normal);
    let d = RequestOptions::default();
    assert_eq!(d.priority, Priority::Normal);
    assert!(d.dedup && d.retry && d.conditional);
    let v = RequestOptions::with_priority(Priority::Visible);
    assert_eq!(v.priority, Priority::Visible);
    assert!(
        v.dedup && v.retry && v.conditional,
        "only the priority changes"
    );
}

#[test]
fn layer_config_defaults_are_sane() {
    let c = LayerConfig::default();
    assert_eq!(c.max_per_host, 8);
    assert!(c.visible_reserve < c.max_per_host);
    assert_eq!(c.max_retries, 2);
    assert!(c.retry_after_cap < c.deadline);
    assert!(c.validator_budget > 0);
}

#[test]
fn counters_count_each_kind() {
    let counters = NetCounters::default();
    for kind in [
        NetEventKind::Completed,
        NetEventKind::Completed,
        NetEventKind::Failed,
        NetEventKind::Joined,
        NetEventKind::Retried,
        NetEventKind::Retried,
        NetEventKind::Retried,
        NetEventKind::NotModified,
        NetEventKind::Cancelled,
    ] {
        counters.event(&NetEvent {
            kind,
            host: "h:1".into(),
            path: "/".into(),
            priority: Priority::Normal,
            elapsed: Duration::ZERO,
            queued: Duration::ZERO,
            status: None,
            bytes: 0,
            attempts: 0,
        });
    }
    let n = |c: &std::sync::atomic::AtomicU64| c.load(Ordering::Relaxed);
    assert_eq!(n(&counters.completed), 2);
    assert_eq!(n(&counters.failed), 1);
    assert_eq!(n(&counters.joined), 1);
    assert_eq!(n(&counters.retried), 3);
    assert_eq!(n(&counters.not_modified), 1);
    assert_eq!(n(&counters.cancelled), 1);
}

#[test]
fn plain_get_passes_through_and_reports_completed() {
    let fake = Fake::new().then(Ok(HttpResponse::new(200, "hello")));
    let (l, timer, events) = layer(fake, cfg());
    let r = block_on(l.send(get("/a?api_key=SECRET"))).expect("answer");
    assert_eq!((r.status, r.body.as_slice()), (200, b"hello".as_slice()));
    assert_eq!(l.inner().calls(), 1);
    assert!(timer.slept().is_empty(), "no retry, no sleep");
    let all = events.all();
    assert_eq!(all.len(), 1);
    let e = &all[0];
    assert_eq!(e.kind, NetEventKind::Completed);
    assert_eq!(e.host, "x.test:443");
    assert_eq!(e.path, "/a", "the query (secrets) is not reported");
    assert_eq!((e.status, e.bytes, e.attempts), (Some(200), 5, 1));
    assert_eq!(e.priority, Priority::Normal);
}

#[test]
fn cloned_layer_shares_the_wrapped_transport() {
    let (l, _t, _e) = layer(Fake::new(), cfg());
    let c = l.clone();
    block_on(c.send(get("/a"))).expect("answer");
    assert_eq!(l.inner().calls(), 1);
}

// --------------------------------------------------------------------- dedup

#[test]
fn identical_gets_share_one_call_and_each_gets_a_copy() {
    let fake = Fake::new().then(Ok(HttpResponse::new(200, "once")));
    let (l, _t, events) = layer(fake, cfg());
    let (a, b) = block_on(join(l.send(get("/a")), l.send(get("/a"))));
    assert_eq!(a.expect("a").body, b"once");
    assert_eq!(b.expect("b").body, b"once");
    assert_eq!(l.inner().calls(), 1, "one network call");
    assert_eq!(events.count(NetEventKind::Joined), 1);
    assert_eq!(events.count(NetEventKind::Completed), 1);
}

#[test]
fn flight_is_forgotten_when_done() {
    let (l, _t, _e) = layer(Fake::new(), cfg());
    block_on(l.send(get("/a"))).expect("first");
    block_on(l.send(get("/a"))).expect("second");
    assert_eq!(l.inner().calls(), 2, "a finished flight is not reused");
}

#[test]
fn different_headers_post_or_dedup_off_do_not_share() {
    let (l, _t, events) = layer(Fake::new(), cfg());
    let mut with_token = get("/a");
    with_token.set_header("X-Token", "one");
    run2(l.send(get("/a")), l.send(with_token));
    assert_eq!(l.inner().calls(), 2, "another account is another flight");

    run2(l.send(post("/a")), l.send(post("/a")));
    assert_eq!(l.inner().calls(), 4, "POST is never shared");

    let off = RequestOptions {
        dedup: false,
        ..RequestOptions::default()
    };
    run2(l.send_with(get("/a"), off), l.send_with(get("/a"), off));
    assert_eq!(l.inner().calls(), 6, "dedup can be switched off");
    assert_eq!(events.count(NetEventKind::Joined), 0);
}

#[test]
fn header_names_compare_case_insensitively_for_dedup() {
    let (l, _t, _e) = layer(Fake::new(), cfg());
    let mut a = get("/a");
    a.set_header("Accept", "x");
    let mut b = get("/a");
    b.headers.push(("ACCEPT".into(), "x".into()));
    run2(l.send(a), l.send(b));
    assert_eq!(l.inner().calls(), 1);
}

// --------------------------------------------------------------------- retry

#[test]
fn transient_status_is_retried_with_jitter_and_reported() {
    let fake = Fake::new()
        .then(status(503))
        .then(Ok(HttpResponse::new(200, "fine")));
    let (l, timer, events) = layer(fake, cfg());
    let r = block_on(l.send(get("/a"))).expect("answer");
    assert_eq!((r.status, r.body.as_slice()), (200, b"fine".as_slice()));
    assert_eq!(l.inner().calls(), 2);
    let slept = timer.slept();
    assert_eq!(slept.len(), 1);
    assert_between(slept[0], 50, 100); // retry_base 100 ms, jitter in [base/2, base]
    assert_eq!(
        events.kinds(),
        vec![NetEventKind::Retried, NetEventKind::Completed]
    );
    let all = events.all();
    assert_eq!(all[0].status, Some(503));
    assert_eq!(all[0].attempts, 1);
    assert_eq!(all[1].attempts, 2);
}

#[test]
fn each_transient_status_is_retried() {
    for code in [408u16, 429, 502, 503, 504] {
        let fake = Fake::new().then(status(code));
        let (l, _t, _e) = layer(fake, cfg());
        let r = block_on(l.send(get("/a"))).expect("answer");
        assert_eq!(r.status, 200, "{code} then ok");
        assert_eq!(l.inner().calls(), 2, "{code} was retried");
    }
}

#[test]
fn other_statuses_are_returned_without_retry() {
    for code in [400u16, 401, 404, 500, 501] {
        let (l, _t, _e) = layer(Fake::new().always(status(code)), cfg());
        let r = block_on(l.send(get("/a"))).expect("answer");
        assert_eq!(r.status, code);
        assert_eq!(l.inner().calls(), 1, "{code} is not transient");
    }
}

#[test]
fn retries_stop_at_max_and_back_off_exponentially() {
    let (l, timer, events) = layer(Fake::new().always(status(503)), cfg());
    let r = block_on(l.send(get("/a"))).expect("the last answer is returned");
    assert_eq!(r.status, 503);
    assert_eq!(l.inner().calls(), 3, "first try + max_retries (2)");
    let slept = timer.slept();
    assert_eq!(slept.len(), 2);
    assert_between(slept[0], 50, 100);
    assert_between(slept[1], 100, 200);
    assert_eq!(events.count(NetEventKind::Retried), 2);
    let last = events.all().pop().expect("event");
    assert_eq!(
        (last.kind, last.attempts, last.status),
        (NetEventKind::Completed, 3, Some(503))
    );
}

#[test]
fn zero_max_retries_never_retries() {
    let config = LayerConfig {
        max_retries: 0,
        ..cfg()
    };
    let (l, timer, _e) = layer(Fake::new().always(status(503)), config);
    assert_eq!(block_on(l.send(get("/a"))).expect("answer").status, 503);
    assert_eq!(l.inner().calls(), 1);
    assert!(timer.slept().is_empty());
}

#[test]
fn retry_after_is_honoured_and_capped() {
    let slow = |v: &str| Ok(HttpResponse::new(429, "").with_header("Retry-After", v));
    let (l, timer, _e) = layer(Fake::new().then(slow("3")), cfg());
    block_on(l.send(get("/a"))).expect("answer");
    assert_eq!(timer.slept(), vec![Duration::from_secs(3)]);

    let (l, timer, _e) = layer(Fake::new().then(slow(" 120 ")), cfg());
    block_on(l.send(get("/a"))).expect("answer");
    assert_eq!(
        timer.slept(),
        vec![Duration::from_secs(5)],
        "capped by retry_after_cap"
    );

    let (l, timer, _e) = layer(
        Fake::new().then(slow("Wed, 21 Oct 2026 07:28:00 GMT")),
        cfg(),
    );
    block_on(l.send(get("/a"))).expect("answer");
    let slept = timer.slept();
    assert_eq!(slept.len(), 1);
    assert_between(slept[0], 50, 100); // a date is not understood: normal backoff
}

#[test]
fn transient_network_errors_are_retried() {
    for code in [
        url_error::TIMED_OUT,
        url_error::NETWORK_CONNECTION_LOST,
        url_error::CANNOT_CONNECT_TO_HOST,
    ] {
        let fake = Fake::new().then(Err(net(code)));
        let (l, _t, _e) = layer(fake, cfg());
        let r = block_on(l.send(get("/a"))).expect("recovered");
        assert_eq!(r.status, 200, "code {code}");
        assert_eq!(l.inner().calls(), 2);
    }
}

#[test]
fn permanent_network_errors_fail_at_once() {
    for code in [
        url_error::CANCELLED,
        url_error::CANNOT_FIND_HOST,
        url_error::DNS_LOOKUP_FAILED,
        url_error::NOT_CONNECTED_TO_INTERNET,
    ] {
        let (l, timer, events) = layer(Fake::new().always(Err(net(code))), cfg());
        let e = block_on(l.send(get("/a"))).expect_err("fails");
        assert_eq!(e, net(code));
        assert_eq!(l.inner().calls(), 1, "code {code} is not retried");
        assert!(timer.slept().is_empty());
        assert_eq!(events.kinds(), vec![NetEventKind::Failed]);
    }
}

#[test]
fn non_network_errors_are_not_retried() {
    let err = ErrorKind::Transport(TransportReason::NoHttpResponse);
    let (l, _t, _e) = layer(Fake::new().always(Err(err.clone())), cfg());
    assert_eq!(block_on(l.send(get("/a"))).expect_err("fails"), err);
    assert_eq!(l.inner().calls(), 1);
}

#[test]
fn persistent_network_error_ends_failed_after_all_tries() {
    let (l, _t, events) = layer(Fake::new().always(Err(net(url_error::TIMED_OUT))), cfg());
    let e = block_on(l.send(get("/a"))).expect_err("fails");
    assert_eq!(e, net(url_error::TIMED_OUT));
    assert_eq!(l.inner().calls(), 3);
    let last = events.all().pop().expect("event");
    assert_eq!(
        (last.kind, last.attempts, last.status),
        (NetEventKind::Failed, 3, None)
    );
}

#[test]
fn post_and_retry_off_are_never_retried() {
    let (l, _t, _e) = layer(Fake::new().always(status(503)), cfg());
    assert_eq!(block_on(l.send(post("/a"))).expect("answer").status, 503);
    assert_eq!(l.inner().calls(), 1, "POST");

    let off = RequestOptions {
        retry: false,
        ..RequestOptions::default()
    };
    assert_eq!(
        block_on(l.send_with(get("/a"), off))
            .expect("answer")
            .status,
        503
    );
    assert_eq!(l.inner().calls(), 2, "retry: false");
}

// ------------------------------------------------------------------ deadline

#[test]
fn deadline_ends_a_silent_request_with_timed_out_and_frees_the_slot() {
    let latch = Arc::new(Latch::default());
    let config = LayerConfig {
        max_per_host: 1,
        visible_reserve: 0,
        ..cfg()
    };
    let (l, timer, events) = layer(Fake::new().hold(&latch, 1), config);
    timer.fire_deadline.store(true, Ordering::SeqCst);
    let e = block_on(l.send(get("/a"))).expect_err("deadline");
    assert_eq!(e, net(url_error::TIMED_OUT));
    assert_eq!(
        l.inner().dropped_early.load(Ordering::SeqCst),
        1,
        "the stuck call was dropped"
    );
    assert_eq!(l.inner().active.load(Ordering::SeqCst), 0);
    let all = events.all();
    assert_eq!(all.len(), 1);
    assert_eq!((all[0].kind, all[0].attempts), (NetEventKind::Failed, 1));

    // The only slot must be free again, or this would hang.
    timer.fire_deadline.store(false, Ordering::SeqCst);
    latch.open();
    assert_eq!(block_on(l.send(get("/b"))).expect("answer").status, 200);
}

#[cfg(feature = "reqwest")]
#[tokio::test]
async fn tokio_timer_enforces_a_real_deadline() {
    let latch = Arc::new(Latch::default());
    let config = LayerConfig {
        deadline: Duration::from_millis(40),
        ..LayerConfig::default()
    };
    let l = LayeredTransport::with_config(
        Fake::new().hold(&latch, 1),
        Arc::new(swiftly_net::TokioTimer),
        config,
    );
    let started = std::time::Instant::now();
    let e = l.send(get("/a")).await.expect_err("deadline");
    assert_eq!(e, net(url_error::TIMED_OUT));
    assert!(started.elapsed() >= Duration::from_millis(30));
    assert!(started.elapsed() < Duration::from_secs(10));
}

// -------------------------------------------------------------- cancellation

#[test]
fn dropping_the_only_caller_cancels_the_call() {
    let latch = Arc::new(Latch::default());
    let (l, _t, events) = layer(Fake::new().hold(&latch, 1), cfg());
    let mut f = go(&l, "/a", Priority::Normal);
    assert!(poll_once(&mut f).is_pending());
    assert_eq!(l.inner().active.load(Ordering::SeqCst), 1);
    drop(f);
    assert_eq!(
        l.inner().active.load(Ordering::SeqCst),
        0,
        "connection work stopped"
    );
    assert_eq!(l.inner().dropped_early.load(Ordering::SeqCst), 1);
    assert_eq!(events.kinds(), vec![NetEventKind::Cancelled]);

    // The cancelled flight left the table: the next call starts a new one.
    latch.open();
    let r = block_on(l.send(get("/a"))).expect("answer");
    assert_eq!(r.status, 200);
    assert_eq!(l.inner().calls(), 2);
}

#[test]
fn a_flight_with_a_waiting_caller_survives_the_starter_leaving() {
    let latch = Arc::new(Latch::default());
    let (l, _t, events) = layer(Fake::new().hold(&latch, 1), cfg());
    let mut starter = go(&l, "/a", Priority::Normal);
    let mut waiter = go(&l, "/a", Priority::Normal);
    assert!(poll_once(&mut starter).is_pending());
    assert!(poll_once(&mut waiter).is_pending());
    drop(starter);
    assert_eq!(l.inner().active.load(Ordering::SeqCst), 1, "still running");
    latch.open();
    let r = block_on(waiter).expect("answer");
    assert_eq!(r.status, 200);
    assert_eq!(l.inner().calls(), 1);
    assert_eq!(l.inner().dropped_early.load(Ordering::SeqCst), 0);
    assert_eq!(events.count(NetEventKind::Cancelled), 0);
    assert_eq!(events.count(NetEventKind::Joined), 1);
}

#[test]
fn a_cancelled_waiter_gives_its_queue_place_to_the_next() {
    let latch = Arc::new(Latch::default());
    let config = LayerConfig {
        max_per_host: 1,
        visible_reserve: 0,
        ..cfg()
    };
    let (l, _t, _e) = layer(Fake::new().hold(&latch, 1), config);
    let mut a = go(&l, "/a", Priority::Normal);
    let mut b = go(&l, "/b", Priority::Normal);
    let mut c = go(&l, "/c", Priority::Normal);
    for f in [&mut a, &mut b, &mut c] {
        assert!(poll_once(f).is_pending());
    }
    assert_eq!(l.inner().calls(), 1);
    drop(b);
    latch.open();
    let (ra, rc) = block_on(join(a, c));
    assert_eq!((ra.expect("a").status, rc.expect("c").status), (200, 200));
    assert_eq!(l.inner().paths(), vec!["/a", "/c"], "b never went out");
}

// ------------------------------------------------------- limits and priority

#[test]
fn per_host_limit_caps_calls_on_the_wire() {
    let latch = Arc::new(Latch::default());
    let config = LayerConfig {
        max_per_host: 2,
        visible_reserve: 0,
        ..cfg()
    };
    let (l, _t, events) = layer(Fake::new().hold(&latch, usize::MAX), config);
    let mut futs: Vec<Fut> = (0..4)
        .map(|i| go(&l, &format!("/{i}"), Priority::Normal))
        .collect();
    for f in &mut futs {
        assert!(poll_once(f).is_pending());
    }
    assert_eq!(l.inner().calls(), 2, "two on the wire, two queued");
    latch.open();
    for r in block_on(join_all(futs)) {
        assert_eq!(r.expect("answer").status, 200);
    }
    assert_eq!(l.inner().calls(), 4);
    assert_eq!(l.inner().peak.load(Ordering::SeqCst), 2);
    assert!(
        events
            .all()
            .iter()
            .all(|e| e.kind == NetEventKind::Completed)
    );
}

#[test]
fn hosts_are_limited_separately() {
    let latch = Arc::new(Latch::default());
    let config = LayerConfig {
        max_per_host: 1,
        visible_reserve: 0,
        ..cfg()
    };
    let (l, _t, _e) = layer(Fake::new().hold(&latch, usize::MAX), config);
    let mut a = go(&l, "/a", Priority::Normal);
    let mut b: Fut = Box::pin(l.send_with(
        HttpRequest::new(Method::Get, url("https://other.test/b")),
        RequestOptions::default(),
    ));
    assert!(poll_once(&mut a).is_pending());
    assert!(poll_once(&mut b).is_pending());
    assert_eq!(l.inner().calls(), 2, "the other host has its own slot");
    latch.open();
    block_on(join(a, b)).0.expect("a");
}

#[test]
fn higher_priority_goes_first_when_a_slot_frees_up() {
    let latch = Arc::new(Latch::default());
    let config = LayerConfig {
        max_per_host: 1,
        visible_reserve: 0,
        ..cfg()
    };
    let (l, _t, _e) = layer(Fake::new().hold(&latch, 1), config);
    let mut futs = vec![
        go(&l, "/a", Priority::Normal),
        go(&l, "/b", Priority::Background),
        go(&l, "/c", Priority::Visible),
        go(&l, "/d", Priority::Normal),
        go(&l, "/e", Priority::Prefetch),
    ];
    for f in &mut futs {
        assert!(poll_once(f).is_pending());
    }
    assert_eq!(l.inner().calls(), 1);
    latch.open();
    for r in block_on(join_all(futs)) {
        r.expect("answer");
    }
    // /a held the slot; then visible, normal, prefetch, background.
    assert_eq!(l.inner().paths(), vec!["/a", "/c", "/d", "/e", "/b"]);
}

#[test]
fn same_priority_keeps_arrival_order() {
    let latch = Arc::new(Latch::default());
    let config = LayerConfig {
        max_per_host: 1,
        visible_reserve: 0,
        ..cfg()
    };
    let (l, _t, _e) = layer(Fake::new().hold(&latch, 1), config);
    let mut futs: Vec<Fut> = ["/a", "/b", "/c", "/d"]
        .iter()
        .map(|p| go(&l, p, Priority::Normal))
        .collect();
    for f in &mut futs {
        assert!(poll_once(f).is_pending());
    }
    latch.open();
    for r in block_on(join_all(futs)) {
        r.expect("answer");
    }
    assert_eq!(l.inner().paths(), vec!["/a", "/b", "/c", "/d"]);
}

#[test]
fn prefetch_and_background_cannot_take_the_reserved_slots() {
    let latch = Arc::new(Latch::default());
    let config = LayerConfig {
        max_per_host: 2,
        visible_reserve: 1,
        ..cfg()
    };
    let (l, _t, _e) = layer(Fake::new().hold(&latch, usize::MAX), config);
    let mut p1 = go(&l, "/p1", Priority::Prefetch);
    let mut p2 = go(&l, "/p2", Priority::Background);
    assert!(poll_once(&mut p1).is_pending());
    assert!(poll_once(&mut p2).is_pending());
    assert_eq!(
        l.inner().calls(),
        1,
        "the last slot is kept free for visible work"
    );
    let mut v = go(&l, "/v", Priority::Visible);
    assert!(poll_once(&mut v).is_pending()); // queues behind p2, but is granted the free slot at once
    assert!(poll_once(&mut v).is_pending()); // the wake-up: it now sends
    assert_eq!(l.inner().calls(), 2, "visible takes the reserved slot");
    assert_eq!(l.inner().paths(), vec!["/p1", "/v"]);
    latch.open();
    for r in block_on(join_all(vec![p1, p2, v])) {
        r.expect("answer");
    }
    assert_eq!(l.inner().calls(), 3);
}

#[test]
fn joining_with_higher_priority_lifts_the_flight() {
    let latch = Arc::new(Latch::default());
    let config = LayerConfig {
        max_per_host: 1,
        visible_reserve: 0,
        ..cfg()
    };
    let (l, _t, events) = layer(Fake::new().hold(&latch, 1), config);
    let mut a = go(&l, "/a", Priority::Normal);
    let mut b = go(&l, "/b", Priority::Background);
    let mut c = go(&l, "/c", Priority::Normal);
    for f in [&mut a, &mut b, &mut c] {
        assert!(poll_once(f).is_pending());
    }
    // A screen now waits for /b: it joins the flight and lifts it above /c.
    let mut b2 = go(&l, "/b", Priority::Visible);
    assert!(poll_once(&mut b2).is_pending());
    assert_eq!(events.count(NetEventKind::Joined), 1);
    latch.open();
    for r in block_on(join_all(vec![a, b, c, b2])) {
        r.expect("answer");
    }
    assert_eq!(l.inner().paths(), vec!["/a", "/b", "/c"]);
}

// -------------------------------------------------------------------- scoped

#[test]
fn scoped_options_reach_requests_made_inside_only() {
    let (l, _t, _e) = layer(Fake::new().always(status(503)), cfg());
    let no_retry = RequestOptions {
        retry: false,
        ..RequestOptions::default()
    };
    let inside = block_on(scoped(no_retry, async { l.send(get("/a")).await }));
    assert_eq!(inside.expect("answer").status, 503);
    assert_eq!(l.inner().calls(), 1, "retry was off inside the scope");

    let outside = block_on(l.send(get("/b")));
    assert_eq!(outside.expect("answer").status, 503);
    assert_eq!(
        l.inner().calls(),
        4,
        "the ambient options are gone again: 1 + 3 tries"
    );
}

#[test]
fn scoped_dedup_off_makes_two_calls() {
    let (l, _t, _e) = layer(Fake::new(), cfg());
    let off = RequestOptions {
        dedup: false,
        ..RequestOptions::default()
    };
    let one = scoped(off, async { l.send(get("/a")).await });
    let two = scoped(off, async { l.send(get("/a")).await });
    let (a, b) = block_on(join(one, two));
    a.expect("a");
    b.expect("b");
    assert_eq!(l.inner().calls(), 2);
}

// ---------------------------------------------------------------- conditional

#[test]
fn etag_makes_the_next_get_conditional_and_304_returns_the_stored_answer() {
    let fake = Fake::new()
        .then(Ok(tagged("\"abc\"", "v1")))
        .then(status(304));
    let (l, _t, events) = layer(fake, cfg());
    let first = block_on(l.send(get("/a"))).expect("first");
    assert_eq!(first.body, b"v1");
    let second = block_on(l.send(get("/a"))).expect("second");
    assert_eq!(
        (second.status, second.body.as_slice()),
        (200, b"v1".as_slice())
    );
    assert_eq!(l.inner().header(0, "If-None-Match"), None);
    assert_eq!(
        l.inner().header(1, "If-None-Match").as_deref(),
        Some("\"abc\"")
    );
    assert_eq!(events.count(NetEventKind::NotModified), 1);
    let last = events.all().pop().expect("event");
    assert_eq!(
        (last.kind, last.status, last.bytes),
        (NetEventKind::Completed, Some(200), 2)
    );
}

#[test]
fn last_modified_is_used_when_there_is_no_etag() {
    let stamp = "Mon, 02 Nov 2026 10:00:00 GMT";
    let first = HttpResponse::new(200, "lm").with_header("Last-Modified", stamp);
    let (l, _t, _e) = layer(Fake::new().then(Ok(first)).then(status(304)), cfg());
    block_on(l.send(get("/a"))).expect("first");
    let second = block_on(l.send(get("/a"))).expect("second");
    assert_eq!(second.body, b"lm");
    assert_eq!(
        l.inner().header(1, "If-Modified-Since").as_deref(),
        Some(stamp)
    );
    assert_eq!(l.inner().header(1, "If-None-Match"), None);
}

#[test]
fn etag_wins_over_last_modified() {
    let first = tagged("\"e\"", "x").with_header("Last-Modified", "Mon, 02 Nov 2026 10:00:00 GMT");
    let (l, _t, _e) = layer(Fake::new().then(Ok(first)).then(status(304)), cfg());
    block_on(l.send(get("/a"))).expect("first");
    block_on(l.send(get("/a"))).expect("second");
    assert_eq!(
        l.inner().header(1, "If-None-Match").as_deref(),
        Some("\"e\"")
    );
    assert_eq!(l.inner().header(1, "If-Modified-Since"), None);
}

#[test]
fn not_modified_takes_the_final_address_of_the_new_answer() {
    let mut first = tagged("\"e\"", "x");
    first.url = Some(url("https://x.test/old"));
    let mut not_modified = HttpResponse::new(304, "");
    not_modified.url = Some(url("https://x.test/moved"));
    let (l, _t, _e) = layer(Fake::new().then(Ok(first)).then(Ok(not_modified)), cfg());
    block_on(l.send(get("/a"))).expect("first");
    let second = block_on(l.send(get("/a"))).expect("second");
    assert_eq!(second.url, Some(url("https://x.test/moved")));
    assert_eq!(second.body, b"x");
}

#[test]
fn a_304_without_a_stored_answer_is_passed_on() {
    let (l, _t, events) = layer(Fake::new().always(status(304)), cfg());
    let r = block_on(l.send(get("/a"))).expect("answer");
    assert_eq!(r.status, 304);
    assert_eq!(events.count(NetEventKind::NotModified), 0);
}

#[test]
fn no_store_and_missing_validators_are_not_remembered() {
    let no_store = tagged("\"e\"", "x").with_header("Cache-Control", "Private, No-Store");
    let (l, _t, _e) = layer(Fake::new().then(Ok(no_store)), cfg());
    block_on(l.send(get("/a"))).expect("first");
    block_on(l.send(get("/a"))).expect("second");
    assert_eq!(l.inner().header(1, "If-None-Match"), None, "no-store");

    let (l, _t, _e) = layer(Fake::new(), cfg());
    block_on(l.send(get("/a"))).expect("first");
    block_on(l.send(get("/a"))).expect("second");
    assert_eq!(
        l.inner().header(1, "If-None-Match"),
        None,
        "a server without validators"
    );
    assert_eq!(l.inner().header(1, "If-Modified-Since"), None);
}

#[test]
fn an_answer_without_validators_forgets_the_old_one() {
    let fake = Fake::new()
        .then(Ok(tagged("\"e\"", "x")))
        .then(Ok(HttpResponse::new(200, "y")));
    let (l, _t, _e) = layer(fake, cfg());
    for _ in 0..3 {
        block_on(l.send(get("/a"))).expect("answer");
    }
    assert_eq!(
        l.inner().header(1, "If-None-Match").as_deref(),
        Some("\"e\"")
    );
    assert_eq!(
        l.inner().header(2, "If-None-Match"),
        None,
        "the plain 200 dropped the validator"
    );
}

#[test]
fn conditional_requests_can_be_switched_off() {
    let (l, _t, _e) = layer(Fake::new().always(Ok(tagged("\"e\"", "x"))), cfg());
    let off = RequestOptions {
        conditional: false,
        ..RequestOptions::default()
    };
    block_on(l.send_with(get("/a"), off)).expect("first");
    block_on(l.send_with(get("/a"), off)).expect("second");
    assert_eq!(l.inner().header(1, "If-None-Match"), None);

    let config = LayerConfig {
        validator_budget: 0,
        ..cfg()
    };
    let (l, _t, _e) = layer(Fake::new().always(Ok(tagged("\"e\"", "x"))), config);
    block_on(l.send(get("/a"))).expect("first");
    block_on(l.send(get("/a"))).expect("second");
    assert_eq!(
        l.inner().header(1, "If-None-Match"),
        None,
        "budget 0 turns them off"
    );
}

#[test]
fn a_validator_set_by_the_caller_is_left_alone() {
    let (l, _t, events) = layer(Fake::new().always(status(304)), cfg());
    let mut req = get("/a");
    req.set_header("If-None-Match", "\"mine\"");
    let r = block_on(l.send(req)).expect("answer");
    assert_eq!(
        r.status, 304,
        "the caller asked conditionally and gets the 304"
    );
    assert_eq!(
        l.inner().header(0, "If-None-Match").as_deref(),
        Some("\"mine\"")
    );
    assert_eq!(events.count(NetEventKind::NotModified), 0);
}

#[test]
fn only_gets_are_conditional() {
    let (l, _t, _e) = layer(Fake::new().always(Ok(tagged("\"e\"", "x"))), cfg());
    block_on(l.send(post("/a"))).expect("first");
    block_on(l.send(post("/a"))).expect("second");
    assert_eq!(l.inner().header(1, "If-None-Match"), None);
}

#[test]
fn validators_are_kept_per_account() {
    let fake = Fake::new().always(Ok(tagged("\"e\"", "x")));
    let (l, _t, _e) = layer(fake, cfg());
    let mut alice = get("/a");
    alice.set_header("Authorization", "alice");
    let mut bob = get("/a");
    bob.set_header("Authorization", "bob");
    block_on(l.send(alice)).expect("alice");
    block_on(l.send(bob)).expect("bob");
    assert_eq!(
        l.inner().header(1, "If-None-Match"),
        None,
        "bob never sees alice's validator"
    );
}

#[test]
fn validator_store_respects_its_budget_and_drops_the_oldest() {
    let config = LayerConfig {
        validator_budget: 100,
        ..cfg()
    };
    // Each body is 20 bytes: five fit in 100, the sixth evicts the oldest.
    let body = "0123456789abcdefghij";
    let (l, _t, _e) = layer(Fake::new().always(Ok(tagged("\"e\"", body))), config);
    for i in 1..=6 {
        block_on(l.send(get(&format!("/{i}")))).expect("answer");
    }
    block_on(l.send(get("/1"))).expect("again"); // call 6: evicted, so unconditional
    block_on(l.send(get("/6"))).expect("again"); // call 7: still remembered
    block_on(l.send(get("/2"))).expect("again"); // call 8: evicted when /1 came back
    assert_eq!(
        l.inner().header(6, "If-None-Match"),
        None,
        "the oldest was dropped"
    );
    assert_eq!(
        l.inner().header(7, "If-None-Match").as_deref(),
        Some("\"e\"")
    );
    assert_eq!(
        l.inner().header(8, "If-None-Match"),
        None,
        "the next oldest went for /1"
    );
}

#[test]
fn an_answer_above_a_quarter_of_the_budget_is_not_stored() {
    let config = LayerConfig {
        validator_budget: 100,
        ..cfg()
    };
    let big = "x".repeat(26);
    let (l, _t, _e) = layer(Fake::new().always(Ok(tagged("\"e\"", &big))), config);
    block_on(l.send(get("/a"))).expect("first");
    block_on(l.send(get("/a"))).expect("second");
    assert_eq!(l.inner().header(1, "If-None-Match"), None);
}
