//! Storage the host implements: Keychain and `UserDefaults` on Apple (ARCHITECTURE.md D3,
//! Storage). Trait methods are synchronous and may be called from any thread.

use std::sync::Arc;

use swiftly_library::Store;

/// Secrets (access tokens). Apple: Keychain, service `de.paulherter.swiftly`.
#[uniffi::export(with_foreign)]
pub trait SecretStore: Send + Sync {
    /// The secret under `name`, `None` if there is none.
    fn get(&self, name: String) -> Option<String>;
    /// Stores (replaces) a secret.
    fn set(&self, name: String, value: String);
    /// Removes a secret; a missing one is fine.
    fn remove(&self, name: String);
}

/// Small values by key, as bytes. Apple: `UserDefaults`. The home page snapshot lives here,
/// one value per account.
#[uniffi::export(with_foreign)]
pub trait KeyValueStore: Send + Sync {
    /// The bytes under `key`, `None` if never set.
    fn get(&self, key: String) -> Option<Vec<u8>>;
    /// Stores (replaces) the bytes under `key`.
    fn set(&self, key: String, value: Vec<u8>);
    /// Removes `key`; a missing one is fine.
    fn remove(&self, key: String);
}

/// The host's key-value store as the named blobs `swiftly-library` persists.
pub(crate) struct Blobs(pub(crate) Arc<dyn KeyValueStore>);

impl Store for Blobs {
    fn read(&self, name: &str) -> Option<Vec<u8>> {
        self.0.get(name.to_owned())
    }
    fn write(&self, name: &str, data: &[u8]) {
        self.0.set(name.to_owned(), data.to_vec());
    }
    fn remove(&self, name: &str) {
        self.0.remove(name.to_owned());
    }
}
