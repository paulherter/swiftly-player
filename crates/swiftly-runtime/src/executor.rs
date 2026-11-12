//! Single-threaded executor, polled once per UI frame. `!Send`: futures may hold `Rc`, `RefCell`, UI state.
//! Wakeups may come from any thread (worker pool, channels) through a Mutex+Condvar ready queue.
use crate::clock::Clock;
use std::cell::{Cell, RefCell};
use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap, HashSet, VecDeque};
use std::future::Future;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::pin::Pin;
use std::rc::Rc;
use std::sync::{Arc, Condvar, Mutex};
use std::task::{Context, Poll, Wake, Waker};
use std::time::Duration;

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

// ---------- ready queue (the only cross-thread state) ----------

#[derive(Default)]
struct ReadyQ {
    order: VecDeque<u64>,
    set: HashSet<u64>,
}
#[derive(Default)]
pub(crate) struct Shared {
    q: Mutex<ReadyQ>,
    cv: Condvar,
}
impl Shared {
    pub(crate) fn wake(&self, id: u64) {
        let mut g = lock(&self.q);
        if g.set.insert(id) {
            g.order.push_back(id);
            self.cv.notify_one();
        }
    }
    fn take_batch(&self) -> Vec<u64> {
        let mut g = lock(&self.q);
        g.set.clear();
        g.order.drain(..).collect()
    }
    fn is_empty(&self) -> bool {
        lock(&self.q).order.is_empty()
    }
}
struct TaskWaker {
    id: u64,
    shared: Arc<Shared>,
}
impl Wake for TaskWaker {
    fn wake(self: Arc<Self>) {
        self.shared.wake(self.id);
    }
    fn wake_by_ref(self: &Arc<Self>) {
        self.shared.wake(self.id);
    }
}

// ---------- task bookkeeping ----------

#[derive(Default)]
pub(crate) struct TaskMeta {
    cancelled: Cell<bool>,
    panicked: Cell<bool>,
    cooperative: bool,
}
type LocalFut = Pin<Box<dyn Future<Output = ()>>>;
struct Slot {
    fut: Option<LocalFut>,
    meta: Rc<TaskMeta>,
    waker: Waker,
}
struct Timer {
    at: Duration,
    seq: u64,
    live: Rc<Cell<bool>>,
    waker: Waker,
}
impl PartialEq for Timer {
    fn eq(&self, o: &Self) -> bool {
        (self.at, self.seq) == (o.at, o.seq)
    }
}
impl Eq for Timer {}
impl PartialOrd for Timer {
    fn partial_cmp(&self, o: &Self) -> Option<Ordering> {
        Some(self.cmp(o))
    }
}
impl Ord for Timer {
    fn cmp(&self, o: &Self) -> Ordering {
        (o.at, o.seq).cmp(&(self.at, self.seq)) // reversed: BinaryHeap is a max-heap
    }
}

pub(crate) struct Inner {
    shared: Arc<Shared>,
    clock: Arc<dyn Clock>,
    tasks: RefCell<HashMap<u64, Slot>>,
    timers: RefCell<BinaryHeap<Timer>>,
    next_id: Cell<u64>,
    seq: Cell<u64>,
    in_frame: Cell<bool>,
    panics: Cell<u64>,
    budget: Cell<usize>,
}

