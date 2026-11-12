//! Clocks. The executor never reads the system time directly: tests inject `FakeClock`.
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

pub trait Clock: Send + Sync {
    /// Monotonic time since the clock started.
    fn now(&self) -> Duration;
}

pub struct SystemClock(Instant);
impl SystemClock {
    pub fn new() -> Self {
        SystemClock(Instant::now())
    }
}
impl Default for SystemClock {
    fn default() -> Self {
        Self::new()
    }
}
impl Clock for SystemClock {
    fn now(&self) -> Duration {
        self.0.elapsed()
    }
}

/// Manually advanced clock (nanoseconds).
#[derive(Clone, Default)]
pub struct FakeClock(Arc<AtomicU64>);
impl FakeClock {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn advance(&self, d: Duration) {
        self.0.fetch_add(d.as_nanos() as u64, Ordering::SeqCst);
    }
    pub fn set(&self, t: Duration) {
        self.0.store(t.as_nanos() as u64, Ordering::SeqCst);
    }
}
impl Clock for FakeClock {
    fn now(&self) -> Duration {
        Duration::from_nanos(self.0.load(Ordering::SeqCst))
    }
}
