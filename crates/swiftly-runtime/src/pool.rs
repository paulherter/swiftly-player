//! Worker pool: N OS threads, or a manual mode where the test drives jobs one by one on its own thread.
//! Results come back to the UI executor through the future's waker (a ready-queue push, never a callback).
use std::collections::VecDeque;
use std::future::Future;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::task::{Context, Poll, Waker};
use std::thread;

type Job = Box<dyn FnOnce() + Send>;
fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

struct PoolInner {
    queue: Mutex<VecDeque<Job>>,
    cv: Condvar,
    manual: bool,
    shutdown: AtomicBool,
}
pub struct WorkerPool {
    inner: Arc<PoolInner>,
    threads: Vec<thread::JoinHandle<()>>,
}
/// Passed to a job: cooperative cancellation (the awaiting future was dropped).
#[derive(Clone)]
pub struct JobCtl(Arc<AtomicBool>);
impl JobCtl {
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkerPanic;

struct Slot<T> {
    result: Option<Result<T, WorkerPanic>>,
    waker: Option<Waker>,
}
pub struct WorkFuture<T> {
    slot: Arc<Mutex<Slot<T>>>,
    cancelled: Arc<AtomicBool>,
}
impl<T> Future for WorkFuture<T> {
    type Output = Result<T, WorkerPanic>;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut g = lock(&self.slot);
        if let Some(r) = g.result.take() {
            return Poll::Ready(r);
        }
        g.waker = Some(cx.waker().clone());
        Poll::Pending
    }
}
impl<T> Drop for WorkFuture<T> {
    /// Dropping the future (task canceled) flags the job: queued jobs are skipped, running ones can check `JobCtl`.
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::SeqCst);
    }
}

impl WorkerPool {
    pub fn threads(n: usize) -> Self {
        let inner = Arc::new(PoolInner {
            queue: Mutex::default(),
            cv: Condvar::new(),
            manual: false,
            shutdown: AtomicBool::new(false),
        });
        let threads = (0..n.max(1))
            // shortcut: a thread the OS refuses to start is skipped (fewer workers); upgrade to an error return if that must be visible.
            .filter_map(|i| {
                let inner = Arc::clone(&inner);
                thread::Builder::new()
                    .name(format!("swiftly-worker-{i}"))
                    .spawn(move || {
                        loop {
                            let job = {
                                let mut q = lock(&inner.queue);
                                loop {
                                    if let Some(j) = q.pop_front() {
                                        break Some(j);
                                    }
                                    if inner.shutdown.load(Ordering::SeqCst) {
                                        break None;
                                    }
                                    q = inner.cv.wait(q).unwrap_or_else(|e| e.into_inner());
                                }
                            };
                            match job {
                                Some(j) => j(),
                                None => return,
                            }
                        }
                    })
                    .ok()
            })
            .collect();
        WorkerPool { inner, threads }
    }
    /// Deterministic mode for tests: nothing runs until `step()`.
    pub fn manual() -> Self {
        WorkerPool {
            inner: Arc::new(PoolInner {
                queue: Mutex::default(),
                cv: Condvar::new(),
                manual: true,
                shutdown: AtomicBool::new(false),
            }),
            threads: vec![],
        }
    }
    pub fn pending(&self) -> usize {
        lock(&self.inner.queue).len()
    }
    /// Manual mode: run the oldest job on the calling thread. False if none was queued.
    pub fn step(&self) -> bool {
        let j = lock(&self.inner.queue).pop_front();
        match j {
            Some(j) => {
                j();
                true
            }
            None => false,
        }
    }
    fn push(&self, j: Job) {
        lock(&self.inner.queue).push_back(j);
        self.inner.cv.notify_one();
    }
    /// Fire and forget (a worker panic is swallowed and counted nowhere: use `run` when the result matters).
    pub fn execute(&self, f: impl FnOnce() + Send + 'static) {
        self.push(Box::new(move || {
            let _ = catch_unwind(AssertUnwindSafe(f));
        }));
    }
    /// Runs `f` on a worker; await the result on the UI executor. Dropping the future cancels a queued job.
    pub fn run<T: Send + 'static>(
        &self,
        f: impl FnOnce(&JobCtl) -> T + Send + 'static,
    ) -> WorkFuture<T> {
        let slot = Arc::new(Mutex::new(Slot {
            result: None,
            waker: None,
        }));
        let cancelled = Arc::new(AtomicBool::new(false));
        let (s, c) = (Arc::clone(&slot), Arc::clone(&cancelled));
        self.push(Box::new(move || {
            if c.load(Ordering::SeqCst) {
                return; // canceled before it started
            }
            let ctl = JobCtl(c);
            let r = catch_unwind(AssertUnwindSafe(|| f(&ctl))).map_err(|_| WorkerPanic);
            let w = {
                let mut g = lock(&s);
                g.result = Some(r);
                g.waker.take()
            };
            if let Some(w) = w {
                w.wake();
            }
        }));
        WorkFuture { slot, cancelled }
    }
}
impl Drop for WorkerPool {
    fn drop(&mut self) {
        self.inner.shutdown.store(true, Ordering::SeqCst);
        self.inner.cv.notify_all();
        for t in self.threads.drain(..) {
            let _ = t.join();
        }
        let _ = self.inner.manual;
    }
}
