//! The memory side of `NetworkImage.swift` (`ImageCache`): decoded images by cost, least recently
//! used out first. The decoded value is the UI's own type; the cache only does the book-keeping.

use crate::store_key::image_key;
use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;
use url::Url;

/// Which kind of device the budgets are for (`#if os(...)` in the Swift code).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Device {
    /// macOS (and the desktop shells): a window can show many grids at once.
    Mac,
    /// tvOS and Android TV: large tiles, tight memory.
    Tv,
    /// iPhone, iPad, Android.
    Phone,
}

impl Device {
    /// Bytes of decoded images kept in memory (`ImageCache.cacheLimit`).
    pub fn memory_limit(self) -> usize {
        match self {
            Self::Mac => 256 * 1024 * 1024,
            Self::Tv => 64 * 1024 * 1024,
            Self::Phone => 96 * 1024 * 1024,
        }
    }

    /// Longest edge when decoding (`ImageCache.edgesLength`).
    pub fn decode_edge(self) -> u32 {
        match self {
            Self::Mac => 1600,
            Self::Tv | Self::Phone => 1200,
        }
    }

    /// Bytes of images kept on disk (`ImageStore.limit`).
    pub fn disk_limit(self) -> u64 {
        match self {
            Self::Tv => 256 * 1024 * 1024,
            Self::Mac | Self::Phone => 512 * 1024 * 1024,
        }
    }
}

/// How many address-to-key pairs are remembered before the table starts over.
const KEY_CACHE_LIMIT: usize = 2_000;

/// A decoded image costs width times height times four bytes; hits move to the end of the order,
/// so eviction removes the longest unused entry and not the longest stored one.
///
/// The order is a map from a use counter to the key, so a hit, an insert and an eviction cost O(log n) however
/// many pictures are held (a list scan took 6 us per hit at 2000 pictures).
#[derive(Debug)]
pub struct MemoryImageCache<V> {
    known: HashMap<Arc<str>, Entry<V>>,
    /// Use counter to key; the smallest counter is the least recently used.
    order: BTreeMap<u64, Arc<str>>,
    tick: u64,
    used: usize,
    limit: usize,
    /// Rises with every eviction, trim and wipe, so a holder of a key can tell that its picture may be gone.
    generation: u64,
    key_cache: HashMap<String, String>,
}

#[derive(Debug)]
struct Entry<V> {
    value: V,
    bytes: usize,
    tick: u64,
}

impl<V> MemoryImageCache<V> {
    /// An empty cache with a budget in bytes.
    pub fn new(limit: usize) -> Self {
        Self {
            known: HashMap::new(),
            order: BTreeMap::new(),
            tick: 0,
            used: 0,
            limit,
            generation: 0,
            key_cache: HashMap::new(),
        }
    }

    /// The key an address is cached under: without the credential (`key(_:)`), remembered per
    /// address. The table starts over past 2000 entries.
    pub fn key_for(&mut self, url: &Url) -> String {
        if let Some(present) = self.key_cache.get(url.as_str()) {
            return present.clone();
        }
        let new = image_key(url);
        if self.key_cache.len() > KEY_CACHE_LIMIT {
            self.key_cache.clear();
        }
        self.key_cache.insert(url.to_string(), new.clone());
        new
    }

    /// The image, and a hit moves it to the end of the order.
    pub fn get(&mut self, key: &str) -> Option<&V> {
        let entry = self.known.get_mut(key)?;
        if entry.tick != self.tick {
            self.tick += 1;
            if let Some(name) = self.order.remove(&entry.tick) {
                self.order.insert(self.tick, name);
            }
            entry.tick = self.tick;
        }
        Some(&entry.value)
    }

    /// Whether the image is held, without counting a use.
    pub fn contains(&self, key: &str) -> bool {
        self.known.contains_key(key)
    }

    /// Stores an image of `bytes` cost, then evicts from the front until the budget fits again.
    /// An image larger than the whole budget evicts itself, as in Swift. Storing a key that is held replaces
    /// the picture and keeps its place in the order.
    pub fn insert(&mut self, key: &str, value: V, bytes: usize) {
        if let Some(old) = self.known.get_mut(key) {
            self.used = self.used.saturating_sub(old.bytes);
            old.value = value;
            old.bytes = bytes;
        } else {
            self.tick += 1;
            let name: Arc<str> = Arc::from(key);
            self.order.insert(self.tick, Arc::clone(&name));
            self.known.insert(
                name,
                Entry {
                    value,
                    bytes,
                    tick: self.tick,
                },
            );
        }
        self.used = self.used.saturating_add(bytes);
        self.evict_to(self.limit);
    }

    fn evict_to(&mut self, bytes: usize) {
        while self.used > bytes {
            let Some((_, out)) = self.order.pop_first() else {
                break;
            };
            let freed = self.known.remove(&out).map_or(0, |entry| entry.bytes);
            self.used = self.used.saturating_sub(freed);
            self.generation += 1;
        }
    }

    /// Evicts from the front (oldest first) until at most `bytes` are counted. Used by the memory-warning hook.
    pub fn trim_to(&mut self, bytes: usize) {
        self.evict_to(bytes);
    }

    /// The byte budget this cache was built with.
    pub fn limit(&self) -> usize {
        self.limit
    }

    /// Release on a memory warning (`wipe`).
    pub fn wipe(&mut self) {
        self.known.clear();
        self.order.clear();
        self.key_cache.clear();
        self.used = 0;
        self.generation += 1;
    }

    /// Counts up whenever a picture left the cache (eviction, trim, wipe). A UI that remembers the number
    /// next to a key knows a changed number means "ask again", never "keep showing what you have".
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// Bytes currently counted.
    pub fn used(&self) -> usize {
        self.used
    }

    /// Number of images held.
    pub fn len(&self) -> usize {
        self.known.len()
    }

    /// Whether no image is held.
    pub fn is_empty(&self) -> bool {
        self.known.is_empty()
    }
}
