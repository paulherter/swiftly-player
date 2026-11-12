//! Settings that follow the Jellyfin account (`SettingsSync.swift`): keys, encoding, who wins,
//! and the merge into the server's `DisplayPreferences`.

use std::collections::BTreeMap;

use serde_json::{Map, Value as Json};
use swiftly_seerr::SeerrAccess;

/// How a setting is held on the device and written as text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// `true` / `false`.
    Bool,
    /// Whole number 0...3600.
    Int,
    /// Text.
    Text,
    /// A JSON array of strings.
    List,
    /// A JSON document kept as text.
    Json,
}

/// One synced setting.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry {
    /// Device (UserDefaults) name.
    pub name: &'static str,
    /// Encoding.
    pub kind: Kind,
    /// The device key carries the server address as a suffix (`|https://...`).
    pub per_server: bool,
}

/// A decoded value.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    /// Bool.
    Bool(bool),
    /// Int.
    Int(i64),
    /// Text.
    Text(String),
    /// List of strings.
    List(Vec<String>),
    /// A JSON document as text.
    Json(String),
}

impl Value {
    /// The text the server stores.
    pub fn encoded(&self) -> String {
        match self {
            Self::Bool(b) => b.to_string(),
            Self::Int(i) => i.to_string(),
            Self::Text(s) | Self::Json(s) => s.clone(),
            Self::List(l) => serde_json::to_string(l)
                .unwrap_or_else(|_| "[]".into())
                .replace('/', "\\/"),
        }
    }

    /// Reads server text as a kind; `None` if it does not fit.
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
            Kind::Text => Some(Self::Text(text.to_string())),
            Kind::List => serde_json::from_str::<Vec<String>>(text)
                .ok()
                .map(Self::List),
            Kind::Json => serde_json::from_str::<Json>(text)
                .ok()
                .filter(|j| j.is_object() || j.is_array())
                .map(|_| Self::Json(text.to_string())),
        }
    }
}

/// Server side state read from the custom prefs.
#[derive(Debug, Clone, PartialEq)]
pub struct Remote {
    /// Decoded values by device name.
    pub values: BTreeMap<String, Value>,
    /// Last change, seconds since 1970.
    pub changed: Option<f64>,
}

impl Remote {
    /// Something usable is stored.
    pub fn present(&self) -> bool {
        self.changed.is_some() && !self.values.is_empty()
    }
}

/// Who wins.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    /// Take the server's.
    Apply,
    /// Write ours.
    Push,
    /// Equal.
    Nothing,
}

/// What to do with the Seerr connection.
#[derive(Debug, Clone, PartialEq)]
pub enum SeerrStep {
    /// Take the server's (`None` = disconnected).
    Adopt(Option<SeerrAccess>, f64),
    /// Write ours.
    Push,
    /// Equal.
    Nothing,
}

/// Namespace.
pub struct SettingsSync;

fn ms(t: f64) -> i64 {
    #[allow(clippy::cast_possible_truncation)]
    let v = (t * 1000.0).round();
    if v.is_finite() { v as i64 } else { 0 }
}

macro_rules! e {
    ($n:literal, $k:ident, $p:literal) => {
        Entry {
            name: $n,
            kind: Kind::$k,
            per_server: $p,
        }
    };
}

impl SettingsSync {
    /// Display preferences id.
    pub const DISPLAY_ID: &'static str = "swiftly";
    /// Client name.
    pub const CLIENT_NAME: &'static str = "Swiftly";
    /// Prefix of every key of ours.
    pub const PREFIX: &'static str = "swiftly.";
    /// Last change (ms since 1970, text).
    pub const CHANGED_KEY: &'static str = "swiftly.changed";
    /// Scheme version key.
    pub const FORMAT_KEY: &'static str = "swiftly.format";
    /// Scheme version.
    pub const FORMAT: &'static str = "1";
    /// Seerr connection key.
    pub const SEERR_KEY: &'static str = "swiftly.seerr";
    /// Seerr change time key.
    pub const SEERR_CHANGED_KEY: &'static str = "swiftly.seerrChanged";

