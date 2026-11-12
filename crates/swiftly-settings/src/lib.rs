//! Typed settings for Swiftly over a [`KeyValueStore`].
//!
//! - [`keys`]: every persisted key with its Swift default and `file:line`; the German names are
//!   exactly the ones devices already hold.
//! - [`Settings`]: typed `get` / `set` with the Swift defaults, per-server keys `<key>|<server>`.
//! - [`MemoryStore`], [`JsonFileStore`]: the Rust stores. On Apple, `UserDefaults` implements the
//!   trait so `@AppStorage` and the core share values.
//! - [`sync`]: which keys travel as `swiftly.*` and who wins (ported from `SettingsSync.swift`).

pub mod extras;
pub mod key;
pub mod keys;
pub mod options;
mod settings;
pub mod store;
pub mod sync;
pub mod value;

pub use key::{Key, KeyInfo, Scope, SettingValue, jellyfin_server, plex_server, server_key};
pub use settings::Settings;
pub use store::{JsonFileStore, KeyValueStore, MemoryStore, StoreError};
pub use value::{Value, ValueType};
