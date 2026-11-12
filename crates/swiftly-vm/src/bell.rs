#[cfg(swiftly_loom)]
use loom::sync::atomic::{AtomicU32, Ordering};
#[cfg(swiftly_loom)]
use loom::sync::{Mutex, MutexGuard};
use std::future::Future;
use std::pin::Pin;
#[cfg(not(swiftly_loom))]
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, PoisonError};
#[cfg(not(swiftly_loom))]
use std::sync::{Mutex, MutexGuard};
use std::task::{Context, Poll, Waker};

/// Bits of [`Change::parts`].
pub mod part {
    /// The rails part.
    pub const RAILS: u32 = 1;
    /// The status part.
    pub const STATUS: u32 = 2;
    /// The grid part of a library view model (same bit as [`RAILS`]).
    pub const GRID: u32 = 1;
    /// The result groups of a search view model (same bit as [`RAILS`]).
    pub const RESULTS: u32 = 1;
    /// The recent searches of a search view model.
    pub const RECENTS: u32 = 4;
    /// The head of a detail page (title, facts, image, overview).
    pub const DETAIL_HERO: u32 = 1;
    /// The play button and the watched / watchlist state of a detail page.
    pub const DETAIL_ACTIONS: u32 = 2;
    /// Cast, extras and similar titles of a detail page.
    pub const DETAIL_BOTTOM: u32 = 4;
    /// The season list of a series page.
    pub const SERIES_SEASONS: u32 = 1;
    /// The episode list of a series page.
    pub const SERIES_EPISODES: u32 = 2;
    /// The main button and the watched / watchlist state of a series page.
    pub const SERIES_BUTTON: u32 = 4;
    /// Cast, extras and similar titles of a series page.
    pub const SERIES_MORE: u32 = 8;
    /// The transport part of the player (position, state, notices).
    pub const PLAYER_TRANSPORT: u32 = 1;
    /// The controls part of the player.
    pub const PLAYER_CONTROLS: u32 = 2;
    /// The track panel of the player.
    pub const PLAYER_TRACKS: u32 = 4;
    /// The skip button / next-episode card of the player.
    pub const PLAYER_OFFER: u32 = 8;
    /// How many parts the view model with most parts has (series: seasons, episodes, button, more).
    pub(crate) const COUNT: usize = 4;
}

/// What [`Changed`] answers: the view model is at `version`, and these parts are newer than
/// the `seen` the observer passed in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Change {
    /// The version of the view model.
    pub version: u64,
    /// Bit mask of the parts that changed after `seen` (see [`part`]).
    pub parts: u32,
}

struct BellState {
    version: u64,
    parts: [u64; part::COUNT],
    wakers: Vec<Waker>,
}

/// The version counter of a view model and the observers parked on it. Runtime-free: any
/// executor can poll [`Changed`].
pub(crate) struct Bell {
    state: Mutex<BellState>,
    waiting: AtomicU32,
}

impl Bell {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(BellState {
                version: 1,
                parts: [1; part::COUNT],
                wakers: Vec::new(),
            }),
            waiting: AtomicU32::new(0),
        })
    }

    fn lock(&self) -> MutexGuard<'_, BellState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The parts with these indices changed: moves the version and wakes every observer.
    pub(crate) fn bump(&self, changed: &[usize]) -> u64 {
        let (version, wakers) = {
            let mut state = self.lock();
            state.version += 1;
            let version = state.version;
            for &index in changed {
                if let Some(slot) = state.parts.get_mut(index) {
                    *slot = version;
                }
            }
            (version, std::mem::take(&mut state.wakers))
        };
        for waker in wakers {
            waker.wake();
        }
        version
    }

    pub(crate) fn version(&self) -> u64 {
        self.lock().version
    }

    pub(crate) fn waiting(&self) -> u32 {
        self.waiting.load(Ordering::SeqCst)
    }

    pub(crate) fn changed(self: &Arc<Self>, seen: u64) -> Changed {
        self.waiting.fetch_add(1, Ordering::SeqCst);
        Changed {
            bell: Arc::clone(self),
            seen,
        }
    }
}

/// Resolves at once if the view model is newer than `seen`, else when it next changes (several
/// changes coalesce into one answer). Dropping it, as a cancelled `Task` does, unparks it.
pub struct Changed {
    bell: Arc<Bell>,
    seen: u64,
}

impl Future for Changed {
    type Output = Change;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Change> {
        let mut state = self.bell.lock();
        if state.version > self.seen {
            let parts = state
                .parts
                .iter()
                .enumerate()
                .filter(|&(_, &v)| v > self.seen)
                .fold(0, |mask, (i, _)| mask | (1 << i));
            return Poll::Ready(Change {
                version: state.version,
                parts,
            });
        }
        if !state.wakers.iter().any(|w| w.will_wake(cx.waker())) {
            state.wakers.push(cx.waker().clone());
        }
        Poll::Pending
    }
}

impl Drop for Changed {
    fn drop(&mut self) {
        self.bell.waiting.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Model checks (`RUSTFLAGS="--cfg swiftly_loom" cargo test -p swiftly-vm --lib loom_`): every interleaving of a bump and an observer.
#[cfg(all(test, swiftly_loom))]
mod loom_tests {
    use super::*;

    #[test]
    fn loom_an_observer_never_misses_a_bump() {
        loom::model(|| {
            let bell = Bell::new();
            let seen = bell.version();
            let ringer = Arc::clone(&bell);
            let t = loom::thread::spawn(move || {
                ringer.bump(&[0]);
            });
            // Parks until the bump lands; a lost wake-up is a deadlock that loom reports.
            let change = loom::future::block_on(bell.changed(seen));
            assert!(change.version > seen);
            assert_eq!(change.parts & 1, 1);
            t.join().expect("ringer");
            assert_eq!(
                bell.waiting(),
                0,
                "dropping the future unparks the observer"
            );
        });
    }

    #[test]
    fn loom_two_observers_and_two_bumps_both_wake_and_coalesce() {
        loom::model(|| {
            let bell = Bell::new();
            let a = {
                let bell = Arc::clone(&bell);
                loom::thread::spawn(move || loom::future::block_on(bell.changed(1)).version)
            };
            let b = {
                let bell = Arc::clone(&bell);
                loom::thread::spawn(move || loom::future::block_on(bell.changed(1)).version)
            };
            bell.bump(&[0]);
            bell.bump(&[1]);
            assert!(a.join().expect("a") >= 2);
            assert!(b.join().expect("b") >= 2);
            assert_eq!(bell.version(), 3);
        });
    }
}
