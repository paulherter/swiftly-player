//! `HelloVm`: a view model made of versioned parts, the shape every screen VM will have.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use tokio::sync::watch;

use crate::core::Platform;
use crate::error::CoreError;

/// One part of a view model: a value that is replaced as a whole.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct HelloState {
    pub greeting: String,
    pub count: u32,
}

#[derive(uniffi::Enum, Clone, Debug)]
pub enum HelloIntent {
    Increment,
    Reset,
    SetGreeting { text: String },
}

/// What `changed` reports: the view model is at least this new.
#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq, Eq)]
pub struct HelloChange {
    pub version: u64,
}

#[derive(uniffi::Object)]
pub struct HelloVm {
    platform: Arc<dyn Platform>,
    state: Mutex<Arc<HelloState>>,
    /// The VM version; every intent that changes a part bumps it. Waiters coalesce on it.
    version: watch::Sender<u64>,
    /// Futures currently parked in `changed` (proves a cancelled Task drops its future).
    waiters: Arc<AtomicU32>,
}

impl HelloVm {
    pub(crate) fn new(platform: Arc<dyn Platform>) -> Arc<Self> {
        let (version, _) = watch::channel(1);
        Arc::new(Self {
            platform,
            state: Mutex::new(Arc::new(HelloState {
                greeting: "Hello".to_owned(),
                count: 0,
            })),
            version,
            waiters: Arc::new(AtomicU32::new(0)),
        })
    }
}

/// Counts a parked `changed` future for as long as it lives, also when it is dropped.
struct Waiter(Arc<AtomicU32>);

impl Waiter {
    fn new(counter: &Arc<AtomicU32>) -> Self {
        counter.fetch_add(1, Ordering::SeqCst);
        Self(Arc::clone(counter))
    }
}

impl Drop for Waiter {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

#[uniffi::export]
impl HelloVm {
    pub fn state(&self) -> HelloState {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        HelloState::clone(&state)
    }

    pub fn version(&self) -> u64 {
        *self.version.borrow()
    }

    /// Never blocks; the effect is applied at once and the version moves.
    pub fn send(&self, intent: HelloIntent) {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let mut next = HelloState::clone(&state);
        match intent {
            HelloIntent::Increment => next.count = next.count.saturating_add(1),
            HelloIntent::Reset => next.count = 0,
            HelloIntent::SetGreeting { text } => next.greeting = text,
        }
        if next == **state {
            return;
        }
        *state = Arc::new(next);
        self.version.send_modify(|v| *v += 1);
        self.platform.log("hello: changed".to_owned());
    }

    /// Returns at once when the VM is newer than `seen`, else waits. Cancelling the Swift
    /// `Task` drops this future (xtask patches the generated Swift to call `rust_future_cancel`).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn changed(&self, seen: u64) -> Result<HelloChange, CoreError> {
        let _waiter = Waiter::new(&self.waiters);
        let mut rx = self.version.subscribe();
        loop {
            let version = *rx.borrow_and_update();
            if version > seen {
                return Ok(HelloChange { version });
            }
            if rx.changed().await.is_err() {
                return Err(CoreError::Closed);
            }
        }
    }

    /// Number of futures parked in `changed`.
    pub fn waiters(&self) -> u32 {
        self.waiters.load(Ordering::SeqCst)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Quiet;
    impl Platform for Quiet {
        fn device_name(&self) -> String {
            "test".to_owned()
        }
        fn log(&self, _line: String) {}
        fn cache_dir(&self) -> Option<String> {
            None
        }
    }

    #[tokio::test]
    async fn changed_returns_at_once_when_newer_and_waits_otherwise() {
        let vm = HelloVm::new(Arc::new(Quiet));
        assert_eq!(vm.changed(0).await.ok(), Some(HelloChange { version: 1 }));
        let parked = {
            let vm = Arc::clone(&vm);
            tokio::spawn(async move { vm.changed(1).await })
        };
        tokio::task::yield_now().await;
        assert_eq!(vm.waiters(), 1);
        vm.send(HelloIntent::Increment);
        assert_eq!(
            parked.await.ok().and_then(Result::ok),
            Some(HelloChange { version: 2 })
        );
        assert_eq!(vm.waiters(), 0);
        assert_eq!(vm.state().count, 1);
    }

    #[tokio::test]
    async fn dropping_the_future_unparks_the_waiter() {
        let vm = HelloVm::new(Arc::new(Quiet));
        let parked = {
            let vm = Arc::clone(&vm);
            tokio::spawn(async move { vm.changed(1).await })
        };
        tokio::task::yield_now().await;
        assert_eq!(vm.waiters(), 1);
        parked.abort();
        let _ = parked.await;
        assert_eq!(vm.waiters(), 0);
    }
}