    /// The synced keys (same list and order as Swift).
    pub const ENTRIES: [Entry; 19] = [
        e!("tonSprache", Text, false),
        e!("utSprache", Text, false),
        e!("utAuto", Bool, false),
        e!("utAussehen", Json, false),
        e!("naechsteAuto", Bool, false),
        e!("introAbspannAuto", Bool, false),
        e!("restzeitAlsEnde", Bool, false),
        e!("vorSek", Int, false),
        e!("zurueckSek", Int, false),
        e!("titelAlsLogo", Bool, false),
        e!("fortschritt", Bool, false),
        e!("merklisteAn", Bool, false),
        e!("alphabetAn", Bool, false),
        e!("neuGetrennt", Bool, false),
        e!("startReihen", List, false),
        e!("startAus", List, false),
        e!("genreChips", Bool, false),
        e!("startGenres", List, false),
        e!("startBibliotheken", Json, true),
    ];

    /// The entry for a device key, ignoring the `|server` suffix.
    pub fn entry_for_device_key(key: &str) -> Option<Entry> {
        let base = key.split('|').next().unwrap_or(key);
        Self::ENTRIES.iter().copied().find(|e| e.name == base)
    }

    /// Reads the device's values; `read(device_key, kind)`.
    pub fn collect(
        server_suffix: &str,
        read: impl Fn(&str, Kind) -> Option<Value>,
    ) -> BTreeMap<String, Value> {
        let mut result = BTreeMap::new();
        for e in Self::ENTRIES {
            let key = if e.per_server {
                format!("{}{server_suffix}", e.name)
            } else {
                e.name.to_string()
            };
            if let Some(v) = read(&key, e.kind) {
                result.insert(e.name.to_string(), v);
            }
        }
        result
    }

    /// Reads the server's custom prefs; foreign keys and unreadable values are ignored.
    pub fn remote(prefs: &BTreeMap<String, String>) -> Remote {
        let mut values = BTreeMap::new();
        for e in Self::ENTRIES {
            if let Some(v) = prefs
                .get(&format!("{}{}", Self::PREFIX, e.name))
                .and_then(|t| Value::decode(t, e.kind))
            {
                values.insert(e.name.to_string(), v);
            }
        }
        let changed = prefs
            .get(Self::CHANGED_KEY)
            .and_then(|t| t.parse::<f64>().ok())
            .map(|v| v / 1000.0);
        Remote { values, changed }
    }

    /// The fields to write for these values.
    pub fn fields(values: &BTreeMap<String, Value>, changed: f64) -> BTreeMap<String, String> {
        let mut out = BTreeMap::new();
        for (name, value) in values {
            if Self::ENTRIES.iter().any(|e| e.name == name) {
                out.insert(format!("{}{name}", Self::PREFIX), value.encoded());
            }
        }
        out.insert(Self::CHANGED_KEY.into(), ms(changed).to_string());
        out.insert(Self::FORMAT_KEY.into(), Self::FORMAT.into());
        out
    }

    /// Who wins (compared in whole milliseconds).
    pub fn decide(remote: &Remote, local_changed: Option<f64>, other_account: bool) -> Decision {
        let (true, Some(theirs)) = (remote.present(), remote.changed) else {
            return Decision::Push;
        };
        if other_account {
            return Decision::Apply;
        }
        let Some(mine) = local_changed else {
            return Decision::Apply;
        };
        match ms(theirs).cmp(&ms(mine)) {
            std::cmp::Ordering::Greater => Decision::Apply,
            std::cmp::Ordering::Less => Decision::Push,
            std::cmp::Ordering::Equal => Decision::Nothing,
        }
    }

