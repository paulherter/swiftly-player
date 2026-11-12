//! Persistence seams. Swift wrote files (`HomePageModel.swift:248-302`) and `UserDefaults`
//! strings (`SearchHistoryStore`, `LibraryModel.swift:60-75`); here both sit behind small
//! traits so the logic stays pure and tests use the in-memory implementations.

use std::collections::HashMap;
use std::sync::Mutex;

/// Named blobs, like files in one folder (the home page store, one file per account).
pub trait Store: Send + Sync {
    /// The bytes under `name`, `None` if missing or unreadable.
    fn read(&self, name: &str) -> Option<Vec<u8>>;
    /// Writes (replaces) the bytes under `name`; a failure is silent, like `try?` in Swift.
    fn write(&self, name: &str, data: &[u8]);
    /// Removes `name`; a missing entry is fine.
    fn remove(&self, name: &str);
}

/// String settings, like `UserDefaults` (`sortierung.<name>`, `filter.<name>`, `letzteSuchen`).
pub trait KeyValue: Send + Sync {
    /// The string under `key`, `None` if never set.
    fn get(&self, key: &str) -> Option<String>;
    /// Sets the string under `key`.
    fn set(&self, key: &str, value: &str);
}

/// A [`Store`] in memory, for tests.
#[derive(Default)]
pub struct MemoryStore {
    files: Mutex<HashMap<String, Vec<u8>>>,
}

impl MemoryStore {
    /// An empty store.
    pub fn new() -> Self {
        Self::default()
    }
    /// How many entries it holds.
    pub fn len(&self) -> usize {
        self.with(|m| m.len())
    }
    /// Whether it holds nothing.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
    fn with<R>(&self, f: impl FnOnce(&mut HashMap<String, Vec<u8>>) -> R) -> R {
        let mut g = self
            .files
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        f(&mut g)
    }
}

impl Store for MemoryStore {
    fn read(&self, name: &str) -> Option<Vec<u8>> {
        self.with(|m| m.get(name).cloned())
    }
    fn write(&self, name: &str, data: &[u8]) {
        self.with(|m| m.insert(name.to_string(), data.to_vec()));
    }
    fn remove(&self, name: &str) {
        self.with(|m| m.remove(name));
    }
}

/// A [`KeyValue`] in memory, for tests.
#[derive(Default)]
pub struct MemoryKeyValue {
    values: Mutex<HashMap<String, String>>,
}

impl MemoryKeyValue {
    /// An empty set of settings.
    pub fn new() -> Self {
        Self::default()
    }
    fn with<R>(&self, f: impl FnOnce(&mut HashMap<String, String>) -> R) -> R {
        let mut g = self
            .values
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        f(&mut g)
    }
}

impl KeyValue for MemoryKeyValue {
    fn get(&self, key: &str) -> Option<String> {
        self.with(|m| m.get(key).cloned())
    }
    fn set(&self, key: &str, value: &str) {
        self.with(|m| m.insert(key.to_string(), value.to_string()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_store_round_trip() {
        let s = MemoryStore::new();
        assert!(s.is_empty());
        s.write("a", b"x");
        assert_eq!(s.read("a"), Some(b"x".to_vec()));
        s.remove("a");
        s.remove("a");
        assert_eq!(s.read("a"), None);
    }
    #[test]
    fn memory_key_value() {
        let k = MemoryKeyValue::new();
        assert_eq!(k.get("x"), None);
        k.set("x", "1");
        assert_eq!(k.get("x").as_deref(), Some("1"));
    }
}