thread_local! {
    static CURRENT: RefCell<Option<Rc<Inner>>> = const { RefCell::new(None) };
    static CURRENT_META: RefCell<Option<Rc<TaskMeta>>> = const { RefCell::new(None) };
}
fn current() -> Rc<Inner> {
    match CURRENT.with(|c| c.borrow().clone()) {
        Some(inner) => inner,
        None => panic!("not inside a UiExecutor"),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JoinError {
    Cancelled,
    Panicked,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cancelled;

struct JoinState<T> {
    result: RefCell<Option<Result<T, JoinError>>>,
    waker: RefCell<Option<Waker>>,
}
struct Finisher<T> {
    state: Rc<JoinState<T>>,
    meta: Rc<TaskMeta>,
    done: bool,
}
impl<T> Finisher<T> {
    fn finish(&mut self, r: Result<T, JoinError>) {
        self.done = true;
        *self.state.result.borrow_mut() = Some(r);
        if let Some(w) = self.state.waker.borrow_mut().take() {
            w.wake();
        }
    }
}
impl<T> Drop for Finisher<T> {
    fn drop(&mut self) {
        if !self.done {
            let e = if self.meta.panicked.get() || std::thread::panicking() {
                JoinError::Panicked
            } else {
                JoinError::Cancelled
            };
            self.finish(Err(e));
        }
    }
}

/// Like `Task<T, Never>` in Swift: dropping the handle detaches the task (it keeps running); `cancel()` cancels it.
pub struct JoinHandle<T> {
    state: Rc<JoinState<T>>,
    meta: Rc<TaskMeta>,
    shared: Arc<Shared>,
    id: u64,
}
impl<T> JoinHandle<T> {
    /// Cancel. Default tasks are dropped at the next frame (destructors run); cooperative tasks (see
    /// `spawn_cooperative`) only see `is_cancelled()` flip and `sleep` return `Err(Cancelled)`, as in Swift.
    pub fn cancel(&self) {
        self.meta.cancelled.set(true);
        self.shared.wake(self.id);
    }
    pub fn is_finished(&self) -> bool {
        self.state.result.borrow().is_some()
    }
    pub fn try_take(&self) -> Option<Result<T, JoinError>> {
        self.state.result.borrow_mut().take()
    }
}
impl<T> Future for JoinHandle<T> {
    type Output = Result<T, JoinError>;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        if let Some(r) = self.state.result.borrow_mut().take() {
            return Poll::Ready(r);
        }
        *self.state.waker.borrow_mut() = Some(cx.waker().clone());
        Poll::Pending
    }
}

/// `Task.isCancelled` of the running task (false outside a task).
pub fn is_cancelled() -> bool {
    CURRENT_META.with(|m| m.borrow().as_ref().is_some_and(|m| m.cancelled.get()))
}

// ---------- timers ----------

pub struct Sleep {
    inner: Rc<Inner>,
    at: Duration,
    live: Option<Rc<Cell<bool>>>,
}
/// `try await Task.sleep(for:)`: `Err(Cancelled)` if the task is canceled (cooperative tasks only).
pub fn sleep(d: Duration) -> Sleep {
    let inner = current();
    let at = inner.clock.now() + d;
    Sleep {
        inner,
        at,
        live: None,
    }
}
impl Future for Sleep {
    type Output = Result<(), Cancelled>;
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        if is_cancelled() {
            return Poll::Ready(Err(Cancelled));
        }
        if self.inner.clock.now() >= self.at {
            return Poll::Ready(Ok(()));
        }
        if self.live.is_none() {
            let live = Rc::new(Cell::new(true));
            let seq = self.inner.seq.get();
            self.inner.seq.set(seq + 1);
            self.inner.timers.borrow_mut().push(Timer {
                at: self.at,
                seq,
                live: Rc::clone(&live),
                waker: cx.waker().clone(),
            });
            self.live = Some(live);
        }
        Poll::Pending
    }
}
impl Drop for Sleep {
    fn drop(&mut self) {
        if let Some(l) = &self.live {
            l.set(false);
        }
    }
}
pub struct YieldNow(bool);
/// Suspension point that lets other ready tasks run first (a hop to another actor in Swift terms).
pub fn yield_now() -> YieldNow {
    YieldNow(false)
}
impl Future for YieldNow {
    type Output = ();
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        if self.0 {
            Poll::Ready(())
        } else {
            self.0 = true;
            cx.waker().wake_by_ref();
            Poll::Pending
        }
    }
}

// ---------- the executor ----------

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct FrameStats {
    pub polled: usize,
    pub completed: usize,
    pub panicked: usize,
}

