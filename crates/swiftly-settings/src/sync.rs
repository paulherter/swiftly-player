//! **Settings that follow the Jellyfin account from device to device.** Pure logic ported from
//! `Packages/JellyfinKit/Sources/JellyfinKit/SettingsSync.swift`: which keys travel, how they are
//! encoded as text, and who wins. The server round trip (`DisplayPreferences/swiftly`) belongs
//! to the network layer; this module only builds and reads the bodies.
//!
//! Times are milliseconds since 1970 (`i64`), the unit the server holds. Swift used `Date`.

use crate::store::KeyValueStore;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Display preferences ID on the server (`SettingsSync.displayID`, `SettingsSync.swift:15`).
pub const DISPLAY_ID: &str = "swiftly";
/// Client name on the server; the column holds 32 characters at most (`SettingsSync.swift:16`).
pub const CLIENT_NAME: &str = "Swiftly";
/// Every synced key starts with this (`SettingsSync.swift:20`). Foreign keys are never touched.
pub const PREFIX: &str = "swiftly.";
/// Milliseconds since 1970 of the last change, as text (`SettingsSync.swift:22`).
pub const CHANGED_KEY: &str = "swiftly.changed";
/// Version of the scheme; written, not yet needed to read (`SettingsSync.swift:24`).
pub const FORMAT_KEY: &str = "swiftly.format";
/// The scheme version.
pub const FORMAT: &str = "1";
/// The Seerr connection value (`SettingsSync.swift`, `seerrKey`).
pub const SEERR_KEY: &str = "swiftly.seerr";
/// Time of the last Seerr change in milliseconds as text.
pub const SEERR_CHANGED_KEY: &str = "swiftly.seerrChanged";

/// How a setting is held on the device and written as text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// `true` / `false`.
    Bool,
    /// Whole number between 0 and 3600.
    Int,
    /// Any text.
    Text,
    /// A list of strings, as a JSON array.
    List,
    /// A JSON document kept as text (the chosen library rows).
    Json,
}

/// One synced setting. On the server it is stored as `swiftly.<name>`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Entry {
    /// The device (`UserDefaults`) key.
    pub name: &'static str,
    /// How it is encoded.
    pub kind: Kind,
    /// The device key carries the server address as a suffix; the suffix is not part of the
    /// synced name.
    pub per_server: bool,
}

const fn e(name: &'static str, kind: Kind, per_server: bool) -> Entry {
    Entry {
        name,
        kind,
        per_server,
    }
}

/// The synced settings, in the order of `SettingsSync.entries` (`SettingsSync.swift:59-79`).
/// **Per user and independent of the device, nothing else:** Wi-Fi only, volume, fill screen,
/// buffer, counters, debug and everything about downloads stay on the device.
pub const ENTRIES: [Entry; 19] = [
    e("tonSprache", Kind::Text, false),
    e("utSprache", Kind::Text, false),
    e("utAuto", Kind::Bool, false),
    e("utAussehen", Kind::Json, false),
    e("naechsteAuto", Kind::Bool, false),
    e("introAbspannAuto", Kind::Bool, false),
    e("restzeitAlsEnde", Kind::Bool, false),
    e("vorSek", Kind::Int, false),
    e("zurueckSek", Kind::Int, false),
    e("titelAlsLogo", Kind::Bool, false),
    e("fortschritt", Kind::Bool, false),
    e("merklisteAn", Kind::Bool, false),
    e("alphabetAn", Kind::Bool, false),
    e("neuGetrennt", Kind::Bool, false),
    e("startReihen", Kind::List, false),
    e("startAus", Kind::List, false),
    e("genreChips", Kind::Bool, false),
    e("startGenres", Kind::List, false),
    e("startBibliotheken", Kind::Json, true),
];

/// The entry for a device key as `UserDefaults` knows it; a `|server` suffix is ignored.
pub fn entry_for_device_key(key: &str) -> Option<&'static Entry> {
    let base = key.split('|').next().unwrap_or(key);
    ENTRIES.iter().find(|e| e.name == base)
}

