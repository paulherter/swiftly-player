//! Where the real app keeps its data: secrets (Keychain / Credential Manager, else a 0600 file), settings and small
//! caches as files in the platform config and cache directories.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use swiftly_accounts::SecretStore;
use swiftly_library::{KeyValue, Store};

/// A directory set by a test in this process (see [`set_config_dir_override`]); it wins over the environment.
static CONFIG_DIR_OVERRIDE: Mutex<Option<PathBuf>> = Mutex::new(None);

/// Held while a test sets the override and opens its core, so two tests of one process cannot swap the directory
/// between the two steps.
static OVERRIDE_OPEN: Mutex<()> = Mutex::new(());

/// Points [`config_dir`] at `dir` for the rest of this process (tests that open several cores with their own device
/// ids; changing the environment of a running process is not safe, so they pass the directory here instead).
/// Like `SWIFTLY_CONFIG_DIR` it also turns the system vault off: the secrets go to a file in `dir`.
pub fn set_config_dir_override(dir: &Path) {
    if let Ok(mut slot) = CONFIG_DIR_OVERRIDE.lock() {
        *slot = Some(dir.to_path_buf());
    }
}

/// Sets the override to `dir` and runs `open` (a core that reads the directory while it opens), as one step against
/// other tests of the process doing the same.
pub fn open_in_config_dir<T>(dir: &Path, open: impl FnOnce() -> T) -> T {
    let _one_at_a_time = OVERRIDE_OPEN
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    set_config_dir_override(dir);
    open()
}

/// Whether a test or the environment chose the config directory (`SWIFTLY_CONFIG_DIR` or the override): the secrets
/// then live in a file there, never in the system vault.
fn config_dir_is_chosen() -> bool {
    CONFIG_DIR_OVERRIDE.lock().is_ok_and(|slot| slot.is_some())
        || std::env::var_os("SWIFTLY_CONFIG_DIR").is_some()
}

/// The directory with the settings (`SWIFTLY_CONFIG_DIR` overrides it, for tests and the fixture runs).
pub fn config_dir() -> PathBuf {
    if let Ok(slot) = CONFIG_DIR_OVERRIDE.lock()
        && let Some(d) = slot.as_ref()
    {
        return d.clone();
    }
    if let Some(d) = std::env::var_os("SWIFTLY_CONFIG_DIR") {
        return PathBuf::from(d);
    }
    let home = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .unwrap_or_default();
    if cfg!(target_os = "macos") {
        home.join("Library/Application Support/Swiftly")
    } else if cfg!(windows) {
        std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .unwrap_or(home)
            .join("Swiftly")
    } else {
        std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".config"))
            .join("swiftly")
    }
}

/// The directory with the disposable files.
pub fn cache_dir() -> PathBuf {
    if let Some(d) = std::env::var_os("SWIFTLY_CACHE_DIR") {
        return PathBuf::from(d);
    }
    config_dir().join("cache")
}

/// Saves a setting. A failed write is logged (`crash::note_error`) instead of dropped; the value stays in memory for this
/// session either way (the store keeps it before it writes). `true` when it reached the disk.
pub fn set_logged<S: swiftly_settings::KeyValueStore + ?Sized>(
    store: &S,
    key: &str,
    value: swiftly_settings::Value,
) -> bool {
    set_logged_with(store, key, value, &mut |what, msg| {
        crate::crash::note_error(what, msg)
    })
}

/// [`set_logged`] with the log sink given (tests).
pub fn set_logged_with<S: swiftly_settings::KeyValueStore + ?Sized>(
    store: &S,
    key: &str,
    value: swiftly_settings::Value,
    log: &mut dyn FnMut(&str, &str),
) -> bool {
    match store.set(key, value) {
        Ok(()) => true,
        Err(e) => {
            log("settings write failed", &format!("{key}: {e:?}"));
            false
        }
    }
}

fn write_private(path: &Path, data: &[u8]) {
    let _ = swiftly_atomic::write_private(path, data);
}

