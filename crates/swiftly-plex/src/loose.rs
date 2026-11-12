//! Lenient reading of Plex's JSON (`PlexWire.swift:14-45`).
//!
//! Plex writes the same field once as a number and once as a string depending on version and
//! route (`"forced": 1`, `true`, `"1"`). Nothing here fails for one odd value: a field that
//! cannot be read is `None`, and an entry of a list that cannot be read is skipped.

use serde_json::Value;

/// `looseString` (PlexWire.swift:14): text, else an integer, else a float as text.
pub(crate) fn string(v: &Value, key: &str) -> Option<String> {
    match v.get(key)? {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Some(i.to_string())
            } else {
                // Swift's `String(Double)`: `7.5`, `8.0`.
                n.as_f64().map(|f| format!("{f:?}"))
            }
        }
        _ => None,
    }
}

/// `looseDouble` (:20): a number, else text that parses.
pub(crate) fn double(v: &Value, key: &str) -> Option<f64> {
    match v.get(key)? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.parse::<f64>().ok(),
        _ => None,
    }
}

/// `looseInt` (:25): an integer, else a finite double below 9e15 truncated.
pub(crate) fn int(v: &Value, key: &str) -> Option<i64> {
    if let Some(i) = v.get(key).and_then(Value::as_i64) {
        return Some(i);
    }
    double(v, key)
        .filter(|n| n.is_finite() && n.abs() < 9e15)
        .map(|n| n as i64)
}

/// `looseBool` (:30): a bool, else a number (non-zero), else `1`/`true`/`yes`.
pub(crate) fn boolean(v: &Value, key: &str) -> Option<bool> {
    if let Some(b) = v.get(key).and_then(Value::as_bool) {
        return Some(b);
    }
    if let Some(n) = int(v, key) {
        return Some(n != 0);
    }
    match v.get(key)? {
        Value::String(s) => Some(["1", "true", "yes"].contains(&s.to_lowercase().as_str())),
        _ => None,
    }
}

/// `looseList` (:38): the entries that can be read, the others dropped; `None` if the key is
/// missing or not an array.
pub(crate) fn list<T>(v: &Value, key: &str, read: impl Fn(&Value) -> Option<T>) -> Option<Vec<T>> {
    match v.get(key)? {
        Value::Array(items) => Some(items.iter().filter_map(read).collect()),
        _ => None,
    }
}
