//! The view models' door to `swiftly-cache`: stale-while-revalidate for lists and titles.
//!
//! A screen paints what is stored for its account at once (`read_*`), then fetches as it always
//! did and stores the answer (`write_*`, which says whether anything differs, so an unchanged
//! answer does not redraw). Everything is per account: the scope is the account key (address
//! and user), a read never crosses scopes, and a dropped scope (logout) voids the tickets of
//! fetches that were still on their way.
//!
//! Lists and titles are stored under different kinds: a list row is a slim tile (no overview),
//! a title is the full answer with its `MediaSources`.

use std::sync::Arc;

use swiftly_cache::{CacheChange, EntityCache, Scope, Ticket};
use swiftly_library::Store;
use swiftly_model::Item;

use crate::account::AccountRef;

const TILE: &str = "tile";
const TITLE: &str = "title";

/// A stored list of tiles.
#[derive(Debug, Clone, PartialEq)]
pub struct CachedPage {
    /// The items in server order.
    pub items: Vec<Item>,
    /// The server's total, if it gave one.
    pub total: Option<u64>,
    /// An event marked it out of date (it still paints).
    pub stale: bool,
}

/// Shared handle on the cache; cheap to clone.
#[derive(Clone)]
pub struct ViewCache {
    cache: EntityCache,
}

impl ViewCache {
    /// Wraps the core's cache.
    pub fn new(cache: EntityCache) -> Self {
        Self { cache }
    }

    /// The underlying cache (events, wipes, sizes).
    pub fn entity_cache(&self) -> &EntityCache {
        &self.cache
    }

    /// The scope of an account: address and user, never the token.
    pub fn scope(account: &AccountRef) -> Scope {
        Scope(account.key())
    }

    /// A ticket for a fetch about to start.
    pub fn ticket(&self, scope: &Scope) -> Ticket {
        self.cache.ticket(scope)
    }

    /// The stored list `key` of the scope, painted from the stored tiles. `None` if the list or
    /// any of its tiles is missing or unreadable (a partial list never paints).
    pub fn read_page(&self, scope: &Scope, key: &str) -> Option<CachedPage> {
        let list = self.cache.get_list(scope, key)?;
        let rows = self.cache.get_entities(scope, TILE, &list.ids);
        let mut items = Vec::with_capacity(rows.len());
        let mut stale = list.stale;
        for row in rows {
            let row = row?;
            stale |= row.stale;
            items.push(serde_json::from_slice::<Item>(&row.data).ok()?);
        }
        Some(CachedPage {
            items,
            total: list.total,
            stale,
        })
    }

    /// Stores a fresh list. Returns whether anything differs from what was stored (order, ids,
    /// total or any tile's content); `true` when nothing was stored before. `ticket` was taken before
    /// the fetch started, so an answer that outlives a logout is not written back.
    pub fn write_page(
        &self,
        ticket: &Ticket,
        key: &str,
        items: &[Item],
        total: Option<u64>,
    ) -> bool {
        let scope = ticket.scope();
        let ids: Vec<String> = items.iter().map(|i| i.id.clone()).collect();
        let before = self.cache.get_entities(scope, TILE, &ids);
        let rows: Vec<(String, Vec<u8>)> = items
            .iter()
            .filter_map(|i| Some((i.id.clone(), serde_json::to_vec(i).ok()?)))
            .collect();
        let content_changed = rows.iter().zip(&before).any(|((_, now), old)| {
            old.as_ref()
                .is_none_or(|o| o.data.as_ref() != now.as_slice())
        });
        if self.cache.put_entities(ticket, TILE, &rows).is_err() {
            return true;
        }
        match self.cache.put_list(ticket, key, &ids, total) {
            Ok(diff) => content_changed || !diff.is_empty(),
            Err(_) => true,
        }
    }

    /// The stored full title.
    pub fn read_title(&self, scope: &Scope, id: &str) -> Option<Item> {
        let row = self.cache.get_entity(scope, TITLE, id)?;
        serde_json::from_slice(&row.data).ok()
    }

    /// Stores a full title. `ticket` was taken before the fetch started.
    pub fn write_title(&self, ticket: &Ticket, item: &Item) {
        if let Ok(bytes) = serde_json::to_vec(item) {
            let _ = self
                .cache
                .put_entities(ticket, TITLE, &[(item.id.clone(), bytes)]);
        }
    }

    /// Calls `f` for every change of the cache until it returns `false`.
    pub fn watch(&self, f: impl Fn(&CacheChange) -> bool + Send + Sync + 'static) {
        self.cache.subscribe_while(f);
    }

    /// The preview blob store of an account: the cache database first, the host's store as the
    /// fallback for a preview written before the cache existed (read once, then it lives here).
    pub fn preview_store(&self, scope: &Scope, host: Arc<dyn Store>) -> Arc<dyn Store> {
        Arc::new(Layered {
            primary: self.cache.blob_store(scope),
            fallback: host,
        })
    }
}

/// The cache database with the host store behind it.
struct Layered {
    primary: swiftly_cache::SqliteStore,
    fallback: Arc<dyn Store>,
}

impl Store for Layered {
    fn read(&self, name: &str) -> Option<Vec<u8>> {
        self.primary.read(name).or_else(|| self.fallback.read(name))
    }
    fn write(&self, name: &str, data: &[u8]) {
        self.primary.write(name, data);
        // The old copy would come back after the cache was cleared; it is replaced, not kept.
        self.fallback.remove(name);
    }
    fn remove(&self, name: &str) {
        self.primary.remove(name);
        self.fallback.remove(name);
    }
}