/// Secrets in a JSON file readable by the user only. The fallback where no system vault is wired (Linux today) or the
/// vault refuses; not encrypted (see DECISIONS: encrypted-file fallback open).
pub struct FileSecrets {
    path: PathBuf,
    map: Mutex<BTreeMap<String, String>>,
}

impl FileSecrets {
    /// Opens (or starts) the file.
    pub fn open(path: PathBuf) -> FileSecrets {
        let map = std::fs::read(&path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        FileSecrets {
            path,
            map: Mutex::new(map),
        }
    }
    fn with<R>(&self, f: impl FnOnce(&mut BTreeMap<String, String>) -> R) -> R {
        let mut g = self
            .map
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let r = f(&mut g);
        if let Ok(b) = serde_json::to_vec(&*g) {
            write_private(&self.path, &b);
        }
        r
    }
}

impl SecretStore for FileSecrets {
    fn get(&self, name: &str) -> Option<String> {
        self.map.lock().ok()?.get(name).cloned()
    }
    fn set(&self, name: &str, value: &str) {
        self.with(|m| m.insert(name.into(), value.into()));
    }
    fn remove(&self, name: &str) {
        self.with(|m| m.remove(name));
    }
}

static SECRET_BACKEND: std::sync::OnceLock<std::sync::Arc<dyn SecretStore>> =
    std::sync::OnceLock::new();

/// Registers the platform vault (Android Keystore through the Kotlin `SecretStore`); `PlatformSecrets` then uses it
/// for every read and write and keeps no file.
pub fn set_secret_backend(b: std::sync::Arc<dyn SecretStore>) {
    let _ = SECRET_BACKEND.set(b);
}

/// The system vault where there is one (macOS Keychain, Windows Credential Manager); the file store elsewhere or
/// when the vault fails. A value found only in the fallback file stays readable.
pub struct PlatformSecrets {
    file: FileSecrets,
}

static VAULT_FALLBACK: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Whether a secret had to be written to the private file because the system vault refused. The UI can show a hint
/// (once) when this is true.
pub fn vault_fallback_used() -> bool {
    VAULT_FALLBACK.load(std::sync::atomic::Ordering::Relaxed)
}

/// Records the fallback and logs it once per run (never the value). Returns whether this call was the first.
#[allow(dead_code)]
fn note_vault_fallback(name: &str) -> bool {
    let first = !VAULT_FALLBACK.swap(true, std::sync::atomic::Ordering::Relaxed);
    if first {
        eprintln!(
            "swiftly-desktop: the system vault refused the secret {name:?}; it is kept in the private secrets.json instead"
        );
    }
    first
}

const SERVICE: &str = "de.swiftly.player";

impl PlatformSecrets {
    /// The store for this machine.
    pub fn new() -> PlatformSecrets {
        PlatformSecrets {
            file: FileSecrets::open(config_dir().join("secrets.json")),
        }
    }
    /// Whether a system vault is in use on this build.
    pub fn uses_vault() -> bool {
        SECRET_BACKEND.get().is_some()
            || cfg!(any(target_os = "macos", target_os = "windows")) && !config_dir_is_chosen()
    }
}

impl Default for PlatformSecrets {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(any(target_os = "macos", target_os = "windows"))]
impl SecretStore for PlatformSecrets {
    fn get(&self, name: &str) -> Option<String> {
        if let Some(b) = SECRET_BACKEND.get() {
            return b.get(name);
        }
        if Self::uses_vault()
            && let Some(v) = keyring::Entry::new(SERVICE, name)
                .ok()
                .and_then(|e| e.get_password().ok())
        {
            return Some(v);
        }
        self.file.get(name)
    }
    fn set(&self, name: &str, value: &str) {
        if let Some(b) = SECRET_BACKEND.get() {
            return b.set(name, value);
        }
        let stored = Self::uses_vault()
            && keyring::Entry::new(SERVICE, name)
                .and_then(|e| e.set_password(value))
                .is_ok();
        if stored {
            self.file.remove(name);
        } else {
            // The old Swift Windows/Linux apps keep the session in a private file as well (no vault), so the file
            // is the known behaviour, not a new downgrade: but it must never happen silently.
            note_vault_fallback(name);
            self.file.set(name, value);
        }
    }
    fn remove(&self, name: &str) {
        if let Some(b) = SECRET_BACKEND.get() {
            return b.remove(name);
        }
        if Self::uses_vault()
            && let Ok(e) = keyring::Entry::new(SERVICE, name)
        {
            let _ = e.delete_credential();
        }
        self.file.remove(name);
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
impl SecretStore for PlatformSecrets {
    fn get(&self, name: &str) -> Option<String> {
        let _ = SERVICE;
        if let Some(b) = SECRET_BACKEND.get() {
            return b.get(name);
        }
        self.file.get(name)
    }
    fn set(&self, name: &str, value: &str) {
        if let Some(b) = SECRET_BACKEND.get() {
            return b.set(name, value);
        }
        self.file.set(name, value);
    }
    fn remove(&self, name: &str) {
        if let Some(b) = SECRET_BACKEND.get() {
            return b.remove(name);
        }
        self.file.remove(name);
    }
}

/// Blobs (home page preview, small caches) as files in a directory.
pub struct DirStore(pub PathBuf);

impl DirStore {
    fn file(&self, name: &str) -> PathBuf {
        let safe: String = name
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || c == '.' || c == '-' {
                    c
                } else {
                    '_'
                }
            })
            .collect();
        self.0.join(safe)
    }
}

impl Store for DirStore {
    fn read(&self, name: &str) -> Option<Vec<u8>> {
        std::fs::read(self.file(name)).ok()
    }
    fn write(&self, name: &str, data: &[u8]) {
        let p = self.file(name);
        let _ = swiftly_atomic::write(&p, data);
    }
    fn remove(&self, name: &str) {
        let _ = std::fs::remove_file(self.file(name));
    }
}

/// String settings (`sortierung.*`, `filter.*`, search history) in one JSON file.
pub struct FileKeyValue {
    path: PathBuf,
    map: Mutex<BTreeMap<String, String>>,
}

impl FileKeyValue {
    /// Opens (or starts) the file.
    pub fn open(path: PathBuf) -> FileKeyValue {
        let map = std::fs::read(&path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        FileKeyValue {
            path,
            map: Mutex::new(map),
        }
    }
}

impl KeyValue for FileKeyValue {
    fn get(&self, key: &str) -> Option<String> {
        self.map.lock().ok()?.get(key).cloned()
    }
    fn set(&self, key: &str, value: &str) {
        let mut g = self
            .map
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        g.insert(key.into(), value.into());
        if let Ok(b) = serde_json::to_vec(&*g) {
            let _ = swiftly_atomic::write_private(&self.path, &b);
        }
    }
}

#[cfg(test)]
mod fallback_tests {
    use super::*;

