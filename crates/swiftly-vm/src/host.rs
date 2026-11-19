use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use swiftly_l10n::Locale;
use swiftly_library::Store;
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport};

/// Runs the effects of a view model. The task must not be polled inside `spawn` (the caller
/// holds a lock); drop-in implementations: a tokio handle, a thread pool.
pub trait Spawner: Send + Sync {
    /// Starts the task and returns at once.
    fn spawn(&self, task: Pin<Box<dyn Future<Output = ()> + Send>>);
}

/// Waits for a time without blocking (a debounce). Separate from [`Host`] so the hosts that
/// only build a `HomeVm` need nothing new; tests pass one they release by hand.
pub trait Sleeper: Send + Sync {
    /// Resolves after `seconds`.
    fn sleep(&self, seconds: f64) -> Pin<Box<dyn Future<Output = ()> + Send>>;
}

/// Seconds on a consistent clock (the `Date` of the Swift code); the 30 s refresh rule reads it.
pub trait Clock: Send + Sync {
    /// Now, in seconds.
    fn now(&self) -> f64;
}

/// Wall-clock seconds since 1970.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> f64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64())
    }
}

/// How old something stamped at `at` is at `now`, both read from the host's [`Clock`]. The age of a remembered answer is
/// always measured on that clock and never on `std::time::Instant`: on Apple `Instant` does not count the time the
/// device sleeps, so after a night in the background an answer from the evening would still count as a minute old.
/// A clock that went backwards (`now` before `at`) gives [`Duration::MAX`]: nothing can be said about the age, so it is
/// old.
pub(crate) fn age(now: f64, at: f64) -> Duration {
    if now >= at {
        Duration::try_from_secs_f64(now - at).unwrap_or(Duration::MAX)
    } else {
        Duration::MAX
    }
}

/// What a view model takes from its host.
#[derive(Clone)]
pub struct Host {
    /// Runs effects.
    pub spawner: Arc<dyn Spawner>,
    /// The time.
    pub clock: Arc<dyn Clock>,
    /// Where the home page preview lives (one blob per account).
    pub store: Arc<dyn Store>,
    /// Language of the display text.
    pub locale: Locale,
    /// Shown in the server's device list.
    pub device_name: String,
    /// App version sent in the `Authorization` header.
    pub client_version: String,
    /// The persistent cache (first paint from disk, refresh in the background); `None`: every
    /// screen loads from the server only, as before the cache existed.
    pub cache: Option<crate::cache::ViewCache>,
}

impl Host {
    /// Runs `task` and calls `on_panic` if it panics, so a screen can show an error instead of waiting for an answer that
    /// never comes (the lost task left it on its loading tiles for good). The spawner keeps its worker either way.
    pub(crate) fn spawn_guarded(
        &self,
        task: Pin<Box<dyn Future<Output = ()> + Send>>,
        on_panic: impl FnOnce() + Send + 'static,
    ) {
        use futures_util::FutureExt;
        self.spawner.spawn(Box::pin(async move {
            if std::panic::AssertUnwindSafe(task)
                .catch_unwind()
                .await
                .is_err()
            {
                on_panic();
            }
        }));
    }

    /// Where the preview of the account `key` lives: the cache database (with the host store as
    /// the fallback for one written before) or, without a cache, the host store alone.
    pub(crate) fn preview_store(&self, key: &str) -> Arc<dyn Store> {
        match &self.cache {
            Some(cache) => cache.preview_store(
                &swiftly_cache::Scope(key.to_owned()),
                Arc::clone(&self.store),
            ),
            None => Arc::clone(&self.store),
        }
    }
}

/// A transport shared by the clients of several accounts.
pub struct Shared<T>(pub Arc<T>);

impl<T: HttpTransport> HttpTransport for Shared<T> {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl Future<Output = Result<HttpResponse, ErrorKind>> + Send {
        self.0.send(request)
    }
}

/// A host clock for tests that can jump ahead: the device sleeps through a night while the runtime's own clock
/// (`Instant`) stands still.
#[cfg(test)]
pub(crate) struct JumpClock(std::sync::Mutex<f64>);

#[cfg(test)]
impl JumpClock {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self(std::sync::Mutex::new(1_000_000.0)))
    }

    /// The device sleeps (or simply waits) this long.
    pub(crate) fn sleep_through(&self, seconds: f64) {
        *self.0.lock().unwrap() += seconds;
    }
}

#[cfg(test)]
impl Clock for JumpClock {
    fn now(&self) -> f64 {
        *self.0.lock().unwrap()
    }
}

#[cfg(test)]
mod age_tests {
    use super::*;

    #[test]
    fn the_age_is_the_difference_on_the_host_clock() {
        assert_eq!(age(110.5, 100.0), Duration::from_millis(10_500));
        assert_eq!(age(100.0, 100.0), Duration::ZERO);
    }

    #[test]
    fn a_clock_that_went_backwards_makes_it_old() {
        assert_eq!(age(99.0, 100.0), Duration::MAX);
        assert_eq!(age(f64::NAN, 100.0), Duration::MAX);
    }
}
