//! The `KeyValueStore` trait and its two Rust implementations.
//!
//! On Apple the app-group `UserDefaults` implements the trait, so `@AppStorage` views and
//! the core share the same values. Everywhere else the [`JsonFileStore`] is used.

use crate::value::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, PoisonError};

/// A store failure.
#[derive(Debug)]
pub enum StoreError {
    /// Reading or writing the file failed.
    Io(std::io::Error),
    /// The file is not a JSON object; it is left untouched.
    Corrupt(String),
    /// The value cannot be stored (a non-finite number).
    Unsupported(String),
}

impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "settings file: {e}"),
            Self::Corrupt(m) => write!(f, "settings file is damaged: {m}"),
            Self::Unsupported(m) => write!(f, "value cannot be stored: {m}"),
        }
    }
}

impl std::error::Error for StoreError {}

impl From<std::io::Error> for StoreError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}

/// A flat store of typed values by string key. Methods take `&self` so one store can be
/// shared between threads (`UserDefaults` is thread-safe too).
pub trait KeyValueStore: Send + Sync {
    /// The value for a key, or `None` if it was never set.
    fn get(&self, key: &str) -> Option<Value>;
    /// Sets a value.
    fn set(&self, key: &str, value: Value) -> Result<(), StoreError>;
    /// Removes a key (`removeObject(forKey:)`); a missing key is not an error.
    fn remove(&self, key: &str) -> Result<(), StoreError>;
    /// Every key that is set, sorted.
    fn keys(&self) -> Vec<String>;