    #[test]
    fn the_vault_fallback_is_announced_once() {
        assert!(note_vault_fallback("token"));
        assert!(vault_fallback_used());
        assert!(!note_vault_fallback("token"));
    }
}

#[cfg(test)]
mod set_logged_tests {
    use super::*;
    use swiftly_settings::{JsonFileStore, KeyValueStore, Value};

    /// A write that fails is reported with the key, and the value is still there for this session.
    #[test]
    fn a_failed_settings_write_is_logged_and_the_value_stays_in_memory() {
        let dir = std::env::temp_dir().join(format!("swiftly-set-logged-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("settings.json");
        let store = JsonFileStore::open(&path).unwrap();
        // The file's place is taken by a directory afterwards: the write cannot succeed.
        std::fs::create_dir(&path).unwrap();
        let mut seen = Vec::new();
        let ok = set_logged_with(
            &store,
            "playerLautstaerke",
            Value::Double(0.4),
            &mut |w, m| seen.push((w.to_owned(), m.to_owned())),
        );
        assert!(!ok);
        assert_eq!(seen.len(), 1, "{seen:?}");
        assert!(seen[0].1.starts_with("playerLautstaerke"), "{seen:?}");
        assert_eq!(store.get("playerLautstaerke"), Some(Value::Double(0.4)));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