    /// The Seerr connection travels as one JSON value with its own change time.
    pub fn seerr_step(
        prefs: &BTreeMap<String, String>,
        local_changed: Option<f64>,
        has_local: bool,
    ) -> SeerrStep {
        let none_or_push = if has_local {
            SeerrStep::Push
        } else {
            SeerrStep::Nothing
        };
        let (Some(text), Some(theirs)) = (
            prefs.get(Self::SEERR_KEY),
            prefs
                .get(Self::SEERR_CHANGED_KEY)
                .and_then(|t| t.parse::<f64>().ok())
                .map(|v| v / 1000.0),
        ) else {
            return none_or_push;
        };
        // A value we cannot read is someone else's mistake, not a disconnect.
        let access = if text.is_empty() {
            None
        } else if let Ok(a) = serde_json::from_str::<SeerrAccess>(text) {
            Some(a)
        } else {
            return none_or_push;
        };
        let Some(mine) = local_changed else {
            // Never touched here: take the server's, unless it would only take away a
            // connection this device has had since before syncing existed.
            return if access.is_none() && has_local {
                SeerrStep::Push
            } else {
                SeerrStep::Adopt(access, theirs)
            };
        };
        match ms(theirs).cmp(&ms(mine)) {
            std::cmp::Ordering::Greater => SeerrStep::Adopt(access, theirs),
            std::cmp::Ordering::Less => SeerrStep::Push,
            std::cmp::Ordering::Equal => SeerrStep::Nothing,
        }
    }

    /// The fields for the Seerr connection (`None` = disconnected, empty text).
    pub fn seerr_fields(access: Option<&SeerrAccess>, changed: f64) -> BTreeMap<String, String> {
        let text = access
            .and_then(|a| serde_json::to_string(a).ok())
            .unwrap_or_default();
        BTreeMap::from([
            (Self::SEERR_KEY.to_string(), text),
            (Self::SEERR_CHANGED_KEY.to_string(), ms(changed).to_string()),
        ])
    }

    /// A change time that never runs behind the server's (one millisecond after it).
    pub fn change_time(now: f64, last_known_remote: Option<f64>) -> f64 {
        match last_known_remote {
            Some(last) if last >= now => last + 0.001,
            _ => now,
        }
    }
}

/// The server's display preferences, kept as the raw body so the rest stays untouched.
#[derive(Debug, Clone, PartialEq)]
pub struct DisplayPreferencesCopy {
    body: Vec<u8>,
}

impl DisplayPreferencesCopy {
    /// Wraps a body; `None` unless it is a JSON object.
    pub fn from_body(body: &[u8]) -> Option<Self> {
        serde_json::from_slice::<Map<String, Json>>(body).ok()?;
        Some(Self {
            body: body.to_vec(),
        })
    }

    /// `CustomPrefs` with string values only (nulls and other types are dropped).
    pub fn custom_prefs(&self) -> BTreeMap<String, String> {
        let Ok(Json::Object(o)) = serde_json::from_slice::<Json>(&self.body) else {
            return BTreeMap::new();
        };
        o.get("CustomPrefs")
            .and_then(Json::as_object)
            .map(|p| {
                p.iter()
                    .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// The body with `fields` merged into `CustomPrefs`; everything else stays.
    pub fn merged(&self, fields: &BTreeMap<String, String>) -> Vec<u8> {
        let mut object = match serde_json::from_slice::<Json>(&self.body) {
            Ok(Json::Object(o)) => o,
            _ => Map::new(),
        };
        let mut prefs = match object.remove("CustomPrefs") {
            Some(Json::Object(p)) => p,
            _ => Map::new(),
        };
        for (k, v) in fields {
            prefs.insert(k.clone(), Json::String(v.clone()));
        }
        object.insert("CustomPrefs".into(), Json::Object(prefs));
        serde_json::to_vec(&Json::Object(object)).unwrap_or_default()
    }
}
