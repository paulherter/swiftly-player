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
use std::sync::atomic::{AtomicU64, Ordering};

use swiftly_cache::{CacheChange, CacheConfig, EntityCache, Invalidation, Scope, Ticket};
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
    /// How often the server link came back after a real outage; shared by every clone ([`Self::link_came_back`]).
    links_back: Arc<AtomicU64>,
}

impl ViewCache {
    /// Wraps the core's cache.
    pub fn new(cache: EntityCache) -> Self {
        Self {
            cache,
            links_back: Arc::new(AtomicU64::new(0)),
        }
    }

    /// Opens `core-cache.sqlite` in `dir` (every host does this once, so a page opens complete from what the lists and
    /// earlier visits stored). A file that cannot be opened is reported to `on_trouble` and the cache then lives in
    /// memory; `None` only when even that fails.
    pub fn open_in(dir: Option<&std::path::Path>, on_trouble: impl FnOnce(String)) -> Option<Self> {
        let on_disk = dir.and_then(|dir| {
            std::fs::create_dir_all(dir).ok()?;
            match EntityCache::open(&dir.join("core-cache.sqlite"), CacheConfig::default()) {
                Ok(c) => Some(c),
                Err(e) => {
                    on_trouble(format!(
                        "core: cache file unusable ({e:?}), keeping it in memory"
                    ));
                    None
                }
            }
        });
        on_disk
            .or_else(|| EntityCache::in_memory(CacheConfig::default()).ok())
            .map(Self::new)
    }

    /// The server link came back after a real outage: what was open meanwhile may rest on a failed attempt that a
    /// working link would not repeat (a title that could not switch to its next episode tries again).
    pub fn link_came_back(&self) {
        self.links_back.fetch_add(1, Ordering::SeqCst);
    }

    /// How often [`Self::link_came_back`] was called; an open title compares it with the count it saw before.
    pub fn links_back(&self) -> u64 {
        self.links_back.load(Ordering::SeqCst)
    }

    /// The underlying cache (events, wipes, sizes).
    pub fn entity_cache(&self) -> &EntityCache {
        &self.cache
    }

    /// The scope of an account: address and user, never the token.
    pub fn scope(account: &AccountRef) -> Scope {
        Scope(account.key())
    }

    /// A server event for the account: the cache marks its lists and titles stale. A change of the library also makes
    /// what the account offers around its titles (the collections and their members, [`crate::offered`]) old, so the
    /// next page asks again. Every path of an event goes through here, none to the cache alone.
    pub fn apply_event(&self, account: &AccountRef, event: &Invalidation) {
        if matches!(event, Invalidation::LibraryChanged { .. }) {
            crate::offered::changed(&account.key());
        }
        self.cache.apply_event(&Self::scope(account), event);
    }

    /// Something changed that cannot be named (the polling fallback, a link that was down for a while and missed
    /// events): every list of the account is stale, and so is what it offers around its titles.
    pub fn lists_changed(&self, account: &AccountRef) {
        crate::offered::changed(&account.key());
        self.cache.lists_changed(&Self::scope(account));
    }

    /// Deletes everything kept for the account (sign-out, removed account), the short-term memory of its pages too.
    pub fn drop_account(&self, account: &AccountRef) {
        crate::offered::forget(&account.key());
        self.cache.drop_scope(&Self::scope(account));
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

    /// The stored list entry of a title (what the last list answer said of it); the seed of a page opened from a tile
    /// that has no stored full title yet.
    pub fn read_tile(&self, scope: &Scope, id: &str) -> Option<Item> {
        let row = self.cache.get_entity(scope, TILE, id)?;
        serde_json::from_slice(&row.data).ok()
    }

    /// Keeps what a list answer (a home row, a search) said of its titles, as the seed of a page opened from one of
    /// those tiles later ([`Self::read_tile`]). What an earlier answer knew and this one lacks stays (a slim row drops the
    /// description and the picture marks); what this answer says replaces it. `ticket` was taken before the fetch started.
    pub fn note_tiles(&self, ticket: &Ticket, items: &[Item]) {
        let scope = ticket.scope();
        let ids: Vec<String> = items.iter().map(|i| i.id.clone()).collect();
        let before = self.cache.get_entities(scope, TILE, &ids);
        let rows: Vec<(String, Vec<u8>)> = items
            .iter()
            .zip(before)
            .filter_map(|(item, old)| {
                let old = old.and_then(|row| serde_json::from_slice::<Item>(&row.data).ok());
                let merged = crate::seed::seeded(item.clone(), old);
                Some((item.id.clone(), serde_json::to_vec(&merged).ok()?))
            })
            .collect();
        let _ = self.cache.put_entities(ticket, TILE, &rows);
    }

    /// A stored structure of a title under its own `kind` (a series' seasons and episodes), as the page last saw it.
    pub fn read_json<V: serde::de::DeserializeOwned>(
        &self,
        scope: &Scope,
        kind: &str,
        id: &str,
    ) -> Option<V> {
        let row = self.cache.get_entity(scope, kind, id)?;
        serde_json::from_slice(&row.data).ok()
    }

    /// Stores a structure under `kind`. `ticket` was taken before the fetch started.
    pub fn write_json<V: serde::Serialize>(
        &self,
        ticket: &Ticket,
        kind: &str,
        id: &str,
        value: &V,
    ) {
        if let Ok(bytes) = serde_json::to_vec(value) {
            let _ = self
                .cache
                .put_entities(ticket, kind, &[(id.to_owned(), bytes)]);
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
