//! Memory-warning hook of the core: the host reports pressure (iOS memory warning, Android `onTrimMemory`),
//! every registered cache drops what it can rebuild. Disk caches stay; only memory goes.
//!
//! Safety rules: the registry holds `Weak` references (a cache that is gone is skipped), and the registry lock is
//! never held while a cache runs its `trim` (the list is copied first), so a slow or re-entrant cache cannot block
//! the thread that reports the warning or deadlock against a registration.

use std::sync::{Arc, Mutex, PoisonError, Weak};

/// How hard the host asks to give memory back.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrimLevel {
    /// Keep a quarter of the memory budget (iOS warning, Android `TRIM_MEMORY_RUNNING_LOW`).
    Moderate,
    /// Drop everything that can be rebuilt (Android `TRIM_MEMORY_COMPLETE`, a second iOS warning).
    Critical,
}

impl TrimLevel {
    /// Host codes: `0` moderate, anything else critical (a host bug must not turn into "ignore").
    pub fn from_code(code: u8) -> Self {
        if code == 0 {
            Self::Moderate
        } else {
            Self::Critical
        }
    }
}

/// Something that holds rebuildable memory.
pub trait Trim: Send + Sync {
    /// Drop memory according to `level`. Must not block and must not call back into the host.
    fn trim(&self, level: TrimLevel);
}

impl<T: swiftly_net::HttpTransport + 'static> Trim for crate::loader::ImageLoader<T> {
    fn trim(&self, level: TrimLevel) {
        crate::loader::ImageLoader::trim(self, level);
    }
}

/// The list of caches that react to a memory warning.
#[derive(Default)]
pub struct MemoryPressure {
    sinks: Mutex<Vec<Weak<dyn Trim>>>,
}

impl MemoryPressure {
    /// An empty registry.
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds a cache. Only a weak reference is kept.
    pub fn register(&self, sink: &Arc<dyn Trim>) {
        let mut list = self.sinks.lock().unwrap_or_else(PoisonError::into_inner);
        list.retain(|w| w.strong_count() > 0);
        list.push(Arc::downgrade(sink));
    }

    /// Tells every live cache to trim; returns how many were reached. The registry lock is released first.
    pub fn warn(&self, level: TrimLevel) -> usize {
        let live: Vec<Arc<dyn Trim>> = {
            let mut list = self.sinks.lock().unwrap_or_else(PoisonError::into_inner);
            list.retain(|w| w.strong_count() > 0);
            list.iter().filter_map(Weak::upgrade).collect()
        };
        for sink in &live {
            sink.trim(level);
        }
        live.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Probe(AtomicUsize);
    impl Trim for Probe {
        fn trim(&self, _: TrimLevel) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }

    #[test]
    fn warn_reaches_live_sinks_and_skips_dropped_ones() {
        let pressure = MemoryPressure::new();
        let kept = Arc::new(Probe(AtomicUsize::new(0)));
        let kept_dyn = Arc::clone(&kept) as Arc<dyn Trim>;
        pressure.register(&kept_dyn);
        let gone: Arc<dyn Trim> = Arc::new(Probe(AtomicUsize::new(0)));
        pressure.register(&gone);
        drop(gone);
        assert_eq!(pressure.warn(TrimLevel::Critical), 1);
        assert_eq!(kept.0.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_sink_may_register_another_during_trim_without_deadlock() {
        struct Reentrant(Arc<MemoryPressure>);
        impl Trim for Reentrant {
            fn trim(&self, _: TrimLevel) {
                let extra: Arc<dyn Trim> = Arc::new(Probe(AtomicUsize::new(0)));
                self.0.register(&extra);
            }
        }
        let pressure = Arc::new(MemoryPressure::new());
        let sink: Arc<dyn Trim> = Arc::new(Reentrant(Arc::clone(&pressure)));
        pressure.register(&sink);
        assert_eq!(pressure.warn(TrimLevel::Moderate), 1);
    }

    #[test]
    fn unknown_host_codes_mean_critical() {
        assert_eq!(TrimLevel::from_code(0), TrimLevel::Moderate);
        assert_eq!(TrimLevel::from_code(1), TrimLevel::Critical);
        assert_eq!(TrimLevel::from_code(255), TrimLevel::Critical);
    }
}
