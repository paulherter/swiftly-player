//! Typed access over a store.

use crate::key::{Key, SettingValue, server_key};
use crate::keys;
use crate::options::BufferLevel;
use crate::store::{KeyValueStore, StoreError};

/// Typed settings over any [`KeyValueStore`].
#[derive(Debug)]
pub struct Settings<S: KeyValueStore> {
    store: S,
}

impl<S: KeyValueStore> Settings<S> {
    /// Wraps a store.
    pub fn new(store: S) -> Self {
        Self { store }
    }

    /// The underlying store.
    pub fn store(&self) -> &S {
        &self.store
    }

    /// Reads a setting: the stored value if it has the right type, else the default
    /// (`object(forKey:) as? T ?? default`).
    pub fn get<T: SettingValue>(&self, key: &Key<T>) -> T {
        self.read(key.name).unwrap_or_else(|| key.default_value())
    }

    /// Writes a setting; an unset `Option` removes the key.
    pub fn set<T: SettingValue>(&self, key: &Key<T>, value: T) -> Result<(), StoreError> {
        self.write(key.name, &value)
    }

    /// Removes a setting, so the default applies again.
    pub fn reset<T: SettingValue>(&self, key: &Key<T>) -> Result<(), StoreError> {
        self.store.remove(key.name)
    }

    /// Whether the user ever set the key.
    pub fn is_set<T: SettingValue>(&self, key: &Key<T>) -> bool {
        self.store.contains(key.name)
    }

    /// Reads the per-server value `<key>|<server>`; if it was never set, the device-wide
    /// `<key>`; then the default (`AppModel.playbackLoad`, `AppModel.swift:236-243`).
    pub fn get_for_server<T: SettingValue>(&self, key: &Key<T>, server: &str) -> T {
        self.read(&server_key(key.name, server))
            .or_else(|| self.read(key.name))
            .unwrap_or_else(|| key.default_value())
    }

    /// Reads only the per-server value, with no device-wide fallback (`startBibliotheken`).
    pub fn get_for_server_only<T: SettingValue>(&self, key: &Key<T>, server: &str) -> T {
        self.read(&server_key(key.name, server))
            .unwrap_or_else(|| key.default_value())
    }

    /// Writes the per-server value `<key>|<server>`.
    pub fn set_for_server<T: SettingValue>(
        &self,
        key: &Key<T>,
        server: &str,
        value: T,
    ) -> Result<(), StoreError> {
        self.write(&server_key(key.name, server), &value)
    }

    fn read<T: SettingValue>(&self, name: &str) -> Option<T> {
        self.store.get(name).and_then(|v| T::from_value(&v))
    }

    fn write<T: SettingValue>(&self, name: &str, value: &T) -> Result<(), StoreError> {
        match value.to_value() {
            Some(v) => self.store.set(name, v),
            None => self.store.remove(name),
        }
    }

    /// The buffer level; an unknown stored text means `normal` (`AppModel.swift:717-718`).
    pub fn buffer_level(&self) -> BufferLevel {
        BufferLevel::from_raw(&self.get(&keys::PUFFERSTUFE)).unwrap_or(BufferLevel::Normal)
    }

    /// Sets the buffer level.
    pub fn set_buffer_level(&self, level: BufferLevel) -> Result<(), StoreError> {
        self.set(&keys::PUFFERSTUFE, level.raw().to_owned())
    }

    /// The one-time `utAuto` migration (`AppModel.swift:683-688`): a subtitle language chosen
    /// before the "automatic" switch existed never took effect, so switch it on once. Returns
    /// the resulting `utAuto`.
    pub fn migrate_subtitle_auto(&self) -> Result<bool, StoreError> {
        let language: String = self.get(&keys::UT_SPRACHE);
        let mut auto = self.get(&keys::UT_AUTO);
        if !self.get(&keys::UT_AUTO_NACHGEZOGEN) {
            self.set(&keys::UT_AUTO_NACHGEZOGEN, true)?;
            if !language.is_empty() && !auto {
                auto = true;
                self.set(&keys::UT_AUTO, true)?;
            }
        }
        Ok(auto)
    }
}
