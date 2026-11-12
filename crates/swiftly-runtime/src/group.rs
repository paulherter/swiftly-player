//! `TaskGroup`: structured children. Dropping the group (its owner finished or was canceled) cancels every child.
use crate::executor::{JoinError, JoinHandle, spawn_local};
use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll};

pub struct TaskGroup<T> {
    children: Vec<JoinHandle<T>>,
}
impl<T: 'static> TaskGroup<T> {
    pub fn new() -> Self {
        TaskGroup { children: vec![] }
    }
    pub fn spawn(&mut self, f: impl Future<Output = T> + 'static) {
        self.children.push(spawn_local(f));
    }
    pub fn len(&self) -> usize {
        self.children.len()
    }
    pub fn is_empty(&self) -> bool {
        self.children.is_empty()
    }
    /// Next finished child (`for await` over a Swift task group), `None` when the group is empty.
    #[allow(clippy::should_implement_trait)] // returns a future, not an Iterator item
    pub fn next(&mut self) -> NextChild<'_, T> {
        NextChild(self)
    }
    pub fn cancel_all(&self) {
        self.children.iter().for_each(|c| c.cancel());
    }
}
impl<T: 'static> Default for TaskGroup<T> {
    fn default() -> Self {
        Self::new()
    }
}
impl<T> Drop for TaskGroup<T> {
    fn drop(&mut self) {
        self.children.iter().for_each(|c| c.cancel());
    }
}
pub struct NextChild<'a, T>(&'a mut TaskGroup<T>);
impl<T> Future for NextChild<'_, T> {
    type Output = Option<Result<T, JoinError>>;
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let g = &mut self.0;
        if g.children.is_empty() {
            return Poll::Ready(None);
        }
        if let Some(i) = g.children.iter().position(|c| c.is_finished()) {
            let c = g.children.swap_remove(i);
            return Poll::Ready(c.try_take());
        }
        for c in g.children.iter_mut() {
            let _ = Pin::new(c).poll(cx); // registers cx's waker on each child (not finished: Pending)
        }
        Poll::Pending
    }
}