/// A setting's value, independent of where it is stored.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SyncValue {
    /// Bool.
    Bool(bool),
    /// Whole number 0...3600.
    Int(i64),
    /// Text.
    Text(String),
    /// List of strings.
    List(Vec<String>),
    /// A JSON document as UTF-8 bytes.
    Json(Vec<u8>),
}

impl SyncValue {
    /// The text that goes to the server.
    pub fn encoded(&self) -> String {
        match self {
            Self::Bool(b) => if *b { "true" } else { "false" }.to_owned(),
            Self::Int(i) => i.to_string(),
            Self::Text(s) => s.clone(),
            // Swift's JSONEncoder writes `/` as `\/`; do the same so both platforms produce the same text.
            Self::List(l) => serde_json::to_string(l)
                .unwrap_or_else(|_| "[]".to_owned())
                .replace('/', "\\/"),
            Self::Json(d) => String::from_utf8_lossy(d).into_owned(),
        }
    }

    /// Reads a value back. **`None` for anything that does not fit its kind**, so a damaged or
    /// foreign entry changes nothing instead of something wrong.
    pub fn decode(text: &str, kind: Kind) -> Option<Self> {
        match kind {
            Kind::Bool => match text {
                "true" => Some(Self::Bool(true)),
                "false" => Some(Self::Bool(false)),
                _ => None,
            },
            Kind::Int => text
                .parse::<i64>()
                .ok()
                .filter(|i| (0..=3600).contains(i))
                .map(Self::Int),
            Kind::Text => Some(Self::Text(text.to_owned())),
            Kind::List => serde_json::from_str::<Vec<String>>(text)
                .ok()
                .map(Self::List),
            Kind::Json => {
                let json: serde_json::Value = serde_json::from_str(text).ok()?;
                // `JSONSerialization.jsonObject(with:)` without fragments: object or array only.
                (json.is_object() || json.is_array()).then(|| Self::Json(text.as_bytes().to_vec()))
            }
        }
    }
}

/// Reads the device value of every synced setting that was ever set, keyed by the synced name.
/// `read` gets the device key (with `|server` where it applies) and the kind, and answers
/// `None` for "never set". `server` is the part after the pipe (empty = none).
pub fn collect(
    server: &str,
    read: impl Fn(&str, Kind) -> Option<SyncValue>,
) -> BTreeMap<String, SyncValue> {
    let mut result = BTreeMap::new();
    for e in &ENTRIES {
        let key = if e.per_server {
            crate::key::server_key(e.name, server)
        } else {
            e.name.to_owned()
        };
        if let Some(v) = read(&key, e.kind) {
            result.insert(e.name.to_owned(), v);
        }
    }
    result
}

/// Reads a synced value from a store by its kind.
pub fn read_from_store(
    store: &dyn KeyValueStore,
    device_key: &str,
    kind: Kind,
) -> Option<SyncValue> {
    match kind {
        Kind::Bool => store.get_bool(device_key).map(SyncValue::Bool),
        Kind::Int => store.get_int(device_key).map(SyncValue::Int),
        Kind::Text => store.get_string(device_key).map(SyncValue::Text),
        Kind::List => match store.get(device_key)? {
            crate::Value::StrList(l) => Some(SyncValue::List(l)),
            _ => None,
        },
        Kind::Json => store.get_data(device_key).map(SyncValue::Json),
    }
}

/// Writes synced values into a store (what "apply" does on the device).
pub fn apply_to_store(
    store: &dyn KeyValueStore,
    server: &str,
    values: &BTreeMap<String, SyncValue>,
) -> Result<(), crate::StoreError> {
    for (name, value) in values {
        let Some(e) = ENTRIES.iter().find(|e| e.name == name) else {
            continue;
        };
        let key = if e.per_server {
            crate::key::server_key(e.name, server)
        } else {
            e.name.to_owned()
        };
        let v = match value {
            SyncValue::Bool(b) => crate::Value::Bool(*b),
            SyncValue::Int(i) => crate::Value::Int(*i),
            SyncValue::Text(s) => crate::Value::Str(s.clone()),
            SyncValue::List(l) => crate::Value::StrList(l.clone()),
            SyncValue::Json(d) => crate::Value::Data(d.clone()),
        };
        store.set(&key, v)?;
    }
    Ok(())
}