    /// Whether a key is set.
    fn contains(&self, key: &str) -> bool {
        self.get(key).is_some()
    }
    /// A string, or `None` if unset or of another type.
    fn get_string(&self, key: &str) -> Option<String> {
        match self.get(key)? {
            Value::Str(s) => Some(s),
            _ => None,
        }
    }
    /// A bool, or `None` if unset or of another type.
    fn get_bool(&self, key: &str) -> Option<bool> {
        match self.get(key)? {
            Value::Bool(b) => Some(b),
            _ => None,
        }
    }
    /// An integer, or `None` if unset or of another type.
    fn get_int(&self, key: &str) -> Option<i64> {
        match self.get(key)? {
            Value::Int(i) => Some(i),
            _ => None,
        }
    }
    /// A double, or `None` if unset or of another type.
    fn get_double(&self, key: &str) -> Option<f64> {
        match self.get(key)? {
            Value::Double(d) => Some(d),
            _ => None,
        }
    }
    /// Data, or `None` if unset or of another type.
    fn get_data(&self, key: &str) -> Option<Vec<u8>> {
        match self.get(key)? {
            Value::Data(d) => Some(d),
            _ => None,
        }
    }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A store in memory; for tests and for platforms that persist elsewhere.
#[derive(Debug, Default)]
pub struct MemoryStore {
    values: Mutex<BTreeMap<String, Value>>,
}

impl MemoryStore {
    /// An empty store.
    pub fn new() -> Self {
        Self::default()
    }
}

impl KeyValueStore for MemoryStore {
    fn get(&self, key: &str) -> Option<Value> {
        lock(&self.values).get(key).cloned()
    }
    fn set(&self, key: &str, value: Value) -> Result<(), StoreError> {
        if matches!(value, Value::Double(d) if !d.is_finite()) {
            return Err(StoreError::Unsupported(format!(
                "{key}: not a finite number"
            )));
        }
        lock(&self.values).insert(key.to_owned(), value);
        Ok(())
    }
    fn remove(&self, key: &str) -> Result<(), StoreError> {
        lock(&self.values).remove(key);
        Ok(())
    }
    fn keys(&self) -> Vec<String> {
        lock(&self.values).keys().cloned().collect()
    }
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Standard Base64 with padding.
pub(crate) fn base64_encode(data: &[u8]) -> String {
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b = [
            chunk[0],
            chunk.get(1).copied().unwrap_or(0),
            chunk.get(2).copied().unwrap_or(0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(B64[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// Decodes standard Base64; `None` for invalid input.
pub(crate) fn base64_decode(text: &str) -> Option<Vec<u8>> {
    let bytes: Vec<u8> = text.bytes().filter(|b| *b != b'=').collect();
    if !text.len().is_multiple_of(4) {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() * 3 / 4);
    for chunk in bytes.chunks(4) {
        let mut n = 0u32;
        for (i, b) in chunk.iter().enumerate() {
            let v = B64.iter().position(|c| c == b)? as u32;
            n |= v << (18 - 6 * i);
        }
        for i in 0..chunk.len().saturating_sub(1) {
            out.push((n >> (16 - 8 * i)) as u8);
        }
    }
    Some(out)
}

/// The JSON form of a value: natural JSON for bool, number, string, string array and
/// string map; data is `{"$data": "<base64>"}`.
pub fn value_to_json(value: &Value) -> Result<serde_json::Value, StoreError> {
    use serde_json::Value as J;
    Ok(match value {
        Value::Bool(b) => J::Bool(*b),
        Value::Int(i) => J::from(*i),
        Value::Double(d) => J::Number(
            serde_json::Number::from_f64(*d)
                .ok_or_else(|| StoreError::Unsupported("not a finite number".into()))?,
        ),
        Value::Str(s) => J::String(s.clone()),
        Value::Data(d) => {
            let mut m = serde_json::Map::new();
            m.insert("$data".into(), J::String(base64_encode(d)));
            J::Object(m)
        }
        Value::StrList(l) => J::Array(l.iter().cloned().map(J::String).collect()),
        Value::StrMap(m) => J::Object(
            m.iter()
                .map(|(k, v)| (k.clone(), J::String(v.clone())))
                .collect(),
        ),
    })
}

/// Reads the JSON form back; `None` for shapes we do not store (they are kept as they are).
pub fn value_from_json(json: &serde_json::Value) -> Option<Value> {
    use serde_json::Value as J;
    match json {
        J::Bool(b) => Some(Value::Bool(*b)),
        J::Number(n) => n
            .as_i64()
            .map(Value::Int)
            .or_else(|| n.as_f64().map(Value::Double)),
        J::String(s) => Some(Value::Str(s.clone())),
        J::Array(a) => a
            .iter()
            .map(|x| x.as_str().map(str::to_owned))
            .collect::<Option<Vec<_>>>()
            .map(Value::StrList),
        J::Object(o) => {
            if o.len() == 1
                && let Some(J::String(b)) = o.get("$data")
            {
                return base64_decode(b).map(Value::Data);
            }
            o.iter()
                .map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_owned())))
                .collect::<Option<BTreeMap<_, _>>>()
                .map(Value::StrMap)
        }
        J::Null => None,
    }
}

#[derive(Debug, Default)]
struct FileState {
    values: BTreeMap<String, Value>,
    /// Entries of a shape we do not model; written back unchanged.
    foreign: BTreeMap<String, serde_json::Value>,
}

/// A store in one JSON file, written through on every change (atomically: temp file,
/// then rename). Used on Android and the desktop; one-time importers fill it from
/// SharedPreferences and today's desktop files.
#[derive(Debug)]
pub struct JsonFileStore {
    path: PathBuf,
    state: Mutex<FileState>,
}

impl JsonFileStore {
    /// Opens the file; a missing file is an empty store. A file that is not a JSON object
    /// is an error and stays untouched.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, StoreError> {
        let path = path.as_ref().to_path_buf();
        let mut state = FileState::default();
        match std::fs::read_to_string(&path) {
            Ok(text) if text.trim().is_empty() => {}
            Ok(text) => {
                let json: serde_json::Value =
                    serde_json::from_str(&text).map_err(|e| StoreError::Corrupt(e.to_string()))?;
                let serde_json::Value::Object(map) = json else {
                    return Err(StoreError::Corrupt("top level is not an object".into()));
                };
                for (k, v) in map {
                    match value_from_json(&v) {
                        Some(value) => {
                            state.values.insert(k, value);
                        }
                        None => {
                            state.foreign.insert(k, v);
                        }
                    }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
        Ok(Self {
            path,
            state: Mutex::new(state),
        })
    }

    /// The file this store writes to.
    pub fn path(&self) -> &Path {
        &self.path
    }

    fn persist(&self, state: &FileState) -> Result<(), StoreError> {
        let mut map = serde_json::Map::new();
        for (k, v) in &state.foreign {
            map.insert(k.clone(), v.clone());
        }
        for (k, v) in &state.values {
            map.insert(k.clone(), value_to_json(v)?);
        }
        let text = serde_json::to_string_pretty(&serde_json::Value::Object(map))
            .map_err(|e| StoreError::Corrupt(e.to_string()))?;
        swiftly_atomic::write(&self.path, text.as_bytes())?;
        Ok(())
    }
}

impl KeyValueStore for JsonFileStore {
    fn get(&self, key: &str) -> Option<Value> {
        lock(&self.state).values.get(key).cloned()
    }
    fn set(&self, key: &str, value: Value) -> Result<(), StoreError> {
        value_to_json(&value)?;
        let mut state = lock(&self.state);
        state.foreign.remove(key);
        state.values.insert(key.to_owned(), value);
        self.persist(&state)
    }
    fn remove(&self, key: &str) -> Result<(), StoreError> {
        let mut state = lock(&self.state);
        let had = state.values.remove(key).is_some() | state.foreign.remove(key).is_some();
        if had { self.persist(&state) } else { Ok(()) }
    }
    fn keys(&self) -> Vec<String> {
        lock(&self.state).values.keys().cloned().collect()
    }
}
