//! Unbounded MPSC channel whose receiver is awaited on the UI executor (progress streams from workers).
//! Equivalent of Swift's `AsyncStream` consumed with `for await`.
use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};

struct State<T> {
    q: VecDeque<T>,
    waker: Option<Waker>,
    senders: usize,
}
struct Chan<T> {
    state: Mutex<State<T>>,
    /// Called after every send, on the sending thread (wakes the event loop).
    on_send: Option<Box<dyn Fn() + Send + Sync>>,
}

pub struct Sender<T>(Arc<Chan<T>>);
pub struct Receiver<T>(Arc<Chan<T>>);

pub fn unbounded<T>() -> (Sender<T>, Receiver<T>) {
    make(None)
}

/// Like `unbounded`, plus a callback run after every `send` on the sending thread (e.g. wake the event loop).
pub fn unbounded_with_wake<T>(
    on_send: impl Fn() + Send + Sync + 'static,
) -> (Sender<T>, Receiver<T>) {
    make(Some(Box::new(on_send)))
}

fn make<T>(on_send: Option<Box<dyn Fn() + Send + Sync>>) -> (Sender<T>, Receiver<T>) {
    let state = Mutex::new(State {
        q: VecDeque::new(),
        waker: None,
        senders: 1,
    });
    let c = Arc::new(Chan { state, on_send });
    (Sender(Arc::clone(&c)), Receiver(c))
}

fn lock<T>(c: &Chan<T>) -> std::sync::MutexGuard<'_, State<T>> {
    c.state.lock().unwrap_or_else(|e| e.into_inner())
}

impl<T> Sender<T> {
    pub fn send(&self, v: T) {
        let w = {
            let mut g = lock(&self.0);
            g.q.push_back(v);
            g.waker.take()
        };
        if let Some(w) = w {
            w.wake();
        }
        if let Some(f) = &self.0.on_send {
            f();
        }
    }
}
impl<T> Clone for Sender<T> {
    fn clone(&self) -> Self {
        lock(&self.0).senders += 1;
        Sender(Arc::clone(&self.0))
    }
}
impl<T> Drop for Sender<T> {
    fn drop(&mut self) {
        let w = {
            let mut g = lock(&self.0);
            g.senders -= 1;
            if g.senders == 0 { g.waker.take() } else { None }
        };
        if let Some(w) = w {
            w.wake();
        }
    }
}

impl<T> Receiver<T> {
    /// Next value, or `None` once every sender is gone and the queue is empty.
    #[allow(clippy::should_implement_trait)] // returns a future, not an Iterator item
    pub fn next(&mut self) -> Next<'_, T> {
        Next(self)
    }

    /// Pops the next queued value without waiting (frame-start drains).
    pub fn try_next(&mut self) -> Option<T> {
        lock(&self.0).q.pop_front()
    }
}
pub struct Next<'a, T>(&'a mut Receiver<T>);
impl<T> Future for Next<'_, T> {
    type Output = Option<T>;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<T>> {
        // Like Swift's AsyncStream iterator: a canceled task's `for await` ends (the executor wakes it on cancel).
        if crate::executor::is_cancelled() {
            return Poll::Ready(None);
        }
        let mut g = lock(&self.0.0);
        if let Some(v) = g.q.pop_front() {
            return Poll::Ready(Some(v));
        }
        if g.senders == 0 {
            return Poll::Ready(None);
        }
        g.waker = Some(cx.waker().clone());
        Poll::Pending
    }
}
