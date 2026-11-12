use std::collections::HashMap;
use std::sync::Mutex;

use crate::bundles::{ALL_KINDS, POINTER_KEY, ServerBundles, bundle_storage_key};
use swiftly_jellyfin::ServerKind;

/// Where secrets live: Keychain on Apple, a vault elsewhere. Synchronous; may be called from
/// any thread. Same shape as `swiftly-uniffi`'s foreign `SecretStore`.
pub trait SecretStore: Send + Sync {
    /// The secret under `name`, `None` if there is none.
    fn get(&self, name: &str) -> Option<String>;
    /// Stores (replaces) a secret.
    fn set(&self, name: &str, value: &str);
    /// Removes a secret; a missing one is fine.
    fn remove(&self, name: &str);
}

/// A [`SecretStore`] in memory, for tests and previews.
#[derive(Default)]
pub struct MemorySecretStore(Mutex<HashMap<String, String>>);

impl MemorySecretStore {
    /// An empty store.
    pub fn new() -> Self {
        Self::default()
    }
}

impl SecretStore for MemorySecretStore {
    fn get(&self, name: &str) -> Option<String> {
        self.0.lock().ok()?.get(name).cloned()
    }
    fn set(&self, name: &str, value: &str) {
        if let Ok(mut m) = self.0.lock() {
            m.insert(name.into(), value.into());
        }
    }
    fn remove(&self, name: &str) {
        if let Ok(mut m) = self.0.lock() {
            m.remove(name);
        }
    }
}

/// Reads every bundle and the pointer from the store (`ServerBundles.load`). An entry that
/// cannot be decoded counts as missing.
pub fn load_bundles(store: &dyn SecretStore) -> ServerBundles {
    ServerBundles::load(|key| store.get(key).map(String::into_bytes))
}

/// Writes every kind (removing the empty ones) and the pointer (`ServerBundles.save`).
pub fn save_bundles(store: &dyn SecretStore, bundles: &ServerBundles) {
    for kind in ALL_KINDS {
        let key = bundle_storage_key(kind);
        match bundles
            .bundle(kind)
            .and_then(|b| serde_json::to_string(b).ok())
        {
            Some(text) => store.set(key, &text),
            None => store.remove(key),
        }
    }
    if bundles.is_empty() {
        store.remove(POINTER_KEY);
    } else {
        store.set(POINTER_KEY, kind_name(bundles.active_kind()));
    }
}

pub(crate) fn kind_name(kind: ServerKind) -> &'static str {
    match kind {
        ServerKind::Jellyfin => "jellyfin",
        ServerKind::Emby => "emby",
        ServerKind::Plex => "plex",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Account, AccountBundle};
    use swiftly_jellyfin::{ServerKind, Session};

    fn acc(kind: ServerKind, id: &str) -> Account {
        Account::new(Session {
            access_token: "t".into(),
            user_id: id.into(),
            user_name: "n".into(),
            server_url: "https://s.test".into(),
            kind,
        })
    }

    // ServerBundles: Jellyfin keeps the key `konten`, others get their own.
    #[test]
    fn save_and_load_roundtrip_with_pointer() {
        let store = MemorySecretStore::new();
        let mut b = ServerBundles::default();
        b.set(
            Some(AccountBundle::new(acc(ServerKind::Jellyfin, "1"))),
            ServerKind::Jellyfin,
        );
        b.set(
            Some(AccountBundle::new(acc(ServerKind::Emby, "2"))),
            ServerKind::Emby,
        );
        b.switch_to(ServerKind::Emby);
        save_bundles(&store, &b);
        assert!(store.get("konten").is_some());
        assert!(store.get("konten.emby").is_some());
        assert!(store.get("konten.plex").is_none());
        assert_eq!(store.get("aktiveArt").as_deref(), Some("emby"));
        let back = load_bundles(&store);
        assert_eq!(back, b);
        assert_eq!(back.kinds(), vec![ServerKind::Jellyfin, ServerKind::Emby]);
    }

    #[test]
    fn current_kind_losing_its_bundle_hands_over() {
        let mut b = ServerBundles::default();
        b.set(
            Some(AccountBundle::new(acc(ServerKind::Jellyfin, "1"))),
            ServerKind::Jellyfin,
        );
        b.set(
            Some(AccountBundle::new(acc(ServerKind::Plex, "2"))),
            ServerKind::Plex,
        );
        b.switch_to(ServerKind::Plex);
        b.set(None, ServerKind::Plex);
        assert_eq!(b.active_kind(), ServerKind::Jellyfin);
        b.switch_to(ServerKind::Emby);
        assert_eq!(b.active_kind(), ServerKind::Jellyfin);
    }

    #[test]
    fn broken_entry_counts_as_missing_and_empty_save_clears() {
        let store = MemorySecretStore::new();
        store.set("konten", "kein JSON");
        store.set("aktiveArt", "plex");
        let b = load_bundles(&store);
        assert!(b.is_empty());
        save_bundles(&store, &b);
        assert!(store.get("konten").is_none() && store.get("aktiveArt").is_none());
    }

    #[test]
    fn plex_account_key_uses_the_machine() {
        let mut a = acc(ServerKind::Plex, "u");
        a.plex = Some(swiftly_plex::PlexSessionDetails::new("m1", "Box", "tok"));
        assert_eq!(a.account_key(), "plex:m1|u");
        assert_eq!(a.server_identity(), "plex:m1");
        let json = serde_json::to_string(&a).expect("enc");
        assert_eq!(serde_json::from_str::<Account>(&json).expect("dec"), a);
        assert_eq!(
            acc(ServerKind::Emby, "u").account_key(),
            "emby:https://s.test|u"
        );
    }
}
