//! The last answer of every Seerr read, kept in the core's cache, so a Seerr screen paints what it last saw at once
//! and the live read then replaces it (stale while revalidate, like the Jellyfin lists).

use std::sync::Arc;

use swiftly_cache::Scope;
use swiftly_seerr::BodyStash;

use crate::ViewCache;

/// The kind the answers are stored under.
const KIND: &str = "seerr-body";

/// The stash of one Seerr connection over the core's cache; the scope is the connection's own (address and session),
/// so two profiles on one Seerr never see each other's answers.
pub struct SeerrStash {
    cache: ViewCache,
    scope: Scope,
}

impl SeerrStash {
    /// The stash of the connection `address` / `cookie` over `cache`.
    pub fn for_connection(cache: ViewCache, address: &str, cookie: &str) -> Arc<dyn BodyStash> {
        Arc::new(Self {
            cache,
            scope: Scope(format!("seerr:{address}:{cookie}")),
        })
    }
}

impl BodyStash for SeerrStash {
    fn get(&self, key: &str) -> Option<Vec<u8>> {
        let row = self
            .cache
            .entity_cache()
            .get_entity(&self.scope, KIND, key)?;
        Some(row.data.to_vec())
    }

    fn put(&self, key: &str, body: &[u8]) {
        let cache = self.cache.entity_cache();
        let ticket = cache.ticket(&self.scope);
        let _ = cache.put_entities(&ticket, KIND, &[(key.to_owned(), body.to_vec())]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_cache::{CacheConfig, EntityCache};

    #[test]
    fn answers_round_trip_per_connection_and_an_empty_body_is_kept() {
        let cache = ViewCache::new(EntityCache::in_memory(CacheConfig::default()).unwrap());
        let a = SeerrStash::for_connection(cache.clone(), "https://s.test", "sid=1");
        let b = SeerrStash::for_connection(cache, "https://s.test", "sid=2");
        assert_eq!(a.get("request?take=20"), None);
        a.put("request?take=20", b"{\"x\":1}");
        a.put("movie/9", b"");
        assert_eq!(a.get("request?take=20").unwrap(), b"{\"x\":1}");
        assert_eq!(a.get("movie/9"), Some(Vec::new()));
        assert_eq!(b.get("request?take=20"), None);
    }
}