/// What the server holds: our values and when they were written.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Remote {
    /// Values by synced name.
    pub values: BTreeMap<String, SyncValue>,
    /// Milliseconds since 1970 of the last write.
    pub changed: Option<i64>,
}

impl Remote {
    /// Whether our scheme is on the server at all.
    pub fn present(&self) -> bool {
        self.changed.is_some() && !self.values.is_empty()
    }
}

fn millis(text: &str) -> Option<i64> {
    let v: f64 = text.parse().ok()?;
    v.is_finite().then(|| v.round() as i64)
}

/// Picks our entries out of the whole `CustomPrefs` and ignores the rest.
pub fn remote_from(prefs: &BTreeMap<String, String>) -> Remote {
    let mut values = BTreeMap::new();
    for e in &ENTRIES {
        if let Some(v) = prefs
            .get(&format!("{PREFIX}{}", e.name))
            .and_then(|t| SyncValue::decode(t, e.kind))
        {
            values.insert(e.name.to_owned(), v);
        }
    }
    Remote {
        values,
        changed: prefs.get(CHANGED_KEY).and_then(|t| millis(t)),
    }
}

/// The entries to write: every value plus time and version. Keys the device has not set are
/// **left out and not removed**, so another device's choice survives.
pub fn fields_for(values: &BTreeMap<String, SyncValue>, changed: i64) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for (name, value) in values {
        if ENTRIES.iter().any(|e| e.name == name) {
            out.insert(format!("{PREFIX}{name}"), value.encoded());
        }
    }
    out.insert(CHANGED_KEY.to_owned(), changed.to_string());
    out.insert(FORMAT_KEY.to_owned(), FORMAT.to_owned());
    out
}

/// The outcome of comparing server and device.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    /// Take the server's values.
    Apply,
    /// Write the device's values.
    Push,
    /// Equal; do nothing.
    Nothing,
}

/// **Newest change wins, whole set at a time.**
///
/// - `local_changed`: when something was last changed on this device or taken from the server;
///   `None` if never.
/// - `other_account`: the device last synced with another account (or never). Then the server's
///   copy wins whatever the times say.
pub fn decide(remote: &Remote, local_changed: Option<i64>, other_account: bool) -> Decision {
    let Some(theirs) = remote.changed.filter(|_| remote.present()) else {
        return Decision::Push;
    };
    if other_account {
        return Decision::Apply;
    }
    let Some(mine) = local_changed else {
        return Decision::Apply;
    };
    match theirs.cmp(&mine) {
        std::cmp::Ordering::Greater => Decision::Apply,
        std::cmp::Ordering::Less => Decision::Push,
        std::cmp::Ordering::Equal => Decision::Nothing,
    }
}

/// The time for a change made now. **Never earlier than what the server already holds**: a
/// device whose clock runs behind would otherwise lose against its own earlier write.
pub fn change_time(now: i64, last_known_remote: Option<i64>) -> i64 {
    match last_known_remote {
        Some(last) if last >= now => last + 1,
        _ => now,
    }
}

// ---- Seerr ----

/// One custom request header (`OwnHeader`, `JK/OwnHeaders.swift:17`; the value is stored as `wert`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OwnHeader {
    /// Header name.
    pub name: String,
    /// Header value.
    #[serde(rename = "wert")]
    pub value: String,
}

/// The Seerr connection (`SeerrAccess`, `JK/Seerr.swift:188`). It follows the account too, but
/// apart from the settings: it lives in the keychain and has its own time.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SeerrAccess {
    /// Seerr address.
    pub address: String,
    /// Session cookie as sent in the `Cookie` header.
    pub cookie: String,
    /// Gateway headers (Cloudflare Access, Authelia, Pangolin); empty for almost everyone.
    #[serde(default)]
    pub headers: Vec<OwnHeader>,
}

