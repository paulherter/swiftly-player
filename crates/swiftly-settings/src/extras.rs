//! Small settings items that are not plain fixed keys: the remembered library per kind, the
//! Keychain account of the Seerr login, the "Gesehen von" server list and the desktop UI scale.

use crate::keys;
use crate::settings::Settings;
use crate::store::{KeyValueStore, StoreError};
use std::collections::BTreeSet;

/// Key of the remembered library for one kind of library: `bibliothek-<art>`
/// (`AppModel.libraryName(_:)`, `Sources/Shared/AppModel.swift:289`). `art` is the collection
/// type (`movies`, `tvshows`, ...). The value is the library id, or `alle` for "All".
pub fn library_name(art: &str) -> String {
    format!("bibliothek-{art}")
}

/// Keychain account of the Seerr login without an account (`SeerrModel.swift:21`).
pub const SEERR_ACCOUNT: &str = "seerr";

/// Keychain account of the Seerr login for one server identity: `seerr|<identity>`
/// (`SeerrModel.swift:73-76`: `Self.key + "|" + new`). An empty identity is the bare key.
pub fn seerr_account(identity: &str) -> String {
    if identity.is_empty() {
        SEERR_ACCOUNT.to_owned()
    } else {
        format!("{SEERR_ACCOUNT}|{identity}")
    }
}

/// The servers known to have the "Gesehen von" plugin (`AppModel.watchersServers`,
/// `AppModel.swift:60,688`): stored sorted as `gesehenVonServer`, read as a set.
pub fn watchers_servers<S: KeyValueStore>(settings: &Settings<S>) -> BTreeSet<String> {
    settings
        .get(&keys::GESEHEN_VON_SERVER)
        .into_iter()
        .collect()
}

/// Stores the set again, sorted like Swift's `Array(set).sorted()`.
pub fn set_watchers_servers<S: KeyValueStore>(
    settings: &Settings<S>,
    servers: &BTreeSet<String>,
) -> Result<(), StoreError> {
    settings.set(&keys::GESEHEN_VON_SERVER, servers.iter().cloned().collect())
}

/// Marks one server as having the plugin (`AppModel.watchers(of:)`, `AppModel.swift:1837`):
/// an empty key is ignored. Returns whether the list changed.
pub fn mark_watchers_server<S: KeyValueStore>(
    settings: &Settings<S>,
    server_key: &str,
) -> Result<bool, StoreError> {
    if server_key.is_empty() {
        return Ok(false);
    }
    let mut servers = watchers_servers(settings);
    if !servers.insert(server_key.to_owned()) {
        return Ok(false);
    }
    set_watchers_servers(settings, &servers)?;
    Ok(true)
}

/// The desktop "Groesse der Oberflaeche" (`Linux/Sources/SwiftlyLinux/Scaling.swift:36-50`).
pub mod ui_scale {
    /// Field name of the share in the desktop selection file (`Selection.swift:341`).
    pub const FIELD: &str = "oberflaeche";
    /// The slider steps: tens, eight stops, 80 to 150 %.
    pub const LEVELS: [f64; 8] = [0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5];

    /// Any value (from the file, edited by hand) snapped to the nearest step; a value that is
    /// not finite is 1. Ties go to the lower step, as `min(by:)` keeps the first.
    pub fn snapped(value: f64) -> f64 {
        if !value.is_finite() {
            return 1.0;
        }
        let mut best = 1.0;
        let mut best_distance = f64::INFINITY;
        for level in LEVELS {
            let distance = (level - value).abs();
            if distance < best_distance {
                best = level;
                best_distance = distance;
            }
        }
        best
    }

    /// System part times user part; within 0.005 of 1 it is exactly 1 (no wrapper).
    pub fn factor(system_share: f64, user_share: f64) -> f64 {
        let f = system_share * user_share;
        if (f - 1.0).abs() < 0.005 { 1.0 } else { f }
    }

    /// What Windows adds on top of GDK: DPI / 96 divided by GDK's integer factor; only a
    /// noticeable share (above 1.05) counts.
    pub fn system_share(dpi: u32, gdk_factor: u32) -> f64 {
        let raw = f64::from(dpi) / 96.0 / f64::from(gdk_factor.max(1));
        if raw > 1.05 { raw } else { 1.0 }
    }
}
