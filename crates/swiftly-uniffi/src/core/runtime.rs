//! The runtime the core's view model effects run on: a small multi-thread tokio runtime owned by
//! the core, so parsing, sorting and tile building of several screens run in parallel and the
//! timers (debounce, retry, deadline) keep their time while one screen does heavy work.
//!
//! UniFFI's own async glue (`async_runtime = "tokio"`) still uses the `async-compat` runtime for
//! the exported `async fn`s; those only await.
//!
//! Rules kept here: no lock is held across an `.await` or a foreign call (the spawner holds none);
//! queues are bounded (the blocking pool has a fixed size, the layer bounds waiters per host).

use std::future::Future;
use std::num::NonZeroUsize;
use std::pin::Pin;

use swiftly_net::{Priority, RequestOptions, scoped};
use swiftly_vm::Spawner;

/// Worker threads for this device: 2-4 on phones and TVs, more on desktops. `SWIFTLY_CORE_WORKERS`
/// overrides it (benchmarks, soak runs).
pub(crate) fn worker_count() -> usize {
    if let Some(n) = std::env::var("SWIFTLY_CORE_WORKERS")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|n| *n > 0)
    {
        return n;
    }
    let cores = std::thread::available_parallelism().map_or(2, NonZeroUsize::get);
    if cfg!(any(
        target_os = "ios",
        target_os = "tvos",
        target_os = "android"
    )) {
        (cores / 2).clamp(2, 4)
    } else {
        cores.clamp(2, 8)
    }
}

/// The owned runtime. Dropping it stops the workers without waiting for pending tasks.
pub(crate) struct CoreRuntime {
    runtime: Option<tokio::runtime::Runtime>,
    handle: tokio::runtime::Handle,
}

impl CoreRuntime {
    pub(crate) fn new(workers: usize) -> std::io::Result<Self> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(workers)
            .max_blocking_threads(4)
            .thread_name("swiftly-core")
            .enable_time()
            .build()?;
        let handle = runtime.handle().clone();
        Ok(Self {
            runtime: Some(runtime),
            handle,
        })
    }

    pub(crate) fn handle(&self) -> &tokio::runtime::Handle {
        &self.handle
    }
}

impl Drop for CoreRuntime {
    fn drop(&mut self) {
        if let Some(runtime) = self.runtime.take() {
            runtime.shutdown_background();
        }
    }
}

/// Runs view model effects on `handle`. Every effect belongs to a screen that is showing, so its
/// requests go out as `Priority::Visible` (ahead of prefetch and background work).
pub(crate) struct CoreSpawner {
    pub(crate) handle: tokio::runtime::Handle,
    /// Keeps an owned runtime alive as long as a view model can still spawn.
    pub(crate) _owner: Option<std::sync::Arc<CoreRuntime>>,
}

impl Spawner for CoreSpawner {
    fn spawn(&self, task: Pin<Box<dyn Future<Output = ()> + Send>>) {
        // Detached on purpose: a view model aborts its own runs.
        drop(self.handle.spawn(scoped(
            RequestOptions::with_priority(Priority::Visible),
            task,
        )));
    }
}
