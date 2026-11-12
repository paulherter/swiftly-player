//! `ImageSlab.swift` (`ImagePlate`): posters and backgrounds on disk.
//!
//! **No ETag needed.** Which address may go to disk is decided by
//! [`store_key`](crate::store_key::store_key): only with Jellyfin's `tag`. If the image changes
//! on the server the address changes, and the old entry is never hit again.
//!
//! **Cleanup follows the age of the last access.** Reading refreshes the date; cleaning up
//! removes the oldest files until the total is three quarters of the limit, so that not every
//! start cleans up.

use crate::store_key::store_key;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};
use url::Url;

/// FNV-1a, 64 bit, as lower-case hex without padding. Stable across launches.
pub fn file_name(text: &str) -> String {
    let mut value: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in text.bytes() {
        value ^= u64::from(byte);
        value = value.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{value:x}")
}

/// The file name for an image address, `None` without `tag` (`ImagePlate.name`).
pub fn name(url: &Url) -> Option<String> {
    store_key(url).map(|key| file_name(&key))
}

/// A store of image files by name. The core gives each UI the same one.
pub trait DiskCache: Send + Sync {
    /// The bytes, or `None` if missing or empty. A hit counts as a use: it refreshes the date
    /// that [`clean_up`](Self::clean_up) sorts by.
    fn read(&self, name: &str) -> Option<Vec<u8>>;
    /// Stores the bytes; empty data is never written.
    fn write(&self, data: &[u8], name: &str);
    /// Removes the files not used for the longest time until the total is below three quarters
    /// of the limit (only if it is above the limit at all). Returns how many went.
    fn clean_up(&self) -> usize;
}

/// The eviction rule shared by both stores: oldest first while the sum stays above three
/// quarters of the limit. `list` is (name, size, last use); returns the names to remove.
fn eviction(mut list: Vec<(String, u64, SystemTime)>, limit: u64) -> Vec<String> {
    let mut sum: u64 = list
        .iter()
        .fold(0u64, |all, entry| all.saturating_add(entry.1));
    if sum <= limit {
        return Vec::new();
    }
    list.sort_by_key(|entry| entry.2);
    let mut out = Vec::new();
    for (name, size, _) in list {
        if sum <= limit.saturating_mul(3) / 4 {
            break;
        }
        sum = sum.saturating_sub(size);
        out.push(name);
    }
    out
}

/// In-memory [`DiskCache`] for tests and for targets without a cache folder. Uses the same
/// eviction rule; "dates" are a counter that every read or write advances.
#[derive(Debug)]
pub struct MemoryPlate {
    limit: u64,
    inner: Mutex<MemoryInner>,
}

#[derive(Debug, Default)]
struct MemoryInner {
    clock: u64,
    files: HashMap<String, (Vec<u8>, u64)>,
}

impl MemoryPlate {
    /// An empty store with a limit in bytes.
    pub fn new(limit: u64) -> Self {
        Self {
            limit,
            inner: Mutex::new(MemoryInner::default()),
        }
    }

    /// Sets the last-use stamp of one entry (the tests' `setAttributes(modificationDate:)`).
    pub fn set_stamp(&self, name: &str, stamp: u64) {
        if let Ok(mut inner) = self.inner.lock() {
            let known = inner
                .files
                .get_mut(name)
                .map(|file| file.1 = stamp)
                .is_some();
            if known {
                // Later reads and writes must count as newer than any stamp set by hand.
                inner.clock = inner.clock.max(stamp);
            }
        }
    }

    /// How many files it holds.
    pub fn len(&self) -> usize {
        self.inner
            .lock()
            .map(|inner| inner.files.len())
            .unwrap_or(0)
    }

    /// Whether it holds no file.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl DiskCache for MemoryPlate {
    fn read(&self, name: &str) -> Option<Vec<u8>> {
        let mut inner = self.inner.lock().ok()?;
        inner.clock += 1;
        let stamp = inner.clock;
        let file = inner.files.get_mut(name)?;
        if file.0.is_empty() {
            return None;
        }
        file.1 = stamp;
        Some(file.0.clone())
    }

    fn write(&self, data: &[u8], name: &str) {
        if data.is_empty() {
            return;
        }
        if let Ok(mut inner) = self.inner.lock() {
            inner.clock += 1;
            let stamp = inner.clock;
            inner.files.insert(name.to_string(), (data.to_vec(), stamp));
        }
    }

    fn clean_up(&self) -> usize {
        let Ok(mut inner) = self.inner.lock() else {
            return 0;
        };
        let list = inner
            .files
            .iter()
            .map(|(name, (data, stamp))| {
                (
                    name.clone(),
                    data.len() as u64,
                    SystemTime::UNIX_EPOCH + Duration::from_secs(*stamp),
                )
            })
            .collect();
        let gone = eviction(list, self.limit);
        for name in &gone {
            inner.files.remove(name);
        }
        gone.len()
    }
}
/// What the folder holds, name to (size, last use). Built by one directory scan at the first clean-up, then kept in
/// step by reads and writes, so later clean-ups never list the folder again.
type Index = HashMap<String, (u64, SystemTime)>;

/// How stale a file's date may get before a read writes the new date to disk (so it survives a restart).
/// Within this window the date lives in the index only; that saves a file open and a date change per read.
const TOUCH_AFTER: Duration = Duration::from_secs(300);

/// [`DiskCache`] in a folder of the cache directory (`ImagePlate`). Errors are swallowed like
/// the Swift `try?`: a failed write is a missing cache entry, not a failure. The folder is listed once (at
/// the first clean-up); after that an index in memory answers sizes and dates.
#[derive(Debug, Clone)]
pub struct FolderPlate {
    folder: PathBuf,
    limit: u64,
    index: Arc<Mutex<Option<Index>>>,
}

impl FolderPlate {
    /// Opens the folder (created if missing) with a limit in bytes.
    pub fn new(folder: impl Into<PathBuf>, limit: u64) -> Self {
        let folder = folder.into();
        let _ = fs::create_dir_all(&folder);
        Self {
            folder,
            limit,
            index: Arc::new(Mutex::new(None)),
        }
    }

    /// The folder.
    pub fn folder(&self) -> &Path {
        &self.folder
    }

    /// The limit in bytes.
    pub fn limit(&self) -> u64 {
        self.limit
    }

    fn index(&self) -> std::sync::MutexGuard<'_, Option<Index>> {
        self.index
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn scan(&self) -> Index {
        let Ok(entries) = fs::read_dir(&self.folder) else {
            return Index::new();
        };
        entries
            .filter_map(|entry| {
                let entry = entry.ok()?;
                let meta = entry.metadata().ok()?;
                let date = meta.modified().unwrap_or(SystemTime::UNIX_EPOCH);
                Some((
                    entry.file_name().to_string_lossy().into_owned(),
                    (meta.len(), date),
                ))
            })
            .collect()
    }

    fn touch(&self, name: &str) {
        if let Ok(file) = fs::OpenOptions::new()
            .write(true)
            .open(self.folder.join(name))
        {
            let _ = file.set_modified(SystemTime::now());
        }
    }
}

impl DiskCache for FolderPlate {
    fn read(&self, name: &str) -> Option<Vec<u8>> {
        let data = fs::read(self.folder.join(name))
            .ok()
            .filter(|data| !data.is_empty());
        let now = SystemTime::now();
        let mut guard = self.index();
        let Some(data) = data else {
            if let Some(index) = guard.as_mut() {
                index.remove(name);
            }
            return None;
        };
        match guard.as_mut() {
            Some(index) => {
                let entry = index
                    .entry(name.to_string())
                    .or_insert((data.len() as u64, SystemTime::UNIX_EPOCH));
                let stale = now
                    .duration_since(entry.1)
                    .is_ok_and(|age| age >= TOUCH_AFTER);
                entry.1 = now;
                drop(guard);
                if stale {
                    self.touch(name);
                }
            }
            None => {
                drop(guard);
                self.touch(name);
            }
        }
        Some(data)
    }

    fn write(&self, data: &[u8], name: &str) {
        if data.is_empty() {
            return;
        }
        // Atomic like `Data.write(options: .atomic)`: a reader never sees half a file.
        if swiftly_atomic::write(&self.folder.join(name), data).is_ok()
            && let Some(index) = self.index().as_mut()
        {
            index.insert(name.to_string(), (data.len() as u64, SystemTime::now()));
        }
    }

    fn clean_up(&self) -> usize {
        let mut guard = self.index();
        let index = guard.get_or_insert_with(|| self.scan());
        let list: Vec<(String, u64, SystemTime)> = index
            .iter()
            .map(|(name, (size, date))| (name.clone(), *size, *date))
            .collect();
        // Like the Swift `try?`: a file that cannot be removed still counts as gone.
        let gone = eviction(list, self.limit);
        for name in &gone {
            let _ = fs::remove_file(self.folder.join(name));
            index.remove(name);
        }
        gone.len()
    }
}
