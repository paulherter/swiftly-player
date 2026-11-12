//! `Inbox<Msg>`: typed messages from background services into the UI thread, drained at the start of each frame.
use crate::channel::{Receiver, Sender, unbounded_with_wake};

/// UI-side end; hand `sender()` clones to services. `wake` runs on the sending thread (it wakes the event loop).
pub struct Inbox<Msg> {
    tx: Sender<Msg>,
    rx: Receiver<Msg>,
}

impl<Msg> Inbox<Msg> {
    pub fn new(wake: impl Fn() + Send + Sync + 'static) -> Self {
        let (tx, rx) = unbounded_with_wake(wake);
        Inbox { tx, rx }
    }

    pub fn sender(&self) -> Sender<Msg> {
        self.tx.clone()
    }

    /// Takes every queued message in send order. Call once at frame start, outside any root borrow where possible.
    pub fn drain(&mut self) -> Vec<Msg> {
        std::iter::from_fn(|| self.rx.try_next()).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn drain_returns_messages_in_order_and_empties_the_inbox() {
        let mut inbox = Inbox::new(|| {});
        let tx = inbox.sender();
        tx.send(1);
        tx.send(2);
        assert_eq!(inbox.drain(), vec![1, 2]);
        assert!(inbox.drain().is_empty());
    }

    #[test]
    fn every_send_from_any_thread_calls_the_wake_callback() {
        let wakes = Arc::new(AtomicUsize::new(0));
        let w = Arc::clone(&wakes);
        let mut inbox = Inbox::new(move || {
            w.fetch_add(1, Ordering::SeqCst);
        });
        let tx = inbox.sender();
        std::thread::spawn(move || {
            tx.send("a");
            tx.send("b");
        })
        .join()
        .ok();
        assert_eq!(wakes.load(Ordering::SeqCst), 2);
        assert_eq!(inbox.drain(), vec!["a", "b"]);
    }
}