pub struct UiExecutor {
    inner: Rc<Inner>,
}
impl UiExecutor {
    /// Also installs itself as the thread's ambient executor, so `spawn_local`/`sleep` work from UI callbacks outside a frame
    /// (observers, button handlers), like `Task { }` works from any MainActor code in Swift.
    pub fn new(clock: Arc<dyn Clock>) -> Self {
        let inner = Rc::new(Inner {
            shared: Arc::new(Shared::default()),
            clock,
            tasks: RefCell::new(HashMap::new()),
            timers: RefCell::new(BinaryHeap::new()),
            next_id: Cell::new(1),
            seq: Cell::new(0),
            in_frame: Cell::new(false),
            panics: Cell::new(0),
            budget: Cell::new(100_000),
        });
        CURRENT.with(|c| *c.borrow_mut() = Some(Rc::clone(&inner)));
        UiExecutor { inner }
    }
    /// Upper bound of polls per `poll_frame` (checked between wake batches) so a self-waking task cannot freeze a frame.
    pub fn set_frame_budget(&self, polls: usize) {
        self.inner.budget.set(polls);
    }
    pub fn spawn_local<T: 'static>(&self, f: impl Future<Output = T> + 'static) -> JoinHandle<T> {
        self.inner.spawn(f, false)
    }
    /// Cancellation only flips `is_cancelled()` and ends `sleep`: the body decides when to stop (Swift semantics).
    pub fn spawn_cooperative<T: 'static>(
        &self,
        f: impl Future<Output = T> + 'static,
    ) -> JoinHandle<T> {
        self.inner.spawn(f, true)
    }
    pub fn live_tasks(&self) -> usize {
        self.inner.tasks.borrow().len()
    }
    pub fn panic_count(&self) -> u64 {
        self.inner.panics.get()
    }
    pub fn has_ready(&self) -> bool {
        !self.inner.shared.is_empty()
    }
    /// Earliest live timer, `None` if none. Used by hosts to decide how long the loop may sleep.
    pub fn next_deadline(&self) -> Option<Duration> {
        let mut t = self.inner.timers.borrow_mut();
        while t.peek().is_some_and(|x| !x.live.get()) {
            t.pop();
        }
        t.peek().map(|x| x.at)
    }
    /// Blocks until something is ready or `timeout` passed (host event loop idle wait). Returns `has_ready()`.
    pub fn park(&self, timeout: Duration) -> bool {
        let g = lock(&self.inner.shared.q);
        if !g.order.is_empty() {
            return true;
        }
        let (g, _) = self
            .inner
            .shared
            .cv
            .wait_timeout(g, timeout)
            .unwrap_or_else(|e| e.into_inner());
        !g.order.is_empty()
    }
    /// Fires due timers, then polls every task that is ready (also those that become ready meanwhile, up to the budget).
    pub fn poll_frame(&self) -> FrameStats {
        crate::root::assert_root_unborrowed();
        let inner = &self.inner;
        let mut stats = FrameStats::default();
        if inner.in_frame.replace(true) {
            return stats; // re-entrant call from inside a task: ignored
        }
        let prev = CURRENT.with(|c| c.borrow_mut().replace(Rc::clone(inner)));
        inner.fire_timers();
        while stats.polled < inner.budget.get() {
            let batch = inner.shared.take_batch();
            if batch.is_empty() {
                break;
            }
            for id in batch {
                inner.poll_task(id, &mut stats);
            }
        }
        CURRENT.with(|c| *c.borrow_mut() = prev);
        inner.in_frame.set(false);
        stats
    }
}
impl Drop for UiExecutor {
    fn drop(&mut self) {
        // Drop all futures with CURRENT set (their destructors may touch the executor); joiners see Cancelled.
        let prev = CURRENT.with(|c| c.borrow_mut().replace(Rc::clone(&self.inner)));
        let slots: Vec<Slot> = self
            .inner
            .tasks
            .borrow_mut()
            .drain()
            .map(|(_, s)| s)
            .collect();
        for s in slots {
            let _ = catch_unwind(AssertUnwindSafe(|| drop(s)));
        }
        CURRENT.with(|c| *c.borrow_mut() = prev);
        CURRENT.with(|c| {
            let mut c = c.borrow_mut();
            if c.as_ref().is_some_and(|x| Rc::ptr_eq(x, &self.inner)) {
                *c = None;
            }
        });
    }
}

