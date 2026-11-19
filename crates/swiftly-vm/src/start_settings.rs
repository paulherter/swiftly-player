//! What the core takes from the settings store when the app starts, before any screen exists.
//!
//! Two switches are read by the core where no store is at hand (decoding a server list, the delete flow), so they live in
//! process-wide cells ([`swiftly_model::switches`]). A cell that only the settings page fills would be wrong after every
//! relaunch until that page opens. This module is the one place that fills it from the store: every host calls
//! [`apply_stored_settings`] once at start, and the settings view model calls [`load_core_switches`] at every publish.
//! A new setting the core reads outside a store belongs here, never into a view model.

use swiftly_model::switches;
use swiftly_settings::{KeyValueStore, Settings, keys};

/// Hands the core-owned switches their stored values ("Leere Serien ausblenden", "Löschen vom Server sperren").
pub fn load_core_switches<S: KeyValueStore>(settings: &Settings<S>) {
    switches::set_hide_empty_series(settings.get(&keys::LEERE_SERIEN_AUSBLENDEN));
    switches::set_server_delete_locked(settings.get(&keys::LOESCHEN_SPERREN));
}

/// Everything the core needs from the stored settings at start: the one-time migration of the subtitle language to the
/// "automatic" switch (it does its work once), then the core-owned switches. Idempotent; cheap.
pub fn apply_stored_settings<S: KeyValueStore>(settings: &Settings<S>) {
    // A store that fails to write only skips the migration; the switches are read all the same.
    let _ = settings.migrate_subtitle_auto();
    load_core_switches(settings);
}
