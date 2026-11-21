//! One signal per account for a host that draws its lists itself: "the account's lists went stale".
//!
//! The core reloads Home and a library grid on its own when the server socket says another device changed something
//! (`UserDataChanged`, `LibraryChanged`), after a link that really dropped, and after a delete from the server. The view
//! models listen to the cache for that (`CacheChange::ListsStale`). A host that reads its pages one-shot through the
//! legacy calls has no view model to ask, so it listens here: [`StaleLists::version`] says where the count is, and
//! [`StaleLists::after`] resolves once it moves past what the host has seen (bursts coalesce into one answer) and
//! returns when the host drops it. The host then reloads its own page and keeps the rows on screen meanwhile.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};

use crate::account::AccountRef;
use crate::bell::Bell;
use crate::cache::ViewCache;

/// The per-account counters of "the lists went stale", fed by one cache listener.
pub struct StaleLists {
    bells: Mutex<HashMap<String, Arc<Bell>>>,
}

impl StaleLists {
    /// Listens to `cache`; the listener leaves the cache when this is dropped.
    pub fn watch(cache: &ViewCache) -> Arc<Self> {
        let this = Arc::new(Self {
            bells: Mutex::new(HashMap::new()),
        });
        let weak = Arc::downgrade(&this);
        cache.watch(move |change| {
            let Some(this) = weak.upgrade() else {
                return false;
            };
            if let swiftly_cache::CacheChange::ListsStale(scope) = change {
                this.bell(&scope.0).bump(&[0]);
            }
            true
        });
        this
    }

    fn bell(&self, key: &str) -> Arc<Bell> {
        let mut bells = self.bells.lock().unwrap_or_else(PoisonError::into_inner);
        Arc::clone(bells.entry(key.to_owned()).or_insert_with(Bell::new))
    }

    /// Where the count of the account is now; a host asks first, then waits for more than this.
    pub fn version(&self, account: &AccountRef) -> u64 {
        self.bell(&account.key()).version()
    }

    /// Resolves with the new count once it is past `seen`: at once if it already is, else at the next change.
    pub async fn after(&self, account: &AccountRef, seen: u64) -> u64 {
        self.bell(&account.key()).changed(seen).await.version
    }
}