/// `spawn_local` from inside a running task or from `poll_frame`.
pub fn spawn_local<T: 'static>(f: impl Future<Output = T> + 'static) -> JoinHandle<T> {
    current().spawn(f, false)
}
pub fn spawn_cooperative<T: 'static>(f: impl Future<Output = T> + 'static) -> JoinHandle<T> {
    current().spawn(f, true)
}

impl Inner {
    fn spawn<T: 'static>(
        self: &Rc<Self>,
        f: impl Future<Output = T> + 'static,
        cooperative: bool,
    ) -> JoinHandle<T> {
        let id = self.next_id.get();
        self.next_id.set(id + 1);
        let meta = Rc::new(TaskMeta {
            cooperative,
            ..Default::default()
        });
        let state = Rc::new(JoinState {
            result: RefCell::new(None),
            waker: RefCell::new(None),
        });
        let mut fin = Finisher {
            state: Rc::clone(&state),
            meta: Rc::clone(&meta),
            done: false,
        };
        let fut: LocalFut = Box::pin(async move {
            let v = f.await;
            fin.finish(Ok(v));
        });
        let waker = Waker::from(Arc::new(TaskWaker {
            id,
            shared: Arc::clone(&self.shared),
        }));
        self.tasks.borrow_mut().insert(
            id,
            Slot {
                fut: Some(fut),
                meta: Rc::clone(&meta),
                waker,
            },
        );
        self.shared.wake(id);
        JoinHandle {
            state,
            meta,
            shared: Arc::clone(&self.shared),
            id,
        }
    }

    fn fire_timers(&self) {
        let now = self.clock.now();
        loop {
            let t = {
                let mut h = self.timers.borrow_mut();
                match h.peek() {
                    Some(t) if t.at <= now || !t.live.get() => h.pop(),
                    _ => None,
                }
            };
            match t {
                Some(t) => {
                    if t.live.get() {
                        t.waker.wake();
                    }
                }
                None => break,
            }
        }
    }

    fn poll_task(&self, id: u64, stats: &mut FrameStats) {
        let (mut fut, meta, waker) = {
            let mut tasks = self.tasks.borrow_mut();
            let Some(s) = tasks.get_mut(&id) else { return };
            let Some(f) = s.fut.take() else { return };
            (f, Rc::clone(&s.meta), s.waker.clone())
        };
        if meta.cancelled.get() && !meta.cooperative {
            self.tasks.borrow_mut().remove(&id);
            self.drop_fut(fut, stats);
            stats.completed += 1;
            return;
        }
        stats.polled += 1;
        let prev = CURRENT_META.with(|m| m.borrow_mut().replace(Rc::clone(&meta)));
        let r = catch_unwind(AssertUnwindSafe(|| {
            fut.as_mut().poll(&mut Context::from_waker(&waker))
        }));
        CURRENT_META.with(|m| *m.borrow_mut() = prev);
        match r {
            Ok(Poll::Pending) => {
                if let Some(s) = self.tasks.borrow_mut().get_mut(&id) {
                    s.fut = Some(fut);
                }
            }
            Ok(Poll::Ready(())) => {
                self.tasks.borrow_mut().remove(&id);
                stats.completed += 1;
            }
            Err(_) => {
                meta.panicked.set(true);
                self.panics.set(self.panics.get() + 1);
                stats.panicked += 1;
                self.tasks.borrow_mut().remove(&id);
                self.drop_fut(fut, stats);
            }
        }
    }

    fn drop_fut(&self, fut: LocalFut, stats: &mut FrameStats) {
        // A destructor may panic or spawn; neither may take the loop down.
        if catch_unwind(AssertUnwindSafe(|| drop(fut))).is_err() {
            self.panics.set(self.panics.get() + 1);
            stats.panicked += 1;
        }
    }
}