/// What to do with the Seerr connection.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SeerrStep {
    /// Take the server's connection; `None` is "disconnected".
    Adopt {
        /// The connection to take.
        access: Option<SeerrAccess>,
        /// Its change time in milliseconds.
        changed: i64,
    },
    /// Write the device's connection.
    Push,
    /// Nothing to do.
    Nothing,
}

/// Newest change wins, as with the settings. `local_changed`: when this device last connected,
/// disconnected or took the connection; `has_local`: the device holds a connection.
pub fn seerr_step(
    remote: &BTreeMap<String, String>,
    local_changed: Option<i64>,
    has_local: bool,
) -> SeerrStep {
    let fallback = if has_local {
        SeerrStep::Push
    } else {
        SeerrStep::Nothing
    };
    let (Some(text), Some(theirs)) = (
        remote.get(SEERR_KEY),
        remote.get(SEERR_CHANGED_KEY).and_then(|t| millis(t)),
    ) else {
        return fallback;
    };
    // A value we cannot read is someone else's mistake, not a disconnect.
    let access = if text.is_empty() {
        None
    } else {
        match serde_json::from_str::<SeerrAccess>(text) {
            Ok(a) => Some(a),
            Err(_) => return fallback,
        }
    };
    let Some(mine) = local_changed else {
        // Never touched here: take the server's, unless it would only take away a connection this
        // device has had since before syncing existed.
        return if access.is_none() && has_local {
            SeerrStep::Push
        } else {
            SeerrStep::Adopt {
                access,
                changed: theirs,
            }
        };
    };
    match theirs.cmp(&mine) {
        std::cmp::Ordering::Greater => SeerrStep::Adopt {
            access,
            changed: theirs,
        },
        std::cmp::Ordering::Less => SeerrStep::Push,
        std::cmp::Ordering::Equal => SeerrStep::Nothing,
    }
}

/// The fields that write the device's connection (`None` = disconnected, written as empty text).
pub fn seerr_fields(access: Option<&SeerrAccess>, changed: i64) -> BTreeMap<String, String> {
    let text = access
        .and_then(|a| serde_json::to_string(a).ok())
        .unwrap_or_default();
    BTreeMap::from([
        (SEERR_KEY.to_owned(), text),
        (SEERR_CHANGED_KEY.to_owned(), changed.to_string()),
    ])
}

// ---- The server's display preferences ----

/// A copy of the server's display preferences for one ID and client. **The body is kept as
/// received.** `POST` replaces everything, and the server maps some keys of `CustomPrefs` (and the
/// sorting) onto fields of its own; sending back only our part would reset those.
#[derive(Clone, Debug, PartialEq)]
pub struct DisplayPreferencesCopy {
    body: serde_json::Map<String, serde_json::Value>,
}

impl DisplayPreferencesCopy {
    /// Reads a response body; `None` if it is not a JSON object.
    pub fn from_body(body: &[u8]) -> Option<Self> {
        match serde_json::from_slice::<serde_json::Value>(body).ok()? {
            serde_json::Value::Object(body) => Some(Self { body }),
            _ => None,
        }
    }

    /// `CustomPrefs` as text. Entries that are not text (the server may hold `null`) are left
    /// out here and stay untouched in the body.
    pub fn custom_prefs(&self) -> BTreeMap<String, String> {
        self.body
            .get("CustomPrefs")
            .and_then(|p| p.as_object())
            .map(|o| {
                o.iter()
                    .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_owned())))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// The body to send: everything as received, with `fields` written into `CustomPrefs`.
    pub fn merged(&self, fields: &BTreeMap<String, String>) -> serde_json::Value {
        let mut body = self.body.clone();
        let mut prefs = body
            .get("CustomPrefs")
            .and_then(|p| p.as_object())
            .cloned()
            .unwrap_or_default();
        for (k, v) in fields {
            prefs.insert(k.clone(), serde_json::Value::String(v.clone()));
        }
        body.insert("CustomPrefs".to_owned(), serde_json::Value::Object(prefs));
        serde_json::Value::Object(body)
    }
}
