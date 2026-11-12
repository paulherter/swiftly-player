//! Typed keys: a persisted name, a type and the default the Swift code uses.

use crate::value::{Value, ValueType};
use std::collections::BTreeMap;

/// A Rust type a setting can have.
pub trait SettingValue: Sized {
    /// The stored type.
    const TYPE: ValueType;
    /// How a default is written in a `const` (`&'static str` for `String`, `()` for `Option`).
    type Const: Copy;
    /// Builds the default.
    fn from_const(c: Self::Const) -> Self;
    /// Reads a stored value; `None` if it has another type (then the default applies, as
    /// `object(forKey:) as? T ?? default` does in Swift).
    fn from_value(v: &Value) -> Option<Self>;
    /// The value to store; `None` means "remove the key" (an unset `Option`).
    fn to_value(&self) -> Option<Value>;
}

impl SettingValue for bool {
    const TYPE: ValueType = ValueType::Bool;
    type Const = bool;
    fn from_const(c: bool) -> Self {
        c
    }
    fn from_value(v: &Value) -> Option<Self> {
        match v {
            Value::Bool(b) => Some(*b),
            _ => None,
        }
    }
    fn to_value(&self) -> Option<Value> {
        Some(Value::Bool(*self))
    }
}

impl SettingValue for i64 {
    const TYPE: ValueType = ValueType::Int;
    type Const = i64;
    fn from_const(c: i64) -> Self {
        c
    }
    fn from_value(v: &Value) -> Option<Self> {
        match v {
            Value::Int(i) => Some(*i),
            // An NSNumber holding a whole double reads as Int in Swift.
            Value::Double(d) if d.fract() == 0.0 && d.abs() < 9.0e15 => Some(*d as i64),
            _ => None,
        }
    }
    fn to_value(&self) -> Option<Value> {
        Some(Value::Int(*self))
    }
}

impl SettingValue for f64 {
    const TYPE: ValueType = ValueType::Double;
    type Const = f64;
    fn from_const(c: f64) -> Self {
        c
    }
    fn from_value(v: &Value) -> Option<Self> {
        match v {
            Value::Double(d) => Some(*d),
            Value::Int(i) => Some(*i as f64),
            _ => None,
        }
    }
    fn to_value(&self) -> Option<Value> {
        Some(Value::Double(*self))
    }
}

impl SettingValue for String {
    const TYPE: ValueType = ValueType::String;
    type Const = &'static str;
    fn from_const(c: &'static str) -> Self {
        c.to_owned()
    }
    fn from_value(v: &Value) -> Option<Self> {
        match v {
            Value::Str(s) => Some(s.clone()),
            Value::Data(d) => String::from_utf8(d.clone()).ok(),
            _ => None,
        }
    }
    fn to_value(&self) -> Option<Value> {
        Some(Value::Str(self.clone()))
    }
}

impl SettingValue for Vec<u8> {
    const TYPE: ValueType = ValueType::Data;
    type Const = &'static [u8];
    fn from_const(c: &'static [u8]) -> Self {
        c.to_vec()
    }
    fn from_value(v: &Value) -> Option<Self> {
        match v {
            Value::Data(d) => Some(d.clone()),
            Value::Str(s) => Some(s.clone().into_bytes()),
            _ => None,
        }
    }
    fn to_value(&self) -> Option<Value> {
        Some(Value::Data(self.clone()))
    }
}

impl SettingValue for Vec<String> {
    const TYPE: ValueType = ValueType::StringList;
    type Const = &'static [&'static str];
    fn from_const(c: &'static [&'static str]) -> Self {
        c.iter().map(|s| (*s).to_owned()).collect()
    }
    fn from_value(v: &Value) -> Option<Self> {
        match v {
            Value::StrList(l) => Some(l.clone()),
            _ => None,
        }
    }
    fn to_value(&self) -> Option<Value> {
        Some(Value::StrList(self.clone()))
    }
}

impl SettingValue for BTreeMap<String, String> {
    const TYPE: ValueType = ValueType::StringMap;
    type Const = ();
    fn from_const((): ()) -> Self {
        BTreeMap::new()
    }
    fn from_value(v: &Value) -> Option<Self> {
        match v {
            Value::StrMap(m) => Some(m.clone()),
            _ => None,
        }
    }
    fn to_value(&self) -> Option<Value> {
        Some(Value::StrMap(self.clone()))
    }
}

/// `Option<T>` is a setting that has no default in the Swift code ("unset" is a state of
/// its own): `None` removes the key.
impl<T: SettingValue> SettingValue for Option<T> {
    const TYPE: ValueType = T::TYPE;
    type Const = ();
    fn from_const((): ()) -> Self {
        None
    }
    fn from_value(v: &Value) -> Option<Self> {
        T::from_value(v).map(Some)
    }
    fn to_value(&self) -> Option<Value> {
        self.as_ref().and_then(T::to_value)
    }
}

/// Where a setting lives and whether it follows the account.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scope {
    /// This device only.
    Device,
    /// Synced as `swiftly.<name>` through the server's display preferences.
    Synced,
    /// Device key with a `|<server>` suffix, not synced.
    DevicePerServer,
    /// Synced and stored per server (`startBibliotheken`).
    SyncedPerServer,
}

impl Scope {
    /// Whether the settings sync carries it.
    pub fn is_synced(self) -> bool {
        matches!(self, Self::Synced | Self::SyncedPerServer)
    }
    /// Whether the stored key has a server suffix.
    pub fn is_per_server(self) -> bool {
        matches!(self, Self::DevicePerServer | Self::SyncedPerServer)
    }
}

/// A typed key. The `name` is the persisted `UserDefaults` key and must never change.
#[derive(Debug)]
pub struct Key<T: SettingValue> {
    /// The persisted key.
    pub name: &'static str,
    /// The default, as written in Swift.
    pub default: T::Const,
    /// Where it lives.
    pub scope: Scope,
    /// Swift `file:line` of the key (relative to the repository root).
    pub source: &'static str,
}

impl<T: SettingValue> Key<T> {
    /// A key definition.
    pub const fn new(
        name: &'static str,
        default: T::Const,
        scope: Scope,
        source: &'static str,
    ) -> Self {
        Self {
            name,
            default,
            scope,
            source,
        }
    }

    /// The default value.
    pub fn default_value(&self) -> T {
        T::from_const(self.default)
    }
}

/// One row of the key registry.
#[derive(Clone, Copy, Debug)]
pub struct KeyInfo {
    /// The persisted key.
    pub name: &'static str,
    /// The stored type.
    pub value_type: ValueType,
    /// The default as written in the definition.
    pub default: &'static str,
    /// Where it lives.
    pub scope: Scope,
    /// Swift `file:line`.
    pub source: &'static str,
}

/// The persisted key of a per-server setting: `<key>|<server>`. `server` is the server
/// address for Jellyfin and Emby (`https://host:8096`) or `plex:<machine id>` for Plex, exactly
/// as `Session.serverSuffix` builds it (`PlexSession.swift:110`). Empty `server` gives the
/// plain device-wide key.
pub fn server_key(name: &str, server: &str) -> String {
    if server.is_empty() {
        name.to_owned()
    } else {
        format!("{name}|{server}")
    }
}

/// The server part for a Jellyfin or Emby server (the address as written).
pub fn jellyfin_server(address: &str) -> String {
    address.to_owned()
}

/// The server part for a Plex server.
pub fn plex_server(machine_identifier: &str) -> String {
    format!("plex:{machine_identifier}")
}
